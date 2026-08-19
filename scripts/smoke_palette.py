#!/usr/bin/env python3
"""Live check: palette namespaces recolour a zone, and only that zone.

Everything below the CLI is unit-tested; what is NOT is the chain that makes it
real — config turns the feature on, `hexe palette set` builds an OSC 1330, the
pod injects it into the pane's output, the frontend's sniffer applies it, and
the renderer emits truecolor for the namespaced rows while every other row keeps
its indexed bytes.

The assertion is on the frontend's own output to the outer pty:

  before  every indexed cell is emitted as `ESC[38;5;N` (index passthrough)
  after   prompt-zone cells become `ESC[38;2;r;g;b` with the colour we set,
          and cells outside the zone are STILL `ESC[38;5;N`

That last clause is the point of the feature. A change that recoloured
everything would pass a naive "did the colour appear" check.

The pane is driven with explicit OSC 133 marks rather than a real prompt: the
zones are what hexe reads, and emitting them directly keeps the test about
palettes instead of about whichever shell happens to be installed.
"""
import atexit
import fcntl, os, pty, re, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"palette{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(
        "local hexe = require('hexe')\n"
        "return hexe.setup({ palette = { namespaces = true } })\n"
    )

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_CONFIG_HOME": CF, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
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


def fail(msg, capture=None):
    # A 400-byte tail is never enough to tell "the cell was not coloured" from
    # "the frame did not contain that row at all", so keep the whole capture.
    if capture is not None:
        path = os.path.join(WD, "capture.bin")
        with open(path, "wb") as fh:
            fh.write(capture)
        msg = f"{msg}\n  full frame capture: {path}"
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


seen = bytearray()


def drain(fd):
    while True:
        try:
            chunk = os.read(fd, 65536)
            if not chunk:
                return
        except OSError:
            return
        seen.extend(chunk)


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "pal"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave); procs.append(fe)
threading.Thread(target=drain, args=(master,), daemon=True).start()
time.sleep(4.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")


def hexe_cli(*args):
    return subprocess.run([HEXE, *args], env=env, cwd=WD, capture_output=True, text=True)


# `list` doubles as the capability probe M7's shell hook uses.
probe = hexe_cli("palette", "list")
if probe.returncode != 0:
    fail(f"`hexe palette list` failed inside a live session: rc={probe.returncode} "
         f"{probe.stdout!r} {probe.stderr!r}")
if "pane uuid=" not in probe.stdout:
    fail(f"`hexe palette list` named no panes: {probe.stdout!r}")
print("probe: `hexe palette list` reports the live pane")

# Paint two rows: one inside an OSC 133 prompt zone, one outside it. Colour 33
# in both, so any difference afterwards is the namespace and nothing else.
# The marks live in a script, never on the typed line. A pane echoes what is
# typed, so a `printf '\033[38;5;33m…'` typed at the prompt puts the literal
# text "38;5;33" on screen — and an assertion looking for those bytes then
# passes without a single cell ever being coloured.
PAINT = os.path.join(WD, "paint.sh")
with open(PAINT, "w") as fh:
    fh.write(
        "printf '\\033]133;A\\007'\n"
        "printf 'PROMPTROW \\033[38;5;33mIN\\033[0m\\n'\n"
        "printf '\\033]133;C\\007'\n"
        "printf 'OUTPUTROW \\033[38;5;33mOUT\\033[0m\\n'\n"
    )
MARK = f"sh {PAINT}\r"
cols = 100

# vaxis picks the SGR form from the outer terminal: `38:5:N` (colon, the
# ITU form) or `38;5;N` (legacy). Which one appears is not what is under test,
# so both count.
IDX33 = re.compile(rb"38[:;]5[:;]33")
SET33 = re.compile(rb"38[:;]2[:;]{0,2}255[:;]0[:;]170")
SET33_OUT = re.compile(rb"38[:;]2[:;]{0,2}0[:;]255[:;]0")
BG_DEFAULT = re.compile(rb"48[:;]2[:;]{0,2}0[:;]0[:;]123")


def repaint():
    """Force a full redraw and return everything the frontend then wrote.

    vaxis renders diffs, so a frame only carries cells that changed. Resizing
    the outer pty is the one lever that makes it emit the whole screen, which
    is what lets the assertions below look at recoloured AND untouched rows in
    the same capture.
    """
    global cols
    del seen[:]
    cols = 99 if cols == 100 else 100
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, cols, 0, 0))
    time.sleep(3.0)
    return bytes(seen)


del seen[:]
os.write(master, MARK.encode())
time.sleep(3.0)

before = repaint()
if not IDX33.search(before):
    fail("baseline: the indexed colour never reached the outer terminal as 38;5;N "
         "", before)
print("baseline: indexed cells are emitted as 38;5;N, untouched")

# Recolour ONLY the prompt namespace.
res = hexe_cli("palette", "set", "--ns", "prompt", "33=#ff00aa")
if res.returncode != 0:
    fail(f"`hexe palette set` failed: rc={res.returncode} {res.stdout!r} {res.stderr!r}")
