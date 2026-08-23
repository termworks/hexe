#!/usr/bin/env python3
"""A plugin starts itself, finds hexe, and reads a pane's bytes.

The three pieces a streaming plugin needs, end to end:

  * `hexe.plugin{}` starts it, and tells it where hexe is via `HEXE_API_SOCKET`
    -- a plugin that had to guess that path would be a plugin that knows hexe's
    runtime layout;
  * the control socket answers `panes`, and each pane carries `pod_socket`, so
    the plugin never builds that path itself either;
  * connecting to that socket as an observer yields the scrollback and then the
    live stream, which is what a web gateway forwards to a browser.

The plugin here is a few lines of Python standing in for the real thing. What
is being tested is hexe's side of the contract, so the stand-in does exactly
what a real one would and nothing else.
"""
import atexit, fcntl, json, os, pty, signal, socket, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"plugstream{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
MARK = f"PLUGINMARK{os.getpid()}"
SEEN = os.path.join(WD, "seen")
STARTED = os.path.join(WD, "started")

# The stand-in plugin: everything a streamer does before it opens a socket of
# its own. AUX_OBSERVER is 0x04 (src/core/wire.zig).
PLUGIN = os.path.join(WD, "plugin.py")
open(PLUGIN, "w").write(f'''
import json, os, socket, struct, sys, time

open({STARTED!r}, "w").write(os.environ.get("HEXE_API_SOCKET", ""))

def api(call):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(os.environ["HEXE_API_SOCKET"])
    body = json.dumps({{"call": call}}).encode()
    s.sendall(struct.pack(">I", len(body)) + body)
    hdr = b""
    while len(hdr) < 4:
        c = s.recv(4 - len(hdr))
        if not c: return None
        hdr += c
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        c = s.recv(need - len(body))
        if not c: break
        body += c
    s.close()
    return json.loads(body)

deadline = time.time() + 30
pane = None
while time.time() < deadline and pane is None:
    r = api("panes")
    for p in (r or {{}}).get("result") or []:
        if p.get("pod_socket"):
            pane = p
            break
    time.sleep(0.5)
if pane is None:
    sys.exit(1)

# Observer: two-byte handshake (channel, protocol version), then framed
# scrollback followed by the live stream. Frames are [type u8][len u32 BE][payload];
# type 1 is output, which is the only one a viewer draws.
o = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
o.connect(pane["pod_socket"])
o.sendall(bytes([0x04, 4]))
o.settimeout(30)

raw, out = bytearray(), bytearray()
end = time.time() + 30
while time.time() < end:
    try:
        b = o.recv(65536)
    except OSError:
        break
    if not b:
        break
    raw.extend(b)
    while len(raw) >= 5:
        ftype = raw[0]
        ln = struct.unpack(">I", bytes(raw[1:5]))[0]
        if len(raw) < 5 + ln:
            break
        payload = bytes(raw[5:5 + ln])
        del raw[:5 + ln]
        if ftype == 1:
            out.extend(payload)
    if {MARK!r}.encode() in bytes(out):
        open({SEEN!r}, "wb").write(bytes(out)[-4000:])
        break
''')

open(os.path.join(CF, "hexe", "init.lua"), "w").write(f"""
local hexe = require("hexe")
hexe.plugin("stream", {{ command = "python3 {PLUGIN}", access = {{ "stream" }} }})
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
    subprocess.run(["pkill", "-9", "-f", PLUGIN], capture_output=True)


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


def drain():
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "plugstream"], stdin=sl, stdout=sl,
                      stderr=sl, env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, daemon=True).start()

deadline = time.time() + 30
while time.time() < deadline and not os.path.exists(STARTED):
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    time.sleep(0.4)
if not os.path.exists(STARTED):
    fail("hexe never started the configured plugin")

sock = open(STARTED).read().strip()
if not sock:
    fail("the plugin started but HEXE_API_SOCKET was empty; it would have to "
         "guess where hexe is")
if not os.path.exists(sock):
    fail(f"HEXE_API_SOCKET points at {sock!r}, which does not exist")
print(f"lifecycle: hexe started the plugin and pointed it at {os.path.basename(sock)}")

# Something for the observer to see.
time.sleep(2.0)
os.write(m, f"echo {MARK}\r".encode())

deadline = time.time() + 40
while time.time() < deadline and not os.path.exists(SEEN):
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    time.sleep(0.5)
if not os.path.exists(SEEN):
    fail("the plugin never saw the pane's output. Either `pod_socket` did not "
         "reach it, or the observer channel delivered nothing — those are the "
         "two things a streaming plugin is made of")

blob = open(SEEN, "rb").read()
if MARK.encode() not in blob:
    fail(f"the observer stream did not contain the marker ({len(blob)} bytes)")
print(f"stream: the plugin read the pane's live output through pod_socket "
      f"({len(blob)} bytes)")

if fe.poll() is not None:
    fail("the frontend died during the checks")

cleanup()
print("PASS: a plugin is started, finds hexe, and reads a pane's bytes")
