#!/usr/bin/env python3
"""A cell remembers the namespace that wrote it.

This is the whole point of the per-cell tag (patches/ghostty-vt-ns.patch), and
it is the one thing the previous design could not do. hexe holds the colours and
the protocol; a program says which namespace its output belongs to by selecting
one and releasing it. Nothing infers regions from OSC 133 or anything else.

One pane prints three runs of the SAME colour index, with a namespace selected
for only the middle one:

    BEFORE  index 33, no namespace   -> stays indexed, host terminal resolves it
    INSIDE  index 33, namespace set  -> truecolor, from that namespace
    AFTER   index 33, released again -> indexed again

All three are on screen together. If the tag were per-pane rather than per-cell,
BEFORE and AFTER would recolour too; if it were not recorded at all, INSIDE
would stay indexed. Both failures are visible in the same capture.
"""
import atexit
import fcntl, os, pty, re, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"palcells{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(
        "local hexe = require('hexe')\n"
        "return hexe.setup({\n"
        "  palette = { namespaces = true },\n"
        # A split draws borders, which is chrome hexe paints itself. Bound here
        # so the test does not depend on whichever defaults are configured.
        "  keys = {\n"
        "    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.s },\n"
        "             hexe.action.split.vertical()),\n"
        "  },\n"
        "})\n"
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
    if capture is not None:
        path = os.path.join(WD, "capture.bin")
        with open(path, "wb") as fh:
            fh.write(capture)
        msg = f"{msg}\n  full frame capture: {path}"
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)


# The sequences go in a script, never on the typed line: a pane echoes what is
# typed, so a printf at the prompt puts the literal text on screen and an
# assertion looking for those bytes passes without a cell ever being coloured.
PAINT = os.path.join(WD, "paint.sh")
with open(PAINT, "w") as fh:
    fh.write(
        "printf '\\033]1330;set;2;33=#ff00aa\\033\\\\'\n"
        "printf 'BEFORE \\033[38;5;33mB\\033[0m\\n'\n"
        "printf '\\033]1330;use;2\\033\\\\'\n"
        "printf 'INSIDE \\033[38;5;33mI\\033[0m\\n'\n"
        # Still inside the namespace, but AFTER an SGR reset. The tag is
        # embedder state, not an SGR attribute; a terminal that clears it here
        # drops the namespace on every cell after the first `\\e[0m` a program
        # emits, which is all of them in practice.
        "printf 'PASTRESET \\033[38;5;33mP\\033[0m\\n'\n"
        "printf '\\033]1330;end\\033\\\\'\n"
        "printf 'AFTER \\033[38;5;33mA\\033[0m\\n'\n"
        # A full-screen app's shape: select, enter the alternate screen, release
        # while inside it, leave. Leaving restores the primary cursor, and the
        # restore must NOT resurrect the released selection — otherwise the
        # shell's own output afterwards is stamped with the app's namespace.
        "printf '\\033]1330;use;2\\033\\\\'\n"
        "printf '\\033[?1049h'\n"
        "printf '\\033]1330;end\\033\\\\'\n"
        "printf '\\033[?1049l'\n"
        "printf 'POSTALT \\033[38;5;33mZ\\033[0m\\n'\n"
    )

IDX33 = re.compile(rb"38[:;]5[:;]33")
MINE33 = re.compile(rb"38[:;]2[:;]{0,2}255[:;]0[:;]170")

seen = bytearray()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "palcells"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave)
procs.append(fe)


def drain(fd):
    while True:
        try:
            c = os.read(fd, 65536)
            if not c:
                return
        except OSError:
            return
        seen.extend(c)


threading.Thread(target=drain, args=(master,), daemon=True).start()
time.sleep(4.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

cols = 100


def repaint(settle=3.0):
    """Force a full redraw; vaxis only emits the cells that changed."""
    global cols
    del seen[:]
    cols = 99 if cols == 100 else 100
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, cols, 0, 0))
    time.sleep(settle)
    return bytes(seen)


os.write(master, f"sh {PAINT}\r".encode())
time.sleep(3.0)
frame = repaint()

for label in (b"BEFORE", b"INSIDE", b"PASTRESET", b"AFTER", b"POSTALT"):
    if label not in frame:
        fail(f"{label.decode()} never reached the screen", frame)


def styling_of(frame, label):
    """Which treatment the coloured glyph on `label`'s line received."""
    i = frame.rfind(label)
    window = frame[i:i + 60]
    if MINE33.search(window):
        return "namespaced"
    if IDX33.search(window):
        return "indexed"
    return "unstyled"

