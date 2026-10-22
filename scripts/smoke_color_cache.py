#!/usr/bin/env python3
"""A pane's colour query is answered from hexe's cache, inside the asker's budget.

A terminal answers OSC 10/11/4 in microseconds, and askers read with a budget to
match: oslo allows 100 ms for its whole startup exchange. Relaying the query to
the host costs that round trip on top of two daemons, so the answer can arrive
after the asker stopped reading — where the line discipline prints it as text
instead. Hexe already holds the host's palette, so it answers from there.

The host here answers colour queries deliberately late: slower than any asker
waits, but inside the window hexe fills its own cache in. With the cache a pane
gets its answer at once; without it the pane gets nothing in time.

Also checks the answer is not stale: after a program sets a colour, a later
query reports the new one.
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
INSTANCE = f"colorcache{os.getpid()}"
WORKDIR = os.path.join(SCRATCH, INSTANCE)
CONFIG_HOME = os.path.join(WORKDIR, "config")
STATE_HOME = os.path.join(WORKDIR, "state")
RUNTIME_DIR = os.path.join(WORKDIR, "run")
SESSION = "t"
ROWS, COLS = 45, 150

# Past any asker's budget, inside the 1500 ms hexe waits for its own answers.
HOST_DELAY_S = 0.4
# What the asker allows, as oslo does for its startup exchange.
ASKER_BUDGET_S = 0.15

OSC_COLOR_QUERY = re.compile(rb"\x1b\]((?:4;\d+)|10|11|12);\?(?:\x1b\\|\x07)")
OSC_BG_SET = re.compile(rb"\x1b\]11;#([0-9a-fA-F]{6})(?:\x1b\\|\x07)")
DECRQM = re.compile(rb"\x1b\[\?(\d+)\$p")
CSI_U = re.compile(rb"\x1b\[\?u")
DA1 = re.compile(rb"\x1b\[c")

os.makedirs(os.path.join(CONFIG_HOME, "hexe"), exist_ok=True)
os.makedirs(STATE_HOME, exist_ok=True)
os.makedirs(RUNTIME_DIR, exist_ok=True)
with open(os.path.join(CONFIG_HOME, "hexe", "init.lua"), "w", encoding="utf-8") as config:
    config.write("local hexe = require('hexe')\nreturn hexe.setup({})\n")

READER = os.path.join(WORKDIR, "ask.py")
with open(READER, "w", encoding="utf-8") as reader:
    reader.write(
        "import os, select, sys, termios, tty\n"
        "budget = float(sys.argv[1])\n"
        "# Built here rather than passed in: a shell argument cannot carry a real ESC.\n"
        "if sys.argv[2] == 'bg':\n"
        "    want = b'\\x1b]11;?\\x1b\\\\'\n"
        "else:\n"
        "    want = b'\\x1b]10;?\\x1b\\\\' + b'\\x1b]11;?\\x1b\\\\'\n"
        "    want += b''.join(b'\\x1b]4;%d;?\\x1b\\\\' % i for i in range(16))\n"
        "fd = os.open('/dev/tty', os.O_RDWR)\n"
        "old = termios.tcgetattr(fd)\n"
        "tty.setraw(fd)\n"
        "try:\n"
        "    os.write(fd, want)\n"
        "    data = b''\n"
        "    end = __import__('time').monotonic() + budget\n"
        "    while True:\n"
        "        left = end - __import__('time').monotonic()\n"
        "        if left <= 0: break\n"
        "        r, _, _ = select.select([fd], [], [], left)\n"
        "        if not r: break\n"
        "        data += os.read(fd, 65536)\n"
        "finally:\n"
        "    termios.tcsetattr(fd, termios.TCSADRAIN, old)\n"
        "print('INBUDGET=%d:%s' % (data.count(b'rgb:'), data.replace(b'\\x1b', b'').decode('latin1')[:40]))\n"
    )

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
# What the host reports as its background, which a program can change.
background = ["2222/5050/1818"]


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
        # A program setting the background changes what a query reports, as on a
        # real terminal — which is what makes a stale cached answer visible.
        for match in OSC_BG_SET.finditer(buf):
            hexcolor = match.group(1).decode()
            background[0] = "/".join(hexcolor[at:at + 2] * 2 for at in (0, 2, 4))
        out, consumed, colors = b"", 0, False
        for match in OSC_COLOR_QUERY.finditer(buf):
            what = match.group(1)
            consumed = max(consumed, match.end())
            colors = True
            if what.startswith(b"4;"):
                out += b"\x1b]4;" + what.split(b";")[1] + b";rgb:6e6e/ffff/5757\x1b\\"
            elif what == b"11":
                out += b"\x1b]11;rgb:" + background[0].encode() + b"\x1b\\"
            else:
                out += b"\x1b]" + what + b";rgb:cdcd/d6d6/f4f4\x1b\\"
        for match in DECRQM.finditer(buf):
            consumed = max(consumed, match.end())
            out += b"\x1b[?" + match.group(1) + b";2$y"
        for match in CSI_U.finditer(buf):
            consumed = max(consumed, match.end())
            out += b"\x1b[?0u"
        for match in DA1.finditer(buf):
            consumed = max(consumed, match.end())
            out += b"\x1b[?62;4c"
        if out:
            if colors:
                time.sleep(HOST_DELAY_S)
            try:
                os.write(master, out)
            except OSError:
                return
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


def first_pane():
    panes = api("panes") or []
    if not panes:
        fail("no pane")
    return panes[0]["uuid"]


def ask(uuid, which, label):
    """Run the reader in the pane and return what it got inside its budget."""
    hexe("terminal", "send", "--uuid", uuid, "--enter", "clear")
    time.sleep(0.8)
    hexe(
        "terminal", "send", "--uuid", uuid, "--enter",
        f"{sys.executable} -I {READER} {ASKER_BUDGET_S} {which}",
    )
    stop = time.time() + 40
    while time.time() < stop:
        text = api("screen_text", json.dumps(uuid)) or ""
        found = re.search(r"INBUDGET=(\d+):(\S*)", text)
        if found:
            return int(found.group(1)), found.group(2)
        time.sleep(0.4)
    fail(f"{label}: the reader never reported")
    return 0, ""


pane = first_pane()
# Let hexe finish filling its own cache, which the slow host makes slow too.
time.sleep(6.0)

# 1. The budget: two dynamic colours and sixteen palette entries, all of which
#    hexe asked the host about at startup, so all of them are cached.
count, sample = ask(pane, "all", "budget")
if count < 18:
    fail(f"only {count} of 18 colour answers arrived within {ASKER_BUDGET_S}s: {sample}")

# 2. Freshness: a program sets the background, so a later query must report the
#    new colour rather than whatever was cached before.
hexe("terminal", "send", "--uuid", pane, "--enter",
     "printf '\\033]11;#112233\\033\\\\'")
time.sleep(4.0)
count, sample = ask(pane, "bg", "freshness")
if count < 1:
    fail(f"no answer to the query after a set: {sample}")
if "1111/2222/3333" not in sample:
    fail(f"the answer after a set was stale: {sample}")

print(f"PASS: a pane's colour query is answered from cache within {ASKER_BUDGET_S}s, and stays fresh")
cleanup()
