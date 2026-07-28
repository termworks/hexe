#!/usr/bin/env python3
"""Live check: a peer that connects and goes silent must not freeze the daemon.

SES accepted a connection and then read its handshake preamble with BLOCKING
bounded reads -- 500ms for `[channel, version]`, and another 500ms for a
frontend VT session id or POD uuid. Any local process could therefore connect,
send nothing, and freeze every session for that long, repeatedly and for free.

Opens a batch of silent connections (some sending a single byte, so the daemon
is stuck mid-preamble rather than at zero bytes) and measures keystroke
round-trip latency in an unrelated live pane.
"""
import fcntl, os, pty, select, signal, socket, struct, subprocess, sys, termios, time

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
sockets = []

STALLED_PEERS = 8
# Old cost: 8 peers x 500ms preamble = ~4s of frozen daemon, and the follow-on
# read doubled it for VT/POD channels. A healthy round trip is well under 1s.
LATENCY_BUDGET_S = 3.0


def sock_dir():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime, "hexe", INST)


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def cleanup():
    for s in sockets:
        try:
            s.close()
        except OSError:
            pass
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
        r, _, _ = select.select([fd], [], [], 0.1)
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

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "stallprobe"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"echo WARM\r")
if not read_until(master, b"WARM", 30):
    fail("pane never became responsive")

ses_sock = os.path.join(sock_dir(), "ses.sock")
if not os.path.exists(ses_sock):
    fail(f"ses socket not found at {ses_sock}")

# Baseline latency with nothing misbehaving.
t0 = time.time()
os.write(master, b"echo BASE_OK\r")
if not read_until(master, b"BASE_OK", 30):
    fail("baseline round trip failed")
base = time.time() - t0
print(f"baseline round trip: {base:.2f}s", flush=True)

# Now connect and go silent. Half send one byte of the two-byte handshake so
# the daemon is stuck MID-preamble, which is the worse case.
for i in range(STALLED_PEERS):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(ses_sock)
    except OSError as e:
        fail(f"could not connect stalled peer {i}: {e}")
    if i % 2 == 0:
        s.send(b"\x02")  # channel byte only; version withheld
    sockets.append(s)
print(f"opened {STALLED_PEERS} silent connections", flush=True)

# The live pane must stay responsive while those peers hold their preambles.
t0 = time.time()
os.write(master, b"echo STALL_OK\r")
if not read_until(master, b"STALL_OK", 30):
    fail("pane went unresponsive while peers held their handshakes open")
stalled = time.time() - t0
print(f"round trip with {STALLED_PEERS} stalled peers: {stalled:.2f}s")

if fe.poll() is not None:
    fail(f"frontend died rc={fe.returncode}")

if stalled > LATENCY_BUDGET_S:
    fail(f"stalled peers froze the daemon: round trip {stalled:.2f}s "
         f"exceeds {LATENCY_BUDGET_S}s (baseline {base:.2f}s)")

cleanup()
print("SMOKE PASS: silent peers cannot stall other sessions")
