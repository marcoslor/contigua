#!/usr/bin/env python3
"""seam-gap.py — a backing row between a framed window's bar and its picture.

Usage:
    seam-gap.py PNG WINDOW_WIDTH BAR_POINTS

WINDOW_WIDTH is the window's width in points (the chrome state's `frame=`),
BAR_POINTS its Compact bar's height (`bar=`). The capture's pixels per point
come from its own width; the seam row is the bar's height in capture pixels.
The picture's first rows must meet the bar there: a row in the three pixels
starting at the seam that is darker than both the row three pixels above it
and the row three pixels below it by MARGIN — across the width — is backing
showing through (ISS-87). A row under the bar's own controls is compared by
its median, so the lights and buttons never count as a gap; the width share
is reported beside it.

Prints `seam=<row> scale=<s> rows=[...]` and exits 0 when no row is a gap.
Stdlib only: `sips` converts the PNG to BMP, which is read without a decoder.
"""
import os
import shutil
import statistics
import struct
import subprocess
import sys
import tempfile

# A row this much darker than both sides, over this share of its columns, is
# the window's backing, not picture.
MARGIN = 12
SHARE = 0.6


def load_bmp(png):
    work = tempfile.mkdtemp(prefix="seam-gap-")
    try:
        bmp = os.path.join(work, "shot.bmp")
        subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(bmp, "rb") as fp:
            data = fp.read()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    if bpp not in (24, 32):
        raise SystemExit("seam-gap: unsupported BMP depth %d" % bpp)
    stride = (width * bpp // 8 + 3) & ~3
    top_down = height < 0
    return data, offset, width, abs(height), bpp // 8, stride, top_down


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    png = sys.argv[1]
    win_w, bar = (float(v) for v in sys.argv[2:4])
    data, offset, width, height, bpp, stride, top_down = load_bmp(png)
    scale = width / win_w
    seam = round(bar * scale)
    # Three pixels on the picture's side of the seam, each compared with the
    # rows three pixels away on both sides.
    reach = max(1, round(3))
    gap_distance = max(1, round(3))
    if seam + reach + gap_distance >= height:
        raise SystemExit("seam row %d is outside a %dx%d capture" % (seam, width, height))

    def row_of(py):
        index = py if top_down else height - 1 - py
        return offset + index * stride

    def luma(py, px):
        i = row_of(py) + px * bpp
        return (data[i] + data[i + 1] + data[i + 2]) / 3.0

    lines, failed = [], False
    for r in range(seam, seam + reach):
        above, below = r - gap_distance, r + gap_distance
        darker, pixels = 0, []
        for px in range(width):
            value = luma(r, px)
            pixels.append(value)
            if value < luma(above, px) - MARGIN and value < luma(below, px) - MARGIN:
                darker += 1
        share = darker / width
        med = statistics.median(pixels)
        gap = (med < statistics.median([luma(above, px) for px in range(width)]) - MARGIN
               and med < statistics.median([luma(below, px) for px in range(width)]) - MARGIN
               and share >= SHARE)
        lines.append("row=%d median=%.0f darker_share=%.2f%s"
                     % (r, med, share, " GAP" if gap else ""))
        failed = failed or gap
    print("seam=%d scale=%.2f %s" % (seam, scale, " ".join(lines)))
    return 3 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
