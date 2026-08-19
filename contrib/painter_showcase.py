#!/usr/bin/env python3
"""A painter that draws everything hexe asks an external program to draw.

hexe draws no chrome of its own. It asks a painter over a Unix socket, one
length-prefixed JSON request per region, and composites whatever comes back. So
a statusbar, a spinner, a pane title and a sprite are all the same thing here:
answer a `select` with either styled runs or a block of ANSI.

Wire format (both directions): 4-byte big-endian length, then a JSON body.

Request:
  {"version":1,"select":["status"],"mode":"run"|"surface",
   "width":120,"height":1,"now_ms":...,"ignore_missing":false,
   "context":{"cwd":..,"home":..,"jobs":0,
              "values":{"schema":1,"session":..,"pod_name":..,"tabs":[..],
                        "active_tab":0,"progress_state":..,"hover_region":..,
                        "sprite_name":..,"sprite_shiny":..,"sprite_position":..}}}

Response, run mode (a line of styled text):
  {"version":1,"ok":true,"output":{"mode":"run",
   "runs":[{"text":" hi ","style":"fg:15 bg:237 bold"}],
   "width":4,"next_frame_ms":100,
   "regions":[{"id":"tab.0","x":0,"y":0,"width":6,"height":1,
               "left":"tab.select.0","hover_style":"bg:240"}]}}

Response, surface mode (a rectangle of ANSI, used for sprites):
  {"version":1,"ok":true,"output":{"mode":"surface",
   "ansi":"<ESC>[31mX<ESC>[0m","width":10,"height":4}}

`next_frame_ms` is what makes animation possible: hexe re-asks that region after
that many milliseconds, so a spinner is just a different frame each time.

Run it:
    python3 contrib/painter_showcase.py &
    hexe            # with mux.status.socket pointing at the same path
"""

import json
import os
import socket
import struct
import sys
import time

SOCKET_PATH = os.environ.get(
    "HEXE_PAINTER_SOCKET",
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hexe", "painter.sock"),
)

ESC = "\x1b"

# Optional: record every selector hexe asks for, one per line.
LOG_PATH = os.environ.get("HEXE_PAINTER_LOG")

# Animation. hexe supplies now_ms, so a frame index is a pure function of it --
# no state to keep, and every region stays in step.
BRAILLE = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
PULSE = [236, 238, 240, 242, 244, 246, 244, 242, 240, 238]
FRAME_MS = int(os.environ.get("HEXE_PAINTER_FRAME_MS", "100"))


