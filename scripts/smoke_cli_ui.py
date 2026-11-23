#!/usr/bin/env python3
"""Live smoke test for the CLI UI & attach/detach interaction overhaul.

Covers:
1. Top-level shortcuts & --help descriptions (`attach`, `detach`, `new`, `list`, `kill`).
2. `hexe ls` / `hexe ses list` stdout output, zero ANSI when piped or NO_COLOR=1,
   and ANSI styling on a TTY.
3. `hexe pod list` piped (`HEXE_POD uuid=...`) vs PTY table rendering.
4. `hexe detach <target>` cleanly detaching a running frontend + post-detach banner
   showing session name, pane count, and profile-aware `hexe -P <inst> attach ...`.
5. Non-TTY `hexe attach <ambiguous>` failing fast with the real candidate error.
6. Interactive `hexe attach` (no args) on a PTY launching the vaxis picker,
   live `/` filtering, and attaching to the chosen session with shell state intact.
7. Session take-over (steal) showing the post-exit stolen banner on the displaced client.
8. Standalone `hexe pod attach` post-detach banner.
"""
import atexit
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
SCRATCH = os.environ.get("HEXE_SMOKE_TMP", "/tmp/hexe-smoke-ui")
os.makedirs(SCRATCH, exist_ok=True)
INST = f"smkui{os.getpid()}"

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")

env = os.environ.copy()
env["HEXE_INSTANCE"] = INST
env["XDG_STATE_HOME"] = os.path.join(SCRATCH, "state")
CFG_DIR = os.path.join(SCRATCH, f"cfg-{os.getpid()}")
os.makedirs(os.path.join(CFG_DIR, "hexe"), exist_ok=True)
with open(os.path.join(CFG_DIR, "hexe", "init.lua"), "w") as _fh:
    _fh.write("local hexe = require('hexe')\nreturn hexe.setup({ palette = { namespaces = true } })\n")
env["XDG_CONFIG_HOME"] = CFG_DIR
env["TERM"] = "xterm-256color"
env["SHELL"] = "/bin/sh"
env.pop("NO_COLOR", None)
env.pop("CLICOLOR_FORCE", None)
for _k in (
    "HEXE_SESSION",
    "HEXE_PANE_UUID",
    "HEXE_MUX_SOCKET",
    "HEXE_POD_SOCKET",
    "HEXE_POD_NAME",
    "HEXE_FLOAT",
    "HEXE_FLOAT_NAME",
):
    env.pop(_k, None)
os.makedirs(env["XDG_STATE_HOME"], exist_ok=True)

procs = []
fds = []


def pgrep(pattern):
    r = subprocess.run(["pgrep", "-f", "--", pattern], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def spawn_pty(argv, extra_env=None, rows=32, cols=110):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    run_env = env.copy()
    if extra_env:
        run_env.update(extra_env)
    p = subprocess.Popen(
        argv,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=run_env,
        cwd=SCRATCH,
        start_new_session=True,
    )
    os.close(slave)
    procs.append(p)
    fds.append(master)
    return p, master


def run_pty_capture(argv, extra_env=None, timeout_s=8):
    p, master = spawn_pty(argv, extra_env=extra_env)
    buf = b""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.15)
        if master in r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
        if p.poll() is not None:
            # drain remaining output
            while True:
                r2, _, _ = select.select([master], [], [], 0.05)
                if master not in r2:
                    break
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
            break
    if p.poll() is None:
        p.kill()
        p.wait()
    try:
        os.close(master)
    except OSError:
        pass
    return p.returncode, buf


def read_until(fd, marker, timeout_s):
    deadline = time.time() + timeout_s
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.15)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return False, buf
            if not chunk:
                return False, buf
            buf += chunk
            if marker in buf:
                return True, buf
    return False, buf


def drain_until_exit(proc, fd, timeout_s=8):
    deadline = time.time() + timeout_s
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
        if proc.poll() is not None:
            # Drain any final bytes after process exits
            for _ in range(10):
                r2, _, _ = select.select([fd], [], [], 0.05)
                if fd not in r2:
                    break
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
            break
    if proc.poll() is None:
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
    return proc.poll(), buf


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    cleanup()
    sys.exit(1)


