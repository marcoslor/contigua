#!/usr/bin/env python3
"""Measure the Compact bar title's contrast from a real window capture.

The title's rect comes from the chrome state (window points, top-left origin);
the capture is the window's own pixels at the run's backing scale. The glyphs
are pure black or white ink, so their core pixels are exact: everything within
a couple of pixels of a core pixel is glyph and antialiasing, and the rest of
the rect is the band the title sits on. The worst band pixel is compared with
the tone's ink at the NFR limit. Stdlib only: the e2e runs on the host's
python3.

    bar-title-contrast.py CAPTURE X,Y,W,H WINDOW_WIDTH TONE LIMIT [LABEL]

Prints one line and exits 0 when the measured contrast is at least LIMIT.
"""

import struct
import sys
import zlib


def chunks(data):
    offset = 8  # PNG signature
    while offset + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        body = data[offset + 8:offset + 8 + length]
        yield kind, body
        offset += 12 + length


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("not a PNG: %s" % path)
    width = height = depth = colour = interlace = None
    palette = None
    raw = []
    for kind, body in chunks(data):
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            palette = body
        elif kind == b"IDAT":
            raw.append(body)
    if depth != 8 or interlace != 0:
        raise SystemExit("unsupported PNG: depth=%s interlace=%s" % (depth, interlace))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None:
        raise SystemExit("unsupported PNG colour type %s" % colour)
    decoded = zlib.decompress(b"".join(raw))
    stride = width * channels
    rows = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filt = decoded[offset]
        line = bytearray(decoded[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        if filt == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 255
        elif filt == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 255
        elif filt == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 255
        elif filt == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                predictor = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + predictor) & 255
        elif filt != 0:
            raise SystemExit("unsupported PNG filter %s" % filt)
        rows.append(bytes(line))
        previous = line
    return width, height, channels, palette, rows


def linear(value):
    value = value / 255.0
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def luminance(red, green, blue):
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)


def pixel(row, channels, palette, x):
    index = x * channels
    if channels == 1:
        value = row[index]
        if palette:
            return palette[value * 3], palette[value * 3 + 1], palette[value * 3 + 2]
        return value, value, value
    if channels == 2:
        return row[index], row[index], row[index]
    if channels == 3:
        return row[index], row[index + 1], row[index + 2]
    return row[index], row[index + 1], row[index + 2]


def main():
    if len(sys.argv) < 6:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    x, y, w, h = (int(part) for part in sys.argv[2].split(","))
    window_width = float(sys.argv[3])
    tone = sys.argv[4]
    limit = float(sys.argv[5])
    label = sys.argv[6] if len(sys.argv) > 6 else ""

    if tone == "dark":
        ink_luminance, is_ink = 0.0, lambda value: value <= 0.02
    elif tone == "light":
        ink_luminance, is_ink = 1.0, lambda value: value >= 0.98
    else:
        raise SystemExit("tone must be dark or light, not %s" % tone)

    width, height, channels, palette, rows = read_png(path)
    scale = width / window_width
    left, right = max(0, int(x * scale)), min(width, int((x + w) * scale))
    top, bottom = max(0, int(y * scale)), min(height, int((y + h) * scale))
    if right - left < 4 or bottom - top < 4:
        raise SystemExit("title rect is empty in the capture: %s" % sys.argv[2])

    grid = []
    for row in rows[top:bottom]:
        grid.append([luminance(*pixel(row, channels, palette, column))
                     for column in range(left, right)])
    glyph = [[is_ink(value) for value in line] for line in grid]
    ink = sum(1 for line in glyph for marked in line if marked)
    if ink < 8:
        raise SystemExit("no %s ink pixels found in the title rect (tone not drawn?)" % tone)

    # The antialiased edge runs about a capture pixel from the core; its
    # darker (or brighter) fringe is glyph, not band. Widen the mask by the
    # radius the run's backing scale needs so no fringe pixel reaches the
    # extremes below.
    radius = max(1, int(round(1.5 * scale)))
    band = []
    for line in range(len(grid)):
        for column in range(len(grid[line])):
            glyph_edge = any(
                glyph[near_line][near_column]
                for near_line in range(max(0, line - radius), min(len(grid), line + radius + 1))
                for near_column in range(max(0, column - radius),
                                         min(len(grid[line]), column + radius + 1)))
            if not glyph_edge:
                band.append(grid[line][column])
    if len(band) < 16:
        raise SystemExit("no band pixels left to measure behind the title")

    worst = min(band) if tone == "dark" else max(band)
    contrast = (max(ink_luminance, worst) + 0.05) / (min(ink_luminance, worst) + 0.05)
    print("%scontrast=%.2f tone=%s band=%.3f..%.3f ink_px=%d limit=%.2f"
          % ((label + " ") if label else "", contrast, tone, min(band), max(band),
             ink, limit))
    return 0 if contrast + 1e-9 >= limit else 3


if __name__ == "__main__":
    sys.exit(main())
