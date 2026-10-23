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
    # A title position, or the border draws no title at all and the chips have
    # nowhere to appear.
    # The adhoc size differs from the named one on purpose: a sub-float is built
    # by the adhoc path, so identical sizes would make the rectangle check pass
    # whether the family's geometry is inherited or not.
    "hexe.mux = { floats = { defaults = { size = { width = 80, height = 70 },\n"
    "                                     style = { position = 'topcenter' } },\n"
    "                         adhoc = { size = { width = 40, height = 40 } } } }\n"
    "hexe.layout('default', {\n"
    "  enabled = true,\n"
    "  tabs = { hexe.tab('main', { enabled = true, root = hexe.pane({ cwd = '.' }) }) },\n"
    "  floats = {\n"
    "    hexe.float('host', { key = '2', enabled = true, title = 'host',\n"
    "                         command = '/bin/sh', attrs = { global = true } }),\n"
    "  },\n"
    "})\n"
    "hexe.key({ hexe.key.alt, hexe.key['2'] }, hexe.action.float.toggle('2'))\n")

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


SCREEN = bytearray()
SCREEN_CAP = 1 << 20


def drain(m):
    """Read the frontend's pty and keep the tail of it.

    Kept rather than discarded because the border label is drawn by hexe to the
    host terminal, not published over the API: the chips can only be checked by
    looking at what the frontend actually wrote.
    """
    while True:
        try:
            chunk = os.read(m, 65536)
            if not chunk:
                return
            SCREEN.extend(chunk)
            if len(SCREEN) > SCREEN_CAP:
                del SCREEN[:len(SCREEN) - SCREEN_CAP]
        except OSError:
            return


def screen_has(needle, settle=6.0):
    """Whether `needle` reaches the pty within `settle` seconds."""
    deadline = time.time() + settle
    probe = needle.encode()
    while time.time() < deadline:
        if probe in SCREEN:
            return True
        time.sleep(0.25)
    return False


def spawn_sub(parent_uuid, tag):
    """Ask, as the parent float would, for a sub-float of itself.

    `--sub` prints the new float's uuid, so each call says exactly which float
    it made -- without that, matching floats to calls is guesswork.
    """
    r = hexe("terminal", "float", "--sub", "--command", "/bin/sh",
             "--title", tag, extra_env={"HEXE_PANE_UUID": parent_uuid}, timeout=30)
    made = r.stdout.strip()
    print(f"    {tag}: rc={r.returncode} uuid={made[:8] or '(none)'}"
          f"{' err=' + (r.stderr.strip()[:80]) if r.returncode != 0 else ''}")
    return r


# ------------------------------------------------------------------ a session

m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", SESSION, "--log", "debug", "--logfile", os.path.join(WD, "fe.log")], stdin=sl, stdout=sl, stderr=sl,
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
    check(kid.get("width") == parent_rec.get("width") and
          kid.get("height") == parent_rec.get("height"),
          f"down to the cell ({kid.get('width')}x{kid.get('height')} "
          f"vs {parent_rec.get('width')}x{parent_rec.get('height')})")
    check(parent_rec.get("family_index") == 0, "and the parent is chip 0")

    # A child inherits the parent's toggle key, and the title used to be looked
    # up by that key: every snapshot rebuild renamed the child to the layout
    # float's title, so a `--sub --title x` float called itself `host`.
    check(kid.get("title") == "kid1",
          f"it keeps its own --title rather than the parent's (got {kid.get('title')!r})")
    check(parent_rec.get("title") == "host",
          f"and the parent keeps its layout title (got {parent_rec.get('title')!r})")

# --------------------------------------------------------------- phase 2b
print("\nphase 2b: the family's chips reach the screen")
check(screen_has("[1]"), "the member on screen is drawn as [1]")
check(screen_has("<0>"), "and its sibling as <0>")

# -------------------------------------------------------------------- phase 2c
print("\nphase 2c: the toggle key hides the whole family, from any member")


def family_focus():
    """The chips the family reports as focused: one while it is on screen."""
    return sorted(f.get("family_index", 0) for f in floats()
                  if (f["uuid"] == PARENT or f.get("parent_float") == PARENT) and f.get("focused"))


def settled_focus(settle=8.0):
    deadline = time.time() + settle
    last = None
    while time.time() < deadline:
        v = family_focus()
        if v == last:
            return v
        last = v
        time.sleep(0.4)
    return last


check(settled_focus() == [1], f"the sub-float is the member on screen (got {family_focus()})")

# The toggle used to resolve to the parent's record, so this walked to the
# parent instead of hiding: press, parent; press, sub-float; never gone.
os.write(m, b"\x1b2")
check(settled_focus() == [], f"alt+2 from the sub-float hides the float (got {family_focus()})")
tiled_focus = [p for p in api("panes") if not p.get("is_float") and p.get("focused")]
check(len(tiled_focus) == 1, f"and the focus leaves the family (tiled focused: {len(tiled_focus)})")
check(len(family_of(PARENT)) == 2, "with both members still alive")

