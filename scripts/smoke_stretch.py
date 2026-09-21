#!/usr/bin/env python3
"""OSC 1332 stretch lines, checked on the screen a user would see.

A stretch line is stored at its minimum width and drawn at the pane's width,
so it has to come out full width when printed, after the terminal is resized
both ways, when scrolled back out of history, and after a reattach replays the
pane. A line wider than the pane is cut rather than wrapped.
"""
import atexit, fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"stretch{os.getpid()}")
CF = os.path.join(WD, "config")
ROWS = 30
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write("local hexe = require('hexe')\n")

env = {k: v for k, v in os.environ.items() if not k.startswith("HEXE_")}
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_CONFIG_HOME": CF, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

# The same screen reconstruction the float smokes use.
_src = open(os.path.join(REPO, "scripts/smoke_float_content.py")).read()
_ns = {}
exec("import re\nROWS,COLS=%d,%d\n" % (ROWS, 80) +
     _src[_src.index("class Screen:"):_src.index("m, sl = pty.openpty()")], _ns)
Screen = _ns["Screen"]

# Markers are written as octal escapes so the shell's echo of the command can
# never be mistaken for the line it prints.
STRETCH = r"printf '\033]1332;begin\033\\\123TL\033]1332;fill;-\033\\\123TR\033]1332;end\033\\\n'"
TWO = r"printf '\033]1332;begin\033\\\124LA\033]1332;fill;-\033\\\124MB\033]1332;fill;=\033\\\124RC\033]1332;end\033\\\n'"
TOO_WIDE = (r"printf '\033]1332;begin\033\\\116CUT" + "a" * 60 +
            r"\033]1332;fill;-\033\\" + "b" * 20 + r"\132\033]1332;end\033\\\n'")


class Term:
    def __init__(self, argv, cols):
        self.lock = threading.Lock()
        self.screen = Screen(ROWS, cols)
        self.cols = cols
        self.m, s = pty.openpty()
        fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, cols, 0, 0))
        self.p = subprocess.Popen(argv, stdin=s, stdout=s, stderr=s, env=env, cwd=WD,
                                  start_new_session=True)
        os.close(s)
        threading.Thread(target=self.drain, daemon=True).start()

    def drain(self):
        while True:
            try:
                chunk = os.read(self.m, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self.lock:
                self.screen.feed(chunk)

    def resize(self, cols):
        with self.lock:
            self.screen = Screen(ROWS, cols)
        self.cols = cols
        fcntl.ioctl(self.m, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, cols, 0, 0))
        try:
            os.kill(self.p.pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass

    def lines(self):
        with self.lock:
            return self.screen.text().split("\n")

    def type(self, text):
        os.write(self.m, text.encode())


term = None


def cleanup():
    r = subprocess.run(["pgrep", "-f", f"instance {INST}"], capture_output=True, text=True)
    for pid in r.stdout.split():
        try:
            os.kill(int(pid), signal.SIGKILL)
        except (ProcessLookupError, ValueError):
            pass
    if term is not None and term.p.poll() is None:
        term.p.kill()


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    screen = "\n".join(term.lines()) if term else ""
    print(f"FAIL: {msg}\n--- screen ---\n{screen}")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, lambda *_: fail("timed out"))
signal.alarm(170)


def wait_for(pred, timeout, what):
    end = time.time() + timeout
    while time.time() < end:
        got = pred()
        if got:
            return got
        time.sleep(0.2)
    fail(what)


def find(marker_a, marker_b):
    for row in term.lines():
        i, j = row.find(marker_a), row.find(marker_b)
        if i >= 0 and j > i:
            return row, i, j
    return None


def spans_width(marker_a, marker_b):
    """The row from `marker_a` to `marker_b` runs from edge to edge."""
    def check():
        got = find(marker_a, marker_b)
        if not got:
            return None
        row = got[0].rstrip()
        # Reaching the right edge is what "full width" means; where the line
        # starts depends on what the shell had already echoed on that row.
        if not row.endswith(marker_b) or len(row) < term.cols - 1:
            return None
        return got
    return check


