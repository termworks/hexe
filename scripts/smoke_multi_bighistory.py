#!/usr/bin/env python3
"""Live check: reattaching to MANY panes with big scrollback must not flap.

Regression target (PLAN.md Part I.2). Each pod replays up to REPLAY_TAIL_CAP
(1MB) on reattach, and SES fans every pane of a session into ONE per-client
queue capped at MUX_VT_QUEUE_MAX_BYTES (4MB). With enough panes holding enough
scrollback the queue overflowed, SES dropped the frontend's VT channel, the
frontend healed it with a full re-register + reattach -- and that reattach
replayed every backlog into the same queue again. The session then flapped
every RECONNECT_RETRY_MS forever.

smoke_bighistory.py covers ONE pane, which never exceeds the shared queue and
so never reproduced this.

The daemon must now apply backpressure (stop reading pods that feed a deep
queue) instead of dropping the channel, so a reattach settles after exactly
ONE reattach RPC.

Needs a ReleaseFast build: a debug build's VT parser cannot keep up with
several megabytes across six pods.
"""
import atexit
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"multibig-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
SES_LOG = os.path.join(WORKDIR, "ses.log")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
# A smoke run from inside a hexe pane inherits that pane's identity; the new
# frontend then hits the nested-mux confirmation and exits rc=0 with no output,
# which is indistinguishable from a product bug. Scrub the whole set.
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

# ESC + ctrl-<letter> is the legacy encoding of ctrl+alt+<letter>.
CTRL_ALT = {"h": b"\x1b\x08", "v": b"\x1b\x16"}

PANES = 6          # 6 x 1MB replay cap = 6MB against a 4MB shared queue
# `seq 1 N` averages ~6.9 bytes/line, so 200k lines is ~1.3MB -- comfortably
# over the pod's 1MB REPLAY_TAIL_CAP, which is what makes each pane contribute
# a full cap's worth to the shared queue.
LINES = 200000


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
    for pat in (f"pod daemon --instance {INST}", f"--instance {INST}"):
        for pid in pgrep(pat):
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
    log.close()
    sys.exit(1)


def spawn_frontend(argv):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=WORKDIR, start_new_session=True)
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
                chunk = os.read(fd, 262144)
            except OSError:
                return False
            if not chunk:
                return False
            buf += chunk
            log.write(chunk)
            if marker in buf:
                return True
            # Keep only a tail: these panes emit megabytes.
            if len(buf) > 1 << 20:
                buf = buf[-4096:]
    return False


def drain(fd, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 262144)
            except OSError:
                return
            if not chunk:
                return
            log.write(chunk)


