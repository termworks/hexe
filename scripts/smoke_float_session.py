#!/usr/bin/env python3
"""A float must land in the session that asked for it — never another one.

Two hexe sessions share one SES daemon. A float request carries the caller's
HEXE_SESSION. That id goes stale easily (a pane's shell inherits it at spawn,
and a reattach can change the session uuid afterwards), and SES used to fall
back to "any connected mux" when it could not resolve the id — so a float
launched in one session popped up inside a DIFFERENT one.

Asserts: (1) a float with session A's id appears in A and NOT in B;
         (2) a float with an unknown/stale id appears in NEITHER (no_mux).
"""
import fcntl, os, pty, select, shutil, struct, subprocess, sys, termios, time
REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "fs%d" % os.getpid(); WD = SC + "/fs%d" % os.getpid(); CF = SC + "/fsf%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
open(CF + "/hexe/init.lua", "w").write("return {}\n")
env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/fsstate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

def dpids():
    return subprocess.run(["pgrep", "-f", "daemon --instance " + INST], capture_output=True, text=True).stdout.split()

def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass

def fail(msg):
    print("FAIL:", msg); cleanup(); sys.exit(1)

def spawn(name, log):
    m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", name, "--log", "debug", "-L", log],
                         stdin=sl, stdout=sl, stderr=sl, env=env, cwd=WD, start_new_session=True)
    os.close(sl); procs.append(p); return p, m

def drain(m, t):
    d = time.time() + t
    while time.time() < d:
        r, _, _ = select.select([m], [], [], 0.1)
        if m in r:
            try: os.read(m, 262144)
            except OSError: return

def session_id_of(m, tag):
    """Read the pane's identity as a shell in that session actually sees it.

    Pane shells get HEXE_PANE_UUID from the pod (HEXE_SESSION is not set there),
    and that is exactly what the float CLI sends, so this mirrors reality."""
    p = WD + "/sid_" + tag
    try: os.unlink(p)
    except FileNotFoundError: pass
    deadline = time.time() + 25
    while time.time() < deadline:
        os.write(m, ('echo "$HEXE_PANE_UUID" > %s\r' % p).encode())
        d2 = time.time() + 3
        while time.time() < d2:
            drain(m, 0.2)
            if os.path.exists(p) and os.path.getsize(p) > 1:
                return open(p).read().strip()
    return None

LOGA = WD + "/a.log"; LOGB = WD + "/b.log"
feA, mA = spawn("sessA", LOGA); time.sleep(3.0)
feB, mB = spawn("sessB", LOGB); time.sleep(3.5)
if feA.poll() is not None or feB.poll() is not None:
    fail("a frontend did not start")

sidA = session_id_of(mA, "a")
sidB = session_id_of(mB, "b")
if not sidA or len(sidA) != 32: fail("could not read pane id for session A (got %r)" % sidA)
if not sidB or len(sidB) != 32: fail("could not read pane id for session B (got %r)" % sidB)
if sidA == sidB: fail("both sessions report the same id — cannot test routing")
print("session A=%s… B=%s…" % (sidA[:8], sidB[:8]))

def float_hits(log_before_a, log_before_b):
    """Which frontend logged a float request since the given offsets?"""
    def n(path, before):
        try: return open(path, errors="replace").read()[before:].count("handleFloatRequest")
        except FileNotFoundError: return 0
    return n(LOGA, log_before_a), n(LOGB, log_before_b)

def logsize(p):
    try: return len(open(p, errors="replace").read())
    except FileNotFoundError: return 0

# 1. Correct id -> must land in A only.
offA, offB = logsize(LOGA), logsize(LOGB)
r = subprocess.run([HEXE, "mux", "float", "--title=x", "--command", 'sleep 0.4; printf OK > "$HEXE_FLOAT_RESULT_FILE"'],
                   env=dict(env, HEXE_PANE_UUID=sidA), cwd=WD, capture_output=True, text=True, timeout=40)
for _ in range(20): drain(mA, 0.1); drain(mB, 0.1)
a, b = float_hits(offA, offB)
if a != 1 or b != 0:
    fail("float with session A's id routed wrong (A got %d, B got %d, out=%r)" % (a, b, r.stdout.strip()))
print("routing: float with A's id went to A only (A=%d B=%d)" % (a, b))

# 2. Unknown/stale id -> must land in NEITHER (no silent cross-session delivery).
offA, offB = logsize(LOGA), logsize(LOGB)
stale = "f" * 32  # a pane/session that does not exist
r = subprocess.run([HEXE, "mux", "float", "--title=y", "--command", 'sleep 0.4; printf LEAK > "$HEXE_FLOAT_RESULT_FILE"'],
                   env=dict(env, HEXE_PANE_UUID=stale), cwd=WD, capture_output=True, text=True, timeout=40)
for _ in range(20): drain(mA, 0.1); drain(mB, 0.1)
a, b = float_hits(offA, offB)
if a or b:
    fail("STALE session id leaked a float into another session (A=%d B=%d) — cross-session misroute" % (a, b))
print("isolation: float with a stale id went nowhere (A=%d B=%d), CLI said %r" % (a, b, (r.stdout + r.stderr).strip()[:60]))

cleanup()
print("SMOKE PASS: floats never cross sessions (correct id routes; stale id is refused)")
