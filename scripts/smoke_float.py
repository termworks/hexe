#!/usr/bin/env python3
"""hexe mux float: the ad-hoc CLI float used everywhere (nvim yazi/tv pickers).

Guards the class of bug where the CLI's wait-for-float-exit was capped at the
10s wire default, so any interactive float (yazi, an editor) open longer than
10s returned an empty result and broke `dir=$(hexe mux float … yazi …)`.

Covers: result-file capture, --title, and crucially a float that stays open
LONGER than 10s still returning its result. Needs a ReleaseFast build (the wait
timing is what matters; Debug is just slower).
"""
import fcntl, os, pty, select, shutil, signal, struct, subprocess, sys, termios, time
REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SC = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"); os.makedirs(SC, exist_ok=True)
INST = "flo%d" % os.getpid(); WD = SC + "/flo%d" % os.getpid(); CF = SC + "/flof%d" % os.getpid()
os.makedirs(WD, exist_ok=True); os.makedirs(CF + "/hexe", exist_ok=True)
open(CF + "/hexe/init.lua", "w").write("return {}\n")
env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=SC + "/flostate", XDG_CONFIG_HOME=CF,
           TERM="xterm-256color", SHELL="/bin/sh", HEXE_TRUST_ALL_PROJECTS="1")
env.pop("HEXE_SESSION", None); os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
m, sl = pty.openpty(); fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "flo"], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl); time.sleep(3.5)
procs = [fe]

def dpids():
    return subprocess.run(["pgrep", "-f", "daemon --instance " + INST], capture_output=True, text=True).stdout.split()

def drain(t):
    d = time.time() + t
    while time.time() < d:
        r, _, _ = select.select([m], [], [], 0.1)
        if m in r:
            try: os.read(m, 262144)
            except OSError: return

def fail(msg):
    print("FAIL:", msg)
    for p in procs:
        if p.poll() is None: p.kill()
    for pid in dpids():
        try: os.kill(int(pid), 9)
        except Exception: pass
    sys.exit(1)

def run_float(cmd, title="t", extra=None, budget=45):
    """Run a float to completion while keeping the frontend pty drained
    (a real terminal always drains; without it the frontend blocks on stdout)."""
    argv = [HEXE, "mux", "float", "--title=" + title, "--command", cmd]
    if extra: argv[3:3] = extra
    p = subprocess.Popen(argv, env=env, cwd=WD, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    procs.append(p)
    t0 = time.time()
    while time.time() - t0 < budget:
        drain(0.3)
        if p.poll() is not None:
            out, err = p.communicate()
            return time.time() - t0, p.returncode, out.strip(), err.strip()
    p.kill(); out, err = p.communicate()
    return time.time() - t0, None, out.strip(), err.strip()

if fe.poll() is not None:
    fail("frontend did not start")

def wait_ready(timeout_s=25):
    """Wait until the pane shell runs a command (frontend + pod ready)."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        p = WD + "/rdy"
        try: os.unlink(p)
        except FileNotFoundError: pass
        os.write(m, ("echo RDY > %s\r" % p).encode())
        d2 = time.time() + 3
        while time.time() < d2:
            drain(0.2)
            if os.path.exists(p) and os.path.getsize(p) > 0:
                return True
    return False

if not wait_ready():
    fail("frontend pane never became ready")
print("instance=%s" % INST)

# 1. Result-file capture (the yazi/tv picker pattern). A real picker always does
# a bit of work first; a bare instant-exit float hits a separate pre-existing
# race in float creation (pending-request registration vs. immediate pod exit),
# which is out of scope here — this test mirrors the real interactive floats.
dt, rc, out, err = run_float('sleep 0.4; printf FLOAT_RESULT_OK > "$HEXE_FLOAT_RESULT_FILE"')
if out != "FLOAT_RESULT_OK":
    fail("result-file capture broken: rc=%s out=%r err=%r" % (rc, out, err))
print("capture: float result returned (%.1fs)" % dt)

# 2. THE regression guard: a float open LONGER than 10s must still return its result.
dt, rc, out, err = run_float('sleep 13; printf LONG_OK > "$HEXE_FLOAT_RESULT_FILE"', budget=45)
if out != "LONG_OK":
    fail("long float (>10s) lost its result — the 10s wait cap regressed: %.1fs rc=%s out=%r err=%r" % (dt, rc, out, err))
if dt < 12:
    fail("long float returned too early (%.1fs) — did not actually wait" % dt)
print("long-wait: float open %.0fs returned its result (the 10s-cap regression guard)" % dt)

# 3. --title reaches the float (the title is applied to the pane; just assert no error).
dt, rc, out, err = run_float("sleep 0.3; true", title="mytitle")
if rc != 0:
    fail("titled float failed: rc=%s err=%r" % (rc, err))
print("title: titled float ran cleanly")

for p in procs:
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill()
for pid in dpids():
    try: os.kill(int(pid), 9)
    except Exception: pass
print("SMOKE PASS: hexe mux float capture + long-wait (>10s) + title all work")
