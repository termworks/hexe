#!/usr/bin/env python3
"""hexe hands a pane's bytes to a plugin, in a format the plugin already reads.

The thing being tested is that hexe knows *nothing* about what the stream is
for. It does not know about sharing, links, QR codes or the far end. It knows a
pane makes bytes, a plugin was granted them, and the format is asciicast v2 --
the same thing `asciinema play` reads.

So:

  * attaching sends a cast header, then the pane as it looks now, then events;
  * a plugin holding `stream` gets to watch and nothing more;
  * a plugin holding `stream` and `typing` may send `[t,"i",data]` back and hexe
    types it into the pane -- view-only versus read-write is the access it was
    granted, not a flag on a request;
  * a password prompt arrives as an asciicast marker, because a plugin keeping
    its own scrollback has to be told to scrub it.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"stream{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
CAST = os.path.join(WD, "out.cast")
MARK = f"streamed{os.getpid()}"
TYPED = f"typedback{os.getpid()}"
SNEAK = f"sneaked{os.getpid()}"

# A read-write plugin: records what it is fed, and types one line back. Its
# stdout is the input channel, so nothing may be printed there casually.
RW = os.path.join(WD, "rw.py")
with open(RW, "w") as fh:
    fh.write(f"""
import json, sys
log = open({os.path.join(WD, 'rw.cast')!r}, "w")
header = sys.stdin.readline()
log.write(header); log.flush()
sent = False
for line in sys.stdin:
    log.write(line); log.flush()
    if not sent and {MARK!r} in line:
        sys.stdout.write(json.dumps([0.0, "i", "echo {TYPED}\\r"]) + "\\n")
        sys.stdout.flush()
        sent = True
""")

VIEW = os.path.join(WD, "view.py")
with open(VIEW, "w") as fh:
    fh.write(f"""
import json, sys
sys.stdin.readline()
for line in sys.stdin:
    if {MARK!r} in line:
        # Holds `stream` but NOT `typing`. hexe must ignore this.
        sys.stdout.write(json.dumps([0.0, "i", "echo {SNEAK}\\r"]) + "\\n")
        sys.stdout.flush()
        break
""")

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(f"""
local hexe = require("hexe")
hexe.plugin("echo", {{ command = "python3 {REPO}/contrib/share-echo.py", access = {{ "stream", "popup" }} }})
hexe.plugin("rw",   {{ command = "python3 {RW}", access = {{ "stream", "typing" }} }})
hexe.plugin("view", {{ command = "python3 {VIEW}", access = {{ "stream" }} }})
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF, "SHARE_ECHO_OUT": CAST,
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
    subprocess.run(["pkill", "-9", "-f", RW], capture_output=True)
    subprocess.run(["pkill", "-9", "-f", "share-echo.py"], capture_output=True)


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
def drain():
    while True:
        try:
            c = os.read(m, 65536)
            if not c:
                return
            screen_out.extend(c)
        except OSError:
            return


def wait_file(path, secs=25):
    end = time.time() + secs
    while time.time() < end:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path).read()
        time.sleep(0.3)
    return None


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "stream"], stdin=sl, stdout=sl,
                      stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 40
pane = None
while time.time() < deadline and pane is None:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    for p in api("panes").get("result") or []:
        pane = p
        break
    time.sleep(0.5)
if pane is None:
    fail("no pane appeared")
uuid = pane["uuid"]

# Nothing is streaming until something asks.
if os.path.exists(CAST):
    fail("a plugin was fed a stream nobody attached")

r = api("stream", '"echo"')
if not (r.get("result") or {}).get("attached"):
    fail(f"`stream('echo')` did not attach: {r}")
# Two plugins on the same pane: the stream is not exclusive, and each gets its
# own cast rather than one being tee'd through the other.
api("stream", '"view"')
r2 = api("stream", '"rw"')
if not (r2.get("result") or {}).get("attached"):
    fail(f"a second plugin could not attach to the same pane: {r2}")
print("attach: both plugins were handed the same pane")

head = wait_file(CAST)
if head is None:
    fail("the plugin received nothing after attaching")
first = head.splitlines()[0]
meta = json.loads(first)
if meta.get("version") != 2:
    fail(f"the plugin was not sent asciicast v2, so a generic consumer cannot read it: {first[:90]}")
if not meta.get("width") or not meta.get("height"):
    fail(f"the cast header carries no size, so a viewer must guess the layout: {first[:90]}")
print(f"format: asciicast v2, {meta['width']}x{meta['height']} — readable by anything that plays casts")

# Live output reaches it.
os.write(m, f"echo {MARK}\r".encode())
deadline = time.time() + 30
got = False
while time.time() < deadline:
    body = open(CAST).read() if os.path.exists(CAST) else ""
    if MARK in body:
        got = True
        break
    time.sleep(0.4)
if not got:
    fail("live output never reached the plugin")

# ...as events, not raw bytes: a consumer parses lines, not a byte soup.
events = [json.loads(l) for l in open(CAST).read().splitlines()[1:] if l.strip().startswith("[")]
if not any(e[1] == "o" for e in events):
    fail("no output events in the cast; the stream is not in the documented shape")
print(f"live: output arrives as asciicast events ({len(events)} so far)")

# A `typing` plugin may send input back; hexe types it into the pane.
deadline = time.time() + 40
typed = False
while time.time() < deadline:
    if TYPED in (api("screen_text").get("result") or ""):
        typed = True
        break
    time.sleep(0.5)
if not typed:
    fail("the read-write plugin's input never reached the pane; `typing` access "
         "is what separates view-only from read-write and it did nothing")
print("write-back: the plugin holding `typing` typed into the pane")

# The other half, and the one that makes `typing` mean anything: a plugin with
# `stream` alone wrote the same kind of event and must have been ignored. Both
# plugins saw the marker at the same moment, so by the time the granted one has
# landed, the ungranted one has had its chance.
screen = api("screen_text").get("result") or ""
if SNEAK in screen:
    fail("a plugin holding only `stream` typed into the pane -- view-only is "
         "not view-only, and the access split buys nothing")
print("write-back: a plugin without `typing` was ignored when it tried")

# Detaching stops it.
api("stream", '"echo"', "false")
time.sleep(1.0)
before = os.path.getsize(CAST)
os.write(m, b"echo after-detach\r")
time.sleep(2.5)
if os.path.getsize(CAST) != before:
    fail("the plugin kept receiving after detach")
print("detach: the stream stops when asked")

if fe.poll() is not None:
    tail = bytes(screen_out[-3000:]).decode("utf-8", "replace")
    fail(f"the frontend died during the checks (rc={fe.returncode})\n--- terminal tail ---\n{tail}")

cleanup()
print("PASS: a pane's bytes reach a plugin as asciicast, and typing access decides write-back")
