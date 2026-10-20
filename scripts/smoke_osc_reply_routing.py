#!/usr/bin/env python3
"""Live check: an OSC colour reply reaches the pane that asked, and no other.

Regression target: a reply nobody was waiting for was written into the focused
pane as input, so `]4;198;rgb:6e6e/ffff/5757` appeared on a shell's command line
as text the user never typed. The host volunteers such reports, and hexe's own
palette refresh asks 258 questions at once whose answers outlive a flat
deadline, so there was no shortage of unowned replies to misdeliver.

Two phases, because the negative on its own proves nothing:

  unsolicited  nothing asked; the reply must NOT reach the pane
  solicited    the pane asks `OSC 4;198;?` first; the reply MUST reach it

A build that drops every reply passes phase 1 and fails phase 2. A build with
the old focused-pane fallback passes phase 2 and fails phase 1.
"""
import atexit
import fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"oscroute{os.getpid()}")
os.makedirs(WD, exist_ok=True)

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
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


def hexe_cli(*args):
    return subprocess.run([HEXE, *args], env=env, cwd=WD, capture_output=True, text=True)


seen = bytearray()


def drain(fd):
    while True:
        try:
            chunk = os.read(fd, 65536)
            if not chunk:
                return
        except OSError:
            return
        seen.extend(chunk)


# The pane runs this: it records every byte it is handed, so the assertion is on
# what the pane's program actually received rather than on what the screen shows.
READER = os.path.join(WD, "reader.py")
with open(READER, "w") as fh:
    fh.write(
        "import os, select, signal, sys, termios, tty\n"
        "out = open(sys.argv[1], 'wb', buffering=0)\n"
        "fd = sys.stdin.fileno()\n"
        "old = termios.tcgetattr(fd)\n"
        "tty.setraw(fd)\n"
        "signal.alarm(60)\n"
        "out.write(b'READY\\n')\n"
        "asked = False\n"
        "try:\n"
        "    while True:\n"
        "        r, _, _ = select.select([fd], [], [], 0.2)\n"
        "        if r:\n"
        "            b = os.read(fd, 4096)\n"
        "            if not b: break\n"
        "            out.write(b)\n"
        "        if not asked and os.path.exists(sys.argv[2]):\n"
        # The pane's own query. From here a reply is owed to THIS pane.
        "            sys.stdout.write('\\x1b]4;198;?\\x1b\\\\'); sys.stdout.flush()\n"
        "            asked = True\n"
        "            out.write(b'\\nASKED\\n')\n"
        # Raw mode disables ISIG, so Ctrl-C never reaches this as a signal and a
        # file is the only way to ask it to let go of the tty.
        "        if os.path.exists(sys.argv[3]):\n"
        "            out.write(b'\\nBYE\\n')\n"
        "            break\n"
        "finally:\n"
        "    termios.tcsetattr(fd, termios.TCSADRAIN, old)\n"
    )

LOG = os.path.join(WD, "hexe.log")
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
# --logfile implies debug level, which is how phase 3 checks that the mechanism
# fired rather than that the reply merely failed to show up.
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "oscroute", "--logfile", LOG],
                      stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave); procs.append(fe)
threading.Thread(target=drain, args=(master,), daemon=True).start()
time.sleep(4.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode}")

os.write(master, b"stty -echo; echo WARM\r")
deadline = time.time() + 30
while time.time() < deadline and b"WARM" not in bytes(seen):
    time.sleep(0.2)
if b"WARM" not in bytes(seen):
    fail("pane never became responsive")

GOT = os.path.join(WD, "received.bin")
TRIGGER = os.path.join(WD, "ask-now")
QUIT = os.path.join(WD, "let-go")
os.write(master, f"python3 {READER} {GOT} {TRIGGER} {QUIT}\r".encode())


