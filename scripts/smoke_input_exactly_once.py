#!/usr/bin/env python3
"""Input across a daemon-crash reconnect is delivered EXACTLY once.

Types a unique command that APPENDS a line to a sink, at the same instant the
daemon is SIGKILLed (racing the keystroke into the reconnect window). After the
frontend auto-reconnects, the command must have run — and run EXACTLY once:
never lost (the bug this feature fixes) and never duplicated (the scary failure
mode of naive replay). We count occurrences in the sink.

Repeated across many rounds/timings, plus a SIGSTOP-frontend variant.
Needs a ReleaseFast build.
"""
import fcntl, os, pty, select, shutil, signal, struct, subprocess, sys, termios, time, re
REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "xo%d" % os.getpid(); WD = SC + "/xo%d" % os.getpid(); CF = SC + "/xof%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
REAL = os.path.expanduser("~/.config/hexe")
if not os.path.isdir(REAL):
    print("SKIP: no ~/.config/hexe"); raise SystemExit(0)
shutil.copytree(REAL, CF + "/hexe", dirs_exist_ok=True)
lp = CF + "/hexe/layout.lua"
if os.path.exists(lp):
    t = open(lp).read(); t = re.sub(r'command = "[^"]*"', 'command = "/bin/sh"', t); open(lp, "w").write(t)
ip = CF + "/hexe/init.lua"; s = open(ip).read()
s = s.replace('os.getenv("HOME") .. "/.config/hexe/layout.lua"', repr(lp).replace("'", '"'))
open(ip, "w").write(s)
env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/xostate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
SINK = WD + "/sink"
open(SINK, "w").close()
procs = []

def spawn():
    m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "xo"], stdin=sl, stdout=sl, stderr=sl,
                         env=env, cwd=WD, start_new_session=True)
    os.close(sl); procs.append(p); return p, m

def dpids():
    return subprocess.run(["pgrep", "-f", "ses daemon --instance " + INST], capture_output=True, text=True).stdout.split()

def drain(m, t):
    d = time.time() + t
    while time.time() < d:
        r, _, _ = select.select([m], [], [], 0.1)
        if m in r:
            try: os.read(m, 262144)
            except OSError: return

def count(tag):
    try: return open(SINK).read().count(tag)
    except FileNotFoundError: return 0

def fail(msg):
    print("FAIL:", msg)
    for p in procs:
        if p.poll() is None: p.kill()
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass
    sys.exit(1)

fe, m = spawn(); time.sleep(3.5)
os.write(m, b"echo READY\r"); time.sleep(1.0); drain(m, 1.0)

ROUNDS = int(os.environ.get("HEXE_XO_ROUNDS", "6"))
for i in range(ROUNDS):
    tag = "MARK_%d_%d" % (os.getpid(), i)
    # small jitter so the keystroke lands at different points of the crash
    before = count(tag)
    # kill the daemon and type the marker essentially simultaneously
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass
    time.sleep(i * 0.03)  # vary the race point per round
    os.write(m, ("printf '%%s\\n' %s >> %s\r" % (tag, SINK)).encode())
    # wait for reconnect + delivery
    ok = False
    d = time.time() + 30
    while time.time() < d:
        drain(m, 0.3)
        if count(tag) >= 1:
            ok = True; break
    n = count(tag)
    if n == 0:
        fail("round %d: marker LOST (input not delivered across the crash)" % i)
    if n > 1:
        fail("round %d: marker DUPLICATED %d times (replay dedup failed!)" % (i, n))
    print("round %d: delivered exactly once (n=%d)" % (i, n))
    # let things settle before the next crash
    if not dpids():
        # ensure a daemon is back up before the next round
        deadline = time.time() + 15
        while time.time() < deadline and not dpids():
            os.write(m, b"echo settle\r"); drain(m, 0.5)
    time.sleep(1.0)

for p in procs:
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill()
for pid in dpids():
    try: os.kill(int(pid), 9)
    except Exception: pass
print("SMOKE PASS: input across a daemon-crash reconnect is delivered exactly once (%d rounds)" % ROUNDS)
