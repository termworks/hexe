#!/usr/bin/env python3
"""Keybind-toggled NAMED floats must show their content every time.

This is the path a real hexe user hits constantly (ctrl+e explorer / yazi, an
alt+g scratch float): a float declared in config with a `key`, bound to
`hexe.action.float.toggle(...)`, toggled open and closed over and over.

It is a very different code path from `hexe mux float`: instead of creating a
pane each time, toggling HIDES and RE-REVEALS the same pane (with exclusivity
rules, per-cwd/sticky handoff, and a VT catch-up drain before reveal). A float
that is revealed but not repainted looks exactly like the reported symptom —
the window frame is there and the inside is blank.

Each round toggles the float open, asserts its content is on screen, toggles it
closed, and asserts the content is gone. The float's program keeps printing a
per-round marker so a *stale* repaint (showing an older round's content) is
caught too, not just a blank one.
"""
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "fto%d" % os.getpid()
WD = SC + "/fto%d" % os.getpid(); CF = SC + "/ftof%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
LOGDIR = SC + "/ftolog%d" % os.getpid(); os.makedirs(LOGDIR, exist_ok=True)

ROWS, COLS = 40, 120

# A float bound to alt+g. Its command tails a file, so the test can push a new
# marker into the float between toggles and prove the reveal repaints fresh.
FEED = os.path.join(WD, "feed.txt")
open(FEED, "w").write("")
open(CF + "/hexe/init.lua", "w").write("""
local hexe = require("hexe")
return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("ftolay", {
        root = "%s",
        tabs = { hexe.tab("main", { root = hexe.pane() }) },
        floats = {
          hexe.float("scratch", {
            key = "g",
            title = "scratch",
            command = "tail -f %s",
            size = { width = 60, height = 50 },
          }),
        },
      }),
    },
  },
  keys = {
    hexe.key({ hexe.key.alt, hexe.key['g'] }, hexe.action.float.toggle('g')),
  },
})
""" % (WD, FEED))

env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/ftostate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); env.pop("HEXE_PANE_UUID", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

_src = open(os.path.join(REPO, "scripts/smoke_float_content.py")).read()
_ns = {}
exec("import re\nROWS,COLS=%d,%d\n" % (ROWS, COLS) +
     _src[_src.index("class Screen:"):_src.index("m, sl = pty.openpty()")], _ns)
screen = _ns["Screen"]()

m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "fto", "--log", "debug",
                       "--logfile", LOGDIR + "/fe.log"],
                      stdin=sl, stdout=sl, stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs = [fe]

ALT_G = b"\x1bg"   # alt+g


def dpids():
    return subprocess.run(["pgrep", "-f", "daemon --instance " + INST],
                          capture_output=True, text=True).stdout.split()


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.kill()
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass


def dump():
    print("---- screen ----")
    for ln in screen.text().split("\n"):
        if ln.strip():
            print("  |" + ln.rstrip())
    print("---- end ----")


def fail(msg):
    print("FAIL:", msg)
    dump()
    print("logs kept in", LOGDIR)
    cleanup()
    sys.exit(1)


def answer_terminal_queries(chunk: bytes):
    out = b""
    if b"\x1b[6n" in chunk:
        out += b"\x1b[%d;%dR" % (screen.cy + 1, screen.cx + 1)
    if b"\x1b[5n" in chunk:
        out += b"\x1b[0n"
    if b"\x1b[c" in chunk or b"\x1b[0c" in chunk:
        out += b"\x1b[?62;22c"
    if out:
        try: os.write(m, out)
        except OSError: pass


def pump(t):
    d = time.time() + t
    while time.time() < d:
        r, _, _ = select.select([m], [], [], 0.1)
        if m in r:
            try: c = os.read(m, 262144)
            except OSError: return
            if not c: return
            screen.feed(c)
            answer_terminal_queries(c)


def wait_screen(tok, timeout):
    d = time.time() + timeout
    while time.time() < d:
        pump(0.2)
        if tok in screen.text():
            return True
    return False


def wait_gone(tok, timeout):
    d = time.time() + timeout
    while time.time() < d:
        pump(0.2)
        if tok not in screen.text():
            return True
    return False


print("instance=%s logs=%s" % (INST, LOGDIR))
pump(4.0)
if fe.poll() is not None:
    fail("frontend did not start")
if not wait_screen("$", 12):
    fail("no shell prompt in the tiled pane")
print("session up")

ROUNDS = int(os.environ.get("FLOAT_TOGGLE_ROUNDS", "8"))
for i in range(ROUNDS):
    tok = "TOGGLE%03d" % i
    # New content for this round; a stale reveal would show an older marker.
    with open(FEED, "a") as f:
        f.write(tok + "\n")
        f.flush()

    os.write(m, ALT_G)                       # open
    if not wait_screen(tok, 20):
        fail("round %d: float toggled OPEN but its content never appeared "
             "(blank float behind its border)" % i)

    os.write(m, ALT_G)                       # close
    if not wait_gone(tok, 20):
        fail("round %d: float toggled CLOSED but its content is still on screen" % i)
    print("round %d: toggled open (content shown) and closed (content gone)" % i)
    pump(0.5)

cleanup()
print("PASS: keybind-toggled named float shows fresh content every time (%d rounds)" % ROUNDS)
