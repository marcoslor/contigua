#!/usr/bin/env python3
"""window-bands.py — black strips at the picture's edges, over a run of window shots.

Usage:
    window-bands.py --dir DIR --bar 28 [--scale 1]

DIR holds `f-*.png`, each a whole window captured by `screencapture -x -o -l`
(the window's own pixels, no shadow) while the `dragbar` check drags an edge.
The picture is the window below its BAR-point bar; the window's rounded
corners are left out of the sampled span. A row or column is black when at
least 98% of it has every channel under 24, the same rule as band-edges.py.

Prints one line:
    frames=N seconds=S fps=F top=N bottom=N left=N right=N worst=N bad=e,dges

and writes `worst-<edge>.png`, a crop of that edge in the frame where it was
widest. Stdlib only; `sips` writes the BMPs and the crops.
"""
import glob
import os
import shutil
import struct
import subprocess
import sys
import tempfile

DARK = 24
BLACK_SHARE = 0.98
CORNER = 16


def argument(name, default=None):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


def load_bmp(png, work):
    bmp = os.path.join(work, os.path.basename(png) + ".bmp")
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(bmp, "rb") as fp:
        data = fp.read()
    if data[:2] != b"BM":
        raise SystemExit("window-bands: sips did not write a BMP")
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    if bpp not in (24, 32):
        raise SystemExit("window-bands: unsupported BMP depth %d" % bpp)
    stride = (width * bpp // 8 + 3) & ~3
    top_down = height < 0
    return data, offset, width, abs(height), bpp // 8, stride, top_down


def measure(png, bar, scale, work):
    data, offset, width, height, bpp, stride, top_down = load_bmp(png, work)

    def row_of(py):
        index = py if top_down else height - 1 - py
        return offset + index * stride

    def dark(px, py):
        i = row_of(py) + px * bpp
        return max(data[i], data[i + 1], data[i + 2]) < DARK

    top_px = min(height - 1, round(bar * scale))
    inset = round(CORNER * scale) + 1
    guard_x0, guard_x1 = 1, width - 2
    y0, y1 = top_px + 1, height - 1 - inset

    def row_black(py, a, b):
        if b < a:
            return False
        return sum(1 for px in range(a, b + 1) if dark(px, py)) >= BLACK_SHARE * (b - a + 1)

    def col_black(px, a, b):
        if b < a:
            return False
        return sum(1 for py in range(a, b + 1) if dark(px, py)) >= BLACK_SHARE * (b - a + 1)

    def count(lines, is_black):
        n = 0
        for line in lines:
            if not is_black(line):
                break
            n += 1
        return n

    top = count(range(top_px, height - inset), lambda py: row_black(py, guard_x0, guard_x1))
    bottom = count(range(height - 1 - inset, top_px - 1, -1),
                   lambda py: row_black(py, inset, width - 1 - inset))
    left = count(range(0, width - inset), lambda px: col_black(px, y0, y1))
    right = count(range(width - 1 - inset, -1, -1), lambda px: col_black(px, y0, y1))
    return {"top": top, "bottom": bottom, "left": left, "right": right}


def crop_edge(png, edge, bar, scale, out):
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", png],
                          check=True, capture_output=True, text=True).stdout
    width = int([line.split(":")[1] for line in size.splitlines() if "pixelWidth" in line][0])
    height = int([line.split(":")[1] for line in size.splitlines() if "pixelHeight" in line][0])
    long_side, short_side = round(240 * scale), round(48 * scale)
    margin = round(60 * scale)
    top_px = round(bar * scale)
    if edge == "top":
        y, x, w, h = top_px, margin, min(long_side, width - 2 * margin), short_side
    elif edge == "bottom":
        y, x, w, h = height - short_side, margin, min(long_side, width - 2 * margin), short_side
    elif edge == "left":
        y, x, w, h = top_px + margin, 0, short_side, min(long_side, height - top_px - 2 * margin)
    else:
        y, x, w, h = top_px + margin, width - short_side, short_side, \
            min(long_side, height - top_px - 2 * margin)
    if w < 1 or h < 1:
        return None
    path = os.path.join(out, "worst-%s.png" % edge)
    subprocess.run(["sips", "-c", str(h), str(w), "--cropOffset", str(y), str(x),
                    png, "--out", path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return path


def main():
    directory = argument("--dir")
    if not directory:
        raise SystemExit(__doc__)
    bar = float(argument("--bar", "28"))
    scale = float(argument("--scale", "1"))
    files = sorted(glob.glob(os.path.join(directory, "f-*.png")),
                   key=lambda p: int(os.path.basename(p)[2:-4]))
    if not files:
        print("frames=0 seconds=0 fps=0 top=? bottom=? left=? right=? worst=? bad=no-frames")
        return 0
    times = [os.stat(path).st_mtime for path in files]
    seconds = max(times) - min(times) if len(times) > 1 else 0.0
    work = tempfile.mkdtemp(prefix="window-bands-")
    try:
        # A clean run has no "worst" frame (every edge 0): keep one frame from
        # the middle of the drag so each edge still has a crop to look at.
        sample = files[len(files) // 2]
        worst = {edge: (0, sample) for edge in ("top", "bottom", "left", "right")}
        for path in files:
            edges = measure(path, bar, scale, work)
            for edge, count in edges.items():
                if count > worst[edge][0]:
                    worst[edge] = (count, path)
        bad = [edge for edge in ("top", "bottom", "left", "right") if worst[edge][0] > 2]
        for edge in ("top", "bottom", "left", "right"):
            crop_edge(worst[edge][1], edge, bar, scale, directory)
        print("frames=%d seconds=%.2f fps=%.1f top=%d bottom=%d left=%d right=%d worst=%d bad=%s" % (
            len(files), seconds, len(files) / seconds if seconds > 0.05 else 0.0,
            worst["top"][0], worst["bottom"][0], worst["left"][0], worst["right"][0],
            max(worst[edge][0] for edge in worst),
            ",".join(bad) if bad else "none"))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
