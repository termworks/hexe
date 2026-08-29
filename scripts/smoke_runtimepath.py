#!/usr/bin/env python3
"""The runtimepath: a list of roots, each laid out the same way inside.

This is neovim's model, and these are the parts of it that are easy to get
wrong and impossible to notice when they are:

  * `plugin/` runs and `lua/` does not -- a plugin needs somewhere to keep a
    helper that is not executed the moment it is on disk;
  * load order is path order between roots and alphabetical within one, so it
    is the same on every machine rather than whatever the filesystem returns;
  * `after/` really is last, which is what makes it an override seam and not
    just another directory;
  * a package under `pack/*/start/*` is a root like any other, and gets its own
    root as `...` so it can read a file it ships;
  * one plugin raising does not stop the others -- deliberately unlike
    init.lua, where a raise is fatal;
  * nothing is approved, so a plugin runs because somebody put it there;
  * `--noplugin` starts with none of it, which is how you answer "is it me or a
    plugin?"

All of it from a config that never mentions a plugin at all.
"""
import atexit, fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"rtp{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
DATA = os.path.join(WD, "data")
ROOT = os.path.join(CF, "hexe")                              # your own root
PACK = os.path.join(DATA, "hexe", "site", "pack", "t", "start", "greeter")
INST = f"smk{os.getpid()}"
MARK = f"rtpmark{os.getpid()}"
ORDER = os.path.join(WD, "order")
PRESSED = os.path.join(WD, "pressed")
RELEASED = os.path.join(WD, "released")
SHIPPED = os.path.join(WD, "shipped")

for d in (os.path.join(ROOT, "plugin"), os.path.join(ROOT, "lua"),
          os.path.join(ROOT, "after", "plugin"), os.path.join(PACK, "plugin"), RUN):
    os.makedirs(d, exist_ok=True)


def note(path, what):
    """Append to the order file, tagged with how many times THIS plugin has run
    in the Lua state running it.

    hexe builds more than one Lua state per process -- one for the session
    config, one for the mux config -- and each reads the config and its
    plugins, so the file interleaves them. A global is per-state, so a
    per-plugin counter reads 1 every time when each state runs each plugin
    once, and 2 the moment a state loads its plugins twice. That is the failure
    worth catching: it doubles every binding a plugin registered, which looks
    exactly like a handler that fires twice. Counting per plugin rather than
    per load keeps the tag meaningful whatever the order turns out to be."""
    return (f'_G.__n{what} = (_G.__n{what} or 0) + 1\n'
            f'local f = io.open("{path}", "a") '
            f'f:write(_G.__n{what} .. " {what}\\n") f:close()\n')


# ---- your own root ----------------------------------------------------------

# Raises after saying it ran. Named to sort FIRST, so everything after it is
# proof that one bad plugin does not take the rest with it.
open(os.path.join(ROOT, "plugin", "05_raise.lua"), "w").write(
    note(ORDER, "raise") + 'error("deliberate")\n')

# Never required by anything. If `lua/` were auto-run the way `plugin/` is,
# this would appear in the order file -- which is the only way to tell the two
# directories apart, since a module that IS required runs its body either way.
open(os.path.join(ROOT, "lua", "never.lua"), "w").write(note(ORDER, "MUSTNOTRUN"))

# Required by a plugin, and reachable only because every root's `lua/` is on
# the require path.
open(os.path.join(ROOT, "lua", "greetlib.lua"), "w").write(
    f'local M = {{}}\nM.mark = "{MARK}"\nreturn M\n')

open(os.path.join(ROOT, "plugin", "10_first.lua"), "w").write(
    note(ORDER, "first") + f"""
local lib = require("greetlib")
hexe.key({{ hexe.key.ctrl, hexe.key.g }}, function(ctx) ctx.popup(lib.mark) end)
""")

open(os.path.join(ROOT, "plugin", "20_second.lua"), "w").write(note(ORDER, "second"))

# `after/` is last however it sorts: `aa` beats every other name alphabetically
# and still must come after the package, which is several roots later.
open(os.path.join(ROOT, "after", "plugin", "aa.lua"), "w").write(note(ORDER, "after"))

# ---- a package: a root like any other, somewhere else on the path -----------

# A file the package ships beside its `plugin/`. Finding it is the point: a
# package that cannot name its own files has to hardcode an install path.
open(os.path.join(PACK, "greeting.txt"), "w").write(MARK + "\n")
open(os.path.join(PACK, "plugin", "greeter.lua"), "w").write(
    note(ORDER, "pack") + f"""
local root = ...                       -- the root it came from
local f = io.open(root .. "/greeting.txt", "r")
local greeting = f and f:read("*l") or "NO-SHIPPED-FILE"
if f then f:close() end

local w = io.open("{SHIPPED}", "w") w:write(greeting) w:close()

-- Push-to-talk shape: one chord, two moments. Each must fire at its own
-- moment -- a press that waits for the release is a recorder that never
-- records, and a release that never fires is one that never stops.
hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.p }}, function(ctx)
  ctx.exec("touch {PRESSED}")
end, {{ on = hexe.when.press }})
hexe.key({{ hexe.key.ctrl, hexe.key.alt, hexe.key.p }}, function(ctx)
  ctx.exec("touch {RELEASED}")
end, {{ on = hexe.when.release }})
""")

