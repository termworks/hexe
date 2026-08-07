#!/usr/bin/env python3
"""Exercise terminal protocol negotiation and surfaces through a live frontend."""

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
ROWS = 40
COLS = 140
os.makedirs(os.path.join(CONFIG_HOME, "hexe"), exist_ok=True)
os.makedirs(STATE_HOME, exist_ok=True)

with open(os.path.join(CONFIG_HOME, "hexe", "init.lua"), "w", encoding="utf-8") as config:
    config.write(
        "local hexe = require('hexe')\n"
        "return hexe.setup({ keys = {\n"
        "  hexe.key({ hexe.key.alt, hexe.key['y'] }, hexe.action.prompt.copy_output()),\n"
        "  hexe.key({ hexe.key.alt, hexe.key['v'] }, hexe.action.split.vertical()),\n"
        "  hexe.key({ hexe.key.alt, hexe.key['h'] }, hexe.action.focus.move('left')),\n"
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
with open(os.path.join(REPO, "scripts", "smoke_float_content.py"), encoding="utf-8") as screen_file:
    screen_source = screen_file.read()
screen_namespace = {}
exec(
    f"import re\nROWS,COLS={ROWS},{COLS}\n"
    + screen_source[screen_source.index("class Screen:") : screen_source.index("m, sl = pty.openpty()")],
    screen_namespace,
)
screen = screen_namespace["Screen"]()


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
        screen.feed(chunk)
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


def pump(fd, duration):
    deadline = time.time() + duration
    data = b""
    while time.time() < deadline:
        readable, _, _ = select.select([fd], [], [], 0.01)
        if fd not in readable:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
        log.write(chunk)
        log.flush()
        screen.feed(chunk)
    return data


def wait_screen(fd, marker, timeout_seconds):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        pump(fd, 0.1)
        if marker in screen.text():
            return True
    return False


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
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

def run_key_case(name, host_sequence, expected):
    command = (
        "stty raw -echo min 0 time 20; "
        f"printf '\\033[>1uKEY_{name}_READY\\r\\n'; "
        "value=$(dd bs=64 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n'); "
        "printf '\\033[<u'; stty sane; stty -echo; "
        f"printf '\\nPROTO_KEY_{name}_%s\\n' \"$value\"\r"
    ).encode()
    os.write(master, command)
    ready, _ = read_until(master, f"KEY_{name}_READY".encode(), 15)
    if not ready:
        fail(f"{name} key capture did not become ready")
    time.sleep(0.2)
    os.write(master, host_sequence)
    marker = f"PROTO_KEY_{name}_{expected.hex()}".encode()
    ok, data = read_until(master, marker, 15)
    if not ok:
        fail(f"{name} did not produce its expected pane encoding; tail={data[-240:]!r}")


run_key_case("CTRL_I", b"\x1b[105;5u", b"\x1b[105;5u")
run_key_case("TAB", b"\x1b[9u", b"\x09")
run_key_case("CTRL_M", b"\x1b[109;5u", b"\x1b[109;5u")
run_key_case("ENTER", b"\x1b[13u", b"\x0d")
print("KITTY KEYS: Ctrl-I, Tab, Ctrl-M, and Enter remained distinct")

os.write(
    master,
    b"printf '\\033[?2026h\\033[8;1HFIRST_SYNC'; sleep 0.05; "
    b"printf '\\033[8;1HSECOND_SYNC\\033[?2026l'\r",
)
sync_deadline = time.time() + 10
saw_intermediate = False
while time.time() < sync_deadline and "SECOND_SYNC" not in screen.text():
    pump(master, 0.005)
    saw_intermediate = saw_intermediate or "FIRST_SYNC" in screen.text()
if "SECOND_SYNC" not in screen.text():
    fail("synchronized output never presented its completed frame")
if saw_intermediate:
    fail("synchronized output exposed an intermediate frame")
print("SYNC: completed frame presented without exposing the intermediate frame")

mouse_expected = b"\x1b[<0;20;10M"
mouse_command = (
    "stty raw -echo min 1 time 20; "
    "printf '\\033[?1000h\\033[?1006hMOUSE_CAPTURE_READY\\r\\n'; "
    f"value=$(dd bs=1 count={len(mouse_expected)} 2>/dev/null | od -An -tx1 | tr -d ' \\n'); "
    "printf '\\033[?1000l\\033[?1006l'; stty sane; stty -echo; "
    "printf '\\nPROTO_MOUSE_%s\\n' \"$value\"\r"
).encode()
os.write(master, mouse_command)
mouse_ready, _ = read_until(master, b"MOUSE_CAPTURE_READY", 15)
if not mouse_ready:
    fail("mouse-aware pane did not become ready")
os.write(master, b"\x1b[<0;20;10M")
mouse_ok, mouse_data = read_until(master, b"PROTO_MOUSE_" + mouse_expected.hex().encode(), 15)
if not mouse_ok:
    fail(f"tracked primary-screen click was not pane-local; tail={mouse_data[-240:]!r}")
print("MOUSE: primary-screen SGR click reached the pane with local coordinates")

selection_text = b"SELECT_LIVE"
os.write(master, b"printf '\\033[20;30HSELECT_LIVE'\r")
if not wait_screen(master, "SELECT_LIVE", 15):
    fail("selection fixture did not render")
pump(master, 0.2)
selection_clipboard = b"\x1b]52;c;" + base64.b64encode(selection_text) + b"\x1b\\"
os.write(master, b"\x1b[<0;30;20M\x1b[<32;40;20M\x1b[<0;40;20m")
selected, selection_data = read_until(master, selection_clipboard, 15)
if not selected:
    fail(f"plain-pane mouse selection did not copy text; tail={selection_data[-240:]!r}")
print("MOUSE: untracked pane retained mux text selection")

os.write(master, b"printf '\\033]99;i=live:p=title;Live\\033\\\\033]99;i=live:p=body;Once\\033\\'\r")
os.write(master, b"printf '\\033]777;notify;Live;Once\\033\\'\r")
if not wait_screen(master, "Live: Once", 15):
    fail("pane notification did not reach the mux surface")
notification_match = re.search(r"\[[0-9a-f]{8}\] Live: Once", screen.text())
if notification_match is None:
    fail("pane notification did not identify its originating pane")
pump(master, 3.8)
if "Live: Once" in screen.text():
    fail("matching Kitty and legacy notifications produced a duplicate queue entry")
print("NOTIFY: pane-attributed Kitty/legacy fallback rendered exactly once")

os.write(master, b"printf '\\033]9;4;1;73\\007'\r")
if not wait_screen(master, "progress 73%", 15):
    fail("pane progress did not reach the status bar")
os.write(master, b"printf '\\033]9;4;0;100\\007'\r")
pump(master, 0.8)
if "progress 73%" in screen.text():
    fail("completed pane progress did not clear from the status bar")
print("PROGRESS: pane progress surfaced and cleared on completion")

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

os.write(master, b"\x1bv")
pump(master, 1.5)
os.write(master, b"stty -echo; echo SPLIT_READY\r")
split_ready, _ = read_until(master, b"SPLIT_READY", 20)
if not split_ready:
    fail("second split pane did not become ready")
split_query = (
    "sleep 1; stty raw -echo min 1 time 20; "
    "printf '\\033[7;11H\\033[6n'; "
    "value=$(dd bs=1 count=7 2>/dev/null | od -An -tx1 | tr -d ' \\n'); "
    "stty sane; stty -echo; printf '\\nPROTO_SPLIT_DSR_%s\\n' \"$value\"\r"
).encode()
os.write(master, split_query)
time.sleep(0.2)
os.write(master, b"\x1bh")
split_expected = b"\x1b[7;11R"
split_ok, split_data = read_until(master, b"PROTO_SPLIT_DSR_" + split_expected.hex().encode(), 20)
if not split_ok:
    fail(f"unfocused split did not receive pane-local DSR; tail={split_data[-240:]!r}")
print("DSR SPLIT: unfocused offset pane received its own local cursor position")

if frontend.poll() is not None:
    fail(f"frontend exited with {frontend.returncode}")
cleanup()
log.close()
print("SMOKE PASS: every PLAN terminal protocol live check passed")
