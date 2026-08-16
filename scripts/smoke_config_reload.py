#!/usr/bin/env python3
"""Live check: `config.reload` picks up edited LAYOUT/float definitions.

`performConfigReload` swapped `Config` but left `ses_config` and the resolved
`active_layout_floats` untouched, so editing a float and reloading appeared to
do nothing — the old definitions stayed live for the rest of the session (and
the previous resolution leaked).

The float definition is read back through `ctx.config().floats`, which is the
only way to observe the resolved set from outside.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
CFGDIR = os.path.join(SCRATCH, f"cfgreload{os.getpid()}")
os.makedirs(os.path.join(CFGDIR, "hexe"), exist_ok=True)
MARKER = os.path.join(SCRATCH, f"reload{os.getpid()}.txt")
LAYOUT = os.path.join(CFGDIR, "hexe", "layout.lua")

open(LAYOUT, "w").write("""
local hexe = require("hexe")
return hexe.layout("default", {
  enabled = true,
  tabs = { hexe.tab("main", { root = hexe.pane({ cwd = "." }) }) },
  floats = { hexe.float("probe", { key = "1", enabled = true, command = "BEFORE_RELOAD" }) },
})
""")

open(os.path.join(CFGDIR, "hexe", "init.lua"), "w").write(f"""
local hexe = require("hexe")
local layout = dofile("{LAYOUT}")
return hexe.setup({{
  ses = {{ layouts = {{ layout }} }},
  keys = {{
    hexe.key({{ hexe.key.ctrl, hexe.key.t }}, function(ctx)
      local fl = ctx.config().floats
      local s = "floats=" .. #fl
      for _, f in ipairs(fl) do s = s .. " cmd=" .. tostring(f.command) end
      local h = io.open("{MARKER}", "a"); h:write(s .. "\\n"); h:close()
    end),
    hexe.key({{ hexe.key.ctrl, hexe.key.r }}, hexe.action.config.reload()),
  }},
}})
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
            "XDG_CONFIG_HOME": CFGDIR, "TERM": "xterm-256color", "SHELL": "/bin/sh"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)
procs = []


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    r = subprocess.run(["pgrep", "-f", f"daemon --instance {INST}"], capture_output=True, text=True)
    if r.returncode == 0:
        for pid in r.stdout.split():
            try: os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError): pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


def lines():
    try:
        return [l for l in open(MARKER).read().splitlines() if l.strip()]
    except OSError:
        return []


def wait_lines(n, timeout_s=15):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if len(lines()) >= n:
            return True
        time.sleep(0.3)
    return False


master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "reload"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=SCRATCH, start_new_session=True)
os.close(slave); procs.append(fe)
time.sleep(3.5)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

os.write(master, b"\x14")  # ctrl+t: read the configured floats
if not wait_lines(1):
    fail("could not read ctx.config().floats before the reload")
before = lines()[0]
if "cmd=BEFORE_RELOAD" not in before:
    fail(f"the configured float did not reach ctx.config(): {before!r}")

# Edit the layout on disk, then reload from inside the running frontend.
txt = open(LAYOUT).read()
open(LAYOUT, "w").write(txt.replace("BEFORE_RELOAD", "AFTER_RELOAD"))

os.write(master, b"\x12")  # ctrl+r: config.reload
time.sleep(3.0)
os.write(master, b"\x14")  # ctrl+t: read them again
if not wait_lines(2):
    fail("no second read after the reload")
after = lines()[1]

if fe.poll() is not None:
    fail("frontend died during config reload")
if "cmd=AFTER_RELOAD" not in after:
    fail(f"reload did not pick up the edited float definition: {after!r} "
         f"(ses_config / active_layout_floats were not refreshed)")

print(f"before reload: {before}")
print(f"after reload:  {after}")
cleanup()
print("SMOKE PASS: config.reload refreshes layout and float definitions")