def frame(now_ms, count):
    return (now_ms // FRAME_MS) % count


# Sprite art. One glyph per cell, 256-colour foreground.
GHOST = [
    "  ppppp  ",
    " ppppppp ",
    "pp.ppp.pp",
    "ppwppppwp",
    "ppppppppp",
    "ppppppppp",
    "p p p p p",
]
PALETTE = {"p": 141, ".": 255, "w": 16, " ": None}
SHINY = {"p": 213, ".": 255, "w": 16, " ": None}
BLOCK = "█"


def sprite_ansi(width, height, shiny, now_ms):
    """Render the sprite as ANSI rows, bobbing one cell on a slow cycle."""
    palette = SHINY if shiny else PALETTE
    bob = 1 if frame(now_ms, 20) >= 10 else 0
    rows = []
    for y in range(height):
        src_y = y - bob
        if src_y < 0 or src_y >= len(GHOST):
            rows.append("")
            continue
        line = GHOST[src_y]
        out = []
        prev = None
        for x in range(min(width, len(line))):
            colour = palette[line[x]]
            if colour is None:
                if prev is not None:
                    out.append(ESC + "[0m")
                    prev = None
                out.append(" ")
                continue
            if colour != prev:
                out.append(ESC + "[38;5;" + str(colour) + "m")
                prev = colour
            out.append(BLOCK)
        if prev is not None:
            out.append(ESC + "[0m")
        rows.append("".join(out))
    return "\r\n".join(rows)


def view_status(req):
    """A statusbar: session, clickable tabs, a live spinner, progress, a clock."""
    ctx = req.get("context", {})
    values = ctx.get("values", {})
    now = req.get("now_ms", 0)
    width = max(int(req.get("width", 80)), 1)

    runs = []
    regions = []
    col = 0

    def emit(text, style, region=None):
        nonlocal col
        if not text:
            return
        runs.append({"text": text, "style": style})
        if region:
            regions.append({
                "id": region["id"], "x": col, "y": 0,
                "width": len(text), "height": 1,
                "left": region["action"], "hover_style": "bg:240 fg:15",
            })
        col += len(text)

    session = values.get("session") or "hexe"
    emit(" " + session + " ", "bg:141 fg:16 bold")

    for i, tab in enumerate(values.get("tabs") or []):
        active = i == values.get("active_tab", 0)
        emit(" " + str(tab) + " ",
             "bg:239 fg:255 bold" if active else "fg:245",
             {"id": "tab." + str(i), "action": "tab.select." + str(i)})

    # The spinner is the animation proof: a different glyph every FRAME_MS.
    spin = BRAILLE[frame(now, len(BRAILLE))]
    pulse = PULSE[frame(now, len(PULSE))]
    emit(" " + spin + " ", "fg:" + str(pulse))

    cwd = ctx.get("cwd") or ""
    home = ctx.get("home") or ""
    if home and cwd.startswith(home):
        cwd = "~" + cwd[len(home):]
    emit(cwd, "fg:110")

    # Progress the focused pane reported via OSC 9;4.
    if values.get("progress_state") == "in_progress":
        pct = values.get("progress_pct") or 0
        bars = 10
        done = int(pct / 100 * bars)
        emit(" [" + BLOCK * done + "░" * (bars - done) + "] ", "fg:114")

    clock = time.strftime("%H:%M:%S")
    pad = width - col - len(clock) - 1
    if pad > 0:
        emit(" " * pad, "")
    emit(clock + " ", "fg:250 bg:236")

    return {"mode": "run", "runs": runs, "width": min(col, width),
            "next_frame_ms": FRAME_MS, "regions": regions}


def view_title(req, is_float):
    """A float or pane title bar; the float one animates."""
    values = req.get("context", {}).get("values", {})
    title = values.get("title") or values.get("pod_name") or ""
    now = req.get("now_ms", 0)
    if is_float:
        spin = BRAILLE[frame(now, len(BRAILLE))]
        text = "─┤ " + spin + " " + title + " ├"
        return {"mode": "run", "runs": [{"text": text, "style": "fg:141"}],
                "width": len(text), "next_frame_ms": FRAME_MS}
    text = " " + title + " "
    return {"mode": "run", "runs": [{"text": text, "style": "fg:245"}],
            "width": len(text)}


def view_sprite(req):
    """A sprite, in surface mode: a rectangle of ANSI hexe composites as-is."""
    values = req.get("context", {}).get("values", {})
    width = max(int(req.get("width", 9)), 1)
    height = max(int(req.get("height", 7)), 1)
    shiny = bool(values.get("sprite_shiny"))
    return {"mode": "surface",
            "ansi": sprite_ansi(width, height, shiny, req.get("now_ms", 0)),
            "width": width, "height": height, "next_frame_ms": 500}


# Views are matched by SUFFIX, not exact name, so a config that renames them
# (status.sprite_view = "my.sprite") still works -- which is also how the smoke
# proves those config keys are applied rather than merely accepted.
def render(req):
    selectors = req.get("select") or []
    name = selectors[0] if selectors else ""
    if LOG_PATH and name:
        with open(LOG_PATH, "a") as fh:
            fh.write(name + "\n")
    if name.endswith("sprite"):
        return view_sprite(req)
    if "float" in name and name.endswith("title"):
        return view_title(req, True)
    if name.endswith("title"):
        return view_title(req, False)
    if name.endswith("status"):
        return view_status(req)
    return None


def recv_frame(conn):
    hdr = b""
    while len(hdr) < 4:
        chunk = conn.recv(4 - len(hdr))
        if not chunk:
            return None
        hdr += chunk
    need = struct.unpack(">I", hdr)[0]
    body = b""
    while len(body) < need:
        chunk = conn.recv(need - len(body))
        if not chunk:
            return None
        body += chunk
    return body


def send_frame(conn, obj):
    body = json.dumps(obj).encode()
    conn.sendall(struct.pack(">I", len(body)) + body)


def main():
    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o600)
    srv.listen(16)
    print("painter listening on " + SOCKET_PATH, file=sys.stderr, flush=True)

    while True:
        conn, _ = srv.accept()
        try:
            while True:
                raw = recv_frame(conn)
                if raw is None:
                    break
                try:
                    req = json.loads(raw)
                except ValueError:
                    send_frame(conn, {"version": 1, "ok": False, "error": "bad json"})
                    continue
                output = render(req)
                if output is None:
                    send_frame(conn, {"version": 1, "ok": False, "error": "unknown view"})
                else:
                    send_frame(conn, {"version": 1, "ok": True, "output": output})
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
