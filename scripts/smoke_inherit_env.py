#!/usr/bin/env python3
"""An `inherit_env` float sees what the parent pane exported after it started.

    export ONE=two          # in a pane
                            # open an inherit_env float
    echo $ONE               # nothing, before this

`inherit_env` was honoured all along; the failure was one level down. The pane's
environment came from `/proc/<pid>/environ`, which on Linux is the image as of
`execve` and therefore cannot contain a later `export` -- ever. So the feature
copied *an* environment while being wrong about exactly the variables anybody
notices.

It now comes from a memfd the shell rewrites at every prompt. Two things follow,
and both are checked here:

  * the variable arrives, which is the bug;
  * `/tmp/hexe-env-*` is gone. That file was the previous mechanism: a
    predictable path in a shared /tmp, created under the user's umask so
    world-readable, holding the entire environment including tokens, rewritten
    every prompt and never unlinked.

The float is given a variable exported AFTER its parent's shell was already
running, which is the only case that distinguishes the two mechanisms.
"""
import atexit, fcntl, glob, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"inheritenv{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
INST = f"smk{os.getpid()}"
MARK = f"HEXEENVPROBE{os.getpid()}"
OUT = os.path.join(WD, "seen")

open(os.path.join(CF, "hexe", "init.lua"), "w").write(f"""
local hexe = require("hexe")
return hexe.setup({{
  ses = {{ layouts = {{ hexe.layout("envlay", {{
    root = "{WD}",
    tabs = {{ hexe.tab("main", {{ root = hexe.pane() }}) }},
    floats = {{
      hexe.float("probe", {{ key = "g", title = "probe",
        command = "sh -c 'printf %s \\"${{{MARK}:-EMPTY}}\\" > {OUT}; sleep 600'",
        attrs = {{ inherit_env = true }} }}),
    }},
  }}) }} }},
  keys = {{ hexe.key({{ hexe.key.alt, hexe.key['g'] }}, hexe.action.float.toggle('g')) }},
}})
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_CONFIG_HOME": CF, "TERM": "xterm-256color", "SHELL": "/bin/bash",
            "HEXE_SKIP_LOCAL_CONFIG": "1", "HEXE_TRUST_ALL_PROJECTS": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET",
           "HEXE_ENV_FD"):
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


def watchdog(_sig, _frm):
    print("FAIL: timed out waiting for the mux")
    sys.stdout.flush()
    cleanup()
    os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(150)


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "inheritenv"], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()
time.sleep(7.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

# Load the integration, then export AFTER the shell is already running. That
# ordering is the whole point: an exec-time image cannot contain this.
# Through $HEXE_BIN: the pane's PATH is the user's, and a shell rc file that
# reorders it would otherwise have this testing whichever hexe is installed.
os.write(m, b'eval "$("${HEXE_BIN:-hexe}" shell init bash)"\r')
time.sleep(2.5)
os.write(m, f'export {MARK}=inherited\r'.encode())
time.sleep(1.0)
# A prompt has to happen for the shell to publish. This is the documented
# one-prompt lag, not a workaround for it.
os.write(m, b"true\r")
time.sleep(3.0)

if os.path.exists(OUT):
    os.unlink(OUT)
os.write(m, b"\x1bg")

deadline = time.time() + 30
while time.time() < deadline and not os.path.exists(OUT):
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode} while opening the float")
    time.sleep(0.4)
if not os.path.exists(OUT):
    fail("the inherit_env float never started, so nothing could be inherited")

time.sleep(0.4)
seen = open(OUT).read().strip()
if seen == "EMPTY":
    fail(f"the float did not inherit {MARK}, exported in the parent pane after "
         f"its shell started. That is the bug: /proc/<pid>/environ is the image "
         f"as of execve and can never hold a later export")
if seen != "inherited":
    fail(f"the float saw {MARK}={seen!r}, expected 'inherited'")
print(f"inherit: the float sees {MARK}={seen}, exported after the shell started")

# The mechanism it replaced must be gone, not merely unused.
leaked = glob.glob("/tmp/hexe-env-*")
if leaked:
    fail(f"the world-readable environment file is still being written: "
         f"{leaked[:3]}. It holds every variable including tokens, under a "
         f"predictable path in a shared /tmp, and nothing ever unlinks it")
print("privacy: no /tmp/hexe-env-* file exists")

# The descriptor must die with the pane. One anonymous file per pane that
# nothing ever closes is the same leak the /tmp file had, just harder to see.
def ses_memfds():
    r = subprocess.run(["pgrep", "-f", f"instance {INST}"], capture_output=True, text=True)
    total = 0
    for pid in (r.stdout or "").split():
        try:
            if "ses daemon" not in open(f"/proc/{pid}/cmdline").read().replace("\0", " "):
                continue
            for f in os.listdir(f"/proc/{pid}/fd"):
                try:
                    if "memfd:hexe-env" in os.readlink(f"/proc/{pid}/fd/{f}"):
                        total += 1
                except OSError:
                    pass
        except OSError:
            pass
    return total


before = ses_memfds()
if before < 2:
    fail(f"SES holds {before} environment descriptors with a pane and a float "
         f"open; expected one per pane, so this count cannot show a leak")

# Killed, not toggled: toggling a float hides it and the pane lives on, so the
# descriptor is supposed to survive that.
# By uuid: "probe" is the float's declared name in the layout, not the name the
# pane was given from the pool, so it matches nothing.
_f = subprocess.run([HEXE, "api", "floats"], env=env, cwd=WD,
                    capture_output=True, text=True, timeout=30)
try:
    _floats = json.loads(_f.stdout or "{}").get("result") or []
except ValueError:
    _floats = []
if not _floats:
    fail(f"could not find the float to kill: {(_f.stdout or _f.stderr)[:200]}")
_uuid = _floats[0]["uuid"]
_k = subprocess.run([HEXE, "terminal", "kill", _uuid[:8]], env=env, cwd=WD,
                    capture_output=True, text=True, timeout=30)
_said = ((_k.stdout or "") + (_k.stderr or "")).strip()
if "Killed" not in _said:
    fail(f"killing the float failed: {_said[:200]}")
deadline = time.time() + 25
while time.time() < deadline and ses_memfds() >= before:
    time.sleep(0.5)
after = ses_memfds()
if after >= before:
    fail(f"killing the float left {after} environment descriptors open (was "
         f"{before}). One anonymous file per pane that nothing closes is a leak "
         f"for as long as the daemon lives")
print(f"lifetime: descriptors {before} -> {after} when the float was killed")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: inherit_env carries what the parent exported, with no file in /tmp")
