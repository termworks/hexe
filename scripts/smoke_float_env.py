#!/usr/bin/env python3
"""A float's `add_env` / `add_path` must reach the program inside it.

`add_env` sets (or overrides) environment variables for that float only, and
`add_path` prepends directories to its PATH so a binary that is not on the
user's PATH becomes runnable inside the float. Both are composed in SES at
spawn time — the frontend only ships the request — so the only honest check is
what the float's own process sees.

The float here prints three things and the test asserts all of them on the
RENDERED screen:
  - a variable that exists only because of `add_env`
  - a variable that ALSO exists in the parent environment (inherit_env=true),
    proving `add_env` wins over what was inherited
  - the output of a binary reachable only via `add_path`
"""
import atexit
import signal
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "fev%d" % os.getpid()
WD = SC + "/fev%d" % os.getpid(); CF = SC + "/fevf%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
LOGDIR = SC + "/fevlog%d" % os.getpid(); os.makedirs(LOGDIR, exist_ok=True)

ROWS, COLS = 40, 120

# A binary that exists ONLY in this directory, which is not on anyone's PATH.
BINDIR = os.path.join(WD, "extrabin"); os.makedirs(BINDIR, exist_ok=True)
BIN = os.path.join(BINDIR, "hexesmokebin")
open(BIN, "w").write("#!/bin/sh\necho PATHBIN_OK\n")
os.chmod(BIN, 0o755)

# A directory that is ALREADY on the inherited PATH (twice, at the very end).
# Naming it in add_path must promote it to the front and collapse the copies,
# not silently do nothing.
DUPDIR = os.path.join(WD, "dupbin"); os.makedirs(DUPDIR, exist_ok=True)

open(CF + "/hexe/init.lua", "w").write("""
local hexe = require("hexe")
return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("fevlay", {
        root = "%s",
        tabs = { hexe.tab("main", { root = hexe.pane() }) },
        floats = {
          hexe.float("envfloat", {
            key = "g",
            title = "envfloat",
            attrs = { inherit_env = true },
            add_env = { SMOKE_ADDED = "ADDED_OK", SMOKE_SHADOWED = "CHILD_OK" },
            add_path = { "%s", "%s" },
            command = "sh -c 'echo A:$SMOKE_ADDED; echo S:$SMOKE_SHADOWED; hexesmokebin; case \\"$PATH\\" in %s:%s:*) echo ORDER_OK;; *) echo ORDER_BAD;; esac; echo N:$(echo \\"$PATH\\" | tr : \\"\\\\n\\" | grep -c \\"^%s$\\"); sleep 300'",
            size = { width = 70, height = 50 },
          }),
        },
      }),
    },
  },
  keys = {
    hexe.key({ hexe.key.alt, hexe.key['g'] }, hexe.action.float.toggle('g')),
  },
})
""" % (WD, BINDIR, DUPDIR, BINDIR, DUPDIR, DUPDIR))

env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/fevstate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1",
           # Already on PATH, twice, at the end — add_path must promote it.
           PATH=os.environ["PATH"] + ":" + DUPDIR + ":" + DUPDIR,
           # Present in the parent environment; add_env must override it.
           SMOKE_SHADOWED="PARENT_BAD")
env.pop("HEXE_SESSION", None); env.pop("HEXE_PANE_UUID", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

_src = open(os.path.join(REPO, "scripts/smoke_float_content.py")).read()
_ns = {}
exec("import re\nROWS,COLS=%d,%d\n" % (ROWS, COLS) +
     _src[_src.index("class Screen:"):_src.index("m, sl = pty.openpty()")], _ns)
screen = _ns["Screen"]()

m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "fev", "--log", "debug",
                       "--logfile", LOGDIR + "/fe.log"],
                      stdin=sl, stdout=sl, stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs = [fe]

ALT_G = b"\x1bg"


def dpids():
    return subprocess.run(["pgrep", "-f", "--", "daemon --instance " + INST],
                          capture_output=True, text=True).stdout.split()


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.kill()
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


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


print("instance=%s logs=%s" % (INST, LOGDIR))
pump(4.0)
if fe.poll() is not None:
    fail("frontend did not start")
if not wait_screen("$", 12):
    fail("no shell prompt in the tiled pane")
print("session up")

os.write(m, ALT_G)
if not wait_screen("A:ADDED_OK", 20):
    fail("add_env variable never reached the float's process")
print("add_env: variable visible inside the float")

if not wait_screen("S:CHILD_OK", 20):
    fail("add_env did not override the inherited value (parent env won)")
if "PARENT_BAD" in screen.text():
    fail("the inherited value is still what the float's process sees")
print("add_env: overrides an inherited variable")

if not wait_screen("PATHBIN_OK", 20):
    fail("add_path directory is not on the float's PATH (binary not found)")
print("add_path: binary from the added directory is runnable")

if not wait_screen("ORDER_OK", 20):
    fail("add_path dirs are not at the FRONT of PATH in declared order "
         "(a dir already on PATH must be promoted, not left where it was)")
if "ORDER_BAD" in screen.text():
    fail("add_path did not take priority over the inherited PATH")
print("add_path: added dirs are searched first, in declared order")

if not wait_screen("N:1", 20):
    fail("the promoted directory is duplicated on PATH (or missing)")
print("add_path: a dir already on PATH is promoted once, not duplicated")

cleanup()
print("PASS: float add_env and add_path reach the program inside the float")
