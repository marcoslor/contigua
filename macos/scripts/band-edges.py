#!/usr/bin/env python3
"""band-edges.py — black bands at the edges of the picture in a window screenshot.

Usage:
    band-edges.py PNG WIN_W WIN_H X Y W H

WIN_W and WIN_H are the window's size in points; X, Y, W, H are the picture's
rect in points, top-left origin, relative to the window (the chrome state's
`video=` field). The PNG's pixels per point come from its own width.

Prints `top=N bottom=N left=N right=N`: how many pixel rows or columns, counted
inward from each edge of the picture, are black (at least 98% of their pixels
with every channel under 24). A picture with no band prints zeros everywhere.

Stdlib only. `sips` converts the PNG to BMP, which is read without a decoder.
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile

DARK = 24
BLACK_SHARE = 0.98


def load_bmp(png):
    work = tempfile.mkdtemp(prefix="band-edges-")
    try:
        bmp = os.path.join(work, "shot.bmp")
        subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(bmp, "rb") as fp:
            data = fp.read()
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if data[:2] != b"BM":
        raise SystemExit("band-edges: sips did not write a BMP")
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    if bpp not in (24, 32):
        raise SystemExit("band-edges: unsupported BMP depth %d" % bpp)
    stride = (width * bpp // 8 + 3) & ~3
    top_down = height < 0
    return data, offset, width, abs(height), bpp // 8, stride, top_down


def main(argv):
    if len(argv) != 8:
        raise SystemExit(__doc__)
    png = argv[1]
    win_w, win_h, x, y, w, h = (float(v) for v in argv[2:])
    data, offset, width, height, bpp, stride, top_down = load_bmp(png)
    scale_x = width / win_w
    scale_y = height / win_h
    x0, y0 = round(x * scale_x), round(y * scale_y)
    x1, y1 = min(width, round((x + w) * scale_x)), min(height, round((y + h) * scale_y))

    def row_of(py):
        index = py if top_down else height - 1 - py
        return offset + index * stride

    def row_is_black(py):
        base = row_of(py)
        dark = 0
        for px in range(x0, x1):
            i = base + px * bpp
            if max(data[i], data[i + 1], data[i + 2]) < DARK:
                dark += 1
        return dark >= BLACK_SHARE * (x1 - x0)

    def col_is_black(px):
        dark = 0
        for py in range(y0, y1):
            i = row_of(py) + px * bpp
            if max(data[i], data[i + 1], data[i + 2]) < DARK:
                dark += 1
        return dark >= BLACK_SHARE * (y1 - y0)

    def count(lines, is_black):
        n = 0
        for line in lines:
            if not is_black(line):
                break
            n += 1
        return n

    top = count(range(y0, y1), row_is_black)
    bottom = count(range(y1 - 1, y0 - 1, -1), row_is_black)
    left = count(range(x0, x1), col_is_black)
    right = count(range(x1 - 1, x0 - 1, -1), col_is_black)
    print("top=%d bottom=%d left=%d right=%d" % (top, bottom, left, right))


if __name__ == "__main__":
    main(sys.argv)
