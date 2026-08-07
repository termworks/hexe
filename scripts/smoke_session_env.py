#!/usr/bin/env python3
"""Live test: a session's panes inherit THAT session's environment.

The ses daemon outlives every session, so panes used to spawn with whatever
shell first started the daemon -- a foreign PATH, a foreign direnv, and a PWD
naming a directory the pane was never in. `_b` in one project built another.

Round 1 starts the daemon from dir A (marker HEXE_SMOKE_MARK=alpha).
Round 2 opens a second session from dir B (marker=bravo) against that SAME
daemon. Round 2's pane must see bravo and B, not alpha and A.
"""
import atexit
import fcntl
import os
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
import time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.environ.get("HEXE_BIN", os.path.join(REPO, "zig-out/bin/hexe"))
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
INST = f"smk{os.getpid()}"
DIR_A = os.path.join(SCRATCH, f"envproj-a-{os.getpid()}")
DIR_B = os.path.join(SCRATCH, f"envproj-b-{os.getpid()}")
for d in (SCRATCH, DIR_A, DIR_B):
    os.makedirs(d, exist_ok=True)

procs = []


def base_env(mark):
    env = os.environ.copy()
    # Running this suite from inside a hexe pane otherwise hands the frontend
    # its parent's pane identity, and startup takes a different path.
    for key in list(env):
        if key.startswith("HEXE_"):
            del env[key]
    env.update({
        "HEXE_INSTANCE": INST,
        "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
        "TERM": "xterm-256color",
        "SHELL": "/bin/sh",
        "HEXE_SMOKE_MARK": mark,
    })
    os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
    return env


def cleanup():
    for p in procs:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception:
            pass
    subprocess.run(["pkill", "-9", "-f", f"--instance {INST}"], capture_output=True)


atexit.register(cleanup)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def spawn_session(name, workdir, mark):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "terminal", "new", "--name", name],
                         stdin=slave, stdout=slave, stderr=slave,
                         env=base_env(mark), cwd=workdir, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, master


def pane_shell_pids():
    """pid -> environ dict for every live pod's shell child in this instance."""
    out = {}
    r = subprocess.run(["pgrep", "-f", f"pod daemon .*--instance {INST}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        r = subprocess.run(["pgrep", "-f", "hexe pod daemon"], capture_output=True, text=True)
    for pod in [int(x) for x in r.stdout.split()]:
        try:
            kids = open(f"/proc/{pod}/task/{pod}/children").read().split()
        except OSError:
            continue
        for kid in kids:
            try:
                raw = open(f"/proc/{kid}/environ", "rb").read()
                cwd = os.readlink(f"/proc/{kid}/cwd")
            except OSError:
                continue
            envd = {}
            for item in raw.split(b"\0"):
                if b"=" in item:
                    k, _, v = item.partition(b"=")
                    envd[k.decode(errors="replace")] = v.decode(errors="replace")
            if envd.get("HEXE_INSTANCE") != INST:
                continue
            out[int(kid)] = (envd, cwd)
    return out


def wait_for_pane(known, timeout_s=15):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        panes = pane_shell_pids()
        fresh = {k: v for k, v in panes.items() if k not in known}
        if fresh:
            return fresh
        time.sleep(0.3)
    return {}


print(f"instance={INST}")
print(f"A={DIR_A} (marker alpha)")
print(f"B={DIR_B} (marker bravo)")

# Round 1: first session starts the daemon, freezing its environment.
_, m1 = spawn_session("alpha", DIR_A, "alpha")
panes1 = wait_for_pane(set())
if not panes1:
    fail("session alpha produced no pane")
pid1, (env1, cwd1) = next(iter(panes1.items()))
print(f"\nsession alpha pane pid={pid1}")
print(f"  HEXE_SMOKE_MARK={env1.get('HEXE_SMOKE_MARK')!r} PWD={env1.get('PWD')!r} cwd={cwd1}")

if env1.get("HEXE_SMOKE_MARK") != "alpha":
    fail(f"alpha pane marker is {env1.get('HEXE_SMOKE_MARK')!r}, expected 'alpha'")
if env1.get("PWD") != cwd1:
    fail(f"alpha pane PWD={env1.get('PWD')!r} does not match real cwd {cwd1!r}")

# Round 2: second session against the SAME (already running) daemon.
_, m2 = spawn_session("bravo", DIR_B, "bravo")
panes2 = wait_for_pane(set(panes1))
if not panes2:
    fail("session bravo produced no pane")
pid2, (env2, cwd2) = next(iter(panes2.items()))
print(f"\nsession bravo pane pid={pid2}")
print(f"  HEXE_SMOKE_MARK={env2.get('HEXE_SMOKE_MARK')!r} PWD={env2.get('PWD')!r} cwd={cwd2}")

if env2.get("HEXE_SMOKE_MARK") != "bravo":
    fail("bravo pane inherited marker "
         f"{env2.get('HEXE_SMOKE_MARK')!r} -- session env leaked from the daemon")
if env2.get("PWD") != cwd2:
    fail(f"bravo pane PWD={env2.get('PWD')!r} does not match real cwd {cwd2!r}")
if os.path.realpath(cwd2) != os.path.realpath(DIR_B):
    fail(f"bravo pane cwd {cwd2!r} is not {DIR_B!r}")
if "OLDPWD" in env2:
    fail(f"bravo pane carries a stale OLDPWD={env2['OLDPWD']!r}")

print("\nPASS: each session's panes carry that session's environment and a correct PWD")
