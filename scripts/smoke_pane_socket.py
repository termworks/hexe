#!/usr/bin/env python3
"""A pane gets its own control socket, and it answers for that pane alone.

The session socket is full control of the session, authenticated only by file
permissions. Handing it to whatever is running in a pane would give a shell
script the whole mux, so a program inside a pane had nothing it could safely be
given -- and scraped its own terminal instead.

A pane's socket is a different door: bound by the frontend, named from the pane
uuid, and narrowed when it binds rather than when someone asks. It grants
nothing the caller did not already have -- it IS the process in that pane -- and
withholds every other pane and the shape of the session.

Checked here:

  * `$HEXE_PANE_API_SOCKET` reaches the pane's shell, and something is
    listening on it;
  * through it, a no-selector call answers for THIS pane, even while another
    pane holds focus -- the caller's own pane is its "current" one;
  * a session-wide call (`panes`, `tabs`, `session`) is refused BY NAME, not
    answered with one pane's worth of a session-wide reply;
  * a selector naming ANOTHER pane resolves to nothing rather than silently to
    the caller's own -- retargeting a write would be worse than refusing it;
  * a verb needing access the pane socket does not hold (`keys`) is refused;
  * the session's own socket still does all of it, so nothing was narrowed for
    everybody.
"""
import atexit, fcntl, json, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"panesock{os.getpid()}")
CF, RUN = os.path.join(WD, "config"), os.path.join(WD, "run")
for d in (os.path.join(CF, "hexe"), RUN):
    os.makedirs(d, exist_ok=True)
