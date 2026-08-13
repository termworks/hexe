#!/usr/bin/env python3
"""Print what a cast looks like on screen at a given moment.

    scripts/demo/frame.py /tmp/hexe-demos/floats.cast          # the last frame
    scripts/demo/frame.py /tmp/hexe-demos/floats.cast 12.5     # at 12.5 seconds
    scripts/demo/frame.py /tmp/hexe-demos/floats.cast --all 3  # every 3 seconds

A film is checked by watching it, and this is how it gets watched without a
browser: the frontend paints cells, so a text dump of the stream shows the
typing and none of the layout. This replays the stream into a screen buffer and
prints the cells -- borders, status bar, tab row and all -- as plain text.

Colours are dropped on purpose. This answers "is the frame right", not "is it
pretty".
"""

import json
import re
import sys

CSI = re.compile(r"\x1b\[([0-9;:?<>!]*)([@-~])")


class Screen:
    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.cells = [[" "] * cols for _ in range(rows)]
        self.x = self.y = 0

    def put(self, ch):
        if self.x >= self.cols:
            self.x = 0
            self.newline()
        self.cells[self.y][self.x] = ch
        self.x += 1

    def newline(self):
        if self.y + 1 >= self.rows:
            self.cells.pop(0)
            self.cells.append([" "] * self.cols)
        else:
            self.y += 1

    def erase_line(self, mode):
        row = self.cells[self.y]
        span = {0: range(self.x, self.cols), 1: range(0, self.x + 1)}.get(mode, range(self.cols))
        for i in span:
            row[i] = " "

    def erase_display(self, mode):
        rows = {0: range(self.y, self.rows), 1: range(0, self.y + 1)}.get(mode, range(self.rows))
        for r in rows:
            self.cells[r] = [" "] * self.cols

    def feed(self, text):
        i = 0
        while i < len(text):
            ch = text[i]
            if ch == "\x1b":
                m = CSI.match(text, i)
                if m:
                    self.csi(m.group(1), m.group(2))
                    i = m.end()
                    continue
                if text.startswith("\x1b]", i):  # OSC, ends at BEL or ST
                    end = text.find("\x07", i)
                    st = text.find("\x1b\\", i)
                    end = min(x for x in (end, st) if x != -1) if (end != -1 or st != -1) else len(text)
                    i = end + (1 if text[end:end + 1] == "\x07" else 2)
                    continue
                if text.startswith("\x1bP", i):  # DCS
                    st = text.find("\x1b\\", i)
                    i = (st + 2) if st != -1 else len(text)
                    continue
                i += 2
                continue
            if ch == "\r":
                self.x = 0
            elif ch == "\n":
                self.newline()
            elif ch == "\b":
                self.x = max(0, self.x - 1)
            elif ch == "\t":
                self.x = min(self.cols - 1, (self.x // 8 + 1) * 8)
            elif ch >= " ":
                self.put(ch)
            i += 1

    def csi(self, params, final):
        if params.startswith("?") or final in "hlmqurt":
            return
        nums = [int(p) for p in re.split("[;:]", params) if p.isdigit()]
        one = nums[0] if nums else None
        if final in "Hf":
            self.y = min(self.rows - 1, (nums[0] if nums else 1) - 1)
            self.x = min(self.cols - 1, (nums[1] if len(nums) > 1 else 1) - 1)
        elif final == "A":
            self.y = max(0, self.y - (one or 1))
        elif final == "B":
            self.y = min(self.rows - 1, self.y + (one or 1))
        elif final == "C":
            self.x = min(self.cols - 1, self.x + (one or 1))
        elif final == "D":
            self.x = max(0, self.x - (one or 1))
        elif final == "G":
            self.x = min(self.cols - 1, (one or 1) - 1)
        elif final == "d":
            self.y = min(self.rows - 1, (one or 1) - 1)
        elif final == "K":
            self.erase_line(one or 0)
        elif final == "J":
            self.erase_display(one or 0)

    def dump(self):
        return "\n".join("".join(row).rstrip() for row in self.cells)


def load(path):
    with open(path) as fh:
        header = json.loads(fh.readline())
        events = [json.loads(line) for line in fh if line.strip()]
    return header, events


def render(path, until):
    header, events = load(path)
    screen = Screen(header["width"], header["height"])
    for at, kind, data in events:
        if kind != "o" or at > until:
            continue
        screen.feed(data)
    return screen.dump()


def main():
    args = [a for a in sys.argv[1:]]
    if not args:
        raise SystemExit("usage: frame.py <cast> [seconds | --all <step>]")
    path = args[0]
    header, events = load(path)
    end = events[-1][0] if events else 0.0
    if len(args) > 2 and args[1] == "--all":
        step = float(args[2])
        at = step
        while at < end + step:
            print("── %s at %.1fs " % (path, min(at, end)) + "─" * 40)
            print(render(path, min(at, end)))
            at += step
    else:
        at = float(args[1]) if len(args) > 1 else end
        print(render(path, at))


if __name__ == "__main__":
    main()
