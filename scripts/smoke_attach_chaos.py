#!/usr/bin/env python3
"""Attach chaos test: everything that can interrupt an attach, randomized.

Round types:
  kill     - SIGKILL frontend, immediately attach .
  steal    - attach . while attached elsewhere
  double   - two simultaneous attach . racers
  abort    - spawn attach ., SIGKILL it after a random 0-800ms (mid-flight
             abort: the lock-leak / junk-record generator), then attach for real
  daemon   - SIGKILL the ses daemon mid-session; auto-reconnect must restore
  clikill  - `hexe terminal kill <session>` then recreate the session

Invariants after every round: exactly one interactive frontend holding the
marker, the daemon alive, and no round may hang past its budget.
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
WORKDIR = os.path.join(SCRATCH, f"chaos-{os.getpid()}")
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

def verify_interactive(fe, master, timeout_s=16):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if fe.poll() is not None:
            return False
        os.write(master, b"echo M_$CHAOS_VAR\r")
        if read_until(master, b"M_chaos42", 3, log):
            return True
    return False

def set_marker(master):
    os.write(master, b"export CHAOS_VAR=chaos$((40+2))\r")
    time.sleep(0.4)

def fresh_session():
    fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "chaos"])
    time.sleep(2.5)
    if fe.poll() is not None:
        fail("session frontend didn't start")
    set_marker(master)
    if not verify_interactive(fe, master):
        fail("fresh session marker failed")
    return fe, master

log = open(os.path.join(SCRATCH, "smoke-chaos.raw"), "wb")
print(f"instance={INST} seed={SEED}")
fe, master = fresh_session()
print("setup: chaos session ready")

ROUNDS = int(os.environ.get("HEXE_STRESS_ROUNDS", "10"))
for i in range(ROUNDS):
    mode = random.choice(["kill", "steal", "double", "abort", "daemon", "clikill"])
    if mode == "kill":
        os.kill(fe.pid, signal.SIGKILL)
        fe.wait()
        os.close(master)
        fe, master = spawn_frontend([HEXE, "mux", "attach", "."])
        if not verify_interactive(fe, master):
            fail(f"round {i + 1} ({mode}): attach failed rc={fe.poll()}")
    elif mode == "steal":
        nfe, nmaster = spawn_frontend([HEXE, "mux", "attach", "."])
        if not verify_interactive(nfe, nmaster):
            fail(f"round {i + 1} ({mode}): steal failed rc={nfe.poll()}")
        deadline = time.time() + 8
        while time.time() < deadline and fe.poll() is None:
            time.sleep(0.2)
        if fe.poll() is None:
            fail(f"round {i + 1} ({mode}): stolen frontend did not exit")
        os.close(master)
        fe, master = nfe, nmaster
    elif mode == "double":
        os.kill(fe.pid, signal.SIGKILL)
        fe.wait()
        os.close(master)
        fa, ma = spawn_frontend([HEXE, "mux", "attach", "."])
        fb, mb = spawn_frontend([HEXE, "mux", "attach", "."])
        winner = None
        deadline = time.time() + 25
        while time.time() < deadline and winner is None:
            for cfe, cm in ((fa, ma), (fb, mb)):
                if cfe.poll() is not None:
                    continue
                os.write(cm, b"echo M_$CHAOS_VAR\r")
                if read_until(cm, b"M_chaos42", 2, log):
                    winner = (cfe, cm)
                    break
        if winner is None:
            fail(f"round {i + 1} (double): no winner (a={fa.poll()} b={fb.poll()})")
        loser_fe, loser_m = (fb, mb) if winner[0] is fa else (fa, ma)
        if loser_fe.poll() is None:
            os.kill(loser_fe.pid, signal.SIGKILL)
            loser_fe.wait()
        os.close(loser_m)
        fe, master = winner
    elif mode == "abort":
        os.kill(fe.pid, signal.SIGKILL)
        fe.wait()
        os.close(master)
        # Mid-flight abort: the attach dies at a random point in its flow.
        victim, vm = spawn_frontend([HEXE, "mux", "attach", "."])
        time.sleep(random.uniform(0.0, 0.8))
        if victim.poll() is None:
            os.kill(victim.pid, signal.SIGKILL)
            victim.wait()
        os.close(vm)
        # The real attach must still work promptly.
        fe, master = spawn_frontend([HEXE, "mux", "attach", "."])
        if not verify_interactive(fe, master):
            fail(f"round {i + 1} ({mode}): attach after abort failed rc={fe.poll()}")
    elif mode == "daemon":
        daemons = pgrep(f"ses daemon --instance {INST}")
        for pid in daemons:
            os.kill(pid, signal.SIGKILL)
        # Auto-reconnect must restore the same session.
        if not verify_interactive(fe, master, timeout_s=25):
            fail(f"round {i + 1} ({mode}): auto-reconnect failed rc={fe.poll()}")
    else:  # clikill
        r = subprocess.run([HEXE, "terminal", "kill", "chaos"], capture_output=True,
                           text=True, env=env, timeout=15)
        deadline = time.time() + 10
        while time.time() < deadline and fe.poll() is None:
            time.sleep(0.2)
        if fe.poll() is None:
            fail(f"round {i + 1} ({mode}): frontend survived session kill (kill said: {(r.stdout + r.stderr).strip()!r})")
        os.close(master)
        fe, master = fresh_session()
    if not pgrep(f"ses daemon --instance {INST}"):
        # Grace: a just-restarted daemon may still be in its exec window.
        time.sleep(3)
        if not pgrep(f"ses daemon --instance {INST}"):
            fail(f"round {i + 1} ({mode}): daemon died and stayed dead")
    print(f"round {i + 1} ({mode}): OK")

if not verify_interactive(fe, master):
    fail("final session not interactive")

# Leak check: chaos must not accumulate junk session records.
import json
state_file = os.path.join(env["XDG_STATE_HOME"], "hexe", INST, "ses_state.json")
try:
    state = json.load(open(state_file))
    detached = state.get("detached_sessions", [])
    if len(detached) > 2:
        fail(f"junk session records accumulated: {len(detached)} detached records after chaos")
    print(f"leak check: {len(detached)} detached records, {len(state.get('panes', []))} panes")
except FileNotFoundError:
    pass
cleanup()
log.close()
print(f"SMOKE PASS: {ROUNDS} chaos rounds survived (seed={SEED})")
