#!/usr/bin/env python3
"""A filmstrip: one fetch buys a whole animation cycle.

A painter that animates used to be asked for every frame, so a 40ms spinner
meant 25 round trips a second even though the data underneath -- the clock, the
branch, the cwd -- changes about once. The animation rate and the data rate were
the same number, and it was the animation that set it.

A painter may now answer with `frames`: every picture of one cycle, each with
its own hold. The frontend plays them off its own timer and comes back only when
`refresh_ms` says the data could have moved.

Checked here against a real mux and a counting painter:

  * the strip actually plays -- every frame of the cycle reaches the screen,
    which is the animation happening with no painter involved;
  * it costs one fetch per refresh, not one per frame, which is the whole point.
"""
import os, pty, subprocess, time, fcntl, termios, struct, threading, re, sys

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
H = os.path.join(REPO, "zig-out/bin/hexe")
W = "/tmp/hexe-filmstrip"
subprocess.run(["rm", "-rf", W])
for d in (W + "/run/hexe", W + "/cfg/hexe"):
    os.makedirs(d, exist_ok=True)

# A painter that answers every request with the same three-frame cycle and
# keeps a tally on disk, so the test can count fetches from outside.
TALLY = W + "/fetches"
open(W + "/painter.py", "w").write(f'''
import sys, struct, json
tally = 0
while True:
    head = sys.stdin.buffer.read(4)
    if len(head) < 4: break
    n = struct.unpack(">I", head)[0]
    sys.stdin.buffer.read(n)
    tally += 1
    open({TALLY!r}, "w").write(str(tally))
    # Every cell differs between frames: the renderer diffs, so a frame that
    # changed one character would be emitted as that character alone and the
    # test could not tell it from no repaint at all.
    frames = [{{"mode": "run", "runs": [{{"text": c * 6}}],
               "width": 6, "next_frame_ms": 120}} for c in "XYZ"]
    body = json.dumps({{"ok": True, "output": {{"frames": frames}}, "version": 1}}).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
    sys.stdout.buffer.flush()
''')

REFRESH = 1000
open(W + "/cfg/hexe/init.lua", "w").write(f"""
local hexe = require("hexe")
hexe.status = {{
  enabled = true, refresh_ms = {REFRESH},
  exec = "{sys.executable} {W}/painter.py",
  zones = {{ left = {{ view = "status.left" }} }},
}}
""")

e = dict(os.environ)
e.update({"HEXE_INSTANCE": "filmstrip", "XDG_RUNTIME_DIR": W + "/run", "XDG_CONFIG_HOME": W + "/cfg",
          "XDG_STATE_HOME": W + "/state", "XDG_DATA_HOME": W + "/data", "TERM": "xterm-256color",
          "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
for k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET", "HEXE_API_SOCKET",
          "HEXE_PAINTER_SOCKET", "HEXE_FLOAT", "HEXE_ENV_FD", "HEXE_BIN"):
    e.pop(k, None)

m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
p = subprocess.Popen([H, "mux", "new", "-n", "film"], stdin=s, stdout=s, stderr=s, env=e, cwd=W,
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

RUN_S = 8
time.sleep(RUN_S)
txt = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '', buf.decode('utf8', 'replace'))
fetches = int(open(TALLY).read()) if os.path.exists(TALLY) else 0

p.terminate()
try:
    p.wait(timeout=8)
except Exception:
    p.kill()
    p.wait(timeout=5)

seen = [c for c in "XYZ" if c * 6 in txt]
print(f"frames seen on screen: {seen}")
print(f"fetches in {RUN_S}s: {fetches}")

fail = []
# Every frame of the cycle must reach the screen: that is the strip playing
# locally, since the painter never sends one frame at a time.
if len(seen) < 3:
    fail.append(f"only {seen} of the 3-frame cycle painted; the strip did not play")
# 8s at one fetch per 1000ms is ~8, plus a first paint and any resize. A
# per-frame painter would be asked ~66 times (8s / 120ms).
if fetches > 20:
    fail.append(f"{fetches} fetches in {RUN_S}s -- asking per frame, not per refresh")
if fetches == 0:
    fail.append("the painter was never asked at all")

if fail:
    for f in fail:
        print("FAIL:", f)
    raise SystemExit(1)
print("PASS: one fetch per refresh, every frame drawn locally")
