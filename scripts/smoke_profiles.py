#!/usr/bin/env python3
"""Live check: profiles are separate hexes — own daemon, own sessions.

A profile is selected with `--profile NAME` (or HEXE_INSTANCE) and gets its own
ses daemon, sockets, state and log, so `work` and `personal` cannot see or
disturb each other.

Two things this pins that were broken:

  * `--profile` did not exist on the root command at all, so bare `hexe` — the
    command a user actually types — could not select a profile.
  * top-level alias normalisation only applied to argv[1], so putting any root
    flag first made `hexe --profile work ses list` fail with
    "unrecognized command 'ses'".

And the separation itself: one profile's session list must never contain
another's, and killing one daemon must not touch the other.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
WD = os.path.join(SCRATCH, f"profiles{os.getpid()}")
os.makedirs(WD, exist_ok=True)

# Profile names must still start with the smoke prefix: smoke-clean identifies
# smoke processes by HEXE_INSTANCE=smk*, and anything else would be left behind.
A = f"smk{os.getpid()}a"
B = f"smk{os.getpid()}b"
procs = []


CF = os.path.join(WD, "cfg")
os.makedirs(os.path.join(CF, "hexe", "profiles"), exist_ok=True)
# The shared config every profile falls back to...
open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    'local hexe = require("hexe")\n'
    'return hexe.setup({ mux = { selection_color = 111 } })\n')
# ...and one profile's own, which must win for that profile only.
open(os.path.join(CF, "hexe", "profiles", f"{A}.lua"), "w").write(
    'local hexe = require("hexe")\n'
    'return hexe.setup({ mux = { selection_color = 222 } })\n')


def base_env(profile=None):
    e = os.environ.copy()
    e.update({"XDG_STATE_HOME": os.path.join(WD, "state"),
              "XDG_CONFIG_HOME": CF,
              "TERM": "xterm-256color", "SHELL": "/bin/sh"})
    for k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
              "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_INSTANCE"):
        e.pop(k, None)
    if profile:
        e["HEXE_INSTANCE"] = profile
    return e


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
    for name in (A, B):
        subprocess.run(["pkill", "-9", "-f", f"instance {name}"], capture_output=True)


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))


def fail(msg):
    print(f"FAIL: {msg}"); cleanup(); sys.exit(1)


def hexe(args, profile=None, timeout=20):
    r = subprocess.run([HEXE] + args, capture_output=True, text=True,
                       env=base_env(profile), cwd=WD, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr)


def start(profile, session):
    """Start a frontend through the ROOT flag, which is the path under test."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen([HEXE, "--profile", profile, "mux", "new", "-n", session],
                         stdin=slave, stdout=slave, stderr=slave,
                         env=base_env(), cwd=WD, start_new_session=True)
    os.close(slave); procs.append(p)

    def drain():
        while True:
            try:
                if not os.read(master, 65536):
                    return
            except OSError:
                return

    threading.Thread(target=drain, daemon=True).start()
    return p


os.makedirs(os.path.join(WD, "state"), exist_ok=True)
fe_a = start(A, "alpha")
time.sleep(4.0)
fe_b = start(B, "bravo")
time.sleep(4.0)

if fe_a.poll() is not None:
    fail(f"`hexe --profile {A} mux new` exited rc={fe_a.returncode} — the root "
         "profile flag does not start a session")
if fe_b.poll() is not None:
    fail(f"second profile exited rc={fe_b.returncode}")
print("root flag: `hexe --profile NAME mux new` started both profiles")

# The alias must survive a root flag preceding it.
rc, out = hexe(["--profile", A, "ses", "list"])
if "unrecognized command" in out:
    fail(f"a root flag broke top-level alias normalisation: {out.strip()[:120]}")
if rc != 0:
    fail(f"`--profile {A} ses list` failed rc={rc}: {out.strip()[:160]}")
if "alpha" not in out:
    fail(f"profile {A} does not list its own session: {out.strip()[:200]}")
if "bravo" in out:
    fail(f"profile {A} can see the OTHER profile's session — they share a daemon: "
         f"{out.strip()[:200]}")
print("separation: each profile lists only its own sessions")

rc, out = hexe(["--profile", B, "ses", "list"])
if "bravo" not in out or "alpha" in out:
    fail(f"profile {B} session list is wrong: {out.strip()[:200]}")

# Discovery: both must show up as running.
rc, out = hexe(["profile", "list"])
if rc != 0:
    fail(f"`hexe profile list` failed rc={rc}: {out.strip()[:160]}")
for name in (A, B):
    line = next((l for l in out.splitlines() if l.split()[:1] == [name] or
                 l.strip().startswith(name)), None)
    if line is None:
        fail(f"`profile list` does not show running profile {name}: {out[:300]}")
    if "running" not in line:
        fail(f"`profile list` shows {name} as not running: {line!r}")
print("discovery: `hexe profile list` reports both as running")

# Killing one daemon must not disturb the other.
subprocess.run(["pkill", "-9", "-f", f"instance {A}"], capture_output=True)
time.sleep(2.0)
rc, out = hexe(["--profile", B, "ses", "list"])
if "bravo" not in out:
    fail(f"killing profile {A} took {B} down with it: {out.strip()[:200]}")
print(f"isolation: killing {A}'s daemon left {B} serving its session")

# Per-profile CONFIG. Profiles were separate daemons but shared one init.lua,
# so `work` and `personal` could not differ in layout, keybinds or painter.
rc, out = hexe(["--profile", A, "config", "validate"])
if f"profiles/{A}.lua" not in out:
    fail(f"profile {A} did not use its own config: {out.strip()[:200]}")
rc, out = hexe(["--profile", B, "config", "validate"])
if "init.lua" not in out or "profiles/" in out:
    fail(f"profile {B} has no config of its own and must fall back to the shared "
         f"init.lua: {out.strip()[:200]}")
print("config: a profile uses profiles/<name>.lua, else the shared init.lua")

# The profile name reaches the filesystem, so it must never escape the config dir.
rc, out = hexe(["--profile", "../../../../tmp/evil/pwned", "config", "validate"])
if "init.lua" not in out:
    fail(f"a profile name escaped the config directory: {out.strip()[:200]}")
print("config: a traversing profile name falls back instead of escaping")

cleanup()
print("SMOKE PASS: profiles are separate daemons with separate sessions")
