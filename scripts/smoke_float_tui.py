#!/usr/bin/env python3
"""Floats running a REAL TUI-shaped program must paint their content.

Reported symptom: opening a float (ctrl+e explorer / yazi, nvim pickers)
sometimes shows only the window border with nothing inside, forever.

smoke_float_content.py covers a float that just prints and exits. That misses
how real TUIs behave: they enter the ALT SCREEN, query the terminal (cursor
position / DA1 / kitty keyboard) and BLOCK waiting for the reply, then paint.
If a float's query reply is not routed back to it, the program waits forever and
the float stays blank behind its border — exactly the reported symptom.

Each round runs a float that:
  1. enters the alt screen,
  2. emits a cursor-position query (DSR 6n) and blocks reading the reply,
  3. only then prints its marker.
The marker therefore proves the whole query/reply round trip worked, not just
that output flows one way. A round that hangs is the bug reproducing.
"""
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "ftu%d" % os.getpid()
WD = SC + "/ftu%d" % os.getpid(); CF = SC + "/ftuf%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
open(CF + "/hexe/init.lua", "w").write("return {}\n")
LOGDIR = SC + "/ftulog%d" % os.getpid(); os.makedirs(LOGDIR, exist_ok=True)

ROWS, COLS = 40, 120
env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/ftustate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); env.pop("HEXE_PANE_UUID", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

# A TUI-shaped program: alt screen -> query -> block for reply -> paint marker.
TUI = r'''
import os, sys, termios, tty, select
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
try:
    sys.stdout.write("\x1b[?1049h")          # alt screen, like yazi/nvim
    sys.stdout.write("\x1b[6n")              # DSR: ask cursor position
    sys.stdout.flush()
    reply = b""
    # Block for the reply, exactly like a real TUI's terminal probe.
    while b"R" not in reply:
        r, _, _ = select.select([fd], [], [], 8.0)
        if not r:
            break                            # timed out: reply never came back
        reply += os.read(fd, 64)
    got = b"R" in reply
    sys.stdout.write("\x1b[2J\x1b[H")
    sys.stdout.write("MARKER_%s_%s" % (os.environ["TUI_ID"], "QUERYOK" if got else "NOREPLY"))
    sys.stdout.flush()
    import time as _t; _t.sleep(1.0)
    sys.stdout.write("\x1b[?1049l")
    sys.stdout.flush()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
'''
TUI_PATH = os.path.join(WD, "tui.py")
open(TUI_PATH, "w").write(TUI)

_src = open(os.path.join(REPO, "scripts/smoke_float_content.py")).read()
_ns = {}
exec("import re\nROWS,COLS=%d,%d\n" % (ROWS, COLS) +
     _src[_src.index("class Screen:"):_src.index("m, sl = pty.openpty()")], _ns)
screen = _ns["Screen"]()

m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "ftu", "--log", "debug",
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


def answer_terminal_queries(chunk: bytes):
    """Act like a real terminal.

    hexe forwards a pane's terminal queries to ITS OWN stdout (our pty master)
    and routes the reply back to the asking pane. A bare pty answers nothing, so
    without this every float would report "no reply" — a harness artifact, not a
    product bug. Answer what a real terminal answers.
    """
    out = b""
    if b"\x1b[6n" in chunk:                          # DSR: cursor position
        out += b"\x1b[%d;%dR" % (screen.cy + 1, screen.cx + 1)
    if b"\x1b[5n" in chunk:                          # DSR: device status
        out += b"\x1b[0n"
    if b"\x1b[c" in chunk or b"\x1b[0c" in chunk:    # DA1
        out += b"\x1b[?62;22c"
    if out:
        try:
            os.write(m, out)
        except OSError:
            pass


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


def wait_any(toks, timeout):
    d = time.time() + timeout
    while time.time() < d:
        pump(0.2)
        t = screen.text()
        for tok in toks:
            if tok in t:
                return tok
    return None


print("instance=%s logs=%s" % (INST, LOGDIR))
pump(3.5)
if fe.poll() is not None:
    fail("frontend did not start")
if not wait_any(["$"], 10):
    fail("no shell prompt")

ROUNDS = int(os.environ.get("FLOAT_TUI_ROUNDS", "8"))
blanks, noreply = [], []
for i in range(ROUNDS):
    mode = "external" if i % 2 == 0 else "in-pane"
    cmd = "TUI_ID=%d python3 %s" % (i, TUI_PATH)
    if mode == "external":
        p = subprocess.Popen([HEXE, "mux", "float", "--title=t%d" % i, "--command", cmd],
                             env=env, cwd=WD, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(p)
    else:
        os.write(m, ("hexe mux float --title=t%d -c '%s'\r" % (i, cmd)).encode())
        p = None

    hit = wait_any(["MARKER_%d_QUERYOK" % i, "MARKER_%d_NOREPLY" % i], 25)
    if hit is None:
        print("round %d (%s): *** BLANK — TUI float never painted ***" % (i, mode))
        blanks.append((i, mode))
    elif hit.endswith("NOREPLY"):
        print("round %d (%s): painted, but the terminal query got NO REPLY" % (i, mode))
        noreply.append((i, mode))
    else:
        print("round %d (%s): TUI float painted, query round trip OK" % (i, mode))

    if p is not None:
        d = time.time() + 25
        while time.time() < d and p.poll() is None:
            pump(0.2)
        if p.poll() is None:
            p.kill()
    pump(2.5)

if blanks:
    fail("%d/%d TUI float rounds stayed BLANK behind their border: %s" % (len(blanks), ROUNDS, blanks))
if noreply:
    fail("%d/%d TUI float rounds never got their terminal query answered: %s "
         "(a real TUI would hang here instead of timing out)" % (len(noreply), ROUNDS, noreply))
cleanup()
print("PASS: TUI-shaped floats paint and their terminal queries round-trip (%d rounds)" % ROUNDS)