def full_width(label):
    """Width of the fill once the stretch line reaches the edge and its gap is
    all fill. Retried, because hexe's own notifications briefly paint over the
    middle of the screen."""
    def check():
        got = spans_width("STL", "STR")()
        if not got:
            return None
        row, i, j = got
        gap = row[i + 3:j]
        return len(gap) if gap and set(gap) == {"-"} else None
    return wait_for(check, 15, f"the stretch line is not full width at {term.cols} columns ({label})")


def two_fills(label):
    def check():
        got = spans_width("TLA", "TRC")()
        if not got:
            return None
        row, i, j = got
        mid = row.find("TMB")
        if mid < 0:
            return None
        left, right = row[i + 3:mid], row[mid + 3:j]
        if set(left) != {"-"} or set(right) != {"="}:
            return None
        return abs(len(left) - len(right)) <= 1
    wait_for(check, 15, f"the two-fill line does not share {term.cols} columns evenly ({label})")


# ---- start, and the capability probe ---------------------------------------
term = Term([HEXE, "mux", "new", "-n", "stretch"], 80)
term.type(r"printf '\123TART\n'" + "\r")
wait_for(lambda: any("START" in r for r in term.lines()), 30, "the shell never became ready")

term.type(f"python3 {REPO}/scripts/demo_stretch.py\r")
wait_for(lambda: any("OSC 1332 supported" in r for r in term.lines()), 15,
         "hexe did not answer OSC 1332 ask with have")
print("ask: hexe answers have;1")

# ---- printed at 80, re-laid out at 120 and at 50 ---------------------------
term.type("clear\r")
time.sleep(1.0)
term.type(STRETCH + "\r")
wait_for(lambda: find("STL", "STR"), 10, "the stretch line never printed")
term.type(TWO + "\r")
at80 = full_width("printed")
two_fills("printed")
print(f"printed: full width at 80 ({at80} fill cells)")

term.resize(120)
at120 = full_width("widened")
two_fills("widened")
term.resize(50)
at50 = full_width("narrowed")
two_fills("narrowed")
if not at120 > at80 > at50:
    fail(f"the fill did not follow the width: 80->{at80}, 120->{at120}, 50->{at50}")
print(f"resize: re-laid out at 120 ({at120}) and at 50 ({at50})")

# ---- too wide: cut, never wrapped ------------------------------------------
term.type(TOO_WIDE + "\r")
wait_for(lambda: any("NCUT" in r for r in term.lines()), 10, "the too-wide line never printed")
time.sleep(0.5)
# The printed line reads NCUT (the command's echo reads \116CUT); a wrap would
# carry its b's onto the row below it.
lines = term.lines()
cut = next(i for i, r in enumerate(lines) if "NCUT" in r)
if cut + 1 < len(lines) and lines[cut + 1].lstrip().startswith("b"):
    fail("a stretch line wider than the pane wrapped onto the next row")
if len(lines[cut].rstrip()) > term.cols:
    fail("a stretch line wider than the pane was drawn past its edge")
print("too wide: cut at the edge, not wrapped")

# ---- scrollback: pushed out, widened, scrolled back ------------------------
term.resize(80)
term.type("clear\r")
time.sleep(0.8)
term.type(STRETCH + "\r")
full_width("before scrolling")
term.type("seq 1 60\r")
wait_for(lambda: find("STL", "STR") is None, 10, "the stretch line never scrolled out")
term.resize(120)
time.sleep(1.0)
for _ in range(40):
    term.type("\x1b[<64;20;10M")
    time.sleep(0.05)
    if find("STL", "STR"):
        break
back = full_width("scrolled back after a resize")
if back < 100:
    fail(f"a stretch line in scrollback kept its old width: {back} fill cells at 120 columns")
print(f"scrollback: re-laid out at 120 ({back})")

# ---- reattach: the pane is replayed, the line still stretches --------------
term.type("q")
term.type("\x1b[<65;20;10M" * 40)
term.type("clear\r")
time.sleep(0.8)
term.type(STRETCH + "\r")
full_width("before reattach")
os.kill(term.p.pid, signal.SIGKILL)
term.p.wait()
os.close(term.m)
time.sleep(1.0)
term = Term([HEXE, "mux", "attach", "stretch"], 100)
again = full_width("after reattach")
print(f"reattach: replayed and full width at 100 ({again})")

cleanup()
print("SMOKE PASS: stretch lines span the pane, follow resizes, scrollback and reattach, and never wrap")
