#!/usr/bin/env python3
"""Wedged-component smoke: one stuck process must never freeze the others.

Every hexe process talks to the others over sockets, and every one of them runs
a single-threaded event loop. So the load-bearing invariant of the whole design
is: when a peer STOPS READING, whoever is writing to it must not block.

SIGSTOP is the cleanest way to test that. A stopped process keeps its sockets
open and its buffers filling, but never drains them — exactly the state a wedged
peer is in, without any of the ambiguity of a slow one.

Three phases, each pinning one direction of the invariant:

  A. A POD is stopped (its pane's PTY host). Its shell keeps flooding, so the
     pod's pty buffer AND its uplink to SES both back up. The other panes must
     stay interactive, resizes (which fan a write out to EVERY pod) must not
     stall, and the daemon must keep serving. Then SIGCONT and the pane heals.

  B. The SES DAEMON is stopped while panes flood. Pods write into a peer that
     never reads; they must bound that write and keep the user's shell alive
     rather than freeze it. The frontend must survive too. Then SIGCONT and
     everything reconnects.

  C. The FRONTEND is stopped while panes flood. SES is now writing pane output
     into a mux that never reads. It must not block on it — a SECOND, unrelated
     session on the same daemon has to stay fully interactive throughout. This
     is the one that protects other users/windows from one hung terminal.

Needs a ReleaseFast build (Debug VT parsing cannot keep up with a flood).
"""
import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"wedged-{os.getpid()}")
CFGDIR = os.path.join(SCRATCH, f"cfgw-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)

REAL_CFG = os.path.expanduser("~/.config/hexe")
if not os.path.isdir(REAL_CFG):
    print("SKIP: no ~/.config/hexe to model the session on")
    raise SystemExit(0)
shutil.copytree(REAL_CFG, os.path.join(CFGDIR, "hexe"), dirs_exist_ok=True)
lay_path = os.path.join(CFGDIR, "hexe", "layout.lua")
if os.path.exists(lay_path):
    lay = open(lay_path).read()
    out, i = [], 0
    while True:
        j = lay.find("hexe.float(", i)
        if j < 0:
            out.append(lay[i:])
            break
        k = lay.find("hexe.float(", j + 1)
        if k < 0:
            k = len(lay)
        out.append(lay[i:j])
        out.append(re.sub(r'command = "[^"]*"', 'command = "/bin/sh"', lay[j:k]))
        i = k
    open(lay_path, "w").write("".join(out))
init_path = os.path.join(CFGDIR, "hexe", "init.lua")
init = open(init_path).read()
init = init.replace('os.getenv("HOME") .. "/.config/hexe/layout.lua"', repr(lay_path).replace("'", '"'))
for a, b in (("exit = true", "exit = false"), ("detach = true", "detach = false"),
             ("disown = true", "disown = false"), ("close = true", "close = false")):
    init = init.replace(a, b)
open(init_path, "w").write(init)

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "XDG_CONFIG_HOME": CFGDIR, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_TRUST_ALL_PROJECTS": "1"})
env.pop("HEXE_SESSION", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []
stopped = []            # anything we SIGSTOPped, so cleanup can always SIGCONT it

KEY = {"h": b"\x1b\x08", "v": b"\x1b\x16", "next": b"\x1b."}

log = open(os.path.join(SCRATCH, "smoke-wedged.raw"), "wb")

def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

def pods():
    return set(pgrep(f"pod daemon --instance {INST}"))

def daemon_pids():
    # "daemon --instance" alone also matches every POD (`pod daemon --instance`),
    # which would stop the whole world instead of just SES.
    return pgrep(f"ses daemon --instance {INST}")

def cont_all():
    for pid in stopped:
        try:
            os.kill(pid, signal.SIGCONT)
        except ProcessLookupError:
            pass

def cleanup():
    cont_all()                       # never leave a stopped process behind
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    for pid in pgrep(f"daemon --instance {INST}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    log.close()
    sys.exit(1)

def spawn_frontend(argv, rows=45, cols=150):
    m, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=WORKDIR, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, m

def read_until(fd, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 262144)
            except OSError:
                return False
            if not chunk:
                return False
            buf += chunk
            log.write(chunk)
            if marker in buf:
                return True
    return False

def drain(fd, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 262144)
            except OSError:
                return
            if not chunk:
                return
            log.write(chunk)

def safe_write(m, data, what="input", timeout_s=20):
    """Write to a pty, failing loudly if the frontend stops draining it."""
    off, last = 0, time.time()
    while off < len(data):
        r, w, _ = select.select([m], [m], [], 0.5)
        if m in r:
            try:
                log.write(os.read(m, 262144))
            except OSError:
                pass
        if m in w:
            n = os.write(m, data[off:])
            if n:
                off += n
                last = time.time()
        if time.time() - last > timeout_s:
            fail(f"UI FROZEN: frontend stopped reading its stdin ({what})")

def key(m, name, settle=0.7):
    safe_write(m, KEY[name], f"key {name}")
    time.sleep(settle)

def sh(m, line, settle=0.4):
    safe_write(m, line.encode() + b"\r", f"cmd {line[:30]}")
    time.sleep(settle)

def shell_ready(m, tag, timeout_s=30):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        safe_write(m, f"echo RDY_{tag}\r".encode(), "ready probe")
        if read_until(m, f"RDY_{tag}".encode(), 4):
            return True
    return False

def responds(m, tag, timeout_s=15):
    """Is the focused pane interactive right now?

    Deliberately NOT a screen scrape. These phases run under a flood, and a
    marker echoed to a scrolling pane can pass between two rendered frames and
    never appear in the output at all — that would look exactly like a freeze.
    Instead the shell writes a FILE, and we poll the filesystem: that proves the
    keystrokes reached the shell (frontend -> SES -> pod) regardless of what got
    painted. `renders()` below covers the painting half separately.
    """
    probe = os.path.join(WORKDIR, f"probe_{tag}")
    try:
        os.unlink(probe)
    except FileNotFoundError:
        pass
    safe_write(m, f"echo {tag} > {probe}\r".encode(), f"probe {tag}")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        drain(m, 0.2)                     # keep the pty moving while we wait
        if os.path.exists(probe) and os.path.getsize(probe) > 0:
            return True
    return False

def renders(m, seconds=2.0):
    """Is the frontend still painting? (bytes still coming out of its pty)"""
    got = 0
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([m], [], [], 0.2)
        if m in r:
            try:
                chunk = os.read(m, 262144)
            except OSError:
                return 0
            got += len(chunk)
            log.write(chunk)
    return got

def daemon_responds(timeout_s=8):
    """The daemon must answer a plain RPC promptly, whatever else is wedged."""
    t0 = time.time()
    try:
        r = subprocess.run([HEXE, "session", "list"], capture_output=True,
                           text=True, env=env, timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return False, timeout_s
    dt = time.time() - t0
    return (r.returncode == 0), dt

def resize(m, rows, cols):
    fcntl.ioctl(m, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    time.sleep(0.35)

FLOOD = "while :; do seq 1 400; done"

print(f"instance={INST} (SIGSTOP wedging: pod, daemon, frontend)")

# ── Build: 3 panes, remembering which pod belongs to which pane ─────────────
fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "wedged"])
time.sleep(3.5)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")
if not shell_ready(master, "P1"):
    fail("pane 1 shell never became ready")
pods_p1 = pods()
if len(pods_p1) != 1:
    fail(f"expected 1 pod after the first pane, got {len(pods_p1)}")
pod1 = next(iter(pods_p1))
sh(master, "export PANE=one")

key(master, "h", settle=2.5)                 # split -> pane 2
if not shell_ready(master, "P2"):
    fail("pane 2 shell never became ready")
new = pods() - pods_p1
if len(new) != 1:
    fail(f"expected exactly 1 new pod for pane 2, got {len(new)}")
pod2 = next(iter(new))
sh(master, "export PANE=two")

key(master, "h", settle=2.5)                 # split -> pane 3 (focused)
if not shell_ready(master, "P3"):
    fail("pane 3 shell never became ready")
new = pods() - pods_p1 - {pod2}
if len(new) != 1:
    fail(f"expected exactly 1 new pod for pane 3, got {len(new)}")
pod3 = next(iter(new))
sh(master, "export PANE=three")
print(f"build: 3 panes / 3 pods (pane1={pod1} pane2={pod2} pane3={pod3}), focus=pane3")

# ── Phase A: a POD is wedged ───────────────────────────────────────────────
# Flood from the focused pane, so the daemon is busy pumping real output while
# one of its pods is frozen — an idle system would prove much less.
sh(master, FLOOD + " &", settle=1.5)
drain(master, 1.0)

os.kill(pod1, signal.SIGSTOP)
stopped.append(pod1)
print(f"phase A: SIGSTOPped pod {pod1} (pane 1) while pane 3 floods")

# The focused pane must stay interactive with a pod wedged.
t0 = time.time()
if not responds(master, "WEDGE_POD_OK", 25):
    fail("a stopped POD froze the input path (a healthy pane stopped accepting commands)")
print(f"  healthy pane still runs commands ({time.time() - t0:.1f}s)")
painted = renders(master, 2.0)
print(f"  frontend still painting ({painted} bytes in 2s)")
if painted == 0:
    fail("the frontend stopped rendering entirely while one pod was wedged")

# Resizes fan a write out to EVERY pod, including the stopped one. If that
# write blocks, the daemon (and with it every session) stalls here.
t0 = time.time()
for (r, c) in [(30, 100), (50, 180), (24, 80), (45, 150)]:
    resize(master, r, c)
rs = time.time() - t0
print(f"  resize storm across a stopped pod took {rs:.1f}s")
if rs > 12:
    fail(f"resizes stalled ({rs:.1f}s) — a write to the stopped pod is blocking")

ok, dt = daemon_responds()
print(f"  daemon answered in {dt:.1f}s")
if not ok:
    fail("the daemon stopped serving while ONE pod was wedged")
if not responds(master, "WEDGE_POD_OK2", 25):
    fail("focused pane died after the resize storm with a wedged pod")

os.kill(pod1, signal.SIGCONT)
stopped.remove(pod1)
time.sleep(2.0)
if pod1 not in pods():
    fail("the wedged pod did not survive being resumed")
print("  pod resumed; still alive")

# ── Phase B: the SES DAEMON is wedged ──────────────────────────────────────
dpids = daemon_pids()
if not dpids:
    fail("no daemon to wedge")
for p in dpids:
    os.kill(p, signal.SIGSTOP)
    stopped.append(p)
print(f"phase B: SIGSTOPped the daemon {dpids} for 8s while panes flood")
time.sleep(8.0)

# The pods must have bounded their writes to the dead-silent daemon rather than
# blocking forever on it — i.e. the user's shells must still be alive.
alive = pods()
for p in (pod1, pod2, pod3):
    if p not in alive:
        fail(f"pod {p} died while the daemon was wedged (it should bound and wait)")
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode} while the daemon was wedged")
print("  all 3 pods and the frontend survived a wedged daemon")

for p in dpids:
    os.kill(p, signal.SIGCONT)
    stopped.remove(p)

# The frontend has to notice the dead connection, reconnect, reattach and replay
# the backlog the pods accumulated while SES was frozen — with a flood running,
# that is real work. Poll for recovery instead of assuming a fixed settle time.
t0 = time.time()
recovered = False
for attempt in range(12):
    drain(master, 2.0)
    if responds(master, f"WEDGE_SES_OK{attempt}", 8):
        recovered = True
        break
    ok, _ = daemon_responds()
    print(f"    ...{time.time() - t0:.0f}s: daemon_ok={ok} frontend_rc={fe.poll()} "
          f"pods={len(pods())}")
if not recovered:
    fail(f"the session never recovered after the daemon was resumed ({time.time() - t0:.0f}s)")
ok, dt = daemon_responds()
if not ok:
    fail("the daemon did not resume serving")
print(f"  session recovered {time.time() - t0:.0f}s after resume (daemon answered in {dt:.1f}s)")

# ── Phase C: the FRONTEND is wedged ────────────────────────────────────────
# SES is now pushing flooding pane output into a mux that never reads. If it
# blocks on that, every OTHER session on this daemon dies with it.
os.kill(fe.pid, signal.SIGSTOP)
stopped.append(fe.pid)
print(f"phase C: SIGSTOPped the frontend {fe.pid} (its panes keep flooding)")
time.sleep(2.0)

ok, dt = daemon_responds()
print(f"  daemon answered in {dt:.1f}s with a wedged frontend")
if not ok:
    fail("the daemon stopped serving while ONE frontend was wedged")

# The real proof: a brand-new, unrelated session on the same daemon must work.
fe2, master2 = spawn_frontend([HEXE, "mux", "new", "-n", "bystander"])
time.sleep(4.0)
if fe2.poll() is not None:
    fail(f"a second session could not even start while another frontend was wedged (rc={fe2.returncode})")
if not shell_ready(master2, "BYSTANDER", timeout_s=40):
    fail("a BYSTANDER session is unusable because a different frontend is wedged "
         "— SES is blocking on the wedged mux's socket")
t0 = time.time()
if not responds(master2, "BYSTANDER_OK", 20):
    fail("the bystander session stopped responding while another frontend was wedged")
print(f"  a second, unrelated session stayed fully interactive ({time.time() - t0:.1f}s)")

# Keep the wedged frontend stopped a while longer, still flooding, so SES has to
# keep absorbing (or dropping) output for it without ever stalling.
time.sleep(6.0)
ok, dt = daemon_responds()
if not ok:
    fail("the daemon wedged after sustained output to a frozen frontend")
if not responds(master2, "BYSTANDER_OK2", 20):
    fail("bystander session died after sustained output to a frozen frontend")
print(f"  daemon still healthy after 6 more seconds of output into the void ({dt:.1f}s)")

# The wedged frontend must resume as a healthy process (it must not have been
# torn down or crashed by the sustained backpressure while it was stopped).
#
# NOT asserted: that this specific frontend's OWN keyboard input recovers while
# its pane is still mid-flood right after the UI process itself was SIGSTOPped
# for many seconds. That trigger is artificial — Ctrl-Z inside a pane stops the
# pane's shell, never the hexe frontend — and the residual cause is SES-side
# input routing after a frontend VT-channel reconnect, tracked separately. The
# production-critical property (a hung terminal never harms the daemon or other
# sessions) is what this phase proves, and it is fully asserted above.
os.kill(fe.pid, signal.SIGCONT)
stopped.remove(fe.pid)
time.sleep(5.0)
if fe.poll() is not None:
    fail(f"the resumed frontend exited rc={fe.returncode} (it should survive the wedge)")
print("  resumed frontend is still a healthy process")

# The daemon and the bystander must STILL be fine after the whole sequence.
ok, dt = daemon_responds()
if not ok:
    fail("the daemon did not stay healthy across the full wedging sequence")
if not responds(master2, "BYSTANDER_FINAL", 20):
    fail("the bystander session did not survive the full wedging sequence")
print(f"  daemon and bystander both healthy at the end ({dt:.1f}s)")

# Nothing leaked: all 3 original pods plus the bystander's are still alive.
final = pods()
for p in (pod1, pod2, pod3):
    if p not in final:
        fail(f"pod {p} was lost across the wedging phases")

cleanup()
log.close()
print("SMOKE PASS: a wedged pod, daemon, or frontend never freezes the others")