def cleanup():
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                p.kill()
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass
    for pid in pgrep(f"daemon --instance {INST}"):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


atexit.register(cleanup)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(1))

print(f"instance={INST}")

# 1. Help, grouped sections, ANSI on PTY vs plain on pipe/NO_COLOR, --version, and clean bad-flag error
r_help = subprocess.run([HEXE, "--help"], capture_output=True, text=True, env=env, timeout=10)
if r_help.returncode != 0:
    fail(f"`hexe --help` failed rc={r_help.returncode}")
if "\x1b[" in r_help.stdout:
    fail(f"piped `hexe --help` emitted ANSI escapes: {r_help.stdout!r}")
for needle in ("Session Shortcuts:", "Core Subsystems:", "Tools & Integration:", "attach", "detach", "new", "list", "kill"):
    if needle not in r_help.stdout:
        fail(f"missing {needle!r} in piped `hexe --help`:\n{r_help.stdout}")

rc_h_tty, pty_help = run_pty_capture([HEXE, "--help"])
if rc_h_tty != 0 or b"\x1b[" not in pty_help:
    fail(f"PTY `hexe --help` expected ANSI styling, rc={rc_h_tty} out={pty_help!r}")
rc_h_nc, pty_help_nc = run_pty_capture([HEXE, "--help"], extra_env={"NO_COLOR": "1"})
if rc_h_nc != 0 or b"\x1b[" in pty_help_nc:
    fail(f"PTY `NO_COLOR=1 hexe --help` emitted ANSI escapes: rc={rc_h_nc}")

# Subsystem empty-args help + alias subcommand help
rc_ses_h, pty_ses_h = run_pty_capture([HEXE, "ses"])
pty_ses_plain = ANSI_RE.sub("", pty_ses_h.decode("utf-8", errors="replace"))
if rc_ses_h != 0 or b"\x1b[" not in pty_ses_h or "hexe session (alias: ses)" not in pty_ses_plain:
    fail(f"PTY `hexe ses` empty-arg help unexpected: rc={rc_ses_h} out={pty_ses_plain!r}")

r_ls_help = subprocess.run([HEXE, "ls", "--help"], capture_output=True, text=True, env=env, timeout=10)
if "\x1b[" in r_ls_help.stdout or "Show tab, split, and float tree details" not in r_ls_help.stdout:
    fail(f"expected clean descriptive option help in `hexe ls --help`:\n{r_ls_help.stdout}")

# --version: plain when piped, colored on PTY
r_ver = subprocess.run([HEXE, "--version"], capture_output=True, text=True, env=env, timeout=10)
if r_ver.returncode != 0 or not r_ver.stdout.startswith("hexe ") or "\x1b[" in r_ver.stdout:
    fail(f"piped `hexe --version` broken: rc={r_ver.returncode} out={r_ver.stdout!r}")
rc_ver_tty, pty_ver = run_pty_capture([HEXE, "--version"])
if rc_ver_tty != 0 or b"\x1b[" not in pty_ver or b"hexe" not in pty_ver:
    fail(f"PTY `hexe --version` expected ANSI styling: rc={rc_ver_tty} out={pty_ver!r}")

# Bad flag exits non-zero cleanly with no Zig stack trace
r_bad = subprocess.run([HEXE, "--definitely-not-a-flag"], capture_output=True, text=True, env=env, timeout=10)
if r_bad.returncode == 0 or "Run 'hexe --help'" not in r_bad.stderr or "error." in r_bad.stderr:
    fail(f"bad flag handling unexpected: rc={r_bad.returncode} err={r_bad.stderr!r}")

