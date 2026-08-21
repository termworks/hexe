#!/usr/bin/env python3
"""Absolute geometry: put a float *there*, put a divider *there*, rename a pane.

`float.nudge` steps in a direction and `split.resize` steps by cells. Both are
the wrong shape for a pointer, which already knows where the user dropped
something and needs to say so in one move. These verbs state a destination.

Driven through the control socket rather than from Lua, because that is the
path a phone or a browser gateway takes, and it exercises the JSON bridge in
both directions at the same time.

What is actually checked:

  * a float moves and resizes to what was asked, and the mux agrees afterwards
    in cells -- percentages that nothing acts on would pass a naive read-back;
  * a partial spec changes only what it names, so dragging a float does not
    quietly reset its size;
  * out-of-range values are clamped rather than accepted, and the caller is
    told what actually happened;
  * a divider set by ratio really moves the panes either side of it;
  * `ratio(2)` selects pane 2 and does NOT set a ratio of 2 -- the argument
    ambiguity that would make a read look like a write;
  * a rename sticks and an invalid name is refused (names reach socket paths).

Not covered: which mechanism moves a divider. `ratio` sets the layout tree
directly AND syncs to SES, and removing the direct move still passes here,
because the SES round trip lands inside the wait. So the destination is pinned
but immediacy is not, and neither is what happens when SES is unreachable.
"""
import atexit, fcntl, json, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"apigeo{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSION = "apigeo"
ROWS, COLS = 40, 120

