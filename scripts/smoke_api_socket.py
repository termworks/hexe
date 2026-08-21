#!/usr/bin/env python3
"""The live API, answered over a socket to a program that is not hexe.

Everything the mux knows about its panes has one definition, in Lua. The
control socket calls those same functions and encodes what they return, so an
outside client sees the mux's own answer rather than a second implementation of
it that can drift.

What matters here is not that a request gets a reply — it is that:

  * the reply is the truth (a mutation through the socket is visible in a later
    read through the socket, and in the mux itself);
  * a client cannot take the mux down. The frontend loop drives every pane, so
    a socket that blocks it would freeze every program in the session. Garbage
    frames, oversized lengths, a client that vanishes mid-request and one that
    never reads its reply are all thrown at it, and the panes must keep running.
"""
import atexit, fcntl, json, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"apisock{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSION = "apisock"

open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    "local hexe = require('hexe')\nreturn hexe.setup({})\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
# The socket directory is per-profile, so it is discovered rather than assumed:
# hard-coding the layout would make this test fail for a reason that has nothing
# to do with the socket.
def find_socket():
    for root, _dirs, files in os.walk(RUN):
        for f in files:
            if f == f"api@{SESSION}.sock":
                return os.path.join(root, f)
    return None


SOCK = None
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


def watchdog(_sig, _frm):
    """A stalled mux would otherwise hang this script rather than fail it.

    The failure being tested for -- a control socket that parks the frontend
    loop -- looks exactly like "no progress", so the timeout IS the assertion
    and has to report itself rather than let the suite sit there.
    """
    print("FAIL: timed out; the mux stopped making progress, which is what a "
          "control socket blocking the frontend loop looks like from outside")
    # Flushed explicitly: stdout to a pipe is block-buffered and os._exit does
    # not flush, so the diagnosis would be discarded exactly when it is needed.
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(150)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush()
    cleanup()
    sys.exit(1)


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", SESSION], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 25
while time.time() < deadline and SOCK is None:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode} before binding the control socket")
    SOCK = find_socket()
    time.sleep(0.3)
if SOCK is None:
    fail(f"no api@{SESSION}.sock anywhere under {RUN} after 25s")

mode = os.stat(SOCK).st_mode & 0o777
if mode != 0o600:
    fail(f"the control socket is mode {mode:o}; it carries full control of the "
         f"session and must not be reachable by other users")
print(f"socket: bound at api@{SESSION}.sock, mode {mode:o}")


