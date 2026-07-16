#!/usr/bin/env python3
"""Live smoke test: reattach to a session running a fullscreen (alt-screen) app.

Reported crash: leave vim/btop running, detach, reattach -> frontend crashes.
Runs `vi` in the pane, kills the frontend, reattaches from a new terminal and
verifies the new frontend survives and still renders the alt-screen app.
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

def spawn_frontend(argv, logname, rows=40, cols=120):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    p = subprocess.Popen(argv + ["--log", "debug", "-L", os.path.join(SCRATCH, logname)],
                         stdin=slave, stdout=slave, stderr=slave,
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

def drain(fd, seconds, log):
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            log.write(chunk)

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

log = open(os.path.join(SCRATCH, "smoke3-fe.raw"), "wb")
print(f"instance={INST}")

# Phase 1: frontend A, start a fullscreen app (vi enters the alternate screen).
fe_a, master_a = spawn_frontend([HEXE, "mux", "new", "-n", "smoke3"], "smoke3-fea.log")
time.sleep(2.5)
if fe_a.poll() is not None:
    fail(f"frontend A exited early rc={fe_a.returncode}")
os.write(master_a, b"vim /tmp/hexe-smoke-vi-target\r")
time.sleep(2.0)
drain(master_a, 1.0, log)
if fe_a.poll() is not None:
    fail("frontend A died after starting vi")
print("phase1: vi running in the pane (alt screen)")

# Phase 2: clean detach via keybind (ctrl+alt+d -> ESC + 0x04 in legacy
# encoding) while vim is fullscreen — the user's actual flow.
os.write(master_a, b"\x1b\x04")
deadline = time.time() + 8
while time.time() < deadline and fe_a.poll() is None:
    drain(master_a, 0.3, log)
if fe_a.poll() is None:
    os.kill(fe_a.pid, signal.SIGKILL)
    fe_a.wait()
    print("phase2: WARN keybind detach did not exit frontend; fell back to SIGKILL")
else:
    print(f"phase2: clean detach, frontend A exited rc={fe_a.returncode}")
os.close(master_a)
time.sleep(2.0)

# Phase 3: reattach; the frontend must survive and render vi's screen.
fe_b, master_b = spawn_frontend([HEXE, "mux", "attach", "smoke3"], "smoke3-feb.log", rows=28, cols=90)
time.sleep(4.0)
if fe_b.poll() is not None:
    fail(f"frontend B crashed/exited rc={fe_b.returncode} after reattach with fullscreen app")

# vi's alt screen shows tildes on empty lines; typing i + text + ESC must work.
os.write(master_b, b"ihello-from-reattach")
time.sleep(0.7)
os.write(master_b, b"\x1b")
if not read_until(master_b, b"hello-from-reattach", 8, log):
    fail("vi did not respond after reattach (pane dead)")
if fe_b.poll() is not None:
    fail(f"frontend B crashed rc={fe_b.returncode} while using vi after reattach")
print("phase3: reattached; vi alive and editable")

# Phase 4: quit vi cleanly; the shell prompt must come back.
def pane_tree(tag):
    pods = pgrep(f"pod daemon --instance {INST}")
    for pp in pods:
        r = subprocess.run(["ps", "--ppid", str(pp), "-o", "pid,stat,comm"], capture_output=True, text=True)
        for line in r.stdout.splitlines()[1:]:
            shell_pid = line.split()[0]
            r2 = subprocess.run(["ps", "--ppid", shell_pid, "-o", "pid,stat,comm"], capture_output=True, text=True)
            print(f"{tag}: pod={pp} shell=[{line.strip()}] children={[l.strip() for l in r2.stdout.splitlines()[1:]]}")

pane_tree("pre-quit")
os.write(master_b, b"\x1b")  # ensure normal mode (belt and braces)
time.sleep(0.5)
os.write(master_b, b"ZQ")  # normal-mode force quit (no ex-command quirks)
time.sleep(1.5)
pane_tree("post-quit")
os.write(master_b, b"echo BACK_$((40+4))\r")
if not read_until(master_b, b"BACK_44", 8, log):
    fail("shell did not return after quitting vi")
if fe_b.poll() is not None:
    fail(f"frontend B crashed rc={fe_b.returncode} after quitting vi")
print("phase4: quit vi, shell prompt back, frontend stable")

cleanup()
log.close()
print("SMOKE PASS: fullscreen app survives detach/reattach without crashing hexe")
