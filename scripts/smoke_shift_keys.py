#!/usr/bin/env python3
"""Check shifted keys through a live split and float, before and after Kitty negotiation."""

import fcntl
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty


CASES = (
    ("legacy", 0, b"\x1b[Z\tA", b"\x1b[Z\tA"),
    ("kitty", 5, b"\x1b[Z\x1b[9;2u\x1b[13;2u\t\r\x1b[97:65;2;65u\x1b[50:64;2;64u",
     b"\x1b[9;2u\x1b[9;2u\x1b[13;2u\t\rA@"),
    ("restored", 0, b"\x1b[Z\tA", b"\x1b[Z\tA"),
)


def read_input(timeout, terminator=None):
    data = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([0], [], [], min(0.2, max(0, deadline - time.monotonic())))
        if not ready:
            continue
        chunk = os.read(0, 4096)
        if not chunk:
            break
        data += chunk
        if terminator and data.endswith(terminator):
            break
        if not terminator:
            deadline = time.monotonic() + 0.5
    return data


def collect(directory):
    directory = Path(directory)
    directory.mkdir()
    saved = termios.tcgetattr(0)
    tty.setraw(0)
    pushed = False
    try:
        for name, flags, _, _ in CASES:
            if flags:
                os.write(1, f"\x1b[>{flags}u".encode())
                pushed = True
            os.write(1, b"\x1b[?u")
            reply = read_input(10, b"u")
            if reply != f"\x1b[?{flags}u".encode():
                raise RuntimeError(f"{name}: unexpected keyboard query reply {reply!r}")
            (directory / f"{name}.ready").touch()
            received = read_input(10)
            result = directory / f"{name}.tmp"
            result.write_bytes(received)
            result.replace(directory / f"{name}.bytes")
            if pushed:
                os.write(1, b"\x1b[<u")
                pushed = False
    finally:
        if pushed:
            os.write(1, b"\x1b[<u")
        termios.tcsetattr(0, termios.TCSANOW, saved)
    (directory / "done").touch()


def run():
    repo = Path(os.environ.get("HEXE_REPO", Path(__file__).resolve().parent.parent))
    hexe = repo / "zig-out/bin/hexe"
    scratch = Path(os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke"))
    scratch.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="shiftkeys-", dir=scratch))
    instance = f"shiftkeys{os.getpid()}"
    config = work / "config/hexe"
    config.mkdir(parents=True)
    (work / "runtime").mkdir(mode=0o700)
    (config / "init.lua").write_text(
        "local hexe = require('hexe')\n"
        "return hexe.setup({ keys = {\n"
        "  hexe.key({ hexe.key.alt, hexe.key['v'] }, hexe.action.split.vertical()),\n"
        "} })\n"
    )
    env = {key: value for key, value in os.environ.items() if not key.startswith("HEXE_")}
    env.update({
        "HEXE_INSTANCE": instance,
        "HEXE_TRUST_ALL_PROJECTS": "1",
        "HEXE_SKIP_LOCAL_CONFIG": "1",
        "XDG_CONFIG_HOME": str(work / "config"),
        "XDG_STATE_HOME": str(work / "state"),
        "XDG_RUNTIME_DIR": str(work / "runtime"),
        "TERM": "xterm-256color",
        "SHELL": "/bin/sh",
    })
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    processes = []

    def drain():
        with (work / "terminal.raw").open("wb") as log:
            while True:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    return
                if not data:
                    return
                log.write(data)
                log.flush()

    def wait_file(path):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if path.exists():
                return
            if frontend.poll() is not None:
                raise RuntimeError(f"frontend exited: {frontend.returncode}")
            time.sleep(0.05)
        raise RuntimeError(f"timed out waiting for {path}")

    def check(surface):
        directory = work / surface
        for name, flags, payload, expected in CASES:
            wait_file(directory / f"{name}.ready")
            os.write(master, payload)
            result = directory / f"{name}.bytes"
            wait_file(result)
            received = result.read_bytes()
            if received != expected:
                raise RuntimeError(f"{surface}/{name}: expected {expected!r}, got {received!r}")
            print(f"{surface}/{name}: kitty={flags}, received {received!r}")
        wait_file(directory / "done")

    def command(surface):
        return shlex.join([sys.executable, str(Path(__file__).resolve()), "--collect", str(work / surface)])

    try:
        frontend = subprocess.Popen(
            [str(hexe), "mux", "new", "-n", "shiftkeys", "--log", "debug",
             "--logfile", str(work / "frontend.log")],
            stdin=slave, stdout=slave, stderr=slave, cwd=work, env=env, start_new_session=True,
        )
        processes.append(frontend)
        os.close(slave)
        slave = None
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        time.sleep(3)
        ready = work / "shell.ready"
        os.write(master, f"touch {shlex.quote(str(ready))}\r".encode())
        wait_file(ready)
        os.write(master, b"\x1bv")
        time.sleep(1)
        os.write(master, (command("split") + "\r").encode())
        check("split")
        floating = subprocess.Popen(
            [str(hexe), "mux", "float", "--title=shiftkeys", "--command", command("float")],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            cwd=work, env=env,
        )
        processes.append(floating)
        check("float")
        print("SMOKE PASS: shifted keys reach split and float panes; negotiation and reset preserved")
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        matches = subprocess.run(
            ["pgrep", "-f", f"instance {instance}( |$)"], capture_output=True, text=True,
        )
        for pid in matches.stdout.split():
            try:
                os.kill(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(master)
        if slave is not None:
            os.close(slave)
        print(f"Evidence: {work}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))
    if len(sys.argv) == 3 and sys.argv[1] == "--collect":
        collect(sys.argv[2])
    else:
        run()
