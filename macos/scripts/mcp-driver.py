#!/usr/bin/env python3
"""MCP end-to-end driver for the `mcp` check (docs/design/mcp.md).

Speaks MCP to PocketDeck through the built stdio shim, then reads the fakephone
event log to prove what reached the phone: INPUT frames, the link and a dropped
file, plus a screenshot decoded from the image content it got back.

Prints one PASS/FAIL line per assertion. No third-party packages: the PNG is
decoded with zlib and a few filters.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import select
import struct
import subprocess
import sys
import time
import traceback
import zlib

PASSED = 0
FAILED = 0


def report(ok, text):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("PASS " + text)
    else:
        FAILED += 1
        print("FAIL " + text)
    sys.stdout.flush()


def note(text):
    print("DRIVER " + text)
    sys.stdout.flush()


# --- MCP stdio client ------------------------------------------------------

class MCP:
    def __init__(self, shim, profile):
        self.proc = subprocess.Popen(
            [shim, "--profile", profile],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        self.next_id = 0

    def _write(self, object):
        self.proc.stdin.write(json.dumps(object, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)

    def request(self, method, params=None, timeout=60):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            raise RuntimeError("no reply to %s in %ss" % (method, timeout))
        line = self.proc.stdout.readline()
        if not line:
            stderr = self.proc.stderr.read() if self.proc.stderr else ""
            raise RuntimeError("shim closed during %s: %s" % (method, stderr.strip()))
        reply = json.loads(line)
        if reply.get("id") != self.next_id:
            raise RuntimeError("reply id %r for request %r" % (reply.get("id"), self.next_id))
        return reply

    def tool(self, name, arguments=None, timeout=60):
        reply = self.request("tools/call", {"name": name, "arguments": arguments or {}},
                            timeout=timeout)
        if "error" in reply:
            raise RuntimeError("%s: JSON-RPC error %r" % (name, reply["error"]))
        return reply["result"]

    def text(self, name, arguments=None, timeout=60):
        result = self.tool(name, arguments, timeout)
        if result.get("isError"):
            raise RuntimeError("%s: %s" % (name, result["content"][0]["text"]))
        body = result["content"][0]["text"]
        if not body:
            raise RuntimeError("%s: empty result text" % name)
        return json.loads(body)

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


# --- fakephone event log ---------------------------------------------------

def events(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return []
    out = []
    for line in raw.split(b"\n"):
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def wait_event(path, predicate, seconds, description):
    deadline = time.time() + seconds
    while time.time() < deadline:
        for event in events(path):
            if predicate(event):
                return event
        time.sleep(0.2)
    raise RuntimeError("timed out waiting for " + description)


# --- PNG ------------------------------------------------------------------

def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def png_stats(data):
    """(width, height, mean luma, min luma, max luma) of an 8-bit RGB/RGBA PNG."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("screenshot is not a PNG")
    offset = 8
    width = height = bit_depth = color_type = None
    idat = b""
    while offset + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        body = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if width is None or bit_depth != 8 or color_type not in (2, 6):
        raise RuntimeError("unexpected PNG format: depth=%r type=%r" % (bit_depth, color_type))
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(idat)
    previous = bytearray(stride)
    total = 0
    count = 0
    low, high = 255, 0
    position = 0
    for _ in range(height):
        filter_type = raw[position]
        position += 1
        line = bytearray(raw[position:position + stride])
        position += stride
        for index in range(stride):
            left = line[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                line[index] = (line[index] + left) & 0xFF
            elif filter_type == 2:
                line[index] = (line[index] + up) & 0xFF
            elif filter_type == 3:
                line[index] = (line[index] + (left + up) // 2) & 0xFF
            elif filter_type == 4:
                line[index] = (line[index] + _paeth(left, up, upper_left)) & 0xFF
            elif filter_type != 0:
                raise RuntimeError("unknown PNG filter %d" % filter_type)
        previous = line
        for x in range(0, width, 3):
            base = x * channels
            luma = 0.2126 * line[base] + 0.7152 * line[base + 1] + 0.0722 * line[base + 2]
            total += luma
            count += 1
            low = min(low, luma)
            high = max(high, luma)
    return width, height, total / max(1, count), low, high


# --- checks ---------------------------------------------------------------

TOOLS = [
    "phone_status", "list_apps", "open_app", "list_windows", "screenshot",
    "tap", "long_press", "swipe", "type_text", "press_key",
    "close_window", "send_link", "send_file",
]


def within_px(actual, expected, pixels):
    return abs(actual - expected) * pixels <= 1.0 + 1e-6


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shim", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--events", required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--link", default="https://example.com/mcp")
    args = parser.parse_args()

    client = MCP(args.shim, args.profile)
    try:
        initialize = client.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "pocketdeck-e2e", "version": "1"},
        }, timeout=30)
        result = initialize.get("result") or {}
        report(result.get("protocolVersion") == "2025-06-18",
               "MCP initialize answers revision 2025-06-18")
        client.notify("notifications/initialized")

        listing = client.request("tools/list", {}, timeout=30).get("result") or {}
        names = [tool.get("name") for tool in listing.get("tools") or []]
        report(sorted(names) == sorted(TOOLS),
               "MCP tools/list has all %d tools" % len(TOOLS))
        report(all(isinstance(t.get("inputSchema"), dict) and
                   t["inputSchema"].get("type") == "object" for t in listing.get("tools") or []),
               "MCP every tool carries an object input schema")

        # The phone connects shortly after launch.
        status = None
        deadline = time.time() + 60
        while time.time() < deadline:
            status = client.text("phone_status")
            if status.get("connected"):
                break
            time.sleep(0.5)
        report(bool(status and status.get("connected")), "MCP phone_status reports a connected phone")
        report((status or {}).get("name") == "FakePhone",
               "MCP phone_status names the fakephone")
        report((status or {}).get("battery") == 87 and (status or {}).get("charging") is False,
               "MCP phone_status carries the fakephone battery (87 %, not charging)")

        apps = []
        settings = []
        deadline = time.time() + 30
        while time.time() < deadline:
            apps = client.text("list_apps").get("apps") or []
            settings = [a for a in apps if a.get("package") == "com.android.settings"]
            if settings:
                break
            time.sleep(0.5)
        report(bool(settings) and settings[0].get("label") == "Settings",
               "MCP list_apps lists Settings (com.android.settings)")

        opened = client.text("open_app", {"app": "com.android.settings"})
        window = opened.get("window")
        report(isinstance(window, int) and opened.get("package") == "com.android.settings",
               "MCP open_app opens a window for com.android.settings")
        windows = client.text("list_windows").get("windows") or []
        match = [w for w in windows if w.get("id") == window]
        report(bool(match) and match[0].get("package") == "com.android.settings",
               "MCP list_windows shows that window and its package")

        # [WIN-2] The same app asked for again is raised, not reopened: one
        # window, one window.open on the wire.
        again = client.text("open_app", {"app": "com.android.settings"})
        report(again.get("window") == window,
               "MCP open_app again raises the same window")
        time.sleep(1)
        opens = 0
        try:
            for raw in open(args.events, errors="replace"):
                try:
                    event = json.loads(raw)
                except ValueError:
                    continue
                msg = event.get("msg") or {}
                if (event.get("ev") == "rx" and msg.get("t") == "window.open"
                        and msg.get("pkg") == "com.android.settings"):
                    opens += 1
        except OSError:
            opens = -1
        report(opens == 1, "MCP the second open_app sent no window.open (one on the wire)")
        settings_windows = [w for w in (client.text("list_windows").get("windows") or [])
                            if w.get("package") == "com.android.settings"]
        report(len(settings_windows) == 1, "MCP the app still has one window")

        # Wait for the stream's VIDEO_CONFIG: it gives the pixel size that makes
        # the coordinate and screenshot assertions meaningful.
        config = wait_event(args.events,
                            lambda e: e.get("ev") == "video" and e.get("config") and e.get("stream") == window,
                            45, "the window's video config")
        width, height = config.get("w"), config.get("h")
        report(isinstance(width, int) and width > 0 and isinstance(height, int) and height > 0,
               "MCP the fakephone configured the window's stream (%sx%s)" % (width, height))

        # The screenshot: correct size, top side <= 1280, not a flat frame.
        shot = None
        last_error = None
        for _ in range(20):
            reply = client.tool("screenshot", {"window": window}, timeout=30)
            content = (reply.get("content") or [{}])[0]
            if not reply.get("isError") and content.get("type") == "image":
                shot = content
                break
            last_error = content.get("text")
            time.sleep(0.25)
        if shot is None:
            raise RuntimeError("screenshot never returned an image (%s)" % (last_error or "no error text"))
        png = base64.b64decode(shot.get("data") or "")
        shot_width, shot_height, mean, low, high = png_stats(png)
        scale = min(1.0, 1280.0 / max(width, height))
        expected = (max(1, int(width * scale)), max(1, int(height * scale)))
        report(max(shot_width, shot_height) <= 1280,
               "MCP screenshot's longest side is at most 1280 px (%dx%d)" % (shot_width, shot_height))
        report(abs(shot_width - expected[0]) <= 1 and abs(shot_height - expected[1]) <= 1,
               "MCP screenshot has the expected size (expected %dx%d)" % expected)
        report(high - low >= 8 and 5 < mean < 250,
               "MCP screenshot is a real frame (mean luma %.1f, range %.0f..%.0f)" % (mean, low, high))

        # Input. Coordinates are the stream's normalized video coordinates; the
        # event log is checked below against the pixel size.
        client.text("tap", {"window": window, "x": 0.25, "y": 0.4})
        client.text("long_press", {"window": window, "x": 0.55, "y": 0.55, "ms": 250})
        swipe_ms = 400
        client.text("swipe", {"window": window, "x1": 0.2, "y1": 0.7,
                              "x2": 0.8, "y2": 0.3, "ms": swipe_ms})
        client.text("type_text", {"window": window, "text": "mcp test 123"})
        client.text("press_key", {"window": window, "key": "enter"})

        link = client.tool("send_link", {"url": args.link})
        report(not link.get("isError"), "MCP send_link is accepted")

        digest = hashlib.sha256(open(args.file, "rb").read()).hexdigest()
        name = os.path.basename(args.file)
        client.tool("send_file", {"path": args.file}, timeout=90)
        drop = wait_event(args.events,
                          lambda e: e.get("ev") == "drop" and e.get("ok")
                          and any(f.get("name") == name for f in e.get("files") or []),
                          120, "the dropped file")
        dropped = [f for f in drop.get("files") or [] if f.get("name") == name][0]
        report(dropped.get("size") == os.path.getsize(args.file) and dropped.get("sha256") == digest,
               "MCP send_file delivers %s with a matching sha256 (%s…)" % (name, digest[:12]))

        # The phone's log is the source of truth for what input frames arrived.
        wait_event(args.events, lambda e: e.get("ev") == "link" and e.get("url") == args.link,
                   30, "the link")
        report(True, "MCP send_link reaches the phone through link.open")

        time.sleep(0.8)  # let the last frames land in the log
        log = events(args.events)
        touches = [e for e in log if e.get("ev") == "input" and e.get("kind") == "touch"
                   and e.get("stream") == window]
        downs = [e for e in touches if e.get("action") == 0]
        ups = [e for e in touches if e.get("action") == 1]
        moves = [e for e in touches if e.get("action") == 2]

        # Tap: down+up at the same point.
        tap_down = [e for e in downs if within_px(e.get("nx", -1), 0.25, width)
                    and within_px(e.get("ny", -1), 0.4, height)]
        report(bool(tap_down), "MCP tap arrives as a TOUCH down within 1 px of (0.25, 0.4)")
        report(any(within_px(e.get("nx", -1), 0.25, width) and within_px(e.get("ny", -1), 0.4, height)
                   for e in ups), "MCP tap lifts at the same point")

        # Long press: down then up 250 ms later (some scheduling slack).
        long_down = [e for e in downs if within_px(e.get("nx", -1), 0.55, width)
                     and within_px(e.get("ny", -1), 0.55, height)]
        long_up = [e for e in ups if within_px(e.get("nx", -1), 0.55, width)
                   and within_px(e.get("ny", -1), 0.55, height)]
        held = (long_up[0]["ts"] - long_down[0]["ts"]) if long_down and long_up else 0
        report(bool(long_down and long_up and 0.15 <= held <= 1.5),
               "MCP long_press holds for %.0f ms" % (held * 1000))

        # Swipe: exactly one down at the start, interpolated moves, one up at the end.
        swipe_down = [e for e in downs if within_px(e.get("nx", -1), 0.2, width)
                      and within_px(e.get("ny", -1), 0.7, height)]
        swipe_up = [e for e in ups if within_px(e.get("nx", -1), 0.8, width)
                    and within_px(e.get("ny", -1), 0.3, height)]
        report(len(swipe_down) == 1 and len(swipe_up) == 1,
               "MCP swipe starts at (0.2, 0.7) and ends at (0.8, 0.3)")
        ordered = sorted(touches, key=lambda e: e.get("ts", 0))
        start_index = next((i for i, e in enumerate(ordered)
                            if e.get("action") == 0 and e in swipe_down), None)
        end_index = next((i for i, e in enumerate(ordered)
                          if e.get("action") == 1 and e in swipe_up), None)
        between = ordered[start_index:end_index] if start_index is not None and end_index is not None else []
        swipe_moves = [e for e in between if e.get("action") == 2]
        report(len(swipe_moves) >= 5,
               "MCP swipe interpolates at ~60 Hz (%d moves)" % len(swipe_moves))
        monotonic = all(0 <= e.get("nx", -1) <= 1 and 0 <= e.get("ny", -1) <= 1 for e in swipe_moves)
        report(monotonic and (not swipe_moves or
               (swipe_moves[0]["nx"] < swipe_moves[-1]["nx"] and swipe_moves[0]["ny"] > swipe_moves[-1]["ny"])),
               "MCP swipe moves run from the start towards the end")

        texts = [e for e in log if e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                 and e["msg"].get("t") == "text" and e["msg"].get("text") == "mcp test 123"
                 and e["msg"].get("stream") == window]
        report(bool(texts), "MCP type_text reaches the phone as the text frame")

        enter_down = [e for e in log if e.get("ev") == "input" and e.get("kind") == "key"
                      and e.get("stream") == window and e.get("action") == 0 and e.get("keycode") == 66]
        enter_up = [e for e in log if e.get("ev") == "input" and e.get("kind") == "key"
                    and e.get("stream") == window and e.get("action") == 1 and e.get("keycode") == 66]
        report(bool(enter_down and enter_up), "MCP press_key sends KEYCODE_ENTER down and up")

        report(len(downs) == 3 and len(ups) == 3,
               "MCP delivered three gestures (%d downs, %d ups, %d moves)" % (len(downs), len(ups), len(moves)))

        closed = client.text("close_window", {"window": window})
        wait_event(args.events, lambda e: e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                   and e["msg"].get("t") == "window.close" and e["msg"].get("stream") == window,
                   30, "window.close")
        report(closed.get("ok") is True and
               not [w for w in client.text("list_windows").get("windows") or [] if w.get("id") == window],
               "MCP close_window closes the window and tells the phone")
    finally:
        client.close()

    print("DRIVER passed=%d failed=%d" % (PASSED, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # one clear line, then the shell fails the check
        traceback.print_exc()
        print("FAIL " + str(error))
        sys.exit(1)
