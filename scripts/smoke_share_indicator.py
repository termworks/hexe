#!/usr/bin/env python3
"""hexe knows when a pane is being watched, and can cut it off.

Two claims, both of which have to be true before a share indicator is worth
drawing:

  * when something connects as an observer, the count reaches the *frontend* --
    the pod owns the observer sockets, so every other process is working from a
    report. If that report does not arrive, a "shared" badge is a guess;
  * `share(sel, false)` disconnects the watcher AND keeps it out. Dropping
    alone loses the race against a reconnect, which would make a stop button
    that silently did not stop.

The second is checked by reconnecting after the block: an observer that gets in
anyway is the bug this test exists for.
"""
import atexit, fcntl, json, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"shareind{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"

open(os.path.join(CF, "hexe", "init.lua"), "w").write("local hexe = require('hexe')\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_FLOAT", "HEXE_PAINTER_SOCKET", "HEXE_ENV_FD", "HEXE_BIN", "HEXE_API_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []
observers = []


def cleanup():
    for o in observers:
        try: o.close()
        except OSError: pass
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
signal.alarm(150)


def api(*args):
    r = subprocess.run([HEXE, "api", *args], env=env, cwd=WD,
                       capture_output=True, text=True, timeout=25)
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return {}


def panes():
    return api("panes").get("result") or []


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "shareind"], stdin=sl, stdout=sl,
                      stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 40
pane = None
while time.time() < deadline and pane is None:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    for p in panes():
        if p.get("pod_socket"):
            pane = p
            break
    time.sleep(0.5)
if pane is None:
    fail("no pane with a pod_socket appeared")

uuid, sock_path = pane["uuid"], pane["pod_socket"]


def pane_now():
    for p in panes():
        if p.get("uuid") == uuid:
            return p
    return {}


def wait_for(pred, what, secs=25):
    end = time.time() + secs
    last = None
    while time.time() < end:
        last = pane_now()
        if pred(last):
            return last
        time.sleep(0.4)
    fail(f"{what}; last saw observers={last.get('observers')!r} "
         f"shared={last.get('shared')!r} share_blocked={last.get('share_blocked')!r}")


start = pane_now()
if "observers" not in start:
    fail("the pane record has no `observers` field; nothing can draw a share badge")
if start.get("shared"):
    fail(f"a pane nobody is watching reports shared={start.get('shared')!r}")


def observe():
    o = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    o.settimeout(10)
    o.connect(sock_path)
    o.sendall(bytes([0x04, 4]))
    observers.append(o)
    return o


# 1. A watcher arrives, and the frontend finds out.
observe()
after = wait_for(lambda p: p.get("observers") == 1, "the frontend never saw the observer arrive")
if not after.get("shared"):
    fail("observers==1 but shared is false; the two disagree about the same fact")
print("connect: the frontend sees 1 observer")

observe()
wait_for(lambda p: p.get("observers") == 2, "a second observer did not reach the frontend")
print("count: a second watcher is counted too")

# 2. A watcher leaving is noticed. The pod finds out on its next write, so give
#    the pane something to say.
observers.pop().close()
os.write(m, b"echo bye\r")
wait_for(lambda p: p.get("observers") == 1, "a disconnected observer was still counted")
print("disconnect: the count follows a watcher down")

# 3. The kill switch: drops who is there, and keeps the next one out.
res = api("share", json.dumps(uuid), "false")
if not res.get("ok"):
    fail(f"`api share` failed: {res}")
blocked = wait_for(lambda p: p.get("share_blocked") is True, "share_blocked never became true")
if blocked.get("observers") != 0:
    fail(f"blocking left {blocked.get('observers')} observers connected")
if blocked.get("shared"):
    fail("a blocked pane still reports shared")
print("stop: blocking dropped every watcher")

try:
    late = observe()
    late.sendall(b"")
    got = late.recv(64)
    if got:
        fail("an observer connected AFTER the pane was blocked and received "
             f"{len(got)} bytes -- stop sharing did not stop it")
except (ConnectionResetError, BrokenPipeError, socket.timeout, OSError):
    pass
print("stop: a reconnecting watcher is refused, not raced")

# 4. And it is reversible, or it would be a one-way door.
api("share", json.dumps(uuid), "true")
wait_for(lambda p: p.get("share_blocked") is False, "sharing could not be re-enabled")
observe()
wait_for(lambda p: p.get("observers") == 1, "no one could watch again after unblocking")
print("resume: sharing can be turned back on")

# 5. The CLI answers the same question without a frontend in the path.
r = subprocess.run([HEXE, "pod", "share", "-u", uuid, "--json"], env=env, cwd=WD,
                   capture_output=True, text=True, timeout=25)
try:
    cli = json.loads(r.stdout or "{}")
except json.JSONDecodeError:
    fail(f"`hexe pod share --json` printed no JSON: {r.stdout!r} {r.stderr!r}")
if cli.get("observers") != 1:
    fail(f"the CLI disagrees with the frontend: {cli}")
print("cli: `hexe pod share` reports the same count")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: hexe sees who is watching, and can cut them off")
