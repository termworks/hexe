#!/usr/bin/env python3
"""A plugin gets the access it declared, and nothing else.

The point of declaring access is that the declaration is *load-bearing*: a
streaming plugin must not be able to type into a shell, and a dictation tool
must not be able to read the byte stream. So this asserts both directions --
what the grant allows, and what it refuses -- because a permission system that
only ever says yes is indistinguishable from no permission system at all.

Three plugins are started with different grants and each is checked against the
same set of calls. They talk to hexe over their own scoped sockets, which is
what makes the grant a property of the door rather than of what the caller
claims about itself.
"""
import atexit, fcntl, json, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"access{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"

# Each plugin does one thing: write down the socket and grant it was handed.
TOOL = os.path.join(WD, "tool.sh")
with open(TOOL, "w") as fh:
    fh.write(f"""#!/bin/sh
{{ echo "sock=$HEXE_API_SOCKET"; echo "access=$HEXE_ACCESS"; }} > {WD!r}/seen.$1
sleep 600
""")
os.chmod(TOOL, 0o755)

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(f"""
local hexe = require("hexe")
hexe.plugin("watcher", {{ command = "sh {TOOL} watcher", access = {{ "stream" }} }})
hexe.plugin("typer",   {{ command = "sh {TOOL} typer",   access = {{ "typing" }} }})
hexe.plugin("quiet",   {{ command = "sh {TOOL} quiet" }})
""")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
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
    subprocess.run(["pkill", "-9", "-f", TOOL], capture_output=True)


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


def call(sock_path, name, *args):
    """One request on a specific socket -- the plugin's, not the session's."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(sock_path)
    req = {"call": name}
    if args:
        req["args"] = list(args)
    body = json.dumps(req).encode()
    s.sendall(struct.pack(">I", len(body)) + body)
    hdr = b""
    while len(hdr) < 4:
        c = s.recv(4 - len(hdr))
        if not c:
            s.close()
            return {}
        hdr += c
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        c = s.recv(need - len(body))
        if not c:
            break
        body += c
    s.close()
    # `result` is the list of return values; a client unwraps the single one.
    r = json.loads(body or b"{}")
    if r.get("ok") and isinstance(r.get("result"), list):
        vals = r["result"]
        r = dict(r, result=vals[0] if (r.get("n") or len(vals)) == 1 else vals)
    return r


def api(*args):
    r = subprocess.run([HEXE, "api", *args], env=env, cwd=WD,
                       capture_output=True, text=True, timeout=25)
    try:
        return json.loads(r.stdout or "{}")
    except json.JSONDecodeError:
        return {}


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "access"], stdin=sl, stdout=sl,
                      stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 40
while time.time() < deadline:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    if all(os.path.exists(os.path.join(WD, f"seen.{n}")) for n in ("watcher", "typer", "quiet")):
        break
    time.sleep(0.4)

grants = {}
for name in ("watcher", "typer", "quiet"):
    path = os.path.join(WD, f"seen.{name}")
    if not os.path.exists(path):
        fail(f"plugin '{name}' never started")
    grants[name] = dict(line.split("=", 1) for line in open(path).read().splitlines() if "=" in line)

# Each plugin gets its OWN socket. Sharing one would make the grant a property
# of the request rather than of the connection, and a request can lie.
socks = {n: g.get("sock", "") for n, g in grants.items()}
if len(set(socks.values())) != 3:
    fail(f"plugins share sockets, so grants cannot differ: {socks}")
for name, s in socks.items():
    if not s or not os.path.exists(s):
        fail(f"plugin '{name}' got no usable socket: {s!r}")
print(f"sockets: each plugin got its own ({', '.join(os.path.basename(s) for s in socks.values())})")

if grants["watcher"].get("access") != "read,stream":
    fail(f"watcher was told access={grants['watcher'].get('access')!r}, expected 'read,stream'")
if grants["quiet"].get("access") != "read":
    fail(f"a plugin that declared nothing got {grants['quiet'].get('access')!r}, "
         "expected the harmless floor 'read'")
print("declaration: each plugin is told what it holds; declaring nothing means read")

# Structure is the floor; CONTENTS are not. A plugin that can list panes must
# not thereby be able to read what is printed in them.
r = call(socks["quiet"], "screen_text")
if r.get("ok"):
    fail("a read-only plugin could read pane CONTENTS; structure and contents "
         "must not be the same grant -- a password on screen is screen_text")
print("screen: listing panes does not imply reading what is in them")

# --- what a grant allows, and what it refuses ------------------------------

def allowed(name, verb, *args):
    r = call(socks[name], verb, *args)
    if not r.get("ok"):
        fail(f"'{name}' was refused `{verb}` but holds the access for it: {r.get('error')!r}")
    return r


def refused(name, verb, *args):
    r = call(socks[name], verb, *args)
    if r.get("ok"):
        fail(f"'{name}' called `{verb}` without holding its access -- the grant is not enforced")
    if "access" not in (r.get("error") or ""):
        fail(f"'{name}' was refused `{verb}` for the wrong reason: {r.get('error')!r}")
    return r


# `read` is held by all three, so it is the control: it must work everywhere.
for name in socks:
    allowed(name, "panes")
print("read: every plugin can look at the session")

r = refused("watcher", "send", "hello")
print(f"refused: the stream plugin cannot type ({r.get('error','')[:52]}…)")
refused("typer", "close")
print("refused: the typing plugin cannot close panes")
refused("quiet", "send", "hello")
refused("quiet", "keys", "ctrl+alt+d")
print("refused: a read-only plugin can neither type nor press keys")

allowed("typer", "send", "")
print("allowed: the typing plugin may type")

# `capture` is deliberately open to everyone: CLAIMING to record is harmless,
# and the harm runs the other way -- recording without claiming. Gating it
# would only give a plugin a reason to skip the indicator.
for name in socks:
    allowed(name, "capture")
print("capture: any plugin may claim the recording indicator")

# `pod_socket` is the byte stream behind a field name, so `read` must not leak it.
watcher_pane = (call(socks["watcher"], "panes").get("result") or [{}])[0]
typer_pane = (call(socks["typer"], "panes").get("result") or [{}])[0]
if not watcher_pane.get("pod_socket"):
    fail("the stream plugin was not given pod_socket, so it cannot stream")
if typer_pane.get("pod_socket"):
    fail("a plugin without stream access was handed pod_socket -- the whole byte "
         "stream, behind a field name")
print("stream: pod_socket is shown to the stream plugin and withheld from the others")

# The session's own socket keeps full authority; scoping is for plugins.
if not api("send", '"# owner still has everything\\n"').get("ok"):
    fail("the session's own socket lost authority; scoping leaked onto the owner")
print("owner: the session socket is unscoped, as before")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: plugins get the access they declared, and are refused the rest")
