#!/usr/bin/env python3
"""Live check: a large paste into a slow reader arrives losslessly.

Reported bug: pasting into a float froze it — the pod's fixed 256K PTY input
buffer silently dropped overflow bytes, tearing the bracketed-paste framing so
the app stayed in paste mode swallowing all input. The buffer now grows.
"""
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time

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
PASTE_BYTES = 400_000
SINK = os.path.join(SCRATCH, "paste-sink.bin")

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

def read_until(fd, marker, timeout_s, log):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try: chunk = os.read(fd, 65536)
            except OSError: return False
            if not chunk: return False
            buf += chunk
            log.write(chunk)
            if marker in buf: return True
    return False

log = open(os.path.join(SCRATCH, "smoke-paste.raw"), "wb")
if os.path.exists(SINK):
    os.unlink(SINK)

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "pastetest"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
time.sleep(2.5)
if fe.poll() is not None: fail("frontend didn't start")

# The reader sleeps first, so the paste backs up in the pod's input buffer
# (kernel pty buffer is only ~64K) before head drains exactly PASTE_BYTES.
cmd = f"sleep 3; head -c {PASTE_BYTES} > {SINK}\r".encode()
os.write(master, cmd)
time.sleep(0.8)

# "Paste" a big blob (larger than the old 256K fixed buffer). Newline every
# 100 bytes: the tty line discipline caps unterminated lines at 4K in
# canonical mode, which would drop bytes before they ever reach hexe.
line = b"a" * 99 + b"\n"
blob = line * (PASTE_BYTES // len(line))
assert len(blob) == PASTE_BYTES
off = 0
stall_deadline = time.time() + 60
while off < len(blob):
    if time.time() > stall_deadline:
        fail("pty write stalled for 60s (input path wedged)")
    r, w, _ = select.select([master], [master], [], 1)
    if master in r:
        # Drain echo so the frontend's output side cannot back up.
        try: log.write(os.read(master, 65536))
        except OSError: pass
    if master in w:
        off += os.write(master, blob[off:off + 65536])
print(f"phase1: wrote {off} paste bytes")

# After the sleep, head consumes exactly PASTE_BYTES and the prompt returns.
# Drain echo while the pipeline catches up (600K of echo renders slowly).
deadline = time.time() + 90
while time.time() < deadline:
    if os.path.exists(SINK) and os.path.getsize(SINK) >= PASTE_BYTES:
        break
    r, _, _ = select.select([master], [], [], 0.3)
    if master in r:
        try: log.write(os.read(master, 65536))
        except OSError: pass
os.write(master, b"echo DONE_$((40+5))\r")
if not read_until(master, b"DONE_45", 60, log):
    fail("pane unresponsive after large paste (input path wedged)")
print("phase2: pane responsive after paste")

size = os.path.getsize(SINK) if os.path.exists(SINK) else -1
if size != PASTE_BYTES:
    fail(f"paste truncated: sink has {size} of {PASTE_BYTES} bytes (input dropped)")
print(f"phase3: all {size} paste bytes arrived losslessly")

cleanup()
log.close()
print("SMOKE PASS: large paste is lossless and the pane stays responsive")
