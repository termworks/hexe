#!/usr/bin/env python3
"""Frame-time baseline for the render path (PLAN.md M0 exit criterion).

Fills a pane with indexed-colour cells — the case palette namespaces touch —
and measures how long hexe takes to absorb and repaint a fixed amount of such
output. Reports bytes/second and the wall time for a fixed payload, so an M1
run can be compared against the same number.

This measures the whole absorb+render pipeline from outside, which is the thing
a user feels; it is not a microbenchmark of convertStyle.
"""
import fcntl, os, pty, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"bench{os.getpid()}")
os.makedirs(WD, exist_ok=True)
INST = f"smk{os.getpid()}"
ROWS, COLS = 50, 200
PAYLOAD_ROWS = 4000

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)


def cleanup(fe):
    if fe.poll() is None:
        fe.terminate()
        try: fe.wait(timeout=3)
        except subprocess.TimeoutExpired: fe.kill()
    subprocess.run(["pkill", "-9", "-f", f"instance {INST}"], capture_output=True)


def main():
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    fe = subprocess.Popen([HEXE, "mux", "new", "-n", "bench"], stdin=slave, stdout=slave,
                          stderr=slave, env=env, cwd=WD, start_new_session=True)
    os.close(slave)

    seen = bytearray()
    stop = False

    def drain():
        while not stop:
            try:
                chunk = os.read(master, 65536)
                if not chunk:
                    return
            except OSError:
                return
            seen.extend(chunk)

    threading.Thread(target=drain, daemon=True).start()
    time.sleep(4.0)
    if fe.poll() is not None:
        print(f"FAIL: frontend exited rc={fe.returncode}")
        return 1

    # A file of indexed-colour rows, then cat it and wait for the end marker.
    src = os.path.join(WD, "payload.txt")
    with open(src, "w") as fh:
        for i in range(PAYLOAD_ROWS):
            cells = "".join(f"\x1b[38;5;{(i + c) % 256}m\x1b[48;5;{(c * 7) % 256}mX"
                            for c in range(COLS // 2))
            fh.write(cells + "\x1b[0m\n")
    size = os.path.getsize(src)

    marker = b"BENCH_DONE_MARKER"
    del seen[:]
    t0 = time.time()
    os.write(master, f"cat {src}; echo {marker.decode()}\r".encode())
    deadline = time.time() + 120
    while time.time() < deadline:
        if marker in bytes(seen):
            break
        time.sleep(0.02)
    elapsed = time.time() - t0

    if marker not in bytes(seen):
        print("FAIL: payload never finished rendering")
        cleanup(fe)
        return 1

    print(f"rows        : {PAYLOAD_ROWS}")
    print(f"payload     : {size/1024/1024:.2f} MiB of indexed-colour SGR")
    print(f"elapsed     : {elapsed:.2f} s")
    print(f"throughput  : {size/elapsed/1024/1024:.2f} MiB/s")
    print(f"per row     : {elapsed/PAYLOAD_ROWS*1000:.3f} ms")
    cleanup(fe)
    return 0


if __name__ == "__main__":
    sys.exit(main())
