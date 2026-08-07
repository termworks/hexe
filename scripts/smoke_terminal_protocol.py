#!/usr/bin/env python3
"""Exercise pane-local query replies and OSC 133 output copying through a live frontend."""

import atexit
import base64
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
INSTANCE = f"proto{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, INSTANCE)
CONFIG_HOME = os.path.join(WORKDIR, "config")
STATE_HOME = os.path.join(WORKDIR, "state")
LOG_PATH = os.path.join(WORKDIR, "frontend.log")
os.makedirs(os.path.join(CONFIG_HOME, "hexe"), exist_ok=True)
os.makedirs(STATE_HOME, exist_ok=True)

with open(os.path.join(CONFIG_HOME, "hexe", "init.lua"), "w", encoding="utf-8") as config:
    config.write(
        "local hexe = require('hexe')\n"
        "return hexe.setup({ keys = {\n"
        "  hexe.key({ hexe.key.alt, hexe.key['y'] }, hexe.action.prompt.copy_output()),\n"
        "} })\n"
    )

env = os.environ.copy()
env.update(
    {
        "HEXE_INSTANCE": INSTANCE,
        "HEXE_TRUST_ALL_PROJECTS": "1",
        "XDG_CONFIG_HOME": CONFIG_HOME,
        "XDG_STATE_HOME": STATE_HOME,
        "TERM": "xterm-256color",
        "SHELL": "/bin/sh",
    }
)
for name in (
    "HEXE_SESSION",
    "HEXE_PANE_UUID",
    "HEXE_POD_NAME",
    "HEXE_POD_SOCKET",
    "HEXE_FLOAT",
    "HEXE_FLOAT_NAME",
    "HEXE_MUX_SOCKET",
):
    env.pop(name, None)

processes = []
log = open(os.path.join(WORKDIR, "protocol.raw"), "wb")


def daemon_pids():
    result = subprocess.run(
        ["pgrep", "-f", "--", f"daemon --instance {INSTANCE}"],
        capture_output=True,
        text=True,
    )
    return [int(value) for value in result.stdout.split()] if result.returncode == 0 else []


def cleanup():
    for process in processes:
        if process.poll() is None:
            process.kill()
    for pid in daemon_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def fail(message):
    print(f"FAIL: {message}")
    cleanup()
    log.close()
    sys.exit(1)


def read_until(fd, marker, timeout_seconds):
    deadline = time.time() + timeout_seconds
    data = b""
    while time.time() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.2)
        if fd not in readable:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            return False, data
        if not chunk:
            return False, data
        data += chunk
        log.write(chunk)
        log.flush()
        if marker in data:
            return True, data
    return False, data


def run_query(fd, name, sequence, expected):
    command = (
        "stty raw -echo min 1 time 20; "
        f"printf '{sequence}'; "
        f"value=$(dd bs=1 count={len(expected)} 2>/dev/null | od -An -tx1 | tr -d ' \\n'); "
        "stty sane; stty -echo; "
        f"printf '\\nPROTO_{name}_%s\\n' \"$value\"\r"
    ).encode()
    marker = f"PROTO_{name}_{expected.hex()}".encode()
    os.write(fd, command)
    ok, data = read_until(fd, marker, 15)
    if not ok:
        fail(f"{name} reply missing; tail={data[-240:]!r}")
    print(f"{name}: {expected!r}")


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
frontend = subprocess.Popen(
    [HEXE, "mux", "new", "-n", "protocol", "--log", "debug", "--logfile", LOG_PATH],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    env=env,
    cwd=WORKDIR,
    start_new_session=True,
)
os.close(slave)
processes.append(frontend)

time.sleep(3)
if frontend.poll() is not None:
    fail(f"frontend exited early with {frontend.returncode}")
os.write(master, b"stty -echo; echo PROTOCOL_READY\r")
ready, _ = read_until(master, b"PROTOCOL_READY", 20)
if not ready:
    fail("shell did not become ready")

run_query(master, "KITTY", "\\033[?u", b"\x1b[?0u")
run_query(master, "DECRQM", "\\033[?2026$p", b"\x1b[?2026;2$y")
run_query(master, "DSR", "\\033[10;20H\\033[6n", b"\x1b[10;20R")

with open(os.path.join(REPO, "build.zig.zon"), encoding="utf-8") as manifest_file:
    manifest = manifest_file.read()
match = re.search(r'\.version\s*=\s*"([^"]+)"', manifest)
if match is None:
    fail("build.zig.zon has no version")
version_reply = f"\x1bP>|hexe({match.group(1)})\x1b\\".encode()
run_query(master, "XTVERSION", "\\033[>0q", version_reply)

output = b"LIVE_OSC133_OUTPUT"
lifecycle = (
    b"printf '\\033]133;A\\007$ \\033]133;B\\007echo live\\015\\012"
    b"\\033]133;C\\007LIVE_OSC133_OUTPUT\\015\\012"
    b"\\033]133;D;0\\007\\033]133;A\\007$ '\r"
)
os.write(master, lifecycle)
shown, _ = read_until(master, output, 15)
if not shown:
    fail("OSC 133 lifecycle output did not render")

clipboard = b"\x1b]52;c;" + base64.b64encode(output) + b"\x1b\\"
os.write(master, b"\x1by")
copied, data = read_until(master, clipboard, 15)
if not copied:
    fail(f"OSC 133 output was not copied; tail={data[-240:]!r}")
print("OSC133: marked command output copied through the configured action")

if frontend.poll() is not None:
    fail(f"frontend exited with {frontend.returncode}")
cleanup()
log.close()
print("SMOKE PASS: pane protocols reply locally and OSC 133 marks are consumable")
