#!/usr/bin/env python3
"""Colour answers must reach whoever asked, and nobody else.

Reproduces `lule_colors`: a script that writes ~262 OSC *sets*
(`ESC ] 4 ; N ; #rrggbb ESC \\`) into every `/dev/pts/*`. Under hexe those sets
pass through each pane's VT to hexe's own stdout, so the outer terminal
recolours too -- and that part is wanted.

What went wrong is what hexe did next, in two places:

  1. a set was read as "this colour is now unknown", so being TOLD 262 colours
     made hexe ask the host 258 questions about colours it had just been given,
     and left its cache empty in between;
  2. a pane's own colour query was relayed to the host and answered a round trip
     later. Askers have deadlines -- oslo waits 100 ms for the background colour
     (`TIMEOUT_MS` in its `term/negotiate.rs`, asserted no larger) -- and over
     ssh, or behind a queue of other queries, the answer missed it. The asker
     stopped reading, and the late answer landed on its command line, where the
     shell ran `4` as a command on the next newline.

A relayed answer that nobody is waiting for also used to be routed by the
pane-target queue, which holds only a COUNT of outstanding OSC queries per pane
and not what each asked for -- so it could be handed to a pane waiting for a
CLIPBOARD reply.

This test is the host terminal: it owns the pty, so it sees hexe's queries and
answers them, exactly as a real terminal would.
"""
import atexit, fcntl, json, os, pty, re, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"oscleak{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSION = "oscleak"

open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    "local hexe = require('hexe')\nreturn hexe.setup({})\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1",
            "HEXE_MAX_CONNECTIONS_PER_MINUTE": "256"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET",
           "HEXE_API_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

procs, failures = [], []
queries_seen = [0]
query_log = []
replies_sent = [0]


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
signal.signal(signal.SIGALRM, lambda *_: (print("FAIL: timed out"), sys.stdout.flush(),
                                          cleanup(), os._exit(1)))
signal.alarm(300)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush(); cleanup(); sys.exit(1)


def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)


def hexe(*args, timeout=40):
    return subprocess.run([HEXE] + list(args), capture_output=True, text=True,
                          env=env, cwd=WD, timeout=timeout)


def api(call, *json_args):
    p = hexe("api", call, *json_args, "--session", SESSION)
    if p.returncode != 0:
        fail(f"hexe api {call} failed: {p.stderr.strip()[:180]}")
    return json.loads(p.stdout)["result"]


def socket_for(s):
    for root, _d, files in os.walk(RUN):
        if f"api@{s}.sock" in files:
            return os.path.join(root, f"api@{s}.sock")
    return None


# --------------------------------------------------- we are the host terminal
#
# hexe's stdout comes to us and its stdin goes from us, so we answer its colour
# queries the way a real terminal does. Without answering, the bug cannot
# happen at all: the leak is made of the ANSWERS.
QUERY_RE = re.compile(rb"\x1b\]((?:4;\d+)|10|11|12);\?(?:\x1b\\|\x07)")


def host_terminal(master):
    buf = b""
    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        # Answer every colour query, in the reply form a terminal uses:
        # four hex digits per channel. This is the text that used to leak.
        out = b""
        consumed = 0
        for m in QUERY_RE.finditer(buf):
            what = m.group(1)
            queries_seen[0] += 1
            query_log.append((time.perf_counter(), what.decode()))
            consumed = m.end()
            if what.startswith(b"4;"):
                idx = what.split(b";")[1].decode()
                out += b"\x1b]4;" + idx.encode() + b";rgb:6e6e/ffff/5757\x1b\\"
            else:
                out += b"\x1b]" + what + b";rgb:2222/5050/1818\x1b\\"
        if out:
            replies_sent[0] += out.count(b"\x1b]")
            try:
                os.write(master, out)
            except OSError:
                return
        # Drop what was answered, and of the rest keep only enough to hold a
        # query that straddled this read. Rescanning answered bytes would
        # answer them again, which looks exactly like hexe asking twice.
        buf = buf[max(consumed, len(buf) - 64):]


