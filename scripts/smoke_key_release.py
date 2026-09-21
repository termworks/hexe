#!/usr/bin/env python3
"""Live check: a pane that asks for key releases is told about them.

Regression target: an application in a hexe pane could never tell a held key
from a tapped one. Holding looked like a stream of fresh presses and letting go
produced nothing, so "hold to charge" was impossible to write and anything bound
to a press re-fired for as long as the key was down.

Two causes, both here:
  1. `loop_input.zig` forwarded only `.press`; releases were dropped outright.
  2. `key_translate.encodeKey` never set `KeyEvent.action`, which defaults to
     `.press` -- so a release, had one been forwarded, would have arrived as a
     phantom SECOND press. Worse than dropping it.

A release must reach a pane that set the Kitty `report_events` flag, carrying
the event type `3`, and must NOT reach a pane that never asked.
"""
import atexit
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"keyrelease-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
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


def spawn():
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "keys"], stdin=slave, stdout=slave,
                         stderr=slave, env=env, cwd=WORKDIR, start_new_session=True)
    os.close(slave)
    procs.append(p)
    return p, master


def read_until(fd, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 262144)
            except OSError:
                return False, buf
            if not chunk:
                return False, buf
            buf += chunk
            if marker in buf:
                return True, buf
    return False, buf


# One program in the pane, testing both halves in order: it reads for a while
# with the protocol OFF, then turns it ON and keeps reading. One process and one
# shell command, because getting a shell prompt back after a raw-mode reader is
# its own fight and the test does not need one.
#
# It writes to a FILE rather than the screen: what the pane RECEIVES is the
# thing under test, and the screen would only show what hexe chose to draw.
READER = os.path.join(WORKDIR, "reader.py")
with open(READER, "w") as f:
    f.write(
        "import os, select, signal, sys, termios, time, tty\n"
        "out = open(sys.argv[1], 'wb', buffering=0)\n"
        "fd = sys.stdin.fileno()\n"
        "old = termios.tcgetattr(fd)\n"
        "tty.setraw(fd)\n"
        "signal.alarm(40)\n"
        "out.write(b'PHASE1\\n')\n"
        "armed = False\n"
        "stage = 1\n"
        "start = time.time()\n"
        "try:\n"
        "    while True:\n"
        "        r, _, _ = select.select([fd], [], [], 0.2)\n"
        "        if r:\n"
        "            b = os.read(fd, 1024)\n"
        "            if not b: break\n"
        "            out.write(b)\n"
        "        if not armed and time.time() - start > 6:\n"
        # Every flag on. `report_events` is the one that asks for releases at
        # all; `report_all` is what extends that to keys which produce text,
        # such as space.
        # `report_events` WITHOUT `report_all` first. The protocol does not
        # report releases for keys that produce text under that combination,
        # and sending one anyway is what made applications show the key twice.
        "            sys.stdout.write('\\x1b[>2u'); sys.stdout.flush()\n"
        "            armed = True\n"
        "            time.sleep(0.5)\n"
        "            out.write(b'\\nPHASE2\\n')\n"
        "        if armed and stage == 1 and time.time() - start > 14:\n"
        "            sys.stdout.write('\\x1b[>15u'); sys.stdout.flush()\n"
        "            stage = 2\n"
        "            time.sleep(0.5)\n"
        "            out.write(b'\\nPHASE3\\n')\n"
        "finally:\n"
        "    termios.tcsetattr(fd, termios.TCSADRAIN, old)\n"
    )

print(f"instance={INST}")

fe, master = spawn()
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"stty -echo; echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")

got = os.path.join(WORKDIR, "received.bin")
os.write(master, f"python3 {READER} {got}\r".encode())


def wait_for_marker(marker, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if os.path.exists(got) and marker in open(got, "rb").read():
            return True
        time.sleep(0.2)
    return False


if not wait_for_marker(b"PHASE1", 30):
    fail("the reader never started")
time.sleep(1.0)

# ---- the protocol is OFF: a release must not be forwarded -------------------
os.write(master, b"\x1b[32;1u")
time.sleep(0.6)
os.write(master, b"\x1b[32;1:3u")
time.sleep(1.0)

if not wait_for_marker(b"PHASE2", 30):
    fail("the reader never armed the protocol")
time.sleep(1.0)

raw = open(got, "rb").read()
phase1 = raw.split(b"PHASE1\n", 1)[1].split(b"\nPHASE2", 1)[0]
print("unarmed pane received:", repr(phase1[:60]), flush=True)

# It must have seen the PRESS, or the negative result below means nothing.
if b" " not in phase1:
    fail("the unarmed pane never saw the press either, so this proves nothing")
if b":3" in phase1:
    fail("a pane that never asked for key events was sent a release anyway")
print("unarmed: the press arrives, the release does not", flush=True)

# ---- report_events but NOT report_all: a text key must stay single ---------
os.write(master, b"\x1b[32;1u")
time.sleep(0.6)
os.write(master, b"\x1b[32;1:3u")
time.sleep(1.0)

if not wait_for_marker(b"PHASE3", 40):
    fail("the reader never asked for the full flag set")
time.sleep(1.0)

raw = open(got, "rb").read()
phase2 = raw.split(b"PHASE2\n", 1)[1].split(b"\nPHASE3", 1)[0]
print("events-only pane received:", repr(phase2[:60]), flush=True)

if b" " not in phase2 and b"32" not in phase2:
    fail("the events-only pane never saw the press, so this proves nothing")
if b":3" in phase2:
    fail("space produces text, so with report_events but no report_all its "
         "release must not be sent — an application reading that as the key "
         "itself shows it twice")
print("events-only: a text key's release is withheld", flush=True)

# ---- every flag on: now the release must arrive, tagged 3 ------------------
os.write(master, b"\x1b[32;1u")
time.sleep(0.6)
os.write(master, b"\x1b[32;1:3u")
time.sleep(1.5)

raw = open(got, "rb").read()
phase3 = raw.split(b"PHASE3\n", 1)[1] if b"PHASE3\n" in raw else b""
print("fully armed pane received:", repr(phase3[:60]), flush=True)

if b"32" not in phase3:
    fail("the armed pane never even saw the press")
if b":3" not in phase3:
    fail("the pane asked for key events and was never told about the release "
         f"— got {phase3!r}")
print("fully armed: the release arrives, tagged :3", flush=True)

# A release must not arrive as a second press: a doubled press is worse than a
# missing release, because the application cannot tell that it is wrong.
if phase3.count(b"[32u") > 1 or phase3.count(b"[32;1u") > 1:
    fail("the release arrived as a second press")
print("the release is not a phantom press", flush=True)

cleanup()
print("SMOKE PASS: key releases reach the panes that asked, and only those")
