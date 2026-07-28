#!/usr/bin/env python3
"""Live check: a single read() carrying many keystrokes delivers all of them.

`handleFocusedInputLoop` used to `return` after forwarding ONE event, dropping
the rest of the batch (`inp[i + res.n ..]`). Every unbound key press takes that
path, so any read() carrying several keystrokes lost all but the first. The
64KB pumpStdin buffer makes multi-event reads routine under fast typing, key
repeat, and non-bracketed paste.

Writes each line as ONE os.write so the frontend sees it as one read.
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
env.pop("HEXE_SESSION", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


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
    log.close()
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
                return False, buf
            if not chunk:
                return False, buf
            buf += chunk
            log.write(chunk)
            if marker in buf:
                return True, buf
    return False, buf


log = open(os.path.join(SCRATCH, f"input-batch-{os.getpid()}.raw"), "wb")
print(f"instance={INST}")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "inbatch"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

# Warm up: prove the pane is live before testing batching.
os.write(master, b"echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")

# Each of these goes out as ONE write, so the frontend reads it as one batch.
# The marker only appears if EVERY byte of the batch survived.
cases = [
    ("ascii", "echo BATCH_ASCII_OK", b"BATCH_ASCII_OK"),
    # Non-Latin-1 codepoints do not map to a local BindKey, which is the
    # specific path the old early-return sat on.
    ("unicode", "echo BATCH_€中_OK", "BATCH_€中_OK".encode()),
    ("long", "echo " + "Z" * 200 + "_TAIL_OK", b"_TAIL_OK"),
]

for name, line, marker in cases:
    os.write(master, (line + "\r").encode())
    ok, buf = read_until(master, marker, 20)
    if not ok:
        tail = buf[-160:].decode("utf-8", "replace")
        fail(f"case {name!r}: batch was truncated — marker never echoed. tail={tail!r}")
    print(f"case {name}: full batch delivered", flush=True)

if fe.poll() is not None:
    fail(f"frontend died rc={fe.returncode}")

cleanup()
log.close()
print("SMOKE PASS: multi-keystroke reads are delivered in full")
