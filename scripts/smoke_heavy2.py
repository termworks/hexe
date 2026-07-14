#!/usr/bin/env python3
"""Heavy-load smoke #2: multi-tab churn, resize storms, float thrashing.

Complements smoke_heavy.py (which builds one fat tab and chaos-tests it).
This one attacks the dimensions that harness does NOT touch:

  - MULTIPLE TABS, each with splits, one holding a fullscreen app
  - RESIZE STORMS: the terminal is resized repeatedly (SIGWINCH) while
    fullscreen apps and floods are running — every pane must re-layout
  - FLOAT THRASHING: rapid open/close/switch of several floats, including
    while output is flooding
  - CONCURRENT LOAD: several panes producing output at once, with pastes
    landing in some of them
  - DETACHED OUTPUT: huge output generated WHILE the session is detached
    (the pod ring must absorb it and replay a bounded window)

After each phase the session must remain fully alive: every pane responds,
pods are intact, the daemon lives, and no junk records accumulate.

Needs a ReleaseFast build (Debug VT parsing cannot keep up with this).
Env: HEXE_STRESS_SEED, HEXE_STRESS_ROUNDS.
"""
import fcntl
import json
import os
import pty
import random
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
WORKDIR = os.path.join(SCRATCH, f"heavy2-{os.getpid()}")
CFGDIR = os.path.join(SCRATCH, f"cfg2-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
SEED = int(os.environ.get("HEXE_STRESS_SEED", str(os.getpid())))
ROUNDS = int(os.environ.get("HEXE_STRESS_ROUNDS", "4"))
random.seed(SEED)

# Model the session on the user's REAL config (same keybinds/float defs),
# with float commands swapped to /bin/sh so the test needs no extra tools.
REAL_CFG = os.path.expanduser("~/.config/hexe")
if not os.path.isdir(REAL_CFG):
    print("SKIP: no ~/.config/hexe to model the heavy session on")
    raise SystemExit(0)
shutil.copytree(REAL_CFG, os.path.join(CFGDIR, "hexe"), dirs_exist_ok=True)
lay_path = os.path.join(CFGDIR, "hexe", "layout.lua")
if os.path.exists(lay_path):
    lay = open(lay_path).read()
    # Swap ONLY float commands (inside hexe.float(...) blocks) to /bin/sh, so
    # the test needs no external tools; leave segment commands alone.
    def swap_float_cmds(text):
        out = []
        i = 0
        while True:
            j = text.find("hexe.float(", i)
            if j < 0:
                out.append(text[i:])
                break
            k = text.find("hexe.float(", j + 1)
            if k < 0:
                k = len(text)
            block = text[j:k]
            block = re.sub(r'command = "[^"]*"', 'command = "/bin/sh"', block)
            out.append(text[i:j])
            out.append(block)
            i = k
        return "".join(out)
    lay = swap_float_cmds(lay)
    open(lay_path, "w").write(lay)
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

KEY = {  # ESC + ctrl-<x> is the legacy encoding of ctrl+alt+<x>
    "h": b"\x1b\x08", "v": b"\x1b\x16", "d": b"\x1b\x04",
    "t": b"\x1b\x14", "x": b"\x1b\x18", "next": b"\x1b.",
    "1": b"\x1b1", "2": b"\x1b2", "3": b"\x1b3",
    "up": b"\x1b\x1b[A", "down": b"\x1b\x1b[B",
    "left": b"\x1b\x1b[D", "right": b"\x1b\x1b[C",
}

def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []

def pod_count():
    return len(pgrep(f"pod daemon --instance {INST}"))

master = None
fe = None

def spawn_frontend(argv, rows=45, cols=150):
    global master
    m, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=WORKDIR, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, m

def resize(m, rows, cols):
    fcntl.ioctl(m, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    # The frontend polls its size; give it a beat to re-layout every pane.
    time.sleep(0.35)

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
    """Write to the pty, failing loudly if the frontend stops draining it.

    A frozen frontend stops reading its stdin; a plain os.write() then blocks
    forever and the harness would hang instead of reporting the freeze.
    """
    off = 0
    last = time.time()
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
            state = "dead" if (fe is not None and fe.poll() is not None) else "alive"
            info = ""
            if fe is not None and fe.poll() is None:
                try:
                    wchan = open(f"/proc/{fe.pid}/wchan").read().strip()
                    stat = open(f"/proc/{fe.pid}/stat").read().split()
                    info = f" wchan={wchan!r} state={stat[2]} utime={stat[13]} stime={stat[14]}"
                except OSError:
                    pass
            fail(f"frontend stopped reading input ({what}): pty write wedged after "
                 f"{off}/{len(data)} bytes — UI frozen [frontend {state}{info}]")

def key(m, name, settle=0.7):
    safe_write(m, KEY[name], f"key {name}")
    time.sleep(settle)

def sh(m, line, settle=0.5):
    safe_write(m, line.encode() + b"\r", f"cmd {line[:24]}")
    time.sleep(settle)

def shell_ready(m, tag, timeout_s=30):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        safe_write(m, f"echo RDY_{tag}\r".encode(), "ready probe")
        if read_until(m, f"RDY_{tag}".encode(), 4):
            return True
    return False

def paste(m, nbytes):
    """Paste through a heredoc: lines keep the tty line discipline happy."""
    blob = (b"p" * 99 + b"\n") * (nbytes // 100)
    safe_write(m, b"cat > /dev/null <<'PEOF'\r", "paste heredoc")
    time.sleep(0.3)
    off = 0
    last = time.time()
    while off < len(blob):
        r, w, _ = select.select([m], [m], [], 1)
        if m in r:
            try:
                log.write(os.read(m, 262144))
            except OSError:
                pass
        if m in w:
            n = os.write(m, blob[off:off + 32768])
            if n:
                off += n
                last = time.time()
        if time.time() - last > 30:
            fail(f"paste wedged at {off}/{len(blob)} bytes")
    sh(m, "PEOF", settle=1.0)

def vim_types(m, text, timeout_s=40):
    """Type `text` into a fullscreen vim and confirm it rendered.

    One-shot inserts race vim's startup under load; retry the insert (ESC
    first, so a half-started vim cannot leave us in a weird mode).
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        safe_write(m, b"\x1b", "esc")
        time.sleep(0.3)
        safe_write(m, b"i" + text.encode() + b"\x1b", "vim insert")
        if read_until(m, text.encode(), 8):
            return True
        time.sleep(1.0)
    return False

def fail(msg):
    print(f"FAIL (seed={SEED}): {msg}")
    cleanup()
    sys.exit(1)

def cleanup():
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

log = open(os.path.join(SCRATCH, "smoke-heavy2.raw"), "wb")
print(f"instance={INST} seed={SEED} rounds={ROUNDS}")
FULLSCREEN = "vim" if subprocess.run(["which", "vim"], capture_output=True).returncode == 0 else "vi"
VIM_A = os.path.join(WORKDIR, "tab1-file")
VIM_B = os.path.join(WORKDIR, "tab2-file")

# ── Build: two tabs, splits in each, a fullscreen app in each ───────────────
fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "heavy2"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

# Tab 1: marker + split + flood + a paste, then fullscreen vim in a split.
sh(master, "export T1=tab$((40+1))")
sh(master, "seq 1 3000", settle=1.0)
drain(master, 2.0)
paste(master, 80_000)
key(master, "h")
if not shell_ready(master, "T1B"):
    fail("tab1 split shell never became ready")
sh(master, "(while :; do seq 1 60; sleep 0.3; done) &")
key(master, "v")
if not shell_ready(master, "T1C"):
    fail("tab1 second split shell never became ready")
sh(master, f"{FULLSCREEN} -n {VIM_A}", settle=4.0)
if not vim_types(master, "hello-tab1"):
    fail("fullscreen app in tab1 split did not render")
print(f"build: tab1 = 3 panes (bigbuf+paste | flood | vim), pods={pod_count()}")

# Tab 2: new tab, split, another fullscreen app + its own flood.
key(master, "t", settle=2.0)
if not shell_ready(master, "T2A"):
    fail("tab2 shell never became ready")
sh(master, "export T2=tab$((40+2))")
sh(master, "seq 1 2000", settle=1.0)
drain(master, 1.5)
key(master, "h")
if not shell_ready(master, "T2B"):
    fail("tab2 split shell never became ready")
sh(master, f"{FULLSCREEN} -n {VIM_B}", settle=4.0)
if not vim_types(master, "hello-tab2"):
    fail("fullscreen app in tab2 did not render")
print(f"build: tab2 = 2 panes (bigbuf | vim), pods={pod_count()}")

# Floats: open all three, give each load, thrash them.
for fk, tag in (("1", "F1"), ("2", "F2"), ("3", "F3")):
    key(master, fk, settle=1.5)
    if not shell_ready(master, tag):
        fail(f"float {fk} shell never became ready")
    sh(master, f"export {tag}=f{fk}", settle=0.3)
    if fk == "1":
        sh(master, "seq 1 3000", settle=1.0)  # huge float buffer
        drain(master, 2.0)
    key(master, fk, settle=1.0)  # hide
pods_built = pod_count()
print(f"build: 3 floats opened+loaded, pods={pods_built}")
if pods_built < 8:  # 3 (tab1) + 2 (tab2) + 3 floats
    fail(f"expected >=8 pods, got {pods_built}")

def verify_all(tag):
    """Every layer must still be alive after a phase."""
    # Focused pane (tab2's vim) accepts input.
    if not vim_types(master, "alive-check", timeout_s=40):
        return f"{tag}: focused fullscreen app unresponsive"
    safe_write(master, b"u", "undo")
    time.sleep(0.3)
    # A float still opens and responds.
    key(master, "2", settle=1.5)
    safe_write(master, b"echo FLOAT_OK\r", "float probe")
    if not read_until(master, b"FLOAT_OK", 20):
        return f"{tag}: float unresponsive"
    key(master, "2", settle=1.0)
    # Tab switching works and the other tab is alive.
    key(master, "next", settle=1.5)
    safe_write(master, b"\x1b", "esc")  # normal mode in case a vim has focus
    # The ESC must be allowed to stand alone. ESC immediately followed by "e" is
    # how alt+e is encoded, so without this pause the two can arrive in one read
    # and be coalesced into a keybind — swallowing the "e" and leaving the shell
    # with "cho TAB_OK". That made this probe fail at random under load.
    time.sleep(0.3)
    safe_write(master, b"echo TAB_OK\r", "tab probe")
    got_tab = read_until(master, b"TAB_OK", 20)
    key(master, "next", settle=1.5)
    if not got_tab:
        return f"{tag}: other tab unresponsive"
    if pod_count() < pods_built:
        return f"{tag}: pods lost ({pod_count()} < {pods_built})"
    return None

err = verify_all("build")
if err:
    fail(err)
print("build: all layers verified (tabs, splits, floats, fullscreen apps)")

# ── Phase A: resize storm under load ───────────────────────────────────────
for (r, c) in [(30, 100), (50, 180), (24, 80), (45, 150), (60, 200), (45, 150)]:
    resize(master, r, c)
drain(master, 2.0)
err = verify_all("resize storm")
if err:
    fail(err)
print("phase A: survived resize storm (6 resizes under load)")

# ── Phase B: float thrash + concurrent paste ───────────────────────────────
# The float keys TOGGLE, so the open/closed state has to be tracked. Pressing
# "1" blind does not "ensure a float is open" — half the time it closes one, and
# then the paste below lands in whatever pane is focused. When that was a vim,
# `cat > /dev/null <<'PEOF'` got read as vim normal-mode commands (the /dev/null
# becoming a search) and 60KB of text was typed into the buffer. That looked
# like a hexe freeze but was entirely self-inflicted.
floats_open = {"1": False, "2": False, "3": False}

def float_toggle(fk, settle=0.7):
    key(master, fk, settle=settle)
    floats_open[fk] = not floats_open[fk]

for _ in range(6):
    float_toggle(random.choice(["1", "2", "3"]), settle=0.4)

for fk, is_open in list(floats_open.items()):
    if is_open:
        float_toggle(fk, settle=0.4)   # back to a known state: all closed
float_toggle("1", settle=1.0)          # now float 1 really IS open and focused
if not shell_ready(master, "PASTE_TGT"):
    fail("float 1 did not come back after thrashing")
paste(master, 60_000)                  # paste INTO the float while others flood
float_toggle("1", settle=1.0)          # close it
err = verify_all("float thrash")
if err:
    fail(err)
print("phase B: survived float thrashing + paste into a float")

# ── Chaos rounds against the fat multi-tab session ────────────────────────
for i in range(ROUNDS):
    mode = random.choice(["kill", "detach", "daemon", "bigoutput"])
    if mode in ("kill", "detach"):
        if mode == "detach":
            key(master, "d", settle=0.5)
            deadline = time.time() + 12
            while time.time() < deadline and fe.poll() is None:
                drain(master, 0.3)
        if fe.poll() is None:
            os.kill(fe.pid, signal.SIGKILL)
            fe.wait()
        os.close(master)
        fe, master = spawn_frontend([HEXE, "mux", "attach", "."])
        time.sleep(8.0)
        if fe.poll() is not None:
            fail(f"round {i+1} ({mode}): attach exited rc={fe.returncode}")
    elif mode == "daemon":
        for pid in pgrep(f"ses daemon --instance {INST}"):
            os.kill(pid, signal.SIGKILL)
        deadline = time.time() + 30
        while time.time() < deadline and not pgrep(f"ses daemon --instance {INST}"):
            time.sleep(0.5)
        time.sleep(12.0)  # reconnect + reattach a fat multi-tab session
        if fe.poll() is not None:
            fail(f"round {i+1} ({mode}): frontend died on daemon kill")
    else:  # bigoutput: a pane keeps producing output WHILE DETACHED
        # Drive a FLOAT (a shell) — the focused split holds a fullscreen app,
        # and a shell command typed into vim would just become buffer text.
        key(master, "3", settle=1.5)
        if not shell_ready(master, "BIGOUT"):
            fail(f"round {i+1} ({mode}): float shell not ready")
        # Long-running producer: it keeps writing into the pod's ring for the
        # whole detached window, so replay must be BOUNDED on reattach.
        sh(master, "(for i in $(seq 1 400); do seq 1 500; done) &", settle=0.5)
        key(master, "3", settle=0.8)  # hide the float; the pod keeps running
        os.kill(fe.pid, signal.SIGKILL)
        fe.wait()
        os.close(master)
        time.sleep(8.0)   # pods produce into their rings while nobody is attached
        fe, master = spawn_frontend([HEXE, "mux", "attach", "."])
        time.sleep(10.0)  # replay must be bounded, not a stall
        if fe.poll() is not None:
            fail(f"round {i+1} ({mode}): attach after detached output exited")

    err = verify_all(f"round {i+1} ({mode})")
    if err:
        fail(err)
    if not pgrep(f"ses daemon --instance {INST}"):
        time.sleep(3)
        if not pgrep(f"ses daemon --instance {INST}"):
            fail(f"round {i+1} ({mode}): daemon dead")
    print(f"round {i+1} ({mode}): OK — {pod_count()} pods alive")

# Leak check.
state_file = os.path.join(env["XDG_STATE_HOME"], "hexe", INST, "ses_state.json")
try:
    state = json.load(open(state_file))
    detached = len(state.get("detached_sessions", []))
    if detached > 2:
        fail(f"junk records accumulated: {detached} detached sessions")
    print(f"leak check: {detached} detached records, {len(state.get('panes', []))} panes")
except FileNotFoundError:
    pass

cleanup()
log.close()
print(f"SMOKE PASS: multi-tab heavy session ({pods_built} pods) survived resize storm, "
      f"float thrash and {ROUNDS} chaos rounds (seed={SEED})")
