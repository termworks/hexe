#!/usr/bin/env python3
"""Hostile input against the palette OSC parser, through the real ingest path.

The unit tests feed `applyOsc` well-formed payloads. This feeds a pane's stdout
the things a real program emits when it is buggy, malicious, or simply not
speaking this protocol: truncated sequences, 64 KiB names, embedded NULs, a
thousand `use` pushes with no matching `end`, ten thousand distinct namespaces,
numbers that do not fit in the types they land in.

Nothing here asserts a colour. The claim is narrower and harder: after all of
it, the frontend is still alive, still drawing, still answering the CLI, and has
not grown without bound. A parser bug in this path is reachable by any program
running in any pane, so "it survives garbage" is the property worth pinning.

The corpus is written to a file and `cat`ed inside the pane, so the bytes reach
the parser exactly as written - no shell quoting in the way, and the sequences
land split across read() boundaries the way real output does.
"""
import atexit
import fcntl, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smk{os.getpid()}"
WD = os.path.join(SCRATCH, f"palfuzz{os.getpid()}")
CF = os.path.join(WD, "config")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)

ROWS, COLS = 24, 100

with open(os.path.join(CF, "hexe", "init.lua"), "w") as fh:
    fh.write(
        "local hexe = require('hexe')\n"
        "return hexe.setup({ palette = { namespaces = true } })\n"
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


# ------------------------------------------------------------------- corpus
ST = b"\x1b\\"
BEL = b"\x07"


def osc(body, term=ST, intro=b"\x1b]"):
    return intro + body + term


def corpus():
    out = bytearray()
    add = out.extend

    # Structurally broken frames.
    add(osc(b"1330"))                      # verb missing entirely
    add(osc(b"1330;"))                     # empty verb
    add(osc(b"1330;;;;;;"))                # nothing but separators
    add(osc(b"1330;nosuchverb;a;b"))       # unknown verb
    add(osc(b"1330;USE;prompt"))           # wrong case
    add(osc(b"1330;use"))                  # use with no name
    add(osc(b"1330;set"))                  # set with no name and no pairs
    add(osc(b"1330;set;prompt"))           # name but no pairs
    add(osc(b"1330;drop"))
    add(osc(b"1330;reset"))
    add(b"\x1b]1330;use;never-terminated")  # no ST at all, then more data follows
    add(b"\n")
    add(osc(b"1330;use;afterbroken"))
    add(osc(b"1330;end", term=BEL))         # BEL terminator instead of ST
    add(osc(b"1330;end", intro=b"\x9d"))    # C1 OSC introducer

    # Names that are not names.
    add(osc(b"1330;use;" + b"N" * 65536))               # 64 KiB name
    add(osc(b"1330;use;has\x00nul"))
    add(osc(b"1330;use;\xff\xfe\xfd invalid utf8"))
    add(osc(b"1330;use;" + b"\x1b" * 32))               # ESC inside the payload
    add(osc(b"1330;use;"))                              # empty name
    add(osc(b"1330;set;" + b"M" * 65536 + b";1=#ff0000"))

    # Values that do not fit where they land.
    for bad in (b"999999999999999999999", b"-1", b"256", b"0x1f", b"1e9", b"",
                b"+7", b" 7 ", b"7.5", b"NaN", b"\x00"):
        add(osc(b"1330;set;fz;" + bad + b"=#ff0000"))
        add(osc(b"1330;set;fz;1=" + bad))
    for bad in (b"#", b"#f", b"#ff", b"#fffff", b"#gggggg", b"##ffffff",
                b"#ffffffffffffffff", b"rgb:1/2/3", b"red", b"#-10000"):
        add(osc(b"1330;set;fz;1=" + bad))

    # Pairs that are not pairs.
    add(osc(b"1330;set;fz;noequalssign"))
    add(osc(b"1330;set;fz;=#ff0000"))
    add(osc(b"1330;set;fz;1==#ff0000"))
    add(osc(b"1330;set;fz;1=#ff0000=#00ff00"))

    # One frame carrying far more pairs than any real caller sends.
    add(osc(b"1330;set;wide;" + b";".join(b"%d=#0a0b0c" % (i % 256) for i in range(4000))))

    # Unbalanced stack in both directions.
    for i in range(1000):
        add(osc(b"1330;use;deep%d" % i))
    for _ in range(1000):
        add(osc(b"1330;end"))
    for _ in range(200):
        add(osc(b"1330;end"))               # popping an already empty stack

    # Far more namespaces than the table can be expected to hold.
    for i in range(10000):
        add(osc(b"1330;set;ns%d;1=#010203" % i))

    # Verbs against namespaces that never existed, and re-dropping.
    for verb in (b"drop", b"reset", b"use"):
        add(osc(b"1330;" + verb + b";ghost"))
        add(osc(b"1330;" + verb + b";ghost"))

    # Capability query spam, and a reply forged by the pane (term->app direction).
    for _ in range(200):
        add(osc(b"1330;ask"))
    add(osc(b"1330;have;1330;200"))

    # Neighbouring OSC numbers must not be swallowed as palette traffic.
    for n in (b"1329", b"1331", b"133", b"13300", b"4", b"104", b"11", b"12"):
        add(osc(n + b";0;?"))

    return bytes(out)


blob = corpus()
with open(os.path.join(WD, "corpus.bin"), "wb") as fh:
    fh.write(blob)

# ------------------------------------------------------------------- frontend
seen = bytearray()
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", "palfuzz"], stdin=slave, stdout=slave,
                      stderr=slave, env=env, cwd=WD, start_new_session=True)
