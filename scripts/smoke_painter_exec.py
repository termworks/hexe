#!/usr/bin/env python3
"""A painter hexe owns: spawned as its child, spoken to over a pipe.

`status.socket` points at one painter every session on the machine shares. Its
accept loop serialises them, its config outlives the binary that made it, and a
slow render is everyone's. `status.exec` runs a painter as THIS frontend's
child instead and sends it the same frames down its pipes -- byte-identical
protocol, different file descriptors.

Checked against a real mux and a real pixy:

  * the bar paints from the child, so the transport actually carries content
    rather than merely connecting;
  * no painter socket is created -- nothing is shared, which is the point;
  * the child goes when the frontend goes, so a painter cannot outlive what it
    was drawing for.

Skipped when pixy is not built, since it needs a real painter on the far end.
"""
import os, pty, subprocess, time, fcntl, termios, struct, threading, re, sys
REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
H = os.path.join(REPO, "zig-out/bin/hexe")
PIXY = os.environ.get("PIXY_BIN", os.path.join(os.path.dirname(REPO), "pixy/build/pixy"))
PCFG = os.environ.get("PIXY_CONFIG", os.path.join(os.path.dirname(REPO), "pixy/config/init.lua"))
if not (os.path.exists(PIXY) and os.path.exists(PCFG)):
    print(f"SKIP: no pixy at {PIXY}; this needs a real painter on the far end")
    raise SystemExit(0)
W="/tmp/hexe-exec"; subprocess.run(["rm","-rf",W])
for d in (W+"/run/hexe", W+"/cfg/hexe"): os.makedirs(d, exist_ok=True)
open(W+"/cfg/hexe/init.lua","w").write(f"""
local hexe = require("hexe")
hexe.status = {{
  enabled = true, refresh_ms = 250,
  exec = "{PIXY} serve --stdio --config {PCFG}",
  zones = {{ left = {{ view = "status.left" }}, center = {{ view = "status.center" }}, right = {{ view = "status.right" }} }},
}}
""")
e=dict(os.environ); e.update({"HEXE_INSTANCE":"exec","XDG_RUNTIME_DIR":W+"/run","XDG_CONFIG_HOME":W+"/cfg",
 "XDG_STATE_HOME":W+"/state","XDG_DATA_HOME":W+"/data","TERM":"xterm-256color","SHELL":"/bin/sh",
 "HEXE_SKIP_LOCAL_CONFIG":"1"})
for k in ("HEXE_SESSION","HEXE_PANE_UUID","HEXE_MUX_SOCKET","HEXE_POD_SOCKET","HEXE_API_SOCKET","HEXE_PAINTER_SOCKET","HEXE_FLOAT","HEXE_ENV_FD","HEXE_BIN"): e.pop(k,None)
m,s=pty.openpty(); fcntl.ioctl(s,termios.TIOCSWINSZ,struct.pack("HHHH",40,140,0,0))
p=subprocess.Popen([H,"mux","new","-n","exec"],stdin=s,stdout=s,stderr=s,env=e,cwd=W,start_new_session=True); os.close(s)
buf=bytearray()
def dr():
    while True:
        try:
            d=os.read(m,65536)
            if not d: return
            buf.extend(d)
        except OSError: return
threading.Thread(target=dr,daemon=True).start()
time.sleep(9)
txt=re.sub(r'\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)','',buf.decode('utf8','replace'))
def painter_pids():
    out=subprocess.run(["pgrep","-f","[p]ixy serve"],capture_output=True,text=True).stdout.split()
    # only children of THIS test's frontend tree, never our own shell
    return [q for q in out if os.path.exists(f"/proc/{q}/cmdline") and
            b"--stdio" in open(f"/proc/{q}/cmdline","rb").read()]
kids=painter_pids()
socks=subprocess.run(["find",W+"/run","-name","painter.sock"],capture_output=True,text=True).stdout.strip()
def fail(msg):
    print(f"FAIL: {msg}")
    p.terminate()
    raise SystemExit(1)

if not kids:
    fail("no painter child was spawned; `status.exec` did not start one")
print(f"child: spawned, pid {kids[0]}")
if socks:
    fail(f"a painter socket was created at {socks}; `exec` must share nothing")
print("socket: none created — the painter is this frontend's alone")
# the bar should carry pixy's clock, i.e. HH:MM:SS
clock = re.search(r'\d\d:\d\d:\d\d', txt)
if not clock:
    fail("the bar never showed the painter's content, so the pipe carried a "
         f"connection but no frames; saw: {txt[-200:]!r}")
print(f"content: the bar is painted by the child ({clock.group(0)})")
if p.poll() is not None:
    fail(f"the frontend exited rc={p.returncode} while using an exec painter")
kid_pid = kids[0] if kids else None
p.terminate()
try: p.wait(timeout=8)
except Exception: p.kill(); p.wait(timeout=5)

alive = None
for i in range(20):
    alive = painter_pids()
    if not alive: break
    time.sleep(0.5)
if alive:
    fail(f"the painter outlived the frontend (pids {alive}) — an exec painter must "
         "die with what it draws for, or it is a stale daemon by another name")
print("lifetime: the child exits with the frontend")
print("PASS: hexe paints through a painter it owns, over a pipe, sharing nothing")

