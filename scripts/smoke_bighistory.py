#!/usr/bin/env python3
"""Live check: reattaching to a pane with a huge scrollback is fast.

Reported: reattaching to tens of thousands of lines replayed the whole 4MB
ring while repainting per chunk — the terminal looked stuck. The pod now
replays a bounded tail (or from the alt-screen enter for fullscreen apps) and
the frontend paints once at backlog_end.
"""
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
env.pop("HEXE_SESSION", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    for pid in pgrep(f"daemon --instance {INST}"):
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass

def fail(msg):
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)

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
            try: chunk = os.read(fd, 65536)
            except OSError: return False
            if not chunk: return False
            buf += chunk
            log.write(chunk)
            if marker in buf: return True
    return False

log = open(os.path.join(SCRATCH, "smoke-bighist.raw"), "wb")
print(f"instance={INST}")

# Phase 1: generate a large scrollback (10k numbered lines — sized for
# debug-build VT-parse throughput; the 1MB replay cap is unit-tested).
fe_a, master_a = spawn_frontend([HEXE, "mux", "new", "-n", "bighist"])
time.sleep(2.5)
if fe_a.poll() is not None: fail("frontend A didn't start")
os.write(master_a, b"seq 1 10000; echo HIST_$((40+6))_DONE\r")
if not read_until(master_a, b"HIST_46_DONE", 120, log):
    fail("history generation did not finish")
print("phase1: 10k lines of history generated")

# Phase 2: hard-kill and reattach; the new frontend must become responsive fast.
os.kill(fe_a.pid, signal.SIGKILL)
fe_a.wait()
os.close(master_a)
time.sleep(2.0)

t0 = time.time()
fe_b, master_b = spawn_frontend([HEXE, "mux", "attach", "bighist"])
if not read_until(master_b, b"HIST_46_DONE", 40, log):
    fail("replayed tail not visible after reattach")
os.write(master_b, b"echo ALIVE_$((40+7))\r")
if not read_until(master_b, b"ALIVE_47", 15, log):
    fail("pane unresponsive after big-history reattach")
elapsed = time.time() - t0
print(f"phase2: reattach responsive in {elapsed:.1f}s with tail visible")
if fe_b.poll() is not None:
    fail(f"frontend B died rc={fe_b.returncode}")
if elapsed > 45:
    fail(f"reattach took {elapsed:.1f}s — still too slow (debug-build budget)")

cleanup()
log.close()
print("SMOKE PASS: big-history reattach is fast and shows the latest content")
