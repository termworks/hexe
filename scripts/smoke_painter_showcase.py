#!/usr/bin/env python3
"""Live check: an EXTERNAL program can draw hexe's chrome, sprites and animation.

hexe draws no chrome of its own any more — statusbar, titles, sprites and
spinners all come from a painter hexe spawns itself. That makes the painter
protocol load-bearing: if it regresses, hexe looks broken with no error anywhere.

Drives the real reference painter (contrib/painter_showcase.py) and asserts the
three things an external author depends on:

  1. run mode      -- styled runs reach the screen (the statusbar renders)
  2. next_frame_ms -- the region is re-asked, so a spinner actually animates
  3. surface mode  -- a block of ANSI is composited (a sprite draws)

The spinner check is the important one: a painter that is asked exactly once
renders a still frame that looks fine in a screenshot, so this compares two
captures and requires the glyph to have MOVED.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SOURCE_PAINTER = os.path.join(REPO, "contrib/painter_showcase.py")
# Run from a copy, so the stale check below can break the painter permanently
# without touching the file in the repository. hexe restarts a child that dies,
# which is right -- and means "kill it" is no longer a way to make a painter
# stay gone.
PAINTER = None  # set once WD exists
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"painter{os.getpid()}")
CF = os.path.join(WD, "cfg")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
import shutil
PAINTER = os.path.join(WD, "painter_showcase.py")
shutil.copy(SOURCE_PAINTER, PAINTER)
ROWS, COLS = 40, 120

# The spinner glyphs the showcase cycles through.
BRAILLE = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

PLOG = os.path.join(WD, "selectors.log")

# Deliberately NON-default view names: hexe must ask for exactly these, which is
# how this test proves status.{view,sprite_view,float_title_view,...} are applied
# and not merely accepted by config validation.
open(os.path.join(CF, "hexe", "init.lua"), "w").write("""
local hexe = require("hexe")
return hexe.setup({
  status = { enabled = true, exec = "%s", refresh_ms = 100, stale_ms = 1500,
             view = "showcase.status",
             sprite_view = "showcase.sprite",
             float_title_view = "showcase.float.title",
             container_title_view = "showcase.container.title" },
  pop = { widgets = { pokemon = { enabled = true, position = "topright" } } },
  keys = {
    hexe.key({ hexe.key.alt, hexe.key['s'] }, hexe.action.overlay.sprite_toggle()),
  },
})
""" % (f"{sys.executable} -u {PAINTER}"))

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "XDG_CONFIG_HOME": CF,
            "HEXE_PAINTER_LOG": PLOG, "HEXE_PAINTER_FRAME_MS": "25",
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


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
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


# Reuse the screen reconstructor: the frontend paints cell diffs, so a raw byte
# grep cannot tell what is actually ON the screen.
_src = open(os.path.join(REPO, "scripts/smoke_float_content.py")).read()
_ns = {}
exec("import re\nROWS,COLS=%d,%d\n" % (ROWS, COLS)
     + _src[_src.index("class Screen:"):_src.index("m, sl = pty.openpty()")], _ns)
screen = _ns["Screen"]()

raw = bytearray()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

# Nothing to start here: the painter is hexe's child, named by `status.exec`,
# so it comes up with the frontend below and goes down with it.
print("painter: hexe spawns it")

fe = subprocess.Popen([HEXE, "mux", "new", "-n", "painter"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave); procs.append(fe)


def drain():
    while True:
        try:
            chunk = os.read(master, 65536)
            if not chunk:
                return
        except OSError:
            return
        raw.extend(chunk)
        screen.feed(chunk)


threading.Thread(target=drain, daemon=True).start()
time.sleep(5.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")


def spinner_cells():
    """Every spinner glyph currently on the reconstructed screen."""
    return [ch for ch in screen.text() if ch in BRAILLE]


# 1. run mode: the painter's statusbar reached the screen.
text = screen.text()
if "painter" not in text:
    fail(f"the painter's statusbar never rendered (session name absent); screen tail={text[-300:]!r}")
if not spinner_cells():
    fail("the statusbar rendered but carries no spinner glyph — run-mode text is being dropped")
print("run mode: painter statusbar rendered with its spinner")

# 2. next_frame_ms: the same region must be re-asked, so the glyph moves.
seen = set()
deadline = time.time() + 12
while time.time() < deadline and len(seen) < 3:
    for ch in spinner_cells():
        seen.add(ch)
    time.sleep(0.25)
if len(seen) < 2:
    fail(f"the spinner never advanced (glyphs seen: {sorted(seen)!r}) — "
         "next_frame_ms is not being honoured, so no painter can animate")

# Distinct glyphs alone is a weak bar: a region repainted a few times per second
# still looks animated in a sampled screenshot while being far slower than the
# frame the painter asked for. next_frame_ms is 100ms here, so measure the real
# request RATE on an idle session.
n_before = sum(1 for _ in open(PLOG)) if os.path.exists(PLOG) else 0
t0 = time.time()
time.sleep(3.0)
n_after = sum(1 for _ in open(PLOG)) if os.path.exists(PLOG) else 0
rate = (n_after - n_before) / (time.time() - t0)
# The painter asks for 25ms frames. Measured: ~9/s when the loop arms its timer
# from the painter's next_frame_ms, ~5/s when it ticks on its own fixed 100ms
# cadence. The pipeline caps well below the requested 40/s -- one render/fetch
# round trip per frame -- so this guards the scheduler, not the ceiling.
if rate < 7.5:
    fail(f"painter is asked only {rate:.1f}x/s though it requested 25ms frames — "
         "the loop quantises animation to its own cadence, so a painter cannot "
         "drive its frame rate")
print(f"animation: {len(seen)} distinct frames, painter asked {rate:.1f}x/s")

# 3. surface mode: reveal the sprite and look for composited blocks.
before = screen.text().count("█")
os.write(master, b"\x1bs")
deadline = time.time() + 12
after = before
while time.time() < deadline:
    after = screen.text().count("█")
    if after > before:
        break
    time.sleep(0.3)
if after <= before:
    fail(f"surface mode never composited: block glyphs {before} -> {after}; "
         "an external tool cannot draw sprites")
print(f"surface mode: sprite composited ({before} -> {after} block cells)")

# 4. the configured view NAMES reached the painter (config is applied, not just
#    validated). sprite_view/float_title_view/container_title_view/stale_ms used
#    to pass validation with no builder field behind them, so renaming a view
#    silently kept the default.
asked = set()
if os.path.exists(PLOG):
    asked = {ln.strip() for ln in open(PLOG) if ln.strip()}
if "showcase.status" not in asked:
    fail(f"status.view was not applied — hexe asked for {sorted(asked)!r}")
if "showcase.sprite" not in asked:
    fail(f"status.sprite_view was not applied — hexe asked for {sorted(asked)!r}")
print(f"config: hexe asked for the configured view names {sorted(asked)!r}")

# 5. stale_ms: when the painter stops answering, its last frame must be marked
#    stale and drawn dimmed. Without this a dead painter leaves a frozen clock
#    that looks live, and stale_ms is inert config.
# hexe owns the painter, so stopping it means killing that child. Matched on
# the script path in its argv, which no other process on the machine carries.
# hexe restarts a child that dies, so killing this one is not enough to make
# the painter stay gone -- the copy is replaced with a program that exits at
# once, and then every restart dies too.
with open(PAINTER, "w") as fh:
    fh.write("import sys\nsys.exit(1)\n")
if subprocess.run(["pkill", "-f", PAINTER], capture_output=True).returncode != 0:
    fail("no painter child was running to stop -- hexe never spawned one")
del raw[:]
deadline = time.time() + 12
dimmed = False
while time.time() < deadline:
    if b"\x1b[2m" in bytes(raw):
        dimmed = True
        break
    time.sleep(0.3)
if not dimmed:
    fail("the bar never dimmed after the painter died — stale_ms has no effect, "
         "so a dead painter leaves a frozen bar looking live")
print("stale: content dimmed after the painter stopped answering")
if fe.poll() is not None:
    fail("frontend died while painting")

cleanup()
print("SMOKE PASS: an external painter draws chrome, animates, and composites sprites")
