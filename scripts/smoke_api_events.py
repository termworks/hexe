#!/usr/bin/env python3
"""Events are pushed to a subscriber, so a client never has to poll.

A gateway that polls for layout changes is either late or wasteful, and on a
phone it is both. A subscribed connection stays open and receives the same
payload the Lua event handlers get — the fan-out happens at the one place every
event already passes through, so there is no second list of events to keep in
step.

The claims worth pinning, in the order they can break:

  * an event arrives without anyone asking for it, and carries its payload;
  * a filtered subscription gets what it asked for and NOT what it did not
    (a filter that quietly passes everything looks identical to a working one
    until the client is drowning in traffic);
  * a subscriber that stops reading does not block anyone else, and does not
    stall the mux.

Not covered here: the 1 MiB backlog cap that eventually drops a subscriber
which never reads. The traffic this test can generate is nowhere near it, so
the cap is asserted by reading the code, not by this script.
"""
import atexit, fcntl, json, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"apiev{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSION = "apiev"

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
procs = []
SOCK = None


def find_socket():
    for root, _dirs, files in os.walk(RUN):
        for f in files:
            if f == f"api@{SESSION}.sock":
                return os.path.join(root, f)
    return None


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


def watchdog(_sig, _frm):
    print("FAIL: timed out waiting for the mux; a control socket that blocks "
          "the frontend loop looks exactly like this from outside")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(150)


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
    fail("the control socket never appeared")


def frame(obj):
    body = json.dumps(obj).encode()
    return struct.pack(">I", len(body)) + body


def recv_frame(s):
    hdr = b""
    while len(hdr) < 4:
        chunk = s.recv(4 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        chunk = s.recv(need - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


def call(obj, timeout=10):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(frame(obj))
    r = recv_frame(s)
    s.close()
    return r


def subscribe(spec, timeout=20):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(frame({"subscribe": spec}))
    ack = recv_frame(s)
    if not ack or not ack.get("ok"):
        fail(f"subscribe was refused: {ack}")
    return s


def collect(s, seconds):
    """Every event that arrives within `seconds`, unsolicited."""
    got = []
    end = time.time() + seconds
    while time.time() < end:
        s.settimeout(max(0.2, end - time.time()))
        try:
            ev = recv_frame(s)
        except (socket.timeout, TimeoutError):
            break
        except OSError:
            break
        if ev is None:
            break
        got.append(ev)
    return got


# ------------------------------------------------------- events arrive at all
sub = subscribe(True)
print("subscribe: accepted a stream subscription")

# Something that certainly raises events: a new tab, then a split.
call({"call": "act", "arg": {"type": "tab.new"}})
call({"call": "act", "arg": {"type": "split.v"}})

events = collect(sub, 8)
if not events:
    fail("nothing arrived on the subscription after creating a tab and a split. "
         "A client that must poll for layout changes is either late or wasteful, "
         "which is the whole reason this exists")

names = [e.get("event") for e in events]
print(f"stream: {len(events)} events arrived unasked: {sorted(set(names))}")

for e in events:
    if "event" not in e or "payload" not in e:
        fail(f"an event frame is missing its envelope: {e}")
    if not isinstance(e["payload"], dict) or "now_ms" not in e["payload"]:
        fail(f"the payload is not the one Lua handlers receive: {e}")
print("stream: each frame carries the same payload a Lua handler gets")

# --------------------------------------------------------- filters must filter
# A filter that silently passes everything looks like a working one right up
# until a phone is drowning in traffic it never asked for.
want = "tab_created"
noise = [n for n in set(names) if n != want]
if not noise:
    fail(f"only {names} were seen, so a filter cannot be shown to exclude "
         f"anything; this check would prove nothing")

filtered = subscribe([want])
call({"call": "act", "arg": {"type": "tab.new"}})
call({"call": "act", "arg": {"type": "split.v"}})
got = collect(filtered, 8)
kinds = {e.get("event") for e in got}
if not kinds:
    fail(f"a subscription filtered to {want!r} received nothing at all, though "
         f"a tab was created")
if kinds != {want}:
    fail(f"a subscription filtered to {want!r} also received {sorted(kinds - {want})}; "
         f"the filter is not filtering")
print(f"filter: asked for {want!r} and got only that ({len(got)} frames)")
filtered.close()

# ------------------------------------------ a stalled subscriber isolates
# Subscribed, then never reads. Well short of the backlog cap, so what is
# checked here is that everyone else keeps working -- not the eventual drop.
lazy = subscribe(True)
for _ in range(60):
    call({"call": "act", "arg": {"type": "split.v"}})
    call({"call": "act", "arg": {"type": "tab.new"}})
time.sleep(2.0)

if fe.poll() is not None:
    fail("the frontend died while a subscriber refused to read")

# One-shot calls still work while that connection sits there unread.
r = call({"call": "session"})
if not r or not r.get("ok"):
    fail("a subscriber that stopped reading blocked ordinary calls")
print("backpressure: a non-reading subscriber does not block other clients")
lazy.close()

sub.close()
time.sleep(1.0)

r = call({"call": "count", "arg": "panes"})
if not r or not r.get("ok"):
    fail("the socket stopped answering after subscribers came and went")
print(f"teardown: subscribers closed, socket still serving ({r['result']} panes)")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: events are pushed, filters are honoured, slow subscribers cannot stall the mux")
