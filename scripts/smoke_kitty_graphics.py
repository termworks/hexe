#!/usr/bin/env python3
"""Live check: an image drawn in a pane reaches a graphics-capable terminal.

Regression target: hexe's whole Kitty image path -- the ghostty image store,
`syncKittyImages`, and the placement blitters in `vt_bridge.zig` -- was compiled
out. Upstream ghostty synthesises its `kitty_graphics` build option from
`oniguruma`, and the exported `ghostty-vt` Zig module force-disables oniguruma,
so `Screen.kitty_images` was an empty struct and every image path sat behind a
comptime `@hasField` that was false. hexe built and ran, and images silently did
nothing. `patches/ghostty-vt-kitty.patch` separates the two options and gives the
module the wuffs dependency the graphics code actually needs.

This smoke plays the part of a graphics-capable host terminal: it answers the
Kitty graphics query so the frontend sets the capability, then has a pane emit
an image and asserts hexe re-transmits it and places it.
"""
import atexit
import base64
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"kittygfx-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

IMG_W = IMG_H = 4
IMG_ID = 42
# What a terminal that speaks the protocol answers to `\x1b_Gi=1,a=q\x1b\\`.
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

pixels = bytes([255, 0, 0, 255] * (IMG_W * IMG_H))
blob = os.path.join(WORKDIR, "img.bin")
with open(blob, "wb") as f:
    f.write(b"\x1b_Gf=32,s=%d,v=%d,i=%d,a=T;" % (IMG_W, IMG_H, IMG_ID))
    f.write(base64.standard_b64encode(pixels))
    f.write(b"\x1b\\")
    f.write(b"\nIMAGE_SENT\n")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "imgcap"])
time.sleep(1.0)
# Answer the capability query the way a graphics-capable terminal does. Sent a
# few times because the frontend queries during startup, not at a fixed moment.
for _ in range(4):
    os.write(master, KITTY_OK)
    time.sleep(0.5)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")
os.write(master, KITTY_OK)
drain(master, 1.0)

os.write(master, f"cat {blob}\r".encode())
# The transmit can land in the SAME burst as the marker, so keep that buffer.
ok, buf = read_until(master, b"IMAGE_SENT", 30)
if not ok:
    fail("the pane never emitted the image")
out = buf + drain(master, 5.0)

# hexe re-transmits the image under its OWN vaxis id, so this is hexe talking to
# the host terminal, not the pane's bytes leaking through.
transmit = b"\x1b_Gf=32,s=%d,v=%d,i=" % (IMG_W, IMG_H)
if transmit not in out:
    fail("hexe never transmitted the image to the host terminal — the Kitty "
         f"graphics path is not running. saw {len(out)} bytes of output")
print("image transmitted to the host terminal", flush=True)

if b"\x1b_Ga=p,i=" not in out:
    fail("the image was transmitted but never placed — no placement sequence")
print("placement emitted", flush=True)

os.write(master, b"echo ALIVE_AFTER\r")
ok, _ = read_until(master, b"ALIVE_AFTER", 30)
if not ok:
    fail("pane unresponsive after drawing an image")

cleanup()
print("SMOKE PASS: a pane's image is transmitted and placed on a graphics-capable terminal")
