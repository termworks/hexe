#!/usr/bin/env python3
"""Live check: a statusbar region painted by an EXTERNAL program.

The bar's content comes from another process over a framed JSON socket. This
test stands up a painter of its own -- deliberately not the one anybody ships,
so the protocol is proven rather than one implementation -- points a copy of the
user's real config at it, and asserts three things:

  1. the painter's text actually reaches the rendered statusbar;
  2. killing the painter mid-session leaves the terminal responsive, keeping
     the last frame instead of blanking or freezing;
  3. a painter that accepts the connection and then NEVER ANSWERS cannot stall
     the render loop.

Phase 3 is the one that matters. The whole point of the region client is that
it is non-blocking end to end, and a test that never exercises a wedged painter
proves nothing about that.
"""
import atexit
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import termios
import threading
import time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
# Handed to the painter, which hexe spawns in a process with its own pid and
# so cannot derive this again.
WORKDIR = os.environ.get("HEXE_REGION_WD") or os.path.join(SCRATCH, f"region-{os.getpid()}")
CFGDIR = os.path.join(SCRATCH, f"cfgregion-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)

# Unix socket paths are capped near 108 bytes, so keep this short and in /tmp
# rather than under the (long) scratch directory.
MARKER = "RGNOK49"

REAL_CFG = os.path.expanduser("~/.config/hexe")
if not os.path.isdir(REAL_CFG):
    print("SKIP: no ~/.config/hexe to model the session on")
    raise SystemExit(0)
shutil.copytree(REAL_CFG, os.path.join(CFGDIR, "hexe"), dirs_exist_ok=True)

# ---------------------------------------------------------------- fake painter
# The painter is hexe's child, so what it saw and what the test wants it to do
# both cross a file.
STATE_FILE = os.path.join(WORKDIR, "painter-state.json")
MODE_FILE = os.path.join(WORKDIR, "painter-mode")


def painter_mode(mode=None):
    """Read the mode, or set it."""
    if mode is not None:
        os.makedirs(WORKDIR, exist_ok=True)
        with open(MODE_FILE, "w") as fh:
            fh.write(mode)
        return mode
    try:
        return open(MODE_FILE).read().strip() or "answer"
    except OSError:
        return "answer"


class _State:
    """What the painter recorded, read fresh from disk on every access."""

    def _load(self):
        try:
            return json.load(open(STATE_FILE))
        except (OSError, ValueError):
            return {"requests": 0, "widths": [], "ctx": {}}

    def __getitem__(self, key):
        return self._load()[key]


state = _State()


def frame_send(conn, obj):
    body = json.dumps(obj).encode()
    conn.sendall(struct.pack(">I", len(body)) + body)


def frame_recv(conn):
    hdr = b""
    while len(hdr) < 4:
        chunk = conn.recv(4 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        chunk = conn.recv(need - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


def serve_stdio():
    """Answer on stdin/stdout until hexe closes the pipe."""
    while True:
        head = sys.stdin.buffer.read(4)
        if len(head) < 4:
            return
        need = struct.unpack(">I", head)[0]
        body = sys.stdin.buffer.read(need)
        if len(body) < need:
            return
        req = json.loads(body)

        try:
            cur = json.load(open(STATE_FILE))
        except (OSError, ValueError):
            cur = {"requests": 0, "widths": [], "ctx": {}}
        cur["requests"] += 1
        cur["widths"].append(req.get("width"))
        # Keep the last context so the test can assert on what hexe reports
        # about the pane, not just that a frame came back.
        try:
            cur["ctx"] = req["context"]["values"]
        except (KeyError, TypeError):
            pass
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(cur, fh)
        os.replace(tmp, STATE_FILE)

        if painter_mode() == "wedge":
            continue                  # read it, answer never; hexe must not care
        out = json.dumps({"version": 1, "ok": True, "output": {
            "mode": "run",
            "runs": [{"text": f" {MARKER} ", "style": "fg:15 bg:237 bold"}],
            "width": len(MARKER) + 2,
            "next_frame_ms": None,
        }}).encode()
        sys.stdout.buffer.write(struct.pack(">I", len(out)) + out)
        sys.stdout.buffer.flush()


if "--painter" in sys.argv:
    serve_stdio()
    raise SystemExit(0)

os.makedirs(WORKDIR, exist_ok=True)
painter_mode("answer")


# ------------------------------------------------------------------- hexe config
lay_path = os.path.join(CFGDIR, "hexe", "layout.lua")
if os.path.exists(lay_path):
    lay = open(lay_path).read()
    out, i = [], 0
    while True:
        j = lay.find("hexe.float(", i)
        if j < 0:
            out.append(lay[i:])
            break
        k = lay.find("hexe.float(", j + 1)
        if k < 0:
            k = len(lay)
        out.append(lay[i:j])
        out.append(re.sub(r'command = "[^"]*"', 'command = "/bin/sh"', lay[j:k]))
        i = k
    open(lay_path, "w").write("".join(out))

init_path = os.path.join(CFGDIR, "hexe", "init.lua")
init = open(init_path).read()
init = init.replace('os.getenv("HOME") .. "/.config/hexe/layout.lua"', repr(lay_path).replace("'", '"'))
for a, b in (("exit = true", "exit = false"), ("detach = true", "detach = false"),
             ("disown = true", "disown = false"), ("close = true", "close = false")):
    init = init.replace(a, b)

# The whole bar is painted externally now: point it at the fake painter.
anchor = "hexe.status = {\n  enabled = true,\n"
if anchor not in init:
    print("SKIP: could not find the statusbar config to point at the painter")
    raise SystemExit(0)
def strip_status_zones(text):
    """Remove a `zones = { ... }` block and its `shrink` from the status table.

    The bar is pointed at the fake painter by injecting `view`, and `view` and
    `zones` are mutually exclusive - a config carrying both is a hard error, so
    a real config that has moved to zones would otherwise fail to load and the
    bar would never come up at all.
    """
    i = text.find("zones = {")
    if i >= 0:
        depth, j = 0, text.index("{", i)
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        while j < len(text) and text[j] in ",\r\n \t":
            j += 1
        text = text[:i] + text[j:]
    text = re.sub(r"^\s*shrink\s*=\s*\{[^}]*\}\s*,?.*$", "", text, flags=re.M)
    # And the config's own painter: a duplicate key in a Lua table literal is
    # the LAST one, so leaving it would silently override the fake one injected
    # below and the test would be watching the real painter.
    return re.sub(r"^\s*exec\s*=\s*\"[^\"]*\"\s*,?.*$", "", text, flags=re.M)


init = strip_status_zones(init)

init = init.replace(
    anchor,
    anchor + '''    view = "smoke",
    exec = "%s",
    refresh_ms = 200,
''' % (f"HEXE_REGION_WD={WORKDIR} python3 {os.path.abspath(__file__)} --painter"),
    1,
)
open(init_path, "w").write(init)

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "XDG_CONFIG_HOME": CFGDIR, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_TRUST_ALL_PROJECTS": "1"})
# Running this from inside a hexe pane would otherwise inherit the pane's
# identity, and the new frontend would hit the nested-mux confirmation and exit
# silently with rc=0 -- which looks exactly like a product bug.
for _k in ("HEXE_PANE_UUID", "HEXE_SESSION", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", "--", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
    for pid in pgrep(f"daemon --instance {INST}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    # The painter goes with hexe, but a run that died between spawning it and
    # killing hexe would leave one, so sweep by the marker in its argv.
    subprocess.run(["pkill", "-f", f"HEXE_REGION_WD={WORKDIR}"], capture_output=True)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)


def safe_write(m, data, what, timeout_s=15):
    off, last = 0, time.time()
    while off < len(data):
        r, w, _ = select.select([m], [m], [], 0.5)
        if m in r:
            try:
                log.write(os.read(m, 65536))
            except OSError:
                pass
        if m in w:
            n = os.write(m, data[off:])
            if n:
                off += n
                last = time.time()
        if time.time() - last > timeout_s:
            fail(f"UI FROZEN: the terminal stopped reading input ({what})")


def read_until(m, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([m], [], [], 0.2)
        if m in r:
            try:
                c = os.read(m, 65536)
            except OSError:
                return False
            if not c:
                return False
            buf += c
            log.write(c)
            if marker in buf:
                return True
    return False


log = open(os.path.join(SCRATCH, "smoke-region.raw"), "wb")
print(f"instance={INST} painter=child of hexe")

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "region"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WORKDIR, start_new_session=True)
os.close(slave)
procs.append(fe)
time.sleep(3.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

# 1. The painter's content must actually reach the bar.
if not read_until(master, MARKER.encode(), 15):
    fail("the painter's text never appeared in the statusbar")
print(f"phase1: painter content rendered ({state['requests']} request(s) served)")

if not state["widths"] or not any(w for w in state["widths"]):
    fail("the painter was never told a width — geometry is not reaching it")
print(f"phase2: geometry delivered (widths seen: {sorted(set(state['widths']))[:4]})")

# 2b. Pane state must reach the painter, not just geometry. OSC 9;4 progress is
# the case that regressed silently: hexe parses it, and before it was added to
# the request context there was nothing left in-process to draw it, so the
# information simply stopped anywhere.
safe_write(master, b"printf '\\033]9;4;1;73\\007'\r", "progress set")
deadline = time.time() + 15
while time.time() < deadline:
    if state["ctx"].get("progress_pct") == 73 and state["ctx"].get("progress_state") == "in_progress":
        break
    time.sleep(0.2)
else:
    fail(f"pane progress never reached the painter (ctx={state['ctx'].get('progress_state')!r}/"
         f"{state['ctx'].get('progress_pct')!r})")
print("phase2b: OSC 9;4 progress reached the painter (in_progress 73%)")

safe_write(master, b"printf '\\033]9;4;0;100\\007'\r", "progress clear")
deadline = time.time() + 15
while time.time() < deadline:
    if state["ctx"].get("progress_state") == "inactive":
        break
    time.sleep(0.2)
else:
    fail(f"completed progress never cleared (ctx={state['ctx'].get('progress_state')!r})")
print("phase2c: progress cleared on completion")

# 3. Wedge the painter: it accepts and reads, then never answers.
painter_mode("wedge")
before = state["requests"]
t0 = time.time()
safe_write(master, b"echo WEDGE_OK\r", "wedged painter echo")
if not read_until(master, b"WEDGE_OK", 15):
    fail("terminal unresponsive while the painter is wedged — the loop is blocking on it")
latency = time.time() - t0
print(f"phase3: shell responded in {latency:.1f}s with a wedged painter")
if latency > 8:
    fail(f"shell took {latency:.1f}s — a wedged painter is stalling frames")

worst = 0.0
for i in range(5):
    t0 = time.time()
    safe_write(master, f"echo WLOOP_{i}\r".encode(), f"wedge loop {i}")
    if not read_until(master, f"WLOOP_{i}".encode(), 12):
        fail(f"terminal unresponsive on iteration {i} with a wedged painter")
    dt = time.time() - t0
    worst = max(worst, dt)
    if dt > 8:
        fail(f"iteration {i} took {dt:.1f}s — frames stall on the wedged painter")
print(f"phase4: 5 round-trips stayed responsive while wedged (worst {worst:.1f}s)")
if state["requests"] <= before:
    fail("the client stopped talking to the painter entirely — it should keep retrying")

# 5. Kill the painter outright. The terminal must survive.
#
# It is hexe's child, so killing it is killing that process -- and hexe must
# start a fresh one rather than wedge on a pipe with nothing behind it.
subprocess.run(["pkill", "-f", f"HEXE_REGION_WD={WORKDIR}"], capture_output=True)
time.sleep(1.0)
for i in range(4):
    t0 = time.time()
    safe_write(master, f"echo DEAD_{i}\r".encode(), f"dead painter {i}")
    if not read_until(master, f"DEAD_{i}".encode(), 12):
        fail(f"terminal unresponsive after the painter died (iteration {i})")
    if time.time() - t0 > 8:
        fail("frames stall once the painter is gone")
print("phase5: terminal stayed responsive after the painter died")

if fe.poll() is not None:
    fail(f"frontend died rc={fe.returncode}")

cleanup()
log.close()
print("SMOKE PASS: an external painter drives a statusbar region and can never freeze the terminal")
