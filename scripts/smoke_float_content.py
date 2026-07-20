#!/usr/bin/env python3
"""Float CONTENT reliability: the float's program output must actually render.

Reported: opening a float sometimes shows only the border/frame — the program
inside never paints (intermittent). smoke_float.py only checks the float
*result* path, which can work fine while the content path silently drops the
pod's first output, so it never caught this.

Each round opens a float whose command prints a unique marker and asserts the
marker appears on the RENDERED SCREEN. It must be a screen check, not a grep of
the pty byte stream: vaxis emits cell diffs, so a marker frequently arrives
split across cursor moves ("CONTENT_1" + CUP + "_MARK") even though it rendered
perfectly. This script therefore reconstructs the screen with a tiny VT
emulator and searches the resulting rows.

Rounds alternate the two real launch paths:
  - external: `hexe mux float` run outside the mux (no HEXE_PANE_UUID)
  - in-pane:  typed into the pane shell, like the nvim/ctrl+e floats
    (source session resolved via HEXE_PANE_UUID)

The marker text lives in a FILE that the float `cat`s, so the marker never
appears in the typed command line — the shell's echo of the command can't
satisfy the assertion.
"""
import fcntl, os, pty, re, select, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "flc%d" % os.getpid()
WD = SC + "/flc%d" % os.getpid(); CF = SC + "/flcf%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
open(CF + "/hexe/init.lua", "w").write("return {}\n")
LOGDIR = SC + "/flclog%d" % os.getpid(); os.makedirs(LOGDIR, exist_ok=True)

ROWS, COLS = 40, 120

env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/flcstate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); env.pop("HEXE_PANE_UUID", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)


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


m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "flc", "--log", "debug",
                       "--logfile", LOGDIR + "/fe.log"],
                      stdin=sl, stdout=sl, stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs = [fe]
raw = open(LOGDIR + "/pty.raw", "wb")
screen = Screen()


def dpids():
    return subprocess.run(["pgrep", "-f", "daemon --instance " + INST],
                          capture_output=True, text=True).stdout.split()


def cleanup():
    raw.flush()
    for p in procs:
        if p.poll() is None:
            p.kill()
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass


def fail(msg):
    print("FAIL:", msg)
    print("logs kept in", LOGDIR)
    cleanup()
    sys.exit(1)


def pump(t):
    d = time.time() + t
    while time.time() < d:
        r, _, _ = select.select([m], [], [], 0.1)
        if m in r:
            try:
                c = os.read(m, 262144)
            except OSError:
                return
            if not c:
                return
            raw.write(c)
            screen.feed(c)


def wait_screen(marker, timeout):
    d = time.time() + timeout
    while time.time() < d:
        pump(0.2)
        if marker in screen.text():
            return True
    return False


print("instance=%s logs=%s" % (INST, LOGDIR))
pump(3.5)
if fe.poll() is not None:
    fail("frontend did not start")
os.write(m, b"echo BASE_OK_TOKEN\r")
if not wait_screen("BASE_OK_TOKEN", 15):
    fail("base pane never rendered")
print("base pane renders")

ROUNDS = int(os.environ.get("FLOAT_CONTENT_ROUNDS", "30"))
failures = []
for i in range(ROUNDS):
    token = "ZQJX%04dMARK" % i
    mfile = os.path.join(WD, "mark%d.txt" % i)
    with open(mfile, "w") as f:
        f.write(token + "\n")
    # The float cats the marker file: the token never appears in the command
    # line itself, so the shell's echo of the typed command cannot match.
    prog = "cat %s; sleep 1.0" % mfile
    mode = "external" if i % 2 == 0 else "in-pane"
    t0 = time.time()
    if mode == "external":
        p = subprocess.Popen([HEXE, "mux", "float", "--title=f%d" % i, "--command", prog],
                             env=env, cwd=WD, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(p)
        ok = wait_screen(token, 15)
        dd = time.time() + 20
        while time.time() < dd and p.poll() is None:
            pump(0.2)
        if p.poll() is None:
            p.kill()
    else:
        os.write(m, ("hexe mux float --title=f%d -c '%s'\r" % (i, prog)).encode())
        ok = wait_screen(token, 15)
        pump(2.5)
    dt = time.time() - t0
    if ok:
        print("round %d (%s): content rendered (%.1fs)" % (i, mode, dt))
    else:
        print("round %d (%s): *** CONTENT NEVER RENDERED ***" % (i, mode))
        if os.environ.get("FLOAT_CONTENT_DUMP"):
            print("---- screen ----")
            for ln in screen.text().split("\n"):
                if ln.strip():
                    print("  |" + ln.rstrip())
            print("---- end ----")
        failures.append((i, mode))
        pump(3.0)

raw.flush()
if failures:
    fail("%d/%d rounds blank: %s" % (len(failures), ROUNDS, failures))
cleanup()
print("PASS: float content rendered every round (%d rounds)" % ROUNDS)
