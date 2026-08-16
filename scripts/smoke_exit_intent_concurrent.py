#!/usr/bin/env python3
"""Live check: a second `exit-intent` does not release the first caller.

SES parked every waiting CLI in ONE slot (`pending_exit_intent_cli_fd`) and
closed the previous occupant when a new request arrived. `com.zig`'s
`runExitIntent` exits 0 on ANY read failure, so that EOF reads as ALLOW: the
first pane exited while its confirmation popup was still on screen, unanswered.
`hexe shp exit-intent` runs from the shell's exit hook, so two shells exiting
together is ordinary, not exotic.

Waiters are now keyed by a request id that the frontend echoes back. The id is
required rather than cosmetic: replies are NOT FIFO — a non-last-split pane is
answered inline while an older confirmation is still waiting on the user.

The assertion is about WHEN caller A returns, not its exit code: both the bug
and the fix end with rc=0, so an exit-code test would pass against the bug.
"""
import atexit
import fcntl, glob, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
CFG = os.path.join(SCRATCH, f"eicfg{os.getpid()}")
os.makedirs(os.path.join(CFG, "hexe"), exist_ok=True)
open(os.path.join(CFG, "hexe", "init.lua"), "w").write("""
local hexe = require("hexe")
return hexe.setup({ mux = { confirm = { exit = true } } })
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "XDG_CONFIG_HOME": CFG, "TERM": "xterm-256color", "SHELL": "/bin/sh"})
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
LOG = os.path.join(SCRATCH, f"exitint{os.getpid()}.log")
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "exitint", "--logfile", LOG], stdin=slave,
                      stdout=slave, stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
threading.Thread(target=drain_pty, args=(master,), daemon=True).start()
time.sleep(3.5)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

# The pane uuid to ask about. Take it from the pod socket name: a session id
# scraped out of the state file looks identical and resolves to no mux, which
# makes SES answer "allow" itself and the test silently vacuous.
runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
socks = glob.glob(os.path.join(runtime, "hexe", INST, "pod-*.sock"))
if not socks:
    fail(f"no pod socket found under {runtime}/hexe/{INST}")
uuid = os.path.basename(socks[0])[len("pod-"):-len(".sock")]
if len(uuid) != 32:
    fail(f"unexpected pod socket name: {socks[0]}")


def exit_intent():
    # `hexe shp exit-intent` takes the pane from the environment — it is the
    # shell exit hook, running inside the pane it asks about.
    e = dict(env)
    e["HEXE_PANE_UUID"] = uuid
    return subprocess.Popen([HEXE, "shp", "exit-intent"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, env=e, cwd=SCRATCH)


# A: last split + confirm.exit -> the frontend raises a popup and A blocks.
a = exit_intent(); procs.append(a)
time.sleep(2.0)
if a.poll() is not None:
    log = open(LOG, errors="replace").read() if os.path.exists(LOG) else ""
    tail = "\n".join(l for l in log.splitlines() if "exit_intent" in l or "confirm" in l)[-600:]
    fail(f"caller A returned rc={a.returncode} without the popup being answered "
         f"— the confirmation was bypassed\n--- frontend ---\n{tail}")
print("A: blocked on the confirmation popup, as it should be")

# B arrives while A is still pending. The frontend answers it inline (deny).
b = exit_intent(); procs.append(b)
try:
    b.wait(timeout=15)
except subprocess.TimeoutExpired:
    fail("caller B never got an answer")
print(f"B: answered inline while A was pending (rc={b.returncode})")

# The whole point: B must not have released A.
time.sleep(1.0)
if a.poll() is not None:
    fail(f"caller A was RELEASED by caller B's request (rc={a.returncode}) — "
         "waiters are sharing one slot, and the pane exits unconfirmed")
print("A: still waiting — B did not steal its slot")

# Answer the popup: A must now come back, and with the answer we gave.
os.write(master, b"y")
try:
    a.wait(timeout=15)
except subprocess.TimeoutExpired:
    fail("caller A never received the popup answer")
if a.returncode != 0:
    fail(f"caller A got the wrong verdict after confirming: rc={a.returncode}")
print("A: released by the popup answer with the confirmed verdict")

if fe.poll() is not None:
    fail("frontend died handling concurrent exit intents")

cleanup()
print("SMOKE PASS: concurrent exit intents are matched to their own callers")
