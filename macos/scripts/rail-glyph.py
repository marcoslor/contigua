#!/usr/bin/env python3
"""Measure the rail's drawn letters from a real-render shot (e2e `deck`, DECK-7).

The visible VM run walks the real pointer in from 96 pt left of the rail to on
it and shoots the rail at each point; this reads the glyph bands back out of the
pixels. No image library: a small PNG reader (8-bit, no interlace) is all a
screencapture needs. A window shot may carry its shadow, so the window is taken
to sit centred in the image.

usage: rail-glyph.py DIR WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X   (six dx shots)
       rail-glyph.py IMAGE WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X  (band centres)

RAIL_X is the rail's leading edge in window points (deckrailanchor); the crop
is the rail's 26 pt column only, so the tag left of the rail is never measured.

DIR holds rail-dx{96,64,40,24,12,0}.png, plus rail-dx0-light.png in the VM. It
prints the measured M height and its implied scale at each dx against A2's pure
scales, the gaps above and below M at dx 0 (17.7 pt +/- 15%), whether A and #
are whole and the tag shows, and N's drawn centre for the click. The IMAGE
form prints each letter's band centre in window points, for the pointer.
"""

import os
import struct
import sys
import zlib

EXPECTED = [(96, 1.00), (64, 1.00), (40, 1.38), (24, 1.82), (12, 2.09), (0, 2.20)]
TOLERANCE = 0.15
GLYPH = 9.0
NAMES = [chr(ord("A") + i) for i in range(26)] + ["#"]


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: %s" % path)
    pos, width, height, depth, colour, interlace, idat = 8, 0, 0, 0, 0, 0, b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if depth != 8 or interlace != 0 or colour not in (2, 6):
        raise ValueError("unsupported PNG")
    channels = 3 if colour == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * channels
    rows = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        line = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += 1 + stride
        for i in range(stride):
            left = line[i - channels] if i >= channels else 0
            up = previous[i]
            upleft = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                line[i] = (line[i] + left) & 0xFF
            elif filter_type == 2:
                line[i] = (line[i] + up) & 0xFF
            elif filter_type == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif filter_type == 4:
                p = left + up - upleft
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - upleft)
                nearest = left if pa <= pb and pa <= pc else (up if pb <= pc else upleft)
                line[i] = (line[i] + nearest) & 0xFF
        rows.append(bytes(line))
        previous = line
    return width, height, channels, rows


def window_margin(path, height_points, scale):
    image_height = read_png(path)[1]
    return max(0.0, (image_height / scale - height_points) / 2)


def bands(path, width_points, height_points, scale, column):
    """The ink bands in a vertical strip, in window points."""
    width, height, channels, rows = read_png(path)
    margin = window_margin(path, height_points, scale)
    x0 = max(0, int(round((margin + column[0]) * scale)))
    x1 = min(width, int(round((margin + column[1]) * scale)))
    y0 = max(0, int(round(margin * scale)))
    y1 = min(height, int(round((margin + height_points) * scale)))
    if x1 <= x0 or y1 <= y0:
        raise ValueError("empty strip %r in %s" % (column, path))
    counts = {}
    for y in range(y0, y1, 2):
        line = rows[y]
        for x in range(x0, x1, 2):
            pixel = line[x * channels:x * channels + 3]
            counts[pixel] = counts.get(pixel, 0) + 1
    background = max(counts, key=counts.get)
    ink = []
    for y in range(y0 + 2, y1 - 3):
        line = rows[y]
        for x in range(x0 + 2, x1 - 2):
            pixel = line[x * channels:x * channels + 3]
            if max(abs(pixel[i] - background[i]) for i in range(3)) > 20:
                ink.append(y)
                break
    found = []
    start = last = None
    for y in ink:
        if start is None:
            start = last = y
        elif y - last <= 2:
            last = y
        else:
            found.append((start, last))
            start = last = y
    if start is not None:
        found.append((start, last))
    found = [band for band in found if band[1] - band[0] >= 2 * scale]
    return [{"top": top / scale - margin, "bottom": (bottom + 1) / scale - margin,
             "height": (bottom + 1 - top) / scale} for top, bottom in found]


def rail_strip(rail_x):
    return (rail_x + 1, rail_x + 25)             # the rail's 26 pt column only