time.sleep(1.5)

after = repaint()

if not SET33.search(after):
    fail("the prompt zone was not recoloured: no 38;2;255;0;170 in the repaint "
         "", after)
print("set: prompt-zone cells now emit truecolor 38;2;255;0;170")

# The output row used the SAME index and must be untouched — this is the
# per-zone claim the whole feature rests on.
if not IDX33.search(after):
    fail("cells outside the prompt zone lost their index passthrough: the palette "
         "leaked across zones", after)
print("isolation: cells outside the zone still emit 38;5;33")

# An application emitting the sequence itself, one byte at a time.
#
# The OSC sniffer buffers across reads, and a palette sequence is long enough
# that it WILL arrive split in practice. Emitting it a byte per write is the
# harshest version of the same thing.
SEQ_BIN = os.path.join(WD, "seq.bin")
with open(SEQ_BIN, "wb") as fh:
    # Real bytes from here, not shell escapes: `\033` inside a single-quoted
    # sh variable is four literal characters, so a script that "emits" it that
    # way tests nothing.
    fh.write(b"\x1b]1330;set;output;33=#00ff00\x1b\\")
DRIP = os.path.join(WD, "drip.sh")
with open(DRIP, "w") as fh:
    fh.write(
        f"size=$(wc -c < {SEQ_BIN})\n"
        "i=0\n"
        "while [ $i -lt $size ]; do\n"
        f"  dd if={SEQ_BIN} bs=1 skip=$i count=1 2>/dev/null\n"
        "  i=$((i+1))\n"
        "done\n"
    )
os.write(master, f"sh {DRIP}\r".encode())
time.sleep(3.0)
dripped = repaint()
if not SET33_OUT.search(dripped):
    fail("a sequence split across writes was not reassembled: the output zone "
         "never took the colour", dripped)
print("split: a byte-at-a-time sequence is reassembled and applied")

# `bg=` sets the namespace's DEFAULT background — what a cell that names no
# colour of its own gets. PLAN.md M4's exit criterion is exactly this command,
# and it used to be inert: the value was parsed, stored and even persisted, but
# the renderer's `.none` arms ignored it, so nothing on screen ever changed.
res = hexe_cli("palette", "set", "--ns", "output", "bg=#00007b")
if res.returncode != 0:
    fail(f"`hexe palette set bg=` failed: {res.stderr!r}")
time.sleep(1.5)
after_bg = repaint()
if not BG_DEFAULT.search(after_bg):
    fail("a namespace default background never reached the screen: `bg=` is "
         "parsed and stored but not rendered", after_bg)
print("defaults: bg= paints the output zone's unstyled cells")

# Read it back. `get` is answered from the session daemon's parked copy, so it
# also proves the frontend actually synced the change there — the thing a
# detach later depends on.
res = hexe_cli("palette", "get", "--ns", "prompt")
if res.returncode != 0:
    fail(f"`hexe palette get` failed: rc={res.returncode} {res.stderr!r}")
if "33=#ff00aa" not in res.stdout:
    fail(f"`hexe palette get` did not report the colour that was set: "
         f"stdout={res.stdout!r} stderr={res.stderr!r}")
print("get: the daemon reports the colour that was set")

# An index filter narrows it; a namespace filter excludes the others.
res = hexe_cli("palette", "get", "--ns", "output")
if "33=#ff00aa" in res.stdout:
    fail(f"`get --ns output` leaked the prompt namespace: {res.stdout!r}")
res = hexe_cli("palette", "list")
if "prompt=" not in res.stdout:
    fail(f"`hexe palette list` did not report the populated namespace: {res.stdout!r}")
print("get: filters by namespace, and list reports what is populated")

# The frontend must survive a namespace it was never told about.
res = hexe_cli("palette", "use", "--ns", "nosuchthing")
if res.returncode != 0:
    fail(f"`hexe palette use` on an undefined namespace failed: {res.stderr!r}")
time.sleep(1.0)
if fe.poll() is not None:
    fail("frontend died applying palette commands")
print("degradation: an undefined namespace is accepted and changes nothing")

# `reset` is the only undo the protocol has: `set` patches and `drop` releases
# the binding, so without this a mistyped colour is permanent.
res = hexe_cli("palette", "reset", "--ns", "prompt")
if res.returncode != 0:
    fail(f"`hexe palette reset` failed: {res.stderr!r}")
time.sleep(1.5)
after_reset = repaint()
if SET33.search(after_reset):
    fail("reset did not forget the colour: the prompt zone is still recoloured",
         after_reset)
if not IDX33.search(after_reset):
    fail("after reset the prompt zone should be back to index passthrough",
         after_reset)
print("reset: the prompt zone falls back to the terminal's own theme")

cleanup()
print("PASS: palette namespaces recolour one zone and leave the rest alone")
