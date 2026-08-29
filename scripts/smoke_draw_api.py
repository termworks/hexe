#!/usr/bin/env python3
"""Anything may put something on the screen, and take it back off.

hexe has always been able to draw art at an arbitrary rectangle -- a pane's
sprite is exactly that -- but only its own config could ask for one. `draw`
makes that a verb, so a plugin can put a panel anywhere without hexe growing a
feature per panel.

Two sources, because callers differ:

A drawing is a name, a rectangle and its bytes -- it borrows no painter and no
config from anywhere, so a caller with neither can still show something.

Checked against a real mux, with NO painter configured at all:

  * a drawing appears, and is gone after `undraw`;
  * naming one twice replaces it rather than stacking two;
  * a `ttl_ms` drawing disappears on its own, so a caller that dies does not
    leave something on the screen for ever.
"""
import os, pty, subprocess, time, fcntl, termios, struct, threading, re, sys

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
W = "/tmp/hexe-drawapi"
subprocess.run(["rm", "-rf", W])
for d in (W + "/run/hexe", W + "/cfg/hexe"):
    os.makedirs(d, exist_ok=True)

# No painter at all: that is the point. A drawing must not need one.
open(W + "/cfg/hexe/init.lua", "w").write(
    "local hexe = require('hexe')\nhexe.status = { enabled = false }\n"
)

e = dict(os.environ)
e.update({"HEXE_INSTANCE": "drawapi", "XDG_RUNTIME_DIR": W + "/run", "XDG_CONFIG_HOME": W + "/cfg",
          "XDG_STATE_HOME": W + "/state", "XDG_DATA_HOME": W + "/data", "TERM": "xterm-256color",
          "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
for k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET", "HEXE_API_SOCKET",
          "HEXE_PAINTER_SOCKET", "HEXE_FLOAT", "HEXE_ENV_FD", "HEXE_BIN"):
    e.pop(k, None)

m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
p = subprocess.Popen([HEXE, "mux", "new", "-n", "da"], stdin=s, stdout=s, stderr=s, env=e, cwd=W,
                     start_new_session=True)
os.close(s)
buf = bytearray()


def drain():
    while True:
        try:
            d = os.read(m, 65536)
            if not d:
                return
            buf.extend(d)
        except OSError:
            return


threading.Thread(target=drain, daemon=True).start()


def cleanup():
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=6)
        except subprocess.TimeoutExpired:
            p.kill()


def fail(msg):
    print("FAIL:", msg)
    cleanup()
    raise SystemExit(1)


def api(*args):
    return subprocess.run([HEXE, "api", *args], env=e, capture_output=True, text=True, cwd=W)


def watch():
    """Start listening BEFORE the thing that repaints.

    With no painter there is nothing ticking, so a drawing produces exactly one
    repaint. Clearing the buffer after asking for it throws that repaint away
    and the test then waits for a redraw that is never coming."""
    del buf[:]


def screen(settle=2.5):
    time.sleep(settle)
    return re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '',
                  buf.decode('utf8', 'replace'))


time.sleep(5)
if "draw" not in api("verbs").stdout:
    fail("`draw` is not advertised as a verb")
print("verbs: draw and undraw are offered")

# ---- content: bytes straight onto the screen --------------------------------
watch()
if "true" not in api("draw", '"panel"', '{"content":"CONTENT-MARK","width":20,"height":1,"x":5,"y":3}').stdout:
    fail("draw with `content` was refused")
if "CONTENT-MARK" not in screen():
    fail("a `content` drawing never reached the screen")
print("content: bytes the caller supplied were drawn")

# ---- naming it again replaces, rather than stacking -------------------------
watch()
api("draw", '"panel"', '{"content":"SECOND-MARK","width":20,"height":1,"x":5,"y":3}')
txt = screen()
if "SECOND-MARK" not in txt:
    fail("redrawing the same name did not replace its content")
print("replace: the same name draws over itself")

watch()
if "true" not in api("undraw", '"panel"').stdout:
    fail("undraw did not report removing the drawing")
if "SECOND-MARK" in screen():
    fail("the drawing survived undraw")
print("undraw: it comes back off the screen")


# ---- a ttl cleans up after a caller that does not ---------------------------
watch()
api("draw", '"tmp"', '{"content":"TTL-MARK","width":20,"height":1,"x":5,"y":9,"ttl_ms":1500}')
if "TTL-MARK" not in screen(1.0):
    fail("a ttl drawing never appeared")
watch()
if "TTL-MARK" in screen(4.0):
    fail("a ttl drawing outlived its ttl -- a caller that dies leaves litter on the screen")
print("ttl: it expires on its own")

cleanup()
print("PASS: anything can draw anywhere, needing no painter at all")