os.close(slave)
procs.append(fe)


def drain(fd):
    while True:
        try:
            chunk = os.read(fd, 65536)
            if not chunk:
                return
        except OSError:
            return
        seen.extend(chunk)


threading.Thread(target=drain, args=(master,), daemon=True).start()
time.sleep(4.0)
if fe.poll() is not None:
    fail(f"frontend exited rc={fe.returncode} before the fuzz even started")


def responsive(tag, timeout=8.0, clear=False):
    """Round-trip a command through the pane's shell.

    `clear` first sends an interrupt and a bare newline. Some of the corpus is
    made of capability queries, and a query gets an answer: hexe writes it into
    the pane's INPUT, exactly as any terminal answers DSR or OSC 4. Two hundred
    queries means two hundred answers sitting in the shell's line buffer, so the
    next command line is garbage — through no fault of the parser. Clearing it
    is what a user does, and what the property under test actually needs: that
    the pane RECOVERS, rather than being blinded for good.
    """
    if clear:
        os.write(master, b"\x03\n")
        time.sleep(1.5)
    del seen[:]
    os.write(master, f"echo {tag}\n".encode())
    deadline = time.time() + timeout
    while time.time() < deadline:
        # Twice: once echoed as it is typed, once printed by the shell that ran it.
        if bytes(seen).count(tag.encode()) >= 2:
            return True
        time.sleep(0.2)
    return False


def rss_kb(pid):
    try:
        with open(f"/proc/{pid}/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


if not responsive("FUZZBASE", timeout=20.0, clear=True):
    fail("pane was not responsive before the fuzz; harness problem, not a product bug")
before_kb = rss_kb(fe.pid)
print(f"baseline: pane responsive, frontend RSS {before_kb} KiB, "
      f"corpus {len(blob) // 1024} KiB")

# ------------------------------------------------------------------ the fuzz
os.write(master, b"cat corpus.bin\n")
time.sleep(12.0)

if fe.poll() is not None:
    fail(f"frontend died while parsing the corpus (rc={fe.returncode}) — a pane can "
         f"kill the multiplexer with malformed OSC 1330")

if not responsive("FUZZALIVE", timeout=15.0, clear=True):
    fail("the pane never recovered after the corpus — a malformed sequence left the "
         "output parser capturing forever, so nothing reaches the screen again")
print("fuzz: frontend alive and still echoing after the full corpus")

# Repeat: a leak or an unbounded table shows up on the second pass, not the first.
for i in range(3):
    os.write(master, b"cat corpus.bin\n")
    time.sleep(8.0)
    if fe.poll() is not None:
        fail(f"frontend died on corpus pass {i + 2} (rc={fe.returncode})")
if not responsive("FUZZALIVE2", timeout=15.0, clear=True):
    fail("frontend stopped echoing after repeated passes")

after_kb = rss_kb(fe.pid)
print(f"fuzz: survived 4 passes, frontend RSS {before_kb} -> {after_kb} KiB")

# 10k namespaces x 4 passes must not translate into unbounded retention. The
# bound is deliberately loose: this is a runaway detector, not a budget.
if before_kb and after_kb and after_kb > before_kb + 262144:
    fail(f"frontend RSS grew {after_kb - before_kb} KiB across the fuzz — palette "
         f"state is retained without bound")

# --------------------------------------------- a truncated OSC must not blind
#
# Kept apart from the corpus on purpose: inside it, the ESC \ of a LATER
# sequence terminates an earlier unterminated one, so the corpus quietly heals
# itself and proves nothing. Alone, `\033]0;title` with no terminator is the
# real case - a program killed mid-write, or a printf missing its ST. Capture
# diverts every byte away from the VT, so without an abort rule the pane is
# blind from that byte on and only a detach/reattach brings it back.
with open(os.path.join(WD, "unterm.bin"), "wb") as fh:
    fh.write(b"\x1b]0;title")

os.write(master, b"cat unterm.bin\n")
time.sleep(3.0)
if fe.poll() is not None:
    fail(f"frontend died on an unterminated OSC (rc={fe.returncode})")
if not responsive("UNTERM", timeout=15.0, clear=True):
    fail("an unterminated OSC blinded the pane: every byte after it is still being "
         "captured, so nothing the shell prints reaches the screen again")
print("truncated: an unterminated OSC is abandoned and the pane keeps rendering")

# ------------------------------------------------------- state still coherent
r = subprocess.run([HEXE, "palette", "list"], env=env, cwd=WD,
                   capture_output=True, text=True, timeout=20)
if r.returncode != 0:
    fail(f"`hexe palette list` failed rc={r.returncode} after the fuzz: "
         f"{(r.stderr or r.stdout).strip()[:300]}")
print("fuzz: `hexe palette list` still answers")

if not responsive("FUZZDONE", timeout=15.0, clear=True):
    fail("frontend stopped echoing after the CLI round trip")

cleanup()
print("PASS: the palette OSC parser survives hostile input from a pane")
