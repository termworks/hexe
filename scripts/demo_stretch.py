#!/usr/bin/env python3
"""OSC 1332 stretch-line demonstration.

Asks the terminal whether it speaks OSC 1332, then draws every shape the
protocol supports. Resize the pane afterwards: every line stays full width.
Without a `have` reply the same lines are drawn at a fixed width instead.
"""

import os
import select
import shutil
import sys
import termios
import tty

OSC = "\x1b]1332;"
ST = "\x1b\\"


def supported(timeout=0.3):
    if not sys.stdin.isatty():
        return False
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        sys.stdout.write(f"{OSC}ask{ST}")
        sys.stdout.flush()
        reply = b""
        while select.select([fd], [], [], timeout)[0]:
            reply += os.read(fd, 64)
            if reply.endswith(b"\x1b\\"):
                break
        return b"1332;have;1" in reply
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def stretch(*parts):
    out = [f"{OSC}begin{ST}"]
    for part in parts:
        out.append(f"{OSC}fill;{part[1]}{ST}" if isinstance(part, tuple) else part)
    out.append(f"{OSC}end{ST}")
    return "".join(out)


def fixed(*parts, width):
    content = sum(len(p) for p in parts if not isinstance(p, tuple))
    fills = [p for p in parts if isinstance(p, tuple)]
    free = max(width - content, 0)
    out = []
    nth = 0
    for part in parts:
        if isinstance(part, tuple):
            w = free // len(fills) + (1 if nth < free % len(fills) else 0)
            nth += 1
            out.append((part[1] * w)[:w])
        else:
            out.append(part)
    return "".join(out)[:width]


FILL = ("fill", "-")
SHAPES = [
    ("content, then fill", ["---[ ls ]", FILL]),
    ("fill, then content", [FILL, "[ 18:50:59 ]---"]),
    ("content, fill, content", ["---[ ls ]", FILL, "[ 18:50:59 ]---"]),
    ("content, fill, content, fill, content",
     ["[ left ]", FILL, "[ middle ]", ("fill", "="), "[ right ]"]),
    ("a box-drawing pattern", ["┤ build ├", ("fill", "─╌"), "┤ ok ├"]),
    ("right-aligned with a space fill", [("fill", " "), "right edge"]),
]


def main():
    live = supported()
    width = shutil.get_terminal_size().columns
    print(f"OSC 1332 {'supported: lines follow the pane width' if live else 'not supported: fixed width'}")
    for label, parts in SHAPES:
        print(f"\n{label}")
        print(stretch(*parts) if live else fixed(*parts, width=width))


if __name__ == "__main__":
    main()
