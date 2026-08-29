#!/usr/bin/env python3
"""Live check: sixel and iTerm2 images come out the other side as Kitty.

Regression target: a mux sits between a program and a terminal, and the two
rarely agree on how to draw an image. ghostty's VT speaks neither sixel (its
readonly stream drops DCS outright) nor iTerm2 inline images (OSC 1337 `File=`
is parsed and thrown away), so a pane running `img2sixel`, `timg`, `chafa -f
sixel`, matplotlib or `imgcat` drew nothing at all.

`src/core/image_import.zig` lifts both out of the pane's byte stream, decodes
them, and hands the pixels to ghostty's Kitty image storage. This asserts the
whole translation: sixel goes IN to the pane, and Kitty comes OUT to the host
terminal, which is the point of putting it in the mux.
"""
import atexit
import base64
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"imgimport-{os.getpid()}")
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

# A sixel: colour 1 defined as pure red, then eight columns of a full band.
# Six rows tall, because a sixel character is six vertical pixels.
sixel_blob = os.path.join(WORKDIR, "img.sixel")
with open(sixel_blob, "wb") as f:
    f.write(b"\x1bP0;1;0q#1;2;100;0;0!8~\x1b\\")
    f.write(b"\nSIXEL_SENT\n")

# The smallest valid PNG, wrapped the way iTerm2's imgcat sends one.
PNG = bytes([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
])
iterm_blob = os.path.join(WORKDIR, "img.iterm")
with open(iterm_blob, "wb") as f:
    f.write(b"\x1b]1337;File=inline=1;size=%d:" % len(PNG))
    f.write(base64.standard_b64encode(PNG))
    f.write(b"\x07")
    f.write(b"\nITERM_SENT\n")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "imgimport"])
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

os.write(master, f"cat {sixel_blob}\r".encode())
# The transmit can land in the SAME burst as the marker, so keep that buffer.
ok, buf = read_until(master, b"SIXEL_SENT", 30)
if not ok:
    fail("the pane never emitted the sixel")
out = buf + drain(master, 5.0)

# 8 wide and 6 tall is the decoded size of that sixel, and hexe transmits it as
# RGBA -- so this is the translation, not a passthrough of the pane's bytes.
transmit = b"\x1b_Gf=32,s=8,v=6,i="
if transmit not in out:
    fail("sixel never reached the host terminal as a Kitty image. "
         f"saw {len(out)} bytes of output")
if b"\x1b_Ga=p,i=" not in out:
    fail("the sixel was transmitted but never placed")
print("sixel in, kitty out", flush=True)

# The pane's own sixel bytes must not have leaked through as text.
if b"#1;2;100;0;0" in out:
    fail("the raw sixel payload reached the host terminal as text")

os.write(master, f"cat {iterm_blob}\r".encode())
ok, buf = read_until(master, b"ITERM_SENT", 30)
if not ok:
    fail("the pane never emitted the iTerm2 image")
out = buf + drain(master, 5.0)

if b"\x1b_Gf=32,s=1,v=1,i=" not in out:
    fail("an iTerm2 inline PNG never reached the host terminal as a Kitty image")
print("iterm2 in, kitty out", flush=True)

os.write(master, b"echo ALIVE_AFTER\r")
ok, _ = read_until(master, b"ALIVE_AFTER", 30)
if not ok:
    fail("pane unresponsive after drawing images")

cleanup()
print("SMOKE PASS: sixel and iTerm2 images are translated into Kitty for the host")