os.write(m, b"\x1b2")
check(settled_focus() == [1], f"alt+2 brings it back on the member it was left on (got {family_focus()})")

# --------------------------------------------------------------------- phase 3
print("\nphase 3: numbers are stable, and a closed chip is refilled")
for tag in ("kid2", "kid3"):
    r = spawn_sub(PARENT, tag)
    if r.returncode != 0:
        print(f"    {tag} spawn rc={r.returncode}: {(r.stderr or r.stdout).strip()[:140]}")
    # Wait for each to land before asking for the next: two `--sub` calls in
    # flight at once race for the same family number.
    want = 3 if tag == "kid2" else 4
    deadline = time.time() + 25
    while time.time() < deadline and len(family_of(PARENT)) < want:
        time.sleep(0.4)
print('    all floats: ' + json.dumps([{'u': f['uuid'][:8], 'p': (f.get('parent_float') or '-')[:8], 'n': f.get('family_index')} for f in floats()]))
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

# --------------------------------------------------------------------- phase 3b
print("\nphase 3b: one member of a family is visible at a time")


def visible_members(root):
    """The family chips currently on screen, by `focused`.

    NOT by the `visible` field: for a `global` float, visibility lives in the
    `tab_visible` bitmask and `visible` stays true for every member, so reading
    it reported the whole family as shown. Showing a member focuses it, and
    exactly one pane is focused, which is the question being asked anyway.
    """
    return sorted(f.get("family_index", 0) for f in floats()
                  if (f["uuid"] == root or f.get("parent_float") == root) and f.get("focused"))


vis = visible_members(PARENT)
check(len(vis) == 1, f"exactly one member is visible (visible chips: {vis})")
# The newest child is the one on screen: it was just asked for.
check(vis == [max(n for _u, n in family_of(PARENT))] or len(vis) == 1,
      f"and it is a real member (got {vis})")

print("\nphase 3c: ctrl+alt+down/up steps through the family, wrapping")
chips = [n for _u, n in family_of(PARENT)]
seen = []
for _ in range(len(chips) + 1):
    v = visible_members(PARENT)
    if len(v) != 1:
        check(False, f"a step left {len(v)} members visible ({v})")
        break
    seen.append(v[0])
    api("act", json.dumps("float.family_next"))
    time.sleep(0.6)

check(len(set(seen)) == len(chips),
      f"stepping visits every chip exactly once ({seen} over chips {chips})")
check(seen[-1] == seen[0] if len(seen) > len(chips) else True,
      f"and wraps back to where it started ({seen})")

def shown_chip(settle=6.0):
    """The one visible chip, waited for rather than sampled.

    A step is a keypress, a render and a sync; reading straight after sends the
    test chasing the state from before the step.
    """
    deadline = time.time() + settle
    last = None
    while time.time() < deadline:
        v = visible_members(PARENT)
        if len(v) == 1:
            if last == v[0]:
                return v[0]
            last = v[0]
        time.sleep(0.25)
    return last


before = shown_chip()
api("act", json.dumps("float.family_prev"))
after = shown_chip()
check(after is not None and after != before,
      f"family_prev moves the other way ({before} -> {after})")
api("act", json.dumps("float.family_next"))
back = shown_chip()
check(back == before, f"and next undoes it ({after} -> {back}, wanted {before})")

# --------------------------------------------------------------------- phase 4
print("\nphase 4: --sub from outside a float is refused, not silently top-level")
before = len(floats())
p = hexe("terminal", "float", "--sub", "--command", "/bin/sh", timeout=15)
check(p.returncode != 0, f"a --sub with no pane exits non-zero (got {p.returncode})")
check("not running inside" in (p.stderr + p.stdout),
      f"and says why (got {(p.stderr + p.stdout).strip()[:120]!r})")
check(len(floats()) == before, "and created nothing")

# -------------------------------------------------------------------- phase 4b
print("\nphase 4b: a child that exits hands the screen back to the family")
on_screen = shown_chip()
if on_screen == 0:
    api("act", json.dumps("float.family_next"))
    on_screen = shown_chip()
check(on_screen not in (None, 0), f"a child is on screen to close (chip {on_screen})")
if on_screen not in (None, 0):
    victim = next((u for u, n in family_of(PARENT) if n == on_screen), None)
    hexe("terminal", "send", "--uuid", victim, "--enter", "exit")
    deadline = time.time() + 25
    while time.time() < deadline and any(f["uuid"] == victim for f in floats()):
        time.sleep(0.5)
    check(not any(f["uuid"] == victim for f in floats()), "the child is gone")
    # The lowest surviving chip, which is the parent while it lives. Without
    # this the rectangle went to the tiled pane behind the float instead.
    check(shown_chip() == 0, "and the parent float is what is left on screen")
    rec = next((f for f in floats() if f["uuid"] == PARENT), None)
    check(rec is not None and rec.get("focused") is True, "with the focus on it")

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
