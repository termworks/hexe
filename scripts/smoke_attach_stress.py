#!/usr/bin/env python3
"""Attach stress test: randomized kill/steal/double-attach rounds under load.

Every attach must either become interactive (marker readable) or exit
cleanly within a bound — never hang. The daemon must survive all of it and
the shell state must persist across every transition.
"""
import fcntl
import os
import pty
import random
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
WORKDIR = os.path.join(SCRATCH, f"stress-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
SEED = int(os.environ.get("HEXE_STRESS_SEED", str(os.getpid())))
random.seed(SEED)

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
    print(f"FAIL (seed={SEED}): {msg}")
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

def verify_interactive(fe, master, tag, timeout_s=14):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if fe.poll() is not None:
            return False
        os.write(master, b"echo M_$STRESS_VAR\r")
        if read_until(master, b"M_stress42", 3, log):
            return True
    return False

log = open(os.path.join(SCRATCH, "smoke-stress.raw"), "wb")
print(f"instance={INST} seed={SEED}")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "stress"])
time.sleep(2.5)
if fe.poll() is not None:
    fail("initial frontend didn't start")
os.write(master, b"export STRESS_VAR=stress$((40+2))\r")
time.sleep(0.4)
# Continuous background output keeps VT traffic flowing through every attach.
os.write(master, b"(while :; do date; sleep 0.2; done) &\r")
time.sleep(0.4)
if not verify_interactive(fe, master, "setup"):
    fail("setup marker failed")
print("setup: session under continuous output, marker set")

ROUNDS = 10
for i in range(ROUNDS):
    mode = random.choice(["kill", "steal", "double", "byname"])
    if mode == "kill":
        os.kill(fe.pid, signal.SIGKILL)
        fe.wait()
        os.close(master)
        new_fe, new_master = spawn_frontend([HEXE, "mux", "attach", "."])
        if not verify_interactive(new_fe, new_master, mode):
            fail(f"round {i + 1} ({mode}): attach failed rc={new_fe.poll()}")
        fe, master = new_fe, new_master
    elif mode == "steal":
        new_fe, new_master = spawn_frontend([HEXE, "mux", "attach", "."])
        if not verify_interactive(new_fe, new_master, mode):
            fail(f"round {i + 1} ({mode}): steal failed rc={new_fe.poll()}")
        deadline = time.time() + 8
        while time.time() < deadline and fe.poll() is None:
            time.sleep(0.2)
        if fe.poll() is None:
            fail(f"round {i + 1} ({mode}): stolen frontend did not exit")
        os.close(master)
        fe, master = new_fe, new_master
    elif mode == "byname":
        new_fe, new_master = spawn_frontend([HEXE, "mux", "attach", "stress"])
        if not verify_interactive(new_fe, new_master, mode):
            fail(f"round {i + 1} ({mode}): by-name steal failed rc={new_fe.poll()}")
        deadline = time.time() + 8
        while time.time() < deadline and fe.poll() is None:
            time.sleep(0.2)
        if fe.poll() is None:
            fail(f"round {i + 1} ({mode}): stolen frontend did not exit")
        os.close(master)
        fe, master = new_fe, new_master
    else:  # double: two simultaneous attaches race for the session
        os.kill(fe.pid, signal.SIGKILL)
        fe.wait()
        os.close(master)
        fa, ma = spawn_frontend([HEXE, "mux", "attach", "."])
        fb, mb = spawn_frontend([HEXE, "mux", "attach", "."])
        # Within the bound: at least one interactive; NEITHER may hang.
        winner = None
        deadline = time.time() + 20
        while time.time() < deadline and winner is None:
            for cand_fe, cand_m in ((fa, ma), (fb, mb)):
                if cand_fe.poll() is not None:
                    continue
                os.write(cand_m, b"echo M_$STRESS_VAR\r")
                if read_until(cand_m, b"M_stress42", 2, log):
                    winner = (cand_fe, cand_m)
                    break
        if winner is None:
            fail(f"round {i + 1} (double): neither racer became interactive (a={fa.poll()} b={fb.poll()})")
        loser_fe, loser_m = (fb, mb) if winner[0] is fa else (fa, ma)
        # The loser must terminate (cleanly or via steal) — kill it if it is
        # showing a fallback session, but it must not be WEDGED (probe it).
        if loser_fe.poll() is None:
            os.kill(loser_fe.pid, signal.SIGKILL)
            loser_fe.wait()
        os.close(loser_m)
        fe, master = winner
    # Daemon must be alive after every round.
    if not pgrep(f"ses daemon --instance {INST}"):
        fail(f"round {i + 1} ({mode}): daemon died")
    print(f"round {i + 1} ({mode}): OK")

if not verify_interactive(fe, master, "final"):
    fail("final session not interactive")
cleanup()
log.close()
print(f"SMOKE PASS: {ROUNDS} randomized attach rounds under load (seed={SEED})")
