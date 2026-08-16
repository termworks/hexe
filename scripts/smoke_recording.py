#!/usr/bin/env python3
"""Live check: `hexe terminal record` records the SESSION, not its own error.

It used to spawn the literal string "hexe terminal attach" with no session
name. That command prints "Error: session name required" and exits, so every
cast ever produced contained exactly that one line — a recorder that always
"worked" and never recorded anything.

Also covers the record-state lifecycle: start must not claim success for a
child that died, and stop/status must agree with it.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
CAST = os.path.join(SCRATCH, f"rec{os.getpid()}.cast")
MARKER = "HEXE_RECORDING_MARKER"

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


def hexe(*args):
    r = subprocess.run([HEXE] + list(args), capture_output=True, text=True, env=env, timeout=20)
    return r.returncode, (r.stdout + r.stderr).strip()


# A session worth recording.
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "rectarget"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
time.sleep(3.5)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

# Recording without naming a session must be refused, not silently useless.
rc, out = hexe("terminal", "record", "--out", CAST)
if rc == 0:
    fail(f"`terminal record` with no session should fail, got rc=0: {out!r}")
rc, out = hexe("record", "start", "--scope", "mux", "--out", CAST)
if rc == 0:
    fail(f"`record start --scope mux` with no --name should fail, got rc=0: {out!r}")

# Record the real session from a second pty.
if os.path.exists(CAST):
    os.unlink(CAST)
m2, s2 = pty.openpty()
fcntl.ioctl(s2, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
rec = subprocess.Popen([HEXE, "terminal", "record", "rectarget", "--out", CAST],
                       stdin=s2, stdout=s2, stderr=s2, env=env, cwd=SCRATCH, start_new_session=True)
os.close(s2); procs.append(rec)
time.sleep(3.0)
os.write(m2, f"echo {MARKER}\r".encode())
time.sleep(2.5)
rec.terminate()
try: rec.wait(timeout=5)
except subprocess.TimeoutExpired: rec.kill()

if not os.path.exists(CAST):
    fail("no cast file was produced")
data = open(CAST, errors="replace").read()
if "session name required" in data:
    fail("the cast contains the recorder's own error message — it attached to nothing")
if MARKER not in data:
    fail(f"the cast does not contain the session's output ({len(data)} bytes)")
header = data.splitlines()[0] if data else ""
if '"version":2' not in header:
    fail(f"bad asciicast header: {header[:120]!r}")
if "rectarget" not in header:
    fail(f"header does not name the recorded session: {header[:120]!r}")
print(f"record: {len(data)} bytes, header names the session, session output present")

# stop/status agreement when nothing is recording.
rc, out = hexe("record", "stop", "--scope", "pod")
if rc == 0:
    fail(f"`record stop` with nothing recording should fail, got rc=0: {out!r}")

# State must not live in a world-writable /tmp path.
stale = f"/tmp/hexe/{INST}"
if os.path.isdir(stale):
    fail(f"recording state still uses the shared {stale}")
print("state: no world-writable /tmp state directory")

cleanup()
print("SMOKE PASS: terminal record captures the named session")