# Styled stderr error on PTY vs plain Error: when piped
r_err_pipe = subprocess.run([HEXE, "terminal", "focus", "diagonal"], capture_output=True, text=True, env=env, timeout=10)
if r_err_pipe.returncode == 0 or "Error:" not in r_err_pipe.stderr or "\x1b[" in r_err_pipe.stderr:
    fail(f"piped error unexpected: rc={r_err_pipe.returncode} err={r_err_pipe.stderr!r}")
rc_err_tty, pty_err = run_pty_capture([HEXE, "terminal", "focus", "diagonal"])
if rc_err_tty == 0 or b"\x1b[31m" not in pty_err or "✗ Error:".encode() not in ANSI_RE.sub("", pty_err.decode("utf-8", errors="replace")).encode():
    fail(f"PTY error expected red ✗ Error:, rc={rc_err_tty} out={pty_err!r}")
print("pass 1: grouped colored --help, --version, clean parse errors, and styled diagnostics")

# 2. Spawn two sessions sharing 5-char prefix `alpha` (`alpha-one` and `alpha-two`)
fe_alpha, m_alpha = spawn_pty([HEXE, "new", "-n", "alpha-one"])
time.sleep(2.0)
if fe_alpha.poll() is not None:
    fail(f"alpha-one exited early rc={fe_alpha.returncode}")

fe_alpaca, m_alpaca = spawn_pty([HEXE, "new", "-n", "alpha-two"])
time.sleep(2.0)
if fe_alpaca.poll() is not None:
    fail(f"alpha-two exited early rc={fe_alpaca.returncode}")

# Set distinct shell state inside alpha-two so we can verify interactive picker attached to the right one
os.write(m_alpaca, b"export UI_TOKEN=alpaca_ok_77\r")
time.sleep(0.4)
os.write(m_alpaca, b"echo TOKEN_$UI_TOKEN\r")
ok, out_buf = read_until(m_alpaca, b"TOKEN_alpaca_ok_77", 8)
if not ok:
    fail(f"failed to initialize alpha-two shell state; got {out_buf[-300:]!r}")
print("pass 2: spawned alpha-one and alpha-two sessions")

# 3. `hexe ls` stdout + piped no-ANSI + NO_COLOR + PTY ANSI
r_ls = subprocess.run([HEXE, "ls"], capture_output=True, text=True, env=env, timeout=10)
if r_ls.returncode != 0:
    fail(f"`hexe ls` failed rc={r_ls.returncode} err={r_ls.stderr!r}")
if "alpha-one" not in r_ls.stdout or "alpha-two" not in r_ls.stdout:
    fail(f"`hexe ls` did not write sessions to stdout: stdout={r_ls.stdout!r} stderr={r_ls.stderr!r}")
if "\x1b[" in r_ls.stdout:
    fail(f"piped `hexe ls` emitted ANSI escapes: {r_ls.stdout!r}")

rc_tty, pty_ls = run_pty_capture([HEXE, "ls"])
if rc_tty != 0 or b"\x1b[" not in pty_ls:
    fail(f"PTY `hexe ls` expected ANSI styling, rc={rc_tty} out={pty_ls!r}")

rc_nc, pty_ls_nc = run_pty_capture([HEXE, "ls"], extra_env={"NO_COLOR": "1"})
if rc_nc != 0 or b"\x1b[" in pty_ls_nc:
    fail(f"PTY `NO_COLOR=1 hexe ls` emitted ANSI escapes: rc={rc_nc} out={pty_ls_nc!r}")
print("pass 3: `hexe ls` stdout, piped plain text, PTY ANSI, NO_COLOR")

# 4. `hexe pod list` piped contract vs PTY table
r_pods = subprocess.run([HEXE, "pod", "list"], capture_output=True, text=True, env=env, timeout=10)
if r_pods.returncode != 0 or "HEXE_POD uuid=" not in r_pods.stdout:
    fail(f"piped `hexe pod list` broken: rc={r_pods.returncode} out={r_pods.stdout!r} err={r_pods.stderr!r}")
if "\x1b[" in r_pods.stdout:
    fail(f"piped `hexe pod list` emitted ANSI escapes: {r_pods.stdout!r}")

