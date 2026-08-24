#!/usr/bin/env python3
"""A stream plugin, in the shape hexe hands one over.

    hexe.plugin("echo", { command = "contrib/share-echo.py",
                          access = { "stream", "popup" } })

Nothing here knows what hexe is beyond one environment variable. What arrives on
stdin is asciicast v2 -- a header line, then `[t, "o", data]` events -- which is
what `asciinema play` reads, what a `.cast` file contains, and what any other
consumer of terminal recordings already speaks. Point this at a real publisher
and it becomes a sharing tool; as written it just writes a file and tells you
where, which is enough to check the wiring.

Add `typing` to its access and it may also send `[t, "i", data]` back on stdout,
and hexe types that into the pane. View-only versus read-write is the access it
was granted, not a mode it asks for.
"""
import json, os, socket, struct, sys, time

OUT = os.environ.get("SHARE_ECHO_OUT", "/tmp/hexe-share.cast")


def notify(text):
    """Tell the user, through the popup access this plugin declared."""
    sock = os.environ.get("HEXE_API_SOCKET")
    if not sock:
        return
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(sock)
        body = json.dumps({"call": "notify", "arg": text}).encode()
        s.sendall(struct.pack(">I", len(body)) + body)
        s.recv(4096)
        s.close()
    except OSError:
        pass


def main():
    # The first line is the cast header: it names the size, so a viewer can lay
    # the pane out before a single byte of content arrives.
    header = sys.stdin.readline()
    if not header:
        return 1
    meta = json.loads(header)

    out = open(OUT, "w")
    out.write(header)
    out.flush()

    # A real plugin publishes here and shows whatever address it got back. The
    # link is the plugin's business -- hexe has no idea what a URL is.
    notify(f"sharing {meta.get('width')}x{meta.get('height')} -> file://{OUT}")

    for line in sys.stdin:
        out.write(line)
        out.flush()
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(ev, list) or len(ev) < 3:
            continue
        # The one rule that is not optional: a password prompt means the
        # scrollback you kept is already tainted. Clearing it is the point --
        # the bytes that drew the prompt arrived BEFORE hexe could know.
        if ev[1] == "m" and ev[2] == "password-on":
            out.seek(0)
            out.truncate()
            out.write(header)
            out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
