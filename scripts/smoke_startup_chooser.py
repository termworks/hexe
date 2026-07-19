#!/usr/bin/env python3
"""Live test: the bare-`hexe` startup chooser (popup, two levels).

Plain `hexe` in a directory now asks, in the MUX popup UI:
  1. attach to a session already rooted at THIS cwd?  (one -> confirm,
     several -> picker, none -> skip)
  2. load the local .hexe.lua?
Declining both starts a plain session.

Cases exercised here:
  A) no sessions, no .hexe.lua      -> no popup, straight to a usable shell
  B) one same-dir session           -> confirm popup; YES attaches (marker visible)
  C) one same-dir session           -> confirm popup; NO starts a fresh session
  D) two same-dir sessions          -> picker popup listing BOTH
  E) no sessions, .hexe.lua present -> layout confirm popup; NO starts plain
  F) a session in ANOTHER directory -> must NOT be offered

The invariant behind (F) is the one that broke before: candidates are filtered
to the current directory only.
"""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
DIR_A = os.path.join(SCRATCH, f"chooser-a-{os.getpid()}")
DIR_B = os.path.join(SCRATCH, f"chooser-b-{os.getpid()}")
DIR_C = os.path.join(SCRATCH, f"chooser-c-{os.getpid()}")
for d in (DIR_A, DIR_B, DIR_C):
    os.makedirs(d, exist_ok=True)

base_env = os.environ.copy()
base_env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(SCRATCH, "smoke-state"),
                 "TERM": "xterm-256color", "SHELL": "/bin/sh"})
base_env.pop("HEXE_SESSION", None)
base_env.pop("HEXE_PANE_UUID", None)
os.makedirs(base_env["XDG_STATE_HOME"], exist_ok=True)
LAYOUT_LUA = """local hexe = require("hexe")
return hexe.setup({ ses = { layouts = { hexe.layout("%s", {
  root = "%s",
  tabs = { hexe.tab("%s", { root = hexe.pane() }) },
}) } } })
"""

procs = []
log = open(os.path.join(SCRATCH, "smoke-chooser.raw"), "wb")


def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def spawn(argv, cwd, prompt=True):
    """Spawn a frontend. prompt=False sets HEXE_SKIP_LOCAL_CONFIG=1."""
    env = base_env.copy()
    if not prompt:
        env["HEXE_SKIP_LOCAL_CONFIG"] = "1"
    else:
        env.pop("HEXE_SKIP_LOCAL_CONFIG", None)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave,
                         env=env, cwd=cwd, start_new_session=True)
    os.close(slave)
    procs.append((p, master))
    return p, master


def drain(fd, seconds):
    """Read everything available for `seconds`, return the decoded text."""
    deadline = time.time() + seconds
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.15)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            log.write(chunk)
    log.flush()
    return buf.decode("utf-8", "replace")


