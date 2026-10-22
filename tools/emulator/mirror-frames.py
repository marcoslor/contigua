#!/usr/bin/env python3
"""mirror-frames.py — the phone mirror's picture on the emulator rig (one boot's section).

Opens a phone mirror, resizes it through odd sizes, and at each size reads the
window.content and VIDEO_CONFIG the phone sends, decodes the last frame of that size
and checks it against the picture rect the phone named:

- the non-black area of the frame lies within the rect, to 1 px on every side;
- no black row or column lies inside the rect at any edge (no band in the picture);
- the frame outside the rect is black (the encoder's own letterbox), so the rect is
  where the picture is and nothing else.

Usage: mirror-frames.py --state STATE --addr HOST:PORT [--out DIR]
       mirror-frames.py --self-test
Writes one line per size to OUT/mirror-frames.log and the frames to OUT/*.png.
Stdlib plus ffmpeg and sips (the rig's own decoders). Exit 0 when every size passes.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "fakephone"))
import deckctl  # noqa: E402
import proto  # noqa: E402

# Box sizes in pixels: window sizes, odd ones included (each changes the picked frame).
SIZES = [(608, 1344), (533, 1181), (400, 800), (333, 741), (720, 1000), (1000, 1500)]
SETTLE_S = 1.2          # frames after a config: the last one of the size is decoded
CONFIG_WAIT_S = 15.0    # a resize's config and keyframe must arrive in this time
DARK = 24               # a channel under this is black
BLACK_SHARE = 0.98      # a row or column this black is band, not picture


def read_bmp(path):
    with open(path, "rb") as fp:
        data = fp.read()
    if data[:2] != b"BM":
        raise RuntimeError("sips did not write a BMP")
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    stride = (width * bpp + 3) & ~3
    top_down = height < 0
    return data, offset, width, abs(height), bpp, stride, top_down


class Picture(object):
    """A decoded frame as pixels: dark(x, y) is True for a black pixel."""

    def __init__(self, png):
        tmp = tempfile.mkdtemp(prefix="mirror-frames-")
        try:
            bmp = os.path.join(tmp, "f.bmp")
            subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            (self.data, self.offset, self.w, self.h, self.bpp,
             self.stride, self.top_down) = read_bmp(bmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def _index(self, x, y):
        row = y if self.top_down else self.h - 1 - y
        return self.offset + row * self.stride + x * self.bpp

    def dark(self, x, y):
        i = self._index(x, y)
        return max(self.data[i], self.data[i + 1], self.data[i + 2]) < DARK

    def row_dark_share(self, y, x0, x1):
        return sum(1 for x in range(x0, x1) if self.dark(x, y)) / float(max(1, x1 - x0))

    def col_dark_share(self, x, y0, y1):
        return sum(1 for y in range(y0, y1) if self.dark(x, y)) / float(max(1, y1 - y0))

    def picture_bbox(self):
        """The bounding box (x0, y0, x1, y1) of the non-black pixels, end-exclusive."""
        rows = []
        for y in range(self.h):
            first = next((x for x in range(self.w) if not self.dark(x, y)), None)
            if first is not None:
                last = next(x for x in range(self.w - 1, first - 1, -1) if not self.dark(x, y))
                rows.append((y, first, last))
        if not rows:
            return None
        return (min(first for _, first, _ in rows), rows[0][0],
                max(last for _, _, last in rows) + 1, rows[-1][0] + 1)


def edges_inside(pic, x0, y0, x1, y1):
    """Black rows and columns counted inward from each edge of the rect (band thickness)."""
    def count(lines, is_black):
        n = 0
        for line in lines:
            if not is_black(line):
                break
            n += 1
        return n
    top = count(range(y0, y1), lambda y: pic.row_dark_share(y, x0, x1) >= BLACK_SHARE)
    bottom = count(range(y1 - 1, y0 - 1, -1), lambda y: pic.row_dark_share(y, x0, x1) >= BLACK_SHARE)
    left = count(range(x0, x1), lambda x: pic.col_dark_share(x, y0, y1) >= BLACK_SHARE)
    right = count(range(x1 - 1, x0 - 1, -1), lambda x: pic.col_dark_share(x, y0, y1) >= BLACK_SHARE)
    return top, bottom, left, right


def outside_is_black(pic, x0, y0, x1, y1):
    """Pixels outside the rect are black (the encoder's own letterbox), to a share."""
    outside = dark = 0
    for y in range(0, pic.h, 2):
        for x in range(0, pic.w, 2):
            if x0 <= x < x1 and y0 <= y < y1:
                continue
            outside += 1
            if pic.dark(x, y):
                dark += 1
    return outside == 0 or dark >= BLACK_SHARE * outside


def verdict(pic, rect):
    """(passed, line): the rect against the picture, as the log line says it."""
    x0, y0, w, h = rect
    x1, y1 = x0 + w, y0 + h
    box = pic.picture_bbox()
    if box is None:
        return False, "no picture in the frame"
    bx0, by0, bx1, by1 = box
    near = all(abs(a - b) <= 1 for a, b in ((bx0, x0), (by0, y0), (bx1, x1), (by1, y1)))
    top, bottom, left, right = edges_inside(pic, x0, y0, x1, y1)
    band_free = (top, bottom, left, right) == (0, 0, 0, 0)
    black_out = outside_is_black(pic, x0, y0, x1, y1)
    line = ("bbox=%d,%d,%d,%d rect=%d,%d,%d,%d edges=top=%d,bottom=%d,left=%d,right=%d outside_black=%s"
            % (bx0, by0, bx1 - bx0, by1 - by0, x0, y0, w, h, top, bottom, left, right, black_out))
    return near and band_free and black_out, line


def self_test(out_dir):
    """The analyser on a frame with a known band: rect, edges and outside must come out right."""
    png = os.path.join(out_dir, "self-test.png")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "color=c=0x3080c0:s=190x380,pad=200:400:0:0:black", "-frames:v", "1", png],
                   check=True)
    pic = Picture(png)
    ok, line = verdict(pic, (0, 0, 190, 380))
    if not ok:
        print("SELF-TEST FAIL: %s" % line)
        return 1
    # The same picture with the rect one pixel short must not pass.
    ok, line = verdict(pic, (0, 0, 188, 380))
    if ok:
        print("SELF-TEST FAIL: a rect 2 px short passed: %s" % line)
        return 1
    print("SELF-TEST OK: the 190x380 picture passes and a 188-wide rect fails (%s)" % line)
    return 0


