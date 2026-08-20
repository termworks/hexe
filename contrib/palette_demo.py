#!/usr/bin/env python3
"""Palette namespaces. Run it inside a hexe pane; it paints and exits.

It prints several bands of the SAME indexed colours, each written while a
different namespace was selected, plus one written with none. Then it exits.

Exiting is the point. The process is gone, nothing is redrawing anything, and
the bands are just characters sitting in the pane's scrollback. Recolour a
namespace from outside — `hexe palette set`, or a printf from any other pane —
and those characters change where they sit, because each cell recorded the
namespace that wrote it. The UNCLAIMED band is the control: nothing anyone does
to a namespace should ever move it.

    python3 contrib/palette_demo.py
"""
import os
import sys

# The slots this script claims, and what this script calls them. Slots are
# numbers 0..31 and hexe assigns meaning to none of them — the number IS the
# address a cell records, so there is no mapping to lose. Which program owns
# which number is an agreement between programs, not something hexe arbitrates.
#
# Slot 0 is what cells that selected nothing resolve against, so it is left
# alone here and used as the control. Slot 1 is hexe's own chrome and cannot be
# claimed by a program, so applications start at 2.
BANDS = [(2, "slot 2"), (3, "slot 3"), (4, "slot 4")]

# Which colour indexes each band prints. The same set every time, so a band that
# changes colour changed because of its namespace and nothing else.
INDEXES = [1, 2, 3, 4, 5, 6]

OSC = 1330


def osc(*parts):
    """Emit one OSC 1330 sequence."""
    sys.stdout.write(f"\033]{OSC};" + ";".join(parts) + "\033\\")
    sys.stdout.flush()


def band(slot, label):
    """Print one row of indexed swatches, tagged with `slot`.

    `use` then `end` around the printing is the whole protocol: every cell
    written between them records the slot number, and keeps it for as long as
    the cell lives.
    """
    if slot is not None:
        osc("use", str(slot))
    swatches = "".join(f"\033[48;5;{i}m\033[38;5;15m {i:^3} \033[0m" for i in INDEXES)
    sys.stdout.write(f"  {label:<12}{swatches}\n")
    sys.stdout.flush()
    if slot is not None:
        osc("end")


def main():
    # Give each band a starting palette so there is something to change. `set`
    # creates the namespace and patches entries; it does NOT select it.
    for slot, _ in BANDS:
        osc("set", str(slot), *[f"{i}=#444444" for i in INDEXES])

    sys.stdout.write("\n\033[1m  palette namespaces — same indexes, different namespaces\033[0m\n\n")
    for slot, label in BANDS:
        band(slot, label)
    band(None, "unclaimed")
    sys.stdout.write("\n")

    uuid = os.environ.get("HEXE_PANE_UUID", "")
    # The CLI wants the full 32-char uuid, not a prefix.
    pane = f" --pane {uuid}" if uuid else ""
    print("  This process has exited. The bands above are just cells now.")
    print("  Recolour a band from anywhere and watch them change in place:\n")
    for slot, _ in BANDS:
        print(f"    hexe palette set --ns {slot} 1=#ff5555 2=#50fa7b{pane}")
    print(f"\n    hexe palette set --ns {BANDS[0][0]} bg=#221111{pane}       # the band's blanks too")
    print(f"    hexe palette reset --ns {BANDS[0][0]}{pane}                  # back to your theme")
    print(f"    hexe palette get --ns {BANDS[0][0]}{pane}                    # what is actually set")
    print("\n  Or straight from a shell, no hexe CLI involved:\n")
    print(f"    printf '\\033]{OSC};set;{BANDS[0][0]};1=#ff00aa\\033\\\\'")
    print(f"\n    hexe palette set --ns 0 1=#ff0000{pane}   # slot 0 = the ordinary palette")
    print("\n  The `unclaimed` row is the control — until you set slot 0, which is")
    print("  exactly what it resolves against.")
    print("  Scroll them off-screen and back, or detach and reattach, then")
    print("  recolour again — the tag rides on the cell, not on this process.")
    if uuid:
        print(f"\n  pane {uuid[:8]}")
    print()

    # Release before exiting. hexe deliberately does not guess when a region
    # ended, so a namespace left selected would be inherited by your shell
    # prompt and everything you type next.
    osc("end")


if __name__ == "__main__":
    main()
