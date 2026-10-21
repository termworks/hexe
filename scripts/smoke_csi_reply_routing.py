#!/usr/bin/env python3
"""A CSI reply from the host reaches a float only if a pane could have asked.

hexe asks the host terminal about its own capabilities -- DECRQM for 1004/1016/
2026/2027/2031 and CSI ? u -- while a float is on screen. `pane_respond`
answers those same query types from hexe's own emulation and never forwards
them, so such a reply coming back from the host is an answer to hexe's own
question and belongs to nobody in a pane. Device attributes are the one CSI
query it does forward, so a DA reply still goes to the float that may have
asked for it.

The panes are left in cooked mode with echo on, which is a shell that has not
yet drawn its first prompt: anything written to a pane's input is echoed by the
line discipline and shows up as text, which is how the bug was visible.
"""

import atexit
import fcntl
import json
import os
import pty
import re
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
INSTANCE = f"csireply{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, INSTANCE)
CONFIG_HOME = os.path.join(WORKDIR, "config")
STATE_HOME = os.path.join(WORKDIR, "state")
RUNTIME_DIR = os.path.join(WORKDIR, "run")
SESSION = "t"
ROWS, COLS = 45, 150

OSC_COLOR = re.compile(rb"\x1b\]((?:4;\d+)|10|11|12);\?(?:\x1b\\|\x07)")
DECRQM = re.compile(rb"\x1b\[\?(\d+)\$p")
CSI_U = re.compile(rb"\x1b\[\?u")
DA1 = re.compile(rb"\x1b\[c")
ECHOED = re.compile(r"\^\[[\[\]][^\s]*")

# Answers to hexe's own questions. No pane can be waiting for any of these.
HEXE_OWN = b"\x1b[?1016;2$y\x1b[?0u\x1b[?2026;2$y\x1b[?1004;2$y"
# Device attributes, the one shape a pane's query can produce.
DEVICE_ATTRS = b"\x1b[?62;4c"

os.makedirs(os.path.join(CONFIG_HOME, "hexe"), exist_ok=True)
os.makedirs(STATE_HOME, exist_ok=True)
os.makedirs(RUNTIME_DIR, exist_ok=True)
with open(os.path.join(CONFIG_HOME, "hexe", "init.lua"), "w", encoding="utf-8") as config:
    config.write("local hexe = require('hexe')\nreturn hexe.setup({})\n")

env = os.environ.copy()
env.update(
    {
        "HEXE_INSTANCE": INSTANCE,
        "HEXE_TRUST_ALL_PROJECTS": "1",
        "XDG_CONFIG_HOME": CONFIG_HOME,
        "XDG_STATE_HOME": STATE_HOME,
        "XDG_RUNTIME_DIR": RUNTIME_DIR,
        "TERM": "xterm-256color",
        "SHELL": "/bin/sh",
        "HEXE_MAX_CONNECTIONS_PER_MINUTE": "256",
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
    "HEXE_PAINTER_SOCKET",
    "HEXE_API_SOCKET",
):
    env.pop(name, None)

processes = []


def daemon_pids():
    result = subprocess.run(
        ["pgrep", "-f", "--", f"instance {INSTANCE}"], capture_output=True, text=True
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


atexit.register(cleanup)
signal.signal(signal.SIGALRM, lambda *_: fail("timed out"))
signal.alarm(300)


def fail(message):
    print(f"FAIL: {message}")
    cleanup()
    sys.exit(1)


def host_answers(buf):
    """What a real terminal would answer in this buffer, and how far it got."""
    out, consumed = b"", 0
    for match in OSC_COLOR.finditer(buf):
        what = match.group(1)
        consumed = max(consumed, match.end())
        if what.startswith(b"4;"):
            out += b"\x1b]4;" + what.split(b";")[1] + b";rgb:6e6e/ffff/5757\x1b\\"
        else:
            out += b"\x1b]" + what + b";rgb:2222/5050/1818\x1b\\"
    for match in DECRQM.finditer(buf):
        consumed = max(consumed, match.end())
        out += b"\x1b[?" + match.group(1) + b";2$y"
    for match in CSI_U.finditer(buf):
        consumed = max(consumed, match.end())
        out += b"\x1b[?0u"
    for match in DA1.finditer(buf):
        consumed = max(consumed, match.end())
        out += b"\x1b[?62;4c"
    return out, consumed


def host(master):
    buf = b""
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        out, consumed = host_answers(buf)
        if out:
            try:
                os.write(master, out)
            except OSError:
                return
        # Keep only enough unanswered tail to hold a query split across reads.
        buf = buf[max(consumed, len(buf) - 64):]


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
frontend = subprocess.Popen(
    [HEXE, "mux", "new", "-n", SESSION],
    stdin=slave,
    stdout=slave,
    stderr=slave,
    env=env,
    cwd=WORKDIR,
    start_new_session=True,
)
os.close(slave)
processes.append(frontend)
threading.Thread(target=host, args=(master,), daemon=True).start()


def session_socket():
    for root, _dirs, files in os.walk(RUNTIME_DIR):
        if f"api@{SESSION}.sock" in files:
            return os.path.join(root, f"api@{SESSION}.sock")
    return None


deadline = time.time() + 60
while time.time() < deadline and session_socket() is None:
    if frontend.poll() is not None:
        fail(f"frontend exited rc={frontend.returncode}")
    time.sleep(0.2)
if session_socket() is None:
    fail("session never came up")


def hexe(*args):
    return subprocess.run(
        [HEXE, *args], capture_output=True, text=True, env=env, cwd=WORKDIR, timeout=60
    )


def api(call, *args):
    result = hexe("api", call, *args, "--session", SESSION)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)["result"]
    except (ValueError, KeyError):
        return None


def panes():
    return api("panes") or []


def echoed_in_panes():
    found = {}
    for pane in panes():
        text = api("screen_text", json.dumps(pane["uuid"])) or ""
        hits = ECHOED.findall(text)
        if hits:
            found[pane["uuid"][:8]] = (bool(pane.get("is_float")), hits)
    return found


time.sleep(3.0)
for pane in panes():
    hexe(
        "terminal",
        "send",
        "--uuid",
        pane["uuid"],
        "--enter",
        f"{HEXE} terminal float -c /bin/sh --title probe",
    )
time.sleep(5.0)
floats = [pane for pane in panes() if pane.get("is_float")]
if not floats:
    fail("no float came up, so the routing under test never runs")

# Cooked mode with echo on: a shell that has not drawn its first prompt yet.
for pane in panes():
    hexe("terminal", "send", "--uuid", pane["uuid"], "--enter", "clear; sleep 20")
time.sleep(2.0)
if echoed_in_panes():
    fail(f"panes already held escape text before any reply was sent: {echoed_in_panes()}")

os.write(master, HEXE_OWN)
time.sleep(3.0)
leaked = echoed_in_panes()
if leaked:
    fail(f"a reply to hexe's own query was typed into a pane: {leaked}")

os.write(master, DEVICE_ATTRS)
time.sleep(3.0)
delivered = echoed_in_panes()
if not delivered:
    fail("device attributes reached no pane, so float query routing is broken")
if not any(is_float for is_float, _hits in delivered.values()):
    fail(f"device attributes went somewhere other than the float: {delivered}")

print("PASS: host replies reach a float only when a pane could have asked")
cleanup()