rc_pod_tty, pty_pods = run_pty_capture([HEXE, "pod", "list"])
pty_pods_plain = ANSI_RE.sub("", pty_pods.decode("utf-8", errors="replace"))
if rc_pod_tty != 0 or "UUID" not in pty_pods_plain or "NAME" not in pty_pods_plain or "PID" not in pty_pods_plain:
    fail(f"PTY `hexe pod list` table missing headers: rc={rc_pod_tty} out={pty_pods_plain!r}")
print("pass 4: `hexe pod list` piped HEXE_POD format + PTY table")

# 5. CLI `hexe detach alpha-one` + verify frontend exits with post-detach banner
r_det1 = subprocess.run([HEXE, "detach", "alpha-one"], capture_output=True, text=True, env=env, timeout=10)
if r_det1.returncode != 0 or "alpha-one" not in r_det1.stdout:
    fail(f"`hexe detach alpha-one` failed: rc={r_det1.returncode} out={r_det1.stdout!r} err={r_det1.stderr!r}")
rc_a, alpha_exit_raw = drain_until_exit(fe_alpha, m_alpha, timeout_s=8)
alpha_exit = ANSI_RE.sub("", alpha_exit_raw.decode("utf-8", errors="replace"))
if rc_a is None:
    fail("alpha-one frontend did not exit after `hexe detach alpha-one`")
if "Detached from session alpha-one" not in alpha_exit or f"hexe -P {INST} attach alpha-one" not in alpha_exit:
    fail(f"alpha-one post-detach banner missing expected content:\n{alpha_exit!r}")

# Detach alpha-two too so both are detached for the interactive picker test
r_det2 = subprocess.run([HEXE, "detach", "alpha-two"], capture_output=True, text=True, env=env, timeout=10)
if r_det2.returncode != 0:
    fail(f"`hexe detach alpha-two` failed: rc={r_det2.returncode} err={r_det2.stderr!r}")
rc_p, alpaca_exit_raw = drain_until_exit(fe_alpaca, m_alpaca, timeout_s=8)
if rc_p is None:
    fail("alpha-two frontend did not exit after `hexe detach alpha-two`")
print("pass 5: `hexe detach` cleanly detached sessions and emitted post-detach banner")

# 6. Non-TTY `hexe attach alpha` (ambiguous) and `hexe attach alp` (too short) fail fast
r_short = subprocess.run([HEXE, "attach", "alp"], capture_output=True, text=True, env=env, timeout=10)
short_err = r_short.stderr + r_short.stdout
if r_short.returncode == 0 or "prefix_too_short" not in short_err:
    fail(f"non-TTY short prefix `hexe attach alp` failed unexpectedly: rc={r_short.returncode} msg={short_err!r}")

r_amb = subprocess.run([HEXE, "attach", "alpha"], capture_output=True, text=True, env=env, timeout=10)
amb_err = r_amb.stderr + r_amb.stdout
if r_amb.returncode == 0:
    fail(f"non-TTY ambiguous `hexe attach alpha` unexpectedly succeeded: {amb_err!r}")
if "ambiguous" not in amb_err.lower() and "multiple" not in amb_err.lower():
    fail(f"non-TTY ambiguous error did not report ambiguity: {amb_err!r}")
print("pass 6: non-TTY short-prefix and ambiguous `hexe attach` fail fast with real errors")

# 7. Interactive `hexe attach` (no args) on PTY: live `/` filter -> attach alpha-two -> verify shell state
fe_pick, m_pick = spawn_pty([HEXE, "attach"])
ok_pick, pick_buf = read_until(m_pick, b"Attach to session", 8)
if not ok_pick:
    plain_pick = ANSI_RE.sub("", pick_buf.decode("utf-8", errors="replace"))
    fail(f"interactive `hexe attach` did not render vaxis picker:\n{plain_pick[-600:]!r}")

# Filter for alpha-two and press Enter to attach
os.write(m_pick, b"/alpha-two")
time.sleep(0.35)
os.write(m_pick, b"\r")
time.sleep(2.2)

