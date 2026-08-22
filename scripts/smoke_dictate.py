#!/usr/bin/env python3
"""Dictation: hexe drives a tool, and types back what the tool says.

hexe does no audio here -- the "tool" is a shell script -- because what is
being tested is hexe's half of the contract, and that half is the same whether
the far end is whisper or `echo`:

  * starting it marks the pane as listening, and the tool is told which pane
    and where hexe's API is;
  * stopping it closes the tool's stdin, which is the stop signal a shell
    script can implement without trapping anything;
  * whatever the tool prints on stdout is typed into the pane dictation was
    STARTED in -- not whichever pane happens to be focused when it finishes,
    which is the bug that would put a sentence in the wrong shell;
  * stderr is not typed, because a tool's diagnostics are not a transcript.

The tool here blocks on stdin exactly as the real one does, so a hexe that
never closed stdin would hang instead of passing.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"dictate{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
PHRASE = f"dictated{os.getpid()}"
SAW = os.path.join(WD, "tool-env")

# The stand-in tool. Blocks on stdin like the real one, records what hexe told
# it, then prints the phrase on stdout and a decoy on stderr.
TOOL = os.path.join(WD, "tool.sh")
with open(TOOL, "w") as fh:
    fh.write(f"""#!/bin/sh
{{ echo "pane=$HEXE_PANE_UUID"; echo "api=$HEXE_API_SOCKET"; }} > {SAW!r}
read -r _ignored || true
echo "STDERR_MUST_NOT_BE_TYPED" >&2
printf '%s' {PHRASE!r}
""")
os.chmod(TOOL, 0o755)

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(f"""
local hexe = require("hexe")
hexe.dictate = {{ command = "sh {TOOL}" }}
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
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


# hexe's own rendered output. The meter is drawn INTO hexe's frame, over the
# pane, so it never appears in `screen_text` (which is the pane's own terminal
# buffer) -- the only place to see it is what hexe writes to its terminal.
screen_out = bytearray()
screen_lock = threading.Lock()

# U+2581..U+2588, the eighth-block ramp the meter is drawn from.
RAMP = [chr(c) for c in range(0x2581, 0x2589)]


def saw_meter(since):
    with screen_lock:
        text = bytes(screen_out[since:]).decode("utf-8", "replace")
    return any(g in text for g in RAMP)


def out_len():
    with screen_lock:
        return len(screen_out)


def drain():
    while True:
        try:
            chunk = os.read(m, 65536)
            if not chunk:
                return
            with screen_lock:
                screen_out.extend(chunk)
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "dictate"], stdin=sl, stdout=sl,
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

# Idle to begin with.
st = api("dictate").get("result") or {}
if st.get("active"):
    fail(f"dictation is active before anything started it: {st}")
if st.get("phase") != "idle":
    fail(f"expected phase idle, got {st.get('phase')!r}")

# 1. Start: the tool runs, and is told where it is.
st = api("dictate", "true").get("result") or {}
if not st.get("active"):
    fail(f"`dictate(true)` did not start anything: {st}")
if st.get("phase") != "listening":
    fail(f"expected phase listening, got {st.get('phase')!r}")
if st.get("pane_uuid") != uuid:
    fail(f"dictation targets {st.get('pane_uuid')!r}, not the focused pane {uuid!r}")
print("start: the tool is running and the pane is marked listening")

deadline = time.time() + 20
while time.time() < deadline and not os.path.exists(SAW):
    time.sleep(0.3)
if not os.path.exists(SAW):
    fail("the tool never ran, or never saw its environment")
saw = dict(line.split("=", 1) for line in open(SAW).read().splitlines() if "=" in line)
if saw.get("pane") != uuid:
    fail(f"the tool was told pane={saw.get('pane')!r}, expected {uuid!r}")
if not saw.get("api"):
    fail("the tool was not told where hexe's API socket is")
print("env: the tool knows its pane and how to reach hexe")

# The meter: three half-block columns at the pane's bottom, animating. Checked
# against hexe's rendered output, because that is the only place it exists.
mark = out_len()
time.sleep(1.5)
if not saw_meter(mark):
    fail("nothing was drawn while listening; the pane gives no sign that a "
         "microphone is open, which is the whole point of the indicator")
print("meter: half-block bars are drawn while the tool is listening")

# It must animate, not sit still -- a frozen bar reads as a stuck session.
frames = set()
for _ in range(6):
    mark = out_len()
    time.sleep(0.35)
    with screen_lock:
        chunk = bytes(screen_out[mark:]).decode("utf-8", "replace")
    frames.update(g for g in RAMP if g in chunk)
if len(frames) < 2:
    fail(f"the meter never changed height (only {frames!r}); it is not animating")
print(f"meter: the bars move ({len(frames)} different heights seen)")

# The tool is blocked on stdin, so nothing has been typed yet. If hexe typed
# something here it would be typing a transcript that does not exist.
screen = (api("screen_text").get("result") or "")
if PHRASE in screen:
    fail("the phrase appeared before dictation was stopped")

# 2. Stop: hexe closes stdin, the tool finishes, hexe types the transcript.
api("dictate", "false")

deadline = time.time() + 30
typed = False
while time.time() < deadline:
    if PHRASE in (api("screen_text").get("result") or ""):
        typed = True
        break
    time.sleep(0.5)
if not typed:
    fail("the tool's text was never typed into the pane; either stdin was not "
         "closed (so the tool never finished) or the transcript was dropped")
print("stop: closing stdin ended the tool and its text was typed into the pane")

screen = api("screen_text").get("result") or ""
if "STDERR_MUST_NOT_BE_TYPED" in screen:
    fail("the tool's stderr was typed into the pane; only stdout is a transcript")
print("stderr: the tool's diagnostics were not typed")

# 3. Back to idle, and startable again -- a one-shot dictation would be useless.
deadline = time.time() + 20
while time.time() < deadline:
    st = api("dictate").get("result") or {}
    if not st.get("active"):
        break
    time.sleep(0.4)
if (api("dictate").get("result") or {}).get("active"):
    fail("dictation never returned to idle after the tool exited")

# And the meter goes away with it. An indicator that outlives the recording is
# worse than none: it says a microphone is open when it is not.
time.sleep(1.0)
mark = out_len()
time.sleep(1.5)
if saw_meter(mark):
    fail("the meter is still being drawn after dictation ended")
print("meter: it stops when dictation does")

st = api("dictate", "true").get("result") or {}
if not st.get("active"):
    fail(f"dictation could not be started a second time: {st}")
api("dictate", "false")
print("reuse: dictation returns to idle and can start again")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: hexe drives a dictation tool and types back what it says")
