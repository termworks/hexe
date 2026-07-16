#!/usr/bin/env python3
"""Live check: hexe terminal kill <id> for a pane uuid prefix and a session."""
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time, json

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
env.pop("HEXE_SESSION", None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []

def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True)
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

def fail(msg):
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)

def hexe(*args):
    r = subprocess.run([HEXE] + list(args), capture_output=True, text=True, env=env, timeout=10)
    return (r.stdout + r.stderr).strip()

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "killme"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
time.sleep(2.5)
if fe.poll() is not None: fail("frontend didn't start")

# Get the pane uuid from persisted state.
time.sleep(1.5)
state_file = os.path.join(env["XDG_STATE_HOME"], "hexe", INST, "ses_state.json")
data = json.load(open(state_file))
panes = [p["uuid"] for p in data["panes"]]
if not panes: fail("no pane in state")
pane_uuid = panes[0]
print(f"phase1: session up, pane={pane_uuid[:8]}")

# Kill the pane by an 8-char prefix.
out = hexe("terminal", "kill", pane_uuid[:8])
print(f"kill pane -> {out!r}")
if "Killed pane" not in out: fail("pane kill failed")
time.sleep(1.5)
# Frontend must survive (respawns a fallback tab).
if fe.poll() is not None: fail("frontend died when its pane was killed")
print("phase2: pane killed by prefix; frontend survived")

# Kill the whole ATTACHED session by name via the close alias.
out = hexe("terminal", "close", "killme")
print(f"close session -> {out!r}")
if "Killed attached session" not in out: fail("attached-session kill failed")
deadline = time.time() + 8
while time.time() < deadline and fe.poll() is None:
    time.sleep(0.3)
if fe.poll() is None: fail("frontend still running after session kill")
print(f"phase3: attached session killed; frontend exited rc={fe.returncode}")
time.sleep(1.0)
leftover = pgrep(f"pod daemon --instance {INST}")
if leftover: fail(f"pods leaked after session kill: {leftover}")
print("phase3b: no pod leaked")

# Nonexistent + ambiguity handling.
out = hexe("terminal", "kill", "zzzznope")
print(f"kill bogus -> {out!r}")
if "Error" not in out: fail("bogus target should error")

cleanup()
print("SMOKE PASS: terminal kill/close works for panes and attached sessions")
