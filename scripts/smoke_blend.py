#!/usr/bin/env python3
"""Live OSC 1331 rendering and host-colour ownership check."""

import atexit
import fcntl
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
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"blend{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(os.path.join(WD, "state"), exist_ok=True)

with open(os.path.join(CF, "hexe", "init.lua"), "w", encoding="utf-8") as fh:
    fh.write("local hexe = require('hexe')\nreturn hexe.setup({ palette = { namespaces = true } })\n")

env = os.environ.copy()
env.update({
    "HEXE_INSTANCE": INST,
    "XDG_STATE_HOME": os.path.join(WD, "state"),
    "XDG_CONFIG_HOME": CF,
    "TERM": "xterm-256color",
    "SHELL": "/bin/sh",
    "HEXE_SKIP_LOCAL_CONFIG": "1",
})
for key in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
            "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET"):
    env.pop(key, None)

procs = []
seen = bytearray()
seen_lock = threading.Lock()
desired_background = [b"0000/0000/0000"]
desired_palette = [b"ffff/0000/0000"]
query_counts = {b"\x1b]10;?\x1b\\": 0, b"\x1b]11;?\x1b\\": 0,
                b"\x1b]4;1;?\x1b\\": 0}


def cleanup():
    for process in procs:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
    result = subprocess.run(["pgrep", "-f", f"instance {INST}"], capture_output=True, text=True)
    if result.returncode == 0:
        for pid in result.stdout.split():
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass


def fail(message, capture=None):
    if capture is not None:
        path = os.path.join(WD, "capture.bin")
        with open(path, "wb") as fh:
            fh.write(capture)
        message += f"\n  full capture: {path}"
    print(f"FAIL: {message}")
    cleanup()
    sys.exit(1)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))

master, slave = pty.openpty()
cols = [100]
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, cols[0], 0, 0))
frontend = subprocess.Popen([HEXE, "mux", "new", "-n", "blend"], stdin=slave, stdout=slave,
                            stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave)
procs.append(frontend)


def respond_to_queries(snapshot):
    replies = []
    for query in query_counts:
        count = snapshot.count(query)
        while query_counts[query] < count:
            query_counts[query] += 1
            if query.startswith(b"\x1b]10"):
                replies.append(b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
            elif query.startswith(b"\x1b]11"):
                replies.append(b"\x1b]11;rgb:" + desired_background[0] + b"\x1b\\")
            else:
                replies.append(b"\x1b]4;1;rgb:" + desired_palette[0] + b"\x1b\\")
    for reply in replies:
        os.write(master, reply)


def drain():
    while True:
        try:
            chunk = os.read(master, 65536)
            if not chunk:
                return
        except OSError:
            return
        with seen_lock:
            seen.extend(chunk)
            snapshot = bytes(seen)
        respond_to_queries(snapshot)


threading.Thread(target=drain, daemon=True).start()
time.sleep(4.0)
if frontend.poll() is not None:
    fail(f"frontend exited rc={frontend.returncode}")
if not all(query_counts.values()):
    fail(f"host colour discovery did not query required colours: {query_counts}")

paint = os.path.join(WD, "paint.sh")
with open(paint, "w", encoding="utf-8") as fh:
    fh.write(
        "printf 'OPAQUE \\033[31mRED\\033[0m\\n'\n"
        "printf '\\033]1331;use;fg=30\\033\\\\'\n"
        "printf 'MIXED \\033[31mRED\\033[0m DEFAULT\\n'\n"
        "printf '\\033]1331;use;fg=60\\033\\\\'\n"
        "printf 'NESTED \\033[31mRED\\033[0m\\n'\n"
        "printf '\\033]1331;end\\033\\\\'\n"
        "printf 'RESTORED \\033[31mRED\\033[0m\\n'\n"
        "printf '\\033[38;2;0;0;255mTRUEBLUE\\033[0m\\n'\n"
        "printf '\\033[38;5;200mUNKNOWN\\033[0m\\n'\n"
        "printf '\\033]1331;end\\033\\\\'\n"
        "printf 'AFTER \\033[31mRED\\033[0m\\n'\n"
        "printf '\\033]1331;use;fg=30\\033\\\\\\033[?1049h\\033]1331;end\\033\\\\\\033[?1049l'\n"
        "printf 'ALTRELEASE \\033[32mGREEN\\033[0m\\n'\n"
        "printf '\\033]1330;set;3;1=#00ff00\\033\\\\'\n"
        "printf '\\033]1330;use;3\\033\\\\'\n"
        "printf '\\033]1331;use;fg=30\\033\\\\'\n"
        "printf 'COMPOSED \\033[31mGREEN\\033[0m\\n'\n"
        "printf '\\033]1331;end\\033\\\\\\033]1330;end\\033\\\\'\n"
    )


def clear_seen():
    with seen_lock:
        seen.clear()
        for query in query_counts:
            query_counts[query] = 0


def capture():
    with seen_lock:
        return bytes(seen)


def repaint(wait=2.5):
    clear_seen()
    cols[0] = 99 if cols[0] == 100 else 100
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, cols[0], 0, 0))
    time.sleep(wait)
    return capture()


os.write(master, f"sh {paint}\r".encode())
time.sleep(3.0)
frame = repaint()


def sgr_index(index):
    return re.compile(rb"38[:;]5[:;]" + str(index).encode())


