#!/usr/bin/env python3
"""Live smoke test: frontend death -> reattach from a new terminal.

The most common real flow: a terminal window closes (frontend dies without a
clean detach), the session parks in the daemon, and the user reattaches from
a new terminal. Shell state (an exported variable) proves the SAME shell
process survived the whole cycle.
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
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

procs = []

def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

def pod_pids():
    return pgrep(f"pod daemon --instance {INST}")

def spawn_frontend(argv):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=SCRATCH, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, master

def read_until(fd, marker, timeout_s, log):
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

def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    for pid in pgrep(f"daemon --instance {INST}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

log = open(os.path.join(SCRATCH, "smoke2-fe.raw"), "wb")
print(f"instance={INST}")

# Phase 1: frontend A with shell state.
fe_a, master_a = spawn_frontend([HEXE, "mux", "new", "-n", "smoke2"])
time.sleep(2.5)
if fe_a.poll() is not None:
    fail(f"frontend A exited early rc={fe_a.returncode}")
os.write(master_a, b"export SMOKE_VAR=persisted$((40+2))\r")
time.sleep(0.5)
os.write(master_a, b"echo VAR_IS_$SMOKE_VAR\r")
if not read_until(master_a, b"VAR_IS_persisted42", 8, log):
    fail("shell state setup failed in frontend A")
pods1 = pod_pids()
if not pods1:
    fail("no pod for frontend A")
print(f"phase1: frontend A up, SMOKE_VAR set, pod={pods1}")

# Phase 2: kill the frontend the hard way (window closed / terminal died).
os.kill(fe_a.pid, signal.SIGKILL)
fe_a.wait()
os.close(master_a)
print("phase2: frontend A SIGKILLed")
time.sleep(2.0)  # let the daemon notice the disconnect and park the session

pods2 = pod_pids()
if set(pods1) - set(pods2):
    fail(f"pods died when frontend died: {pods1} -> {pods2}")
print(f"phase3: session parked, pods alive ({pods2})")

# Phase 4: reattach from a brand-new terminal.
r = subprocess.run([HEXE, "ses", "list"], capture_output=True, text=True, env=env, timeout=10)
print(f"pre-attach ses list: out={r.stdout.strip()!r} err={r.stderr.strip()[:300]!r}")
fe_b, master_b = spawn_frontend([HEXE, "mux", "attach", "smoke2", "--log", "debug",
                                 "-L", os.path.join(SCRATCH, "smoke2-feb.log")])
time.sleep(3.0)
if fe_b.poll() is not None:
    fail(f"frontend B exited rc={fe_b.returncode} (reattach failed)")

ok = False
for attempt in range(3):
    os.write(master_b, b"echo VAR_IS_$SMOKE_VAR\r")
    if read_until(master_b, b"VAR_IS_persisted42", 8, log):
        ok = True
        break
    time.sleep(2)
if not ok:
    fail("SMOKE_VAR lost after reattach: not the same shell")
print("phase4: reattached from new terminal; same shell, state intact")

pods3 = pod_pids()
if set(pods1) != set(pods3):
    fail(f"pod changed across reattach: {pods1} -> {pods3}")
print(f"phase5: pod identity stable across the whole cycle ({pods3})")

cleanup()
log.close()
print("SMOKE PASS: frontend death -> park -> reattach, shell state preserved")
