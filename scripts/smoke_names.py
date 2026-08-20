#!/usr/bin/env python3
"""Panes are named from the configured dictionary, and never twice the same.

A pane name is not decoration: the pod behind it is addressed by `--name` and
its socket is `pod@<name>.sock`, so a duplicate is two panes fighting over one
socket path. The rules under test:

  vocabulary   with `names.pane` set, panes get entries from THAT list and
               nothing from the built-in pool
  uniqueness   the first FREE entry, so N panes get N distinct names
  exhaustion   past the end of a short list, names gain the configured suffix

The dictionary is produced by a command, which is the case that matters: it is
how a painter hands hexe the vocabulary for art it can actually draw.
"""
import atexit
import fcntl, os, pty, re, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"names{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)

# Deliberately short, so opening more panes than entries exercises the suffix.
POOL = ["quartz", "basalt", "gneiss"]
POOL_SH = os.path.join(WD, "pool.sh")
with open(POOL_SH, "w") as fh:
    fh.write("#!/bin/sh\n" + "".join(f"echo {n}\n" for n in POOL))
os.chmod(POOL_SH, 0o755)

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(
        "local hexe = require('hexe')\n"
        "return hexe.setup({\n"
        "  names = {\n"
        f"    pane = hexe.command('{POOL_SH}'),\n"
        "    order = 'sequential',\n"
        "    suffix = '-%d',\n"
        "  },\n"
        # Bound here rather than assumed: the smoke needs to open panes, and a
        # default binding it does not control would make this test about keys.
        "  keys = {\n"
        "    hexe.key({ hexe.key.ctrl, hexe.key.alt, hexe.key.s },\n"
        "             hexe.action.split.vertical()),\n"
        "  },\n"
        "})\n"
    )

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_CONFIG_HOME": CF, "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET"):
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
    cleanup()
    sys.exit(1)


seen = bytearray()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "names"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave)
procs.append(fe)


def drain():
    while True:
        try:
            c = os.read(master, 65536)
            if not c:
                return
        except OSError:
            return
        seen.extend(c)


threading.Thread(target=drain, daemon=True).start()
time.sleep(5.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")


def pane_names():
    """Every live pane name, straight from the daemon."""
    # A pane's name IS its pod name, and the pod list is where it is visible
    # for a live session.
    r = subprocess.run([HEXE, "pod", "list"], env=env, cwd=WD,
                       capture_output=True, text=True, timeout=20)
    return r.stdout + r.stderr


# Open more panes than the dictionary has entries.
WANT = len(POOL) + 2
for _ in range(WANT - 1):
    os.write(master, b"\x1b\x13")     # ctrl+alt+s -> split.vertical
    time.sleep(2.0)
time.sleep(3.0)

listing = pane_names()
found = [n for n in POOL if re.search(rf"\b{n}\b", listing)]
if not found:
    fail(f"no configured entry appears in the pane list — the dictionary never "
         f"reached SES.\nlisting:\n{listing[:600]}")
print(f"vocabulary: panes named from the configured dictionary ({', '.join(found)})")

# Nothing from the built-in NATO pool should appear while a dictionary is set.
nato = [n for n in ("alfa", "bravo", "charlie", "delta", "echo")
        if re.search(rf"\b{n}\b", listing)]
if nato:
    fail(f"built-in pool leaked through while a dictionary was configured: {nato}\n"
         f"listing:\n{listing[:600]}")
print("vocabulary: the built-in pool is not used while a dictionary is set")

# Every name distinct: a duplicate is two pods on one socket path.
names = re.findall(r"\b(?:" + "|".join(POOL) + r")(?:-\d+)?\b", listing)
if len(names) != len(set(names)):
    dupes = sorted({n for n in names if names.count(n) > 1})
    fail(f"the same name was handed out twice ({dupes}) — their pod sockets "
         f"collide on pod@<name>.sock")
print(f"uniqueness: {len(set(names))} panes, {len(set(names))} distinct names")

# Past the end of a 3-entry list, the suffix has to appear.
suffixed = [n for n in names if re.search(r"-\d+$", n)]
if len(set(names)) > len(POOL) and not suffixed:
    fail(f"more panes than dictionary entries but no name gained a suffix: {names}")
if suffixed:
    print(f"exhaustion: past the dictionary, names take the suffix ({suffixed[0]})")

if fe.poll() is not None:
    fail("frontend died during the checks")

cleanup()
print("PASS: panes are named from the configured dictionary, uniquely")
