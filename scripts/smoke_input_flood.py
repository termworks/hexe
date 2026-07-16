#!/usr/bin/env python3
"""Input must survive heavy output: typing works while a pane floods.

The failure this pins: a pane producing a torrent of output could leave the
terminal painting that output but DEAF to the keyboard — permanently, until the
flood stopped. The io_uring stdin watcher's poll re-arm was being lost under the
output load, and nothing re-armed it. A real terminal must always accept keys.

Minimal and deterministic: one pane, start an unbounded flood, then repeatedly
prove that a typed command actually executes (it writes a file we poll for, so
the check does not depend on the flood-scrolled screen). No SIGSTOP, no daemon
games — just sustained output vs. input.

Needs a ReleaseFast build (Debug VT parsing cannot keep up with the flood).
"""
import fcntl
import os
import pty
import re
import select
import shutil
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
WORKDIR = os.path.join(SCRATCH, f"inflood-{os.getpid()}")
CFGDIR = os.path.join(SCRATCH, f"cfgif-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)

REAL_CFG = os.path.expanduser("~/.config/hexe")
if not os.path.isdir(REAL_CFG):
    print("SKIP: no ~/.config/hexe to model the session on")
    raise SystemExit(0)
shutil.copytree(REAL_CFG, os.path.join(CFGDIR, "hexe"), dirs_exist_ok=True)
lay_path = os.path.join(CFGDIR, "hexe", "layout.lua")
if os.path.exists(lay_path):
    lay = open(lay_path).read()
    out, i = [], 0
    while True:
        j = lay.find("hexe.float(", i)
        if j < 0:
            out.append(lay[i:])
            break
        k = lay.find("hexe.float(", j + 1)
        if k < 0:
            k = len(lay)
        out.append(lay[i:j])
        out.append(re.sub(r'command = "[^"]*"', 'command = "/bin/sh"', lay[j:k]))
        i = k
    open(lay_path, "w").write("".join(out))
init_path = os.path.join(CFGDIR, "hexe", "init.lua")
init = open(init_path).read()
init = init.replace('os.getenv("HOME") .. "/.config/hexe/layout.lua"', repr(lay_path).replace("'", '"'))
for a, b in (("exit = true", "exit = false"), ("detach = true", "detach = false"),
             ("disown = true", "disown = false"), ("close = true", "close = false")):
    init = init.replace(a, b)
open(init_path, "w").write(init)

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "XDG_CONFIG_HOME": CFGDIR, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_TRUST_ALL_PROJECTS": "1"})
env.pop("HEXE_SESSION", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []
log = open(os.path.join(SCRATCH, "smoke-inflood.raw"), "wb")

def pgrep(p):
    r = subprocess.run(["pgrep", "-f", p], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

def cleanup():
    subprocess.run(["pkill", "-f", "while :; do seq"], capture_output=True)
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    for pid in pgrep(f"ses daemon --instance {INST}"):
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass

def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    log.close()
    sys.exit(1)

def drain(fd, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if fd in r:
            try:
                log.write(os.read(fd, 262144))
            except OSError:
                return

def safe_write(m, data, what="input", timeout_s=20):
    off, last = 0, time.time()
    while off < len(data):
        r, w, _ = select.select([m], [m], [], 0.5)
        if m in r:
            try:
                log.write(os.read(m, 262144))
            except OSError:
                pass
        if m in w:
            n = os.write(m, data[off:])
            if n:
                off += n
                last = time.time()
        if time.time() - last > timeout_s:
            fail(f"UI FROZEN: frontend stopped reading its stdin ({what})")

def shell_ready(m, tag, timeout_s=30):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        safe_write(m, f"echo RDY_{tag}\r".encode(), "ready probe")
        got = read_marker(m, f"RDY_{tag}".encode(), 4)
        if got:
            return True
    return False

def read_marker(m, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([m], [], [], 0.2)
        if m in r:
            try:
                c = os.read(m, 262144)
            except OSError:
                return False
            buf += c
            log.write(c)
            if marker in buf:
                return True
    return False

def executes(m, tag, timeout_s=20):
    """Prove a typed command actually RAN, via the filesystem (flood-proof)."""
    probe = os.path.join(WORKDIR, f"p_{tag}")
    try:
        os.unlink(probe)
    except FileNotFoundError:
        pass
    safe_write(m, f"echo {tag} > {probe}\r".encode(), f"probe {tag}")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        drain(m, 0.2)
        if os.path.exists(probe) and os.path.getsize(probe) > 0:
            return True
    return False

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "inflood"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WORKDIR, start_new_session=True)
os.close(slave)
procs.append(fe)
time.sleep(3.5)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")
if not shell_ready(master, "INIT"):
    fail("shell never became ready")

print(f"instance={INST}")
# Baseline: input works with no flood.
if not executes(master, "BASE"):
    fail("input did not work even without a flood")
print("baseline: typed command executes")

# Start an unbounded flood in this same pane (backgrounded).
safe_write(master, b"while :; do seq 1 500; done &\r", "start flood")
time.sleep(1.5)
drain(master, 1.0)
print("flood started")

# Now hammer input WHILE the pane floods. Every one must execute, promptly.
worst = 0.0
for i in range(12):
    t0 = time.time()
    if not executes(master, f"FLOOD_{i}", timeout_s=20):
        fail(f"typed command #{i} never executed while the pane floods "
             f"(input starved by output)")
    dt = time.time() - t0
    worst = max(worst, dt)
    if dt > 10:
        fail(f"command #{i} took {dt:.1f}s — input is being starved by output")
print(f"under flood: 12/12 typed commands executed (worst {worst:.1f}s)")

# Sustain the flood a while, then check input is STILL alive (not just at first).
drain(master, 6.0)
if not executes(master, "SUSTAINED", timeout_s=20):
    fail("input died after sustained flooding")
print("after 6s of sustained flood: input still alive")

if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

cleanup()
log.close()
print("SMOKE PASS: heavy pane output never starves keyboard input")