if fe_pick.poll() is not None:
    fail(f"interactive attach frontend exited prematurely rc={fe_pick.returncode}")

# Verify we attached to alpha-two by reading $UI_TOKEN
ok_tok = False
for _ in range(3):
    os.write(m_pick, b"echo CHECK_$UI_TOKEN\r")
    ok_tok, tok_buf = read_until(m_pick, b"CHECK_alpaca_ok_77", 5)
    if ok_tok:
        break
    time.sleep(1.0)
if not ok_tok:
    fail("interactive picker did not attach to alpha-two (UI_TOKEN missing)")
print("pass 7: interactive `hexe attach` vaxis picker + `/` filter attached to alpha-two")

# 8. Session steal: attach another frontend to alpha-two -> displaced frontend prints stolen banner
fe_steal, m_steal = spawn_pty([HEXE, "attach", "alpha-two"])
rc_disp, disp_raw = drain_until_exit(fe_pick, m_pick, timeout_s=10)
disp_plain = ANSI_RE.sub("", disp_raw.decode("utf-8", errors="replace"))
if rc_disp is None:
    steal_buf = b""
    while True:
        r_s, _, _ = select.select([m_steal], [], [], 0.1)
        if m_steal not in r_s:
            break
        try:
            c = os.read(m_steal, 65536)
            if not c:
                break
            steal_buf += c
        except OSError:
            break
    steal_plain = ANSI_RE.sub("", steal_buf.decode("utf-8", errors="replace"))
    fail(f"displaced frontend did not exit when session was stolen\n  steal rc={fe_steal.poll()} out={steal_plain[-400:]!r}\n  disp tail={disp_plain[-300:]!r}")
if "attached from another terminal" not in disp_plain:
    fail(f"displaced frontend missing stolen banner:\n{disp_plain!r}")
time.sleep(1.0)
if fe_steal.poll() is not None:
    fail(f"stealing frontend exited early rc={fe_steal.returncode}")
print("pass 8: session take-over emitted post-exit banner on displaced frontend")

# 9. Interactive standalone `hexe pod attach` (no args -> standalone vaxis pod picker) + Ctrl+B d detach banner
fe_pod, m_pod = spawn_pty([HEXE, "pod", "attach"])
ok_pod_pick, pod_pick_buf = read_until(m_pod, b"Attach to pod", 8)
if not ok_pod_pick:
    plain_pod_pick = ANSI_RE.sub("", pod_pick_buf.decode("utf-8", errors="replace"))
    fail(f"interactive `hexe pod attach` did not render standalone vaxis picker:\n{plain_pod_pick[-600:]!r}")

os.write(m_pod, b"\r")  # select first pod
time.sleep(1.0)
os.write(m_pod, b"\x02")  # Ctrl+B default detach prefix
time.sleep(0.15)
os.write(m_pod, b"d")
rc_pod, pod_raw = drain_until_exit(fe_pod, m_pod, timeout_s=6)
pod_plain = ANSI_RE.sub("", pod_raw.decode("utf-8", errors="replace"))
if rc_pod != 0 or "Detached from pod" not in pod_plain:
    fail(f"pod attach detach banner missing: rc={rc_pod} out={pod_plain!r}")
print("pass 9: interactive `hexe pod attach` standalone vaxis picker + post-detach banner")

# 10. Subcommand color & stdout/pipe contracts: pod gc, record status, pod share, palette list/get, terminal info
r_gc = subprocess.run([HEXE, "pod", "gc", "--dry-run"], capture_output=True, text=True, env=env, timeout=10)
if r_gc.returncode != 0 or "\x1b[" in r_gc.stdout or not r_gc.stdout.strip():
    fail(f"piped `hexe pod gc --dry-run` unexpected: rc={r_gc.returncode} out={r_gc.stdout!r} err={r_gc.stderr!r}")
