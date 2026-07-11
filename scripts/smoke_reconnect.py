#!/usr/bin/env python3
"""Live smoke test: SES daemon crash -> frontend auto-reconnect + session restore.

Runs a real terminal frontend under a pty in an isolated HEXE_INSTANCE,
verifies shell I/O works, SIGKILLs the ses daemon, and verifies:
  1. the frontend survives and auto-restarts the daemon,
  2. the pod (and the user's shell) never died,
  3. shell I/O works again end-to-end after the auto-reattach.
"""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"

env = os.environ.copy()
env["HEXE_INSTANCE"] = INST
env["XDG_STATE_HOME"] = os.path.join(SCRATCH, "smoke-state")
env["TERM"] = "xterm-256color"
env["SHELL"] = "/bin/sh"
env.pop("HEXE_SESSION", None)
env.pop("HEXE_NO_PROJECT_COMMANDS", None)

os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

def ses_pids():
    return pgrep(f"ses daemon --instance {INST}")

def pod_pids():
    return pgrep(f"pod daemon --instance {INST}")

def read_until(fd, marker, timeout_s, log):
    """Read pty master until marker bytes appear; returns True on hit."""
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False
            if not chunk:
                return False
            buf += chunk
            log.write(chunk)
            if marker in buf:
                return True
    return False

def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)

fe = None
def cleanup():
    if fe and fe.poll() is None:
        fe.terminate()
        try:
            fe.wait(timeout=3)
        except subprocess.TimeoutExpired:
            fe.kill()
    for pid in ses_pids() + pod_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
log = open(os.path.join(SCRATCH, "smoke-fe.raw"), "wb")

print(f"instance={INST}")
fe = subprocess.Popen(
    [HEXE, "mux", "new", "-n", "smoke", "--log", "debug", "-L", os.path.join(SCRATCH, "smoke-fe.log")],
    stdin=slave, stdout=slave, stderr=slave,
    env=env, cwd=SCRATCH, start_new_session=True,
)
os.close(slave)

# Phase 1: frontend up, daemon up, shell I/O round-trip.
time.sleep(2.5)
if fe.poll() is not None:
    fail(f"frontend exited early rc={fe.returncode}")
ses1 = ses_pids()
if not ses1:
    fail("no ses daemon started")
print(f"phase1: ses daemon pid={ses1}")

os.write(master, b"echo SMOKE_$((40+2))_BEFORE\r")
if not read_until(master, b"SMOKE_42_BEFORE", 8, log):
    fail("no shell echo before crash")
print("phase1: shell I/O OK")
pods1 = pod_pids()
if not pods1:
    fail("no pod process found")
print(f"phase1: pod pids={pods1}")

# Phase 2: SIGKILL the daemon mid-session.
for pid in ses1:
    os.kill(pid, signal.SIGKILL)
print("phase2: ses daemon SIGKILLed")

# Phase 3: frontend must auto-restart the daemon and reattach.
deadline = time.time() + 15
ses2 = []
while time.time() < deadline:
    ses2 = [p for p in ses_pids() if p not in ses1]
    if ses2:
        break
    time.sleep(0.3)
if not ses2:
    fail("daemon was not auto-restarted within 15s")
print(f"phase3: daemon auto-restarted pid={ses2}")
if fe.poll() is not None:
    fail(f"frontend died after daemon crash rc={fe.returncode}")

pods2 = pod_pids()
if set(pods1) - set(pods2):
    fail(f"pods died across daemon crash: {pods1} -> {pods2}")
print(f"phase3: pods survived ({pods2})")

# Phase 4: end-to-end shell I/O after auto-reattach (give reattach a moment).
time.sleep(3)
ok = False
for attempt in range(3):
    os.write(master, b"echo SMOKE_$((40+3))_AFTER\r")
    if read_until(master, b"SMOKE_43_AFTER", 8, log):
        ok = True
        break
    time.sleep(2)
if not ok:
    fail("no shell echo after reconnect: panes did not recover")
print("phase4: shell I/O after auto-reconnect OK")

# Phase 5: the daemon's crash-persistence record shows the restored session.
r = subprocess.run([HEXE, "ses", "list"], capture_output=True, text=True, env=env, timeout=10)
print(f"phase5: ses list stdout={r.stdout.strip()!r} stderr={r.stderr.strip()[:120]!r}")
time.sleep(1.5)  # persist cadence is 1s
state_file = os.path.join(env["XDG_STATE_HOME"], "hexe", INST, "ses_state.json")
data = open(state_file).read()
if '"session_name":"smoke"' not in data:
    fail("restored session missing from persisted daemon state")
print("phase5: persisted state records the restored session")

cleanup()
log.close()
print("SMOKE PASS: daemon crash -> auto-reconnect -> session restored, shell intact")
