#!/usr/bin/env python3
"""A painter for hexe: draws the status bar and pane/float titles.

hexe draws no chrome of its own. It connects to a socket, asks for a named view
at a given width, and composites the styled runs that come back. This program
answers those requests. It is stdlib-only and deliberately small — copy it and
make the bar yours, or write your own in any language (see docs/regions.md for
the wire format).

    python3 contrib/painter.py &
    hexe

By default it binds $HEXE_PAINTER_SOCKET, else $XDG_RUNTIME_DIR/hexe/painter.sock,
which is where hexe looks when its config says nothing.
"""
import json
import os
import socket
import struct
import sys
import time

# ---------------------------------------------------------------- appearance
#
# Modelled on oslo's prompt, which is the palette this setup already speaks:
# basic ANSI colours, bold for emphasis, dim white separators, and no background
# anywhere. The bar sits on the terminal's own background, so it reads as part
# of the shell rather than as a painted strip.
#
#   bresilla@tron | I | sh >        ❮  (develop)  ~/data/code/tools/hexe
#      36    1;35   2;37  1;32          32           1;34

S_TIME = "fg:6"             # cyan, as the username is
S_SEP = "dim fg:7"          # the " | " between things
S_SESSION = "bold fg:5"     # magenta, as the host is
S_TAB_ACTIVE = "bold fg:2"  # green, as the prompt mark is
S_TAB_INACTIVE = "dim fg:7"
S_REC = "bold fg:1"
S_BATTERY = "fg:3"
S_DIR = "bold fg:4"         # blue, as the prompt's cwd is
S_PROGRESS = "bold fg:3"    # yellow; red when the task reported an error

SEP = " | "


# ------------------------------------------------------------------- segments


def fish_truncate(path, home):
    """~/data/code/tools/hexe -> ~/d/c/t/hexe"""
    if not path:
        return "/"
    p = path
    if home and p.startswith(home):
        p = "~" + p[len(home):]
    if p.startswith("~"):
        lead, rest = "~", p[1:]
    else:
        lead, rest = "", p
    parts = [c for c in rest.split("/") if c]
    if not parts:
        return p[:1] or "/"
    short = [c[0] for c in parts[:-1]] + [parts[-1]]
    joined = "/".join(short)
    return f"{lead}/{joined}" if lead else f"/{joined}"


def battery_text():
    base = "/sys/class/power_supply"
    try:
        for name in sorted(os.listdir(base)):
            if not name.startswith("BAT"):
                continue
            with open(f"{base}/{name}/capacity") as f:
                pct = f.read().strip()
            status = ""
            try:
                with open(f"{base}/{name}/status") as f:
                    status = f.read().strip()
            except OSError:
                pass
            return ("+" if status == "Charging" else "") + pct + "%"
    except OSError:
        pass
    return None


def run_width(runs):
    return sum(len(r["text"]) for r in runs)


def pad(n):
    """Gaps are unstyled: styling them would paint a strip across the row."""
    return [{"text": " " * n, "style": ""}] if n > 0 else []


# --------------------------------------------------------------------- views


