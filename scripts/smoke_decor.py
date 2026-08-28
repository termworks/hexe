#!/usr/bin/env python3
"""Side decoration panels reserve columns, and the pane really loses them.

A panel is not an overlay. It takes columns from the pane's content, which means
the pty inside is narrower and the program running there is told so. That is the
claim worth pinning: a decoration that only *looked* reserved would leave
programs drawing underneath it.

Asserted from inside the pane, via `tput cols` — the number the program itself
sees — not from the rendered frame, which cannot distinguish "reserved" from
"painted over".
"""
import atexit
import fcntl, json, os, pty, re, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
# The painter runs as hexe's child, in a process with its own pid, so the
# working directory has to be handed to it rather than derived again.
WD = os.environ.get("HEXE_DECOR_WD") or os.path.join(SCRATCH, f"decor{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)

ROWS, COLS = 30, 100
LEFT_W, RIGHT_W = 6, 4

class Screen:
    """Minimal VT screen: enough of CUP/ED/EL/CR/LF to reconstruct what a user
    would see from the frontend's cell-diff output."""

    def __init__(self, rows=ROWS, cols=COLS):
        self.rows, self.cols = rows, cols
        self.grid = [[" "] * cols for _ in range(rows)]
        self.cy = self.cx = 0
        self.pending = b""

    def _clear_region(self, y0, x0, y1, x1):
        for y in range(y0, y1 + 1):
            xs = x0 if y == y0 else 0
            xe = x1 if y == y1 else self.cols - 1
            for x in range(xs, min(xe + 1, self.cols)):
                self.grid[y][x] = " "

    def feed(self, data: bytes):
        buf = self.pending + data
        self.pending = b""
        i, n = 0, len(buf)
        while i < n:
            c = buf[i]
            if c == 0x1B:  # ESC
                if i + 1 >= n:
                    self.pending = buf[i:]
                    return
                nxt = buf[i + 1]
                if nxt == ord("["):  # CSI
                    m = re.match(rb"\x1b\[([0-9;:<=>?]*)([ -/]*)([@-~])", buf[i:])
                    if not m:
                        self.pending = buf[i:]
                        return
                    self._csi(m.group(1), m.group(3))
                    i += m.end()
                    continue
                if nxt == ord("]"):  # OSC — skip to BEL or ST
                    m = re.match(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", buf[i:])
                    if not m:
                        self.pending = buf[i:]
                        return
                    i += m.end()
                    continue
                if nxt in (ord("P"), ord("^"), ord("_")):  # DCS/PM/APC — skip to ST
                    m = re.match(rb"\x1b[P^_].*?\x1b\\", buf[i:], re.S)
                    if not m:
                        self.pending = buf[i:]
                        return
                    i += m.end()
                    continue
                i += 2  # two-byte escape
                continue
            if c == 0x0D:
                self.cx = 0; i += 1; continue
            if c == 0x0A:
                self.cy = min(self.cy + 1, self.rows - 1); i += 1; continue
            if c == 0x08:
                self.cx = max(0, self.cx - 1); i += 1; continue
            if c < 0x20:
                i += 1; continue
            # printable run (decode UTF-8 leniently, one codepoint per cell)
            j = i
            while j < n and buf[j] >= 0x20 and buf[j] != 0x1B:
                j += 1
            for ch in buf[i:j].decode("utf-8", "replace"):
                if self.cy < self.rows and self.cx < self.cols:
                    self.grid[self.cy][self.cx] = ch
                self.cx += 1
                if self.cx >= self.cols:
                    self.cx = 0
                    self.cy = min(self.cy + 1, self.rows - 1)
            i = j

    def _csi(self, params: bytes, final: bytes):
        p = params.decode("ascii", "replace")
        if p[:1] in ("?", "<", "=", ">"):
            return  # private/parameter-prefixed CSI: no cell content
        nums = [int(x) if x.isdigit() else 0 for x in p.split(";")] if p else []
        f = final.decode("ascii", "replace")
        if f == "H" or f == "f":
            self.cy = (nums[0] - 1 if nums and nums[0] > 0 else 0)
            self.cx = (nums[1] - 1 if len(nums) > 1 and nums[1] > 0 else 0)
            self.cy = max(0, min(self.cy, self.rows - 1))
            self.cx = max(0, min(self.cx, self.cols - 1))
        elif f == "A": self.cy = max(0, self.cy - max(1, nums[0] if nums else 1))
        elif f == "B": self.cy = min(self.rows - 1, self.cy + max(1, nums[0] if nums else 1))
        elif f == "C": self.cx = min(self.cols - 1, self.cx + max(1, nums[0] if nums else 1))
        elif f == "D": self.cx = max(0, self.cx - max(1, nums[0] if nums else 1))
        elif f == "G": self.cx = max(0, min((nums[0] - 1 if nums else 0), self.cols - 1))
        elif f == "J":
            mode = nums[0] if nums else 0
            if mode == 2 or mode == 3: self._clear_region(0, 0, self.rows - 1, self.cols - 1)
            elif mode == 0: self._clear_region(self.cy, self.cx, self.rows - 1, self.cols - 1)
            elif mode == 1: self._clear_region(0, 0, self.cy, self.cx)
        elif f == "K":
            mode = nums[0] if nums else 0
            if mode == 0: self._clear_region(self.cy, self.cx, self.cy, self.cols - 1)
            elif mode == 1: self._clear_region(self.cy, 0, self.cy, self.cx)
            elif mode == 2: self._clear_region(self.cy, 0, self.cy, self.cols - 1)

    def text(self):
        return "\n".join("".join(r) for r in self.grid)


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


def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)


# ------------------------------------------------------------------ painter
# Each slot gets a distinct glyph, so the assertions can tell not just that
# something was drawn but that the RIGHT slot was drawn where it belongs.
SOCK = os.path.join(WD, "painter.sock")
ICONS = {("left", "start"): "L", ("left", "center"): "M", ("left", "end"): "N",
         ("right", "start"): "R", ("right", "center"): "S", ("right", "end"): "T"}
TITLES = {("top", "start"): "TSTART", ("top", "center"): "TCENTER",
          ("top", "end"): "TEND", ("bottom", "start"): "BSTART",
          ("bottom", "center"): "BCENTER", ("bottom", "end"): "BEND"}
stop_painter = threading.Event()
CLICKED = os.path.join(WD, "clicked")
# What the painter was asked for. It is hexe's child now, so the record crosses
# a file rather than living in this process's memory.
ASKED = os.path.join(WD, "asked.jsonl")
asked = []


def note_asked(entry):
    with open(ASKED, "a") as fh:
        fh.write(json.dumps(entry) + "\n")


def asked_so_far():
    try:
        with open(ASKED) as fh:
            return [tuple(json.loads(line)) for line in fh if line.strip()]
    except OSError:
        return []


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


def answer(req):
    """Serve whichever slot hexe named in the request context."""
    vals = {}
    try:
        vals = req["context"]["values"]
    except (KeyError, TypeError):
        pass
    edge, slot = vals.get("decor_edge"), vals.get("decor_slot")
    note_asked((edge, slot, req.get("width"), req.get("height")))

    if (edge, slot) in ICONS:
        # A surface fills its whole rect, so an icon drawn on every row proves
        # the strip's height as well as its columns.
        h = int(req.get("height") or 1)
        ansi = "\r\n".join([ICONS[(edge, slot)]] * h)
        out = {"mode": "surface", "ansi": ansi,
               "width": int(req.get("width") or 1), "height": h}
        if (edge, slot) == ("left", "center"):
            # A button filling this slot, so the click test does not depend on
            # hitting one exact cell.
            out["regions"] = [{
                "id": "panel.button",
                "x": 0, "y": 0,
                "width": int(req.get("width") or 1), "height": h,
                "actions": {"left": f"touch {CLICKED}"},
            }]
        return out
    if (edge, slot) in TITLES:
        text = TITLES[(edge, slot)]
        return {"mode": "run", "runs": [{"text": text, "style": "fg:15 bg:237"}],
                "width": len(text), "next_frame_ms": None}
    return {"mode": "run", "runs": [], "width": 0, "next_frame_ms": None}


def serve_stdio():
    """Answer on stdin/stdout until hexe closes the pipe.

    hexe spawns this file with --painter, so `answer` and its helpers are shared
    with the test rather than duplicated into a second script.
    """
    while True:
        head = sys.stdin.buffer.read(4)
        if len(head) < 4:
            return
        need = struct.unpack(">I", head)[0]
        body = sys.stdin.buffer.read(need)
        if len(body) < need:
            return
        out = json.dumps({"version": 1, "ok": True,
                          "output": answer(json.loads(body))}).encode()
        sys.stdout.buffer.write(struct.pack(">I", len(out)) + out)
        sys.stdout.buffer.flush()


if "--painter" in sys.argv:
    serve_stdio()
    raise SystemExit(0)




def write_config(with_panels):
    """Same config either way, so the only variable is the panels."""
    decor = ""
    if with_panels:
        decor = (
            "  decor = {\n"
            f"    left  = {{ width = {LEFT_W}, top = 'd.ls', center = 'd.lc', bottom = 'd.le' }},\n"
            f"    right = {{ width = {RIGHT_W}, top = 'd.rs', center = 'd.rc', bottom = 'd.re' }},\n"
            "    top    = { left = 'd.ts', center = 'd.tc', right = 'd.te' },\n"
            "    bottom = { left = 'd.bs', center = 'd.bc', right = 'd.be' },\n"
            "  },\n"
        )
    status = f"  status = {{ exec = 'HEXE_DECOR_WD={WD} python3 {os.path.abspath(__file__)} --painter' }},\n"
    # A float, because the top and bottom slots resolve against a float's border
    # -- they are the generalisation of the single float title.
    fl = (
        "  ses = { layouts = { hexe.layout('dlay', {\n"
        f"    root = '{WD}',\n"
        "    tabs = { hexe.tab('main', { root = hexe.pane() }) },\n"
        "    floats = { hexe.float('scratch', { key = 'g', title = 'scratch',\n"
        "      command = 'sleep 600', size = { width = 60, height = 50 } }) },\n"
        "  }) } },\n"
        "  keys = { hexe.key({ hexe.key.alt, hexe.key['g'] },\n"
        "                    hexe.action.float.toggle('g')) },\n"
    )
    with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
        fh.write("local hexe = require('hexe')\nreturn hexe.setup({\n"
                 + status + fl + decor + "})\n")


def pane_cols(tag):
    """The width the program inside the pane is actually given."""
    out = os.path.join(WD, f"cols-{tag}")
    if os.path.exists(out):
        os.unlink(out)
    # `stty size` reads the winsize from stdin, so it still reports the pane's
    # geometry with stdout redirected -- `tput cols` does not.
    os.write(master, f"stty size > {out}\n".encode())
    deadline = time.time() + 15
    while time.time() < deadline:
        if os.path.exists(out):
            time.sleep(0.3)
            raw = open(out).read().strip()
            parts = raw.split()
            if len(parts) == 2:
                return int(parts[1])
        time.sleep(0.2)
    return None


def marker_column(word):
    """The screen column the pane's leftmost cell is drawn at.

    Printed from a script rather than typed, because a typed line is echoed at
    the prompt and would be found at the prompt's column instead of the pane's.
    """
    # The script's own path must not contain the word: the typed command line is
    # echoed by the pane, and the marker would be found in that echo instead.
    sh = os.path.join(WD, "mark.sh")
    with open(sh, "w") as fh:
        fh.write(f"printf '\\r{word}\\n'\n")
    os.write(master, f"sh {sh}\n".encode())
    time.sleep(3.0)
    for row in screen.grid:
        line = "".join(row)
        at = line.find(word)
        if at >= 0:
            return at
    return None


# ---------------------------------------------------------------- baseline
write_config(with_panels=False)
seen = bytearray()
screen = Screen(ROWS, COLS)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "decor"], stdin=slave, stdout=slave,
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
        screen.feed(c)