kinds = {l.decode(): styling_of(frame, l)
         for l in (b"BEFORE", b"INSIDE", b"PASTRESET", b"AFTER", b"POSTALT")}

if kinds["PASTRESET"] != "namespaced":
    fail(f"an SGR reset inside a selected namespace dropped the tag "
         f"(PASTRESET is {kinds['PASTRESET']}) — programs emit \\e[0m constantly, "
         f"so this loses the namespace on nearly every cell", frame)

if kinds["INSIDE"] != "namespaced":
    fail(f"the selected namespace never reached the cells written under it "
         f"(INSIDE is {kinds['INSIDE']}) — the per-cell tag is not being stamped", frame)

if kinds["POSTALT"] != "indexed":
    fail(f"a namespace released inside the alternate screen came back when the "
         f"app left it (POSTALT is {kinds['POSTALT']}) — the shell's own output "
         f"is being stamped with a released namespace", frame)

leaked = [k for k in ("BEFORE", "AFTER") if kinds[k] != "indexed"]
if leaked:
    fail(f"a namespace selected for one run of output recoloured cells written "
         f"outside it: {[(k, kinds[k]) for k in leaked]} should still be indexed. "
         f"The tag is being applied per pane rather than per cell", frame)

print(f"cells: {kinds} — the tag rides on the cell, not the pane")

# Recolouring the namespace afterwards must repaint its cells and only its cells.
r = subprocess.run([HEXE, "palette", "set", "--ns", "2", "33=#00ff88"],
                   env=env, cwd=WD, capture_output=True, text=True)
if r.returncode != 0:
    fail(f"`hexe palette set` failed: rc={r.returncode} {(r.stderr or r.stdout)[:200]}")
time.sleep(2.0)
frame = repaint()

RECOLOURED = re.compile(rb"38[:;]2[:;]{0,2}0[:;]255[:;]136")
i = frame.rfind(b"INSIDE")
if i < 0 or not RECOLOURED.search(frame[i:i + 60]):
    fail("recolouring the namespace did not repaint the cells written under it — "
         "scrollback is not resolving through the stored palette", frame)
if styling_of(frame, b"AFTER") != "indexed":
    fail("recolouring one namespace changed cells that never belonged to it", frame)
print("cells: recolouring a namespace repaints exactly its own cells")

# Slot 1 is hexe's own chrome, not a pane namespace. Setting it must recolour
# what HEXE draws -- the status bar, borders, float titles -- and nothing a
# program wrote. `use;1` from a pane must be refused, or an application could
# tag its output as chrome and be dragged along by a theme change.
CHROME = os.path.join(WD, "chrome.sh")
with open(CHROME, "w") as fh:
    fh.write(
        # An application trying to claim the chrome slot, then printing.
        "printf '\033]1330;use;1\033\\'\n"
        "printf 'CLAIMED \033[38;5;33mC\033[0m\n'\n"
        "printf '\033]1330;end\033\\'\n"
    )
os.write(master, f"sh {CHROME}\r".encode())
time.sleep(3.0)
frame = repaint()
if b"CLAIMED" not in frame:
    fail("CLAIMED never reached the screen", frame)
if styling_of(frame, b"CLAIMED") != "indexed":
    fail("a pane claimed hexe's reserved slot: its output resolved through the "
         "chrome namespace, so theming the chrome would drag it along", frame)
print("chrome: a pane cannot claim hexe's reserved slot")

# Split so hexe has borders to draw, then theme the index they use. Passive
# borders are palette 237 by default (config.zig BorderColor), so a truecolor
# emission of that value means chrome resolved through the reserved slot.
os.write(master, b"\x1b\x13")
time.sleep(2.5)
r = subprocess.run([HEXE, "palette", "set", "--ns", "1", "237=#123456"],
                   env=env, cwd=WD, capture_output=True, text=True)
if r.returncode != 0:
    fail(f"`palette set --ns 1` failed: rc={r.returncode} {(r.stderr or r.stdout)[:200]}")
time.sleep(2.0)
frame = repaint()
CHROME_RGB = re.compile(rb"[34]8[:;]2[:;]{0,2}18[:;]52[:;]86")
if not CHROME_RGB.search(frame):
    fail("theming hexe's slot changed nothing on screen: chrome is not resolving "
         "through the reserved namespace", frame)
print("chrome: theming slot 1 recolours what hexe draws")

if fe.poll() is not None:
    fail("frontend died during the checks")

cleanup()
print("PASS: cells carry the namespace that wrote them")