rc_gc_tty, pty_gc = run_pty_capture([HEXE, "pod", "gc", "--dry-run"])
if rc_gc_tty != 0 or b"\x1b[" not in pty_gc:
    fail(f"PTY `hexe pod gc --dry-run` expected ANSI styling: rc={rc_gc_tty} out={pty_gc!r}")

r_rec_pipe = subprocess.run([HEXE, "record", "status"], capture_output=True, text=True, env=env, timeout=10)
if r_rec_pipe.returncode != 0 or r_rec_pipe.stdout.strip() != "0" or "\x1b[" in r_rec_pipe.stdout:
    fail(f"piped `hexe record status` expected '0' on stdout: rc={r_rec_pipe.returncode} out={r_rec_pipe.stdout!r}")
rc_rec_tty, pty_rec = run_pty_capture([HEXE, "record", "status"])
pty_rec_plain = ANSI_RE.sub("", pty_rec.decode("utf-8", errors="replace"))
if rc_rec_tty != 0 or b"\x1b[" not in pty_rec or "Not recording" not in pty_rec_plain:
    fail(f"PTY `hexe record status` expected styled human status: rc={rc_rec_tty} out={pty_rec_plain!r}")

r_pal_pipe = subprocess.run([HEXE, "palette", "list"], capture_output=True, text=True, env=env, timeout=10)
if r_pal_pipe.returncode != 0 or "pane uuid=" not in r_pal_pipe.stdout or "\x1b[" in r_pal_pipe.stdout:
    fail(f"piped `hexe palette list` broken: rc={r_pal_pipe.returncode} out={r_pal_pipe.stdout!r}")
rc_pal_tty, pty_pal = run_pty_capture([HEXE, "palette", "list"])
pty_pal_plain = ANSI_RE.sub("", pty_pal.decode("utf-8", errors="replace"))
if rc_pal_tty != 0 or b"\x1b[" not in pty_pal or "UUID" not in pty_pal_plain or "NAMESPACES" not in pty_pal_plain:
    fail(f"PTY `hexe palette list` expected styled table: rc={rc_pal_tty} out={pty_pal_plain!r}")

# Extract first pane uuid from palette list for terminal info + pod share + palette set/get checks
m_uuid = re.search(r"uuid=([0-9a-f]{32})", r_pal_pipe.stdout)
if not m_uuid:
    fail(f"could not extract pane uuid from `hexe palette list`: {r_pal_pipe.stdout!r}")
pane_uuid = m_uuid.group(1)

r_info_pipe = subprocess.run([HEXE, "terminal", "info", "--uuid", pane_uuid], capture_output=True, text=True, env=env, timeout=10)
if r_info_pipe.returncode != 0 or "Pane Info:" not in r_info_pipe.stdout or "\x1b[" in r_info_pipe.stdout:
    fail(f"piped `hexe terminal info` broken: rc={r_info_pipe.returncode} out={r_info_pipe.stdout!r}")
rc_info_tty, pty_info = run_pty_capture([HEXE, "terminal", "info", "--uuid", pane_uuid])
if rc_info_tty != 0 or b"\x1b[" not in pty_info or b"Pane Info:" not in ANSI_RE.sub("", pty_info.decode("utf-8", errors="replace")).encode():
    fail(f"PTY `hexe terminal info` expected ANSI styling: rc={rc_info_tty} out={pty_info!r}")

r_share_off = subprocess.run([HEXE, "pod", "share", "--uuid", pane_uuid, "--off"], capture_output=True, text=True, env=env, timeout=10)
if r_share_off.returncode != 0 or "blocked" not in r_share_off.stdout or "\x1b[" in r_share_off.stdout:
    fail(f"piped `hexe pod share --off` broken: rc={r_share_off.returncode} out={r_share_off.stdout!r}")
rc_share_tty, pty_share = run_pty_capture([HEXE, "pod", "share", "--uuid", pane_uuid])
if rc_share_tty != 0 or b"\x1b[31m" not in pty_share or "blocked" not in ANSI_RE.sub("", pty_share.decode("utf-8", errors="replace")):
    fail(f"PTY `hexe pod share` expected red blocked styling: rc={rc_share_tty} out={pty_share!r}")
