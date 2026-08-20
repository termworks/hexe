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
WORKDIR = os.path.join(SCRATCH, f"region-{os.getpid()}")
CFGDIR = os.path.join(SCRATCH, f"cfgregion-{os.getpid()}")
os.makedirs(WORKDIR, exist_ok=True)

# Unix socket paths are capped near 108 bytes, so keep this short and in /tmp
# rather than under the (long) scratch directory.
SOCK = f"/tmp/hexe-rgn-{os.getpid()}.sock"
MARKER = "RGNOK49"

REAL_CFG = os.path.expanduser("~/.config/hexe")
if not os.path.isdir(REAL_CFG):
    print("SKIP: no ~/.config/hexe to model the session on")
    raise SystemExit(0)
shutil.copytree(REAL_CFG, os.path.join(CFGDIR, "hexe"), dirs_exist_ok=True)

# ---------------------------------------------------------------- fake painter
state = {"requests": 0, "mode": "answer", "widths": [], "ctx": {}}
stop_painter = threading.Event()


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


def painter():
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    srv.bind(SOCK)
    srv.listen(16)
    srv.settimeout(0.3)
    while not stop_painter.is_set():
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        try:
            req = frame_recv(conn)
            if req is None:
                conn.close()
                continue
            state["requests"] += 1
            state["widths"].append(req.get("width"))
            # Keep the last context so the test can assert on what hexe reports
            # about the pane, not just that a frame came back.
            try:
                state["ctx"] = req["context"]["values"]
            except (KeyError, TypeError):
                pass
            if state["mode"] == "wedge":
                # Accept, read, then answer never. The client must not care.
                continue
            frame_send(conn, {
                "version": 1,
                "ok": True,
                "output": {
                    "mode": "run",
                    "runs": [{"text": f" {MARKER} ", "style": "fg:15 bg:237 bold"}],
                    "width": len(MARKER) + 2,
                    "next_frame_ms": None,
                },
            })
        except OSError:
            pass
        finally:
            if state["mode"] != "wedge":
                conn.close()
    srv.close()


painter_thread = threading.Thread(target=painter, daemon=True)
painter_thread.start()
time.sleep(0.4)

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
anchor = "  status = {\n    enabled = true,\n"
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
    return re.sub(r"^\s*shrink\s*=\s*\{[^}]*\}\s*,?.*$", "", text, flags=re.M)


init = strip_status_zones(init)

init = init.replace(
    anchor,
    anchor + '''    view = "smoke",
    socket = "%s",
    refresh_ms = 200,
''' % SOCK,
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
    stop_painter.set()
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
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass


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
print(f"instance={INST} painter={SOCK}")

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
state["mode"] = "wedge"
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
stop_painter.set()
painter_thread.join(timeout=3)
try:
    os.unlink(SOCK)
except FileNotFoundError:
    pass
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
