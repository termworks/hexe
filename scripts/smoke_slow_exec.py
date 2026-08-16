#!/usr/bin/env python3
"""Live check: a HANGING `hexe.exec` must not freeze the terminal.

`hexe.exec()` used to run std.process.Child.run right on the render path. A
command that did not return stalled the frame — and with it the whole UI: no
repaint, no keystrokes.

The statusbar segment that used to host this test is gone (the bar is painted
externally now), but `hexe.exec` is still reachable from Lua — a keybind `when`
callback runs it on every matching keypress. That is where the invariant lives
today, so that is where this injects: a bind whose `when` calls a hexe.exec
that NEVER RETURNS (`sleep 100000`, with a 60s timeout so even the timeout(1)
backstop cannot save it).

It also asserts the command was actually REACHED (the fake command logs each
invocation): without that, a run where the callback never fired would "pass"
while proving nothing.
"""
import atexit
import fcntl
import os
import pty
import re
import select
import shutil
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
WORKDIR = os.path.join(SCRATCH, f"slowseg-{os.getpid()}")
CFGDIR = os.path.join(SCRATCH, f"cfgslow-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)

REAL_CFG = os.path.expanduser("~/.config/hexe")
if not os.path.isdir(REAL_CFG):
    print("SKIP: no ~/.config/hexe to model the session on")
    raise SystemExit(0)
shutil.copytree(REAL_CFG, os.path.join(CFGDIR, "hexe"), dirs_exist_ok=True)

HANGLOG = os.path.join(WORKDIR, "hang-calls.log")

# Floats: swap to /bin/sh so the test needs no external tools.
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

# The hostile bind: its `when` logs that it ran, then hangs forever.
# timeout = 60000 means even timeout(1) will not rescue the frame for a minute.
# The action is irrelevant -- evaluating the condition is what must not block.
HANG_BIND = '''    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.y }, hexe.action.tab.next(), {
      when = function(_)
        local r = hexe.exec("echo call >> %s; sleep 100000", { timeout = 60000, cache = 500 })
        return r ~= nil and r.ok == true
      end,
    }),
''' % HANGLOG

anchor = "  keys = concat(layout_keys, {\n"
if anchor not in init:
    print("SKIP: could not find the keys list to inject into")
    raise SystemExit(0)
init = init.replace(anchor, anchor + HANG_BIND, 1)
open(init_path, "w").write(init)

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "XDG_CONFIG_HOME": CFGDIR, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_TRUST_ALL_PROJECTS": "1"})
# A smoke run from inside a hexe pane inherits that pane's identity; the new
# frontend then hits the nested-mux confirmation and exits rc=0 with no output,
# which is indistinguishable from a product bug. Scrub the whole set.
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", "--", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

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
    subprocess.run(["pkill", "-f", f"echo call >> {HANGLOG}"], capture_output=True)

# Run teardown even when this script raises or is killed by a timeout.
# Without this, cleanup() ran only on the success path and inside fail(),
# so any unhandled exception left the daemon, its pods and their shells
# alive. Hundreds of runs accumulate enough of them to slow the machine
# down and make later smokes fail in ways that look like product bugs.
atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))

def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)

def safe_write(m, data, what, timeout_s=15):
    off, last = 0, time.time()
    while off < len(data):
        r, w, _ = select.select([m], [m], [], 0.5)
        if m in r:
            try:
                log.write(os.read(m, 65536))
            except OSError:
                pass
        if m in w:
            n = os.write(m, data[off:])
            if n:
                off += n
                last = time.time()
        if time.time() - last > timeout_s:
            fail(f"UI FROZEN: the terminal stopped reading input while a segment hangs ({what})")

def read_until(m, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([m], [], [], 0.2)
        if m in r:
            try:
                c = os.read(m, 65536)
            except OSError:
                return False
            if not c:
                return False
            buf += c
            log.write(c)
            if marker in buf:
                return True
    return False

log = open(os.path.join(SCRATCH, "smoke-slowexec.raw"), "wb")
print(f"instance={INST} (keybind `when` whose hexe.exec never returns)")

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "slowseg"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WORKDIR, start_new_session=True)
os.close(slave)
procs.append(fe)
time.sleep(3.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode} (a hanging segment must not kill it)")

# 1. The shell must be usable even though a statusbar segment never returns.
t0 = time.time()
# ctrl+alt+y evaluates the hanging `when`. The bind does not match (the exec is
# still pending), so the key falls through to the shell -- ^U clears whatever it
# left on the line so the echo below is what actually runs.
safe_write(master, b"\x1b\x19", "hangbind keypress")
safe_write(master, b"\x15", "clear line")
safe_write(master, b"echo SEG_$((40+9))_OK\r", "shell echo")
if not read_until(master, b"SEG_49_OK", 15):
    fail("shell unresponsive while a segment hangs — the UI is frozen")
latency = time.time() - t0
print(f"phase1: shell responded in {latency:.1f}s with a never-returning exec")
if latency > 8:
    fail(f"shell took {latency:.1f}s — the hanging exec is stalling the loop")

# 2. Keep interacting; splits and repeated commands must all stay snappy.
safe_write(master, b"\x1b\x08", "split")  # ctrl+alt+h
time.sleep(2.0)
worst = 0.0
for i in range(6):
    t0 = time.time()
    safe_write(master, b"\x1b\x19", f"hangbind {i}")
    safe_write(master, b"\x15", f"clear {i}")
    safe_write(master, f"echo LOOP_{i}\r".encode(), f"loop {i}")
    if not read_until(master, f"LOOP_{i}".encode(), 12):
        fail(f"terminal unresponsive on iteration {i} — the hang leaked into the loop")
    dt = time.time() - t0
    worst = max(worst, dt)
    if dt > 8:
        fail(f"iteration {i} took {dt:.1f}s — frames are stalling on the exec")
print(f"phase2: 6 interactive round-trips stayed responsive (worst {worst:.1f}s)")

# 3. The test is only meaningful if the hanging command was actually REACHED.
calls = open(HANGLOG).read().splitlines() if os.path.exists(HANGLOG) else []
print(f"phase3: the hanging exec ran {len(calls)} time(s)")
if not calls:
    fail("the `when` callback never ran its command — this test proved nothing")

# 4. One in flight at a time, not one per rendered frame.
hung = len(pgrep(f"echo call >> {HANGLOG}"))
print(f"phase4: {hung} hung command(s) in flight (must not grow per frame)")
if hung > 8:
    fail(f"{hung} hung commands — the cache spawns one per render instead of one at a time")

if fe.poll() is not None:
    fail(f"frontend died rc={fe.returncode}")

cleanup()
log.close()
print("SMOKE PASS: a never-returning hexe.exec no longer freezes the terminal")
