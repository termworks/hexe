#!/usr/bin/env python3
"""Live check: a peer that stops READING its CTL replies must not stall others.

Regression target (PLAN.md 1.5). SES wrote every control reply with
`wire.write*Timeout`, which polls until the socket accepts the bytes. Once a
client stops draining its CTL socket the kernel buffer fills, and each reply to
that client then costs the single-threaded daemon up to HANDLER_IO_TIMEOUT_MS
(500ms) -- during which every other session is frozen. Replies now go through a
bounded per-fd outbound queue: whatever the socket takes is written inline and
the remainder drains on the periodic tick, so nothing on the loop waits.

1.4/smoke_stalled_peer covers a peer that never finishes its HANDSHAKE. This is
the other half: a fully accepted peer that reads nothing back.

The peer shrinks its receive buffer and floods pings without ever reading the
pongs, so the reply path is guaranteed to hit a full socket.
"""
import atexit
import threading
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

# Wire constants (src/core/wire.zig).
HANDSHAKE_FRONTEND_CTL = 0x01
PROTOCOL_VERSION = 4
MSG_PING = 0x011B

# SES's socket send buffer is what has to fill: for AF_UNIX, queued bytes are
# charged to the SENDER, so shrinking our receive buffer does not constrain the
# daemon at all (an earlier version of this test did exactly that and passed
# against the unfixed daemon -- it never wedged anything). The only lever is
# volume: keep pinging until far more pong bytes are outstanding than a default
# ~208KB sndbuf can hold, while never reading a single one.
FLOOD_SECONDS = 8.0
PONG_BYTES = 10
# On the unfixed daemon each wedged peer costs ONE 500ms stall: the reply write
# times out, and replyOrClose then drops the connection. So the freeze scales
# with the number of peers, not with how long any one of them sulks -- 16 peers
# is ~8s of frozen daemon against a 1.5s budget. A healthy round trip is ~0.1s.
WEDGED_PEERS = 16
# Old cost: one 500ms stall per reply that hit the full buffer, so the daemon
# froze for many seconds. A healthy round trip is well under a second.
LATENCY_BUDGET_S = 1.5


def sock_dir():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime, "hexe", INST)


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", "--", pat], capture_output=True, text=True)
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


def ctl_header(msg_type, request_id=0, payload_len=0):
    """wire.ControlHeader: extern struct, align(1) fields, native endian."""
    return struct.pack("<HII", msg_type, request_id, payload_len)


print(f"instance={INST}")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "wedgeprobe"])
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

# Connect peers that complete the handshake and then never read a byte back.
for i in range(WEDGED_PEERS):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(ses_sock)
    except OSError as e:
        fail(f"could not connect wedged peer {i}: {e}")
    s.send(bytes([HANDSHAKE_FRONTEND_CTL, PROTOCOL_VERSION]))
    sockets.append(s)

# Prove the ping/pong path actually works on this channel before relying on it
# to generate reply pressure. Without this the whole test could pass simply
# because SES ignores unregistered pings and never replies at all.
probe = sockets[0]
probe.settimeout(5.0)
probe.send(ctl_header(MSG_PING))
try:
    pong = probe.recv(64)
except socket.timeout:
    fail("SES never answered a ping on the frontend CTL channel — "
         "this test cannot generate reply pressure")
if len(pong) < 10:
    fail(f"short pong: {pong!r}")
probe.settimeout(None)

# Flood pings and never read the replies, from BACKGROUND threads. The stall
# has to overlap the measurement: on the unfixed daemon each peer freezes the
# loop only at the moment its reply hits a full send buffer, and it is dropped
# straight afterwards. Measuring after the flood would miss the freeze entirely.
for s in sockets:
    s.setblocking(False)

sent_lock = threading.Lock()
sent_total = 0
stop_flood = threading.Event()


def flood(sock):
    """Push pings until told to stop. A broken pipe is expected on the unfixed
    daemon -- that IS the reply timeout dropping us -- so it ends this peer
    quietly rather than failing the test."""
    global sent_total
    batch = ctl_header(MSG_PING) * 64
    while not stop_flood.is_set():
        try:
            n = sock.send(batch)
        except BlockingIOError:
            time.sleep(0.005)
            continue
        except OSError:
            return
        with sent_lock:
            sent_total += n // 10


threads = [threading.Thread(target=flood, args=(s,), daemon=True) for s in sockets]
for t in threads:
    t.start()
# Let the peers get far enough ahead that SES is writing into full buffers by
# the time the pane round trip is measured.
time.sleep(1.0)
with sent_lock:
    print(f"flooding {WEDGED_PEERS} peers (~{sent_total * PONG_BYTES // 1024}KB of "
          f"pongs owed so far), reading none of the replies", flush=True)

# The live pane must stay responsive while SES has replies it cannot deliver.
t0 = time.time()
os.write(master, b"echo WEDGE_OK\r")
if not read_until(master, b"WEDGE_OK", 30):
    fail("pane went unresponsive while a peer refused to read its CTL replies")
wedged = time.time() - t0
stop_flood.set()
for t in threads:
    t.join(timeout=2)
with sent_lock:
    outstanding = sent_total * PONG_BYTES
print(f"round trip with {WEDGED_PEERS} wedged CTL readers: {wedged:.2f}s "
      f"(~{outstanding // 1024}KB of replies owed)")
if outstanding < 256 * 1024:
    fail(f"only ~{outstanding // 1024}KB of replies outstanding — not enough to "
         f"fill the daemon's send buffers, so this test proves nothing")

if fe.poll() is not None:
    fail(f"frontend died rc={fe.returncode}")

if wedged > LATENCY_BUDGET_S:
    fail(f"a wedged CTL reader froze the daemon: round trip {wedged:.2f}s "
         f"exceeds {LATENCY_BUDGET_S}s (baseline {base:.2f}s)")

# The daemon must also survive the peers going away with replies still queued.
for s in sockets:
    s.close()
sockets.clear()
time.sleep(1.0)
os.write(master, b"echo SURVIVE_OK\r")
if not read_until(master, b"SURVIVE_OK", 30):
    fail("daemon did not survive wedged peers disconnecting with queued replies")

cleanup()
print("SMOKE PASS: a peer that never reads its CTL replies cannot stall others")