# The user's config names no plugin whatsoever.
open(os.path.join(ROOT, "init.lua"), "w").write("local hexe = require('hexe')\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF, "XDG_DATA_HOME": DATA,
            "HEXE_TRUST_LEDGER": os.path.join(WD, "trust"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_FLOAT", "HEXE_PAINTER_SOCKET", "HEXE_ENV_FD", "HEXE_BIN", "HEXE_API_SOCKET",
           "HEXE_NOPLUGIN"):
    env.pop(_k, None)
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
    sys.stdout.flush()
    cleanup()
    sys.exit(1)


def watchdog(_s, _f):
    print("FAIL: timed out")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(180)


def hexe(*args, **kw):
    return subprocess.run([HEXE, *args], env=kw.get("env", env), cwd=WD,
                          capture_output=True, text=True, timeout=30)


def order():
    """(generation, what) for everything that ran, in the order it ran."""
    try:
        return [tuple(l.split(" ", 1)) for l in open(ORDER).read().split("\n") if l]
    except FileNotFoundError:
        return []


# ---- the path is a path, and it says what it would run ----------------------

r = hexe("plugin", "list")
if os.path.join(ROOT, "after") not in r.stdout:
    fail(f"the after root is not on the path: {r.stdout!r}")
listed = [l.split(". ", 1)[1].strip() for l in r.stdout.split("\n") if ". " in l and l.strip()[0].isdigit()]
if not listed:
    fail(f"`plugin list` found nothing to run: {r.stdout!r}")
if any("greetlib" in p for p in listed):
    fail("a file under `lua/` is listed as something to run; `lua/` is for "
         "modules a plugin requires, not files hexe executes")
print(f"path: {len(listed)} plugins listed, and nothing from lua/")

# ---- --noplugin runs none of it ---------------------------------------------

hexe("--noplugin", "config", "validate")
if order():
    fail(f"--noplugin still ran plugins: {order()}")
print("--noplugin: nothing ran, so 'is it me or a plugin?' is answerable")

# ---- order, and one raise not costing the rest ------------------------------

screen_out = bytearray()
lock = threading.Lock()


def out_len():
    with lock:
        return len(screen_out)


def seen_since(since):
    with lock:
        return bytes(screen_out[since:]).decode("utf-8", "replace")


def drain(fd):
    while True:
        try:
            c = os.read(fd, 65536)
            if not c:
                return
            with lock:
                screen_out.extend(c)
        except OSError:
            return


def start_frontend():
    m2, sl = pty.openpty()
    fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "rtp"], stdin=sl, stdout=sl,
                         stderr=sl, env=env, cwd=WD, start_new_session=True)
    os.close(sl)
    procs.append(p)
    threading.Thread(target=drain, args=(m2,), daemon=True).start()
    return m2, p


m, fe = start_frontend()
time.sleep(6)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

ran = order()
want = ["raise", "first", "second", "pack", "after"]
if not ran:
    fail("no plugin ran at all")

# Order first, because a wrong order is the likelier failure and explains the
# rest: path order between roots, alphabetical within one, `after` last. `want`
# repeats once per Lua state.
seq = [what for _, what in ran]
if len(seq) % len(want) or any(seq[i:i + len(want)] != want
                               for i in range(0, len(seq), len(want))):
    fail(f"load order is {seq}, expected {want} repeated once per Lua state")

# Each state runs each plugin once, so every count reads 1. A 2 is a state that
# loaded its plugins twice, and every binding they made is now registered twice.
repeated = sorted({what for n, what in ran if n != "1"})
if repeated:
    fail(f"a Lua state loaded {repeated} more than once; every binding those "
         f"plugins made is registered twice")
print(f"order: {' -> '.join(want)}  ({len(seq) // len(want)} Lua states, once each)")
print("raise: the plugin that raised did not stop the ones after it")
print("lua/: never auto-run, but on the require path")
print("after/: last, however it sorts")

# ---- it runs because it is there, and it works ------------------------------

mark = out_len()
os.write(m, b"\x07")  # ctrl+g -- bound by a plugin, using a module from lua/
deadline = time.time() + 15
while time.time() < deadline and MARK not in seen_since(mark):
    time.sleep(0.4)
if MARK not in seen_since(mark):
    fail("a plugin's own keybinding did not fire. Nothing was approved and "
         "nothing should need to be: it is on the path because somebody put it there")
print("run: a plugin's keybinding works, unapproved, from a config naming no plugin")
print("require: it reached a module in its root's lua/")

# A package is a root like any other, several places further down the path, and
# it read a file it ships through the root it was handed as `...`. Without that
# a package cannot carry a script or a data file.
shipped = open(SHIPPED).read().strip() if os.path.exists(SHIPPED) else ""
if shipped == "NO-SHIPPED-FILE":
    fail("the package could not find a file it ships in its own root")
if shipped != MARK:
    fail(f"the package did not read its own shipped file: {shipped!r}")
print("package: pack/*/start/* loaded, and read a file it ships via `...`")

# Push-to-talk: press and release are separate moments and both must land.
subprocess.run([HEXE, "api", "keys", '"ctrl+alt+p"'], env=env, cwd=WD,
               capture_output=True, timeout=25)
time.sleep(1.5)
if not os.path.exists(PRESSED):
    fail("a press-bound action did not fire on press; for push-to-talk that is "
         "a recorder that never starts")
if os.path.exists(RELEASED):
    fail("the release action fired on press")
subprocess.run([HEXE, "api", "keys", '"ctrl+alt+p"', '"release"'], env=env, cwd=WD,
               capture_output=True, timeout=25)
deadline = time.time() + 15
while time.time() < deadline and not os.path.exists(RELEASED):
    time.sleep(0.3)
if not os.path.exists(RELEASED):
    fail("a release-bound action never fired; push-to-talk would start and never stop")
print("push-to-talk: press fires on press, release fires on release")

user_config = open(os.path.join(ROOT, "init.lua")).read()
if "greeter" in user_config or "plugin" in user_config:
    fail("the user's config mentions a plugin; putting one on the path should "
         "not mean editing your own file")
print("config: the user's init.lua never mentions any of them")

cleanup()
print("PASS: a path of roots, plugin/ run and lua/ required, after/ last")
