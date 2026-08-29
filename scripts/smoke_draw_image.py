#!/usr/bin/env python3
"""Live check: hexe places an image file of its own accord.

Every other image in hexe belongs to a program running in a pane. This is the
other direction -- hexe itself putting a picture on the screen because a caller
asked, through the same `draw` verb that takes bytes:

    hexe api draw '"logo"' '{"image":"/path/x.png","width":10,"height":4}'

The point of encoding it as a Kitty placement into the drawing's own surface VT,
rather than adding a second way to draw, is that everything downstream already
works: it reaches a graphics-capable terminal as a Kitty image, and one without
graphics as half blocks. This asserts both, from the one API call.
"""
import fcntl, os, pty, re, struct, subprocess, sys, termios, threading, time, zlib

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")

W = "/tmp/hexe-drawimage"
subprocess.run(["rm", "-rf", W])
os.makedirs(W, exist_ok=True)

def png(width, height, rgba):
    """A minimal PNG, built here so the smoke needs no image library."""
    raw = b"".join(b"\x00" + bytes(rgba) * width for _ in range(height))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


# Solid red, big enough that scaling to the drawing's rectangle is a real scale.
IMG = os.path.join(W, "logo.png")
open(IMG, "wb").write(png(32, 16, (255, 0, 0, 255)))
NOT_IMG = os.path.join(W, "notes.txt")
open(NOT_IMG, "w").write("this is not a picture\n")

# A real 1x1 JPEG, and a GIF hexe has no decoder for. The Kitty protocol has no
# JPEG, so a JPEG only works if hexe decodes it before encoding the placement.
JPEG = bytes([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48,
    0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xFF, 0xDB, 0x00, 0x43, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xFF, 0xC0,
    0x00, 0x11, 0x08, 0x00, 0x01, 0x00, 0x01, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11,
    0x01, 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0xFF, 0xC4, 0x00, 0x14, 0x10, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xC4, 0x00,
    0x14, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xFF, 0xC4, 0x00, 0x14, 0x11, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00,
    0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0x7F, 0x00, 0xFF, 0xD9,
])
JPG_IMG = os.path.join(W, "photo.jpg")
open(JPG_IMG, "wb").write(JPEG)
GIF_IMG = os.path.join(W, "anim.gif")
open(GIF_IMG, "wb").write(b"GIF89a\x01\x00\x01\x00\x80\x00\x00")

def env_for(instance):
    """Each run gets its own instance and its own runtime directory.

    The two halves of this smoke are separate hexe stacks on purpose: reusing
    one means the second frontend races the first's daemons shutting down, and
    a start that fails for that reason looks exactly like the bug under test."""
    root = os.path.join(W, instance)
    for d in (root + "/run/hexe", root + "/cfg/hexe"):
        os.makedirs(d, exist_ok=True)
    open(root + "/cfg/hexe/init.lua", "w").write(
        "local hexe = require('hexe')\nhexe.status = { enabled = false }\n"
    )
    v = dict(os.environ)
    v.update({"HEXE_INSTANCE": instance, "XDG_RUNTIME_DIR": root + "/run",
              "XDG_CONFIG_HOME": root + "/cfg", "XDG_STATE_HOME": root + "/state",
              "XDG_DATA_HOME": root + "/data", "TERM": "xterm-256color",
              "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
    for k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
              "HEXE_API_SOCKET", "HEXE_PAINTER_SOCKET", "HEXE_FLOAT", "HEXE_ENV_FD", "HEXE_BIN"):
        v.pop(k, None)
    return v


e = env_for("drawgfx")

KITTY_OK = b"\x1b_Gi=1;OK\x1b\\"
UPPER_HALF = "▀".encode()
LOWER_HALF = "▄".encode()

procs = []
buf = bytearray()


def spawn():
    m, s = pty.openpty()
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "di"], stdin=s, stdout=s, stderr=s, env=e,
                         cwd=W, start_new_session=True)
    os.close(s)
    procs.append(p)

    def drain():
        while True:
            try:
                d = os.read(m, 65536)
                if not d:
                    return
                buf.extend(d)
            except OSError:
                return

    threading.Thread(target=drain, daemon=True).start()
    return p, m


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=6)
            except subprocess.TimeoutExpired:
                p.kill()
    for inst in ("drawgfx", "drawplain"):
        subprocess.run(["pkill", "-f", "--", "--instance " + inst], capture_output=True)


