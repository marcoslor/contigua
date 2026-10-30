#!/usr/bin/env python3
"""Are two shots of the same window still where it matters? (e2e, DECK-7)

Leaving the rail must return it to rest within 0.3 s, and the rail's pixels are
the proof. The window is not still: the link chip pulses and the toolbar's own
material moves, so a whole-image comparison flakes. This compares the rail's
strip only (its column plus the arc's room), with the same PNG reader
rail-glyph.py uses.

usage: rail-still.py A.png B.png WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X
prints the strip's differing pixels; exits 1 when the rail moved.
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("railglyph", os.path.join(HERE, "rail-glyph.py"))
rail_glyph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rail_glyph)

TOLERANCE = 8          # a channel difference above this is a drawn change


def strip_pixels(path, width_points, height_points, scale, rail_x):
    width, height, channels, rows = rail_glyph.read_png(path)
    margin = rail_glyph.window_margin(path, height_points, scale)
    x0 = max(0, int(round((margin + rail_glyph.rail_strip(rail_x)[0]) * scale)))
    x1 = min(width, int(round((margin + rail_glyph.rail_strip(rail_x)[1]) * scale)))
    y0 = max(0, int(round(margin * scale)))
    y1 = min(height, int(round((margin + height_points) * scale)))
    pixels = []
    for y in range(y0, y1):
        line = rows[y]
        pixels.append(line[x0 * channels:x1 * channels])
    return pixels, x1 - x0, channels


def main():
    if len(sys.argv) != 7:
        print("usage: rail-still.py A.png B.png WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X")
        return 2
    a, b = sys.argv[1], sys.argv[2]
    width, height, scale = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
    rail_x = float(sys.argv[6])
    try:
        rows_a, columns, channels = strip_pixels(a, width, height, scale, rail_x)
        rows_b, _, _ = strip_pixels(b, width, height, scale, rail_x)
    except (OSError, ValueError) as error:
        print("cannot read the shots: %s" % error)
        return 1
    if len(rows_a) != len(rows_b):
        print("the two shots have different heights")
        return 1
    changed = 0
    worst = 0
    for line_a, line_b in zip(rows_a, rows_b):
        for i in range(0, min(len(line_a), len(line_b)) - 2, channels):
            delta = max(abs(line_a[i + c] - line_b[i + c]) for c in range(3))
            worst = max(worst, delta)
            if delta > TOLERANCE:
                changed += 1
    if changed:
        print("%d of %d rail strip pixels moved (worst channel difference %d)"
              % (changed, len(rows_a) * columns, worst))
        return 1
    print("the rail's strip is still (%d x %d pixels, worst difference %d)"
          % (columns, len(rows_a), worst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