def wait_for(marker, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if os.path.exists(GOT) and marker in open(GOT, "rb").read():
            return True
        time.sleep(0.2)
    return False


if not wait_for(b"READY", 30):
    fail("the reader never started")
time.sleep(1.0)

# The exact bytes a terminal sends when answering OSC 4 with `?`.
REPLY = b"\x1b]4;198;rgb:6e6e/ffff/5757\x1b\\"
# What a terminal sends when answering OSC 11 with `?` -- the background colour
# an agentic CLI asks for to choose a light or dark theme.
REPLY_BG = b"\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\"

# ---- phase 1: nobody asked -------------------------------------------------
before = open(GOT, "rb").read()
os.write(master, REPLY)
time.sleep(2.0)
phase1 = open(GOT, "rb").read()[len(before):]
print("unsolicited, pane received:", repr(phase1[:80]), flush=True)
if b"rgb:" in phase1 or b"4;198" in phase1:
    fail("a reply nobody asked for was written into the pane — this is the "
         "stray `]4;198;rgb:...` on the command line")
print("unsolicited: dropped, as it must be", flush=True)

# ---- phase 2: the pane asks, so the reply is owed to it ---------------------
open(TRIGGER, "w").close()
if not wait_for(b"ASKED", 30):
    fail("the reader never sent its own query")
time.sleep(0.5)
before = open(GOT, "rb").read()
os.write(master, REPLY)
time.sleep(2.0)
phase2 = open(GOT, "rb").read()[len(before):]
print("solicited, pane received:  ", repr(phase2[:80]), flush=True)
if b"rgb:" not in phase2 and b"4;198" not in phase2:
    fail("the pane asked and was never given the answer — dropping every reply "
         f"is not the fix either; got {phase2!r}")
print("solicited: delivered to the pane that asked", flush=True)

# ---- setup for the phases that read the screen ------------------------------
#
# The reader has to let go of the tty, and echo has to be ON: from here the
# question is whether the bytes show up on the command line the way the user saw
# them, and with `stty -echo` the shell swallows them silently and every phase
# below passes without testing anything.
open(QUIT, "w").close()
if not wait_for(b"BYE", 20):
    fail("the reader never let go of the tty")
time.sleep(1.0)
os.write(master, b"stty echo; echo ECHOON\r")
deadline = time.time() + 20
while time.time() < deadline and b"ECHOON" not in bytes(seen):
    time.sleep(0.2)
if b"ECHOON" not in bytes(seen):
    fail("could not turn echo back on, so a clean screen would prove nothing")

QUERY = ("python3 -c 'import sys; "
         "sys.stdout.write(\"\\033]11;?\\033\\\\\"); sys.stdout.flush()'")

# ---- phase 3: the asker exits and the shell marks nothing -------------------
#
# Every shell without integration. Nothing in the pane's output says the program
# is gone, so the answer is refused one layer down: the pod asks the kernel
# whether any program holds the pty, and the shell holding it means the asker has
# exited. Phases 2 and 5 are the control that answers still get delivered.
#
# This runs BEFORE any OSC 133 appears: the pod exempts a pane whose shell marks
# its prompts, and that exemption is sticky for the pod's life.
mark = len(seen)
os.write(master, QUERY.encode() + b"\r")
time.sleep(0.5)
os.write(master, REPLY_BG)
time.sleep(2.5)
if b"rgb:1c1c" in bytes(seen[mark:]):
    print("      screen tail:", repr(bytes(seen[mark:])[-200:]))
    fail("with no shell integration the answer to a dead program still reached "
         "the shell's command line")
print("asker exited, no marks: refused at the pty, nothing leaked", flush=True)

# ---- phase 3b: a colour SET injected as input is none of our business -------
#
# `hexe.send` writes bytes straight into a pane, and a config or plugin may well
# push a palette sequence through it. A set uses the same OSC codes as an answer
# and differs only in the value: `#rrggbb` rather than the `rgb:` form a terminal
# answers in. Refusing one would be the check at the pty swallowing input nobody
# asked it to touch.
#
# Deliberately here, where phase 3 just proved the check is live and no prompt
# mark has exempted this pane yet -- so a wrong match would be caught.
mark = len(seen)
SET = "\u001b]4;1;#ff0000\u001b\\"
sent = hexe_cli("api", "send", json.dumps(SET))
if sent.returncode != 0:
    fail(f"could not inject input through hexe.send: {sent.stderr.strip()}")
time.sleep(2.0)
if b"4;1;#ff0000" not in bytes(seen[mark:]):
    print("      screen tail:", repr(bytes(seen[mark:])[-200:]))
    fail("a colour SET injected into the pane was swallowed — the reply check is "
         "matching more than replies")
print("injected colour set: delivered untouched", flush=True)

# ---- phase 4: the asker exits and the shell DOES mark its prompts ------------
#
# What an agentic CLI does: Claude Code and Codex ask for the background colour
# at startup to pick a theme. If one exits before the answer lands, the pane
# lives on and the shell inherits it. `133;C` ... `133;D` `133;A` is the shape
# oslo emits around a command; /bin/sh prints nothing, so they are explicit here.
mark = len(seen)
mark_log = os.path.getsize(LOG) if os.path.exists(LOG) else 0
os.write(master, (f"printf '\\033]133;C\\033\\\\'; {QUERY}; "
                  f"printf '\\033]133;D;0\\033\\\\\\033]133;A;aid=1\\033\\\\'").encode() + b"\r")
# A real terminal answers in milliseconds, so the reply must land while the query
# is still inside its deadline. Sleeping past QUERY_TIMEOUT_MS would let expiry
# drop it and this phase would pass for the wrong reason.
time.sleep(0.5)
os.write(master, REPLY_BG)
time.sleep(2.5)

screen = bytes(seen[mark:])
with open(LOG, "rb") as fh:
    fh.seek(mark_log)
    logtail = fh.read().decode("utf-8", "replace")

if b"rgb:1c1c" in screen:
    print("      screen tail:", repr(screen[-200:]))
    fail("a reply outlived the program that asked for it and was still handed "
         "to the pane, where the shell reads it as typed text and runs it on "
         "the next newline")
# A clean screen is not enough on its own: it also happens when nothing ever
# asked. Something has to be on record as having actively refused the answer.
#
# Which layer refuses it depends on where the pty chunk boundaries fall. When the
# query and the `133;D` mark land in one chunk, the mark clears the pane's queue
# before the frontend registers anything, so the answer arrives unowned and the
# frontend drops it. When they land in separate chunks the query is registered
# first and the mark retires it. Both are the fix working; pinning one of them
# makes this phase fail on a chunk boundary rather than on a regression.
refusals = [ln.strip() for ln in logtail.splitlines()
            if "prompt mark dropped" in ln or "unowned OSC reply" in ln]
if not refusals:
    fail("the screen is clean but nothing in hexe refused the answer, so this "
         "phase is passing for some other reason")
print("      via:", refusals[-1].split("] ", 1)[-1])
print("asker exited: the prompt mark retired its query, reply dropped", flush=True)

# ---- phase 4b: the answer BEATS the prompt mark ------------------------------
#
# The ordering that actually happens. A terminal answers a colour question in
# about a millisecond, while a shell has to reap its child and render a prompt
# before it emits `133;D`/`133;A` -- tens of milliseconds. So the answer arrives
# while hexe still believes a command is running, and retiring the query at the
# mark is too late to help.
#
# Phase 4 sent the marks first and therefore never exercised this. It is the
# real case for any shell with prompt marks, which is to say the common one.
mark = len(seen)
os.write(master, (f"printf '\\033]133;C\\033\\\\'; {QUERY}").encode() + b"\r")
time.sleep(0.5)
os.write(master, REPLY_BG)          # answer first ...
time.sleep(0.3)
os.write(master, b"printf '\\033]133;D;0\\033\\\\\\033]133;A;aid=1\\033\\\\'\r")  # ... mark after
time.sleep(2.0)
if b"rgb:1c1c" in bytes(seen[mark:]):
    print("      screen tail:", repr(bytes(seen[mark:])[-220:]))
    fail("the answer arrived before the prompt mark and reached the shell's "
         "command line — retiring at the mark is too late, and the pty check "
         "that would have caught it is switched off for panes that mark prompts")
print("answer before the mark: still refused", flush=True)

# ---- phase 5: the shell itself asks, on a shell that marks its prompts ------
#
# A shell that picks its colours from the terminal's background asks on its own
# behalf, with no program in between, and `printf` being a /bin/sh builtin runs
# in the shell's own process group. From the pty that looks exactly like phase
# 3 -- the shell holds the terminal either way -- so the only thing that tells
# them apart is the prompt marks phase 4 established. With them, the frontend
# retires a dead program's questions precisely and anything still outstanding
# really was the shell's, so the pod stands aside and the answer is delivered.
#
# Asserted on hexe's own record rather than on the screen. The answer goes into
# the shell's input, and bash's readline treats a leading `ESC ]` as a meta key
# sequence, so whether the bytes are echoed visibly depends on the line state --
# which makes a screen check here report the shell's rendering, not hexe's
# behaviour.
mark_log = os.path.getsize(LOG)
os.write(master, b"printf '\\033]11;?\\033\\\\'\r")
time.sleep(0.4)
os.write(master, REPLY_BG)
time.sleep(2.0)
with open(LOG, "rb") as fh:
    fh.seek(mark_log)
    logtail = fh.read().decode("utf-8", "replace")
if "handed to the pane that asked" not in logtail:
    for ln in logtail.splitlines():
        if "colour" in ln or "OSC" in ln or "prompt mark" in ln:
            print("      log:", ln.strip())
    fail("the shell asked for the background colour on its own behalf and was "
         "not given the answer — the checks are refusing replies they are "
         "supposed to deliver")
print("shell's own query: answered", flush=True)


cleanup()
print("SMOKE PASS: OSC replies reach the asking pane only")
