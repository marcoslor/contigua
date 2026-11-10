#!/usr/bin/env python3
"""The Deck grid's drawn block, from --debug-deck-grid (e2e `deck`).

The design's numbers (DECK-4): 96 pt tiles and a fixed 16 pt pitch at 100 % in
an 880 pt cap, at EVERY window width; a resize only changes the column count,
and past the cap the block is centred with margins and never scaled. The block
reserves the rail's 44 pt on its trailing side, so the rail's column starts one
18 pt gap right of the grid's right edge. The geometry lines are written by
DeckGridProbe.reportGeometry on every real geometry change, so the check resizes
the Deck (control deck-size) and reads the settled line back.

usage: deck-geometry.py FILE WIDTH COLUMNS [WAIT_S]

Exit 0 when the newest geometry for a WIDTH-wide window has the design's cell,
gap and cap, the expected column count, and a block that is centred with the
rail's room and no cell under the rail. On success it prints one line; on
failure it prints why and exits 1.
"""
import json
import sys
import time

CELL = 96.0
GAP = 16.0
CAP = 880.0
RAIL_WIDTH = 26.0
RAIL_GAP = 18.0
RAIL_SPACE = RAIL_WIDTH + RAIL_GAP
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
    cell = CELL
    gap = GAP
    cap = CAP
    span = columns * cell + max(columns - 1, 0) * gap
    left = (viewport - (span + RAIL_SPACE)) / 2
    rail_left = left + span + RAIL_GAP
    problems = []
    if block.get("zoom") != 1:
        problems.append("zoom=%s" % block.get("zoom"))
    if abs(block.get("cell", 0) - cell) > 0.5:
        problems.append("cell=%.1f, expected %.1f" % (block.get("cell", 0), cell))
    if abs(block.get("gap", 0) - gap) > 0.5:
        problems.append("gap=%.1f, expected %.1f" % (block.get("gap", 0), gap))
    if abs(block.get("cap", 0) - cap) > 0.5:
        problems.append("cap=%.1f, expected %.1f" % (block.get("cap", 0), cap))
    if block.get("columns") != columns:
        problems.append("columns=%s, expected %d" % (block.get("columns"), columns))
    if abs(block.get("contentWidth", 0) - span) > 0.5:
        problems.append("contentWidth=%.1f, expected %.0f"
                        % (block.get("contentWidth", 0), span))
    if abs(block.get("contentLeft", 0) - left) > 0.5:
        problems.append("contentLeft=%.1f, centred would be %.1f"
                        % (block.get("contentLeft", 0), left))
    if block.get("contentLeft", 0) + block.get("contentWidth", 0) + RAIL_SPACE > viewport + 0.5:
        problems.append("the block overruns the width: %.1f + %.1f + %.0f > %.1f"
                        % (block.get("contentLeft", 0), block.get("contentWidth", 0),
                           RAIL_SPACE, viewport))
    if abs(block.get("railLeft", 0) - rail_left) > 0.5:
        problems.append("railLeft=%.1f, one gap right of the grid is %.1f"
                        % (block.get("railLeft", 0), rail_left))
    if block.get("railLeft", 0) < block.get("contentLeft", 0) + block.get("contentWidth", 0) + RAIL_GAP - 0.5:
        problems.append("the rail overlaps the grid")
    if block.get("railLeft", 0) + RAIL_WIDTH > viewport + 0.5:
        problems.append("the rail runs past the window")
    if problems:
        print("; ".join(problems))
        return 1
    print("%d cols, %.0f pt tiles, %.0f pt block, %.1f pt margins, "
          "rail at %.1f pt (viewport %.0f)"
          % (columns, cell, span, left, rail_left, viewport))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    wait = float(sys.argv[4]) if len(sys.argv) > 4 else 15
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3], wait))