open(os.path.join(CF, "hexe", "init.lua"), "w").write("local hexe = require('hexe')\n")
INST = f"smk{os.getpid()}"
MARK = os.path.join(WD, "panesock")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "XDG_STATE_HOME": os.path.join(WD, "state"), "XDG_DATA_HOME": os.path.join(WD, "data"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET", "HEXE_API_SOCKET",
           "HEXE_PANE_API_SOCKET", "HEXE_FLOAT", "HEXE_PAINTER_SOCKET", "HEXE_ENV_FD", "HEXE_BIN"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


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


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush()
    cleanup()
    sys.exit(1)


def watchdog(_s, _f):
    print("FAIL: timed out")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(180)


def call(sock_path, name, *args):
    """One request, unwrapped the way any client unwraps: result is a list."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    try:
        s.connect(sock_path)
    except OSError as e:
        s.close()
        return {"__connect_error": str(e)}
    req = {"call": name}
    if args:
        req["args"] = list(args)
    body = json.dumps(req).encode()
    s.sendall(struct.pack(">I", len(body)) + body)
    hdr = b""
    while len(hdr) < 4:
        c = s.recv(4 - len(hdr))
        if not c:
            s.close()
            return {}
        hdr += c
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        c = s.recv(need - len(body))
        if not c:
            break
        body += c
    s.close()
    r = json.loads(body or b"{}")
    if r.get("ok") and isinstance(r.get("result"), list):
        vals = r["result"]
        r = dict(r, result=vals[0] if (r.get("n") or len(vals)) == 1 else vals)
    return r


def api(*args):
    r = subprocess.run([HEXE, "api", "--session", "panesock", *args], env=env, cwd=WD,
                       capture_output=True, text=True, timeout=25)
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return {}


# --- a session with two panes ------------------------------------------------

m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "panesock"], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 40
while time.time() < deadline and not api("panes").get("result"):
    if fe.poll() is not None:
        fail(f"the frontend exited rc={fe.returncode}")
    time.sleep(0.5)

api("act", '{"type":"split.v"}')
deadline = time.time() + 20
while time.time() < deadline and len(api("panes").get("result") or []) < 2:
    time.sleep(0.4)
panes = api("panes").get("result") or []
if len(panes) < 2:
    fail(f"needed two panes to test cross-pane refusal; got {len(panes)}")

sess_sock = api("session").get("result", {}).get("socket")
if not sess_sock:
    fail("the session did not report its own socket")

# --- the pane's shell was told where its socket is ---------------------------
#
# Read from the SHELL's environment, not derived here: the point is that the
# variable reaches the program in the pane.
focused = api("pane").get("result", {})
other = next((p for p in panes if p["uuid"] != focused.get("uuid")), None)
if not other:
    fail("could not find a second pane distinct from the focused one")

api("send", json.dumps(focused["uuid"]),
    json.dumps(f'printf "%s" "$HEXE_PANE_API_SOCKET" > {MARK}\n'))

deadline = time.time() + 20
while time.time() < deadline and not (os.path.exists(MARK) and open(MARK).read().strip()):
    time.sleep(0.4)
if not os.path.exists(MARK):
    fail("the pane's shell never wrote the variable; $HEXE_PANE_API_SOCKET did not reach it")
pane_sock = open(MARK).read().strip()
if not pane_sock:
    fail("$HEXE_PANE_API_SOCKET is set but empty in the pane's shell")
if not os.path.exists(pane_sock):
    fail(f"the pane's shell was told {pane_sock!r}, but nothing bound it")
print(f"env: the pane's shell has $HEXE_PANE_API_SOCKET -> {os.path.basename(pane_sock)}")

# --- it answers for THIS pane ------------------------------------------------

r = call(pane_sock, "pane")
if "__connect_error" in r:
    fail(f"nothing is listening on the pane's own socket: {r['__connect_error']}")
if not r.get("ok"):
    fail(f"`pane` on the pane's own socket failed: {r}")
if r["result"].get("uuid") != focused["uuid"]:
    fail(f"the pane socket answered for {r['result'].get('uuid')!r}, not for its own pane "
         f"{focused['uuid']!r}")
print(f"scope: a no-selector call answers for this pane ({r['result']['uuid'][:8]})")

# Focus the OTHER pane: the socket's answer must not follow the session's focus.
api("focus", json.dumps(other["uuid"]))
time.sleep(1.0)
now_focused = api("pane").get("result", {}).get("uuid")
if now_focused != other["uuid"]:
    fail("could not move focus to the other pane, so the next check would prove nothing")
r = call(pane_sock, "pane")
if not r.get("ok") or r["result"].get("uuid") != focused["uuid"]:
    fail("with focus elsewhere, the pane socket followed the session's focus instead of "
         f"staying on its own pane: got {r.get('result', {}).get('uuid')!r}")
print("scope: it stays on its own pane while another pane holds focus")

# --- session-wide calls are refused by name ----------------------------------

for verb in ("panes", "tabs", "session", "ui", "floats"):
    r = call(pane_sock, verb)
    if r.get("ok"):
        fail(f"`{verb}` was ANSWERED on a pane's socket: {str(r)[:200]} — a pane's socket must "
             "not describe the session")
    if "pane" not in (r.get("error") or "").lower():
        fail(f"`{verb}` was refused without saying it is a pane socket: {r.get('error')!r}")
print("refusal: panes/tabs/session/ui/floats are refused by name, not half-answered")

# --- another pane's uuid resolves to nothing ---------------------------------

r = call(pane_sock, "pane", other["uuid"])
if r.get("ok") and isinstance(r.get("result"), dict) and r["result"].get("uuid") == other["uuid"]:
    fail("the pane socket answered about ANOTHER pane when handed its uuid")
if r.get("ok") and isinstance(r.get("result"), dict) and r["result"].get("uuid") == focused["uuid"]:
    fail("a selector naming another pane was silently retargeted to the caller's own pane; "
         "for a write that would send keystrokes to the wrong place")
print("refusal: another pane's uuid resolves to nothing, and is not retargeted")

# The same rule for a WRITE, which is where getting it wrong actually costs
# something: keystrokes delivered to a pane the caller does not own.
LEAK = os.path.join(WD, "leaked")
call(pane_sock, "send", other["uuid"], f'printf leaked > {LEAK}\n')
time.sleep(2.0)
if os.path.exists(LEAK):
    fail("`send` to another pane's uuid on a pane socket WROTE INTO THAT PANE — a program in one "
         "pane can type into another")
MINE = os.path.join(WD, "mine")
call(pane_sock, "send", focused["uuid"], f'printf mine > {MINE}\n')
deadline = time.time() + 15
while time.time() < deadline and not os.path.exists(MINE):
    time.sleep(0.3)
if not os.path.exists(MINE):
    fail("`send` to the socket's OWN pane did not arrive; the scope refuses everything, which "
         "would make the pane socket useless rather than safe")
print("write: send reaches its own pane and cannot reach the other one")

# --- access it was not granted ------------------------------------------------

r = call(pane_sock, "keys", "ctrl+alt+d")
if r.get("ok"):
    fail("`keys` worked on a pane's socket; pressing a chord AT HEXE is session-wide and the "
         "pane socket holds no `keyboard` access")
print("access: a verb needing access it does not hold is refused")

# --- verbs() tells the truth about THIS door ---------------------------------
#
# A list that disagrees with the gate is worse than no list: a client believes
# it and acts on it. So every name offered must actually get past the gate, and
# every name withheld must actually be refused.
GATE = ("access, which this", "is about the whole session")
sess_verbs = {v["name"] for v in (call(sess_sock, "verbs").get("result") or [])}
pane_verbs = {v["name"] for v in (call(pane_sock, "verbs").get("result") or [])}
if not sess_verbs:
    fail("`verbs` is not answered at all; a family where one tool has the handshake and "
         "another does not is not one family")
if not pane_verbs < sess_verbs:
    fail(f"the pane socket's verbs are not a strict subset of the session's: "
         f"{sorted(pane_verbs - sess_verbs)} extra")
disagree = []
for name in sorted(sess_verbs):
    err = (call(pane_sock, name).get("error") or "")
    gated = any(g in err for g in GATE)
    if name in pane_verbs and gated:
        disagree.append(f"offered but refused: {name}")
    if name not in pane_verbs and not gated:
        disagree.append(f"withheld but callable: {name}")
if disagree:
    fail("`verbs` disagrees with the gate — " + "; ".join(disagree))
sample = next(iter(call(sess_sock, "verbs")["result"]))
for field in ("name", "about", "access"):
    if field not in sample:
        fail(f"a verbs entry is missing `{field}`: {sample}")
print(f"verbs: {len(pane_verbs)} of {len(sess_verbs)} offered here, and every one agrees with "
      "the gate")

# --- the session socket is untouched -----------------------------------------

r = call(sess_sock, "panes")
if not r.get("ok") or not isinstance(r["result"], list) or len(r["result"]) < 2:
    fail(f"the session's own socket lost `panes`: {str(r)[:200]} — the narrowing leaked out of "
         "the pane door")
r = call(sess_sock, "pane", other["uuid"])
if not r.get("ok") or r["result"].get("uuid") != other["uuid"]:
    fail("the session's own socket can no longer select an arbitrary pane")
print(f"session: the session's own socket still sees all {len(call(sess_sock, 'panes')['result'])} "
      "panes and selects any of them")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: a pane has its own socket, scoped to itself when it binds")
