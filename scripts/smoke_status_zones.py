#!/usr/bin/env python3
"""Live check: the status bar composed from three independently addressed zones.

SEGMENTS.md phase 1. Three things it has to get right, none of which the
single-view bar exercises:

  placement   left flush at 0, right flush to the far edge, centre between them
  isolation   a zone whose painter goes silent must not take the others with it
  hit-testing regions come back in ZONE-local coordinates, so hexe has to offset
              them by the zone origin - forget that and every click in the right
              zone lands somewhere else

The painter answers each selector with its own marker and its own width, so a
mistake in placement shows up as a marker at the wrong column rather than as a
missing bar. Placement arithmetic itself is unit-tested in
src/frontends/terminal/statusbar_layout.zig; this covers the wiring around it.

Two of the checks here are load-bearing and were confirmed to fail against
unfixed code: the origin offset (drop the translation and the hover check
fails) and the isolation check (wedge all three and it fails). Phase 0 is
coverage of the ok:false opt-out path rather than a sharp assertion.
"""
import atexit
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import fcntl
import pty
import termios

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"zones{os.getpid()}")
CF = os.path.join(WD, "config")
SOCK = os.path.join(WD, "painter.sock")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)

ROWS, COLS = 24, 100

# Distinct markers so a misplaced zone is visible as a wrong column, and widths
# chosen so the three together fit inside COLS.
MARKERS = {"left": "LEFTZONE", "center": "MIDZONE", "right": "RIGHTZONE"}

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(
        "local hexe = require('hexe')\n"
        "return hexe.setup({ status = {\n"
        "  enabled = true,\n"
        f"  socket = '{SOCK}',\n"
        "  refresh_ms = 120,\n"
        "  zones = {\n"
        "    left   = { view = 'status.left' },\n"
        "    center = { view = 'status.center' },\n"
        "    right  = { view = 'status.right' },\n"
        "  },\n"
        "  shrink = { 'center', 'right', 'left' },\n"
        "} })\n"
    )

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_CONFIG_HOME": CF, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

# ---------------------------------------------------------------- fake painter
painter_state = {
    "declined": {"center"},  # zones answered with ok:false, as an unimplemented
                             # view is answered: they must take no width
    "wedged": set(),        # selectors that accept and never answer
    "seen": {},             # selector -> request count
    "tick": 0,              # bumped so answers change and staleness is visible
    "hover": {},            # selector -> last hover_region hexe reported
}
stop_painter = threading.Event()


def frame_send(conn, obj):
    body = json.dumps(obj).encode()
    conn.sendall(struct.pack(">I", len(body)) + body)


def frame_recv(conn):
    hdr = b""
    while len(hdr) < 4:
        chunk = conn.recv(4 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        chunk = conn.recv(need - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


def zone_of(selector):
    return selector.rsplit(".", 1)[-1] if selector.startswith("status.") else None


def painter():
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    srv.bind(SOCK)
    srv.listen(16)
    srv.settimeout(0.3)
    while not stop_painter.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        zone = None
        try:
            req = frame_recv(conn)
            if req is None:
                conn.close()
                continue
            # The request names its view in `select`, as an array.
            sel_list = req.get("select") or []
            sel = sel_list[0] if sel_list else ""
            zone = zone_of(sel)
            if zone is None:
                frame_send(conn, {"version": 1, "ok": False})
                conn.close()
                continue

            painter_state["seen"][zone] = painter_state["seen"].get(zone, 0) + 1
            ctx = req.get("context", {})
            # hover_region rides inside context.values, not context itself.
            painter_state["hover"][zone] = ctx.get("values", {}).get("hover_region", "")

            if zone in painter_state["declined"]:
                frame_send(conn, {"version": 1, "ok": False})
                conn.close()
                continue

            if zone in painter_state["wedged"]:
                continue                      # accept, read, never answer

            text = f"{MARKERS[zone]}{painter_state['tick']}"
            frame_send(conn, {
                "version": 1,
                "ok": True,
                "output": {
                    "mode": "run",
                    "runs": [{"text": text, "style": "fg:15 bg:237"}],
                    "width": len(text),
                    "next_frame_ms": None,
                    # One clickable rectangle covering the whole zone, in
                    # ZONE-local coordinates — the thing hexe must offset.
                    "regions": [{
                        "id": f"{zone}.all",
                        "x": 0, "y": 0, "width": len(text), "height": 1,
                        "actions": {"left": f"noop.{zone}"},
                    }],
                },
            })
        except OSError:
            pass
        finally:
            if zone not in painter_state["wedged"]:
                try:
                    conn.close()
                except OSError:
                    pass
    srv.close()


threading.Thread(target=painter, daemon=True).start()
time.sleep(0.4)


def cleanup():
    stop_painter.set()
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    r = subprocess.run(["pgrep", "-f", f"instance {INST}"], capture_output=True, text=True)
    if r.returncode == 0:
        for pid in r.stdout.split():
            try: os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError): pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg, capture=None):
    if capture is not None:
        path = os.path.join(WD, "capture.bin")
        with open(path, "wb") as fh:
            fh.write(capture)
        msg = f"{msg}\n  full frame capture: {path}"
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)


