#!/usr/bin/env python3
"""Typed input must survive a float opening/closing.

Regression guard for a long-standing (2026-03) bug: opening a float armed an
unbounded "drop the next stdin batch" flag, meant to swallow the leftover bytes
of the key that triggered the float. Nothing expired it, so when a float opened
without a trailing trigger key — every `hexe mux float` typed in a shell, and
any float the user did not immediately type into — the arm sat pending and ate
whatever was typed NEXT, seconds or minutes later. Symptoms: "I typed a command
and nothing happened", "the first key I press after a float does nothing".

Each round opens a float, waits for it to finish, then types a command and
requires it to be echoed. The old code failed the FIRST typed batch of every
round while the second worked — so a round types once and asserts, and the
rounds repeat to catch any residual off-by-one arming.

Assertions read a reconstructed SCREEN, not the raw pty bytes: the frontend
emits cell diffs, so a marker often arrives split across cursor moves even when
it rendered perfectly.
"""
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "iaf%d" % os.getpid()
WD = SC + "/iaf%d" % os.getpid(); CF = SC + "/iaff%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
open(CF + "/hexe/init.lua", "w").write("return {}\n")
LOGDIR = SC + "/iaflog%d" % os.getpid(); os.makedirs(LOGDIR, exist_ok=True)

ROWS, COLS = 40, 120
env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/iafstate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); env.pop("HEXE_PANE_UUID", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

# Reuse the screen emulator from the float-content smoke.
_src = open(os.path.join(REPO, "scripts/smoke_float_content.py")).read()
_ns = {}
exec("import re\nROWS,COLS=%d,%d\n" % (ROWS, COLS) +
     _src[_src.index("class Screen:"):_src.index("m, sl = pty.openpty()")], _ns)
screen = _ns["Screen"]()

m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "iaf", "--log", "debug",
                       "--logfile", LOGDIR + "/fe.log"],
                      stdin=sl, stdout=sl, stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs = [fe]


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


def fail(msg):
    print("FAIL:", msg)
    print("---- screen ----")
    for ln in screen.text().split("\n"):
        if ln.strip():
            print("  |" + ln.rstrip())
    print("logs kept in", LOGDIR)
    cleanup()
    sys.exit(1)


def pump(t):
    d = time.time() + t
    while time.time() < d:
        r, _, _ = select.select([m], [], [], 0.1)
        if m in r:
            try: c = os.read(m, 262144)
            except OSError: return
            if not c: return
            screen.feed(c)


def wait_screen(tok, timeout):
    d = time.time() + timeout
    while time.time() < d:
        pump(0.2)
        if tok in screen.text():
            return True
    return False


print("instance=%s logs=%s" % (INST, LOGDIR))
pump(3.5)
if fe.poll() is not None:
    fail("frontend did not start")
if not wait_screen("$", 10):
    fail("no shell prompt")

os.write(m, b"echo BASE_TOKEN\r")
if not wait_screen("BASE_TOKEN", 15):
    fail("typing did not work even before any float")
print("baseline: typing works")

ROUNDS = int(os.environ.get("INPUT_AFTER_FLOAT_ROUNDS", "5"))
for i in range(ROUNDS):
    mark = os.path.join(WD, "m%d.txt" % i)
    with open(mark, "w") as f:
        f.write("INFLOAT%d\n" % i)
    p = subprocess.Popen([HEXE, "mux", "float", "--title=f%d" % i,
                          "--command", "cat %s; sleep 0.8" % mark],
                         env=env, cwd=WD, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    procs.append(p)
    if not wait_screen("INFLOAT%d" % i, 20):
        fail("round %d: float content never rendered" % i)
    d = time.time() + 25
    while time.time() < d and p.poll() is None:
        pump(0.2)
    if p.poll() is None:
        p.kill()
        fail("round %d: float CLI never exited" % i)
    pump(1.5)

    # THE regression: the very first thing typed after the float must land.
    tok = "AFTER%d" % i
    os.write(m, ("echo %s\r" % tok).encode())
    if not wait_screen(tok, 15):
        fail("round %d: the first command typed after a float was swallowed "
             "(unbounded drop_next_input_batch regressed)" % i)
    print("round %d: float rendered, and input right after it landed" % i)

cleanup()
print("PASS: input survives float open/close (%d rounds)" % ROUNDS)