r_share_on = subprocess.run([HEXE, "pod", "share", "--uuid", pane_uuid, "--on"], capture_output=True, text=True, env=env, timeout=10)
if r_share_on.returncode != 0 or "not shared" not in r_share_on.stdout or "\x1b[" in r_share_on.stdout:
    fail(f"piped `hexe pod share --on` broken: rc={r_share_on.returncode} out={r_share_on.stdout!r}")

# Palette set + get swatch check on TTY vs plain when piped (broadcast so attached pane sniffs & parks it)
r_pset = subprocess.run([HEXE, "palette", "set", "--ns", "0", "1=#ff5500"], capture_output=True, text=True, env=env, timeout=10)
if r_pset.returncode != 0:
    fail(f"`hexe palette set` failed: rc={r_pset.returncode} err={r_pset.stderr!r}")
time.sleep(0.8)
r_pget_pipe = subprocess.run([HEXE, "palette", "get", "--ns", "0", "1"], capture_output=True, text=True, env=env, timeout=10)
if r_pget_pipe.returncode != 0 or "\x1b[" in r_pget_pipe.stdout or "1=#ff5500" not in r_pget_pipe.stdout:
    fail(f"piped `hexe palette get` broken: rc={r_pget_pipe.returncode} out={r_pget_pipe.stdout!r}")
rc_pget_tty, pty_pget = run_pty_capture([HEXE, "palette", "get", "--ns", "0", "1"])
if rc_pget_tty != 0 or b"\x1b[38;2;255;85;0m" not in pty_pget:
    fail(f"PTY `hexe palette get` expected 24-bit color swatch: rc={rc_pget_tty} out={pty_pget!r}")

# `hexe pod new` piped JSON vs PTY styled summary card + `hexe pod kill` confirmation
# Note: pod daemon inherits stderr, so capture stdout only (like shell `$(hexe pod new)`).
import json as _json
r_pnew = subprocess.run([HEXE, "pod", "new", "-n", "smokepod"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env, timeout=10)
if r_pnew.returncode != 0 or "\x1b[" in r_pnew.stdout:
    fail(f"piped `hexe pod new` failed: rc={r_pnew.returncode} out={r_pnew.stdout!r}")
pnew_obj = _json.loads(r_pnew.stdout)
if pnew_obj.get("type") != "pod_new" or len(pnew_obj.get("uuid", "")) != 32:
    fail(f"piped `hexe pod new` bad JSON: {pnew_obj!r}")
r_pkill = subprocess.run([HEXE, "pod", "kill", "--uuid", pnew_obj["uuid"]], capture_output=True, text=True, env=env, timeout=10)
if r_pkill.returncode != 0 or "Sent TERM to pod" not in r_pkill.stdout or "\x1b[" in r_pkill.stdout:
    fail(f"piped `hexe pod kill` unexpected: rc={r_pkill.returncode} out={r_pkill.stdout!r} err={r_pkill.stderr!r}")

rc_pnew_tty, pty_pnew = run_pty_capture([HEXE, "pod", "new", "-n", "smokepod2"])
pty_pnew_plain = ANSI_RE.sub("", pty_pnew.decode("utf-8", errors="replace"))
if rc_pnew_tty != 0 or b"\x1b[" not in pty_pnew or "Created pod smokepod2" not in pty_pnew_plain:
    fail(f"PTY `hexe pod new` expected styled summary card: rc={rc_pnew_tty} out={pty_pnew_plain!r}")
m_p2 = re.search(r"UUID:\s+([0-9a-f]{32})", pty_pnew_plain)
if m_p2:
    subprocess.run([HEXE, "pod", "kill", "--uuid", m_p2.group(1)], capture_output=True, text=True, env=env, timeout=10)
print("pass 10: pod gc/new/kill/share, record status, palette list/get swatches, and terminal info TTY vs pipe contracts")

cleanup()
print("SMOKE PASS: all CLI UI & attach/detach interaction checks succeeded")
