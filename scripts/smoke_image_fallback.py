#!/usr/bin/env python3
"""Live check: an image still appears on a terminal with no graphics support.

Regression target: hexe draws images by re-transmitting them to the host with
the Kitty protocol, and a host that does not speak it got NOTHING -- a blank
hole where the image should be, with no indication anything was there. That is
the worst of the available outcomes.

`src/frontends/terminal/image_fallback.zig` now draws the image out of text
instead: one upper half block per cell, foreground painting the top half of the
pixels and background the bottom, so a row of cells carries two rows of pixels.

This smoke is the deliberate opposite of `smoke_kitty_graphics.py`: it NEVER
answers the graphics capability query, so the frontend believes it is talking to
a plain terminal. A pane then draws an image and the half blocks must appear.
"""
import atexit
import base64
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"imgfallback-{os.getpid()}")
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

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "imgfallback"])
# Deliberately silent: a terminal that cannot draw images does not answer the
# Kitty graphics query, so the frontend must fall back on its own.
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")
drain(master, 1.0)

os.write(master, f"cat {sixel_blob}\r".encode())
ok, buf = read_until(master, b"SIXEL_SENT", 30)
if not ok:
    fail("the pane never emitted the sixel")
out = buf + drain(master, 6.0)

# No graphics capability, so nothing may be transmitted to the host.
if b"\x1b_Gf=" in out:
    fail("hexe transmitted a Kitty image to a terminal that never claimed to "
         "support the protocol")

UPPER_HALF = "\u2580".encode()
LOWER_HALF = "\u2584".encode()
if UPPER_HALF not in out and LOWER_HALF not in out:
    fail("no half blocks were drawn: the image is invisible on a terminal "
         f"without graphics. saw {len(out)} bytes of output")
print("half blocks drawn for the sixel", flush=True)

# The sixel was solid red, so the blocks must carry its colour rather than
# whatever the pane's text colour happened to be. vaxis writes the
# colon-separated SGR form; accept the semicolon one too.
red = (b"38:2:255:0:0" in out) or (b"38;2;255;0;0" in out)
if not red:
    fail("half blocks were drawn without the image's colour")
print("half blocks carry the image colour", flush=True)

if b"#1;2;100;0;0" in out:
    fail("the raw sixel payload reached the host terminal as text")

os.write(master, b"echo ALIVE_AFTER\r")
ok, _ = read_until(master, b"ALIVE_AFTER", 30)
if not ok:
    fail("pane unresponsive after drawing an image")

cleanup()
print("SMOKE PASS: images degrade to half blocks on a terminal without graphics")
