#!/usr/bin/env python3
"""Live reliability test: `hexe mux attach .` (attach by current directory).

Reported: dot-attach "sometimes attaches, sometimes not". Root cause: it only
matched DETACHED sessions, so attaching immediately after a window died raced
the daemon's disconnect detection. Attached sessions are now listed (flagged)
and dot-attach steals them through the normal force-detach path.

Rounds alternate the two racy flows, with zero settle time:
  A) kill the frontend and IMMEDIATELY attach . from the session's directory
  B) attach . while the session is still attached elsewhere (steal)
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
WORKDIR = os.path.join(SCRATCH, f"dotproj-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
env.pop("HEXE_SESSION", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

def spawn_frontend(argv):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=WORKDIR, start_new_session=True)
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

log = open(os.path.join(SCRATCH, "smoke-dot.raw"), "wb")
print(f"instance={INST} workdir={WORKDIR}")

# Session with a state marker, rooted at WORKDIR.
fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "dotsess"])
time.sleep(2.5)
if fe.poll() is not None:
    fail("initial frontend didn't start")
os.write(master, b"export DOT_VAR=dot$((40+2))\r")
time.sleep(0.5)
os.write(master, b"echo VAR_$DOT_VAR\r")
if not read_until(master, b"VAR_dot42", 8, log):
    fail("marker setup failed")
print("setup: session 'dotsess' rooted in workdir, marker set")

ROUNDS = 6
for i in range(ROUNDS):
    mode = "kill-then-attach" if i % 2 == 0 else "steal-while-attached"
    if mode == "kill-then-attach":
        os.kill(fe.pid, signal.SIGKILL)
        fe.wait()
        os.close(master)
        # ZERO settle time: this is exactly the race users hit.
    new_fe, new_master = spawn_frontend([HEXE, "mux", "attach", "."])
    deadline = time.time() + 12
    attached = False
    while time.time() < deadline:
        if new_fe.poll() is not None:
            break
        os.write(new_master, b"echo VAR_$DOT_VAR\r")
        if read_until(new_master, b"VAR_dot42", 3, log):
            attached = True
            break
    if not attached:
        rc = new_fe.poll()
        fail(f"round {i + 1} ({mode}): attach . failed (rc={rc})")
    if mode == "steal-while-attached":
        # The stolen frontend must exit cleanly.
        deadline = time.time() + 8
        while time.time() < deadline and fe.poll() is None:
            time.sleep(0.2)
        if fe.poll() is None:
            fail(f"round {i + 1}: stolen frontend did not exit")
        os.close(master)
    print(f"round {i + 1} ({mode}): attach . OK, marker intact")
    fe, master = new_fe, new_master

# Phase 2: genuine ambiguity — a second session rooted in the same directory.
fe2, master2 = spawn_frontend([HEXE, "mux", "new", "-n", "dotsess2"])
time.sleep(2.5)
if fe2.poll() is not None:
    fail("second session didn't start")

# 2a: interactive picker must appear and accept a selection (tty stdin).
picker_fe, picker_master = spawn_frontend([HEXE, "mux", "attach", "."])
if not read_until(picker_master, b"Select session", 12, log):
    fail("ambiguous dot-attach did not show the picker")
os.write(picker_master, b"1\r")
time.sleep(2.5)
if picker_fe.poll() is not None:
    fail(f"picker selection failed rc={picker_fe.returncode}")
os.write(picker_master, b"echo PICKED_$((40+8))\r")
if not read_until(picker_master, b"PICKED_48", 10, log):
    fail("picked session is not interactive")
print("phase2a: ambiguity picker works under a tty")
os.kill(picker_fe.pid, signal.SIGKILL)
picker_fe.wait()
os.close(picker_master)
time.sleep(1.5)

# 2b: with NO tty on stdin, ambiguity must exit promptly — never hang.
t0 = time.time()
r = subprocess.run([HEXE, "mux", "attach", "."], stdin=subprocess.DEVNULL,
                   capture_output=True, text=True, env=env, cwd=WORKDIR, timeout=20)
elapsed = time.time() - t0
if elapsed > 15:
    fail(f"non-tty ambiguous attach took {elapsed:.1f}s (hang)")
print(f"phase2b: non-tty ambiguous attach exits promptly ({elapsed:.1f}s, rc={r.returncode})")

cleanup()
log.close()
print(f"SMOKE PASS: attach-by-dot reliable across {ROUNDS} kill/steal rounds + ambiguity")
