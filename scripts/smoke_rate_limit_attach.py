#!/usr/bin/env python3
"""Live check: pod reconnects must not lock the user out of SES.

Regression target (PLAN.md A-14). The connection rate limit was GLOBAL
(60/minute) and applied at accept time, before SES knew who was connecting.
Every pod redials from its own ~1s tick, so a daemon restart with a dozen panes
saturated the window within seconds — and SES then rejected the user's `attach`
and every CLI command with "server_overloaded". The pods always won that race,
because they retry automatically and a human does not.

The rate limit now applies only to interactive channels, after the handshake has
said which channel it is; POD channels are exempt and are still bounded by the
hard concurrent-connection ceiling.

This opens more POD_CTL connections than the whole per-minute budget and then
asks whether an ordinary CLI command still works.
"""
import atexit
import os, signal, socket, subprocess, sys, time

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
sockets = []

# Wire constants (src/core/wire.zig).
SES_HANDSHAKE_POD_CTL = 0x03
PROTOCOL_VERSION = 4

# Default limit is 60/minute; comfortably exceed it.
POD_CONNECTS = 90


def pgrep(pat):
    r = subprocess.run(["pgrep", "-f", "--", pat], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def cleanup():
    for s in sockets:
        try:
            s.close()
        except OSError:
            pass
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


def sock_dir():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime, "hexe", INST)


def cli_works(tag):
    """An ordinary CLI round trip. Returns (ok, combined_output).

    Checking the exit code is NOT enough, and neither is grepping for
    "overload": when SES refuses the connection the CLI reports
    `Error: failed to handshake with ses daemon: RuntimeEpochMismatch`
    -- and still exits 0. (That exit code is its own bug; noted separately.)
    An earlier version of this test looked only for "overload" + rc==0 and so
    passed against the unfixed daemon, proving nothing. Treat ANY error line as
    failure.
    """
    r = subprocess.run([HEXE, "ses", "list"], capture_output=True, text=True,
                       env=env, cwd=SCRATCH, timeout=20)
    out = (r.stdout + r.stderr).strip()
    low = out.lower()
    ok = r.returncode == 0 and "error" not in low and "overload" not in low
    return ok, out


print(f"instance={INST}")

subprocess.run([HEXE, "session", "daemon", "--instance", INST],
               env=env, cwd=SCRATCH, check=False, timeout=30)
time.sleep(1.5)
ses_sock = os.path.join(sock_dir(), "ses.sock")
if not os.path.exists(ses_sock):
    fail(f"ses socket not found at {ses_sock}")

ok, out = cli_works("baseline")
if not ok:
    fail(f"CLI did not work before any load: {out!r}")
print("baseline CLI ok", flush=True)

# Model a restart storm: many POD control connections in quick succession.
# Each sends the full POD_CTL preamble ([channel, version] + 16-byte uuid) so
# SES classifies it as a pod rather than reaping it as an incomplete handshake.
opened = 0
for i in range(POD_CONNECTS):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(ses_sock)
        s.send(bytes([SES_HANDSHAKE_POD_CTL, PROTOCOL_VERSION]) + bytes(16))
    except OSError:
        s.close()
        continue
    sockets.append(s)
    opened += 1
print(f"opened {opened} POD_CTL connections (budget is 60/min)", flush=True)
if opened < 61:
    fail(f"only {opened} pod connections landed — cannot exceed the 60/min budget, "
         f"so this test proves nothing")

time.sleep(1.0)

# The user's CLI must still work.
ok, out = cli_works("after")
print(f"CLI after pod storm: ok={ok}", flush=True)
if not ok:
    fail("pod reconnects exhausted the global connection rate limit and locked "
         f"the user out of SES: {out!r}")

cleanup()
print("SMOKE PASS: pod reconnect storms do not rate-limit the user out")
