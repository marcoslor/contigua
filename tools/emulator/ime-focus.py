#!/usr/bin/env python3
"""ime-focus: the phone's own screen keeps the top focus and its keyboard.

WIN-51 / ISS-35. One session, one window:

1. Settings' search field on display 0, keyboard shown (baseline).
2. A window for the messenger opens and draws; the field is tapped again and
   the keyboard must come back within 2 s with `mTopFocusedDisplayId=0`.
3. The created display's raw virtual-display flags carry
   STEAL_TOP_FOCUS_DISABLED (`dumpsys display`), and `dumpsys window` says the
   display cannot take the top focus when it prints that field.

Every line says a length, an id, a count or a state. No task label, window
title, typed text or path is printed or written. The shell side owns the boot,
the pairing and the kill.
"""
import hashlib
import http.server
import os
import re
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
import zlib

WT = os.environ["POCKETDECK_WT"]
ADB = os.environ["ADB_BIN"]
SERIAL = "emulator-5554"
HOST = os.environ.get("POCKETDECK_HOST", "127.0.0.1")
PORT = int(os.environ.get("POCKETDECK_PORT", "47996"))
STATE = os.environ["DECKCTL_STATE"]
OUT = os.environ["IME_FOCUS_OUT"]
MESSENGER = os.environ.get("POCKETDECK_MESSENGER", "org.fossify.messages")
BROWSER = os.environ.get("POCKETDECK_BROWSER", "acr.browser.lightning")

sys.path.insert(0, os.path.join(WT, "tools", "fakephone"))
import deckctl  # noqa: E402
import proto  # noqa: E402

TEST_TEXT = "pdime42"
TEST_NON_ASCII = "\u00e9"
WIN = "WIN-51"
FLAG_STEAL_TOP_FOCUS_DISABLED = 1 << 16
OPENED = []

# Keycodes for the fixed test string (ASCII letters and digits only).
KEYCODES = {
    "a": 29, "b": 30, "c": 31, "d": 32, "e": 33, "f": 34, "g": 35, "h": 36,
    "i": 37, "j": 38, "k": 39, "l": 40, "m": 41, "n": 42, "o": 43, "p": 44,
    "q": 45, "r": 46, "s": 47, "t": 48, "u": 49, "v": 50, "w": 51, "x": 52,
    "y": 53, "z": 54, "0": 7, "1": 8, "2": 9, "3": 10, "4": 11, "5": 12,
    "6": 13, "7": 14, "8": 15, "9": 16,
}
KEYCODE_ENTER = 66
FAILED = 0


def log(message):
    print(message, flush=True)


def ok(name, detail=""):
    log("ok [%s] %s%s" % (WIN, name, (": " + detail) if detail else ""))


def fail(name, detail=""):
    global FAILED
    FAILED = 1
    log("FAIL [%s] %s%s" % (WIN, name, (": " + detail) if detail else ""))


def adb(*args, timeout=60):
    return subprocess.run([ADB, "-s", SERIAL] + list(args),
                          capture_output=True, text=True, timeout=timeout)


def sh(*args, timeout=60):
    return adb("shell", *args, timeout=timeout).stdout.replace("\r", "")