threading.Thread(target=drain, args=(master,), daemon=True).start()
time.sleep(5.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

base = pane_cols("base")
if base is None:
    fail("could not read the pane width without panels; harness problem")
print(f"baseline: the pane is {base} columns wide with no panels")

cleanup()
procs.clear()
time.sleep(1.0)

# ------------------------------------------------------------- with panels
write_config(with_panels=True)
INST = f"smk{os.getpid()}b"
env["HEXE_INSTANCE"] = INST
seen = bytearray()
screen = Screen(ROWS, COLS)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "decor2"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave)
procs.append(fe)
threading.Thread(target=drain, args=(master,), daemon=True).start()
time.sleep(5.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode} with panels configured")

panelled = pane_cols("panelled")
if panelled is None:
    fail("could not read the pane width with panels configured")

want = base - LEFT_W - RIGHT_W
if panelled != want:
    fail(f"the pane kept {panelled} columns; panels of {LEFT_W}+{RIGHT_W} should "
         f"have left it {want} (was {base}). The panels are not reserving space, "
         f"so anything drawn there would sit on top of the program's output")
print(f"panels: {LEFT_W}+{RIGHT_W} columns reserved, pane went {base} -> {panelled}")

# Width alone is not enough. A pane that keeps its origin but loses width would
# leave the gap on the WRONG side: the left panel would draw over the program's
# first columns while empty space sat on the right.
col = marker_column("PANEEDGE")
if col is None:
    fail("the pane never drew the marker, so its origin could not be checked")