# ------------------------------------------------------------------- frontend
seen = bytearray()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "zones"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave)
procs.append(fe)


def drain(fd):
    while True:
        try:
            chunk = os.read(fd, 65536)
            if not chunk:
                return
        except OSError:
            return
        seen.extend(chunk)


threading.Thread(target=drain, args=(master,), daemon=True).start()
time.sleep(4.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")


def repaint(settle=2.5):
    """Force a full redraw; vaxis only emits cells that changed."""
    global COLS
    del seen[:]
    COLS = 99 if COLS == 100 else 100
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    time.sleep(settle)
    return bytes(seen)


CUP = re.compile(rb"\x1b\[(\d+);(\d+)H")
SGR = re.compile(rb"\x1b\[[0-9;:]*m")


def bar_rows(frame):
    """Every draw of the status row, as (visible text) with columns preserved.

    vaxis positions once and then emits the whole row, so a zone's column is its
    offset inside the reconstructed line, not the last CUP before it.
    """
    rows = []
    for m in CUP.finditer(frame):
        if int(m.group(1)) != ROWS:
            continue
        out = bytearray(b" " * (int(m.group(2)) - 1))
        tail = frame[m.end():]
        i = 0
        while i < len(tail):
            if tail[i] == 0x1b:
                sgr = SGR.match(tail, i)
                if sgr is None:
                    break                 # any other escape ends this row
                i = sgr.end()
                continue
            if tail[i] in (0x0a, 0x0d):
                break
            out.append(tail[i])
            i += 1
        rows.append(bytes(out))
    return rows


def column_of(frame, marker):
    """Column a marker sits at, in the last row draw that contains it."""
    want = marker.encode()
    for row in reversed(bar_rows(frame)):
        idx = row.find(want)
        if idx >= 0:
            return idx
    return None


# --------------------------------------------- 0. declining, then implementing
#
# Coverage of the opt-out path rather than a sharp assertion: `ok:false` is a
# *successful* exchange, and this walks a painter from declining a zone to
# implementing it. It catches a hang or a zone that never returns; it does not
# pin down the retry cadence, which recovers well inside this window either way.
frame = repaint()
if MARKERS["center"].encode() in frame:
    fail("a zone answering ok:false still drew content", frame)
if column_of(frame, MARKERS["left"]) != 0:
    fail("left zone moved because the centre declined", frame)
print("zones: a declined zone draws nothing")

painter_state["declined"].clear()
deadline = time.time() + 6.0
while time.time() < deadline:
    if MARKERS["center"].encode() in repaint(settle=1.0):
        break
else:
    fail("a zone that declined and then started answering never came back")
print(f"zones: a zone that starts answering appears within "
      f"{6.0 - (deadline - time.time()):.1f}s")

# -------------------------------------------------------------- 1. all present
#
# Every marker carries the tick, so bumping it makes all three zones change and
# guarantees a full row rather than whatever vaxis considered dirty.
painter_state["tick"] += 1
time.sleep(1.5)
frame = repaint()
for zone, marker in MARKERS.items():
    if marker.encode() not in frame:
        fail(f"zone {zone} never reached the bar", frame)
print("zones: all three selectors answered and were drawn")

# --------------------------------------------------------------- 2. placement
left_col = column_of(frame, MARKERS["left"])
right_col = column_of(frame, MARKERS["right"])
center_col = column_of(frame, MARKERS["center"])
if left_col != 0:
    fail(f"left zone is not flush at column 0 (drawn at {left_col})", frame)
right_text_len = len(MARKERS["right"]) + len(str(painter_state["tick"]))
if right_col is None or right_col + right_text_len != COLS:
    fail(f"right zone is not flush to the far edge (drawn at {right_col}, "
         f"bar is {COLS} wide)", frame)
if center_col is None or not (left_col < center_col < right_col):
    fail(f"centre zone is not between the other two (left={left_col} "
         f"center={center_col} right={right_col})", frame)
print(f"zones: placed left={left_col} center={center_col} right={right_col} of {COLS}")

# ------------------------------------------------------- 3. one zone goes dark
#
# The single-view bar had one failure mode: a silent painter froze the whole
# bar. With zones, silence has to be contained to the zone that went quiet.
painter_state["wedged"].add("center")
painter_state["tick"] += 1
before = dict(painter_state["seen"])
time.sleep(2.0)

frame = repaint()
new_left = f"{MARKERS['left']}{painter_state['tick']}".encode()
new_right = f"{MARKERS['right']}{painter_state['tick']}".encode()
if new_left not in frame or new_right not in frame:
    fail("a wedged centre zone stopped the live zones updating — the whole "
         "point of addressing them separately", frame)
if painter_state["seen"].get("left", 0) <= before.get("left", 0):
    fail("the left zone stopped being asked while the centre was wedged")
print("zones: a wedged zone does not stall the others")

painter_state["wedged"].discard("center")
time.sleep(1.5)

# -------------------------------------------------- 4. hit-testing is offset
#
# The right zone's rectangle arrives at x=0 in ZONE-local coordinates. Hover a
# column that is only inside it after adding the zone origin: without the
# offset, hexe reports the wrong id or none at all.
frame = repaint()
right_col = column_of(frame, MARKERS["right"])
if right_col is None:
    fail("right zone vanished before the hover check", frame)

def hover(col):
    painter_state["hover"] = {}
    os.write(master, f"\x1b[<35;{col + 1};{ROWS}M".encode())
    time.sleep(2.0)
    return {z: v for z, v in painter_state["hover"].items() if v}


# The left zone sits at origin 0, so it resolves with or without the offset.
# It is the control: if this reports nothing, the pointer never arrived and the
# offset check below would be measuring the wrong thing.
left_col = column_of(frame, MARKERS["left"])
seen_left = hover(left_col + 2)
if not seen_left:
    fail(f"hovering the left zone at column {left_col + 2} reported no region at "
         f"all — the pointer is not reaching the bar", frame)

seen_right = hover(right_col + 2)
if seen_right.get("right") != "right.all":
    fail(f"hover at column {right_col + 2} reported {seen_right!r}, not 'right.all' "
         f"— the right zone starts at {right_col} and its rectangle arrives at "
         f"zone-local x=0, so hexe is not offsetting by the zone origin")
print("zones: hit rectangles are offset by the zone origin")

if fe.poll() is not None:
    fail("frontend died during the zone checks")

cleanup()
print("PASS: three status zones place, isolate and hit-test independently")