def run_sizes(client, out_dir, log):
    results = []
    client.send_json({"t": "window.open", "stream": 1, "w": SIZES[0][0], "h": SIZES[0][1],
                      "dpi": 450, "mode": "phone"})
    content = None
    segment = None
    last_config = None
    index = 0
    opened = False
    pending_resize = None

    def finish(seg):
        if seg is None or not seg["au"]:
            return
        path = os.path.join(out_dir, "seg-%02d.h264" % seg["index"])
        with open(path, "wb") as fp:
            fp.write(seg["sps"])
            for au in seg["au"]:
                fp.write(au)
        png = os.path.join(out_dir, "frame-%02d-%dx%d.png" % (seg["index"], seg["w"], seg["h"]))
        deckctl.dump_last_frame(path, png)
        results.append((seg, png))

    import time
    deadline = time.time() + 60
    while time.time() < deadline:
        # Checked on every pass: the frames never stop, so a timeout may never come.
        now = time.time()
        if pending_resize is None and segment is not None and now - segment["at"] > SETTLE_S:
            # The picture of the current size has had its frames: decode it, then resize on.
            finish(segment)
            segment = None
            if index >= len(SIZES):
                break
            w, h = SIZES[index]
            client.send_json({"t": "window.resize", "stream": 1, "w": w, "h": h, "dpi": 450})
            pending_resize = (w, h, now)
        elif pending_resize is not None and now - pending_resize[2] > CONFIG_WAIT_S:
            raise RuntimeError("no VIDEO_CONFIG for the resize to %dx%d" % pending_resize[:2])
        frame = client.recv(0.2)
        if frame is deckctl.TIMEOUT:
            continue
        if frame is None:
            raise RuntimeError("the phone closed the connection")
        if frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise RuntimeError("phone error %s" % msg.get("code"))
            if msg.get("t") == "window.opened":
                opened = True
            if msg.get("t") == "window.content" and msg.get("stream") == 1:
                content = (msg["x"], msg["y"], msg["w"], msg["h"])
            continue
        if frame.type == proto.TYPE_VIDEO_CONFIG:
            codec, w, h, sps = proto.unpack_video_config(frame)
            if content is None:
                raise RuntimeError("VIDEO_CONFIG %dx%d without window.content" % (w, h))
            finish(segment)
            index += 1
            segment = {"index": index, "w": w, "h": h, "rect": content, "sps": sps, "au": [],
                       "at": time.time()}
            log.write("config %d: %dx%d rect=%s\n" % (index, w, h, content))
            content = None
            if pending_resize is not None:
                pending_resize = None
            continue
        if frame.type == proto.TYPE_VIDEO_FRAME and segment is not None:
            _pts, _flags, au = proto.unpack_video_frame(frame)
            segment["au"].append(au)
    if not opened:
        raise RuntimeError("no window.opened")
    return results


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--state")
    parser.add_argument("--addr")
    parser.add_argument("--out")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    out_dir = args.out or os.path.join(HERE, "..", "..", ".agent", "emu", "mirror-frames")
    os.makedirs(out_dir, exist_ok=True)
    if args.self_test:
        return self_test(out_dir)
    host, port = args.addr.rsplit(":", 1)
    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(host, int(port), state, on_code=None)
    failed = 0
    log_path = os.path.join(out_dir, "mirror-frames.log")
    with open(log_path, "w") as log:
        try:
            results = run_sizes(client, out_dir, log)
        finally:
            try:
                client.send_json({"t": "window.close", "stream": 1})
            except Exception:  # noqa: BLE001 - the rig is being torn down
                pass
        for seg, png in results:
            ok, line = verdict(Picture(png), seg["rect"])
            text = "PASS" if ok else "FAIL"
            if not ok:
                failed += 1
            msg = "%s frame %dx%d %s" % (text, seg["w"], seg["h"], line)
            print(msg)
            log.write(msg + "\n")
        if len(results) < len(SIZES):
            print("FAIL only %d of %d sizes were decoded" % (len(results), len(SIZES)))
            failed += 1
    print("mirror-frames: %d sizes, %d failed; log %s" % (len(results), failed, log_path))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
