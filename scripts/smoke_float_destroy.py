#!/usr/bin/env python3
"""Live check: a float declared `attrs = { destroy = true }` dies when hidden.

`destroy` is documented as "Kill the float process when hiding it". It parsed,
it OR-merged with mux.floats.defaults, and it was reported to Lua as
`pane.destroyable` — but NOTHING ever read it. Hiding such a float left its
process running forever, so a `destroy` float leaked one process per toggle.

Two floats, toggled identically, differing only in that attribute:

  alt+g  destroy = true   -> hiding must KILL the command
  alt+h  (no attrs)       -> hiding must LEAVE it running

The control is not decoration. Without it, "the process is gone" is equally
explained by the toggle tearing every float down, and the test would pass
against an implementation that ignores the attribute entirely.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"fdest{os.getpid()}")
CF = os.path.join(SCRATCH, f"fdestcfg{os.getpid()}")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(WD, exist_ok=True)

DIE = f"HEXE_DESTROY_MARK_{os.getpid()}"
LIVE = f"HEXE_KEEP_MARK_{os.getpid()}"

open(os.path.join(CF, "hexe", "init.lua"), "w").write("""
local hexe = require("hexe")
return hexe.setup({
  ses = {
    layouts = {
      hexe.layout("fdestlay", {
        root = "%s",
        tabs = { hexe.tab("main", { root = hexe.pane() }) },
        floats = {
          hexe.float("dies", {
            key = "g",
            command = "sh -c 'echo %s; sleep 300'",
            size = { width = 50, height = 40 },
            attrs = { destroy = true },
          }),
          hexe.float("stays", {
            key = "h",
            command = "sh -c 'echo %s; sleep 300'",
            size = { width = 50, height = 40 },
          }),
        },
      }),
    },
  },
  keys = {
    hexe.key({ hexe.key.alt, hexe.key['g'] }, hexe.action.float.toggle('g')),
    hexe.key({ hexe.key.alt, hexe.key['h'] }, hexe.action.float.toggle('h')),
  },
})
""" % (WD, DIE, LIVE))

env = dict(os.environ, HEXE_INSTANCE=INST, XDG_STATE_HOME=os.path.join(SCRATCH, "smoke-state"),
           XDG_CONFIG_HOME=CF, TERM="xterm-256color", SHELL="/bin/sh")
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
    for mark in (DIE, LIVE):
        subprocess.run(["pkill", "-9", "-f", mark], capture_output=True)
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


def alive(mark):
    """Is the float's command still running? Match the sleep, not the echo."""
    r = subprocess.run(["pgrep", "-f", f"echo {mark}"], capture_output=True, text=True)
    return r.returncode == 0


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
LOG = os.path.join(WD, "fe.log")
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "fdest", "--logfile", LOG], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave); procs.append(fe)
threading.Thread(target=drain_pty, args=(master,), daemon=True).start()
time.sleep(4.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

ALT_G = b"\x1bg"
ALT_H = b"\x1bh"


def toggle(keys, mark, want_alive, phase):
    os.write(master, keys)
    deadline = time.time() + 12
    while time.time() < deadline:
        if alive(mark) == want_alive:
            return
        time.sleep(0.3)
    procs_seen = subprocess.run(["pgrep", "-af", f"echo {mark}"], capture_output=True, text=True).stdout
    fail(f"{phase}: float {mark} is {'not ' if want_alive else ''}running "
         f"(expected {'running' if want_alive else 'gone'})\nmatching processes:\n{procs_seen}")


# Open both floats.
toggle(ALT_G, DIE, True, "open destroy-float")
toggle(ALT_H, LIVE, True, "open control-float")
print("both floats are open and their commands are running")

# Hide the control float: its process must survive.
os.write(master, ALT_H)
time.sleep(4.0)
if not alive(LIVE):
    fail("control float (no destroy attribute) was killed on hide — "
         "hiding tears down every float, so this test cannot prove anything")
print("control: hidden float without the attribute kept running")

# Hide the destroy float: its process must be gone.
toggle(ALT_G, DIE, False, "hide destroy-float")
print("destroy: hiding the float killed its command")

if not alive(LIVE):
    fail("the control float died while the destroy float was hidden")
if fe.poll() is not None:
    fail("frontend died toggling floats")

# Closing the session must not orphan the surviving float's process.
#
# SES ignores SIGHUP so it can outlive its launching terminal, and SIG_IGN
# survives fork AND exec — so every pane's command inherited it. The pod exited
# on SIGTERM, the kernel hung up the pty, and a command that never reads the tty
# (a sleep, a watcher, a long build) shrugged the hangup off and ran forever.
# An interactive shell hides this: it exits on EOF without needing the signal,
# which is why "no pod leaked" checks stayed green while trees leaked.
subprocess.run([HEXE, "terminal", "close", "fdest"], capture_output=True, text=True, env=env)
deadline = time.time() + 15
while time.time() < deadline and alive(LIVE):
    time.sleep(0.3)
if alive(LIVE):
    fail("closing the session orphaned the float's command — it ignored the pty hangup")
print("teardown: closing the session reaped the float's command")

cleanup()
print("SMOKE PASS: the destroy float attribute kills the process on hide")
