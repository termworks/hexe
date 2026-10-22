#!/usr/bin/env python3
"""A colour report from the host reaches a pane only if a pane asked for it.

Hexe queries the host for its own palette, and re-queries after a pane changes
it — which is what a pywal-style recolour does to every pty at once. Those
answers are hexe's. A pane's own colour query is either registered in
`host_colors` or counted into the OSC reply queue, so a report belonging to
neither is nobody's, and typing it into whichever pane happens to be focused
puts `]11;rgb:…` on somebody's command line.

Two ways in, both real:
  * a report nobody asked for, which is what an answer later than
    `QUERY_TIMEOUT_MS` looks like to hexe;
  * the recolour itself, with the host answering slower than that timeout.

The panes are left in cooked mode with echo on, so anything written to a pane's
input is echoed by the line discipline and can be read back as text.
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
INSTANCE = f"colorreply{os.getpid()}"
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
# `rgb:` as text, or the echoed form of a report written into a pane's input.
LEAK = re.compile(r"rgb:[0-9a-fA-F]{2,4}/|\^\[\]1[012];|\^\[\]4;\d+;")

# An answer that arrives after hexe stopped waiting looks exactly like this.
UNASKED = b"\x1b]11;rgb:2222/5050/1818\x1b\\\x1b]10;rgb:cdcd/d6d6/f4f4\x1b\\\x1b]4;3;rgb:f0f0/c6c6/7474\x1b\\"


def full_palette_dump():
    """What the host answers a whole `queryAll`: foreground, background, 0..255.

    The reported shape, and three of these arrived at once — 774 reports, which
    is far past `MAX_PENDING`, so most of them can only be unclaimed.
    """
    out = b"\x1b]10;rgb:f8f8/f3f3/fbfb\x1b\\\x1b]11;rgb:1010/0c0c/1212\x1b\\"
    for index in range(256):
        out += b"\x1b]4;%d;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\" % (
            index, index, index, 255 - index, 255 - index, index // 2, index // 2
        )
    return out


BULK = full_palette_dump() * 3
# A pywal-style recolour: sets, not queries, which is what makes hexe re-ask.
RECOLOUR = (b"\x1b]4;1;#e06c75\x07\x1b]4;2;#98c379\x07\x1b]4;3;#e5c07b\x07"
            b"\x1b]10;#abb2bf\x07\x1b]11;#282c34\x07\x1b]12;#528bff\x07")

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
# Seconds the host waits before answering a colour query. Past hexe's
# QUERY_TIMEOUT_MS the pending is expired and the answer belongs to nobody.
color_delay = [0.0]


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


def fail(message):
    print(f"FAIL: {message}")
    cleanup()
    sys.exit(1)


signal.signal(signal.SIGALRM, lambda *_: fail("timed out"))
signal.alarm(420)


def host_answers(buf):
    """What a real terminal answers in this buffer, and how far it got."""
    out, consumed, colors = b"", 0, False
    for match in OSC_COLOR.finditer(buf):
        what = match.group(1)
        consumed = max(consumed, match.end())
        colors = True
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
    return out, consumed, colors


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
        out, consumed, colors = host_answers(buf)
        if out:
            if colors and color_delay[0]:
                time.sleep(color_delay[0])
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


def leaks():
    found = {}
    for pane in panes():
        text = api("screen_text", json.dumps(pane["uuid"])) or ""
        hits = LEAK.findall(text)
        if hits:
            found[pane["uuid"][:8]] = hits
    return found


def tty_of(uuid):
    hexe("terminal", "send", "--uuid", uuid, "--enter", "tty")
    stop = time.time() + 15
    while time.time() < stop:
        found = re.search(r"/dev/pts/\d+", api("screen_text", json.dumps(uuid)) or "")
        if found:
            return found.group(0)
        time.sleep(0.4)
    return None


def quiesce():
    """Panes in cooked mode with echo on: a shell that has not drawn a prompt."""
    for pane in panes():
        hexe("terminal", "send", "--uuid", pane["uuid"], "--enter", "clear; sleep 25")
    time.sleep(2.0)


time.sleep(3.0)
ptys = {pane["uuid"]: tty_of(pane["uuid"]) for pane in panes()}
if not all(ptys.values()):
    fail(f"could not resolve every pane's pty: {ptys}")

quiesce()
if leaks():
    fail(f"panes held colour text before anything was sent: {leaks()}")

# 1. A report nobody asked for, which is what a late answer looks like.
os.write(master, UNASKED)
time.sleep(3.0)
unasked = leaks()
if unasked:
    fail(f"a colour report nobody asked for was typed into a pane: {unasked}")

# 2. The recolour itself, answered slower than hexe waits. Written into each
#    pane's own pty, which is how a pywal-style script does it.
color_delay[0] = 2.5
for uuid, path in ptys.items():
    with open(path, "wb") as pane_tty:
        pane_tty.write(RECOLOUR)
time.sleep(6.0)
quiesce()
time.sleep(6.0)
recoloured = leaks()
if recoloured:
    fail(f"a late answer to hexe's own re-query was typed into a pane: {recoloured}")

# 3. The reported shape: three whole palettes at once, into a pane whose
#    foreground process is reading in cooked mode and echoes what it is given.
color_delay[0] = 0.0
quiesce()
os.write(master, BULK)
time.sleep(4.0)
bulk = leaks()
if bulk:
    sample = {pane: hits[:4] for pane, hits in bulk.items()}
    fail(f"a whole palette dump was typed into a pane: {sample}")

print("PASS: a colour report reaches a pane only when a pane asked for it")
cleanup()
