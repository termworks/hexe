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
CONTROL = os.path.join(WD, "control.json")
SEEN = os.path.join(WD, "seen.json")
PAINTER = os.path.join(WD, "painter.py")
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
        f"  exec = 'python3 {PAINTER}',\n"
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

# ---------------------------------------------------------------- the painter
#
# A child of hexe now, not a socket everybody shares, so the state the test
# drives it with and the observations it makes back cross a file rather than a
# thread boundary. `control` is what the test wants it to do; `seen` is what it
# was asked.
def control(**kw):
    """Change what the painter does, mid-run."""
    cur = json.load(open(CONTROL)) if os.path.exists(CONTROL) else {}
    cur.update(kw)
    with open(CONTROL, "w") as fh:
        json.dump(cur, fh)


def observed():
    """What the painter has been asked for so far."""
    try:
        return json.load(open(SEEN))
    except (OSError, ValueError):
        return {"seen": {}, "hover": {}}


TICK = [0]
control(declined=["center"], wedged=[], tick=0)

with open(PAINTER, "w") as fh:
    fh.write(f'''#!/usr/bin/env python3
import json, os, struct, sys

CONTROL = {CONTROL!r}
SEEN = {SEEN!r}
MARKERS = {MARKERS!r}


def state():
    try:
        return json.load(open(CONTROL))
    except (OSError, ValueError):
        return {{"declined": [], "wedged": [], "tick": 0}}


def note(zone, hover):
    try:
        cur = json.load(open(SEEN))
    except (OSError, ValueError):
        cur = {{"seen": {{}}, "hover": {{}}}}
    cur["seen"][zone] = cur["seen"].get(zone, 0) + 1
    cur["hover"][zone] = hover
    tmp = SEEN + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cur, fh)
    os.replace(tmp, SEEN)


def recv():
    head = sys.stdin.buffer.read(4)
    if len(head) < 4:
        return None
    n = struct.unpack(">I", head)[0]
    body = sys.stdin.buffer.read(n)
    return json.loads(body) if len(body) == n else None


def send(obj):
    body = json.dumps(obj).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
    sys.stdout.buffer.flush()


while True:
    req = recv()
    if req is None:
        break
    st = state()
    sel = (req.get("select") or [""])[0]
    zone = sel.rsplit(".", 1)[-1] if sel.startswith("status.") else None
    if zone is None or zone not in MARKERS:
        send({{"version": 1, "ok": False}})
        continue
    ctx = req.get("context", {{}})
    note(zone, ctx.get("values", {{}}).get("hover_region", ""))
    if zone in st.get("declined", []):
        send({{"version": 1, "ok": False}})
        continue
    if zone in st.get("wedged", []):
        continue                      # read the request, never answer
    text = "%s%d" % (MARKERS[zone], st.get("tick", 0))
    send({{"version": 1, "ok": True, "output": {{
        "mode": "run",
        "runs": [{{"text": text, "style": "fg:15 bg:237"}}],
        "width": len(text),
        "next_frame_ms": None,
        # One clickable rectangle covering the whole zone, in ZONE-local
        # coordinates -- the thing hexe must offset.
        "regions": [{{"id": "%s.all" % zone, "x": 0, "y": 0,
                     "width": len(text), "height": 1,
                     "actions": {{"left": "noop.%s" % zone}}}}],
    }}}})
''')


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    # The painter is hexe's child, so it goes with hexe; only the frontend tree
    # needs sweeping.
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

control(declined=[])
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
TICK[0] += 1
control(tick=TICK[0])
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
right_text_len = len(MARKERS["right"]) + len(str(TICK[0]))
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
control(wedged=["center"])
TICK[0] += 1
control(tick=TICK[0])
before = dict(observed()["seen"])
time.sleep(2.0)

frame = repaint()
new_left = f"{MARKERS['left']}{TICK[0]}".encode()
new_right = f"{MARKERS['right']}{TICK[0]}".encode()
if new_left not in frame or new_right not in frame:
    fail("a wedged centre zone stopped the live zones updating — the whole "
         "point of addressing them separately", frame)
if observed()["seen"].get("left", 0) <= before.get("left", 0):
    fail("the left zone stopped being asked while the centre was wedged")
print("zones: a wedged zone does not stall the others")

control(wedged=[])
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
    os.path.exists(SEEN) and os.remove(SEEN)
    os.write(master, f"\x1b[<35;{col + 1};{ROWS}M".encode())
    time.sleep(2.0)
    return {z: v for z, v in observed()["hover"].items() if v}


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
