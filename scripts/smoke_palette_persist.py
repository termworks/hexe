#!/usr/bin/env python3
"""Do palettes survive a clear, and a detach/reattach?

M4 leans on the pod's backlog for persistence: `hexe palette set` injects the
OSC into the pane's output, so a reattach replays it. That has two ways to lose:

  clear      the pod empties its backlog when it sees a clear-screen sequence,
             which would take every palette definition with it
  truncation the ring is finite; enough output pushes the definition out

This asserts the first directly and the second by construction. If a palette
does not survive, replay is the wrong persistence mechanism and the state has
to live somewhere that is not a byte ring.
"""
import atexit
import fcntl, os, pty, re, select, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"palpersist{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write("local hexe = require('hexe')\n"
             "return hexe.setup({ palette = { namespaces = true } })\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_CONFIG_HOME": CF, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

# The colour under test, as both SGR forms vaxis may pick.
RED = re.compile(rb"38[:;]2[:;]{0,2}255[:;]0[:;]0")
IDX33 = re.compile(rb"38[:;]5[:;]33")


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


def fail(msg, capture=None):
    if capture is not None:
        path = os.path.join(WD, "capture.bin")
        with open(path, "wb") as fh:
            fh.write(capture)
        msg = f"{msg}\n  full frame capture: {path}"
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


class Term:
    """A frontend under its own pty, with a background drain."""

    def __init__(self, argv, tag, rows=30, cols=100):
        self.cols = cols
        self.seen = bytearray()
        # Keep a debug log per frontend. When this fails it is almost always
        # "which side dropped it", and the answer is only in the logs.
        self.log = os.path.join(WD, f"{tag}.log")
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.proc = subprocess.Popen(argv + ["--log", "debug", "-L", self.log],
                                     stdin=slave, stdout=slave, stderr=slave,
                                     env=env, cwd=WD, start_new_session=True)
        os.close(slave)
        procs.append(self.proc)
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        while True:
            try:
                chunk = os.read(self.master, 65536)
                if not chunk:
                    return
            except OSError:
                return
            self.seen.extend(chunk)

    def write(self, data):
        os.write(self.master, data)

    def repaint(self):
        """Resize to force a full redraw; diff-rendering only emits changes."""
        del self.seen[:]
        self.cols = 99 if self.cols == 100 else 100
        fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                    struct.pack("HHHH", 30, self.cols, 0, 0))
        time.sleep(3.0)
        return bytes(self.seen)


def hexe_cli(*args):
    return subprocess.run([HEXE, *args], env=env, cwd=WD, capture_output=True, text=True)


# A script, never a typed line: the pane echoes what is typed, so sequences on
# the command line get asserted on without a cell ever being coloured.
PAINT = os.path.join(WD, "paint.sh")
with open(PAINT, "w") as fh:
    # The pane declares its own region: cells written between `use` and `end`
    # carry the namespace, which is what has to survive the round trip.
    fh.write("printf '\\033]1330;use;4\\033\\\\'\n"
             "printf 'NSROW \\033[38;5;33mIN\\033[0m\\n'\n"
             "printf '\\033]1330;end\\033\\\\'\n")

a = Term([HEXE, "mux", "new", "-n", "palp"], "fe-a")
time.sleep(4.0)
if a.proc.poll() is not None:
    fail(f"frontend exited rc={a.proc.returncode}")

a.write(f"sh {PAINT}\r".encode())
time.sleep(3.0)
if not IDX33.search(a.repaint()):
    fail("setup: the namespaced row never rendered its indexed colour")

res = hexe_cli("palette", "set", "--ns", "4", "33=#ff0000")
if res.returncode != 0:
    fail(f"palette set failed: {res.stderr!r}")
time.sleep(1.5)
if not RED.search(a.repaint()):
    fail("setup: the palette never applied in the first place")
print("setup: the namespace applied to the cells written under it")

# --- 1. a clear-screen empties the pod's backlog -------------------------
a.write(b"clear\r")
time.sleep(2.0)
a.write(f"sh {PAINT}\r".encode())
time.sleep(3.0)
after_clear = a.repaint()
if not RED.search(after_clear):
    fail("a clear-screen dropped the palette: the pod empties its backlog on "
         "clear, taking the definition with it", after_clear)
print("clear: palette survives a clear-screen")

# --- 2. detach and reattach ----------------------------------------------
os.kill(a.proc.pid, signal.SIGKILL)
a.proc.wait()
os.close(a.master)
time.sleep(2.5)

b = Term([HEXE, "mux", "attach", "palp"], "fe-b")
time.sleep(5.0)
if b.proc.poll() is not None:
    fail(f"reattach failed rc={b.proc.returncode}")

b.write(f"sh {PAINT}\r".encode())
time.sleep(3.0)
after_reattach = b.repaint()
if not IDX33.search(after_reattach) and not RED.search(after_reattach):
    fail("reattach: the namespaced row is not on screen at all", after_reattach)
if not RED.search(after_reattach):
    fail("the palette did not survive detach/reattach: replay is not carrying "
         "the definition", after_reattach)
print("reattach: palette survives detach and reattach")

cleanup()
print("PASS: palettes survive clear and detach/reattach")
