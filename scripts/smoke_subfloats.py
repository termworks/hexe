#!/usr/bin/env python3
"""Sub-floats: a float can own floats, and they die with it.

A sub-float joins its parent's family — the parent's toggle key, the parent's
rectangle, the next free chip number — and cannot outlive it. None of that can
be checked without a live session, because the family lives in the frontend's
float records and the cascade runs in the daemon's `killPane`:

  * `hexe terminal float --sub` makes a CHILD, not a second top-level float:
    it reports the parent's uuid, shares the parent's key and geometry.
  * numbers are stable and gaps are refilled: 1, 2, 3, close 2, next child is 2.
  * closing the parent closes every child, which is the whole point of tying
    them together.
  * a `--sub` from outside a float is refused rather than silently making a
    top-level float.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"subfloat{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSION = "subs"

# A layout with one keyed float, so there is a parent with a real toggle key.
# The assignment style, which is what a real config uses: declare the layout and
# return nothing. Ending with `return hexe.setup({})` is the other style and
# discards layouts registered this way, so the keyed float never existed and
# `float.show` answered false.
open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    "local hexe = require('hexe')\n"
    "hexe.layout('default', {\n"
    "  enabled = true,\n"
    "  tabs = { hexe.tab('main', { enabled = true, root = hexe.pane({ cwd = '.' }) }) },\n"
    "  floats = {\n"
    "    hexe.float('host', { key = '2', enabled = true, title = 'host',\n"
    "                         command = '/bin/sh', attrs = { global = true } }),\n"
    "  },\n"
    "})\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1",
            "HEXE_MAX_CONNECTIONS_PER_MINUTE": "256"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET",
           "HEXE_API_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

procs, failures = [], []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    r = subprocess.run(["pgrep", "-f", f"instance {INST}"], capture_output=True, text=True)
    if r.returncode == 0:
        for pid in r.stdout.split():
            try: os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError): pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
signal.signal(signal.SIGALRM, lambda *_: (print("FAIL: timed out"), sys.stdout.flush(),
                                          cleanup(), os._exit(1)))
signal.alarm(300)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush(); cleanup(); sys.exit(1)


def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)


def hexe(*args, extra_env=None, timeout=40):
    e = dict(env)
    if extra_env:
        e.update(extra_env)
    return subprocess.run([HEXE] + list(args), capture_output=True, text=True,
                          env=e, cwd=WD, timeout=timeout)


def api(call, *json_args):
    p = hexe("api", call, *json_args, "--session", SESSION)
    if p.returncode != 0:
        fail(f"hexe api {call} failed: {p.stderr.strip()[:180]}")
    return json.loads(p.stdout)["result"]


def floats():
    """Float records, as the session reports them."""
    return api("floats")


def socket_for(s):
    for root, _d, files in os.walk(RUN):
        if f"api@{s}.sock" in files:
            return os.path.join(root, f"api@{s}.sock")
    return None


def drain(m):
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


def spawn_sub(parent_uuid, tag):
    """Ask, as the parent float would, for a sub-float of itself."""
    return hexe("terminal", "float", "--sub", "--command", "/bin/sh",
                "--title", tag, extra_env={"HEXE_PANE_UUID": parent_uuid}, timeout=15)


# ------------------------------------------------------------------ a session

m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", SESSION], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, args=(m,), daemon=True).start()

deadline = time.time() + 30
while time.time() < deadline and socket_for(SESSION) is None:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    time.sleep(0.3)
if socket_for(SESSION) is None:
    fail("session never bound its socket")
time.sleep(2.5)

# --------------------------------------------------------------------- phase 1
print("phase 1: a parent float, from the layout, with a real toggle key")
api("act", json.dumps({"type": "float.show", "float": "2"}))
deadline = time.time() + 20
while time.time() < deadline and not floats():
    time.sleep(0.4)
fl = floats()
if not fl:
    fail("the keyed float never appeared")
PARENT = fl[0]["uuid"]
print(f"  parent float {PARENT[:8]}")
check(len(fl) == 1, f"one float so far (got {len(fl)})")


def family_of(root):
    """(uuid, family_index) for every member of root's family, by chip number."""
    out = []
    for f in floats():
        parent = f.get("parent_float")
        if f["uuid"] == root or parent == root:
            out.append((f["uuid"], f.get("family_index", 0)))
    return sorted(out, key=lambda t: t[1])


