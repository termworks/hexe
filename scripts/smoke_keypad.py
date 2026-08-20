#!/usr/bin/env python3
"""Live check: numpad keys reach the pane, in every form a terminal sends them.

A keypad key has three wire forms and only one of them worked:

  plain digit (numlock on)      -> arrived fine
  Kitty `CSI 57400 u`           -> forwarded VERBATIM to a shell that never
                                   negotiated the protocol, so `^[[57400u`
                                   landed in the pane instead of `1`
  application-keypad `ESC O q`  -> not decoded by the input parser at all, and
                                   the parser-first policy drops undecoded
                                   bytes, so the keypress vanished entirely

The keypad has no legacy encoding, which is why Kitty reports it as a
functional code while Home/End/F-keys keep their old sequences — so this only
breaks on machines that HAVE a keypad, which is why it went unnoticed.

Asserted through `cat > file` rather than the screen: the pane's tty is
canonical, so the bytes land verbatim and the check is about delivery, not
rendering.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"keypad{os.getpid()}")
os.makedirs(WD, exist_ok=True)
SINK = os.path.join(WD, "typed.txt")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
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
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


def drain_pty(fd):
    while True:
        try:
            if not os.read(fd, 65536):
                return
        except OSError:
            return


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "keypad"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave); procs.append(fe)
threading.Thread(target=drain_pty, args=(master,), daemon=True).start()
time.sleep(4.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")


def collect(sequences, timeout_s=20):
    """Type sequences into `cat > SINK`, terminate the line, return what landed."""
    if os.path.exists(SINK):
        os.unlink(SINK)
    os.write(master, f"cat > {SINK}\r".encode())
    time.sleep(2.0)
    for seq in sequences:
        os.write(master, seq)
        time.sleep(0.35)
    os.write(master, b"\r")          # flush the canonical line
    time.sleep(0.8)
    os.write(master, b"\x04")        # EOF ends cat
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if os.path.exists(SINK):
            body = open(SINK, "rb").read()
            if body:
                return body
        time.sleep(0.3)
    return b""


# Every wire form of the same keys. Expected: 1 1 + + . 1
KEYPAD = [
    b"\x1b[57400u",   # Kitty kp_1
    b"\x1bOq",        # application-keypad 1
    b"\x1b[57413u",   # Kitty kp_add
    b"\x1bOk",        # application-keypad +
    b"\x1b[57409u",   # Kitty kp_decimal
    b"1",             # plain digit (numlock on)
]
got = collect(KEYPAD)
if not got:
    fail("nothing reached the pane at all — `cat >` never produced a file")
line = got.split(b"\n")[0]
if line != b"11++.1":
    fail(f"keypad keys did not arrive as their conventional characters: {line!r} "
         f"(expected b'11++.1'); raw={got[:60]!r}")
print(f"keypad: all six forms delivered -> {line.decode()!r}")

# The other direction: input that is NOT keypad must pass through untouched.
# A plain arrow must stay an arrow, and a MODIFIED keypad press must keep its
# modifier rather than being flattened to a bare digit.
CONTROL = [b"\x1b[A", b"\x1b[57400;5u"]
got2 = collect(CONTROL)
if not got2:
    fail("control phase produced no output")
if b"\x1b[A" not in got2:
    fail(f"a plain arrow key was rewritten or dropped: {got2[:60]!r}")
if b"\x1b[57400;5u" not in got2:
    fail(f"ctrl+keypad lost its modifier (flattened to a bare key): {got2[:60]!r}")
print("control: arrows and modified keypad presses pass through unchanged")

if fe.poll() is not None:
    fail("frontend died handling keypad input")

cleanup()
print("SMOKE PASS: keypad input reaches the pane in every form")
