#!/usr/bin/env python3
"""Frame-time baseline for the render path (PLAN.md M0 exit criterion).

Fills a pane with indexed-colour cells — the case palette namespaces touch —
and measures how long hexe takes to absorb and repaint a fixed amount of such
output. Reports bytes/second and the wall time for a fixed payload, so an M1
run can be compared against the same number.

This measures the whole absorb+render pipeline from outside, which is the thing
a user feels; it is not a microbenchmark of convertStyle.
"""
import fcntl, os, pty, statistics, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"bench{os.getpid()}")
os.makedirs(WD, exist_ok=True)
INST = f"smk{os.getpid()}"
ROWS, COLS = 50, 200
PAYLOAD_ROWS = 4000
RUNS = int(os.environ.get("HEXE_BENCH_RUNS", "1"))
BLEND = os.environ.get("HEXE_BENCH_BLEND") == "1"

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
    if BLEND:
        deadline = time.time() + 8
        while b"\x1b]11;?\x1b\\" not in bytes(seen) and time.time() < deadline:
            if fe.poll() is not None:
                print(f"FAIL: frontend exited rc={fe.returncode}")
                return 1
            time.sleep(0.02)
        if b"\x1b]11;?\x1b\\" not in bytes(seen):
            print("FAIL: frontend did not start host colour discovery")
            cleanup(fe)
            return 1
    else:
        time.sleep(4.0)
        if fe.poll() is not None:
            print(f"FAIL: frontend exited rc={fe.returncode}")
            return 1

    if BLEND:
        reports = bytearray(b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:0000/0000/0000\x1b\\")
        for index in range(256):
            value = f"{index:02x}{index:02x}".encode()
            reports.extend(b"\x1b]4;" + str(index).encode() + b";rgb:" + value + b"/" + value + b"/" + value + b"\x1b\\")
        os.write(master, reports)
        time.sleep(1.0)

    # A file of indexed-colour rows, then cat it and wait for the end marker.
    src = os.path.join(WD, "payload.txt")
    with open(src, "w") as fh:
        for i in range(PAYLOAD_ROWS):
            cells = "".join(f"\x1b[38;5;{(i + c) % 256}m\x1b[48;5;{(c * 7) % 256}mX"
                            for c in range(COLS // 2))
            fh.write(cells + "\x1b[0m\n")
    size = os.path.getsize(src)

    # The marker lives in a script, never on the typed line: the pane echoes
    # what is typed, so a marker in the command text can be seen rendered
    # before a single payload byte is, which times the echo instead of the
    # render. That made runs differ by 200x depending on scheduling.
    elapsed_runs = []
    for run in range(RUNS):
        marker = f"BENCH_DONE_{run:03d}".encode()
        runner = os.path.join(WD, f"run-{run:03d}.sh")
        with open(runner, "w") as fh:
            if BLEND:
                fh.write("printf '\\033]1331;use;fg=30\\033\\\\'\n")
            fh.write(f"cat {src}\n")
            if BLEND:
                fh.write("printf '\\033]1331;end\\033\\\\'\n")
            fh.write(f"printf '%s\\n' {marker.decode()}\n")
        del seen[:]
        started = time.perf_counter()
        os.write(master, f"sh {runner}\r".encode())
        deadline = time.time() + 120
        while time.time() < deadline:
            if marker in bytes(seen):
                break
            time.sleep(0.01)
        elapsed = time.perf_counter() - started
        if marker not in bytes(seen):
            print(f"FAIL: payload run {run + 1} never finished rendering")
            cleanup(fe)
            return 1
        elapsed_runs.append(elapsed)

    elapsed = statistics.median(elapsed_runs)

    print(f"rows        : {PAYLOAD_ROWS}")
    print(f"mode        : {'mixed-30' if BLEND else 'opaque'}")
    print(f"runs        : {RUNS}")
    print(f"payload     : {size/1024/1024:.2f} MiB of indexed-colour SGR")
    print(f"median      : {elapsed:.3f} s")
    print(f"range       : {min(elapsed_runs):.3f}..{max(elapsed_runs):.3f} s")
    print("samples     : " + " ".join(f"{sample:.6f}" for sample in elapsed_runs))
    print(f"throughput  : {size/elapsed/1024/1024:.2f} MiB/s")
    print(f"per row     : {elapsed/PAYLOAD_ROWS*1000:.3f} ms")
    cleanup(fe)
    return 0


if __name__ == "__main__":
    sys.exit(main())
