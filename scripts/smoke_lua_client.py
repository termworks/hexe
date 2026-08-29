#!/usr/bin/env python3
"""Another Lua program can drive a running hexe through the shipped library.

hexe already had the server half: a socket that dispatches a call by name into
the same Lua functions the local API uses. What it had no client for was
*another program* — only `hexe api`, a CLI, which a Lua host would have to shell
out to and then parse.

So `hexe lua-api` prints a plain-Lua file. It carries framing, JSON, discovery
and the exposed verbs, and the one thing it cannot do — open a socket — arrives
as the chunk's argument. That makes it copyable between siblings rather than
portable-in-principle, and it is what lets one hexe talk to another.

Checked here:

  * `hexe lua-api` prints something that loads as Lua and has no host
    dependency beyond the transport it is handed;
  * a session's own Lua, using that file, reads ANOTHER session's live pane
    list — the thing a sibling actually wants and cannot scrape accurately;
  * connecting to your OWN session is refused with a reason, because from
    inside the frontend's event loop it can never be answered and would
    otherwise look like a hang.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"luacl{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
DATA = os.path.join(WD, "data")
PKG = os.path.join(DATA, "hexe", "site", "pack", "t", "start", "caller")
for d in (os.path.join(CF, "hexe"), RUN, os.path.join(PKG, "plugin")):
    os.makedirs(d, exist_ok=True)
INST = f"smk{os.getpid()}"
RESULT = os.path.join(WD, "result")

open(os.path.join(PKG, "plugin", "caller.lua"), "w").write(f"""
hexe.key({{ hexe.key.ctrl, hexe.key.g }}, function(ctx)
  local out = io.open("{RESULT}", "w")
  local ok, err = pcall(function()
    local client = require("hexe.client")
    out:write("loaded=" .. type(client) .. "\\n")

    -- Our own session: refused, with a reason.
    local me, why_me = client.connect("caller_side")
    out:write("self=" .. tostring(me) .. " why=" .. tostring(why_me) .. "\\n")

    -- A different session: the actual use.
    local mux, why = client.connect("other_side")
    if not mux then out:write("other failed: " .. tostring(why) .. "\\n"); return end
    local panes = mux.panes()
    local sess = mux.session()
    out:write("other_name=" .. tostring(sess and sess.name)
              .. " panes=" .. tostring(#panes)
              .. " first=" .. tostring(panes[1] and panes[1].name) .. "\\n")
  end)
  if not ok then out:write("RAISED: " .. tostring(err) .. "\\n") end
  out:close()
end)
""")
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
signal.alarm(180)


def api(*args):
    r = subprocess.run([HEXE, "api", *args], env=env, cwd=WD,
                       capture_output=True, text=True, timeout=30)
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return {}


# --- the library is printed, and is plain Lua -------------------------------

r = subprocess.run([HEXE, "lua-api"], env=env, cwd=WD, capture_output=True, text=True, timeout=30)
src = r.stdout
if len(src) < 500:
    fail(f"`hexe lua-api` printed {len(src)} bytes; there is no library to hand out")
if "function M.connect" not in src:
    fail("what `hexe lua-api` printed has no connect(); it is not the client library")
for forbidden in ("require(", "hexe.json", "package."):
    if forbidden in src.replace('require("hexe.client")', ""):
        fail(f"the client library reaches for `{forbidden}` — a host that lacks it cannot load "
             "the file, which defeats the point of it being plain Lua")
print(f"library: `hexe lua-api` prints {len(src)} bytes of dependency-free Lua")

def start(name):
    m, sl = pty.openpty()
    fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "mux", "new", "-n", name], stdin=sl, stdout=sl, stderr=sl,
                         env=env, cwd=WD, start_new_session=True)
    os.close(sl)
    procs.append(p)

    def drain():
        while True:
            try:
                if not os.read(m, 65536):
                    return
            except OSError:
                return
    threading.Thread(target=drain, daemon=True).start()
    return p


other = start("other_side")
time.sleep(5)
caller = start("caller_side")

deadline = time.time() + 40
while time.time() < deadline:
    if (api("--session", "caller_side", "panes").get("result")
            and api("--session", "other_side", "panes").get("result")):
        break
    if caller.poll() is not None:
        fail(f"the calling session exited rc={caller.returncode}")
    time.sleep(0.5)

api("--session", "caller_side", "keys", '"ctrl+g"')

deadline = time.time() + 30
while time.time() < deadline and not os.path.exists(RESULT):
    time.sleep(0.4)
if not os.path.exists(RESULT):
    fail("the plugin never ran")
body = open(RESULT).read()

if "RAISED" in body:
    fail(f"the client library raised inside hexe's own VM: {body.strip()}")
if "loaded=table" not in body:
    fail(f"require('hexe.client') did not return the library: {body.strip()}")
print("in-vm: hexe's own Lua loads the same library it hands out")

# The self-connect guard.
if "self=nil" not in body:
    fail("connecting to your OWN session was allowed; from inside the frontend's "
         f"event loop that can never be answered and hangs: {body.strip()}")
if "this session" not in body:
    fail(f"the self-connection was refused without saying why: {body.strip()}")
print("self: connecting to your own session is refused, with the reason")

# The cross-session call, which is the whole point.
if "other_name=other_side" not in body:
    fail(f"the call to the other session did not return its name: {body.strip()}")
if "panes=1" not in body:
    fail(f"the other session's pane list did not come back: {body.strip()}")
first = [l for l in body.splitlines() if l.startswith("other_name=")]
print(f"cross-session: {first[0] if first else body.strip()}")

if caller.poll() is not None or other.poll() is not None:
    fail("a session died during the checks")

cleanup()
print("PASS: one hexe drives another through the library it ships")
