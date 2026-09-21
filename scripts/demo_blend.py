#!/usr/bin/env python3
"""Live OSC 1331 colour-mixing demonstration."""

import argparse
import re
import sys
import time
from pathlib import Path

OSC = "\x1b]1331;"
ST = "\x1b\\"
RESET = f"{OSC}reset{ST}\x1b[0m"
DEFAULT_STATE = Path("/tmp/hexe-osc1331-demo.state")

ANSI = {
    "black": 30,
    "red": 31,
    "green": 32,
    "yellow": 33,
    "blue": 34,
    "magenta": 35,
    "cyan": 36,
    "white": 37,
    "bright-black": 90,
    "bright-red": 91,
    "bright-green": 92,
    "bright-yellow": 93,
    "bright-blue": 94,
    "bright-magenta": 95,
    "bright-cyan": 96,
    "bright-white": 97,
}


def parse_state(text):
    fields = text.strip().lower().split()
    if len(fields) != 2:
        raise ValueError("expected: PERCENT COLOR")

    percent = int(fields[0])
    if not 0 <= percent <= 100:
        raise ValueError("percentage must be between 0 and 100")

    color = fields[1]
    if color.isdecimal() and 0 <= int(color) <= 255:
        index = int(color)
        label = f"ANSI color {index}"
        sgr = f"\x1b[38;5;{index}m"
    elif color in ANSI:
        label = color
        sgr = f"\x1b[{ANSI[color]}m"
    elif re.fullmatch(r"#[0-9a-f]{6}", color):
        label = color
        red, green, blue = (int(color[index:index + 2], 16) for index in (1, 3, 5))
        sgr = f"\x1b[38;2;{red};{green};{blue}m"
    else:
        names = ", ".join(ANSI)
        raise ValueError(f"unknown colour {color!r}; use 0..255, #RRGGBB or: {names}")

    return percent, label, sgr


def sample(label, sgr, percent=None):
    scope = "" if percent is None else f"{OSC}use;fg={percent}{ST}"
    end = "" if percent is None else f"{OSC}end{ST}"
    return f"{label:<14} {scope}{sgr}████████████████████  The quick brown fox\x1b[0m{end}"


def render(text):
    percent, color, sgr = parse_state(text)
    print()
    print(f"source={color}  mix={percent}% foreground + {100 - percent}% background")
    print(sample("opaque 100%", sgr))
    print(sample(f"mixed {percent}%", sgr, percent))
    print("-" * 68, flush=True)


def write_initial_state(path):
    if path.exists():
        return
    path.write_text("30 1\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    write_initial_state(args.state)
    print("OSC 1331 live demo")
    print("Run this inside a Hexe pane.")
    print(f"Watching: {args.state}")
    print("State format: PERCENT COLOR, for example: 30 1 or 65 #ff8800")
    print("Press Ctrl-C to stop.", flush=True)

    previous = None
    previous_error = None
    try:
        while True:
            try:
                current = args.state.read_text(encoding="utf-8")
                if current != previous:
                    render(current)
                    previous = current
                    previous_error = None
            except (OSError, UnicodeError, ValueError) as error:
                message = f"ERROR: {error}"
                if message != previous_error:
                    print(message, flush=True)
                    previous_error = message

            if args.once:
                return
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        print(RESET, end="", flush=True)


if __name__ == "__main__":
    main()
