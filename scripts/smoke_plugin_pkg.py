#!/usr/bin/env python3
"""A plugin is a package you install, not a command string in your config.

The thing being tested is that installing a plugin does not mean editing your
config. The plugin brings its own keybinding, its own logic and its own
declaration of what it needs; your `init.lua` never mentions it.

  * `hexe plugin install` reads the manifest and reports what is asked for,
    WITHOUT running anything -- that ordering is the reason the manifest is a
    separate file from the body;
  * an unapproved package does not run, and `hexe plugin allow` is what changes
    that;
  * once approved, its `init.lua` runs inside hexe and its keybinding works --
    from a config that names no plugin at all;
  * changing the package after approval stops it running again.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"pkg{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
DATA = os.path.join(WD, "data")
SRC = os.path.join(WD, "src", "greeter")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
os.makedirs(SRC, exist_ok=True)
INST = f"smk{os.getpid()}"
MARK = f"pkgmark{os.getpid()}"
PRESSED = os.path.join(WD, "pressed")
RELEASED = os.path.join(WD, "released")

# The package. Note what is NOT in the user's config: this keybinding.
open(os.path.join(SRC, "plugin.lua"), "w").write("""
return {
  name        = "greeter",
  version     = "1.2.3",
  description = "says hello when you press a key",
  entry       = "init.lua",
  access      = { "popup" },
}
""")
# A file the package ships beside its entry. Finding it is the point: a package
# that cannot name its own files has to hardcode an install path.
open(os.path.join(SRC, "greeting.txt"), "w").write(MARK + "\n")
open(os.path.join(SRC, "init.lua"), "w").write(f"""
local here = ...                       -- the package's own directory
local f = io.open(here .. "/greeting.txt", "r")
local greeting = f and f:read("*l") or "NO-SHIPPED-FILE"
if f then f:close() end

hexe.key({{ hexe.key.ctrl, hexe.key.g }}, function(ctx)
  ctx.popup(greeting)
end)

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
open(os.path.join(CF, "hexe", "init.lua"), "w").write("local hexe = require('hexe')\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF, "XDG_DATA_HOME": DATA,
            "HEXE_TRUST_LEDGER": os.path.join(WD, "trust"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh", "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_FLOAT", "HEXE_PAINTER_SOCKET", "HEXE_ENV_FD", "HEXE_BIN", "HEXE_API_SOCKET"):
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
signal.alarm(150)


def hexe(*args):
    return subprocess.run([HEXE, *args], env=env, cwd=WD,
                          capture_output=True, text=True, timeout=30)


# --- install: reads the manifest, runs nothing --------------------------------

r = hexe("plugin", "install", SRC)
body = r.stdout + r.stderr
if "greeter" not in body or "1.2.3" not in body:
    fail(f"install did not report what it installed: {body!r}")
if "popup" not in body:
    fail(f"install did not say what the plugin asks for: {body!r}")
if "allow" not in body:
    fail("install did not say that nothing has run yet; the manifest exists to "
         "be read BEFORE the body runs and the user was not told")
print("install: the manifest is read and reported, and nothing ran")

r = hexe("plugin", "list")
if "greeter" not in r.stdout:
    fail(f"the installed plugin is not listed: {r.stdout!r}")
if "CHANGED" not in r.stdout and "ok" in r.stdout:
    fail("a freshly installed plugin is already approved; installing and "
         "approving must be separate or the manifest buys nothing")
print("list: it is installed and not yet approved")

# --- an unapproved package must not run ---------------------------------------

screen_out = bytearray()
lock = threading.Lock()


def out_len():
    with lock:
        return len(screen_out)


def seen_since(since):
    with lock:
        return bytes(screen_out[since:]).decode("utf-8", "replace")


def drain():
    while True:
        try:
            c = os.read(m, 65536)
            if not c:
                return
            with lock:
                screen_out.extend(c)
        except OSError:
            return


def start_frontend():
    global m, fe
    m2, sl = pty.openpty()
    fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", "pkg"], stdin=sl, stdout=sl,
                         stderr=sl, env=env, cwd=WD, start_new_session=True)
    os.close(sl)
    procs.append(p)
    return m2, p


def stop_frontend(p):
    subprocess.run(["pkill", "-9", "-f", f"instance {INST}"], capture_output=True)
    try: p.kill()
    except OSError: pass
    time.sleep(1.5)


m, fe = start_frontend()
threading.Thread(target=drain, daemon=True).start()
time.sleep(6)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

mark = out_len()
os.write(m, b"\x07")  # ctrl+g
time.sleep(2.0)
if MARK in seen_since(mark):
    fail("an UNAPPROVED plugin's keybinding fired; the trust ledger did nothing")
print("unapproved: its keybinding does not fire")
stop_frontend(fe)

# --- approve, and it works, from a config that names no plugin ----------------

r = hexe("plugin", "allow", "greeter")
if "approved" not in (r.stdout + r.stderr):
    fail(f"allow did not approve: {r.stdout!r} {r.stderr!r}")
r = hexe("plugin", "list")
if "ok" not in r.stdout:
    fail(f"after allow it is still not ok: {r.stdout!r}")
print("allow: approving it is a separate, explicit step")

screen_out.clear()
m, fe = start_frontend()
threading.Thread(target=drain, daemon=True).start()
time.sleep(6)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

mark = out_len()
os.write(m, b"\x07")
deadline = time.time() + 15
fired = False
while time.time() < deadline:
    if MARK in seen_since(mark):
        fired = True
        break
    time.sleep(0.4)
if not fired:
    fail("the approved plugin's keybinding did not fire; the package's own "
         "binding is the reason it is a package and not a config snippet")
print("run: the plugin's own keybinding works, from a config that names no plugin")

# The text came from a file shipped IN the package and read via `...`, so a
# package can carry scripts and data rather than hardcoding an install path.
if "NO-SHIPPED-FILE" in seen_since(mark):
    fail("the plugin could not find a file it ships beside its own entry; "
         "without that a package cannot carry a script")
print("shipped files: it found its own directory and read a file it ships")

# Push-to-talk: press and release are separate moments and both must land.
# `keys` presses the chord; `keys(chord, "release")` lets go of it.
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
    fail("a release-bound action never fired; push-to-talk would start and "
         "never stop")
print("push-to-talk: press fires on press, release fires on release")

user_config = open(os.path.join(CF, "hexe", "init.lua")).read()
if "greeter" in user_config or "plugin" in user_config:
    fail("the user's config mentions the plugin; installing should not mean "
         "editing your own file")
print("config: the user's init.lua never mentions it")
stop_frontend(fe)

# --- changing it after approval stops it again --------------------------------

installed_entry = os.path.join(DATA, "hexe", "plugins", "greeter", "init.lua")
with open(installed_entry, "a") as fh:
    fh.write("\n-- edited after approval\n")
r = hexe("plugin", "list")
if "CHANGED" not in r.stdout:
    fail(f"an edited package still reads as approved: {r.stdout!r}")
print("tamper: editing it after approval revokes it")

r = hexe("plugin", "remove", "greeter")
if "removed" not in (r.stdout + r.stderr):
    fail(f"remove failed: {r.stdout!r} {r.stderr!r}")
if "greeter" in hexe("plugin", "list").stdout:
    fail("it is still listed after removal")
print("remove: it goes away, and takes its keybinding with it")

cleanup()
print("PASS: plugins install, declare, approve and remove as packages")
