#!/usr/bin/env python3
"""Addressing a pane: `--session` + `--pane`, or `--uuid` alone.

The address is a hierarchy — session → pane — and pane names are unique per
SESSION, not per daemon. Every claim in that sentence is one a unit test cannot
reach, because it needs two real sessions sharing one daemon:

  * two sessions may both hold a pane called the same thing, and
    `--session A --pane x` and `--session B --pane x` must reach DIFFERENT
    panes. Getting this wrong types into the wrong person's shell.
  * a uuid is absolute: `--uuid <prefix>` needs no session.
  * a pane in a DETACHED session is still addressable — typing goes to the pod,
    which outlives the frontend.
  * ambiguity is always refused, never guessed: a name two sessions share with
    no `--session`, and a uuid prefix matching two panes.
  * a rename onto a name already taken IN THAT SESSION fails; the same name in
    the other session is free.
  * every failure exits non-zero, with a distinct code per reason.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"addr{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSIONS = ("alpha", "beta")
SHARED_NAME = "driven"

open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    "local hexe = require('hexe')\nreturn hexe.setup({})\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET",
           "HEXE_API_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

procs, masters, failures = [], [], []


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


def watchdog(_sig, _frm):
    print("FAIL: timed out waiting on the mux")
    sys.stdout.flush(); cleanup(); os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(240)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush(); cleanup(); sys.exit(1)


def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)


def hexe(*args, want_rc=None):
    p = subprocess.run([HEXE] + list(args), capture_output=True, text=True,
                       env=env, cwd=WD, timeout=30)
    if want_rc is not None and p.returncode != want_rc:
        fail(f"`hexe {' '.join(args)}` exited {p.returncode}, wanted {want_rc}: "
             f"{(p.stderr or p.stdout).strip()[:200]}")
    return p


def api(session, call, *json_args):
    p = hexe("api", call, *json_args, "--session", session)
    if p.returncode != 0:
        fail(f"hexe api {call} ({session}) failed: {p.stderr.strip()[:200]}")
    return json.loads(p.stdout)["result"]


def api_try(session, call, *json_args):
    """Like `api`, but a verb that answers `false` is an answer, not a failure.

    `hexe api` exits non-zero when a pane verb returns false, because an action
    that did not happen must not look like one that did. A test asserting on
    that false has to read it rather than die on it.
    """
    p = hexe("api", call, *json_args, "--session", session)
    try:
        return json.loads(p.stdout)["result"]
    except (ValueError, KeyError):
        fail(f"hexe api {call} ({session}) gave no result: "
             f"{(p.stderr or p.stdout).strip()[:200]}")


def socket_for(session):
    for root, _d, files in os.walk(RUN):
        if f"api@{session}.sock" in files:
            return os.path.join(root, f"api@{session}.sock")
    return None


def drain(m):
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


def start_session(name):
    m, sl = pty.openpty()
    fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", name], stdin=sl, stdout=sl, stderr=sl,
                         env=env, cwd=WD, start_new_session=True)
    os.close(sl)
    procs.append(p); masters.append(m)
    threading.Thread(target=drain, args=(m,), daemon=True).start()
    deadline = time.time() + 30
    while time.time() < deadline:
        if p.poll() is not None:
            fail(f"session {name} exited rc={p.returncode} before binding its socket")
        if socket_for(name):
            return p
        time.sleep(0.3)
    fail(f"session {name} never bound api@{name}.sock")


# ----------------------------------------------------------- two live sessions

for s in SESSIONS:
    start_session(s)
print(f"sessions: {', '.join(SESSIONS)} listening on one daemon")
time.sleep(2.5)  # let each shell reach a prompt before anything is typed

pane = {}
for s in SESSIONS:
    rows = api(s, "panes")
    if not rows:
        fail(f"session {s} reports no panes")
    pane[s] = rows[0]["uuid"]
    print(f"  {s}: pane {pane[s][:8]}")

if pane[SESSIONS[0]] == pane[SESSIONS[1]]:
    fail("both sessions report the same pane uuid; they are not separate")

# ------------------------------------------------------------------- phase 1
print("\nphase 1: one name, two sessions — the point of per-session names")
for s in SESSIONS:
    r = api(s, "rename", json.dumps(pane[s]), json.dumps(SHARED_NAME))
    check(r is True, f"{s}: renaming its pane to '{SHARED_NAME}' succeeded")

for s in SESSIONS:
    rows = api(s, "panes")
    got = rows[0].get("name")
    check(got == SHARED_NAME, f"{s}: its pane is called '{SHARED_NAME}' (got {got!r})")

# ------------------------------------------------------------------- phase 2
print("\nphase 2: the same name in each session reaches a DIFFERENT pane")
for s in SESSIONS:
    stamp = os.path.join(WD, f"hit_{s}.txt")
    hexe("terminal", "send", "--session", s, "--pane", SHARED_NAME, "--enter",
         f"echo {s} > {stamp}", want_rc=0)

deadline = time.time() + 20
while time.time() < deadline:
    if all(os.path.exists(os.path.join(WD, f"hit_{s}.txt")) for s in SESSIONS):
        break
    time.sleep(0.3)

for s in SESSIONS:
    stamp = os.path.join(WD, f"hit_{s}.txt")
    got = open(stamp).read().strip() if os.path.exists(stamp) else None
    check(got == s, f"--session {s} --pane {SHARED_NAME} reached {s}'s pane (got {got!r})")

# ------------------------------------------------------------------- phase 3
print("\nphase 3: a uuid is absolute — no session needed")
s = SESSIONS[0]
stamp = os.path.join(WD, "by_uuid.txt")
hexe("terminal", "send", "--uuid", pane[s][:8], "--enter", f"echo byuuid > {stamp}", want_rc=0)
deadline = time.time() + 15
while time.time() < deadline and not os.path.exists(stamp):
    time.sleep(0.3)
got = open(stamp).read().strip() if os.path.exists(stamp) else None
check(got == "byuuid", f"--uuid <prefix> with no --session reached the pane (got {got!r})")

p = hexe("terminal", "info", "--uuid", pane[s])
check(p.returncode == 0, f"a full uuid needs no lookup (exit {p.returncode})")

# ------------------------------------------------------------------- phase 4
print("\nphase 4: ambiguity is refused, never guessed")
p = hexe("terminal", "info", "--pane", SHARED_NAME)
check(p.returncode == 4, f"a name both sessions use, with no --session, exits 4 (got {p.returncode})")
check("session" in (p.stderr + p.stdout).lower(),
      "and the message says to name the session")

# A uuid-prefix collision cannot be provoked here -- uuids are random, so no
# prefix is guaranteed to match two panes. That case is covered deterministically
# by the unit test "a selector matching two panes is ambiguous, not the first
# one" in src/modules/session/state_test.zig, which constructs the collision.
p = hexe("terminal", "info", "--uuid", pane[s][:8])
check(p.returncode == 0, f"a uuid prefix that matches exactly one pane resolves (got {p.returncode})")

# ------------------------------------------------------------------- phase 5
print("\nphase 5: rename collides inside a session, not across them")
second = api(SESSIONS[0], "act", json.dumps("split.h"))
time.sleep(2.0)
rows = api(SESSIONS[0], "panes")
if len(rows) < 2:
    fail(f"could not split {SESSIONS[0]} to get a second pane (act -> {second!r})")
other = next(r["uuid"] for r in rows if r["uuid"] != pane[SESSIONS[0]])
r = api_try(SESSIONS[0], "rename", json.dumps(other), json.dumps(SHARED_NAME))
check(r is False,
      f"renaming a second pane in {SESSIONS[0]} to '{SHARED_NAME}' is refused (got {r!r})")
rows = api(SESSIONS[0], "panes")
names = [x.get("name") for x in rows]
check(names.count(SHARED_NAME) == 1,
      f"only one pane in {SESSIONS[0]} holds the name (names={names})")
# The other session still holds it, untouched.
check(api(SESSIONS[1], "panes")[0].get("name") == SHARED_NAME,
      f"{SESSIONS[1]} still holds '{SHARED_NAME}'")

# ------------------------------------------------------------------- phase 6
print("\nphase 6: a detached session is still addressable — typing goes to the pod")
det = SESSIONS[1]
det_pane = pane[det]
stamp = os.path.join(WD, "detached.txt")
# Detach, do not kill. SIGTERM is a graceful QUIT and takes the panes with it;
# only `mux.detach` leaves them running with the session parked.
idx = SESSIONS.index(det)
hexe("api", "act", json.dumps("mux.detach"), "--session", det)
deadline = time.time() + 25
while time.time() < deadline and socket_for(det):
    time.sleep(0.4)
check(socket_for(det) is None, f"{det}'s control socket is gone (it detached)")

# The session must be listed as detached, with its panes intact -- otherwise
# this phase is testing a dead pane rather than a detached one.
listing = hexe("session", "list", "--json").stdout
try:
    detached_names = [s.get("name") for s in json.loads(listing).get("detached", [])]
except ValueError:
    detached_names = []
check(det in detached_names, f"{det} is listed as detached (got {detached_names})")

p = hexe("terminal", "send", "--uuid", det_pane[:8], "--enter", f"echo detached > {stamp}")
check(p.returncode == 0, f"typing into a detached pane by uuid exits 0 (got {p.returncode}; "
                         f"{(p.stderr or '').strip()[:120]})")
deadline = time.time() + 15
while time.time() < deadline and not os.path.exists(stamp):
    time.sleep(0.3)
got = open(stamp).read().strip() if os.path.exists(stamp) else None
check(got == "detached", f"the detached pane ran it (got {got!r})")

# With the other session gone, the shared name is no longer ambiguous.
# Detaching does NOT free the name: the pane is still there and still answers
# to it, which is the whole reason a detached pane is addressable. So the name
# stays ambiguous, and the session is what disambiguates it.
p = hexe("terminal", "info", "--pane", SHARED_NAME)
check(p.returncode == 4,
      f"'{SHARED_NAME}' is still ambiguous: a detached pane keeps its name (exit {p.returncode})")
p = hexe("terminal", "info", "--session", det, "--pane", SHARED_NAME)
check(p.returncode == 0,
      f"--session {det} --pane {SHARED_NAME} resolves the detached one (exit {p.returncode})")

# ------------------------------------------------------------------- phase 7
print("\nphase 7: the exit codes a script branches on")
p = hexe("terminal", "info", "--pane", "nosuchpane")
check(p.returncode == 3, f"an unknown pane name exits 3 (got {p.returncode})")
p = hexe("terminal", "info", "--session", "nosuchsession", "--pane", SHARED_NAME)
check(p.returncode == 3, f"an unknown session exits 3 (got {p.returncode})")
p = hexe("terminal", "info", "--uuid", "ffffffffffffffffffffffffffffffff")
check(p.returncode == 3, f"a uuid nobody has exits 3 (got {p.returncode})")

print()
if failures:
    print(f"FAIL: {len(failures)} check(s) failed")
    for f in failures:
        print(f"  - {f}")
    sys.stdout.flush(); cleanup(); sys.exit(1)
print("PASS: session -> pane addressing, with per-session names")
sys.stdout.flush(); cleanup()