# --- the local page the browser test types into (lengths only) --------------
EVENTS = []
EVENTS_LOCK = threading.Lock()
PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>IMEFOCUS PAGE</title>
<style>html,body{margin:0;padding:0;background:#fff}
#f{position:absolute;left:0;top:150px;width:100%;height:110px;font-size:54px;border:6px solid #000}
</style></head><body><input id="f" autofocus>
<script>
var f=document.getElementById('f');
function r(){fetch('/r?n='+f.value.length+'&e='+(f.value.indexOf('\\u00e9')>=0?1:0)).catch(function(){});}
f.addEventListener('input',r);
fetch('/loaded').catch(function(){});
</script></body></html>
"""


class PageHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/r":
            q = urllib.parse.parse_qs(parsed.query)
            try:
                length = int((q.get("n") or ["-1"])[0])
            except ValueError:
                length = -1
            has_e = (q.get("e") or ["0"])[0] == "1"
            with EVENTS_LOCK:
                EVENTS.append(("input", length, has_e))
        elif parsed.path == "/loaded":
            with EVENTS_LOCK:
                EVENTS.append(("loaded",))
        elif parsed.path == "/":
            body = PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


def start_page():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), PageHandler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


def events_since(mark):
    with EVENTS_LOCK:
        return list(EVENTS[mark:])


def wait_event(mark, pred, link, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for event in events_since(mark):
            if pred(event):
                return event
        link.pump(0.2)
    return None


# --- the session's stream ---------------------------------------------------
class Link:
    """Keeps the session's JSON, counts frames, drops the video payloads."""

    def __init__(self, client):
        self.client = client
        self.messages = []
        self.cursor = 0
        self.frames = {}
        self.configs = {}
        self.closed = False

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            frame = self.client.recv(min(0.25, max(0.01, end - time.time())))
            if frame is None:
                self.closed = True
                return
            if frame is deckctl.TIMEOUT:
                continue
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                self.messages.append(msg)
                self._print(msg)
            elif frame.type == proto.TYPE_VIDEO_CONFIG:
                _codec, w, h, _sps = proto.unpack_video_config(frame)
                self.configs[frame.stream] = (w, h)
            elif frame.type == proto.TYPE_VIDEO_FRAME:
                self.frames[frame.stream] = self.frames.get(frame.stream, 0) + 1

    def _print(self, msg):
        kind = msg.get("t")
        if kind == "window.opened":
            log("MSG window.opened stream=%s displayId=%s taskId=%s"
                % (msg.get("stream"), msg.get("displayId"), msg.get("taskId")))
        elif kind == "window.closed":
            log("MSG window.closed stream=%s reason=%s"
                % (msg.get("stream"), msg.get("reason")))
        elif kind == "window.title":
            log("MSG window.title stream=%s pkg=%s len=%s"
                % (msg.get("stream"), msg.get("pkg"), len(msg.get("title") or "")))
        elif kind == "error":
            log("MSG error stream=%s code=%s" % (msg.get("stream"), msg.get("code")))

    def next_of(self, kind, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            while self.cursor < len(self.messages):
                msg = self.messages[self.cursor]
                self.cursor += 1
                if msg.get("t") == kind:
                    return msg
            self.pump(min(0.25, max(0.01, deadline - time.time())))
        return None

    def titles(self, stream=None):
        return [m for m in self.messages if m.get("t") == "window.title"
                and (stream is None or m.get("stream") == stream)]


def open_window(link, stream, pkg, w=640, h=480, dpi=160):
    link.client.send_json({"t": "window.open", "stream": stream,
                           "w": w, "h": h, "dpi": dpi, "pkg": pkg})
    opened = link.next_of("window.opened", 30)
    if not opened:
        return None
    OPENED.append(stream)
    display = int(opened.get("displayId") or 0)
    deadline = time.time() + 20
    while time.time() < deadline and stream not in link.frames:
        link.pump(0.25)
    log("WINDOW stream=%d pkg=%s display=%d task=%s frames=%s config=%s"
        % (stream, pkg, display, opened.get("taskId"), link.frames.get(stream, 0),
           link.configs.get(stream)))
    return display


# --- the phone's own display 0 ---------------------------------------------
def field_center(xml, want):
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return None
    best = None
    for node in root.iter("node"):
        rid = (node.get("resource-id") or "").lower()
        text = ((node.get("text") or "") + " " + (node.get("content-desc") or "")).lower()
        cls = (node.get("class") or "").lower()
        if want not in rid and want not in text and want not in cls:
            continue
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds") or "")
        if not m:
            continue
        x0, y0, x1, y1 = map(int, m.groups())
        if x1 <= x0 or y1 <= y0:
            continue
        center = ((x0 + x1) // 2, (y0 + y1) // 2, node.get("class") or rid)
        if "edittext" in cls:
            return center
        best = best or center
    return best


def uiautomator_dump(tag):
    path = "/data/local/tmp/imefocus-%s.xml" % tag
    for _ in range(3):
        adb("shell", "uiautomator", "dump", path)
        out = sh("cat", path)
        if "<hierarchy" in out:
            return out
        time.sleep(1.0)
    return ""


def settings_field(tag):
    sh("am", "start", "-W", "-a", "android.settings.SETTINGS")
    time.sleep(1.2)
    field = field_center(uiautomator_dump(tag + "-home"), "edittext")
    if field is None:
        bar = field_center(uiautomator_dump(tag + "-home"), "search")
        if bar is not None:
            log("SETTINGS %s: tapping the search bar (%d,%d)" % (tag, bar[0], bar[1]))
            tap_display0(bar[0], bar[1])
            time.sleep(1.2)
        field = field_center(uiautomator_dump(tag + "-search"), "edittext")
    if field is None:
        return None
    log("SETTINGS %s: field (%d,%d) %s" % (tag, field[0], field[1], field[2]))
    return (field[0], field[1])


def tap_display0(x, y):
    adb("shell", "input", "-d", "0", "tap", str(x), str(y))


def ime_state():
    out = sh("dumpsys", "input_method")
    # Window titles never enter these lines: `mCurClient` is a ClientState and
    # the rest are ids, policies and booleans.
    keep = ("mInputShown", "mShowRequested", "mImeWindowVis", "mCurClient",
            "mCurMethodId", "mCurId", "mCurDisplayId", "mCurTokenDisplayId",
            "mSelfReportedDisplayId")
    lines = [line.strip() for line in out.splitlines()
             if any(key in line for key in keep)]
    shown = None
    display = None
    for line in lines:
        m = re.search(r"mInputShown=(\w+)", line)
        if m and shown is None:
            shown = m.group(1) == "true"
        m = re.search(r"mSelfReportedDisplayId=(\d+)", line)
        if m:
            display = int(m.group(1))
    return shown, display, lines


def save_lines(name, lines):
    with open(os.path.join(OUT, name), "w") as fp:
        fp.write("\n".join(lines))


def window_state():
    out = sh("dumpsys", "window")
    top = None
    for line in out.splitlines():
        m = re.search(r"mTopFocusedDisplayId=(\d+)", line)
        if m:
            top = int(m.group(1))
    can = {}
    current = None
    for line in out.splitlines():
        m = re.search(r"Display: mDisplayId=(\d+)", line)
        if m:
            current = int(m.group(1))
        m = re.search(r"mCanStealTopFocus=(\w+)", line)
        if m:
            display = current
            same = re.search(r"displayId[= ](\d+)", line)
            if same:
                display = int(same.group(1))
            if display is not None:
                can[display] = m.group(1)
    return top, can


def display_flags(stream):
    """The created display's raw virtual-display flags from `dumpsys display`."""
    out = sh("dumpsys", "display")
    lines = out.splitlines()
    name = "pocketdeck-%d" % stream
    start = None
    for index, line in enumerate(lines):
        if 'DisplayDeviceInfo{"%s"' % name in line:
            start = index
            break
    if start is None:
        return None, None
    block = []
    for line in lines[start:]:
        if block and line.strip().startswith("DisplayDeviceInfo{"):
            break
        block.append(line)
    raw = None
    for line in block:
        m = re.match(r"\s*mFlags=(\d+)\s*$", line)
        if m:
            raw = int(m.group(1))
    return lines[start].strip(), raw


def ime_log():
    out = sh("logcat", "-d", "-s", "ImeTracker:I", "InputDispatcher:I")
    return [line for line in out.splitlines()
            if "ImeTracker" in line or "InputDispatcher" in line]


def clear_logcat():
    adb("shell", "logcat", "-c")


# --- the window's own input ------------------------------------------------
def start_debug(display, field):
    clear_logcat()
    sh("am", "start", "-W", "--display", str(display),
       "-n", "dev.pocketdeck/.app.PasteDebugActivity", "--es", "field", field)
    deadline = time.time() + 10
    while time.time() < deadline:
        text = sh("logcat", "-d", "-s", "PasteDebug:I")
        if "ready field=%s" % field in text:
            return True
        time.sleep(0.3)
    return False


def debug_log():
    return sh("logcat", "-d", "-s", "PasteDebug:I")


def wait_debug(pattern, timeout=6.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        text = debug_log()
        if re.search(pattern, text):
            return True
        time.sleep(0.3)
    return False


def type_keys(link, stream, text):
    for ch in text:
        code = KEYCODES[ch]
        link.client.send_raw(proto.pack_key(stream, proto.KEY_DOWN, code, 0))
        time.sleep(0.04)
        link.client.send_raw(proto.pack_key(stream, proto.KEY_UP, code, 0))
        time.sleep(0.04)


def send_key(link, stream, code):
    link.client.send_raw(proto.pack_key(stream, proto.KEY_DOWN, code, 0))
    time.sleep(0.04)
    link.client.send_raw(proto.pack_key(stream, proto.KEY_UP, code, 0))


def tap_stream(link, stream, nx, ny):
    link.client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, nx, ny))
    time.sleep(0.06)
    link.client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, nx, ny))
    link.pump(0.3)


