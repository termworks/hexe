#!/usr/bin/env python3
"""Live check: silent peers on a POD socket must not wedge the user's shell.

Regression target (PLAN.md C-4). The pod's accept callback drains the whole
listen backlog in a loop and handled each connection synchronously with bounded
BLOCKING reads: 2s for the handshake, and for an SHP connection three more
(header + struct + trail) for ~6s total. Any local process could therefore
connect to a pod socket, send nothing, and freeze that pod -- and the shell
running inside it -- once per queued connection.

This is the pod-side twin of smoke_stalled_peer.py, which covers SES.

The peers are staged at the three points that used to block: before the
handshake, mid-handshake, and mid-SHP-request (past the handshake, so the
expensive 3-read path is the one left hanging).
"""
import atexit
import fcntl, glob, os, pty, select, signal, socket, struct, subprocess, sys, termios, time

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
POD_HANDSHAKE_SHP_CTL = 0x02
PROTOCOL_VERSION = 4

# The listen backlog is 16; fill enough of it to make the old serial cost
# obvious. Silent handshakes cost 2s each and stalled SHP requests up to ~6s,
# so this is many seconds of frozen shell before the fix and none after.
STALLED_PEERS = 12
LATENCY_BUDGET_S = 3.0


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


print(f"instance={INST}")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "podstall"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"echo WARM\r")
if not read_until(master, b"WARM", 30):
    fail("pane never became responsive")

runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
pod_socks = glob.glob(os.path.join(runtime, "hexe", INST, "pod-*.sock"))
if not pod_socks:
    fail(f"no pod socket found under {os.path.join(runtime, 'hexe', INST)}")
pod_sock = pod_socks[0]
print(f"pod socket: {os.path.basename(pod_sock)}", flush=True)

# Baseline latency with nothing misbehaving.
t0 = time.time()
os.write(master, b"echo BASE_OK\r")
if not read_until(master, b"BASE_OK", 30):
    fail("baseline round trip failed")
base = time.time() - t0
print(f"baseline round trip: {base:.2f}s", flush=True)

# Stage peers at each point that used to block.
staged = {"silent": 0, "half_handshake": 0, "mid_request": 0}
for i in range(STALLED_PEERS):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(pod_sock)
    except OSError as e:
        fail(f"could not connect stalled peer {i} to the pod: {e}")
    mode = i % 3
    if mode == 0:
        staged["silent"] += 1                      # nothing at all
    elif mode == 1:
        s.send(bytes([POD_HANDSHAKE_SHP_CTL]))     # channel byte, version withheld
        staged["half_handshake"] += 1
    else:
        # Past the handshake, then stop partway through the SHP control header:
        # this is the path that used to cost three bounded reads (~6s).
        s.send(bytes([POD_HANDSHAKE_SHP_CTL, PROTOCOL_VERSION]) + b"\x00\x01")
        staged["mid_request"] += 1
    sockets.append(s)
print(f"staged {STALLED_PEERS} stalled pod peers: {staged}", flush=True)

# The shell in that very pod must stay responsive.
t0 = time.time()
os.write(master, b"echo STALL_OK\r")
if not read_until(master, b"STALL_OK", 30):
    fail("the pane's shell went unresponsive while peers held the pod's accept path")
stalled = time.time() - t0
print(f"round trip with {STALLED_PEERS} stalled pod peers: {stalled:.2f}s")

if fe.poll() is not None:
    fail(f"frontend died rc={fe.returncode}")

if stalled > LATENCY_BUDGET_S:
    fail(f"stalled peers wedged the pod: round trip {stalled:.2f}s "
         f"exceeds {LATENCY_BUDGET_S}s (baseline {base:.2f}s)")

# The pod must also still work after the peers vanish mid-handshake.
for s in sockets:
    s.close()
sockets.clear()
time.sleep(1.0)
os.write(master, b"echo SURVIVE_OK\r")
if not read_until(master, b"SURVIVE_OK", 30):
    fail("pod did not survive stalled peers disconnecting")

cleanup()
print("SMOKE PASS: silent peers cannot wedge a pod's shell")