def read_until(fd, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False, buf.decode("utf-8", "replace")
            if not chunk:
                return False, buf.decode("utf-8", "replace")
            buf += chunk
            log.write(chunk)
            if marker in buf:
                log.flush()
                return True, buf.decode("utf-8", "replace")
    log.flush()
    return False, buf.decode("utf-8", "replace")


def plain(text):
    """Strip escape sequences so popup body text can be matched."""
    text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", text)
    text = re.sub(r"\x1b\[[0-9;:?]*[ -/]*[@-~]", "", text)
    text = re.sub(r"\x1b[@-Z\\-_]", "", text)
    return text


def wait_for_text(fd, needle, timeout_s):
    """Accumulate output until `needle` shows up in the escape-stripped text."""
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            log.write(chunk)
            if needle in plain(buf.decode("utf-8", "replace")):
                log.flush()
                return True, plain(buf.decode("utf-8", "replace"))
    log.flush()
    return False, plain(buf.decode("utf-8", "replace"))


def shell_works(master, tag, timeout_s=20):
    """Prove a real pane shell is attached and running commands.

    Retries the write: right after a popup is answered the pane shell may not
    be up yet, and keystrokes sent before it exists are simply dropped.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        os.write(master, f"echo RDY_{tag}\r".encode())
        ok, _ = read_until(master, f"RDY_{tag}".encode(), 3)
        if ok:
            return True
    return False


def kill_fe(p, master):
    if p.poll() is None:
        os.kill(p.pid, signal.SIGKILL)
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    try:
        os.close(master)
    except OSError:
        pass


def fail(msg):
    print(f"FAIL: {msg}")
    cleanup()
    sys.exit(1)


def cleanup():
    for p, master in procs:
        if p.poll() is None:
            p.kill()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
        try:
            os.close(master)
        except OSError:
            pass
    for pid in pgrep(f"daemon --instance {INST}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


print(f"instance={INST} dirA={DIR_A} dirB={DIR_B} dirC={DIR_C}")

# ---------------------------------------------------------------- case A
# Nothing to offer: bare hexe must go straight to a working shell.
a_fe, a_master = spawn([HEXE], DIR_A)
time.sleep(2.5)
if a_fe.poll() is not None:
    fail("A: bare hexe exited immediately")
if not shell_works(a_master, "A"):
    fail("A: no popup expected, but never reached a usable shell")
text = plain(drain(a_master, 0.4))
if "Attach to session" in text or ".hexe.lua" in text:
    fail("A: a popup was shown with nothing to offer")
print("A: no candidates, no .hexe.lua -> plain session OK")

# Give that session a marker so an attach is provable.
os.write(a_master, b"export CH_VAR=ch$((40+2))\r")
time.sleep(0.4)
if not shell_works(a_master, "A2"):
    fail("A: marker setup failed")

# ---------------------------------------------------------------- case F/B
# One same-dir session now exists. Also start one in ANOTHER directory: it
# must never appear as a candidate.
b_other, b_other_master = spawn([HEXE, "mux", "new", "-n", "otherdir"], DIR_B, prompt=False)
time.sleep(2.5)
if b_other.poll() is not None:
    fail("F: session in the other directory didn't start")

b_fe, b_master = spawn([HEXE], DIR_A)
ok, text = wait_for_text(b_master, "Attach to session", 15)
if b_fe.poll() is not None:
    fail("B: bare hexe exited before showing the popup")
if not ok:
    fail(f"B: attach confirm popup not shown; saw: {text[-400:]!r}")
if "otherdir" in text:
    fail("F: a session from ANOTHER directory was offered as a candidate")
print("B: single same-dir candidate -> confirm popup shown")
print("F: session in another directory correctly NOT offered")

# Answer YES -> must attach and see the marker from the DIR_A session.
os.write(b_master, b"y")
deadline = time.time() + 20
ok = False
while time.time() < deadline and not ok:
    os.write(b_master, b"echo VAR_$CH_VAR\r")
    ok, _ = read_until(b_master, b"VAR_ch42", 3)
if not ok:
    fail("B: answered YES but did not attach (marker missing)")
print("B: YES -> attached to the existing session")

# The stolen frontend should have exited.
deadline = time.time() + 8
while time.time() < deadline and a_fe.poll() is None:
    time.sleep(0.2)
if a_fe.poll() is None:
    fail("B: stolen frontend did not exit")
kill_fe(a_fe, a_master)

# ---------------------------------------------------------------- case C
# Same setup, answer NO -> a fresh session, marker must NOT be present.
c_fe, c_master = spawn([HEXE], DIR_A)
ok, text = wait_for_text(c_master, "Attach to session", 15)
if not ok:
    fail(f"C: attach confirm popup not shown; saw: {text[-400:]!r}")
os.write(c_master, b"n")
time.sleep(2.0)
if not shell_works(c_master, "C"):
    fail("C: answered NO but never got a usable shell")
os.write(c_master, b"echo VAR_[$CH_VAR]\r")
ok, out = read_until(c_master, b"VAR_[]", 10)
if not ok:
    fail(f"C: NO should start a FRESH session, but the marker leaked: {out[-300:]!r}")
print("C: NO -> fresh plain session (no attach)")

# ---------------------------------------------------------------- case D
# Two same-dir sessions -> picker listing both.
d_fe, d_master = spawn([HEXE], DIR_A)
ok, text = wait_for_text(d_master, "Attach to session here", 15)
if d_fe.poll() is not None:
    fail("D: bare hexe exited before showing the picker")
if not ok:
    fail(f"D: picker popup not shown; saw: {text[-500:]!r}")
# Let the whole list paint before counting entries.
text += plain(drain(d_master, 1.0))
# Both candidates must be listed: count the "(N panes)" entries.
entries = re.findall(r"\(\d+ panes?\)", text)
if len(entries) < 2:
    fail(f"D: picker listed {len(entries)} candidate(s), expected 2; saw: {text[-500:]!r}")
if "otherdir" in text:
    fail("F: other-directory session leaked into the picker")
print(f"D: two same-dir candidates -> picker listed {len(entries)} entries")
# Escape out of the picker: with no .hexe.lua this lands on a plain session.
os.write(d_master, b"\x1b")
time.sleep(2.0)
if not shell_works(d_master, "D"):
    fail("D: cancelling the picker did not fall through to a plain session")
print("D: picker cancelled -> plain session")

kill_fe(d_fe, d_master)
kill_fe(c_fe, c_master)
kill_fe(b_fe, b_master)
kill_fe(b_other, b_other_master)
time.sleep(1.5)

# ---------------------------------------------------------------- case E
# A directory with NO sessions but a .hexe.lua -> level 2 popup. This needs its
# own directory: SIGKILLing a frontend leaves a DETACHED session record behind,
# so DIR_A still has attach candidates.
with open(os.path.join(DIR_C, ".hexe.lua"), "w") as f:
    f.write(LAYOUT_LUA % ("chooserlay", DIR_C, "ctab"))

e_fe, e_master = spawn([HEXE], DIR_C)
ok, text = wait_for_text(e_master, ".hexe.lua", 15)
if e_fe.poll() is not None:
    fail("E: bare hexe exited before showing the layout popup")
if not ok:
    fail(f"E: local-layout confirm popup not shown; saw: {text[-400:]!r}")
if "Attach to session" in text:
    fail("E: offered an attach when no same-dir session exists")
print("E: no candidates + .hexe.lua -> layout confirm popup shown")
os.write(e_master, b"n")
time.sleep(2.0)
if not shell_works(e_master, "E"):
    fail("E: declined the layout but never got a usable shell")
print("E: NO -> plain session")

kill_fe(e_fe, e_master)
time.sleep(1.0)

# ---------------------------------------------------------------- case G
# Same, but ACCEPT the layout: the .hexe.lua must actually be applied.
DIR_G = os.path.join(SCRATCH, f"chooser-g-{os.getpid()}")
os.makedirs(DIR_G, exist_ok=True)
with open(os.path.join(DIR_G, ".hexe.lua"), "w") as f:
    f.write(LAYOUT_LUA % ("laidout", DIR_G, "gtab"))

g_fe, g_master = spawn([HEXE], DIR_G)
ok, text = wait_for_text(g_master, ".hexe.lua", 15)
if not ok:
    fail(f"G: local-layout confirm popup not shown; saw: {text[-400:]!r}")
os.write(g_master, b"y")
ok, text = wait_for_text(g_master, "local layout loaded", 15)
if not ok:
    fail(f"G: accepted the layout but it was never applied; saw: {text[-400:]!r}")
if not shell_works(g_master, "G"):
    fail("G: layout loaded but no usable shell")
print("G: YES -> .hexe.lua layout applied, shell usable")

cleanup()
print("PASS: startup chooser (attach level + layout level, popup UI, cwd-scoped)")
