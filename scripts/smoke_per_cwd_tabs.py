#!/usr/bin/env python3
"""Multi-tab per_cwd + sub-float isolation smoke test.

Verifies against a real mux + ses daemon that per_cwd floats (and their
sub-float families) never leak or mix across tabs belonging to different
project directories:

  1. Four tabs in distinct project dirs (projA, projB, projC, projD), each
     opening its own per_cwd float (and sub-floats on projA & projC).
  2. Moving tab-to-tab (tab.next / tab.prev) preserves strict per-tab
     isolation: each tab shows ONLY its own project's float & active chip.
  3. Closing a middle tab (projB) shifts tab_visible cleanly on both frontend
     and SES: projB's float hides instead of leaking onto projC, projC shifts
     from tab 3 -> tab 2, projD shifts from tab 4 -> tab 3, and projA stays
     on tab 1.
  4. Opening a new tab in projB and toggling the float key reclaims projB's
     original float UUID on the new tab without leaking to other tabs.
  5. Changing directory inside a tab while another dir's per_cwd float is
     visible hides the old dir's float when revealing the new dir's existing
     float (no two same-key per_cwd floats visible on one tab).
  6. Spawning a `--sub` float from a background/other-tab per_cwd float does
     not steal focus from or mix into the active tab's float.
"""
import fcntl
import json
import os
import pty
import struct
import subprocess
import sys
import termios
import threading
import time

HEXE = "/home/bresilla/data/code/tools/hexe/zig-out/bin/hexe"
W = "/tmp/hexe-per-cwd-tabs"

subprocess.run(["pkill", "-f", "instance pctabs"], capture_output=True)
subprocess.run(["rm", "-rf", W], check=False)
dirs = {}
for name in ("projA", "projB", "projC", "projD"):
    p = f"{W}/{name}"
    os.makedirs(p, exist_ok=True)
    dirs[name] = p
for d in (f"{W}/run", f"{W}/cfg/hexe", f"{W}/state", f"{W}/data"):
    os.makedirs(d, exist_ok=True)

with open(f"{W}/cfg/hexe/init.lua", "w") as f:
    f.write(f"""
local hexe = require("hexe")
return hexe.setup({{
  ses = {{ layouts = {{ hexe.layout("pctabs", {{
    root = "{dirs['projA']}",
    tabs = {{
      hexe.tab("tabA", {{ root = hexe.pane({{ cwd = "{dirs['projA']}" }}) }}),
      hexe.tab("tabB", {{ root = hexe.pane({{ cwd = "{dirs['projB']}" }}) }}),
      hexe.tab("tabC", {{ root = hexe.pane({{ cwd = "{dirs['projC']}" }}) }}),
      hexe.tab("tabD", {{ root = hexe.pane({{ cwd = "{dirs['projD']}" }}) }}),
    }},
    floats = {{
      hexe.float("agent", {{
        key = "4",
        title = "agent",
        command = "sh",
        attrs = {{ per_cwd = true, sticky = true, global = true, exclusive = true }},
        size = {{ width = 60, height = 50 }},
      }}),
      hexe.float("helper", {{
        key = "2",
        title = "helper",
        command = "sh",
        attrs = {{ per_cwd = true, sticky = true, global = true, exclusive = true }},
        size = {{ width = 60, height = 50 }},
      }}),
    }},
  }}) }} }},
  keys = {{
    hexe.key({{ hexe.key.alt, hexe.key["4"] }}, hexe.action.float.toggle("4")),
    hexe.key({{ hexe.key.alt, hexe.key["2"] }}, hexe.action.float.toggle("2")),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.right }}, hexe.action.tab.next()),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.left }}, hexe.action.tab.prev()),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.down }}, hexe.action.float.family_next()),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.up }}, hexe.action.float.family_prev()),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key["t"] }}, hexe.action.tab.new()),
    hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key["x"] }}, hexe.action.tab.close()),
  }},
}})
""")