def main():
    if len(sys.argv) != 6:
        print("usage: rail-glyph.py DIR|IMAGE WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X")
        return 2
    target, width, height, scale = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
    rail_x = float(sys.argv[5])
    if os.path.isfile(target):
        found = [band for band in bands(target, width, height, scale, rail_strip(rail_x))
                 if band["bottom"] <= height - 3]
        for index, band in enumerate(found[:len(NAMES)]):
            print("centre %s %.1f" % (NAMES[index], (band["top"] + band["bottom"]) / 2))
        if found:
            print("peak %.1f" % max(band["height"] for band in found))
        return 0

    failures = []
    measured = {}
    images = {}
    for dx, expected in EXPECTED:
        path = os.path.join(target, "rail-dx%d.png" % dx)
        if not os.path.exists(path):
            failures.append("no shot at dx %d" % dx)
            continue
        found = [band for band in bands(path, width, height, scale, rail_strip(rail_x))
                 if band["bottom"] <= height - 3]
        if len(found) < 20:
            failures.append("dx %d: %d letter bands" % (dx, len(found)))
            continue
        measured[dx] = found
        images[dx] = path
    if 96 not in measured:
        print("; ".join(failures) or "no rest shot at dx 96")
        return 1
    rest = measured[96]
    base = rest[12]["height"] if len(rest) > 12 else max(b["height"] for b in rest)

    def peak(found):
        return max(range(len(found)), key=lambda i: found[i]["height"])

    print("dx  measured_M  implied_scale  expected")
    for dx, expected in EXPECTED:
        if dx not in measured:
            continue
        found = measured[dx]
        index = 12 if (dx >= 64 and len(found) > 12) else peak(found)
        height_pt = found[index]["height"]
        implied = height_pt / base
        print("%3d %9.1f pt %12.2f %9.2f" % (dx, height_pt, implied, expected))
        if abs(implied - expected) > expected * TOLERANCE + 0.05:
            failures.append("dx %d: implied scale %.2f, expected %.2f +/- %d%%"
                            % (dx, implied, expected, int(TOLERANCE * 100)))
    if 64 in measured:
        implied = measured[64][12]["height"] / base
        if implied > 1.15:
            failures.append("at the last icon column the letter is %.2f x, over 1.15" % implied)

    if 0 in measured:
        found = measured[0]
        index = peak(found)

        def em(ink):
            return ink / 0.72      # a capital's cap height in Helvetica

        gaps = {}
        if index > 0:
            distance = (found[index]["top"] + found[index]["bottom"]) / 2 \
                - (found[index - 1]["top"] + found[index - 1]["bottom"]) / 2
            gaps["above"] = distance - (em(found[index]["height"]) + em(found[index - 1]["height"])) / 2
        if index + 1 < len(found):
            distance = (found[index + 1]["top"] + found[index + 1]["bottom"]) / 2 \
                - (found[index]["top"] + found[index]["bottom"]) / 2
            gaps["below"] = distance - (em(found[index]["height"]) + em(found[index + 1]["height"])) / 2
        if len(gaps) == 2:
            print("gaps above/below M at dx 0: %.1f / %.1f pt (17.7 +/- 15%%)"
                  % (gaps["above"], gaps["below"]))
            for name, gap in gaps.items():
                if abs(gap - 17.7) > 17.7 * TOLERANCE:
                    failures.append("the gap %s M is %.1f pt, not 17.7 +/- 15%%" % (name, gap))
        if found[0]["top"] < 1 or found[-1]["bottom"] > height - 1:
            failures.append("a letter is cut at the window's edge")
        print("letters drawn: %d (A top %.1f pt, # bottom %.1f pt of %d)"
              % (len(found), found[0]["top"], found[-1]["bottom"], int(height)))
        tag = bands(os.path.join(target, "rail-dx0.png"), width, height, scale,
                    (rail_x - 130, rail_x - 2))
        if not tag:
            failures.append("no tag beside the rail at dx 0")
        print("tag at dx 0: %s" % ("shown" if tag else "missing"))
        print("M centre %.1f pt down the window" % ((found[index]["top"] + found[index]["bottom"]) / 2))
        if index + 1 < len(found):
            below = found[index + 1]
            print("N centre %.1f pt down the window" % ((below["top"] + below["bottom"]) / 2))
    light = os.path.join(target, "rail-dx0-light.png")
    if os.path.exists(light):
        found = bands(light, width, height, scale, rail_strip(rail_x))
        print("light: %d letters at dx 0" % len(found))
        if len(found) < 20:
            failures.append("light: %d letters at dx 0" % len(found))
    if failures:
        print("; ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
