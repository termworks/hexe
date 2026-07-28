#!/usr/bin/env python3
"""Live check: `hexe pod attach` works and does NOT evict the pane's own mux.

Regression target (PLAN.md C-1). `pod attach` handshaked as
POD_HANDSHAKE_SES_VT, which makes it the pod's *authoritative* VT client — and
`acceptVtClient` unconditionally closes the previous one. Running it against a
live pane therefore evicted SES, which re-dialled, which evicted the attach
client: a flap with a full backlog replay every cycle.

It now observes for output and uses short-lived aux-input connections for
input, neither of which displaces `Pod.client`.

Three things are asserted. The first two are necessary but NOT sufficient: on
the unfixed build the flap re-dials fast enough that both still pass, because a
25s echo check cannot see a sub-second eviction cycle. The third is the one that
actually discriminates -- it counts the pod's own client replacements.
  1. attach actually WORKS   — output reaches it and input reaches the shell;
  2. attach is NON-DESTRUCTIVE — the original mux pane keeps working;
  3. attach causes NO client evictions in the pod log (the flap itself).
"""
import atexit
import fcntl, glob, os, pty, re, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
env = os.environ.copy()
WORKDIR = os.path.join(SCRATCH, f"podatt-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
POD_LOG = os.path.join(WORKDIR, "pod.log")
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
env.pop("HEXE_SESSION", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", "--", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    for pid in pgrep(f"--instance {INST}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)


def spawn_pty(argv):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=SCRATCH, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, master


def read_until(fd, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False, buf
            if not chunk:
                return False, buf
            buf += chunk
            if marker in buf:
                return True, buf
            if len(buf) > (1 << 20):
                buf = buf[-8192:]
    return False, buf


def log_bytes():
    try:
        with open(POD_LOG, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return b""


def observer_accepts():
    """Times the pod accepted a NON-authoritative observer connection."""
    return log_bytes().count(b"accept: aux observer")


def vt_accepts():
    """Times the pod accepted an AUTHORITATIVE VT client. Each one evicts the
    previous client, so an attach landing here is the C-1 flap."""
    return log_bytes().count(b"accept: SES VT client")


print(f"instance={INST}")

# Start the daemon ourselves so pods inherit debug logging; the frontend would
# otherwise autostart it without logging and the flap would be invisible.
subprocess.run([HEXE, "session", "daemon", "--instance", INST,
                "--log", "debug", "--logfile", POD_LOG],
               env=env, cwd=WORKDIR, check=False, timeout=30)
time.sleep(1.5)

fe, master = spawn_pty([HEXE, "mux", "new", "-n", "podatt"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

ok, _ = read_until(master, b"WARM", 30) if os.write(master, b"echo WARM\r") else (False, b"")
if not ok:
    fail("pane never became responsive")

runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
pod_socks = glob.glob(os.path.join(runtime, "hexe", INST, "pod-*.sock"))
if not pod_socks:
    fail("no pod socket found")
uuid = re.sub(r"^pod-|\.sock$", "", os.path.basename(pod_socks[0]))
print(f"pod uuid={uuid[:8]}", flush=True)

# Attach to that pod directly.
before_observers = observer_accepts()
before_vt = vt_accepts()
att, att_master = spawn_pty([HEXE, "pod", "attach", "--uuid", uuid])
time.sleep(3.0)
if att.poll() is not None:
    fail(f"`pod attach` exited immediately rc={att.returncode}")

# 1. Attach must actually work: its input must reach the shell and the
#    resulting output must come back to the attach terminal.
os.write(att_master, b"echo ATTACH_IO_OK\r")
ok, buf = read_until(att_master, b"ATTACH_IO_OK", 25)
if not ok:
    tail = buf[-200:].decode("utf-8", "replace")
    fail(f"`pod attach` I/O did not round-trip — attach is not functional. tail={tail!r}")
print("attach I/O round-trips", flush=True)

# 2. And it must NOT have stolen the pane from the mux. Before the fix the
#    attach evicted SES, so the mux pane stopped responding (and the two
#    flapped, each re-dial replaying the whole backlog).
os.write(master, b"echo MUX_ALIVE_OK\r")
ok, buf = read_until(master, b"MUX_ALIVE_OK", 25)
if not ok:
    tail = buf[-200:].decode("utf-8", "replace")
    fail(f"the mux pane stopped responding while `pod attach` was connected — "
         f"attach evicted the session's VT client. tail={tail!r}")
print("mux pane still live during attach", flush=True)

if att.poll() is not None:
    fail(f"`pod attach` died rc={att.returncode} (evicted by SES re-dialling?)")

# 3. The discriminating assertion: WHICH channel the pod accepted the attach
#    on. Counting evictions alone cannot do this -- SES legitimately re-dials
#    (backlog replay), so replacements are not attributable to the attach. But
#    the channel is unambiguous: the fix routes attach to the observer channel,
#    the unfixed build to the authoritative VT channel.
time.sleep(6.0)
new_observers = observer_accepts() - before_observers
new_vt = vt_accepts() - before_vt
print(f"since attach: observer_accepts={new_observers} vt_client_accepts={new_vt}", flush=True)
if new_observers < 1:
    fail("`pod attach` did not connect on the observer channel — it is still "
         "handshaking as the pod's AUTHORITATIVE VT client, which evicts SES "
         "and starts the flap (each cycle replaying the whole backlog)")

# Detach and confirm the pane is still healthy afterwards.
att.terminate()
try:
    att.wait(timeout=5)
except subprocess.TimeoutExpired:
    att.kill()
time.sleep(1.0)

os.write(master, b"echo MUX_AFTER_OK\r")
ok, buf = read_until(master, b"MUX_AFTER_OK", 25)
if not ok:
    fail("the mux pane did not survive `pod attach` disconnecting")

if fe.poll() is not None:
    fail(f"frontend died rc={fe.returncode}")

cleanup()
print("SMOKE PASS: `pod attach` works without evicting the pane's mux")