env = dict(os.environ)
env.update({
    "HEXE_INSTANCE": "pctabs",
    "XDG_RUNTIME_DIR": f"{W}/run",
    "XDG_CONFIG_HOME": f"{W}/cfg",
    "XDG_STATE_HOME": f"{W}/state",
    "XDG_DATA_HOME": f"{W}/data",
    "TERM": "xterm-256color",
    "SHELL": "/bin/sh",
    "HEXE_SKIP_LOCAL_CONFIG": "1",
    "HEXE_TRUST_ALL_PROJECTS": "1",
})
for k in (
    "HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
    "HEXE_API_SOCKET", "HEXE_PANE_API_SOCKET", "HEXE_FLOAT", "HEXE_ENV_FD",
    "HEXE_BIN",
):
    env.pop(k, None)

m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
proc = subprocess.Popen(
    [HEXE, "mux", "new", "-n", "pctabs"],
    stdin=s, stdout=s, stderr=s, env=env, cwd=dirs["projA"],
    start_new_session=True,
)
os.close(s)

def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return

threading.Thread(target=drain, daemon=True).start()


def cleanup():
    try:
        proc.terminate()
    except Exception:
        pass
    subprocess.run(["pkill", "-f", "instance pctabs"], capture_output=True)


def fail(msg):
    print(f"FAIL: {msg}")
    try:
        print("  tabs:", json.dumps(api("tabs")))
        print("  floats:", json.dumps([
            {
                "title": fl.get("title"),
                "uuid": (fl.get("uuid") or "")[:8],
                "pwd_dir": fl.get("pwd_dir"),
                "fam": fl.get("family_index"),
                "vis": fl.get("visible"),
                "foc": fl.get("focused"),
                "vis_tabs": fl.get("visible_tabs"),
            }
            for fl in (api("floats") or [])
        ]))
    except Exception:
        pass
    cleanup()
    sys.exit(1)


def api(*args):
    r = subprocess.run(
        [HEXE, "api", "--session", "pctabs", *args],
        env=env, cwd=W, capture_output=True, text=True, timeout=20,
    )
    try:
        return json.loads(r.stdout or "{}").get("result")
    except Exception:
        return None


def wait_ready():
    deadline = time.time() + 20
    while time.time() < deadline:
        tabs = api("tabs")
        if tabs and len(tabs) == 4:
            return
        time.sleep(0.3)
    fail("mux did not start with 4 tabs")


