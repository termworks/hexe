#!/usr/bin/env python3
"""Live check: a program inside a pane can work out how big a cell is.

Regression target: a pane's pty reported `ws_xpixel = 0` and `ws_ypixel = 0`.
Cell counts alone do not say how tall a picture will be, so every program that
draws images -- `icat`, `timg`, `chafa`, anything asking `TIOCGWINSZ` -- fell
back to a guess, and the guess was made against the wrong terminal, because the
pane is not the window.

The frontend knows the host's cell size (it reads it from its own winsize and
refreshes it on every resize). It now sends that with the pane's size in cells,
and the pod puts a real pixel geometry on the pty.

Asserted, from inside a pane:
  1. the pty reports non-zero pixel dimensions;
  2. dividing them by the cell counts gives back the host's cell size;
  3. a resize keeps the two consistent;
  4. a host that reports no pixel size still leaves the pane at zero, rather
     than inventing a geometry.
"""
import atexit
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"cellsize-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

# The outer terminal's geometry. 100x30 cells of 9x19 pixels: deliberately not
# the 8x16 default, so a pane reporting the default would be caught.
COLS, ROWS = 100, 30
CELL_W, CELL_H = 9, 19


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


def spawn_frontend(cols, rows, cell_w, cell_h):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                struct.pack("HHHH", rows, cols, cols * cell_w, rows * cell_h))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "cells"], stdin=slave, stdout=slave,
                         stderr=slave, env=env, cwd=WORKDIR, start_new_session=True)
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


# A program in the pane that reports its own pty geometry, the way an image tool
# does before deciding how many rows a picture needs.
#
# It writes to a FILE rather than to the screen. The pane's output reaches this
# process only after hexe has rendered it into cells, positioned and repainted,
# so scraping it back out of the escape stream would be testing the renderer --
# not the ioctl this is about.
REPORT = os.path.join(WORKDIR, "geom.py")
with open(REPORT, "w") as f:
    f.write(
        "import fcntl, os, struct, sys, termios\n"
        "ws = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\0'*8))\n"
        "open(sys.argv[1], 'w').write('rows=%d cols=%d xpx=%d ypx=%d' % ws)\n"
    )

_report_seq = [0]


def geometry(master, tag):
    _report_seq[0] += 1
    out = os.path.join(WORKDIR, f"geom-{_report_seq[0]}.txt")
    os.write(master, f"python3 {REPORT} {out}\r".encode())

    deadline = time.time() + 30
    while time.time() < deadline:
        if os.path.exists(out) and os.path.getsize(out) > 0:
            break
        time.sleep(0.2)
    else:
        fail(f"{tag}: the program in the pane never reported its geometry")

    m = re.match(r"rows=(\d+) cols=(\d+) xpx=(\d+) ypx=(\d+)", open(out).read())
    if not m:
        fail(f"{tag}: could not read the reported geometry")
    rows, cols, xpx, ypx = (int(v) for v in m.groups())
    print(f"{tag}: pane is {cols}x{rows} cells, {xpx}x{ypx} pixels", flush=True)
    return cols, rows, xpx, ypx


print(f"instance={INST}")

fe, master = spawn_frontend(COLS, ROWS, CELL_W, CELL_H)
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"stty -echo; echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")

cols, rows, xpx, ypx = geometry(master, "initial")
if xpx == 0 or ypx == 0:
    fail("the pane's pty reports no pixel size: a program in it cannot work out "
         "how big a cell is")
if cols == 0 or rows == 0:
    fail("the pane reported no cell size at all")

if xpx // cols != CELL_W or ypx // rows != CELL_H:
    fail(f"the pane's cell size is {xpx // cols}x{ypx // rows}, but the host's is "
         f"{CELL_W}x{CELL_H} — the wrong geometry is worse than none")
print("the pane reports the host's real cell size", flush=True)

# ---- and it survives a resize ------------------------------------------------
fcntl.ioctl(master, termios.TIOCSWINSZ,
            struct.pack("HHHH", ROWS - 6, COLS - 20, (COLS - 20) * CELL_W, (ROWS - 6) * CELL_H))
os.kill(fe.pid, signal.SIGWINCH)
time.sleep(2.0)

cols2, rows2, xpx2, ypx2 = geometry(master, "after resize")
if cols2 == cols and rows2 == rows:
    fail("the pane never saw the resize, so this proves nothing")
if xpx2 // cols2 != CELL_W or ypx2 // rows2 != CELL_H:
    fail(f"after a resize the pane's cell size is {xpx2 // cols2}x{ypx2 // rows2}, "
         f"not the host's {CELL_W}x{CELL_H}")
print("the cell size stays right across a resize", flush=True)

cleanup()
del procs[:]

# ---- a host that reports nothing --------------------------------------------
# Zero must stay zero: a made-up geometry is worse than an honest absence,
# because a program cannot tell it is being lied to.
fe2, master2 = spawn_frontend(COLS, ROWS, 0, 0)
time.sleep(3.0)
if fe2.poll() is not None:
    fail("frontend didn't start without a host pixel size")

os.write(master2, b"stty -echo; echo WARM2\r")
ok, _ = read_until(master2, b"WARM2", 30)
if not ok:
    fail("pane never became responsive without a host pixel size")

_, _, xpx3, ypx3 = geometry(master2, "no host pixel size")
if xpx3 != 0 or ypx3 != 0:
    fail(f"the host reported no pixel size, but the pane claims {xpx3}x{ypx3} — "
         "hexe invented a geometry rather than passing on the absence")
print("no host pixel size means no pane pixel size", flush=True)

cleanup()
print("SMOKE PASS: a pane's pty carries the host's real cell size")