# --------------------------------------------------------------------- phase 2
print("\nphase 2: --sub makes a child, not another top-level float")
p = spawn_sub(PARENT, "kid1")
deadline = time.time() + 25
while time.time() < deadline and len(floats()) < 2:
    time.sleep(0.4)
fl = floats()
check(len(fl) == 2, f"a second float exists (got {len(fl)})")

kid = next((f for f in fl if f["uuid"] != PARENT), None)
check(kid is not None, "the new float is distinguishable from the parent")
if kid:
    check(kid.get("parent_float") == PARENT,
          f"it names the parent as its parent_float (got {kid.get('parent_float')})")
    check(kid.get("family_index") == 1, f"it is chip 1 (got {kid.get('family_index')})")
    parent_rec = next(f for f in fl if f["uuid"] == PARENT)
    check(kid.get("float_key") == parent_rec.get("float_key"),
          "it shares the parent's toggle key, so one key reaches the family")
    check(kid.get("width_pct") == parent_rec.get("width_pct") and
          kid.get("height_pct") == parent_rec.get("height_pct"),
          "it inherits the parent's rectangle")
    check(parent_rec.get("family_index") == 0, "and the parent is chip 0")

# --------------------------------------------------------------------- phase 3
print("\nphase 3: numbers are stable, and a closed chip is refilled")
spawn_sub(PARENT, "kid2")
spawn_sub(PARENT, "kid3")
deadline = time.time() + 30
while time.time() < deadline and len(family_of(PARENT)) < 4:
    time.sleep(0.4)
fam = family_of(PARENT)
check([n for _u, n in fam] == [0, 1, 2, 3], f"chips are 0,1,2,3 (got {[n for _u, n in fam]})")

# Close chip 2 and check 3 keeps its number, then that a new child takes 2.
chip2 = next((u for u, n in fam if n == 2), None)
check(chip2 is not None, "found chip 2 to close")
if chip2:
    api("close", json.dumps(chip2))
    deadline = time.time() + 20
    while time.time() < deadline and len(family_of(PARENT)) > 3:
        time.sleep(0.4)
    fam = family_of(PARENT)
    check([n for _u, n in fam] == [0, 1, 3],
          f"3 keeps its number after 2 closes (got {[n for _u, n in fam]})")

    spawn_sub(PARENT, "kid4")
    deadline = time.time() + 25
    while time.time() < deadline and len(family_of(PARENT)) < 4:
        time.sleep(0.4)
    fam = family_of(PARENT)
    check([n for _u, n in fam] == [0, 1, 2, 3],
          f"the next child refills the gap at 2 (got {[n for _u, n in fam]})")

# --------------------------------------------------------------------- phase 4
print("\nphase 4: --sub from outside a float is refused, not silently top-level")
before = len(floats())
p = hexe("terminal", "float", "--sub", "--command", "/bin/sh", timeout=15)
check(p.returncode != 0, f"a --sub with no pane exits non-zero (got {p.returncode})")
check("not running inside" in (p.stderr + p.stdout),
      f"and says why (got {(p.stderr + p.stdout).strip()[:120]!r})")
check(len(floats()) == before, "and created nothing")

# --------------------------------------------------------------------- phase 5
print("\nphase 5: closing the parent closes the whole family")
fam = family_of(PARENT)
kids = [u for u, n in fam if n != 0]
check(len(kids) >= 2, f"there are children to lose ({len(kids)})")
api("close", json.dumps(PARENT))

deadline = time.time() + 30
while time.time() < deadline:
    live = {f["uuid"] for f in floats()}
    if not any(k in live for k in kids) and PARENT not in live:
        break
    time.sleep(0.5)

live = {f["uuid"] for f in floats()}
check(PARENT not in live, "the parent is gone")
orphans = [k[:8] for k in kids if k in live]
check(not orphans, f"every child went with it (orphans: {orphans})")

# And their pods are gone too: a closed float that leaves a process behind is a
# leak the user cannot see or reach.
still = []
for k in kids:
    r = subprocess.run(["pgrep", "-f", f"pod daemon.*--uuid {k}"], capture_output=True, text=True)
    if r.returncode == 0:
        still.append(k[:8])
check(not still, f"no sub-float pod outlived its parent (alive: {still})")

print()
if failures:
    print(f"FAIL: {len(failures)} check(s) failed")
    for f in failures:
        print(f"  - {f}")
    sys.stdout.flush(); cleanup(); sys.exit(1)
print("PASS: sub-floats join a family, number stably, and die with their parent")
sys.stdout.flush(); cleanup()