def fail(msg):
    print("FAIL:", msg)
    cleanup()
    raise SystemExit(1)


def api(*args):
    return subprocess.run([HEXE, "api", *args], env=e, capture_output=True, text=True, cwd=W)


def drew(r):
    """The verb's own answer. `ok` reports that the CALL worked, which it does
    even when the draw was refused -- the refusal is `result`."""
    return '"result":true' in r.stdout.replace(" ", "")


def settle(seconds=3.0):
    time.sleep(seconds)
    return bytes(buf)


# ---- a terminal that speaks the protocol ------------------------------------
p, m = spawn()
time.sleep(2.0)
for _ in range(4):
    os.write(m, KITTY_OK)
    time.sleep(0.4)
time.sleep(3.0)
if p.poll() is not None:
    fail("frontend didn't start")

if "draw" not in api("verbs").stdout:
    fail("`draw` is not advertised as a verb")

del buf[:]
r = api("draw", '"logo"', '{"image":"%s","width":10,"height":4,"x":2,"y":2}' % IMG)
if not drew(r):
    fail(f"draw with `image` was refused: {r.stdout!r} {r.stderr!r}")
out = settle()

if b"\x1b_Gf=" not in out:
    fail("the image never reached the host terminal as a Kitty transmission")
if b"\x1b_Ga=p,i=" not in out:
    fail("the image was transmitted but never placed")
print("graphics terminal: hexe's own image is transmitted and placed", flush=True)

# ---- the same, from a JPEG ---------------------------------------------------
del buf[:]
r = api("draw", '"photo"', '{"image":"%s","width":8,"height":3,"x":40,"y":2}' % JPG_IMG)
if not drew(r):
    fail(f"draw with a JPEG was refused: {r.stdout!r}")
out = settle()
if b"\x1b_Gf=32,s=1,v=1,i=" not in out:
    fail("a JPEG drawing never reached the host terminal — the Kitty protocol "
         "has no JPEG, so hexe has to decode it first")
print("graphics terminal: a JPEG is decoded and placed", flush=True)

# ---- a path that is not an image --------------------------------------------
r = api("draw", '"bogus"', '{"image":"%s","width":10,"height":4}' % NOT_IMG)
if drew(r):
    fail("draw accepted a file that is not an image")
r = api("draw", '"missing"', '{"image":"/nope/none.png","width":10,"height":4}')
if drew(r):
    fail("draw accepted a path that does not exist")
r = api("draw", '"gif"', '{"image":"%s","width":10,"height":4}' % GIF_IMG)
if drew(r):
    fail("draw accepted an image format hexe has no decoder for")
print("a non-image, a missing path and an unsupported format are all refused", flush=True)

cleanup()
del procs[:]
del buf[:]

# ---- a terminal that does not ------------------------------------------------
e = env_for("drawplain")
p, m = spawn()
# Never answer the capability query.
time.sleep(5.0)
if p.poll() is not None:
    fail("frontend didn't start for the fallback run")

del buf[:]
r = api("draw", '"logo"', '{"image":"%s","width":10,"height":4,"x":2,"y":2}' % IMG)
if not drew(r):
    fail("draw with `image` was refused on a plain terminal")
out = settle()

if b"\x1b_Gf=" in out:
    fail("hexe transmitted a Kitty image to a terminal that never claimed support")
if UPPER_HALF not in out and LOWER_HALF not in out:
    fail("hexe's own image drew nothing on a terminal without graphics")
if b"38:2:255:0:0" not in out and b"38;2;255;0;0" not in out:
    fail("half blocks were drawn without the image's colour")
print("plain terminal: the same call draws half blocks in the image's colour", flush=True)

cleanup()
print("SMOKE PASS: hexe places an image file itself, on either kind of terminal")
