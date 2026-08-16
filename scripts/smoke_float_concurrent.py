#!/usr/bin/env python3
"""KNOWN-FAILING repro: blocking `hexe terminal float` never returns.

NOT wired into `make smoke` — it fails, and it failed before the correlation
fix too (verified by stashing). Two separate defects live here:

1. FIXED — SES kept every waiting CLI caller in ONE slot keyed by an all-zero
   uuid, so a second concurrent float closed the first caller's fd and then
   received its output. Waiters are now keyed by a request id that the frontend
   echoes back on `float_result`.

2. NOT FIXED — a blocking float never completes AT ALL, even with a single
   caller. SES sends `pane_exited` for the float's pane, and the frontend never
   dispatches it, so `handleBlockingFloatCompletion` never runs. Ruled out:
   request-id stamping on notifications, queued-push stranding, and fd
   mismatch. Root cause still unknown.

Run it directly to reproduce:  python3 scripts/smoke_float_concurrent.py

Original description:
Live check: two blocking `hexe terminal float` calls do not steal from each other.

SES kept every waiting CLI caller in ONE slot keyed by an all-zero uuid — the
re-key on `float_created` that the code comment described was never implemented,
because `float_created` is never sent. So a second concurrent float closed the
first caller's fd (it exits "No response from ses" while its float is still on
screen) and then received the first float's output.

Each float here echoes a distinct marker. The test fails if either caller gets
the other's output, or if either is dropped.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"

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


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 160, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "floatconc"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
time.sleep(3.5)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

results = {}


def run_float(tag):
    """A blocking float that prints its own marker and exits."""
    rf = os.path.join(SCRATCH, f"floatres{os.getpid()}{tag}.txt")
    if os.path.exists(rf):
        os.unlink(rf)
    r = subprocess.run(
        [HEXE, "terminal", "float", "--command", f"sh -c 'printf MARKER_{tag} > {rf}'",
         "--result-file", rf],
        capture_output=True, text=True, env=env, timeout=45)
    body = ""
    if os.path.exists(rf):
        body = open(rf).read().strip()
    results[tag] = (r.returncode, (r.stdout + r.stderr).strip()[:120], body)


# Launch both at once — the failure mode needs them overlapping.
threads = [threading.Thread(target=run_float, args=(t,)) for t in ("A", "B")]
for t in threads:
    t.start()
    time.sleep(0.4)
for t in threads:
    t.join(timeout=50)

if len(results) != 2:
    fail(f"a caller never returned (one was dropped): got {sorted(results)}")

for tag in ("A", "B"):
    rc, out, body = results[tag]
    print(f"float {tag}: rc={rc} result={body!r} out={out!r}")

# Each caller must see its OWN marker, not the other's.
for tag, other in (("A", "B"), ("B", "A")):
    _, out, body = results[tag]
    if f"MARKER_{other}" in body or f"MARKER_{other}" in out:
        fail(f"caller {tag} received caller {other}'s result — waiters are sharing a slot")
    if "No response from ses" in out:
        fail(f"caller {tag} was dropped: its fd was closed by the other request")

if fe.poll() is not None:
    fail("frontend died handling concurrent float requests")

cleanup()
print("SMOKE PASS: concurrent blocking floats are matched to their own callers")
