#!/usr/bin/env python3
"""`hexe terminal read`: a pane's text, answered by the pod.

Addressed and reached exactly like `send` — resolved through SES, served by the
pod — so the claims that need a live pane are:

  * `-n N` returns N lines of content, not N rows counted from a blank bottom.
  * with OSC 133 marks and no flag, it returns the LAST COMMAND'S output and
    nothing else: not the prompt, not the command before it.
  * `-c N` spans N commands, oldest first.
  * it works on a DETACHED session, because the pod holds the ring. This is the
    whole reason the read lives in the pod rather than the frontend.
  * a pane with no marks and no `-n` is an error naming `-n`, not a screenful
    passed off as a command's output.

The marks are produced by feeding real OSC 133 sequences through the pane's own
shell, so this exercises the same path a shell-integrated prompt takes.
"""
import atexit, fcntl, json, os, pty, signal, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"read{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSION = "reader"

open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    "local hexe = require('hexe')\nreturn hexe.setup({})\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1"})
for _k in ("HEXE_SESSION", "HEXE_PANE_UUID", "HEXE_MUX_SOCKET", "HEXE_POD_SOCKET",
           "HEXE_POD_NAME", "HEXE_FLOAT", "HEXE_FLOAT_NAME", "HEXE_PAINTER_SOCKET",
           "HEXE_API_SOCKET"):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

procs, failures = [], []


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


def watchdog(_s, _f):
    print("FAIL: timed out waiting on the mux")
    sys.stdout.flush(); cleanup(); os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(240)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush(); cleanup(); sys.exit(1)


def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)


def hexe(*args):
    return subprocess.run([HEXE] + list(args), capture_output=True, text=True,
                          env=env, cwd=WD, timeout=30)


def read(*args):
    """`hexe terminal read`, returning (rc, stdout)."""
    p = hexe("terminal", "read", "--session", SESSION, "--pane", PANE_NAME, *args)
    return p.returncode, p.stdout, p.stderr


def send(text):
    p = hexe("terminal", "send", "--session", SESSION, "--pane", PANE_NAME, "--enter", text)
    if p.returncode != 0:
        fail(f"send failed rc={p.returncode}: {p.stderr.strip()[:160]}")


def socket_for(session):
    for root, _d, files in os.walk(RUN):
        if f"api@{session}.sock" in files:
            return os.path.join(root, f"api@{session}.sock")
    return None


def drain(m):
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


# ------------------------------------------------------------------ a session

m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
fe = subprocess.Popen([HEXE, "mux", "new", "-n", SESSION], stdin=sl, stdout=sl, stderr=sl,
                      env=env, cwd=WD, start_new_session=True)
os.close(sl)
procs.append(fe)
threading.Thread(target=drain, args=(m,), daemon=True).start()

deadline = time.time() + 30
while time.time() < deadline and socket_for(SESSION) is None:
    if fe.poll() is not None:
        fail(f"frontend exited rc={fe.returncode}")
    time.sleep(0.3)
if socket_for(SESSION) is None:
    fail("session never bound its socket")
time.sleep(2.5)

p = hexe("api", "panes", "--session", SESSION)
rows = json.loads(p.stdout)["result"]
PANE_UUID = rows[0]["uuid"]
PANE_NAME = rows[0]["name"]
print(f"session: {SESSION}, pane {PANE_NAME} [{PANE_UUID[:8]}]")

# --------------------------------------------------------------------- phase 1
print("\nphase 1: -n reads lines of content, from a pane with no marks at all")
# The searched token must appear ONLY in the output, never in the text of a
# command echoed on screen. `echo line5` would put "line5" on the screen the
# moment the line is typed, so a wait for it returns before anything has run and
# the test then reads a half-finished pane -- which answers truthfully, about a
# different moment. Composing the value from a variable and a literal keeps
# "line5" out of every command line.
send("p=line")
send("for i in 1 2 3 4 5; do echo $p$i; done")

deadline = time.time() + 25
while time.time() < deadline:
    rc, outp, _e = read("-n", "10")
    if rc == 0 and "line5" in outp:
        break
    time.sleep(0.5)
else:
    fail("the pane never printed line5; the loop did not run")

rc, outp, err = read("-n", "2")
check(rc == 0, f"-n 2 exits 0 (got {rc}; {err.strip()[:120]})")
lines = [l for l in outp.splitlines() if l.strip()]
# Two lines of CONTENT: the bug this guards is counting a blank bottom row as
# one of them, which returned a single line.
check(len(lines) == 2, f"-n 2 returns two lines (got {len(lines)}: {lines})")
check("line5" in outp, f"-n 2 includes the newest line (got {lines})")

rc, outp, _e = read("-n", "1")
check(rc == 0 and len([l for l in outp.splitlines() if l.strip()]) == 1,
      "-n 1 returns exactly one line")

# --------------------------------------------------------------------- phase 2
print("\nphase 2: no marks and no -n is an error that names -n")
rc, outp, err = read()
check(rc == 3, f"a bare read on an unmarked pane exits 3 (got {rc})")
check("-n" in err, "and the message tells you to use -n")
check("shell init" in err, "and mentions shell integration")
check(outp.strip() == "", "and prints nothing on stdout")

