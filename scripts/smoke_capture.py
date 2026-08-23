#!/usr/bin/env python3
"""Dictation is a plugin, not a hexe feature.

hexe has no `hexe.dictate` setting, no dictate actions and no speech code. What
it has is two general things a plugin composes:

  * `typing` access, so a tool may put text into a pane;
  * `capture`, so a tool may say "something is recording you" and hexe draws it.

So this drives the same end-to-end flow the old built-in dictation had -- claim
the indicator, produce text, type it into the pane -- entirely through the
plugin surface. If that works, nothing was lost by deleting the feature.

The indicator is checked against hexe's *rendered output*, because that is the
only place it exists: hexe draws it, deliberately, so no painter can style it
away and no plugin can forge it.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"capture{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
PHRASE = f"dictated{os.getpid()}"
GO = os.path.join(WD, "go")
SAW = os.path.join(WD, "seen")

# A dictation tool, with the speech part replaced by a file. Everything else is
# what a real one does: claim the indicator, renew it, then type the text in.
TOOL = os.path.join(WD, "tool.sh")
with open(TOOL, "w") as fh:
    fh.write(f"""#!/bin/sh
{{ echo "sock=$HEXE_API_SOCKET"; echo "access=$HEXE_ACCESS"; }} > {SAW!r}
while [ ! -f {GO!r} ]; do sleep 0.2; done
pane=$(hexe api pane 2>/dev/null | sed -n 's/.*"uuid":"\\([0-9a-f]*\\)".*/\\1/p')
i=0
while [ $i -lt 12 ]; do
    hexe api capture true >/dev/null 2>&1
    sleep 0.4
    i=$((i+1))
done
hexe api capture false >/dev/null 2>&1
hexe api send "\\"$pane\\"" '"echo {PHRASE}\\r"' >/dev/null 2>&1
sleep 600
""")
os.chmod(TOOL, 0o755)

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(f"""
local hexe = require("hexe")
hexe.plugin("dictate", {{ command = "sh {TOOL}", access = {{ "typing" }} }})
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


# hexe's own rendered output: the only place the indicator exists.
screen_out = bytearray()
lock = threading.Lock()
RAMP = [chr(c) for c in range(0x2581, 0x2589)]


def out_len():
    with lock:
        return len(screen_out)


def saw_bars(since):
    with lock:
        text = bytes(screen_out[since:]).decode("utf-8", "replace")
    return {g for g in RAMP if g in text}


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
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "capture"], stdin=sl, stdout=sl,
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
seen = dict(l.split("=", 1) for l in open(SAW).read().splitlines() if "=" in l)
if seen.get("access") != "read,typing":
    fail(f"the plugin holds {seen.get('access')!r}, expected 'read,typing'")
print("plugin: dictation is an ordinary plugin holding `typing`")

# Nothing claims capture until something does.
st = api("capture").get("result") or {}
if st.get("capturing"):
    fail(f"something claimed capture before anything asked: {st}")
mark = out_len()
time.sleep(1.2)
if saw_bars(mark):
    fail("the capture bars are drawn when nothing is capturing")
print("idle: nothing is drawn while nothing is capturing")

# Go: the plugin claims the indicator and types the text.
open(GO, "w").write("go")

deadline = time.time() + 25
while time.time() < deadline:
    if (api("capture").get("result") or {}).get("capturing"):
        break
    time.sleep(0.3)
st = api("capture").get("result") or {}
if not st.get("capturing"):
    fail("the plugin claimed capture and hexe did not report it")
print(f"claim: hexe reports capture on pane {str(st.get('pane_uuid'))[:8]}")

frames = set()
for _ in range(6):
    mark = out_len()
    time.sleep(0.35)
    frames |= saw_bars(mark)
if not frames:
    fail("hexe reports capturing but drew nothing; the indicator is the whole "
         "point and it is invisible")
if len(frames) < 2:
    fail(f"the bars never changed height ({frames!r}); a frozen indicator reads "
         "as a frozen screen")
print(f"indicator: hexe draws moving bars ({len(frames)} heights seen)")

# The text lands in the pane, through `typing` access alone.
deadline = time.time() + 40
typed = False
while time.time() < deadline:
    if PHRASE in (api("screen_text").get("result") or ""):
        typed = True
        break
    time.sleep(0.5)
if not typed:
    fail("the plugin's text never reached the pane")
print("typing: the plugin typed its text into the pane")

# The claim is released, and the light goes out.
deadline = time.time() + 20
while time.time() < deadline:
    if not (api("capture").get("result") or {}).get("capturing"):
        break
    time.sleep(0.4)
if (api("capture").get("result") or {}).get("capturing"):
    fail("capture was never released")
time.sleep(0.8)
mark = out_len()
time.sleep(1.5)
if saw_bars(mark):
    fail("the bars are still drawn after capture ended; an indicator that "
         "outlives the recording is worse than none")
print("release: the indicator stops when the capture does")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: dictation works as a plugin, with no dictation code in hexe")
