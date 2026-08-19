#!/usr/bin/env python3
"""Palette namespaces, live. Run it inside a hexe pane.

It paints three bands of indexed colour — one in the prompt zone, one in the
output zone, one in neither — and then waits. Every key below repaints a
namespace *without redrawing a single cell*: the characters already on screen
change colour where they belong to that namespace, and nowhere else. The
DEFAULT band is the control; nothing you press should ever move it.

    python3 contrib/palette_demo.py

Edit SCHEMES to change what a key does. That table is the whole configuration.
"""
import os
import sys
import termios
import tty

# ==========================================================================
# EDIT ME. key -> (namespace, {palette index or 'fg'/'bg'/'cursor': colour})
#
# Namespaces: 'prompt'  the prompt line and what you type on it
#             'output'  command output
#             'alt'     full-screen apps
#             '*'       every live namespace at once
#
# A namespace only overrides the indices you name here. Anything you leave out
# keeps falling through to your terminal's own theme, which is why the bands
# below stay partly untouched.
# ==========================================================================
SCHEMES = {
    "1": ("prompt", {33: "#ff00aa", 208: "#ff5f00", 2: "#00d7af"}),
    "2": ("prompt", {33: "#5fafff", 208: "#87d7ff", 2: "#005f87"}),
    "3": ("output", {33: "#ffd700", 208: "#ffaf00", 2: "#875f00"}),
    "4": ("output", {33: "#8787ff", 208: "#af87ff", 2: "#5f5f87"}),
    "5": ("*", {33: "#666666", 208: "#888888", 2: "#aaaaaa"}),
}

# The indices the bands are painted with. Anything in SCHEMES that is not here
# simply will not be visible — nothing on screen is using it.
RAMP = [1, 2, 3, 4, 5, 6, 33, 208]

OSC = 1330


def seq(*params):
    """One OSC 1330 sequence. This is exactly what `hexe palette` sends."""
    return f"\033]{OSC};" + ";".join(str(p) for p in params) + "\033\\"


def emit(s):
    sys.stdout.write(s)
    sys.stdout.flush()


def band(label, mark):
    """Paint one row of indexed cells, inside the OSC 133 zone `mark`.

    The zone is what decides the namespace: hexe reads it off the row, which is
    also why this keeps working after the row scrolls into history.
    """
    if mark:
        emit(f"\033]133;{mark}\007")
    # One index per cell, as the BACKGROUND, and the digits on it say which.
    # An earlier version put index i in the foreground and i+4 behind it, so
    # "change colour 6" moved a cell labelled 2 and the thin digits of cell 6 —
    # the label lied about what you were looking at.
    #
    # The label is truecolor on purpose: `38;2;r;g;b` is never namespaced, so
    # the digits stay legible no matter what a scheme does to the palette.
    cells = "".join(
        f"\033[48;5;{i}m\033[38;2;255;255;255m{i:>4} \033[0m" for i in RAMP
    )
    emit(f"  {label:<14}{cells}\033[0m\n")


def paint():
    emit("\033[2J\033[H")
    emit("\033[1m  hexe palette namespaces\033[0m\n\n")
    band("PROMPT zone", "A")
    band("OUTPUT zone", "C")
    band("DEFAULT zone", "D")   # OSC 133 D closes the zone: back to slot 0
    emit("\n")
    for key, (ns, colours) in SCHEMES.items():
        names = " ".join(f"{k}={v}" for k, v in colours.items())
        emit(f"   \033[1m{key}\033[0m  {ns:<8} {names}\n")
    emit("   \033[1ma\033[0m  ask — is hexe listening?\n")
    emit("   \033[1mp\033[0m  repaint the bands\n")
    emit("   \033[1mq\033[0m  quit\n\n")
    emit("  The DEFAULT band is the control. If it ever moves, that is a bug.\n")


def apply(key):
    ns, colours = SCHEMES[key]
    # `set` is a patch and accumulates, so this only moves the indices named.
    # Chunked at 32 per sequence, which is the documented cap.
    items = [f"{k}={v}" for k, v in colours.items()]
    for i in range(0, len(items), 32):
        emit(seq("set", ns, *items[i:i + 32]))


def main():
    if not os.environ.get("HEXE_PANE_UUID"):
        print("Not inside a hexe pane — the sequences would be discarded.")
        print("Open hexe first, then run this there.")
        return 1

    paint()
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        while True:
            ch = sys.stdin.read(1)
            if ch in ("q", "\x03", "\x04"):
                break
            if ch in SCHEMES:
                apply(ch)
            elif ch == "a":
                # hexe replies OSC 1330;have;<osc>;<free> on stdin. Nothing is
                # required to ask; silence just means "not hexe".
                emit(seq("ask"))
            elif ch == "p":
                paint()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        emit("\033[0m\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