m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", SESSION, "--log", "debug", "--logfile", os.path.join(WD, "fe.log")], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=host_terminal, args=(m,), daemon=True).start()

deadline = time.time() + 30
while time.time() < deadline and socket_for(SESSION) is None:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    time.sleep(0.3)
if socket_for(SESSION) is None:
    fail("session never bound its socket")
time.sleep(2.5)

rows = api("panes")
if not rows:
    fail("no panes")
PANE = rows[0]["uuid"]
print(f"session {SESSION}, pane {PANE[:8]}")


def pane_text():
    p = hexe("api", "screen_text", json.dumps(PANE), "--session", SESSION)
    if p.returncode != 0:
        return ""
    try:
        return json.loads(p.stdout)["result"] or ""
    except (ValueError, KeyError):
        return ""


def send(text):
    hexe("terminal", "send", "--uuid", PANE, "--enter", text)


# --------------------------------------------------------------------- phase 1
print("\nphase 1: put the pane in the state that made the answers land on it")
# A pane waiting on a NON-colour OSC reply. This is what fills the pane-target
# queue, and the queue is what the leaked colour answers were handed to. OSC 52
# with `?` asks the terminal for the clipboard; nothing here ever answers it, so
# the pane stays waiting -- which is exactly the real case of a program that
# asked and then stopped reading.
send("printf '\\033]52;c;?\\033\\\\'")
time.sleep(1.5)

# --------------------------------------------------------------------- phase 2
print("\nphase 2: replay lule_colors — 262 OSC sets into the pane's pty")
# Byte for byte what the script writes: `ESC ] 4 ; N ; #rrggbb ESC \` sets, no
# queries. Each one carries its value, and the same bytes go on to the host, so
# hexe has been told what the host's palette is about to be -- it has no reason
# to ask, and asking is what used to fill the stream with loose answers.
seq = b"".join([
    b"\x1b]10;#f0fbf4\x1b\\", b"\x1b]11;#0a120d\x1b\\", b"\x1b]12;#7ee09f\x1b\\",
    b"\x1b]13;#0a120d\x1b\\", b"\x1b]17;#7ee09f\x1b\\", b"\x1b]19;#0a120d\x1b\\",
] + [b"\x1b]4;%d;#%02x%02x%02x\x1b\\" % (i, i, 255 - i, (i * 7) % 256) for i in range(256)])

# Written through the pane's own shell, which is how the script's `cat
# sequences > /dev/pts/N` reaches a pane: as output from inside it.
with open(os.path.join(WD, "seq.bin"), "wb") as fh:
    fh.write(seq)
at_startup = queries_seen[0]
send(f"cat {os.path.join(WD, 'seq.bin')}")

# Wait for the queries the sets provoke to stop arriving, rather than for a
# threshold the startup burst already meets.
settled = queries_seen[0]
deadline = time.time() + 25
while time.time() < deadline:
    time.sleep(1.0)
    if queries_seen[0] == settled and queries_seen[0] > at_startup:
        break
    settled = queries_seen[0]
from_sets = queries_seen[0] - at_startup
print(f"  {at_startup} queries at startup, {from_sets} provoked by the 262 sets "
      f"({replies_sent[0]} replies sent in all)")
check(from_sets == 0,
      f"being TOLD 262 colours made hexe ask no questions ({from_sets} asked)")

# --------------------------------------------------------------------- phase 3
print("\nphase 3: no colour answer may appear as text in the pane")
time.sleep(3.0)
txt = pane_text()
leaks = re.findall(r"\]\s*4;\d+;rgb:[0-9a-f/]+", txt) + re.findall(r"rgb:[0-9a-f]{4}/", txt)
if leaks:
    print("  leaked fragments: " + ", ".join(sorted(set(leaks))[:4]))
    at = txt.find("rgb:")
    print("  context: " + repr(txt[max(0, at - 90):at + 60]))
check(not leaks, f"no colour reply leaked into the pane ({len(leaks)} fragments)")
# The shell would also try to RUN a leaked reply on the next newline.
check("command not found" not in txt,
      "and nothing was executed as a command")