def view_status(req):
    ctx = req.get("context", {}) or {}
    vals = ctx.get("values", {}) or {}
    width = int(req.get("width") or 80)
    regions = []

    # ---- left: clock, session
    left = [{"text": " " + time.strftime("%H:%M:%S"), "style": S_TIME}]
    session = vals.get("session") or ""
    if session:
        left.append({"text": SEP, "style": S_SEP})
        left.append({"text": session, "style": S_SESSION})

    # ---- centre: tabs
    tabs = vals.get("tabs") or []
    active = int(vals.get("active_tab") or 0)
    centre, tab_spans = [], []
    for i, name in enumerate(tabs):
        if i:
            centre.append({"text": SEP, "style": S_SEP})
        tab_spans.append((i, run_width(centre), len(name)))
        centre.append({"text": name, "style": S_TAB_ACTIVE if i == active else S_TAB_INACTIVE})

    # ---- right: progress, recording, battery, cwd
    right, rec_off = [], None
    # OSC 9;4 from the focused pane. `hexe` parses the sequence and forwards the
    # state; rendering it is the painter's call.
    # progress lives under context.values, alongside session/tabs -- reading it
    # from `ctx` returned None forever, so this whole segment was dead.
    pstate = vals.get("progress_state") or "inactive"
    if pstate != "inactive":
        pct = vals.get("progress_pct")
        if pstate == "indeterminate" or pct is None:
            ptext = "progress ..."
        elif pstate == "error":
            ptext = f"progress {pct}% !"
        elif pstate == "paused":
            ptext = f"progress {pct}% (paused)"
        else:
            ptext = f"progress {pct}%"
        right.append({"text": ptext, "style": "bold fg:1" if pstate == "error" else S_PROGRESS})
    if vals.get("recording"):
        if right:
            right.append({"text": SEP, "style": S_SEP})
        # Offset of REC within `right`, not 0: progress may precede it, and the
        # click region has to land on the text actually drawn.
        rec_off = run_width(right)
        right.append({"text": "REC", "style": S_REC})
    bat = battery_text()
    if bat:
        if right:
            right.append({"text": SEP, "style": S_SEP})
        right.append({"text": bat, "style": S_BATTERY})
    cwd = ctx.get("cwd") or ""
    if cwd:
        if right:
            right.append({"text": SEP, "style": S_SEP})
        right.append({"text": fish_truncate(cwd, ctx.get("home") or ""), "style": S_DIR})
    if right:
        right.append({"text": " ", "style": ""})

    # ---- lay out: centre the tabs, right-align the tail
    lw, cw, rw = run_width(left), run_width(centre), run_width(right)
    centre_start = max(lw + 1, (width - cw) // 2)
    if centre_start + cw + rw > width:
        centre_start = max(lw + 1, width - rw - cw)

    runs = list(left)
    runs += pad(centre_start - lw)
    runs += centre
    used = centre_start + cw
    runs += pad(max(0, width - used - rw))
    right_start = max(used, width - rw)
    runs += right

    for idx, off, w in tab_spans:
        regions.append({
            "id": f"tab.{idx + 1}", "x": centre_start + off, "y": 0,
            "width": w, "height": 1,
            "actions": {"left": f"tab.select.{idx + 1}"},
        })
    if rec_off is not None:
        regions.append({
            "id": "recording", "x": right_start + rec_off, "y": 0,
            "width": 3, "height": 1,
            "actions": {"left": "record.switch", "right": "record.stop"},
            "hover_style": "bold fg:15",
        })

    return {
        "mode": "run",
        "runs": runs,
        "width": min(run_width(runs), width),
        "next_frame_ms": 1000,
        "regions": regions,
    }


def view_title(req):
    ctx = req.get("context", {}) or {}
    vals = ctx.get("values", {}) or {}
    title = vals.get("title") or ctx.get("title") or ""
    if not title:
        return {"mode": "run", "runs": [], "width": 0, "next_frame_ms": None}
    style = S_TAB_ACTIVE if vals.get("active", True) else S_TAB_INACTIVE
    text = f" {title} "
    return {"mode": "run", "runs": [{"text": text, "style": style}],
            "width": len(text), "next_frame_ms": None}


VIEWS = {
    "status": view_status,
    "float.title": view_title,
    "container.title": view_title,
}


# ---------------------------------------------------------------------- serve


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
    return json.loads(body)


def send_frame(conn, obj):
    body = json.dumps(obj).encode()
    conn.sendall(struct.pack(">I", len(body)) + body)


def socket_path():
    if os.environ.get("HEXE_PAINTER_SOCKET"):
        return os.environ["HEXE_PAINTER_SOCKET"]
    rt = os.environ.get("XDG_RUNTIME_DIR")
    if rt:
        os.makedirs(f"{rt}/hexe", exist_ok=True)
        return f"{rt}/hexe/painter.sock"
    d = f"/tmp/hexe-{os.getuid()}"
    os.makedirs(d, exist_ok=True)
    return f"{d}/painter.sock"


def main():
    path = socket_path()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o600)
    srv.listen(16)
    print(f"painter listening on {path}", file=sys.stderr)

    while True:
        try:
            conn, _ = srv.accept()
        except KeyboardInterrupt:
            break
        except OSError:
            continue
        try:
            req = recv_frame(conn)
            if req is None:
                continue
            name = (req.get("select") or [""])[0]
            fn = VIEWS.get(name)
            if fn is None:
                send_frame(conn, {"version": 1, "ok": False,
                                  "error": f"unknown view {name!r}"})
                continue
            send_frame(conn, {"version": 1, "ok": True, "output": fn(req)})
        except (OSError, ValueError, KeyError):
            # A bad frame must never take the painter down; hexe keeps its last
            # good one and asks again.
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    srv.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    main()
