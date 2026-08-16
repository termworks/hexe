#!/usr/bin/env python3
"""Live check: `hexe pod record --capture-input` records keystrokes, except passwords.

Two defects lived here.

1. `--capture-input` was a DEAD FLAG. The recorder handled `.input` frames, but
   the pod broadcast only `.output` to observers, so the arm was unreachable and
   every cast came out input-free while the flag reported success.

2. Password suppression was DEAD END TO END. `password_input` is derived by
   ghostty from the PTY's termios (canonical + no echo), but ghostty only does
   that in its own exec loop, which hexe does not use — the pod owns the PTY.
   Nothing in hexe ever wrote `terminal.flags.password_input`, so the flag was
   permanently false and every consumer of it was dead: the pod's output/backlog
   suppression, keycast suppression, and `hexe.live.pane.password_input`.
   The pod now derives it from its own master fd and tells observers.

The pty master MUST be drained (see smoke_float_concurrent) or the frontend
blocks in writev(2) and this looks like a product hang.
"""
import atexit
import fcntl, glob, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
CAST = os.path.join(SCRATCH, f"podrec{os.getpid()}.cast")
VISIBLE = "VISIBLEMARK"
SECRET = "SUPERSECRETPW"

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
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


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


def drain_pty(fd):
    while True:
        try:
            if not os.read(fd, 65536):
                return
        except OSError:
            return


LOG = os.path.join(SCRATCH, f"podrec{os.getpid()}.log")
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "podrec", "--logfile", LOG], stdin=slave,
                      stdout=slave, stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
threading.Thread(target=drain_pty, args=(master,), daemon=True).start()
time.sleep(3.5)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

# Find the pane's pod socket.
runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
socks = glob.glob(os.path.join(runtime, "hexe", INST, "pod-*.sock"))
if not socks:
    fail(f"no pod socket found under {runtime}/hexe/{INST}")
sock = socks[0]

rec = subprocess.Popen([HEXE, "pod", "record", "--socket", sock, "--out", CAST, "--capture-input"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                       env=env, cwd=SCRATCH, start_new_session=True)
procs.append(rec)
time.sleep(2.0)
if rec.poll() is not None:
    fail(f"`pod record` exited early rc={rec.returncode}")

# 1) Ordinary typing must be captured.
os.write(master, f"echo {VISIBLE}\r".encode())
time.sleep(2.0)

# 2) A password prompt: canonical mode with echo off is exactly what the pod
#    must detect. Typed bytes here must NOT reach the cast.
os.write(master, b"stty -echo\r")
time.sleep(2.0)
os.write(master, f"echo {SECRET}\r".encode())
time.sleep(2.0)
os.write(master, b"stty echo\r")
time.sleep(2.0)

rec.terminate()
try: rec.wait(timeout=5)
except subprocess.TimeoutExpired: rec.kill()

if not os.path.exists(CAST):
    fail("no cast file was produced")
data = open(CAST, errors="replace").read()

inputs = []
for line in data.splitlines()[1:]:
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if len(ev) >= 3 and ev[1] == "i":
        inputs.append(ev[2])
typed = "".join(inputs)

if not inputs:
    fail(f"--capture-input produced NO input events at all ({len(data)} bytes of cast) "
         "— the pod is not mirroring input to observers")
if VISIBLE not in typed:
    fail(f"typed text missing from the recorded input stream: {typed!r}")
print(f"capture: {len(inputs)} input event(s), typed text present")

if SECRET in typed:
    fail(f"PASSWORD LEAK: text typed while the tty was canonical+noecho was recorded: {typed!r}")
if SECRET in data:
    fail("PASSWORD LEAK: the secret reached the cast through the output stream")
print("password mode: keystrokes typed with echo off were not recorded")

# The frontend half: keycast suppression and `hexe.live.pane.password_input`
# read terminal.flags.password_input, which NOTHING in hexe used to write. The
# pod now reports the transition and the frontend applies it to the pane.
log = open(LOG, errors="replace").read() if os.path.exists(LOG) else ""
if "password_input=true" not in log:
    fail("the frontend never applied password mode to the pane "
         "(keycast and hexe.live.pane.password_input stay dead)")
if "password_input=false" not in log:
    fail("the frontend never saw password mode turn back OFF — the pane would stay locked")
print("frontend: pane password_input flipped on and back off")

cleanup()
print("SMOKE PASS: pod record captures input and suppresses it during password entry")