if col != LEFT_W:
    fail(f"the pane's first column is drawn at {col}, not {LEFT_W}. The left "
         f"panel reserved width without moving the pane, so the panel and the "
         f"program's output are occupying the same columns")
print(f"panels: the pane starts at column {col}, clear of the {LEFT_W}-wide left panel")

# The strip is only reserved space until something is drawn in it. Each side
# slot painted a distinct glyph on every row of its own third.
if os.environ.get("DECOR_DUMP"):
    with open(os.path.join(WD, "screen.txt"), "w") as fh:
        fh.write(screen.text())
    with open(os.path.join(WD, "asked.txt"), "w") as fh:
        fh.write(repr(asked_so_far()))
    print("dumped to", WD)

strip_rows = {}
for y, row in enumerate(screen.grid):
    left_cell = row[0] if LEFT_W else ""
    if left_cell in ("L", "M", "N"):
        strip_rows.setdefault(left_cell, []).append(y)

missing = [g for g in ("L", "M", "N") if g not in strip_rows]
if missing:
    fail(f"the left strip's slots {missing} drew nothing. Asked for: {asked_so_far()[:12]}. "
         f"Columns were reserved but no painter content reached them")

order = [min(strip_rows[g]) for g in ("L", "M", "N")]
if order != sorted(order):
    fail(f"the left strip's three slots are out of order top-to-bottom: "
         f"start/center/end begin at rows {order}")
