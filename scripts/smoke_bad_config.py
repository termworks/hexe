#!/usr/bin/env python3
"""A broken config must degrade, never crash.

Found the hard way: a config with a Lua error made hexe SEGFAULT on startup.
The config-error path built its message with allocPrint, handed it to the
notification manager, and freed it on the next line — but a notification lives
for seconds, so the renderer walked freed bytes with a grapheme iterator and
died. Any user with a typo in their init.lua hit this.

The notification manager now copies messages. This asserts the whole flow:
hexe starts on a broken config, shows the error, and keeps running with a
usable shell.
"""
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "bcf%d" % os.getpid()
WD = SC + "/bcf%d" % os.getpid(); CF = SC + "/bcff%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
LOGDIR = SC + "/bcflog%d" % os.getpid(); os.makedirs(LOGDIR, exist_ok=True)

ROWS, COLS = 40, 120
env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/bcfstate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); env.pop("HEXE_PANE_UUID", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

_src = open(os.path.join(REPO, "scripts/smoke_float_content.py")).read()
_ns = {}
exec("import re\nROWS,COLS=%d,%d\n" % (ROWS, COLS) +
     _src[_src.index("class Screen:"):_src.index("m, sl = pty.openpty()")], _ns)

CASES = [
    ("lua runtime error", 'local hexe = require("hexe")\nreturn hexe.setup({ keys = nope.bad.field })\n'),
    ("lua syntax error", 'local hexe = require("hexe")\nreturn hexe.setup({ keys = { ,, } }\n'),
    ("wrong schema", 'local hexe = require("hexe")\nreturn hexe.setup({ ses = { layouts = "not-a-table" } })\n'),
    ("not a table", 'return 42\n'),
]

procs = []


def dpids():
    return subprocess.run(["pgrep", "-f", "daemon --instance " + INST],
                          capture_output=True, text=True).stdout.split()


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.kill()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: pass
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass


def fail(msg):
    print("FAIL:", msg)
    print("logs kept in", LOGDIR)
    cleanup()
    sys.exit(1)


print("instance=%s logs=%s" % (INST, LOGDIR))

for idx, (name, body) in enumerate(CASES):
    open(CF + "/hexe/init.lua", "w").write(body)
    screen = _ns["Screen"]()
    m, sl = pty.openpty()
    fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "bcf%d" % idx, "--log", "debug",
                          "--logfile", LOGDIR + "/fe%d.log" % idx],
                         stdin=sl, stdout=sl, stderr=sl, env=env, cwd=WD, start_new_session=True)
    os.close(sl)
    procs.append(p)

    def pump(t):
        d = time.time() + t
        while time.time() < d:
            r, _, _ = select.select([m], [], [], 0.1)
            if m in r:
                try: c = os.read(m, 262144)
                except OSError: return
                if not c: return
                screen.feed(c)

    # Let it start, show whatever error notification it wants, and keep running
    # well past the notification's lifetime (that is when the freed message used
    # to be rendered).
    pump(8.0)
    rc = p.poll()
    if rc is not None:
        sig = -rc if rc < 0 else None
        if sig == signal.SIGSEGV:
            fail("case '%s': hexe SEGFAULTED on a broken config" % name)
        fail("case '%s': hexe exited (rc=%s) instead of degrading" % (name, rc))

    # And it must still be a working terminal, not a frozen window.
    ok = False
    deadline = time.time() + 20
    while time.time() < deadline and not ok:
        os.write(m, b"echo BADCFG_OK_%d\r" % idx)
        d2 = time.time() + 3
        while time.time() < d2:
            pump(0.2)
            if "BADCFG_OK_%d" % idx in screen.text():
                ok = True
                break
    if not ok:
        fail("case '%s': hexe survived but the shell never responded" % name)

    print("case '%s': degraded cleanly, shell usable" % name)
    p.kill()
    try: p.wait(timeout=5)
    except subprocess.TimeoutExpired: pass
    try: os.close(m)
    except OSError: pass
    time.sleep(1.0)

cleanup()
print("PASS: broken configs degrade without crashing (%d cases)" % len(CASES))
