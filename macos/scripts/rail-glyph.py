#!/usr/bin/env python3
"""Measure the rail's drawn letters from a real-render shot (e2e `deck`, DECK-7).

The rail magnifies around the letter under the pointer and freezes its span on
enter; a quiet run forces the enter and the moves, and a visible one walks the
real pointer. This reads the glyph bands back out of the pixels. No image
library: a small PNG reader (8-bit, no interlace) is all a screencapture needs.
A window shot may carry its shadow, so the window is taken to sit centred in
the image.

usage: rail-glyph.py DIR WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X   (the enter set)
       rail-glyph.py IMAGE WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X  (band centres)

RAIL_X is the rail's leading edge in window points (deckrailanchor); the crop
is the rail's 26 pt column only, so the tag left of the rail is never measured.

DIR holds rail-rest.png, rail-enter-m.png, rail-side-leading.png,
rail-side-trailing.png, rail-down-z.png, rail-down-hash.png and rail-away.png
(the side shots and the light one only in the VM). It prints the measured M
height and its implied scale at each step against 2.2x and 1.0x, A's first ink
row across the moves (which must not move, +/- 1 px at the backing scale),
whether the tag shows on the rail, and A and # whole. The IMAGE form prints
each letter's band centre in window points, for the pointer.
"""

import os
import statistics
import struct
import sys
import zlib

TOLERANCE = 0.15
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
    measured = []
    for top, bottom in found:
        # The band's ink width too: a letter is at most a letter wide, while
        # the toolbar's bottom edge runs across the whole strip.
        first = last = None
        for y in range(top, bottom + 1):
            line = rows[y]
            for x in range(x0 + 2, x1 - 2):
                pixel = line[x * channels:x * channels + 3]
                if max(abs(pixel[i] - background[i]) for i in range(3)) > 20:
                    first = x if first is None else min(first, x)
                    last = x if last is None else max(last, x)
        measured.append({"top": top / scale - margin, "bottom": (bottom + 1) / scale - margin,
                         "height": (bottom + 1 - top) / scale,
                         "width": ((last - first + 1) / scale) if first is not None else 0})
    return measured


def rail_strip(rail_x):
    # The rail's column plus the room the arc reaches into: a magnified letter
    # grows left of the column, so a column-only crop would measure a sliver.
    return (rail_x - 12, rail_x + 26)


STEPS = [("rest", "rail-rest.png"),
         ("enter M", "rail-enter-m.png"),
         ("side leading", "rail-side-leading.png"),
         ("side trailing", "rail-side-trailing.png"),
         ("move Z", "rail-down-z.png"),
         ("move #", "rail-down-hash.png"),
         ("away", "rail-away.png")]
# Which letter is under the pointer in each step: its band is the tallest. The
# dim # is left out of the size check: its 35% ink loses antialiased rows to the
# band threshold, so only its position is measured from the pixels.
TARGET = {"enter M": 12, "side leading": 12, "side trailing": 12, "move Z": 25}
# The steps with the pointer on the rail: A's first ink row is frozen there.
ON_RAIL = ("enter M", "side leading", "side trailing", "move Z", "move #")


def letters(path, width, height, scale, rail_x):
    """The A..# bands, top to bottom, in the rail's strip.

    A window also draws its toolbar's bottom edge at this x, and on a 2x guest
    that line is tall enough to pass for a letter, shifting every index by one.
    The letters sit one rest pitch apart, so a leading band that is not one
    pitch from the next is dropped.
    """
    found = [band for band in bands(path, width, height, scale, rail_strip(rail_x))
             if band["bottom"] <= height - 3]
    # The toolbar's bottom edge runs across this x too, and on a 2x guest it is
    # a band above every letter; the window's bottom rounding is a band below.
    # Both span the strip, so only bands no wider than a letter are letters.
    return [band for band in found if 0 < band["width"] <= 20][:len(NAMES)]


