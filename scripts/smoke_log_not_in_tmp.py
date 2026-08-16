#!/usr/bin/env python3
"""Live check: the debug log must not live in world-writable /tmp.

Regression target (PLAN.md A-6). `getLogPath` ALWAYS returned
`/tmp/hexe/<instance>/log`, ignoring XDG entirely, and the directory was made
with a bare `makePath` — no ownership check, no O_NOFOLLOW. A local attacker who
pre-creates `/tmp/hexe/<instance>` (or symlinks it at one of the victim's files)
gets hexe to write there. The log is not innocuous: it records cwds, command
lines and pane metadata.

The path now follows XDG_STATE_HOME (then ~/.local/state), and the directory
must pass an ownership check before use.
"""
import atexit
import os, signal, subprocess, sys, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
STATE_HOME = os.path.join(SCRATCH, f"state-{os.getpid()}")
os.makedirs(STATE_HOME, exist_ok=True)

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": STATE_HOME,
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
# A smoke run from inside a hexe pane inherits that pane's identity; the new
# frontend then hits the nested-mux confirmation and exits rc=0 with no output,
# which is indistinguishable from a product bug. Scrub the whole set.
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", "--", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def cleanup():
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


print(f"instance={INST}")

# Start the daemon WITHOUT --logfile so it uses the default log path.
subprocess.run([HEXE, "session", "daemon", "--instance", INST, "--log", "debug"],
               env=env, cwd=SCRATCH, check=False, timeout=30)
time.sleep(2.0)

# NOTE the pattern: a daemon started by hand has "session daemon ..." in its
# argv, while one autostarted by a frontend has "ses daemon ...". Matching on
# "daemon --instance" covers both; "ses daemon" silently matches neither of the
# manual ones and reads as "the daemon died".
if not pgrep(f"daemon --instance {INST}"):
    fail("daemon did not start")

tmp_log = f"/tmp/hexe/{INST}/log"
xdg_log = os.path.join(STATE_HOME, "hexe", INST, "log")

if os.path.exists(tmp_log):
    fail(f"debug log was written to world-writable /tmp: {tmp_log} "
         f"(it records cwds, command lines and pane metadata)")

if not os.path.exists(xdg_log):
    fail(f"debug log not found under XDG_STATE_HOME: expected {xdg_log}")

size = os.path.getsize(xdg_log)
if size == 0:
    fail(f"log at {xdg_log} is empty — daemon may not actually be logging there")
print(f"log is at XDG_STATE_HOME ({size} bytes), not /tmp", flush=True)

# The containing directory must not be group/world writable.
mode = os.stat(os.path.dirname(xdg_log)).st_mode & 0o777
if mode & 0o022:
    fail(f"log directory is group/world writable: mode={oct(mode)}")
print(f"log dir mode={oct(mode)}", flush=True)

cleanup()
print("SMOKE PASS: debug log lives in private state, not /tmp")
