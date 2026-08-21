#!/usr/bin/env python3
"""`float.show` / `float.hide` state a destination; `float.toggle` flips.

Idempotence is the whole point, so it is checked by running the same bind twice
and requiring the second run to change nothing. On its own that proves little —
a mux that had stopped responding would pass it — so a blind toggle runs in
between: it must flip both floats, and show/hide must then drive them back.
Together those say show/hide act, and act only when there is something to do.

`show` is also required to OPEN a float that was never opened, not merely to
reveal a hidden one; otherwise "make sure this is up" fails exactly on first use.

Driven through a compound keybinding — a Lua function calling `ctx.act` in a
loop — because that is where a regression would actually bite.

Also pins `name` and `key_name` on `ctx.config().floats`: the declared float's
`key` is a character code, and a config forced to address floats by that number
instead of the name it wrote is a trap the API should not set.
"""
import atexit, fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"floatstate{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
INST = f"smk{os.getpid()}"
REPORT = os.path.join(WD, "report")

LUA = r"""
local hexe = require("hexe")

-- Put every float where its per_cwd attribute says it belongs. Stated, not
-- flipped, so running it again is a no-op.
local function arrange(ctx)
  for _, d in ipairs(ctx.config().floats) do
    if d.per_cwd then ctx.act(hexe.action.float.hide(d.key_name))
    else ctx.act(hexe.action.float.show(d.key_name)) end
  end
end

-- Flip every float, whatever it is doing. The contrast that matters: this
-- moves state on every run, so a `show`/`hide` that appears to do nothing can
-- be told apart from a mux that has stopped responding.
local function flip(ctx)
  for _, d in ipairs(ctx.config().floats) do
    ctx.act(hexe.action.float.toggle(d.key_name))
  end
end

local function report(ctx)
  local out = {}
  for _, d in ipairs(ctx.config().floats) do
    out[#out+1] = string.format("declared name=%s key_name=%s per_cwd=%s",
                                tostring(d.name), tostring(d.key_name), tostring(d.per_cwd))
  end
  for _, f in ipairs(ctx.floats()) do
    out[#out+1] = string.format("live key=%s per_cwd=%s visible=%s",
                                tostring(f.float_key), tostring(f.per_cwd), tostring(f.visible))
  end
  ctx.exec("cat > __REPORT__ <<'EOF'\n" .. table.concat(out, "\n") .. "\nEOF")
end

return hexe.setup({
  ses = { layouts = { hexe.layout("fslay", {
    root = "__WD__",
    tabs = { hexe.tab("main", { root = hexe.pane() }) },
    floats = {
      hexe.float("percwd", { key = "p", title = "percwd", command = "sleep 600",
                             attrs = { per_cwd = true } }),
      hexe.float("plain",  { key = "o", title = "plain",  command = "sleep 600" }),
    },
  }) } },
  keys = {
    hexe.key({ hexe.key.alt, hexe.key['p'] }, hexe.action.float.toggle('p')),
    hexe.key({ hexe.key.alt, hexe.key['a'] }, arrange),
    hexe.key({ hexe.key.alt, hexe.key['t'] }, flip),
    hexe.key({ hexe.key.alt, hexe.key['r'] }, report),
  },
})
"""
open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    LUA.replace("__REPORT__", REPORT).replace("__WD__", WD))

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_CONFIG_HOME": CF, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1", "HEXE_TRUST_ALL_PROJECTS": "1"})
for k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
          "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET"):
    env.pop(k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    r = subprocess.run(["pgrep", "-f", f"instance {INST}"], capture_output=True, text=True)
    if r.returncode == 0:
        for pid in r.stdout.split():
            try: os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError): pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "fs"], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


threading.Thread(target=drain, daemon=True).start()
time.sleep(5.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")


def press(seq, settle=3.0):
    os.write(m, seq)
    time.sleep(settle)


def snapshot(tag):
    if os.path.exists(REPORT):
        os.unlink(REPORT)
    press(b"\x1br", 1.0)
    deadline = time.time() + 15
    while time.time() < deadline and not os.path.exists(REPORT):
        time.sleep(0.3)
    if not os.path.exists(REPORT):
        fail(f"the report bind never ran ({tag})")
    time.sleep(0.3)
    lines = open(REPORT).read().strip().splitlines()
    vis = {}
    declared = {}
    for ln in lines:
        if ln.startswith("live key="):
            parts = dict(p.split("=", 1) for p in ln[len("live "):].split())
            vis[int(parts["key"])] = parts["visible"] == "true"
        elif ln.startswith("declared "):
            parts = dict(p.split("=", 1) for p in ln[len("declared "):].split())
            declared[parts["name"]] = parts
    return vis, declared


PERCWD, PLAIN = ord("p"), ord("o")

# The declared list must name its floats, not just number them.
_, declared = snapshot("initial")
if set(declared) != {"percwd", "plain"}:
    fail(f"ctx.config().floats did not report the names the config declared: "
         f"got {sorted(declared)}. A script can only address these floats by "
         f"the character code of their key")
for name, d in declared.items():
    if len(d["key_name"]) != 1:
        fail(f"float {name} has key_name={d['key_name']!r}, not a single "
             f"character usable with float.show/float.hide")
print(f"declared: {sorted(declared)} with key_name {[d['key_name'] for d in declared.values()]}")

# Open the per_cwd float, so `arrange` has something to actually hide.
press(b"\x1bp")

# Stated destination, applied twice. The second run must change nothing.
press(b"\x1ba")
first, _ = snapshot("after show/hide")
if first.get(PERCWD, False) is not False:
    fail(f"float.hide left the per_cwd float visible={first.get(PERCWD)}")
if first.get(PLAIN, False) is not True:
    fail(f"float.show did not bring up the non-per_cwd float "
         f"(visible={first.get(PLAIN)}); show must open a float that was never "
         f"opened, not only reveal a hidden one")
print(f"show/hide: per_cwd hidden, plain shown {first}")

press(b"\x1ba")
second, _ = snapshot("after repeat")
if second != first:
    fail(f"running the same show/hide bind again changed the floats: "
         f"{first} -> {second}. show/hide must state a destination, not flip")
print(f"show/hide: unchanged when run again {second}")

# A blind toggle for contrast. Without this, "show/hide changed nothing on the
# second run" is equally consistent with a mux that stopped acting at all.
press(b"\x1bt")
flipped, _ = snapshot("after a blind toggle")
if flipped.get(PERCWD) != True or flipped.get(PLAIN) != False:
    fail(f"a blind float.toggle did not flip both floats ({flipped}); the "
         f"snapshot cannot observe visibility changes, so the idempotency "
         f"check above proves nothing")
print(f"toggle: flips whatever it finds {flipped}")

# And show/hide drives it back, so they act rather than merely decline to.
press(b"\x1ba")
restored, _ = snapshot("after re-arranging")
if restored != first:
    fail(f"show/hide did not restore the stated arrangement after a flip: "
         f"{first} -> {restored}")
print(f"show/hide: drives state back from any starting point {restored}")

if fe.poll() is not None:
    fail("frontend died during the checks")

cleanup()
print("PASS: float.show/float.hide state a destination and floats carry their names")