open(os.path.join(CF, "hexe", "init.lua"), "w").write(f"""
local hexe = require("hexe")
return hexe.setup({{
  ses = {{ layouts = {{ hexe.layout("geolay", {{
    root = "{WD}",
    tabs = {{ hexe.tab("main", {{ root = hexe.pane() }}) }},
    floats = {{
      hexe.float("scratch", {{ key = "g", title = "scratch", command = "sleep 600",
                             size = {{ width = 40, height = 40 }},
                             position = {{ x = 10, y = 10 }} }}),
    }},
  }}) }} }},
  keys = {{ hexe.key({{ hexe.key.alt, hexe.key['g'] }}, hexe.action.float.toggle('g')) }},
}})
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1", "HEXE_TRUST_ALL_PROJECTS": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []
SOCK = None


def find_socket():
    for root, _dirs, files in os.walk(RUN):
        for f in files:
            if f == f"api@{SESSION}.sock":
                return os.path.join(root, f)
    return None


def cleanup():
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


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush()
    cleanup()
    sys.exit(1)


def watchdog(_sig, _frm):
    print("FAIL: timed out; the mux stopped making progress")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(150)


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", SESSION], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 25
while time.time() < deadline and SOCK is None:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    SOCK = find_socket()
    time.sleep(0.3)
if SOCK is None:
    fail("the control socket never appeared")


def api(name, *args, timeout=10):
    # `args` is the positional list: these verbs take (selector, value), which
    # a single `arg` cannot express.
    req = {"call": name}
    if args:
        req["args"] = list(args)
    body = json.dumps(req).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(struct.pack(">I", len(body)) + body)
    hdr = b""
    while len(hdr) < 4:
        chunk = s.recv(4 - len(hdr))
        if not chunk:
            s.close()
            return None
        hdr += chunk
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        chunk = s.recv(need - len(body))
        if not chunk:
            break
        body += chunk
    s.close()
    return json.loads(body)


def ok(r, what):
    if not r or not r.get("ok"):
        fail(f"{what} failed: {r}")
    return r["result"]


def panes():
    return ok(api("panes"), "panes")


def by_uuid(uuid):
    for p in panes():
        if p["uuid"] == uuid:
            return p
    fail(f"pane {uuid[:8]} vanished")


# ------------------------------------------------------------------- a float
os.write(m, b"\x1bg")
deadline = time.time() + 20
fl = None
while time.time() < deadline:
    fl = [p for p in panes() if p.get("is_float")]
    if fl:
        break
    time.sleep(0.4)
if not fl:
    fail("the float never opened, so there is nothing to move")
fuuid = fl[0]["uuid"]

g = ok(api("geometry", fuuid), "geometry read")
if not g.get("float"):
    fail(f"the float did not report itself as one: {g}")
print(f"read: float at {g['x']},{g['y']} sized {g['width']}x{g['height']} "
      f"({g['cell_width']}x{g['cell_height']} cells)")

# Move and resize in one call, and check the mux really applied it in cells --
# a percentage echoed straight back would pass without anything having moved.
before_cells = (g["cell_x"], g["cell_y"], g["cell_width"], g["cell_height"])
g2 = ok(api("geometry", fuuid, {"x": 30, "y": 20, "width": 60, "height": 50}), "geometry set")
for k, want in (("x", 30), ("y", 20), ("width", 60), ("height", 50)):
    if g2.get(k) != want:
        fail(f"asked for {k}={want}, got {g2.get(k)}: {g2}")

time.sleep(1.5)
live = by_uuid(fuuid)
after_cells = (live["x"], live["y"], live["width"], live["height"])
if after_cells == before_cells:
    fail(f"the percentages changed but the float did not move: still at "
         f"{after_cells} cells. Nothing acted on the request")
exp_w = round(COLS * 0.60)
if abs(live["width"] - exp_w) > 4:
    fail(f"a 60%-wide float on a {COLS}-column screen is {live['width']} cells, "
         f"nowhere near the ~{exp_w} expected")
print(f"set: float moved {before_cells} -> {after_cells} cells, and 60% is ~{exp_w}")

# A partial spec must leave everything it does not name alone: a drag changes
# position, and must not quietly snap the size back to a default.
g3 = ok(api("geometry", fuuid, {"x": 5}), "partial geometry")
if g3.get("x") != 5:
    fail(f"partial set did not apply x: {g3}")
if (g3.get("width"), g3.get("height"), g3.get("y")) != (60, 50, 20):
    fail(f"a spec naming only x also changed the rest: {g3}. Dragging a float "
         f"would reset its size")
print("set: a partial spec changes only what it names")

# Out of range is clamped, and the answer says so rather than echoing the ask.
g4 = ok(api("geometry", fuuid, {"width": 400, "x": 250}), "clamped geometry")
if g4.get("width") != 100 or g4.get("x") != 100:
    fail(f"out-of-range geometry was not clamped to 0..100: {g4}")
print(f"set: 400% clamped to {g4['width']}%, and the caller is told")

# ------------------------------------------------------------------ a divider
ok(api("act", {"type": "split.v"}), "split")
time.sleep(1.5)
splits = ok(api("splits"), "splits")
if len(splits) < 2:
    fail(f"the split did not happen; only {len(splits)} tiled panes")
a, b = splits[0], splits[1]

r0 = ok(api("ratio", a["uuid"]), "ratio read")
if not isinstance(r0, (int, float)):
    fail(f"ratio did not return a number: {r0!r}")

def rects():
    return tuple((by_uuid(p["uuid"])["width"], by_uuid(p["uuid"])["height"])
                 for p in (a, b))


before = rects()
ok(api("ratio", a["uuid"], 0.25), "ratio set")
time.sleep(1.5)
after = rects()
if after == before:
    fail(f"setting the divider to 0.25 left the panes at {before}; the ratio "
         f"was recorded but nothing moved")

# Which axis the divider splits, and which pane is its first branch, are both
# read off the screen. `splits()` comes from a hash map, so its order says
# nothing about the tree -- sorting by position is what makes "the first branch
# gets a quarter" a statement about the layout rather than about iteration order.
recs = [by_uuid(a["uuid"]), by_uuid(b["uuid"])]
axis_is_width = recs[0]["width"] != recs[1]["width"]
recs.sort(key=lambda p: p["x"] if axis_is_width else p["y"])
sizes = [p["width"] if axis_is_width else p["height"] for p in recs]
if sizes[0] >= sizes[1]:
    fail(f"a ratio of 0.25 should leave the divider's first branch the smaller "
         f"one; along the split axis they are {sizes} (panes {after})")
print(f"set: divider 0.25 moved panes {before} -> {after} (w,h); "
      f"first branch {sizes[0]} vs {sizes[1]} cells")

# The ambiguity that would turn a read into a write.
r_before = ok(api("ratio", a["uuid"]), "ratio before index read")
ok(api("ratio", 2), "ratio by pane index")
time.sleep(1.0)
r_after = ok(api("ratio", a["uuid"]), "ratio after index read")
if abs(r_after - r_before) > 0.001:
    fail(f"`ratio(2)` changed the divider ({r_before} -> {r_after}). A number in "
         f"the selector position must select pane 2, not set a ratio of 2")
print("args: `ratio(2)` selects pane 2 rather than setting a ratio of 2")

# -------------------------------------------------------------------- naming
if ok(api("rename", a["uuid"], "workbench"), "rename") is not True:
    fail("rename was refused")
time.sleep(1.0)
if by_uuid(a["uuid"]).get("name") != "workbench":
    fail(f"the rename did not stick: {by_uuid(a['uuid']).get('name')!r}")

# A name reaches a socket path and a CLI argument, so it is constrained.
if ok(api("rename", a["uuid"], "Bad Name/../x"), "invalid rename") is not False:
    fail("an invalid pane name was accepted; names reach socket paths and CLI "
         "arguments, where a slash or a space is not harmless")
if by_uuid(a["uuid"]).get("name") != "workbench":
    fail("a refused rename still changed the name")
print("rename: applied, and an invalid name is refused without clobbering")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: floats, dividers and names can be set to a destination, not just stepped")
