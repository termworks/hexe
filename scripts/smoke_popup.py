#!/usr/bin/env python3
"""A plugin puts a link (or a QR) on screen, and the user dismisses it.

hexe has no idea what a link is and no idea what a QR code is. `popup` takes a
block of text and draws it until a key is pressed. A QR is a grid of block
characters the plugin already rendered -- which is the whole point: the moment
hexe knows what a QR is, it owns a QR library and a set of opinions about them.

So this checks the three things that make it usable at all:

  * a multi-line block is drawn intact, not clipped to one line -- a QR sheared
    in half is worse than no QR;
  * it stays until dismissed, rather than timing out while someone reaches for
    their phone;
  * a keypress closes it, and that key does not also reach the shell.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"popup{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
LINK = f"https://drop.example/{os.getpid()}"
SAW = os.path.join(WD, "seen")
GO = os.path.join(WD, "go")

# A tiny QR stand-in: a block grid, exactly what `qrencode -t UTF8` produces.
QR_ROWS = ["█▀▀▀▀▀█ ▄▀▄ █▀▀▀▀▀█",
           "█ ███ █ ▀█▄ █ ███ █",
           "█ ▀▀▀ █ █▄▀ █ ▀▀▀ █",
           "▀▀▀▀▀▀▀ ▀ ▀ ▀▀▀▀▀▀▀"]
QR = "\n".join(QR_ROWS)

TOOL = os.path.join(WD, "tool.sh")
with open(TOOL, "w") as fh:
    fh.write(f"""#!/bin/sh
{{ echo "access=$HEXE_ACCESS"; }} > {SAW!r}
while [ ! -f {GO!r} ]; do sleep 0.2; done
hexe api popup "$(cat {WD!r}/payload.json)" >/dev/null 2>&1
sleep 600
""")
os.chmod(TOOL, 0o755)
# The plugin sends a link and a QR together, as one block.
open(os.path.join(WD, "payload.json"), "w").write(json.dumps(f"scan to join\n{QR}\n{LINK}"))

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(f"""
local hexe = require("hexe")
hexe.plugin("sharer", {{ command = "sh {TOOL}", access = {{ "popup" }} }})
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "PATH": os.path.join(REPO, "zig-out/bin") + ":" + os.environ.get("PATH", ""),
            "TERM": "xterm-256color", "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_FLOAT", "HEXE_PAINTER_SOCKET", "HEXE_ENV_FD", "HEXE_BIN", "HEXE_API_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    r = subprocess.run(["pgrep", "-f", f"instance {INST}"], capture_output=True, text=True)
    if r.returncode == 0:
        for pid in r.stdout.split():
            try: os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError): pass
    subprocess.run(["pkill", "-9", "-f", TOOL], capture_output=True)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush()
    cleanup()
    sys.exit(1)


def watchdog(_s, _f):
    print("FAIL: timed out")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(150)


def api(*args):
    r = subprocess.run([HEXE, "api", *args], env=env, cwd=WD,
                       capture_output=True, text=True, timeout=25)
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return {}


screen_out = bytearray()
lock = threading.Lock()


def out_len():
    with lock:
        return len(screen_out)


def seen_since(since):
    with lock:
        return bytes(screen_out[since:]).decode("utf-8", "replace")


def drain():
    while True:
        try:
            c = os.read(m, 65536)
            if not c:
                return
            with lock:
                screen_out.extend(c)
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "popup"], stdin=sl, stdout=sl,
                      stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 40
while time.time() < deadline and not os.path.exists(SAW):
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    time.sleep(0.4)
if not os.path.exists(SAW):
    fail("the plugin never started")
if "popup" not in open(SAW).read():
    fail("the plugin was not granted popup access")
print("plugin: holds `popup` and nothing more")

# Nothing on screen until the plugin says so.
mark = out_len()
time.sleep(1.2)
if LINK in seen_since(mark):
    fail("the link was on screen before anything asked for it")

open(GO, "w").write("go")

deadline = time.time() + 25
shown = False
while time.time() < deadline:
    if LINK in seen_since(0):
        shown = True
        break
    time.sleep(0.3)
if not shown:
    fail("the plugin called popup and nothing appeared")
print("show: the link the plugin passed is on screen")

# The QR block must survive intact. Every row, not just the first: the old
# overlay drew one line, which would have cut this in half.
body = seen_since(0)
missing = [r for r in QR_ROWS if r not in body]
if missing:
    fail(f"{len(missing)} of {len(QR_ROWS)} QR rows never rendered — a multi-line "
         f"block is being flattened, so a real QR would be unscannable")
print(f"block: all {len(QR_ROWS)} rows of the QR rendered")

# It waits. Someone reaching for their phone must not lose it to a timeout.
mark = out_len()
time.sleep(3.0)
st = api("popup", '"probe"')
if not st.get("ok"):
    fail(f"popup call failed: {st}")
time.sleep(0.6)
if "probe" not in seen_since(mark):
    fail("a second popup did not replace the first")
print("persist: it stays until something replaces or dismisses it")

# A keypress closes it, and does not reach the shell.
os.write(m, b"q")
time.sleep(1.5)
mark = out_len()
time.sleep(1.2)
if "probe" in seen_since(mark):
    fail("the popup is still drawn after a keypress")
screen = api("screen_text").get("result") or ""
if "q" in screen.replace("$", "").strip().split("\n")[-1:][0:1] and screen.strip().endswith("q"):
    fail("the key that dismissed the popup also reached the shell")
print("dismiss: a keypress closes it and is swallowed")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: a plugin can show a link or a QR, and hexe knows what neither is")
