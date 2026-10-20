#!/usr/bin/env python3
"""`hexe terminal read` under load: does answering a read stall the pod?

The read is served by parsing the pod's backlog ring into a throwaway VT, and
that happens **synchronously in the pod's accept path**. The pod's one hard rule
is that it must never stop draining the pty — backpressure there suspends the
program in the pane. So the question this file exists to answer is not "does the
read return the right text" (smoke_pane_read.py does that) but:

  * how long does one read actually take on a FULL ring?
  * does a burst of output take materially longer while reads hammer the pod?
  * do repeated reads leak? The VT is built and freed per read, so pod RSS must
    come back down.
  * does the ring wrapping get reported, rather than silently returning a
    partial answer that looks whole?
  * do concurrent reads corrupt each other?

Measured interleaved, not sequentially: this machine's load moves, and the repo
has been burnt before by a sequential comparison that said 15% where an
interleaved one said 4.6%.
"""
import atexit, fcntl, json, os, pty, re, signal, statistics, struct, subprocess, sys, termios, threading, time

REPO = os.environ.get("HEXE_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEXE = os.path.join(REPO, "zig-out/bin/hexe")
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke")
WD = os.path.join(SCRATCH, f"readstress{os.getpid()}")
CF = os.path.join(WD, "config")
RUN = os.path.join(WD, "run")
os.makedirs(os.path.join(CF, "hexe"), exist_ok=True)
os.makedirs(RUN, exist_ok=True)
INST = f"smk{os.getpid()}"
SESSION = "stress"

open(os.path.join(CF, "hexe", "init.lua"), "w").write(
    "local hexe = require('hexe')\nreturn hexe.setup({})\n")

env = os.environ.copy()
env.update({"HEXE_INSTANCE": INST, "XDG_STATE_HOME": os.path.join(WD, "state"),
            "XDG_RUNTIME_DIR": RUN, "XDG_CONFIG_HOME": CF,
            "TERM": "xterm-256color", "SHELL": "/bin/sh",
            "HEXE_SKIP_LOCAL_CONFIG": "1",
            # Each CLI call is a fresh connection, and the daemon rate-limits
            # those to 60 a minute by default. Hammering reads therefore hits
            # the DoS guard long before it stresses anything this file is about.
            # Raised to the limiter's own capacity so the guard stays real but
            # stops being the thing under test; phase 7 checks it separately.
            "HEXE_MAX_CONNECTIONS_PER_MINUTE": "256"})
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
    print("FAIL: timed out; a read that never returns is exactly the stall "
          "this file is looking for")
    sys.stdout.flush(); cleanup(); os._exit(1)


signal.signal(signal.SIGALRM, watchdog)
signal.alarm(600)


def fail(msg):
    print(f"FAIL: {msg}")
    sys.stdout.flush(); cleanup(); sys.exit(1)


def check(ok, msg):
    print(("  ok   " if ok else "  FAIL ") + msg)
    if not ok:
        failures.append(msg)


def hexe(*args, timeout=60):
    return subprocess.run([HEXE] + list(args), capture_output=True, text=True,
                          env=env, cwd=WD, timeout=timeout)


def read(*args, timeout=60):
    return hexe("terminal", "read", "--uuid", PANE_UUID, *args, timeout=timeout)


def send(text):
    p = hexe("terminal", "send", "--uuid", PANE_UUID, "--enter", text)
    if p.returncode != 0:
        fail(f"send failed rc={p.returncode}: {p.stderr.strip()[:160]}")


def socket_for(s):
    for root, _d, files in os.walk(RUN):
        if f"api@{s}.sock" in files:
            return os.path.join(root, f"api@{s}.sock")
    return None


def drain(m):
    while True:
        try:
            if not os.read(m, 65536):
                return
        except OSError:
            return


def pod_pid():
    """The pod process for our pane, by its own command line.

    From /proc rather than from `pod list`: the pod stamps its uuid into its
    argv, so this cannot disagree with reality the way a metadata file on disk
    can, and it needs no cooperation from the thing being measured.
    """
    p = subprocess.run(["pgrep", "-f", f"pod daemon.*--uuid {PANE_UUID}"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    pids = [int(x) for x in p.stdout.split() if x.strip().isdigit()]
    return pids[0] if pids else None


def rss_kb(pid):
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        return None
    return None


# ------------------------------------------------------------------ a session

m, sl = pty.openpty()
fcntl.ioctl(sl, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
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

rows = json.loads(hexe("api", "panes", "--session", SESSION).stdout)["result"]
PANE_UUID = rows[0]["uuid"]
PID = pod_pid()
print(f"session {SESSION}, pane {PANE_UUID[:8]}, pod pid {PID}")
if PID is None:
    fail("could not find the pod pid; the rest of this file measures that process")


def await_output(token, what, limit=120):
    deadline = time.time() + limit
    while time.time() < deadline:
        p = read("-n", "4")
        if p.returncode == 0 and token in p.stdout:
            return
        time.sleep(0.5)
    fail(f"{what}: never saw {token}")


# --------------------------------------------------------------------- phase 1
print("\nphase 1: fill the ring, then time a read on a FULL 4 MiB ring")
# ~4.5 MiB of output: more than the ring holds, so it is guaranteed full and
# guaranteed to have wrapped.
send("i=0; while [ $i -lt 60000 ]; do echo \"pad-$i-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"; i=$((i+1)); done; echo FILLDONE")
await_output("FILLDONE", "ring fill", limit=300)

times = []
for _ in range(10):
    t0 = time.perf_counter()
    p = read("-n", "50")
    dt = time.perf_counter() - t0
    if p.returncode != 0:
        fail(f"read on a full ring failed rc={p.returncode}: {p.stderr.strip()[:160]}")
    times.append(dt)

med = statistics.median(times)
worst = max(times)
print(f"  read on a full ring: median {med*1000:.0f} ms, worst {worst*1000:.0f} ms "
      f"(n={len(times)})")
# Generous: this is a whole-process spawn plus a 4 MiB VT parse. The point is to
# catch a regression into seconds, not to police milliseconds.
check(worst < 5.0, f"a read on a full ring stays under 5 s (worst {worst:.2f} s)")

# --------------------------------------------------------------------- phase 2
print("\nphase 2: the wrapped ring is reported, not silently partial")
p = read("-n", "5")
check(p.returncode == 0, f"the read still succeeds (got {p.returncode})")
check("mid-history" in p.stderr,
      f"stderr says the history may start mid-way (got {p.stderr.strip()[:120]!r})")
check("mid-history" not in p.stdout, "and that note is NOT on stdout, so a pipe stays clean")

# --------------------------------------------------------------------- phase 3
print("\nphase 3: repeated reads must not leak — the VT is per read")
before = rss_kb(PID)
loop_failures = []
for i in range(60):
    p = read("-n", "20")
    if p.returncode != 0:
        loop_failures.append((i, p.returncode, (p.stderr or p.stdout).strip()[:160]))
after = rss_kb(PID)
if loop_failures:
    print(f"  {len(loop_failures)} of 60 reads failed; first few:")
    for i, rc, msg in loop_failures[:3]:
        print(f"    #{i} rc={rc}: {msg}")
    # Who did that read actually reach? A mismatch means a daemon built from
    # other sources, so the question is whether this run's own daemon is still
    # there and still the one being found.
    print("  -- diagnosis --")
    print(f"    frontend alive: {fe.poll() is None}")
    ses = subprocess.run(["pgrep", "-af", f"instance {INST}"], capture_output=True, text=True)
    print(f"    our processes:\n      " + "\n      ".join(
        l[:110] for l in ses.stdout.splitlines()[:6]) or "      (none)")
    for root, _d, files in os.walk(RUN):
        socks = [f for f in files if f.endswith(".sock")]
        if socks:
            print(f"    {root}: {sorted(socks)[:6]}")
    st = hexe("session", "status")
    print(f"    session status rc={st.returncode}: "
          f"{(st.stdout or st.stderr).strip()[:160]}")
check(not loop_failures, f"all 60 back-to-back reads succeed ({len(loop_failures)} failed)")
print(f"  pod RSS {before} kB -> {after} kB over 60 reads")
check(before is not None and after is not None, "pod RSS is readable")
if before and after:
    growth = after - before
    # A per-read VT that was not freed would add megabytes over 60 reads.
    check(growth < 20000, f"pod RSS grew by less than 20 MB (grew {growth} kB)")

# --------------------------------------------------------------------- phase 4
print("\nphase 4: does hammering reads slow the pty drain? (interleaved)")


def burst(tag, hammer):
    """Time a fixed output burst, optionally while reads hammer the pod."""
    stop = threading.Event()
    reads = [0]

    def hammer_loop():
        while not stop.is_set():
            if read("-n", "30").returncode == 0:
                reads[0] += 1

    t = None
    if hammer:
        t = threading.Thread(target=hammer_loop, daemon=True)
        t.start()
    t0 = time.perf_counter()
    send(f"i=0; while [ $i -lt 4000 ]; do echo \"{tag}-$i\"; i=$((i+1)); done; echo {tag}END")
    await_output(f"{tag}END", f"burst {tag}", limit=240)
    dt = time.perf_counter() - t0
    stop.set()
    if t:
        t.join(timeout=10)
    return dt, reads[0]


# Interleaved A/B/A/B so drifting machine load hits both arms equally.
quiet, loud = [], []
for i in range(2):
    q, _ = burst(f"q{i}", hammer=False)
    quiet.append(q)
    l, nreads = burst(f"l{i}", hammer=True)
    loud.append(l)
    print(f"  pass {i}: quiet {q:.2f} s, with reads {l:.2f} s ({nreads} reads served)")

mq, ml = statistics.median(quiet), statistics.median(loud)
ratio = ml / mq if mq > 0 else 0
print(f"  median: quiet {mq:.2f} s, hammered {ml:.2f} s  -> {ratio:.2f}x")
# A synchronous parse in the accept path WILL cost something; what must not
# happen is the drain stopping. 3x is the line between "pays for the reads" and
# "the pane is being held up".
check(ratio < 3.0, f"output keeps flowing while reads hammer the pod ({ratio:.2f}x)")

# --------------------------------------------------------------------- phase 5
print("\nphase 5: concurrent reads do not corrupt each other")
results = {}


def one(idx):
    p = read("-n", "12")
    results[idx] = (p.returncode, p.stdout)


threads = [threading.Thread(target=one, args=(i,)) for i in range(12)]
for t in threads:
    t.start()
for t in threads:
    t.join(timeout=90)

check(len(results) == 12, f"all 12 concurrent reads returned (got {len(results)})")
check(all(rc == 0 for rc, _ in results.values()),
      f"all succeeded (codes {sorted({rc for rc, _ in results.values()})})")
bodies = {out for _rc, out in results.values()}
# The pane is quiet now, so every read saw the same screen. Differing bodies
# would mean one read read another's buffer.
check(len(bodies) <= 2, f"concurrent reads agree on the screen ({len(bodies)} distinct bodies)")

# --------------------------------------------------------------------- phase 6
print("\nphase 6: the pane is still alive and correct after all of that")
send("echo STILL_ALIVE_$((21*2))")
await_output("STILL_ALIVE_42", "post-stress liveness")
check(True, "the pane still runs commands after the stress")
check(pod_pid() == PID, "it is the same pod process; it never died and respawned")

p = read("-n", "3")
check(p.returncode == 0 and "STILL_ALIVE_42" in p.stdout,
      "and reads still return its newest output")

# --------------------------------------------------------------------- phase 7
print("\nphase 7: the ses daemon reclaims every resolve connection")
# Each addressed command opens a fresh connection to SES to resolve its target.
# A handler that reads its payload straight off the descriptor owns that
# descriptor; one that forgets to close it leaks one fd per command, with memory
# flat and nothing visible until a long-lived daemon runs out. That is exactly
# what happened here, and only counting descriptors found it.
def ses_daemon_pid():
    p = subprocess.run(["pgrep", "-f", "ses daemon"], capture_output=True, text=True)
    if p.returncode != 0:
        return None
    for pid in p.stdout.split():
        try:
            environ = open(f"/proc/{int(pid)}/environ", "rb").read().split(b"\0")
        except (OSError, ValueError):
            continue
        if f"HEXE_INSTANCE={INST}".encode() in environ:
            return int(pid)
    return None


def fd_count(pid):
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except OSError:
        return None


SES_PID = ses_daemon_pid()
check(SES_PID is not None, "found this run's ses daemon")
if SES_PID:
    base = fd_count(SES_PID)
    for _ in range(80):
        read("-n", "5")
    grown = fd_count(SES_PID)
    print(f"  ses daemon fds {base} -> {grown} over 80 resolves")
    check(base is not None and grown is not None, "its fd count is readable")
    if base is not None and grown is not None:
        # A couple of fds of slack for anything else the daemon legitimately
        # opens; a leak shows up as ~80.
        check(grown - base <= 4,
              f"no fd leak per resolve (grew {grown - base} over 80 calls)")

# --------------------------------------------------------------------- phase 8
print("\nphase 8: the connection rate limit is reported honestly")
# Its own daemon, at the DEFAULT limit, so the guard is the real one. The point
# is not that the limit exists -- it should -- but that hitting it says so.
# It used to surface as `RuntimeEpochMismatch`, i.e. "your binary is stale",
# which is the one diagnosis guaranteed to be wrong and sends you rebuilding.
rl_env = dict(env)
rl_env.pop("HEXE_MAX_CONNECTIONS_PER_MINUTE", None)
rl_inst = f"{INST}rl"
rl_env["HEXE_INSTANCE"] = rl_inst
rl_run = os.path.join(WD, "rl-run")
os.makedirs(rl_run, exist_ok=True)
rl_env["XDG_RUNTIME_DIR"] = rl_run

rl_daemon = subprocess.Popen([HEXE, "ses", "daemon"], env=rl_env, cwd=WD,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
procs.append(rl_daemon)
time.sleep(2.0)

saw_refusal, saw_mismatch, saw_expected = False, False, 0
for _ in range(90):
    p = subprocess.run([HEXE, "terminal", "info", "--pane", "nosuch"],
                       capture_output=True, text=True, env=rl_env, cwd=WD, timeout=30)
    blob = p.stderr + p.stdout
    if "rate-limiting" in blob:
        saw_refusal = True
    elif "RuntimeEpochMismatch" in blob:
        saw_mismatch = True
    elif "no pane matches" in blob:
        saw_expected += 1

check(saw_expected > 0, f"resolves work up to the limit ({saw_expected} answered)")
check(saw_refusal, "past the limit, the refusal says it is rate-limiting")
check(not saw_mismatch,
      "and never claims a protocol mismatch, which is what it used to say")
subprocess.run(["pkill", "-f", f"instance {rl_inst}"], capture_output=True)

print()
if failures:
    print(f"FAIL: {len(failures)} check(s) failed")
    for f in failures:
        print(f"  - {f}")
    sys.stdout.flush(); cleanup(); sys.exit(1)
print("PASS: reads stay bounded, leak-free, and do not stall the pod")
sys.stdout.flush(); cleanup()