# --------------------------------------------------------------------- phase 4
print("\nphase 4: the pane still works, and real colour queries still answer")
send("echo STILL_FINE_$((6*7))")
deadline = time.time() + 20
ok_alive = False
while time.time() < deadline:
    if "STILL_FINE_42" in pane_text():
        ok_alive = True
        break
    time.sleep(0.5)
check(ok_alive, "the pane still runs commands after the recolour storm")

# --------------------------------------------------------------------- phase 5
print("\nphase 5: a pane's colour query is answered from cache, not relayed")
# This is oslo's case, run the way oslo runs it. oslo asks for the background
# colour and waits 100 ms (TIMEOUT_MS in its term/negotiate.rs, asserted <= 100)
# before it stops reading. Relaying the question to the host and the answer back
# is a round trip that a local terminal never makes -- and over ssh, or behind a
# queue of other queries, it does not fit in 100 ms. The answer then arrives
# after oslo has stopped reading and lands on its command line.
#
# The reader below is the real test, not `rgb:` in the pane text: an answer that
# shows up as pane TEXT is the leak phase 3 forbids. A genuine asker reads in
# raw mode and consumes its own answer, leaving no trace.
READER = os.path.join(WD, "ask_bg.py")
with open(READER, "w") as fh:
    fh.write(
        "import os, select, sys, termios, tty\n"
        "fd = os.open('/dev/tty', os.O_RDWR)\n"
        "old = termios.tcgetattr(fd)\n"
        "tty.setraw(fd)\n"
        "try:\n"
        "    os.write(fd, b'\\x1b]11;?\\x1b\\\\')\n"
        "    r, _, _ = select.select([fd], [], [], 0.1)\n"
        "    data = os.read(fd, 256) if r else b''\n"
        "finally:\n"
        "    termios.tcsetattr(fd, termios.TCSADRAIN, old)\n"
        "print('OSC11_' + ('OK' if b'rgb:' in data else 'TIMEOUT'))\n")

# hexe polls the colours it actually uses on a timer of its own, so an idle
# window is measured first: a query during the asker's window only counts
# against hexe if it is more than that, or asks for the background.
idle_from = len(query_log)
time.sleep(4.0)
idle = [what for _t, what in query_log[idle_from:]]

before = queries_seen[0]
send(f"{sys.executable} -I {READER}")

verdict = None
deadline = time.time() + 20
while time.time() < deadline:
    txt = pane_text()
    if "OSC11_OK" in txt:
        verdict = "OK"
        break
    if "OSC11_TIMEOUT" in txt:
        verdict = "TIMEOUT"
        break
    time.sleep(0.3)

asked = [what for _t, what in query_log[-(queries_seen[0] - before):]] if queries_seen[0] > before else []
print(f"  idle window asked {idle or 'nothing'}; the asker's window asked "
      f"{asked or 'nothing'}; the asker got {verdict or 'no verdict'}")
# A deadline check alone would not catch a relay here: on this machine the
# round trip to the host fits inside 100 ms. It catches a colour answer that is
# dropped instead of delivered; the relay is caught by the count below.
check(verdict == "OK", "an asker with a 100 ms deadline got its answer")
# The asker asked for the background. If hexe relayed it rather than answering
# from cache, an `11` query shows up here that the idle window did not have.
relayed_bg = asked.count("11") - idle.count("11")
check(relayed_bg <= 0,
      f"and the background query was answered from cache, not relayed ({relayed_bg} relayed)")

# And the late answer to a relayed query must not land on the shell either.
time.sleep(1.5)
tail = pane_text()
check("rgb:" not in tail.replace("OSC11_OK", ""),
      "no colour answer reached the shell as text")

print()
if failures:
    print(f"FAIL: {len(failures)} check(s) failed")
    for f in failures:
        print(f"  - {f}")
    sys.stdout.flush(); cleanup(); sys.exit(1)
print("PASS: a pywal-style recolour leaks no colour answers into a pane")
sys.stdout.flush(); cleanup()