# --------------------------------------------------------------------- phase 3
print("\nphase 3: with OSC 133 marks, a bare read is the LAST command's output")
# The marks have to come from the PROMPT, not from printf calls between
# commands: hexe's own `shell init` uses IPC hooks rather than OSC 133 (the
# prompt is painted by an external program), and sequences emitted *between*
# commands land on rows the shell then draws its own prompt over, so they never
# form a block. bash's PS1 marks prompt-start and prompt-end, and PS0 is
# emitted after a command is read and before it runs — exactly 133;C.
send("PS1=$'\\033]133;A\\007$ \\033]133;B\\007'")
send("PS0=$'\\033]133;C\\007'")


def send_and_await(cmd, expect):
    """Send one command and wait until its OUTPUT is on screen.

    One at a time, rather than firing all of them and sleeping. Sending four
    lines back to back leaves the order in which the shell gets round to them up
    to timing, and then a read that lands mid-sequence returns a true answer to
    a different question than the test is asking.
    """
    send(cmd)
    deadline = time.time() + 25
    while time.time() < deadline:
        rc, outp, _e = read("-n", "10")
        if rc == 0 and expect in outp:
            return
        time.sleep(0.4)
    fail(f"`{cmd}` never printed {expect}")


# Same rule as phase 1: the token lives only in the output. `a=AAA` puts "AAA"
# on screen but never "AAA111", which is what is waited for and asserted on.
send("a=AAA b=BBB c=CCC")
send_and_await("echo ${a}111", "AAA111")
send_and_await("echo ${b}222", "BBB222")
send_and_await("echo ${c}333", "CCC333")

# The mark-based read must also agree the last block is complete before the
# assertions below lean on it.
deadline = time.time() + 25
while time.time() < deadline:
    rc, outp, _e = read()
    if rc == 0 and "CCC333" in outp:
        break
    time.sleep(0.4)
else:
    fail("the bare read never returned the last command's output")

rc, outp, err = read()
check(rc == 0, f"a bare read now exits 0 (got {rc}; {err.strip()[:120]})")
check("CCC333" in outp, f"it has the last command's output (got {outp.strip()[:120]!r})")
check("BBB222" not in outp, "and NOT the command before it")
check("echo ${c}333" not in outp, "and not the command line itself, only its output")

# --------------------------------------------------------------------- phase 4
print("\nphase 4: -c N spans N commands, oldest first")
rc, outp, err = read("-c", "2")
check(rc == 0, f"-c 2 exits 0 (got {rc}; {err.strip()[:120]})")
check("BBB222" in outp and "CCC333" in outp, f"-c 2 has both outputs (got {outp.strip()[:160]!r})")
if "BBB222" in outp and "CCC333" in outp:
    check(outp.index("BBB222") < outp.index("CCC333"), "oldest first")
check("AAA111" not in outp, "-c 2 stops at two, not three")
# Spanning two blocks is ONE selection, so the prompt line between them comes
# with it -- and should: without it you cannot tell where one command's output
# ends and the next begins. A single command has no such line, so `-c 1` and a
# bare read stay output-only.
check("echo ${c}333" in outp,
      "-c 2 keeps the prompt line between the two, as the separator")

rc, outp, _e = read("-c", "3")
check(rc == 0 and "AAA111" in outp, "-c 3 reaches the third command back")

# --------------------------------------------------------------------- phase 5
print("\nphase 5: both flags at once is a usage error")
p = hexe("terminal", "read", "--session", SESSION, "--pane", PANE_NAME, "-n", "2", "-c", "2")
check(p.returncode == 1, f"-n with -c exits 1 (got {p.returncode})")
p = hexe("terminal", "read", "--session", SESSION, "--pane", PANE_NAME, "-n", "0")
check(p.returncode == 1, f"-n 0 exits 1 (got {p.returncode})")
p = hexe("terminal", "read", "--session", SESSION, "--pane", PANE_NAME, "-n", "abc")
check(p.returncode == 1, f"-n abc exits 1 (got {p.returncode})")

# --------------------------------------------------------------------- phase 6
print("\nphase 6: it still reads after the session detaches — the pod has the ring")
hexe("api", "act", json.dumps("mux.detach"), "--session", SESSION)
deadline = time.time() + 25
while time.time() < deadline and socket_for(SESSION):
    time.sleep(0.4)
check(socket_for(SESSION) is None, "the control socket is gone (detached)")

# By uuid, with no session and no frontend anywhere.
p = hexe("terminal", "read", "--uuid", PANE_UUID[:8], "-c", "2")
check(p.returncode == 0, f"reading a detached pane exits 0 (got {p.returncode}; "
                         f"{p.stderr.strip()[:160]})")
check("CCC333" in p.stdout, f"and still has the output (got {p.stdout.strip()[:120]!r})")

# And it is still live: typing into it and reading it back, with nothing attached.
hexe("terminal", "send", "--uuid", PANE_UUID[:8], "--enter", "printf 'DETACHED_OK\\n'")
seen = False
deadline = time.time() + 20
while time.time() < deadline:
    p = hexe("terminal", "read", "--uuid", PANE_UUID[:8], "-n", "3")
    if p.returncode == 0 and "DETACHED_OK" in p.stdout:
        seen = True
        break
    time.sleep(0.5)
check(seen, "a detached pane can be written to and read back with no frontend")

print()
if failures:
    print(f"FAIL: {len(failures)} check(s) failed")
    for f in failures:
        print(f"  - {f}")
    sys.stdout.flush(); cleanup(); sys.exit(1)
print("PASS: reading a pane, answered by the pod")
sys.stdout.flush(); cleanup()