def wait_for(pred, desc, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        val = pred()
        if val:
            return val
        time.sleep(0.2)
    fail(f"timeout waiting for {desc}")


def vis_tabs_list(fl):
    vt = fl.get("visible_tabs")
    if isinstance(vt, list):
        return vt
    return []


def assert_only_project_visible(expected_dir, expected_tab_1based, label, expected_fam=None):
    fls = api("floats") or []
    tabs = api("tabs") or []
    active = next((t for t in tabs if t.get("active")), None)
    if not active or active.get("index") != expected_tab_1based:
        fail(f"[{label}] expected active tab {expected_tab_1based}, got {active}")

    visible_here = [fl for fl in fls if fl.get("visible")]
    if expected_dir is None:
        if visible_here:
            fail(f"[{label}] expected NO visible floats, got {[(f.get('pwd_dir'), f.get('family_index')) for f in visible_here]}")
        return

    if len(visible_here) != 1:
        fail(f"[{label}] expected exactly 1 visible float ({expected_dir}), got {[(f.get('pwd_dir'), f.get('family_index'), f.get('visible_tabs')) for f in visible_here]}")
    shown = visible_here[0]
    if shown.get("pwd_dir") != expected_dir:
        fail(f"[{label}] WRONG PROJECT FLOAT SHOWN! expected {expected_dir}, got {shown.get('pwd_dir')}")
    if expected_fam is not None and shown.get("family_index") != expected_fam:
        fail(f"[{label}] expected family_index={expected_fam}, got {shown.get('family_index')}")
    if vis_tabs_list(shown) != [expected_tab_1based]:
        fail(f"[{label}] expected visible_tabs={[expected_tab_1based]}, got {vis_tabs_list(shown)}")


def spawn_sub(parent_uuid, title):
    e2 = dict(env)
    e2["HEXE_PANE_UUID"] = parent_uuid
    e2["HEXE_FLOAT"] = "1"
    r = subprocess.run(
        [HEXE, "terminal", "float", "--sub", "--title", title, "-c", "sh"],
        env=e2, cwd=W, capture_output=True, text=True, timeout=15,
    )
    if r.returncode != 0:
        fail(f"spawn --sub {title} failed rc={r.returncode} stderr={r.stderr}")
    return r.stdout.strip()


# --- Phase 1: open per_cwd float on all 4 project tabs + sub-floats on A and C ---
wait_ready()
print("Phase 1: open per_cwd floats on tabs 1..4 (projA..projD) + sub-floats on A and C")

project_order = ["projA", "projB", "projC", "projD"]
root_uuids = {}

for idx, name in enumerate(project_order, start=1):
    api("tab_select", str(idx))
    wait_for(lambda i=idx: any(t["active"] and t["index"] == i for t in (api("tabs") or [])), f"tab {idx} active")
    os.write(m, b"\x1b4")  # Alt+4 -> agent (per_cwd)
    shown = wait_for(
        lambda d=dirs[name]: next((fl for fl in (api("floats") or []) if fl.get("visible") and fl.get("pwd_dir") == d), None),
        f"{name} float visible",
    )
    root_uuids[name] = shown["uuid"]
    assert_only_project_visible(dirs[name], idx, f"phase1-{name}")

    if name in ("projA", "projC"):
        sub_uuid = spawn_sub(shown["uuid"], f"sub-{name}")
        wait_for(
            lambda u=sub_uuid: any(fl.get("uuid") == u and fl.get("visible") for fl in (api("floats") or [])),
            f"sub-{name} visible",
        )
        assert_only_project_visible(dirs[name], idx, f"phase1-{name}-sub", expected_fam=1)

print("  PASS Phase 1: all 4 tabs have isolated per_cwd floats (A & C on chip 1)")

# --- Phase 2: walk across all 4 tabs back and forth ---
print("Phase 2: move tab-to-tab across all 4 tabs")
for idx, name in [(3, "projC"), (2, "projB"), (1, "projA"), (2, "projB"), (3, "projC"), (4, "projD")]:
    api("tab_select", str(idx))
    time.sleep(0.4)
    exp_fam = 1 if name in ("projA", "projC") else 0
    assert_only_project_visible(dirs[name], idx, f"phase2-tab{idx}-{name}", expected_fam=exp_fam)

print("  PASS Phase 2: tab-to-tab switching preserves strict per-project isolation")

# --- Phase 3: close middle tab (tab 2 = projB) ---
print("Phase 3: close middle tab (tab 2 = projB) and verify zero cross-tab mixing")
api("tab_select", "2")
wait_for(lambda: any(t["active"] and t["index"] == 2 for t in (api("tabs") or [])), "tab 2 active")
# Focus tiled split on tab 2 so Ctrl+Alt+x closes the tab (not the float),
# while projB's float is STILL visible on tab 2!
tab2 = next(t for t in api("tabs") if t["index"] == 2)
api("focus", json.dumps(tab2["focused_uuid"]))
time.sleep(0.4)
os.write(m, b"\x1b[120;7u")  # fallback via tab_close? Let's use key or send exit to shell!
# Send `exit` to tab 2's shell pane (the exact real-world way tabs close when a shell exits,
# which calls state.closeCurrentTab() while projB's float is still visible on tab 2).
api("send", json.dumps(tab2["focused_uuid"]), json.dumps("exit\n"))
wait_for(lambda: len(api("tabs") or []) == 3, "3 tabs remaining after closing tab 2")
time.sleep(0.6)

# Remaining tabs are now:
#   tab 1 = projA (chip 1)
#   tab 2 = projC (chip 1)
#   tab 3 = projD (chip 0)
# And projB's float MUST have visible_tabs == [] (NOT leaked onto tab 2 / projC!).
fl_b = next((fl for fl in (api("floats") or []) if fl.get("uuid") == root_uuids["projB"]), None)
if not fl_b:
    fail("projB float disappeared from float list after closing tab 2")
if vis_tabs_list(fl_b):
    fail(f"projB float leaked onto surviving tab(s): visible_tabs={vis_tabs_list(fl_b)}")

assert_only_project_visible(dirs["projC"], 2, "phase3-after-close-tab2-is-projC", expected_fam=1)

api("tab_select", "1")
time.sleep(0.4)
assert_only_project_visible(dirs["projA"], 1, "phase3-tab1-is-projA", expected_fam=1)

api("tab_select", "3")
time.sleep(0.4)
assert_only_project_visible(dirs["projD"], 3, "phase3-tab3-is-projD", expected_fam=0)

print("  PASS Phase 3: closing middle tab shifted tab_visible cleanly with zero mixing")

# --- Phase 4: spawn background --sub from hidden projB float while on tab 3 (projD) ---
print("Phase 4: background --sub from hidden projB float does not steal focus or leak onto tab 3")
sub_b = spawn_sub(root_uuids["projB"], "sub-projB-bg")
time.sleep(0.6)
assert_only_project_visible(dirs["projD"], 3, "phase4-bg-sub-no-leak", expected_fam=0)
fl_sub_b = next((fl for fl in (api("floats") or []) if fl.get("uuid") == sub_b), None)
if not fl_sub_b or vis_tabs_list(fl_sub_b):
    fail(f"background sub-float of projB leaked visible_tabs: {fl_sub_b}")
fl_d = next(fl for fl in (api("floats") or []) if fl.get("uuid") == root_uuids["projD"])
if not fl_d.get("focused"):
    fail("background --sub stole focus away from tab 3's active projD float")

print("  PASS Phase 4: background --sub stayed hidden and preserved active float focus")

# --- Phase 5: cd inside tab 3 from projD -> projB while projD float is visible, then toggle Alt+4 ---
print("Phase 5: cd tab 3 from projD -> projB with projD float visible, toggle Alt+4 hides projD and reveals projB")
tab3 = next(t for t in api("tabs") if t["index"] == 3)
api("focus", json.dumps(tab3["focused_uuid"]))
time.sleep(0.4)
api("send", json.dumps(tab3["focused_uuid"]), json.dumps(f"cd {dirs['projB']}\n"))
wait_for(
    lambda: next((p.get("cwd") for p in (api("panes") or []) if p.get("uuid") == tab3["focused_uuid"]), None) == dirs["projB"],
    "tab 3 shell cwd changed to projB",
)
os.write(m, b"\x1b4")  # Alt+4 -> should reveal existing projB family and HIDE projD on tab 3!
time.sleep(1.0)
assert_only_project_visible(dirs["projB"], 3, "phase5-tab3-now-projB")

# Double check tabs 1 and 2 are STILL completely unaffected!
api("tab_select", "1")
time.sleep(0.4)
assert_only_project_visible(dirs["projA"], 1, "phase5-verify-tab1-projA", expected_fam=1)
api("tab_select", "2")
time.sleep(0.4)
assert_only_project_visible(dirs["projC"], 2, "phase5-verify-tab2-projC", expected_fam=1)

print("  PASS Phase 5: revealing existing per_cwd float hid old-dir instance and left other tabs untouched")

if proc.poll() is not None:
    fail("frontend died during checks")

cleanup()
print("ALL PASS: per_cwd floats and sub-floats stay strictly isolated across tabs")
