#!/usr/bin/env python3
"""A daemon that would not stop keeps its socket.

When a frontend meets a daemon from a different build it stops that daemon and
deletes its socket, so a replacement can bind. Deleting is only safe once the
old daemon is actually gone: a unix socket path cannot be re-linked, so an
unlinked path plus a live daemon still holding the instance lock is a mux that
nothing can reach and nothing can rebuild. `hexe session status` reports "not
running" while the daemon sits there listening on an inode with no name.

That is not hypothetical -- it happened, from mixing an installed hexe with a
freshly built one. `terminateStaleDaemon` has several ways to leave the daemon
running (no recorded pid, a pid that is not ours, a refused signal, a daemon
that outlives the kill wait) and the caller deleted the socket regardless.

Reproduced here without needing two builds: any failed handshake marks the
daemon stale, so this stands up a fake one that accepts connections, answers
with garbage, holds the instance lock, and records a pid that is alive but is
not a ses daemon -- so termination must refuse. The socket must survive.
"""
import atexit, fcntl, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"stale{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
INST = f"smk{os.getpid()}"
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)

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
lock_fd = None
serving = threading.Event()


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
    print("FAIL: timed out")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(120)

# hexe puts an instance's sockets in a per-profile directory; find it the same
# way rather than assuming the layout.
SOCK_DIR = os.path.join(RUN, "hexe", INST)
os.makedirs(SOCK_DIR, exist_ok=True)
SES = os.path.join(SOCK_DIR, "ses.sock")
LOCK = SES + ".lock"

# A process that is alive but is emphatically not a ses daemon, so
# `pidIsSesDaemon` refuses to signal it -- one of the ways termination gives up
# while the daemon is still there.
decoy = subprocess.Popen(["sleep", "300"])
procs.append(decoy)
with open(LOCK, "w") as fh:
    fh.write(str(decoy.pid))

# Hold the instance lock the way a live daemon does. Nothing may conclude the
# instance is free while this is held.
lock_fd = os.open(LOCK, os.O_RDWR)
fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def fake_daemon():
    """Accept, then answer with something that is not a valid hello.

    A failed handshake is exactly how a build mismatch presents itself, and it
    is what puts the frontend on the stale-daemon path.
    """
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.unlink(SES)
    except FileNotFoundError:
        pass
    srv.bind(SES)
    srv.listen(16)
    srv.settimeout(0.3)
    serving.set()
    while not stop.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            conn.sendall(b"\x00" * 64)   # not a hello any build would accept
        except OSError:
            pass
        finally:
            conn.close()
    srv.close()


stop = threading.Event()
threading.Thread(target=fake_daemon, daemon=True).start()
if not serving.wait(10):
    fail("the fake daemon never started listening")
if not os.path.exists(SES):
    fail("the fake daemon did not create its socket")
print(f"setup: a daemon that will not stop is holding {os.path.basename(SES)} and the instance lock")

# A frontend meets it, decides it is stale, and tries to take over.
m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "stale"], stdin=sl, stdout=sl, stderr=sl,
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

# Long enough to cover the SIGTERM wait, the SIGKILL escalation and the retry
# behind them -- the window in which the socket used to disappear.
time.sleep(20)

if not os.path.exists(SES):
    fail("the frontend deleted the socket of a daemon it could not stop. "
         "A unix socket path cannot be re-linked, so that daemon is now "
         "unreachable and un-replaceable: every client reports 'daemon is not "
         "running' while it sits there listening")
print("socket: survived a takeover attempt that could not stop the daemon")

# The lock is the authority on whether a daemon is still there, and it is.
try:
    probe = os.open(LOCK, os.O_RDONLY)
    try:
        fcntl.flock(probe, fcntl.LOCK_SH | fcntl.LOCK_NB)
        fcntl.flock(probe, fcntl.LOCK_UN)
        fail("the instance lock came free, so this run proved nothing: the "
             "daemon it was supposed to fail to stop is gone")
    except OSError:
        pass
    finally:
        os.close(probe)
except OSError as e:
    fail(f"could not probe the instance lock: {e}")
print("lock: still held, so the socket really did belong to a live daemon")

# And the instance is still reachable: something is listening on that path.
try:
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(5)
    c.connect(SES)
    c.close()
except OSError as e:
    fail(f"the socket exists but nothing accepts on it ({e}); the instance is "
         f"still bricked, just less visibly")
print("reachable: the surviving socket still accepts connections")

stop.set()
cleanup()
print("PASS: a daemon that cannot be stopped keeps its socket, so the instance stays reachable")
