#!/usr/bin/env python3
"""Record one asciicast of hexe, driven by a demo script.

The recording is headless. This script opens a pty, starts a real terminal
frontend on it, types into it from outside, and writes what comes back as an
asciicast. Nothing needs a real terminal, so a film can be made over ssh or in
CI exactly as it is made here.

    scripts/demo/record.py scripts/demo/floats.demo [out.cast]

Why not tmux, the way a shell's demos are usually driven: hexe *is* the thing
under the recorder. Running it inside another multiplexer would put a second
key parser and a second renderer between the demo and the film, and the keys
these demos press -- Ctrl+Alt+letter, Alt+digit -- are exactly the ones the
outer multiplexer would want for itself.

The demo script is a line-per-action file:

    cols 120           terminal width  (default 120)
    rows 30            terminal height (default 30)
    speed 0.06         seconds between keystrokes while typing
    name work          session name (default: the demo's own slug)
    launch <argv>      the frontend to record (default: `terminal new --name <name>`)
    env NAME=value     an environment variable the whole stack starts with
    setup <command>    typed into the session before the recorder starts filming
    presh <command>    run on the host before anything starts, not filmed
    run <text>         type it, then Enter
    type <text>        type it, leave the line alone
    key <spec> …       one or more keys: C-M-h, M-1, Up, Enter, Escape, C-c
    wait <seconds>     pause, so a viewer can read what just happened
    clear              clear the pane without showing the command
    sh <command>       run a host command with the demo's environment, filmed
                       only through its effect on screen (`hexe terminal float …`)
    crash              kill the frontend outright, the way a crash would
    spawn <argv>       start another `hexe …` on the same pty, in the same film
    #  …               a comment

`$WORK`, `$HEXE` and `$INSTANCE` are substituted everywhere.

Every demo runs in its own instance, under the fixture's config, HOME and state
directories, so a recording can neither see nor disturb a real session.
"""

import atexit
import errno
import fcntl
import json
import os
import pty
import re
import select
import shlex
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

