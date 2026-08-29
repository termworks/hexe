#!/usr/bin/env python3
"""Live check: a float covers an image instead of being painted through.

A Kitty image is not made of cells. hexe writes ONE placement onto the image's
top-left cell and the terminal draws the whole picture from there, spanning as
many cells as the placement says -- and it composites that against the text on
its own terms, not hexe's. A float drawn over the middle of an image therefore
never touches the cell the placement lives on, and the terminal happily draws
the picture over the float. The float is the thing the user is looking at.

The other half is the same problem from the other side: a float that covers the
image's top-left cell removes the placement entirely, so an image only slightly
overlapped vanishes completely.

hexe now trims a placement to the part of it that is still visible, and drops it
when a float leaves nothing. This asserts both, by reading the placements hexe
actually emits: `\\x1b_Ga=p,i=<id>...,r=<rows>,c=<cols>`.
"""
import atexit
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"occlusion-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

COLS, ROWS = 120, 40
CELL_W, CELL_H = 9, 19
# The image is asked for at this size in cells, anchored at the pane's origin.
IMG_COLS, IMG_ROWS = 60, 24
KITTY_OK = b"\x1b_Gi=1;OK\x1b\\"


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


buf = bytearray()


def spawn():
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                struct.pack("HHHH", ROWS, COLS, COLS * CELL_W, ROWS * CELL_H))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "occ"], stdin=slave, stdout=slave,
                         stderr=slave, env=env, cwd=WORKDIR, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, master


def read_until(fd, marker, timeout_s):
    deadline = time.time() + timeout_s
    got = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 262144)
            except OSError:
                return False, got
            if not chunk:
                return False, got
            got += chunk
            buf.extend(chunk)
            if marker in got:
                return True, got
    return False, got


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
            buf.extend(chunk)


def placements(data):
    """Every image placement in the stream, as (rows, cols)."""
    out = []
    for m in re.finditer(rb"\x1b_Ga=p,i=\d+([^\x1b]*)\x1b\\", data):
        opts = m.group(1)
        r = re.search(rb",r=(\d+)", opts)
        c = re.search(rb",c=(\d+)", opts)
        if r and c:
            out.append((int(r.group(1)), int(c.group(1))))
    return out


print(f"instance={INST}")

fe, master = spawn()
time.sleep(2.0)
for _ in range(4):
    os.write(master, KITTY_OK)
    time.sleep(0.4)
time.sleep(2.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"stty -echo; echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")

# A large image anchored at the pane's top-left corner.
pixels = bytes([0, 128, 255, 255] * (64 * 64))
import base64
blob = os.path.join(WORKDIR, "img.bin")
with open(blob, "wb") as f:
    f.write(b"\x1b[H")
    f.write(b"\x1b_Gf=32,s=64,v=64,i=7,a=T,c=%d,r=%d,C=1;" % (IMG_COLS, IMG_ROWS))
    f.write(base64.standard_b64encode(pixels))
    f.write(b"\x1b\\")
    f.write(b"\nIMAGE_UP\n")

del buf[:]
os.write(master, f"cat {blob}\r".encode())
ok, _ = read_until(master, b"IMAGE_UP", 30)
if not ok:
    fail("the pane never emitted the image")
drain(master, 4.0)

before = placements(bytes(buf))
if not before:
    fail("the image was never placed at all, so this proves nothing")
full = max(before)
print(f"unobstructed: placement is {full[1]}x{full[0]} cells", flush=True)
if full[1] < IMG_COLS or full[0] < IMG_ROWS:
    fail(f"the image was placed at {full[1]}x{full[0]}, smaller than the {IMG_COLS}x{IMG_ROWS} "
         "asked for, with nothing covering it")

# ---- now put a float over the middle of it ----------------------------------
del buf[:]
fl = subprocess.Popen([HEXE, "mux", "float", "--title=cover", "--command", "sleep 60"],
                      env=env, cwd=WORKDIR, stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL, start_new_session=True)
procs.append(fl)
drain(master, 6.0)

after = placements(bytes(buf))
# The placement is re-emitted every frame; the distinct sizes are the story.
print(f"with a float over it: placement sizes {sorted(set(after))}", flush=True)

if not after:
    # Nothing drawn at all is the acceptable answer only if the float covers
    # the whole image; a centred float does not.
    fail("the image disappeared entirely when a float covered part of it")

widest = max(after)
if widest[1] >= full[1] and widest[0] >= full[0]:
    fail(f"the image is still placed at its full {widest[1]}x{widest[0]} with a float over it — "
         "the terminal will draw the picture across the float")
print("the placement was trimmed to the part the float leaves visible", flush=True)

# ---- and it comes back when the float goes -----------------------------------
fl.terminate()
try:
    fl.wait(timeout=10)
except subprocess.TimeoutExpired:
    fl.kill()
del buf[:]
drain(master, 6.0)

restored = placements(bytes(buf))
if not restored or max(restored)[1] < full[1]:
    fail(f"the image did not return to full size after the float closed: {restored}")
print("full size returns once the float is gone", flush=True)

cleanup()
print("SMOKE PASS: a float occludes an image instead of being painted over")