def call(payload, expect_reply=True, read_reply=True):
    """One request. `payload` is bytes so malformed frames can be sent too."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(SOCK)
    s.sendall(payload)
    if not read_reply:
        s.close()
        return None
    hdr = b""
    while len(hdr) < 4:
        chunk = s.recv(4 - len(hdr))
        if not chunk:
            s.close()
            return None
        hdr += chunk
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        chunk = s.recv(need - len(body))
        if not chunk:
            break
        body += chunk
    s.close()
    return json.loads(body)


def api(name, arg=None):
    req = {"call": name}
    if arg is not None:
        req["arg"] = arg
    body = json.dumps(req).encode()
    return call(struct.pack(">I", len(body)) + body)


def alive():
    return fe.poll() is None


# ------------------------------------------------------------------ reading
r = api("session")
if not r or not r.get("ok"):
    fail(f"`session` did not answer: {r}")
if not isinstance(r.get("result"), dict):
    fail(f"`session` returned {r.get('result')!r}, not a record — the socket is "
         f"not returning what the live API returns")
if r["result"].get("name") != SESSION:
    fail(f"`session` reported name {r['result'].get('name')!r}, expected {SESSION!r}")
print(f"read: session is {r['result']['name']} at {r['result'].get('root')}")

r = api("panes")
if not r or not r.get("ok") or not isinstance(r["result"], list):
    fail(f"`panes` did not return a list: {r}")
if len(r["result"]) != 1:
    fail(f"a fresh session should have one pane; got {len(r['result'])}")
pane = r["result"][0]
for field in ("uuid", "width", "height", "cwd", "alive"):
    if field not in pane:
        fail(f"the pane record is missing `{field}`; the socket is not returning "
             f"what the Lua API returns")
print(f"read: pane {pane['uuid'][:8]} {pane['width']}x{pane['height']} in {pane.get('cwd')}")

# A string argument, not a table: the JSON->Lua bridge must carry scalars too.
r = api("count", "panes")
if not r or not r.get("ok") or r["result"] != 1:
    fail(f"`count 'panes'` returned {r}; expected 1")
print("read: scalar arguments reach the API (count 'panes' == 1)")

# ----------------------------------------------------------------- writing
r = api("act", {"type": "split.v"})
if not r or not r.get("ok") or r["result"] is not True:
    fail(f"`act split.v` was refused: {r}")

# Polled, not slept on: spawning a pane involves the daemon and a pty, and a
# fixed wait turns a slow machine into a false failure that reads exactly like
# a real one ("the write did not take effect").
seen = None
deadline = time.time() + 20
while time.time() < deadline:
    r = api("count", "panes")
    seen = r.get("result") if r else None
    if seen == 2:
        break
    time.sleep(0.4)
if seen != 2:
    fail(f"after splitting through the socket the mux still reports {seen} panes "
         f"after 20s. A write that no later read can see means the socket is not "
         f"acting on live state")
print("write: a split through the socket is visible in the next read (2 panes)")

# And the mux itself agrees, not just the socket's own view of itself.
# Confirmed down a different path entirely -- CLI to the session daemon, which
# never consults the frontend's Lua. If only the socket believed in the new
# pane, the socket would be reporting its own wishes.
info = subprocess.run([HEXE, "session", "list", "--json"], env=env, cwd=WD,
                      capture_output=True, text=True, timeout=20)
try:
    listing = json.loads(info.stdout)
except (ValueError, TypeError):
    fail(f"`hexe session list --json` gave nothing parseable: {info.stdout!r} {info.stderr!r}")
match = [s for s in listing.get("connected", []) if s.get("name") == SESSION]
if not match:
    fail(f"the daemon does not list the session the socket described: {listing}")
if match[0].get("pane_count") != 2:
    fail(f"the daemon counts {match[0].get('pane_count')} panes but the socket "
         f"reported 2; the socket is not describing the real session")
print(f"write: the daemon agrees independently ({match[0]['pane_count']} panes)")

# ------------------------------------------------------------------ abuse
# Each of these has killed a naive server. The panes must not care.
r = api("nosuchcall")
if not r or r.get("ok") is not False:
    fail(f"an unknown call should be refused, got {r}")

r = call(struct.pack(">I", 5) + b"notjs")
if not r or r.get("ok") is not False:
    fail(f"malformed JSON should be refused, got {r}")

# A length header that promises far more than will ever arrive.
call(struct.pack(">I", 0xFFFFFFF0) + b"{}", read_reply=True)

# A client that disappears mid-request.
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(SOCK)
s.sendall(struct.pack(">I", 4096) + b'{"call":"pan')
s.close()

# A client that asks and then never reads the answer.
hoarders = []
for _ in range(4):
    h = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    h.connect(SOCK)
    body = json.dumps({"call": "panes"}).encode()
    h.sendall(struct.pack(">I", len(body)) + body)
    hoarders.append(h)

# More connections at once than the server keeps slots for.
floods = []
for _ in range(24):
    try:
        f = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        f.connect(SOCK)
        floods.append(f)
    except OSError:
        pass

time.sleep(3.0)
if not alive():
    fail("the frontend died while being abused through the control socket")


def responsive(timeout_s):
    """Does the mux still answer? A stalled loop leaves a live process, so
    liveness alone would pass while every pane in the session is frozen."""
    end = time.time() + timeout_s
    while time.time() < end:
        try:
            s2 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s2.settimeout(max(0.5, end - time.time()))
            s2.connect(SOCK)
            body = json.dumps({"call": "session"}).encode()
            s2.sendall(struct.pack(">I", len(body)) + body)
            hdr = b""
            while len(hdr) < 4:
                chunk = s2.recv(4 - len(hdr))
                if not chunk:
                    break
                hdr += chunk
            s2.close()
            if len(hdr) == 4:
                return True
        except (OSError, socket.timeout):
            pass
        time.sleep(0.3)
    return False


# Asked while the non-readers and the flood are STILL holding their connections:
# that is when a blocking accept or a blocking write would have the loop parked.
if not responsive(12):
    fail("the mux stopped answering while clients held connections open. The "
         "frontend loop drives every pane, so a control socket that waits on a "
         "client freezes every program in the session")
print("abuse: still answering while non-readers hold their connections")

for h in hoarders + floods:
    try: h.close()
    except OSError: pass
time.sleep(1.0)

# The session must still be answering, and its panes still running.
if not responsive(12):
    fail("after the abuse the control socket stopped answering")
r = api("count", "panes")
if not r or r.get("result") != 2:
    fail(f"after the abuse the mux reports {r}; state was damaged")
print("abuse: bad frames, huge lengths, vanished clients, non-readers, "
      "connection flood — socket still answering, panes untouched")

if not alive():
    fail("the frontend died during the checks")

cleanup()
print("PASS: the live API answers outside the process, and no client can stall the mux")
