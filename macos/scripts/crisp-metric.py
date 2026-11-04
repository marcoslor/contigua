#!/usr/bin/env python3
"""The crispness metric (ISS-39): how faithfully a Mac stream window shows the
phone's own pixels.

The phone side gives a lossless picture at the stream's size (the fake phone
feeds this exact PNG to its encoder; a real phone draws the same pattern in its
debug activity). This crops the window's capture to the video rect and reports

  * PSNR of the drawn pixels against that reference over the text block, and
  * the 1 px line pattern's Michelson contrast on both axes.

No image library: a small PNG reader/writer (8-bit, no interlace) is all a
screencapture needs. A reference at another size is scaled with ffmpeg's
Lanczos filter first, so the comparison is "what an ideal resampler would show
at the window's pixels" rather than a nearest-neighbour crop.

usage: crisp-metric.py --capture CAP.png --reference REF.png --regions REF.json
                       --crop X,Y,W,H --scale S [--save-crop OUT.png]
                       [--save-zoom OUT.png] [--zoom 4]
The crop is in window points; scale is the display's backing scale.
"""

import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

FFMPEG = os.environ.get("FFMPEG") or shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"


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
        raise ValueError("unsupported PNG %s (depth %d, colour %d)" % (path, depth, colour))
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


def write_png(path, width, height, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw += bytes(row)

    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    with open(path, "wb") as fp:
        fp.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
                 chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def luma_rows(width, height, channels, rows):
    """One luma byte per pixel (BT.709 weights)."""
    out = []
    for row in rows:
        line = bytearray(width)
        for x in range(width):
            off = x * channels
            line[x] = (row[off] * 54 + row[off + 1] * 183 + row[off + 2] * 19) >> 8
        out.append(line)
    return out


def resize_reference(path, width, height):
    """Lanczos-scale the reference to (width, height); returns a temp PNG."""
    handle, out = tempfile.mkstemp(suffix=".png", prefix="crisp-ref-")
    os.close(handle)
    result = subprocess.run(
        [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", path,
         "-vf", "scale=%d:%d:flags=lanczos" % (width, height), out],
        capture_output=True)
    if result.returncode != 0:
        raise ValueError("ffmpeg could not scale the reference: %s" %
                         result.stderr.decode("utf-8", "replace").strip())
    return out


def mse(region_a, region_b, x, y, w, h):
    total = 0
    count = 0
    for row in range(y, y + h):
        a = region_a[row]
        b = region_b[row]
        for col in range(x, x + w):
            delta = a[col] - b[col]
            total += delta * delta
            count += 1
    return total / count if count else 0.0


def contrast(rows, rect, vertical):
    """Michelson contrast of the 1 px line pairs: (max-min)/(max+min) over the
    per-column (vertical lines) or per-row (horizontal lines) mean luma."""
    x, y, w, h = rect
    if w <= 0 or h <= 0:
        return 0.0
    if vertical:
        means = []
        for col in range(x, x + w):
            total = 0
            for row in range(y, y + h):
                total += rows[row][col]
            means.append(total / h)
    else:
        means = []
        for row in range(y, y + h):
            total = 0
            line = rows[row]
            for col in range(x, x + w):
                total += line[col]
            means.append(total / w)
    lo, hi = min(means), max(means)
    return (hi - lo) / (hi + lo) if (hi + lo) > 0 else 0.0


def crop_rect(raw, scale):
    x, y, w, h = raw
    return (int(round(x * scale)), int(round(y * scale)),
            int(round(w * scale)), int(round(h * scale)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--regions", required=True)
    parser.add_argument("--crop", required=True, help="X,Y,W,H in window points")
    parser.add_argument("--scale", type=float, default=1.0)
    parser.add_argument("--save-crop")
    parser.add_argument("--save-zoom")
    parser.add_argument("--zoom", type=int, default=4)
    args = parser.parse_args()

    scale = args.scale
    crop = crop_rect([float(part) for part in args.crop.split(",")], scale)
    cap_w, cap_h, cap_c, cap_rows = read_png(args.capture)
    x, y, w, h = crop
    x = max(0, min(x, cap_w - 1))
    y = max(0, min(y, cap_h - 1))
    w = max(1, min(w, cap_w - x))
    h = max(1, min(h, cap_h - y))
    cap = [row[x * cap_c:(x + w) * cap_c] for row in cap_rows[y:y + h]]
    cap_luma = luma_rows(w, h, cap_c, cap)

    spec = json.load(open(args.regions))
    ref_path = args.reference
    ref_w, ref_h = spec["w"], spec["h"]
    temp = None
    if (ref_w, ref_h) != (w, h):
        temp = resize_reference(ref_path, w, h)
        ref_path = temp
    try:
        got_w, got_h, ref_c, ref_rows = read_png(ref_path)
        ref_luma = luma_rows(got_w, got_h, ref_c, ref_rows)
    finally:
        if temp:
            os.unlink(temp)

    sx = w / float(ref_w)
    sy = h / float(ref_h)

    def mapped(name):
        rx, ry, rw, rh = spec["regions"][name]
        return (int(round(rx * sx)), int(round(ry * sy)),
                max(1, int(round(rw * sx))), max(1, int(round(rh * sy))))

    text = mapped("text")
    # A little air around the glyphs is the "text-heavy region" the PSNR reads.
    margin_x, margin_y = 8, 8
    tx = max(0, text[0] - margin_x)
    ty = max(0, text[1] - margin_y)
    text_region = (tx, ty,
                   max(1, min(w - tx, text[2] + 2 * margin_x)),
                   max(1, min(h - ty, text[3] + 2 * margin_y)))
    error = mse(cap_luma, ref_luma, *text_region)
    psnr = 99.0 if error == 0 else 20.0 * math.log10(255.0) - 10.0 * math.log10(error)
    contrast_v = contrast(cap_luma, mapped("vertical"), vertical=True)
    contrast_h = contrast(cap_luma, mapped("horizontal"), vertical=False)

    if args.save_crop:
        write_png(args.save_crop, w, h, cap)
    if args.save_zoom:
        # A 64x64 patch around the text block's centre, nearest-neighbour 4x:
        # the reviewer's record of the glyph edges.
        side = min(64, w, h)
        px = max(0, min(text[0] + text[2] // 2 - side // 2, w - side))
        py = max(0, min(text[1] + text[3] // 2 - side // 2, h - side))
        zoom = max(1, args.zoom)
        rows = []
        for row in range(py, py + side):
            line = bytearray()
            source = cap[row]
            for col in range(px, px + side):
                pixel = source[col * cap_c:col * cap_c + 3]
                line += pixel * zoom
            for _ in range(zoom):
                rows.append(line)
        write_png(args.save_zoom, side * zoom, side * zoom, rows)

    print("psnr=%.2f contrast=%.3f contrast_v=%.3f contrast_h=%.3f crop=%dx%d ref=%dx%d"
          % (psnr, min(contrast_v, contrast_h), contrast_v, contrast_h, w, h, ref_w, ref_h))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        sys.stderr.write("crisp-metric: %s\n" % error)
        sys.exit(2)