REPO = os.environ.get("HEXE_REPO",
                      os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
HEXE = os.environ.get("HEXE_BIN", os.path.join(REPO, "zig-out/bin/hexe"))
WORK = os.environ.get("DEMO_WORK", "/tmp/hexe-demo-work")
CAST_DIR = os.environ.get("CAST_DIR", "/tmp/hexe-demos")

# A terminal that answers the questions a TUI asks on startup. Without the
# primary-device reply libvaxis waits out its capability timeout on every
# recording, which is three seconds of nothing at the head of every film.
# Nothing here claims the kitty keyboard protocol: the demos press keys a
# plain xterm can carry, and a film should show what that terminal sees.
QUERY_REPLIES = [
    (b"\x1b[c", b"\x1b[?62;22c"),        # primary device attributes
    (b"\x1b[>c", b"\x1b[>0;10;1c"),      # secondary device attributes
    (b"\x1b[>0q", b"\x1bP>|demo(1)\x1b\\"),  # XTVERSION
    (b"\x1b[6n", b"\x1b[1;1R"),          # cursor position report
]

KEYS = {
    "enter": b"\r", "return": b"\r", "tab": b"\t", "space": b" ",
    "escape": b"\x1b", "esc": b"\x1b", "bspace": b"\x7f", "backspace": b"\x7f",
    "up": b"\x1b[A", "down": b"\x1b[B", "right": b"\x1b[C", "left": b"\x1b[D",
    "home": b"\x1b[H", "end": b"\x1b[F",
    "pageup": b"\x1b[5~", "pagedown": b"\x1b[6~",
    "delete": b"\x1b[3~", "insert": b"\x1b[2~",
    "f1": b"\x1bOP", "f2": b"\x1bOQ", "f3": b"\x1bOR", "f4": b"\x1bOS",
}
ARROWS = {"up": "A", "down": "B", "right": "C", "left": "D"}


def keyspec(spec):
    """One key as the bytes a terminal without the kitty protocol would send.

    `C-` is control, `M-` is meta/alt, `S-` is shift. Modified arrows go out as
    CSI 1 ; <mod> <letter>, modified letters as the control character with an
    ESC in front -- which is what hexe sees from a terminal that never answered
    the kitty query, and therefore what these demos have to press.
    """
    ctrl = alt = shift = False
    while len(spec) > 2 and spec[1] == "-" and spec[0] in "CMSAcmsa":
        head = spec[0].upper()
        ctrl = ctrl or head == "C"
        alt = alt or head in ("M", "A")
        shift = shift or head == "S"
        spec = spec[2:]

    low = spec.lower()
    if low in ARROWS and (ctrl or alt or shift):
        mod = 1 + (1 if shift else 0) + (2 if alt else 0) + (4 if ctrl else 0)
        return ("\x1b[1;%d%s" % (mod, ARROWS[low])).encode()
    if low in KEYS and not (ctrl or alt or shift):
        return KEYS[low]
    if low in KEYS:
        base = KEYS[low]
        return (b"\x1b" + base) if alt else base

    if len(spec) != 1:
        raise SystemExit("unknown key %r" % spec)
    ch = spec
    if ctrl:
        if ch.lower() == "\\":
            ch = "\x1c"
        elif ch.lower() == "]":
            ch = "\x1d"
        elif ch.lower() == "_" or ch == "/":
            ch = "\x1f"
        elif ch.lower() == " ":
            ch = "\x00"
        else:
            ch = chr(ord(ch.lower()) - 96)
    elif shift:
        ch = ch.upper()
    return (b"\x1b" + ch.encode()) if alt else ch.encode()


class Recorder:
    def __init__(self, demo_path, out_path):
        self.slug = os.path.basename(demo_path)[: -len(".demo")]
        self.out = out_path
        self.cols, self.rows, self.speed = 120, 30, 0.06
        self.name = self.slug.replace("-", "_")[:24]
        self.launch = None
        self.extra_env = {}
        self.lines = []
        self.instance = "dem" + re.sub(r"[^a-z0-9]", "", self.slug)[:8]
        self.events = []
        self.t0 = None
        self.recording = False
        self.procs = []
        self.front = None
        self.done = threading.Event()

        with open(demo_path) as fh:
            for raw in fh:
                line = raw.rstrip("\n")
                verb, _, rest = line.partition(" ")
                if verb == "cols":
                    self.cols = int(rest)
                elif verb == "rows":
                    self.rows = int(rest)
                elif verb == "speed":
                    self.speed = float(rest)
                elif verb == "name":
                    self.name = rest.strip()
                elif verb == "launch":
                    self.launch = rest.strip()
                elif verb == "env":
                    k, _, v = rest.partition("=")
                    self.extra_env[k.strip()] = v
                else:
                    self.lines.append((verb, rest))

        if self.launch is None:
            self.launch = "terminal new --name " + self.name

    # ── environment ─────────────────────────────────────────────────────────
    def environ(self):
        env = {
            "PATH": os.path.dirname(os.path.abspath(HEXE)) + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": WORK + "/home",
            "XDG_CONFIG_HOME": WORK + "/config",
            "XDG_STATE_HOME": WORK + "/state",
            "XDG_DATA_HOME": WORK + "/data",
            "XDG_RUNTIME_DIR": WORK + "/run",
            "HEXE_DEMO_BIN": os.path.dirname(os.path.abspath(HEXE)),
            "HEXE_INSTANCE": self.instance,
            "TERM": "xterm-256color",
            "SHELL": "/bin/bash",
            "LANG": "C.UTF-8",
            "COLORTERM": "truecolor",
            "USER": os.environ.get("USER", "demo"),
        }
        for k, v in self.extra_env.items():
            env[k] = self.subst(v)
        return env

    def subst(self, text):
        # Matched to the end of the name, so `$HEXE_INSTANCE` in a demo line is
        # left for the shell instead of being eaten as `$HEXE` plus a suffix.
        table = {"WORK": WORK, "HEXE": HEXE, "INSTANCE": self.instance}
        return re.sub(r"\$(WORK|HEXE|INSTANCE)(?![A-Za-z0-9_])",
                      lambda m: table[m.group(1)], text)

    # ── the pty ─────────────────────────────────────────────────────────────
    def open_pty(self):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", self.rows, self.cols, 0, 0))
        self.reader = threading.Thread(target=self.pump, daemon=True)
        self.reader.start()

    def resize(self, rows):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, self.cols, 0, 0))
        for proc in self.procs:
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGWINCH)
                except OSError:
                    pass

    def pump(self):
        while not self.done.is_set():
            r, _, _ = select.select([self.master], [], [], 0.1)
            if not r:
                continue
            try:
                data = os.read(self.master, 65536)
            except OSError as exc:
                if exc.errno in (errno.EIO, errno.EBADF):
                    return
                continue
            if not data:
                return
            if self.recording:
                self.events.append((time.time() - self.t0, data))
            for query, reply in QUERY_REPLIES:
                if query in data:
                    try:
                        os.write(self.master, reply)
                    except OSError:
                        pass

    # ── processes ───────────────────────────────────────────────────────────
    def spawn_on_pty(self, argv_str):
        argv = [HEXE] + shlex.split(self.subst(argv_str))
        proc = subprocess.Popen(argv, stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                env=self.environ(), cwd=WORK + "/proj", start_new_session=True)
        self.procs.append(proc)
        self.front = proc
        return proc

    def host(self, cmd, background=False):
        proc = subprocess.Popen(["/bin/bash", "-lc", self.subst(cmd)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                env=self.environ(), cwd=WORK + "/proj", start_new_session=True)
        self.procs.append(proc)
        if not background:
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
        return proc

    # ── typing ──────────────────────────────────────────────────────────────
    def send(self, data):
        os.write(self.master, data)

    def type_text(self, text):
        for ch in self.subst(text):
            self.send(ch.encode())
            time.sleep(self.speed)

    # ── the film ────────────────────────────────────────────────────────────
    def run(self):
        if not os.access(HEXE, os.X_OK):
            raise SystemExit("no hexe binary at %s -- run: make build" % HEXE)
        if not os.path.isdir(WORK + "/config/hexe"):
            raise SystemExit("no fixture at %s -- run: scripts/demo/fixture.sh" % WORK)

        atexit.register(self.cleanup)
        self.open_pty()

        for verb, rest in self.lines:
            if verb == "presh":
                self.host(rest)

        self.spawn_on_pty(self.launch)
        time.sleep(4.0)

        # Everything below the setup lines is filmed; nothing above them is. A
        # setup command is typed with a leading space, so it stays out of the
        # shell's history and cannot come back on camera through a recall.
        for verb, rest in self.lines:
            if verb == "setup":
                self.type_text(" " + rest)
                self.send(b"\r")
                time.sleep(0.8)
        self.type_text(" clear")
        self.send(b"\r")
        time.sleep(1.0)

        # **Open the film on a whole frame.** The frontend paints differences,
        # so a recording that simply starts filming mid-session captures the
        # keystrokes and none of the furniture: no status bar, no borders, no
        # tab row, because none of them changed. Shrinking the pty by a row and
        # putting it back is a layout change, and a layout change is repainted
        # in full -- the shrink happens before the first frame, the restore is
        # the first frame.
        self.resize(self.rows - 1)
        time.sleep(0.9)
        self.t0 = time.time()
        self.recording = True
        self.resize(self.rows)
        time.sleep(1.2)

        for verb, rest in self.lines:
            if verb in ("", "#") or verb.startswith("#") or verb in ("setup", "presh"):
                continue
            elif verb == "run":
                self.type_text(rest)
                time.sleep(0.35)
                self.send(b"\r")
                time.sleep(1.1)
            elif verb == "type":
                self.type_text(rest)
            elif verb == "key":
                for spec in rest.split():
                    self.send(keyspec(spec))
                    time.sleep(0.45)
            elif verb == "wait":
                time.sleep(float(rest))
            elif verb == "clear":
                self.type_text("clear")
                self.send(b"\r")
                time.sleep(0.7)
            elif verb == "sh":
                self.host(rest)
                time.sleep(0.6)
            elif verb == "bg":
                self.host(rest, background=True)
                time.sleep(0.6)
            elif verb == "crash":
                if self.front and self.front.poll() is None:
                    os.killpg(os.getpgid(self.front.pid), signal.SIGKILL)
                time.sleep(1.0)
            elif verb == "spawn":
                self.spawn_on_pty(rest)
                time.sleep(3.5)
            else:
                raise SystemExit("unknown verb %r in %s" % (verb, self.slug))

        time.sleep(0.8)
        self.recording = False
        self.write_cast()
        self.cleanup()
        self.report()

    def write_cast(self):
        os.makedirs(os.path.dirname(os.path.abspath(self.out)), exist_ok=True)
        header = {
            "version": 2, "width": self.cols, "height": self.rows,
            "timestamp": int(time.time()), "title": "hexe: " + self.slug,
            "env": {"SHELL": "/bin/bash", "TERM": "xterm-256color"},
        }
        with open(self.out, "w") as fh:
            fh.write(json.dumps(header) + "\n")
            for at, data in self.events:
                fh.write(json.dumps([round(at, 3), "o", data.decode("utf-8", "replace")]) + "\n")

    def cleanup(self):
        self.done.set()
        for proc in self.procs:
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except OSError:
                    pass
        subprocess.run(["pkill", "-9", "-f", "instance " + self.instance],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for fd in ("master", "slave"):
            try:
                os.close(getattr(self, fd))
            except (OSError, AttributeError):
                pass

    def report(self):
        size = os.path.getsize(self.out)
        span = self.events[-1][0] if self.events else 0.0
        print("%s  %.1fs  %d events  %d bytes" % (self.out, span, len(self.events), size))
        if span < 3.0:
            print("  WARNING: %s is shorter than three seconds -- did the frontend start?" % self.slug)
        blob = b"".join(d for _, d in self.events)
        for wrong in (b"panic", b"error: ", b"Shell exited"):
            if wrong in blob:
                print("  WARNING: %r appears in the recording -- watch it before publishing" % wrong)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: record.py <demo-file> [out.cast]")
    demo = sys.argv[1]
    slug = os.path.basename(demo)[: -len(".demo")]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(CAST_DIR, slug + ".cast")
    Recorder(demo, out).run()


if __name__ == "__main__":
    main()