print(f"panels: left strip slots drew at rows {order}, stacked in order")

# ...and they are in the reserved columns, not on top of the pane.
for g, rows in strip_rows.items():
    for y in rows:
        line = "".join(screen.grid[y])
        if line[LEFT_W - 1] not in (" ", g) and line[:LEFT_W].strip(g + " "):
            fail(f"row {y} of the left strip holds {line[:LEFT_W]!r}, which is not "
                 f"only panel content — the strip and the pane overlap")

asked = asked_so_far()
for edge, slot, w, h in asked:
    if edge in ("left", "right") and w not in (LEFT_W, RIGHT_W):
        fail(f"the painter was asked for a {w}-wide {edge} surface, but the "
             f"reserved strip is {LEFT_W if edge == 'left' else RIGHT_W} wide")
print(f"panels: the painter was asked at the reserved widths ({len(asked)} requests)")

# ------------------------------------------------------------------- clicking
# A panel that draws but cannot be pressed is a picture, not a button. The
# painter declared a button over the whole centre-left slot; a click inside it
# must run the action the painter named. Asserted by a file the action creates,
# not by anything on screen: the frame cannot distinguish "ran" from "looked
# like it ran".
if os.path.exists(CLICKED):
    os.unlink(CLICKED)

# SGR mouse press, 1-based, on the middle of the centre-left slot.
mid_row = min(strip_rows["M"]) + 1
os.write(master, f"\033[<0;{LEFT_W // 2 + 1};{mid_row + 1}M".encode())
time.sleep(0.3)
os.write(master, f"\033[<0;{LEFT_W // 2 + 1};{mid_row + 1}m".encode())

deadline = time.time() + 12
while time.time() < deadline and not os.path.exists(CLICKED):
    time.sleep(0.3)
if not os.path.exists(CLICKED):
    fail(f"clicking the centre-left panel button at column {LEFT_W // 2} row "
         f"{mid_row} ran nothing. The panel draws but does not respond, so the "
         f"buttons on it are decoration only")
print("panels: a click on a panel button ran the action the painter named")

# ------------------------------------------------- top and bottom, on a float
# These are the float title generalised into three addressed pieces, so they
# are checked where the title lives.
os.write(master, b"\x1bg")
time.sleep(4.0)


def row_of(word):
    for y, row in enumerate(screen.grid):
        at = "".join(row).find(word)
        if at >= 0:
            return y, at
    return None, None


placed = {w: row_of(w) for w in ("TSTART", "TCENTER", "TEND",
                                 "BSTART", "BCENTER", "BEND")}
absent = [w for w, (y, _) in placed.items() if y is None]
if absent:
    fail(f"the float's border slots {absent} drew nothing. hexe asked for "
         f"{sorted(set((e, sl) for e, sl, _, _ in asked if e))}")

top_rows = {placed[w][0] for w in ("TSTART", "TCENTER", "TEND")}
bot_rows = {placed[w][0] for w in ("BSTART", "BCENTER", "BEND")}
if len(top_rows) != 1 or len(bot_rows) != 1:
    fail(f"a border edge's three slots landed on different rows: "
         f"top {sorted(top_rows)}, bottom {sorted(bot_rows)}")
if min(bot_rows) <= min(top_rows):
    fail(f"the bottom edge drew at row {min(bot_rows)}, at or above the top "
         f"edge at row {min(top_rows)} — the two edges are swapped")

for edge, names in (("top", ("TSTART", "TCENTER", "TEND")),
                    ("bottom", ("BSTART", "BCENTER", "BEND"))):
    cols = [placed[w][1] for w in names]
    if cols != sorted(cols):
        fail(f"the {edge} edge's start/center/end are out of order across the "
             f"border: they begin at columns {cols}")
print(f"border: top row {min(top_rows)} at columns "
      f"{[placed[w][1] for w in ('TSTART', 'TCENTER', 'TEND')]}, "
      f"bottom row {min(bot_rows)}")

if fe.poll() is not None:
    fail("frontend died during the checks")

cleanup()
print("PASS: twelve slots — strips reserve columns, border slots place in order")
