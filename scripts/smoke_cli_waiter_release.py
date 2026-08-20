#!/usr/bin/env python3
"""Live check: a CLI blocked on a frontend answer is released if it dies.

SES parks the waiting CLI's fd in `pending_exit_intent_cli_fd` /
`pending_float_cli_fds` until the frontend replies. Neither
`processPendingCtlCloses` nor `purgeClientFdState` cleaned those (both handle
`pending_pop_requests`), so a frontend that crashed mid-request left the CLI
parked in `wire.readControlHeaderBlocking` — an unbounded `poll(-1)` — forever,
and leaked one daemon fd each time.

`hexe com exit-intent` is wired into the shell's exit hook, so this presents as
a shell that can never exit.
"""
import atexit
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
# A smoke run from inside a hexe pane inherits that pane's identity. `mux new`
# then takes the nested-mux path, cannot reach THIS instance's daemon to ask the
# question, and (before the exit-code fix) exited 0 with no session -- reported
# here as "frontend didn't start". Scrub the whole set, like every other smoke.
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

# Generous: the point is hang vs. no-hang, not latency.
RELEASE_TIMEOUT_S = 25


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", "--", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    for pid in pgrep(f"--instance {INST}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

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


def spawn_frontend(argv):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=SCRATCH, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, master


def read_until(fd, marker, timeout_s):
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
            if marker in buf:
                return True
            if len(buf) > (1 << 20):
                buf = buf[-4096:]
    return False


print(f"instance={INST}")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "cliwait"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"echo WARM\r")
if not read_until(master, b"WARM", 30):
    fail("pane never became responsive")

# Discover the pane uuid the CLI should target.
os.write(master, b"echo PANE=$HEXE_PANE_UUID\r")
if not read_until(master, b"PANE=", 15):
    fail("could not read HEXE_PANE_UUID from the pane")

# A float with --wait blocks the CLI until the frontend reports a result.
# Use a command that never exits, so only the frontend's death can release it.
waiter = subprocess.Popen(
    [HEXE, "mux", "float", "--title=hangprobe", "-c", "sleep 900"],
    env=env, cwd=SCRATCH, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    start_new_session=True,
)
procs.append(waiter)
time.sleep(4.0)

if waiter.poll() is not None:
    fail(f"CLI waiter exited before the frontend died (rc={waiter.returncode}) — "
         "it never actually blocked, so this run proves nothing")
print("setup: CLI is blocked waiting on the frontend", flush=True)

# Kill the frontend outright: it can never answer now.
os.kill(fe.pid, signal.SIGKILL)
fe.wait()
os.close(master)
print("setup: frontend SIGKILLed", flush=True)

t0 = time.time()
try:
    waiter.wait(timeout=RELEASE_TIMEOUT_S)
except subprocess.TimeoutExpired:
    fail(f"CLI waiter still blocked {RELEASE_TIMEOUT_S}s after the frontend died — "
         "SES never released it (this is the hung-shell bug)")

elapsed = time.time() - t0
print(f"CLI waiter released {elapsed:.1f}s after the frontend died (rc={waiter.returncode})")

cleanup()
print("SMOKE PASS: a dead frontend releases its blocked CLI waiters")