def log_bytes():
    try:
        with open(SES_LOG, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return b""


def reattach_count():
    """Reattach RPCs served. One per attach is healthy; a climbing count is
    the flap loop."""
    return log_bytes().count(b"completeReattach: begin")


def vt_drop_count():
    """Times SES tore down a frontend's VT channel. The overflow-drop is what
    made the frontend re-register, which replayed the backlogs that overflowed
    the queue in the first place."""
    return log_bytes().count(b"removing MUX VT")


def queue_full_count():
    """Frames that hit the hard queue cap. Backpressure should keep this at 0;
    a few are survivable now (the frame is dropped, the channel is not), but
    the channel must never be torn down for them."""
    b = log_bytes()
    return b.count(b"failed to queue MUX VT frame") + b.count(b"mux VT queue full")


log = open(os.path.join(WORKDIR, "raw.log"), "wb")
print(f"instance={INST} workdir={WORKDIR}")

# Start the daemon ourselves so it logs; the frontend would otherwise autostart
# it without logging and the flap would be invisible.
subprocess.run([HEXE, "session", "daemon", "--instance", INST,
                "--log", "debug", "--logfile", SES_LOG],
               env=env, cwd=WORKDIR, check=False, timeout=30)
time.sleep(1.5)
if not os.path.exists(SES_LOG):
    fail("ses daemon did not start with logging")

# Phase 1: build a session of PANES panes, each with >1MB of scrollback.
fe_a, master_a = spawn_frontend([HEXE, "mux", "new", "-n", "multibig"])
time.sleep(3.0)
if fe_a.poll() is not None:
    fail("frontend A didn't start")

def wait_shell_ready(master, tag, timeout_s=40):
    """A freshly split pane spawns a pod + shell; typing before the shell
    exists silently drops the keystrokes. Poll until our echo comes back."""
    deadline = time.time() + timeout_s
    marker = f"READY_{tag}".encode()
    while time.time() < deadline:
        os.write(master, f"echo READY_{tag}\r".encode())
        if read_until(master, marker, 3):
            return True
    return False


for i in range(PANES):
    if i > 0:
        os.write(master_a, CTRL_ALT["h" if i % 2 else "v"])
        time.sleep(1.5)
        if not wait_shell_ready(master_a, f"P{i}"):
            fail(f"pane {i} shell never became ready")
    # Launch the generator but do NOT wait for it. Waiting would make the
    # frontend render ~1.3MB per pane before the next split, which dominates
    # runtime and starves later splits. The rings fill after the kill below.
    os.write(master_a, f"seq 1 {LINES}; echo GEN_{i}_DONE\r".encode())
    time.sleep(0.5)
    drain(master_a, 1.0)
    print(f"phase1: pane {i} generating", flush=True)

# Kill the frontend now and let the pods keep filling their backlog rings while
# DETACHED. That is both much faster (no rendering) and a truer reproduction:
# the real report is "detached panes accumulate scrollback, then I reattach".
os.kill(fe_a.pid, signal.SIGKILL)
fe_a.wait()
os.close(master_a)
print("phase1: frontend killed; letting detached pods fill their rings", flush=True)
time.sleep(25.0)
print(f"phase1: {PANES} panes hold big detached backlogs", flush=True)

# Phase 2: reattach. Exactly one reattach RPC may be served, and the VT
# channel must survive replaying all of those backlogs at once.

before_reattach = reattach_count()
before_drops = vt_drop_count()
before_full = queue_full_count()
t0 = time.time()
fe_b, master_b = spawn_frontend([HEXE, "mux", "attach", "multibig"])


def diag():
    return (f"reattach_rpcs={reattach_count() - before_reattach} "
            f"vt_channel_drops={vt_drop_count() - before_drops} "
            f"queue_full={queue_full_count() - before_full}")


if not read_until(master_b, b"GEN_", 90):
    fail(f"no replayed content visible after reattach — {diag()}")

# Let any flap loop express itself: RECONNECT_RETRY_MS is 2s, so 15s gives it
# ~7 chances to re-attach if the queue-overflow drop is still happening.
drain(master_b, 15.0)

served = reattach_count() - before_reattach
drops = vt_drop_count() - before_drops
elapsed = time.time() - t0
print(f"phase2: {diag()} in {elapsed:.1f}s")

if fe_b.poll() is not None:
    fail(f"frontend B died rc={fe_b.returncode} — {diag()}")

os.write(master_b, b"echo ALIVE_MB\r")
if not read_until(master_b, b"ALIVE_MB", 25):
    fail(f"pane unresponsive after reattach — {diag()}")

# The core invariant: replaying many big backlogs must never cost the frontend
# its VT channel. That drop is what the frontend heals with a re-register +
# reattach, which replays the same backlogs again — the flap.
if drops > 0:
    fail(f"SES dropped the frontend VT channel {drops}x during reattach — "
         f"backpressure is not holding; {diag()}")
if served > 1:
    fail(f"session flapped: {served} reattach RPCs for one attach — {diag()}")
if served == 0:
    fail("no reattach RPC observed — smoke did not exercise the reattach path")

cleanup()
log.close()
print(f"SMOKE PASS: {PANES} big-scrollback panes reattached once, no flap")