def main():
    if len(sys.argv) != 6:
        print("usage: rail-glyph.py DIR|IMAGE WIDTH_POINTS HEIGHT_POINTS SCALE RAIL_X")
        return 2
    target, width, height, scale = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
    rail_x = float(sys.argv[5])
    if os.path.isfile(target):
        found = letters(target, width, height, scale, rail_x)
        for index, band in enumerate(found):
            print("centre %s %.1f" % (NAMES[index], (band["top"] + band["bottom"]) / 2))
        if found:
            print("peak %.1f" % max(band["height"] for band in found))
        return 0

    failures = []
    draws = {}
    for label, name in STEPS:
        path = os.path.join(target, name)
        if not os.path.exists(path):
            if label.startswith("side"):
                continue        # a quiet run cannot move the pointer sideways
            failures.append("no %s shot (%s)" % (label, name))
            continue
        found = letters(path, width, height, scale, rail_x)
        if len(found) < 20:
            failures.append("%s: %d letter bands" % (label, len(found)))
            continue
        draws[label] = found
    if "rest" not in draws:
        print("; ".join(failures) or "no rest shot")
        return 1

    def tallest(found):
        return max(range(len(found)), key=lambda i: found[i]["height"])

    # The rest ink heights vary a point with antialiasing; the median is the
    # honest base for the ratio.
    base = statistics.median(band["height"] for band in draws["rest"])
    print("step           tallest   implied  expected   A top")
    for label, _ in STEPS:
        if label not in draws:
            continue
        found = draws[label]
        index = tallest(found)
        expected = 2.2 if label in TARGET else 1.0
        implied = found[index]["height"] / base
        print("%-14s %5s %5.1f pt %8.2f %8.2f   %6.2f"
              % (label, NAMES[index], found[index]["height"], implied, expected,
                 found[0]["top"]))
        if label == "move #":
            continue        # dimmed: its slot's scale is the JSON's to prove
        if label not in TARGET:
            continue
        if index != TARGET[label]:
            failures.append("%s: the tallest letter is %s, not %s"
                            % (label, NAMES[index], NAMES[TARGET[label]]))
        if abs(implied - expected) > expected * TOLERANCE + 0.02:
            failures.append("%s: %s is %.2fx, expected %.2fx +/-15%%"
                            % (label, NAMES[index], implied, expected))
    # Sideways inside the column: the scale does not change.
    for label in ("side leading", "side trailing"):
        if label in draws and "enter M" in draws:
            ratio = draws[label][12]["height"] / draws["enter M"][12]["height"]
            if abs(ratio - 1) > 0.05:
                failures.append("%s: M changed to %.2f x the enter's" % (label, ratio))
            print("%s: M %.2f x the enter's (unchanged +/-5%%)" % (label, ratio))

    # The frozen span: on the rail, A's first ink row does not move while the
    # pointer sweeps. Leaving returns it to the rest row.
    rail_tops = {label: draws[label][0]["top"] for label in draws
                 if label in ON_RAIL}
    if rail_tops:
        first = rail_tops.get("enter M", next(iter(rail_tops.values())))
        for label, top in rail_tops.items():
            if abs(top - first) > 1.0 / scale + 0.01:
                failures.append("on the rail, %s: A's top moved to %.2f pt, was %.2f"
                                % (label, top, first))
        print("A's top on the rail: %s (%.2f pt, +/- %.2f)"
              % (", ".join("%s %.2f" % (label, top) for label, top in rail_tops.items()),
                 first, 1.0 / scale))
    if "away" in draws:
        moved = abs(draws["away"][0]["top"] - draws["rest"][0]["top"])
        if moved > 1.0 / scale + 0.01:
            failures.append("away: A's top is %.1f pt from rest" % moved)
        print("A's top back at rest: %.2f (was %.2f)" % (draws["away"][0]["top"],
                                                         draws["rest"][0]["top"]))

    if "enter M" in draws:
        found = draws["enter M"]
        if found[0]["top"] < 1 or found[-1]["bottom"] > height - 1:
            failures.append("a letter is cut at the window's edge")
        tag = bands(os.path.join(target, "rail-enter-m.png"), width, height, scale,
                    (rail_x - 130, rail_x - 22))
        if not tag:
            failures.append("no tag beside the rail on the enter")
        print("tag on the enter: %s" % ("shown" if tag else "missing"))

    light = os.path.join(target, "rail-enter-m-light.png")
    if os.path.exists(light):
        found = letters(light, width, height, scale, rail_x)
        print("light: %d letters on the enter" % len(found))
        if len(found) < 20:
            failures.append("light: %d letters on the enter" % len(found))
    if failures:
        print("; ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
