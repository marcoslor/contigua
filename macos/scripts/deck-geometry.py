#!/usr/bin/env python3
"""The Deck grid's drawn block, from --debug-deck-grid (e2e `deck`).

The D design's numbers are fixed: 96 pt tiles, 16 pt between columns, and a
block centred in the window and never wider than 880 pt. The geometry lines are
written by DeckGridProbe.reportGeometry on every real geometry change, so the
check resizes the Deck (control deck-size) and reads the settled line back.

usage: deck-geometry.py FILE WIDTH COLUMNS [WAIT_S]

Exit 0 when the newest geometry for a WIDTH-wide window has the expected
column count, the design's cell and gap, and a block that is centred and
capped. On success it prints one line; on failure it prints why and exits 1.
"""
import json
import sys
import time

CELL = 96.0
GAP = 16.0
CAP = 880.0
# A window's content width can differ from the requested width by the vertical
# scroller, never by more. Anything smaller means the resize has not settled.
TOLERANCE = 64


def geometry(path):
    try:
        lines = [json.loads(line) for line in open(path) if line.strip()]
    except FileNotFoundError:
        return None
    blocks = [line for line in lines if "cap" in line]
    return blocks[-1] if blocks else None


def main(path, width, columns, wait):
    width = float(width)
    columns = int(columns)
    deadline = time.time() + wait
    block = None
    while time.time() < deadline:
        block = geometry(path)
        if block and width - TOLERANCE <= block.get("viewport", 0) <= width:
            break
        time.sleep(0.25)
    if not block:
        print("no grid geometry yet")
        return 1
    viewport = block.get("viewport", 0)
    if not (width - TOLERANCE <= viewport <= width):
        print("geometry is for a %.0f pt viewport, not %.0f" % (viewport, width))
        return 1
    problems = []
    if block.get("zoom") != 1:
        problems.append("zoom=%s" % block.get("zoom"))
    if abs(block.get("cell", 0) - CELL) > 0.5:
        problems.append("cell=%.1f" % block.get("cell", 0))
    if abs(block.get("gap", 0) - GAP) > 0.5:
        problems.append("gap=%.1f" % block.get("gap", 0))
    if abs(block.get("cap", 0) - CAP) > 0.5:
        problems.append("cap=%.1f" % block.get("cap", 0))
    if block.get("columns") != columns:
        problems.append("columns=%s, expected %d" % (block.get("columns"), columns))
    span = columns * CELL + max(columns - 1, 0) * GAP
    if abs(block.get("contentWidth", 0) - span) > 0.5:
        problems.append("contentWidth=%.1f, expected %.0f"
                        % (block.get("contentWidth", 0), span))
    left = (viewport - span) / 2
    if abs(block.get("contentLeft", 0) - left) > 0.5:
        problems.append("contentLeft=%.1f, centred would be %.1f"
                        % (block.get("contentLeft", 0), left))
    if problems:
        print("; ".join(problems))
        return 1
    print("%d cols, %.0f pt block, %.1f pt margins (viewport %.0f)"
          % (columns, span, left, viewport))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    wait = float(sys.argv[4]) if len(sys.argv) > 4 else 15
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3], wait))