def send_text(link, stream, text):
    link.client.send_json({"t": "text", "stream": stream, "text": text})


def make_png(path):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + \
            struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    rows = b"".join(b"\x00" + bytes((x * 3 + y * 5) % 256 for x in range(48 * 3))
                    for y in range(48))
    png = b"\x89PNG\r\n\x1a\n" + \
        chunk(b"IHDR", struct.pack(">IIBBBBB", 48, 48, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)
    return png


def clip_image(link, data, ident):
    """The Mac's ⌘V image: clip.image.* with paste:true, then the phone's answer."""
    link.client.send_json({"t": "clip.image.start", "id": ident, "mime": "image/png",
                           "size": len(data), "paste": True})
    offset = 0
    while offset < len(data):
        end = min(offset + (256 << 10), len(data))
        link.client.send_raw(proto.pack_frame(proto.TYPE_CLIP_DATA, ident, data[offset:end]))
        offset = end
    link.client.send_json({"t": "clip.image.end", "id": ident, "size": len(data),
                           "sha256": hashlib.sha256(data).hexdigest()})
    deadline = time.time() + 15
    while time.time() < deadline:
        for msg in link.messages:
            if msg.get("t") == "clip.image.done" and msg.get("id") == ident:
                return msg
        link.pump(0.25)
    return None


def drop_file(link, data, ident, target):
    """The Mac's drop: drop.start with the window's package, then the bytes."""
    link.client.send_json({"t": "drop.start", "id": ident, "name": "pdime42.png",
                           "mime": "image/png", "size": len(data),
                           "sha256": hashlib.sha256(data).hexdigest(),
                           "index": 1, "count": 1, "target": target})
    deadline = time.time() + 15
    while time.time() < deadline:
        if any(msg.get("t") == "drop.progress" and msg.get("id") == ident
               for msg in link.messages):
            break
        link.pump(0.2)
    offset = 0
    while offset < len(data):
        end = min(offset + (256 << 10), len(data))
        link.client.send_raw(proto.pack_frame(proto.TYPE_DROP_DATA, ident, data[offset:end]))
        offset = end
    deadline = time.time() + 30
    while time.time() < deadline:
        for msg in link.messages:
            if msg.get("t") == "drop.result" and msg.get("id") == ident:
                return msg
        link.pump(0.25)
    return None


# --- the check --------------------------------------------------------------
def main():
    os.makedirs(OUT, exist_ok=True)
    server, page_port = start_page()
    log("PAGE serving on 127.0.0.1:%d (the emulator reaches it at 10.0.2.2)" % page_port)

    state = deckctl.ClientState(STATE)
    client = deckctl.open_session(HOST, PORT, state, on_code=None)
    link = Link(client)
    log("SESSION connected: device=%s" % client.device_id)
    try:
        return run(link, page_port)
    finally:
        try:
            for stream in OPENED:
                client.send_json({"t": "window.close", "stream": stream})
            link.pump(0.5)
        except Exception:
            pass
        client.close()
        server.shutdown()
        sh("rm", "-f", "/data/local/tmp/imefocus-home.xml",
           "/data/local/tmp/imefocus-baseline-home.xml",
           "/data/local/tmp/imefocus-baseline-search.xml",
           "/data/local/tmp/imefocus-window-home.xml",
           "/data/local/tmp/imefocus-window-search.xml")


def run(link, page_port):
    clear_logcat()

    # 1. the baseline: display 0's own keyboard with no window.
    field = settings_field("baseline")
    if field is None:
        fail("the phone's own search field", "no EditText in Settings")
        return 1
    tap_display0(field[0], field[1])
    deadline = time.time() + 2.0
    shown = False
    while time.time() < deadline and not shown:
        shown, _display, _lines = ime_state()
        if not shown:
            time.sleep(0.2)
    _shown, _client, lines = ime_state()
    save_lines("ime-baseline.txt", lines)
    if shown:
        ok("the phone's keyboard shows before any window", "mInputShown=true")
    else:
        fail("the phone's keyboard shows before any window", "mInputShown=false")
        return 1
    # Put the keyboard away before the window opens, so its return is the proof.
    for _ in range(2):
        if ime_state()[0] is False:
            break
        adb("shell", "input", "-d", "0", "keyevent", "4")
        time.sleep(0.7)
    if ime_state()[0] is not False:
        fail("the phone's keyboard hides again", "mInputShown is not false")
        return 1

    # 2. a window for another app; it draws, then the phone's field is tapped.
    display1 = open_window(link, 1, MESSENGER)
    if not display1:
        fail("a window opens", "no window.opened")
        return 1
    time.sleep(1.0)
    link.pump(0.5)

    tap_display0(field[0], field[1])
    shown_at = None
    started = time.time()
    while time.time() - started < 2.0:
        shown, _client_display, lines = ime_state()
        if shown:
            shown_at = time.time() - started
            break
        link.pump(0.15)
    top, can = window_state()
    shown, client_display, lines = ime_state()
    save_lines("ime-window.txt", lines + [
        "mTopFocusedDisplayId=%s" % top,
        "mCanStealTopFocus=%s" % (" ".join("%d:%s" % (d, v) for d, v in sorted(can.items())) or "absent"),
    ])
    imelog = ime_log()
    save_lines("imelog-window.txt", imelog[-20:])
    detail = ("mTopFocusedDisplayId=%s mCanStealTopFocus=%s mInputShown=%s "
              "clientDisplay=%s shown_after=%s" %
              (top, " ".join("%d:%s" % (d, v) for d, v in sorted(can.items())) or "absent",
               shown, client_display, "%.1fs" % shown_at if shown_at is not None else "never"))
    if top == 0 and shown:
        ok("display-0 keyboard shows with a window open", detail)
    else:
        fail("display-0 keyboard shows with a window open", detail)
    for line in imelog[-6:]:
        log("IMELOG %s" % line)

    # The window display's own flags: the requested bit reached the device.
    info_line, raw = display_flags(1)
    with open(os.path.join(OUT, "flags.txt"), "w") as fp:
        fp.write("window_display=%d\n" % display1)
        fp.write("DisplayDeviceInfo: %s\n" % (info_line or "absent"))
        fp.write("mFlags=%s (STEAL_TOP_FOCUS_DISABLED bit=%s)\n" %
                 (raw, bool(raw is not None and raw & FLAG_STEAL_TOP_FOCUS_DISABLED)))
        fp.write("mTopFocusedDisplayId=%s\n" % top)
        fp.write("mCanStealTopFocus=%s\n" %
                 (" ".join("%d:%s" % (d, v) for d, v in sorted(can.items())) or "absent"))
    log("FLAGS display=%d %s" % (display1, info_line or "DisplayDeviceInfo absent"))
    log("FLAGS display=%d mFlags=%s steal_top_focus_disabled=%s" %
        (display1, raw, bool(raw is not None and raw & FLAG_STEAL_TOP_FOCUS_DISABLED)))
    if raw is not None and raw & FLAG_STEAL_TOP_FOCUS_DISABLED:
        ok("the window's display carries STEAL_TOP_FOCUS_DISABLED",
           "mFlags=%d bit16 set, mTopFocusedDisplayId=%s" % (raw, top))
    else:
        fail("the window's display carries STEAL_TOP_FOCUS_DISABLED",
             "mFlags=%s mTopFocusedDisplayId=%s" % (raw, top))
    if can:
        value = can.get(display1)
        if value == "false":
            ok("the window's display cannot take the top focus",
               "mCanStealTopFocus=false for display %d" % display1)
        else:
            fail("the window's display cannot take the top focus",
                 "mCanStealTopFocus=%s for display %d" % (value, display1))
    else:
        log("NOTE: this build's `dumpsys window` has no mCanStealTopFocus; "
            "the top focus staying on display 0 is the same fact")

    # The final state of the phone's keyboard, for the record.
    shown, client_display, lines = ime_state()
    save_lines("ime-final.txt", lines)
    log("IME final: mInputShown=%s clientDisplay=%s" % (shown, client_display))
    return FAILED


if __name__ == "__main__":
    sys.exit(main())
