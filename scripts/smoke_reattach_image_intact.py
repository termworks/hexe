#!/usr/bin/env python3
"""Live check: reattaching a pane that displayed an image must not print base64.

Regression target: the backlog replay window starts at `ring_len -
REPLAY_TAIL_CAP` and was then nudged forward to the next newline
(`alignReplayToLine`). That resynchronises every sequence a text program emits,
because a newline cannot appear inside a CSI. A Kitty image cannot be fixed that
way: its APC payload is base64, so it contains no newline at all, and it is
routinely larger than both the 64 KiB align scan and the 1 MiB replay tail. The
cut therefore landed INSIDE the payload, the frontend's parser began in ground
state, and the remaining base64 printed into the pane as a wall of text.

`alignReplayOutOfStringSeq` now moves the cut past the sequence's terminator (or
re-opens the sequence when the ring holds no terminator).

Asserted after reattach:
  1. the pane is still live;
  2. the marker written after the image is present;
  3. no long base64 run is rendered as visible text.
"""
import atexit
import base64
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"image-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

# 640x640 RGBA is 1.6 MB raw, ~2.2 MB base64: comfortably past REPLAY_TAIL_CAP
# (1 MiB), so the replay cut is guaranteed to land inside the payload.
IMG_W = IMG_H = 640
TAIL_MARKER = "IMAGE_TAIL_MARKER"
# The pane is 150 columns; a base64 run this long cannot be anything but a
# payload printed as text.
MIN_B64_RUN = 400


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


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
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
                return False, buf
            if not chunk:
                return False, buf
            buf += chunk
            if marker in buf:
                return True, buf
            if len(buf) > (8 << 20):
                buf = buf[-(2 << 20):]
    return False, buf


def drain(fd, seconds):
    deadline = time.time() + seconds
    out = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 262144)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    return out


print(f"instance={INST}")

# The image blob, written as a file the pane simply cats: a single APC holding
# one unbroken base64 run, then the marker on its own line.
pixels = bytes((i * 7 + 13) % 256 for i in range(256)) * ((IMG_W * IMG_H * 4) // 256)
payload = base64.standard_b64encode(pixels)
blob = os.path.join(WORKDIR, "image.bin")
with open(blob, "wb") as f:
    f.write(b"before the image\n")
    f.write(b"\x1b_Gf=32,s=%d,v=%d,i=1,a=T;" % (IMG_W, IMG_H))
    f.write(payload)
    f.write(b"\x1b\\")
    f.write(b"\n" + TAIL_MARKER.encode() + b"\n")
print(f"image blob: {len(payload)} base64 bytes in one APC", flush=True)

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "imgpane"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")

os.write(master, f"cat {blob}\r".encode())
ok, _ = read_until(master, TAIL_MARKER.encode(), 120)
if not ok:
    fail("the pane never emitted the image blob")
drain(master, 3.0)
print("image emitted into the pane", flush=True)

os.kill(fe.pid, signal.SIGKILL)
fe.wait()
os.close(master)
time.sleep(2.0)
print("frontend killed; reattaching", flush=True)

fe2, master2 = spawn_frontend([HEXE, "mux", "attach", "imgpane"])
ok, buf = read_until(master2, TAIL_MARKER.encode(), 90)
screen = buf + drain(master2, 6.0)

if fe2.poll() is not None:
    fail(f"frontend died after reattach rc={fe2.returncode}")

if not ok:
    fail("the marker written after the image never reappeared after reattach")
print("tail marker present after reattach", flush=True)

# Strip real sequences -- including APC/DCS/OSC, which is how the frontend
# would legitimately re-transmit the image to a graphics-capable host.
visible = re.sub(rb"\x1b[\]P_X^][^\x07\x1b]*(?:\x07|\x1b\\)?", b"", screen)
visible = re.sub(rb"\x1b\[[0-9;:?]*[ -/]*[@-~]", b"", visible)
run = re.search(rb"[A-Za-z0-9+/]{%d,}" % MIN_B64_RUN, visible)
if run:
    fail(f"a {len(run.group(0))}-byte base64 run rendered as literal text after reattach "
         f"— the replay began inside the image payload. context={run.group(0)[:120]!r}")

os.write(master2, b"echo ALIVE_AFTER\r")
ok, _ = read_until(master2, b"ALIVE_AFTER", 30)
if not ok:
    fail("pane unresponsive after reattach")

cleanup()
print("SMOKE PASS: a pane that displayed an image reattaches without printing its payload")
