#!/usr/bin/env python3
"""`navigatable`: a float that joins directional navigation instead of skipping it.

By default a float is skipped by focus.move -- it has a dedicated toggle key, so
left/right switches tabs and up/down does nothing. A float that declares
`navigatable = true` takes part in the split navigation instead: focus moves to
whatever is actually beside it, and only falls back to a tab switch at the edge,
exactly as it would from a tiled pane.

The attribute existed, was parsed, validated, merged, copied onto the pane and
reported over the API, and did nothing at all. Two things were in the way:

  * `focus_move.perform` returned early for EVERY float, before the navigation
    it would otherwise have reached;
  * `recyclePaneForFloat` re-wrote the float's UI record on every session-state
    sync from a `PaneFloatUiConfig` that does not carry `navigatable`, so the
    field was filled from its default and cleared moments after being set.

The second is why this needs a live mux rather than a unit test: nothing is
wrong at creation, and only a later sync undoes it.
"""
import os, pty, subprocess, time, fcntl, termios, struct, threading, json
H="/home/bresilla/data/code/tools/hexe/zig-out/bin/hexe"
W="/tmp/hexe-nav"; subprocess.run(["rm","-rf",W])
for d in (W+"/run", W+"/cfg/hexe"): os.makedirs(d, exist_ok=True)
open(W+"/cfg/hexe/init.lua","w").write(f"""
local hexe = require("hexe")
return hexe.setup({{
  ses = {{ layouts = {{ hexe.layout("navlay", {{
    root = "{W}",
    tabs = {{ hexe.tab("one", {{ root = hexe.pane() }}), hexe.tab("two", {{ root = hexe.pane() }}) }},
    floats = {{
      hexe.float("nav",   {{ key = "n", title = "nav",   command = "sleep 600",
                           attrs = {{ navigatable = true,  global = true }},
                           size = {{ width = 25, height = 40 }}, position = {{ x = 85, y = 50 }} }}),
      hexe.float("plain", {{ key = "m", title = "plain", command = "sleep 600",
                           attrs = {{ navigatable = false, global = true }},
                           size = {{ width = 25, height = 40 }}, position = {{ x = 85, y = 50 }} }}),
    }},
  }}) }} }},
  keys = {{
    hexe.key({{ hexe.key.alt, hexe.key['n'] }}, hexe.action.float.toggle('n')),
    hexe.key({{ hexe.key.alt, hexe.key['m'] }}, hexe.action.float.toggle('m')),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.left }}, hexe.action.focus.move('left')),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.right }}, hexe.action.focus.move('right')),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.up }}, hexe.action.focus.move('up')),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.down }}, hexe.action.focus.move('down')),
  }},
}})
""")
e=dict(os.environ); e.update({"HEXE_INSTANCE":"nav","XDG_RUNTIME_DIR":W+"/run","XDG_CONFIG_HOME":W+"/cfg",
 "XDG_STATE_HOME":W+"/state","XDG_DATA_HOME":W+"/data","TERM":"xterm-256color","SHELL":"/bin/sh",
 "HEXE_SKIP_LOCAL_CONFIG":"1","HEXE_TRUST_ALL_PROJECTS":"1"})
for k in ("HEXE_SESSION","HEXE_PANE_UUID","HEXE_MUX_SOCKET","HEXE_POD_SOCKET","HEXE_API_SOCKET","HEXE_PANE_API_SOCKET","HEXE_FLOAT","HEXE_ENV_FD","HEXE_BIN"): e.pop(k,None)
m,s=pty.openpty(); fcntl.ioctl(s,termios.TIOCSWINSZ,struct.pack("HHHH",40,140,0,0))
p=subprocess.Popen([H,"mux","new","-n","nav","--logfile","/tmp/hexe-nav.log"],stdin=s,stdout=s,stderr=s,env=e,cwd=W,start_new_session=True); os.close(s)
def dr():
    while True:
        try:
            if not os.read(m,65536): return
        except OSError: return
threading.Thread(target=dr,daemon=True).start(); time.sleep(8)
def api(*a):
    r=subprocess.run([H,"api","--session","nav",*a],env=e,cwd=W,capture_output=True,text=True,timeout=20)
    try: return json.loads(r.stdout or "{}").get("result")
    except: return None
results = {}


def state():
    f=api("pane") or {}; s=api("session") or {}
    return (f.get("name"), f.get("is_float"), s.get("active_tab"))
cfg = api("config") or {}
binds = (cfg.get("input") or {}).get("binds") or cfg.get("binds") or []
print("binds in config:", len(binds) if isinstance(binds,list) else binds)
for b in (binds if isinstance(binds,list) else [])[:12]:
    print("   ", b)
api("tab_select", "2"); time.sleep(1)
api("act", '{"type":"split.h"}'); time.sleep(2)
print("tab 2 panes:", [(p.get("name"), p.get("x"), p.get("width")) for p in (api("panes") or []) if not p.get("is_float")])
for key, label in ((b"\x1bn","navigatable=true"), (b"\x1bm","navigatable=false")):
    api("tab_select", "2"); time.sleep(1)
    os.write(m, key); time.sleep(2.5)
    before = state()
    print(f"    tabs={[ (t.get('index'), t.get('active')) for t in (api('tabs') or []) ]} floats={len(api('floats') or [])}")
    os.write(m, b"\x1b[1;7D")   # ctrl+alt+Left, as a real terminal sends it
    print("    sent CSI 1;7D (ctrl+alt+left)")
    time.sleep(2)
    after = state()
    print(f"  {label:18s} from float={before} -> {after}")
    results[label] = (before, after)
    os.write(m, key); time.sleep(1.5)
p.terminate()

import sys
def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)

nb, na = results["navigatable=true"]
if na[1] is not False:
    fail(f"a navigatable float did not hand focus to a split: {nb} -> {na}")
if na[2] != nb[2]:
    fail(f"a navigatable float switched tabs instead of moving to the split beside it: "
         f"{nb} -> {na} — the neighbour was there, so this is the tab-edge fallback firing early")

pb, pa = results["navigatable=false"]
if pa[2] == pb[2]:
    fail(f"a plain float stopped switching tabs: {pb} -> {pa} — the default must not change")

print("PASS: a navigatable float navigates to its neighbour; a plain one still switches tabs")
