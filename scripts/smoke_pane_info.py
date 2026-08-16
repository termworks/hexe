#!/usr/bin/env python3
"""Live check: `hexe com <pane> info` reports real pane state, not struct defaults.

SES stores pane geometry, cursor, screen mode, cwd and last command; the
frontend is the only thing that knows them. Each of those had a reader in the
pane_info handler and no writer, so the command answered 0x0 / cursor 0,0 /
primary screen / empty cwd for every pane regardless of what it was doing.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time, json


def drain_pty(fd):
    """An undrained master fills at ~64 KiB and blocks the frontend in writev(2)."""
    while True:
        try:
            if not os.read(fd, 65536):
                return
        except OSError:
            return

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
# A smoke run from inside a hexe pane inherits that pane's identity and the new
# frontend exits rc=0 on the nested-mux guard, which mimics a product bug.
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

ROWS, COLS = 40, 120


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", "--", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    for pid in pgrep(f"daemon --instance {INST}"):
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


def hexe(*args):
    r = subprocess.run([HEXE] + list(args), capture_output=True, text=True, env=env, timeout=10)
    return (r.stdout + r.stderr).strip()


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "infobox"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
threading.Thread(target=drain_pty, args=(master,), daemon=True).start()
time.sleep(2.5)
if fe.poll() is not None: fail("frontend didn't start")

time.sleep(1.5)
state_file = os.path.join(env["XDG_STATE_HOME"], "hexe", INST, "ses_state.json")
data = json.load(open(state_file))
panes = [p["uuid"] for p in data["panes"]]
if not panes: fail("no pane in state")
pane_uuid = panes[0]
print(f"phase1: session up, pane={pane_uuid[:8]}")

# Run a command in the pane so there is a real cwd and a real last command.
os.write(master, b"cd /tmp && echo hexe-smoke-marker\n")
time.sleep(2.5)

info = hexe("terminal", "info", "--uuid", pane_uuid)
print("--- pane info ---")
print(info)
print("-----------------")

fields = {}
for line in info.splitlines():
    if ":" in line:
        k, _, v = line.partition(":")
        fields[k.strip().lower()] = v.strip()


def field(*names):
    for n in names:
        for k, v in fields.items():
            if n in k:
                return v
    return None


# Size must match the pty we allocated, not the 0x0 the struct defaults to.
size = field("window", "size", "dimensions")
if not size:
    fail(f"pane info reports no size field; got keys {sorted(fields)}")
if "0x0" in size.replace(" ", ""):
    fail(f"size is the never-written default: {size!r}")
if str(COLS) not in size:
    fail(f"size {size!r} does not carry the real pty width {COLS}")
print(f"phase2: size reported as {size!r} (real pty is {COLS}x{ROWS})")

# CWD must be present. Before the fix SES never received one.
cwd = field("cwd", "directory")
if not cwd or cwd in ("(none)", "-", ""):
    fail(f"cwd missing from pane info: {cwd!r}")
print(f"phase3: cwd reported as {cwd!r}")

# Cursor position: the pane has echoed a command, so the cursor cannot still
# be at the origin the struct defaults to.
cur = field("cursor")
if cur is None:
    fail("pane info reports no cursor")
if cur.replace(" ", "") in ("0,0",):
    fail(f"cursor is the never-written default: {cur!r}")
print(f"phase4: cursor reported as {cur!r}")

cleanup()
print("SMOKE PASS: pane info reports live geometry and cwd")
