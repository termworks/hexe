#!/usr/bin/env python3
"""Live check: reattaching a high-output pane must not garble it.

Regression target: the backlog replay window started at a purely arithmetic
offset (`ring_len - REPLAY_TAIL_CAP`), so on any pane that produced more than
1 MiB it could begin in the MIDDLE of an ANSI escape sequence. The frontend's VT
then starts parsing at, say, the `[` of `\\x1b[38;5;250m`, desyncs, and prints
the rest of the sequence as literal text -- the screen garbles and scrollback is
wrong. Panes under 1 MiB never skip, which is why only busy TUIs showed it.

The replay now starts on a line boundary (a newline cannot occur inside an
escape sequence), and re-sends the alt-screen enter if the window begins after
one.

Asserted after reattach:
  1. the pane is still live;
  2. the LAST marker written before detaching is present;
  3. no escape-sequence FRAGMENT is rendered as visible text.
"""
import atexit
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, f"bigscroll-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
# A smoke run from inside a hexe pane inherits that pane's identity; the new
# frontend then hits the nested-mux confirmation and exits rc=0 with no output,
# which is indistinguishable from a product bug. Scrub the whole set.
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

# Each line carries several escape sequences, so a cut lands inside one with
# high probability. ~1.6MB total comfortably exceeds REPLAY_TAIL_CAP (1MiB),
# which is what makes the replay skip at all.
LINES = 14000
LAST_MARKER = f"TAIL_MARKER_{LINES}"

# Fragments that only ever appear on screen if the parser consumed a partial
# escape sequence and fell back to printing the remainder literally.
FRAGMENTS = ("38;5;", "48;5;", "[0m", "[1m", "?1049")


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


def spawn_frontend(argv):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 150, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=WORKDIR, start_new_session=True)
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
            if len(buf) > (4 << 20):
                buf = buf[-(1 << 20):]
    return False, buf


def drain(fd, seconds):
    deadline = time.time() + seconds
    out = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 262144)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    return out


print(f"instance={INST}")

fe, master = spawn_frontend([HEXE, "mux", "new", "-n", "bigscroll"])
time.sleep(3.0)
if fe.poll() is not None:
    fail("frontend didn't start")

os.write(master, b"echo WARM\r")
ok, _ = read_until(master, b"WARM", 30)
if not ok:
    fail("pane never became responsive")

# A generator whose every line is wrapped in colour escapes, so the 1MiB cut
# almost certainly lands inside one.
gen = os.path.join(WORKDIR, "gen.sh")
with open(gen, "w") as f:
    f.write(
        "#!/bin/sh\n"
        f"i=1; while [ $i -le {LINES} ]; do\n"
        "  printf '\\033[38;5;%dm\\033[1mLINE_%05d\\033[0m \\033[48;5;236mpadpadpadpadpadpadpadpadpadpadpadpadpadpadpadpad\\033[0m\\n' "
        "$((i % 250 + 1)) $i\n"
        "  i=$((i+1))\n"
        "done\n"
        f"echo {LAST_MARKER}\n"
    )
os.chmod(gen, 0o755)

os.write(master, f"sh {gen}\r".encode())
ok, _ = read_until(master, LAST_MARKER.encode(), 240)
if not ok:
    fail("generator never finished")
drain(master, 3.0)
print(f"generated {LINES} coloured lines (>1MiB, so replay must skip)", flush=True)

# Detach hard, then reattach.
os.kill(fe.pid, signal.SIGKILL)
fe.wait()
os.close(master)
time.sleep(2.0)
print("frontend killed; reattaching", flush=True)

fe2, master2 = spawn_frontend([HEXE, "mux", "attach", "bigscroll"])
ok, buf = read_until(master2, LAST_MARKER.encode(), 90)
screen = buf + drain(master2, 6.0)

if fe2.poll() is not None:
    fail(f"frontend died after reattach rc={fe2.returncode}")

if not ok:
    fail("the last line written before detaching never reappeared after reattach "
         "— replayed scrollback is missing or unreadable")
print("tail marker present after reattach", flush=True)

# The discriminating check: a desynced parser renders the remainder of a cut
# escape sequence as ordinary text. Strip real escapes first, then look for
# fragments in what is left as VISIBLE output.
visible = re.sub(rb"\x1b\[[0-9;:?]*[ -/]*[@-~]", b"", screen)
visible = re.sub(rb"\x1b[\]P][^\x07\x1b]*(\x07|\x1b\\\\)?", b"", visible)
found = [f for f in FRAGMENTS if f.encode() in visible]
if found:
    ctx = b""
    for f in found:
        idx = visible.find(f.encode())
        ctx += visible[max(0, idx - 60):idx + 60] + b" || "
    fail(f"escape-sequence fragments rendered as literal text after reattach: {found} "
         f"— the replay began mid-sequence and desynced the VT. context={ctx[:400]!r}")

os.write(master2, b"echo ALIVE_AFTER\r")
ok, _ = read_until(master2, b"ALIVE_AFTER", 30)
if not ok:
    fail("pane unresponsive after reattach")

cleanup()
print("SMOKE PASS: high-output pane reattaches without garbling its scrollback")