def sgr_rgb(r, g, b):
    return re.compile(rb"38[:;]2[:;]{0,2}" + str(r).encode() + rb"[:;]" +
                      str(g).encode() + rb"[:;]" + str(b).encode())


checks = (
    (re.compile(rb"\x1b\[(?:31m|38[:;]5[:;]1m)"), "ordinary ANSI red did not remain an ANSI/indexed colour outside the scope"),
    (sgr_rgb(77, 0, 0), "30 percent ANSI red was not mixed against black"),
    (sgr_rgb(77, 77, 77), "SGR reset dropped the live scope or default foreground did not mix"),
    (sgr_rgb(153, 0, 0), "nested 60 percent scope was not retained"),
    (sgr_rgb(0, 0, 77), "truecolour foreground did not mix"),
    (sgr_index(200), "unknown host palette entry did not degrade to opaque indexed output"),
    (re.compile(rb"\x1b\[(?:32m|38[:;]5[:;]2m)"), "leaving the alternate screen resurrected a released blend scope"),
    (sgr_rgb(0, 77, 0), "OSC 1330 namespace did not resolve before OSC 1331 mixing"),
)
for pattern, message in checks:
    if not pattern.search(frame):
        fail(message, frame)
print("render: indexed, default, truecolour, nested and OSC 1330 sources mix correctly")

query_helper = os.path.join(WD, "query.py")
query_result = os.path.join(WD, "query-result")
blend_query_result = os.path.join(WD, "blend-query-result")
with open(query_helper, "w", encoding="utf-8") as fh:
    fh.write(
        "import os, select, termios, time, tty\n"
        "def read_st():\n"
        "  data = b''; end = time.time() + 4\n"
        "  while b'\\x1b\\\\' not in data and time.time() < end:\n"
        "    ready, _, _ = select.select([0], [], [], 0.2)\n"
        "    if ready: data += os.read(0, 256)\n"
        "  return data\n"
        "old = termios.tcgetattr(0)\n"
        "try:\n"
        "  tty.setraw(0)\n"
        "  os.write(1, b'\\x1b]1331;ask\\x1b\\\\')\n"
        f"  open({blend_query_result!r}, 'wb').write(read_st())\n"
        "  os.write(1, b'\\x1b]4;1;?\\x1b\\\\')\n"
        f"  open({query_result!r}, 'wb').write(read_st())\n"
        "finally:\n"
        "  termios.tcsetattr(0, termios.TCSANOW, old)\n"
    )
os.write(master, f"python3 {query_helper}\r".encode())
deadline = time.time() + 8
while not os.path.exists(query_result) and time.time() < deadline:
    time.sleep(0.2)
if not os.path.exists(query_result):
    fail("pane OSC 4 query did not complete")
if not os.path.exists(blend_query_result):
    fail("OSC 1331 capability query did not complete")
with open(blend_query_result, "rb") as fh:
    blend_reply = fh.read()
if b"\x1b]1331;have;1;fg\x1b\\" not in blend_reply:
    fail(f"OSC 1331 capability reply was wrong: {blend_reply!r}")
with open(query_result, "rb") as fh:
    pane_reply = fh.read()
if b"\x1b]4;1;rgb:ffff/0000/0000\x1b\\" not in pane_reply:
    fail(f"pane did not receive its OSC 4 reply: {pane_reply!r}")
print("ownership: a pane-issued OSC 4 query received its host reply")

mutation = os.path.join(WD, "mutate.sh")
with open(mutation, "w", encoding="utf-8") as fh:
    fh.write("printf '\\033]4;1;#ffff00\\033\\\\'\n")
desired_palette[0] = b"ffff/ffff/0000"
previous_palette_queries = query_counts[b"\x1b]4;1;?\x1b\\"]
os.write(master, f"sh {mutation}\r".encode())
deadline = time.time() + 5
while query_counts[b"\x1b]4;1;?\x1b\\"] <= previous_palette_queries and time.time() < deadline:
    time.sleep(0.1)
time.sleep(1.0)
mutated = repaint()
if not sgr_rgb(77, 77, 0).search(mutated):
    fail("forwarded OSC 4 mutation did not invalidate and refresh the host palette", mutated)
print("mutation: forwarded host palette changes refresh retained mixed cells")

with open(mutation, "w", encoding="utf-8") as fh:
    fh.write("printf '\\033]104;1\\033\\\\'\n")
desired_palette[0] = b"ffff/0000/0000"
previous_palette_queries = query_counts[b"\x1b]4;1;?\x1b\\"]
os.write(master, f"sh {mutation}\r".encode())
deadline = time.time() + 5
while query_counts[b"\x1b]4;1;?\x1b\\"] <= previous_palette_queries and time.time() < deadline:
    time.sleep(0.1)
time.sleep(1.0)

desired_background[0] = b"0000/0000/ffff"
previous_bg_queries = query_counts[b"\x1b]11;?\x1b\\"]
os.write(master, b"\x1b[?997;2n")
deadline = time.time() + 5
while query_counts[b"\x1b]11;?\x1b\\"] <= previous_bg_queries and time.time() < deadline:
    time.sleep(0.1)
time.sleep(1.0)
changed = repaint()
if not sgr_rgb(77, 0, 179).search(changed):
    fail("host colour-scheme update did not repaint retained cells against blue", changed)
print("refresh: host colour changes repaint existing mixed cells without application redraw")

print("PASS: OSC 1331 live blend smoke")
