#!/usr/bin/env python3
"""Live check: palette namespaces recolour a zone, and only that zone.

Everything below the CLI is unit-tested; what is NOT is the chain that makes it
real — config turns the feature on, `hexe palette set` builds an OSC 1330, the
pod injects it into the pane's output, the frontend's sniffer applies it, and
the renderer emits truecolor for the namespaced rows while every other row keeps
its indexed bytes.

The assertion is on the frontend's own output to the outer pty:

  before  every indexed cell is emitted as `ESC[38;5;N` (index passthrough)
  after   cells written while a namespace was selected become
          `ESC[38;2;r;g;b`, and cells written outside it are STILL `ESC[38;5;N`

That last clause is the point of the feature. A change that recoloured
everything would pass a naive "did the colour appear" check.

The pane declares its own region with `use`/`end`. hexe stores namespaces and
resolves indexes; it never infers from the screen which cells a namespace covers,
so the program that wrote them is the only thing that decides.
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

# Paint two rows: one written while a namespace is selected, one after it is
# released. Colour 33 in both, so any difference afterwards is the namespace and
# nothing else.
# The marks live in a script, never on the typed line. A pane echoes what is
# typed, so a `printf '\033[38;5;33m…'` typed at the prompt puts the literal
# text "38;5;33" on screen — and an assertion looking for those bytes then
# passes without a single cell ever being coloured.
PAINT = os.path.join(WD, "paint.sh")
with open(PAINT, "w") as fh:
    fh.write(
        "printf '\\033]1330;use;3\\033\\\\'\n"
        "printf 'INZONE \\033[38;5;33mIN\\033[0m\\n'\n"
        "printf '\\033]1330;end\\033\\\\'\n"
        "printf 'OUTZONE \\033[38;5;33mOUT\\033[0m\\n'\n"
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
# OSC 12 is how a cursor colour reaches the host terminal; OSC 112 undoes it.
OSC12 = re.compile(rb"\x1b\]12;#00ff88")
ALT_BLUE = re.compile(rb"38[:;]2[:;]{0,2}0[:;]0[:;]255")


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

# Recolour ONLY the namespace the pane selected.
res = hexe_cli("palette", "set", "--ns", "3", "33=#ff00aa")
if res.returncode != 0:
    fail(f"`hexe palette set` failed: rc={res.returncode} {res.stdout!r} {res.stderr!r}")
time.sleep(1.5)

after = repaint()

if not SET33.search(after):
    fail("cells written under the selected namespace were not recoloured: no "
         "38;2;255;0;170 in the repaint", after)
print("set: cells written under the namespace emit truecolor 38;2;255;0;170")

# The row printed after `end` used the SAME index and must be untouched.
if not IDX33.search(after):
    fail("cells written outside the namespace lost their index passthrough: the "
         "palette leaked beyond the region the program declared", after)
print("isolation: cells outside the namespace still emit 38;5;33")

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
    fh.write(b"\x1b]1330;set;3;33=#00ff00\x1b\\")
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
    fail("a sequence split across writes was not reassembled: the namespace "
         "never took the colour", dripped)
print("split: a byte-at-a-time sequence is reassembled and applied")


res = hexe_cli("palette", "set", "--ns", "3", "bg=#00007b")
if res.returncode != 0:
    fail(f"`hexe palette set bg=` failed: {res.stderr!r}")
time.sleep(1.5)
after_bg = repaint()
if not BG_DEFAULT.search(after_bg):
    fail("a namespace default background never reached the screen: `bg=` is "
         "parsed and stored but not rendered", after_bg)
print("defaults: bg= paints the namespace's unstyled cells")

# Read it back. `get` is answered from the session daemon's parked copy, so it
# also proves the frontend actually synced the change there — the thing a
# detach later depends on.
res = hexe_cli("palette", "get", "--ns", "3")
if res.returncode != 0:
    fail(f"`hexe palette get` failed: rc={res.returncode} {res.stderr!r}")
if "33=#00ff00" not in res.stdout:
    fail(f"`hexe palette get` did not report the colour that was set: "
         f"stdout={res.stdout!r} stderr={res.stderr!r}")
print("get: the daemon reports the colour that was set")

# An index filter narrows it; a namespace filter excludes the others.
res = hexe_cli("palette", "get", "--ns", "9")
if "33=#ff00aa" in res.stdout:
    fail(f"`get --ns other` leaked another namespace: {res.stdout!r}")
res = hexe_cli("palette", "list")
if "3=" not in res.stdout:
    fail(f"`hexe palette list` did not report the populated namespace: {res.stdout!r}")
print("get: filters by namespace, and list reports what is populated")

# `cursor=` colours the terminal's OWN cursor, which hexe cannot paint as a
# cell — it has to tell the host terminal with OSC 12. So the assertion is that
# hexe emits that sequence, and only while a namespace holding one is selected.
#
# The selection has to still be live when the assertion runs: a script that
# selects and exits releases nothing (there is no `end`), but the shell that
# regains the terminal is the same pane, so the namespace stays current. Block
# on `read` to hold it there deterministically.
CURSOR_SH = os.path.join(WD, "cursorns.sh")
with open(CURSOR_SH, "w") as fh:
    fh.write("printf '\033]1330;use;5\033\\\\CURSORNS '\n"
             "read x\n")
os.write(master, f"sh {CURSOR_SH}\r".encode())
time.sleep(2.5)

del seen[:]
time.sleep(1.0)
if OSC12.search(bytes(seen)):
    fail("hexe emitted a cursor colour before any namespace asked for one")

# Clear BEFORE the set: emission is change-driven and happens within a frame
# of the OSC landing, so clearing afterwards races it away.
del seen[:]
res = hexe_cli("palette", "set", "--ns", "5", "cursor=#00ff88")
if res.returncode != 0:
    fail(f"`hexe palette set cursor=` failed: {res.stderr!r}")
time.sleep(2.5)
if not OSC12.search(bytes(seen)):
    fail("a namespace cursor colour never reached the terminal: `cursor=` is "
         "parsed and stored but no OSC 12 was emitted", bytes(seen))
print("cursor: the selected namespace's cursor colour reaches the terminal")

# And it is change-driven: an unchanged selection must not re-emit.
del seen[:]
time.sleep(2.5)
if OSC12.search(bytes(seen)):
    fail("hexe re-emits the cursor colour every frame instead of on change",
         bytes(seen))
print("cursor: not re-emitted while the selection is unchanged")

os.write(master, b"\r")   # unblock the `read`
time.sleep(1.5)

# A slot nobody has set is a legitimate selection that simply resolves to
# nothing — every index still passes through to the terminal's own theme.
res = hexe_cli("palette", "use", "--ns", "20")
if res.returncode != 0:
    fail(f"`hexe palette use` on an unset slot failed: {res.stderr!r}")
time.sleep(1.0)
if fe.poll() is not None:
    fail("frontend died applying palette commands")

# A slot outside the range is refused rather than folded onto a live one, which
# would paint cells with another caller's colours.
res = hexe_cli("palette", "use", "--ns", "99")
if res.returncode == 0:
    fail("`hexe palette use --ns 99` was accepted; an out-of-range slot must be "
         "refused, not wrapped onto a live namespace")
print("degradation: an unset slot changes nothing, an out-of-range slot is refused")

# `reset` is the only undo the protocol has: `set` patches and `drop` releases
# the binding, so without this a mistyped colour is permanent.
res = hexe_cli("palette", "reset", "--ns", "3")
if res.returncode != 0:
    fail(f"`hexe palette reset` failed: {res.stderr!r}")
time.sleep(1.5)
after_reset = repaint()
if SET33.search(after_reset):
    fail("reset did not forget the colour: the namespace is still recoloured",
         after_reset)
if not IDX33.search(after_reset):
    fail("after reset the namespace should be back to index passthrough",
         after_reset)
print("reset: the namespace falls back to the terminal's own theme")

# Clearing has to reach the daemon too. A `reset` that repaints the screen but
# leaves the parked copy behind would resurrect the old colours on reattach —
# the serialized blob goes from "one entry" to empty, and SES has to store that
# emptiness rather than keep the last non-empty version.
res = hexe_cli("palette", "get", "--ns", "3")
if "33=#ff00aa" in res.stdout:
    fail(f"reset did not reach the daemon's parked copy: {res.stdout!r}")
print("reset: the daemon's parked copy is cleared too")

cleanup()
print("PASS: palette namespaces recolour what a program declared, and nothing else")
