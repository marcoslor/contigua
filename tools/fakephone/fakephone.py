#!/usr/bin/env python3
"""fakephone - a protocol-faithful fake PocketDeck phone.

Speaks docs/PROTOCOL.md v1 on a TCP socket, advertises over mDNS via the macOS
`dns-sd` CLI, and produces real H.264 out of ffmpeg (one process per window
stream). It is the reference server the macOS app and the Android server are
tested against, so the wire format here is the contract.

Usage:
    python3 fakephone.py --port 0 --auto-allow --events /tmp/ev.jsonl
"""

import argparse
import base64
import errno
import hashlib
import hmac
import json
import os
import random
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proto  # noqa: E402

FFMPEG = os.environ.get("FFMPEG") or shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
DNS_SD = "/usr/bin/dns-sd"

SERVICE_TYPE = "_pocketdeck._tcp"
DEVICE_MODEL = "FakePhone"
SCREEN_W, SCREEN_H, SCREEN_DPI = 1080, 2340, 450
BATTERY = 87
FRAME_RATE = 60

# Backpressure: at most ~250 ms of delta frames pending per stream (60 fps).
MAX_PENDING_DELTA = 15
LOW_PENDING_DELTA = 4

DEFAULT_STATE = os.path.expanduser("~/.pocketdeck-fakephone.json")

APPS = [
    {"pkg": "com.android.settings", "label": "Settings",
     "activity": "com.android.settings/.Settings"},
    {"pkg": "com.whatsapp", "label": "WhatsApp",
     "activity": "com.whatsapp/.Main"},
    {"pkg": "com.android.chrome", "label": "Chrome",
     "activity": "com.android.chrome/com.google.android.apps.chrome.Main"},
    {"pkg": "com.spotify.music", "label": "Spotify",
     "activity": "com.spotify.music/.MainActivity"},
    {"pkg": "com.android.camera2", "label": "Camera",
     "activity": "com.android.camera2/com.android.camera.CameraLauncher"},
    {"pkg": "com.google.android.gm", "label": "Gmail",
     "activity": "com.google.android.gm/.ConversationListActivityGmail"},
    {"pkg": "com.android.dialer", "label": "Phone",
     "activity": "com.android.dialer/.main.impl.MainActivity"},
    {"pkg": "com.google.android.apps.messaging", "label": "Messages",
     "activity": "com.google.android.apps.messaging/.ui.ConversationListActivity"},
    {"pkg": "com.google.android.apps.maps", "label": "Maps",
     "activity": "com.google.android.apps.maps/com.google.android.maps.MapsActivity"},
    {"pkg": "com.android.vending", "label": "Play Store",
     "activity": "com.android.vending/.AssetBrowserActivity"},
    {"pkg": "org.telegram.messenger", "label": "Telegram",
     "activity": "org.telegram.messenger/.DefaultIcon"},
    {"pkg": "com.google.android.youtube", "label": "YouTube",
     "activity": "com.google.android.youtube/.HomeActivity"},
    {"pkg": "com.android.gallery3d", "label": "Gallery",
     "activity": "com.android.gallery3d/.app.GalleryActivity"},
]

# Packages the phone has no icon for: like the real phone, it answers `icon`
# with an empty png.
NO_ICON_PKGS = set()

_EXTRA_LABELS = [
    "Authenticator", "Calculator", "Calendar", "Clock", "Contacts", "Drive", "Files", "Fitbit", "Keep Notes",
    "RootlessJamesDSP", "Netflix", "Slack", "Signal", "Uber", "Waze", "Wallet", "Weather", "Zoom",
    "Duolingo", "Notion", "Podcasts", "Reddit", "Shizuku", "Translate", "Tuner",
]


def add_demo_apps(count, no_icon_every):
    """Grow APPS to `count` entries (screenshots of a full grid); every
    `no_icon_every`-th app of the whole list gets no icon."""
    index = 0
    while len(APPS) < count:
        label = _EXTRA_LABELS[index % len(_EXTRA_LABELS)]
        if index >= len(_EXTRA_LABELS):
            label = "%s %d" % (label, index // len(_EXTRA_LABELS) + 1)
        pkg = "demo.%s" % label.lower().replace(" ", "")
        APPS.append({"pkg": pkg, "label": label, "activity": "%s/.Main" % pkg})
        index += 1
    if no_icon_every > 0:
        for position, app in enumerate(sorted(APPS, key=lambda a: a["label"].lower())):
            if position % no_icon_every == no_icon_every - 1:
                NO_ICON_PKGS.add(app["pkg"])



# --- tiny 5x7 bitmap font (ffmpeg here has no drawtext; we render our own) ---
_GLYPHS = {
    "A": ".###./#...#/#...#/#####/#...#/#...#/#...#",
    "B": "####./#...#/#...#/####./#...#/#...#/####.",
    "C": ".####/#..../#..../#..../#..../#..../.####",
    "D": "####./#...#/#...#/#...#/#...#/#...#/####.",
    "E": "#####/#..../#..../####./#..../#..../#####",
    "F": "#####/#..../#..../####./#..../#..../#....",
    "G": ".###./#...#/#..../#.###/#...#/#...#/.###.",
    "H": "#...#/#...#/#...#/#####/#...#/#...#/#...#",
    "I": "#####/..#../..#../..#../..#../..#../#####",
    "J": "..###/...#./...#./...#./...#./#..#./.##..",
    "K": "#...#/#..#./#.#../##.../#.#../#..#./#...#",
    "L": "#..../#..../#..../#..../#..../#..../#####",
    "M": "#...#/##.##/#.#.#/#.#.#/#...#/#...#/#...#",
    "N": "#...#/##..#/#.#.#/#..##/#...#/#...#/#...#",
    "O": ".###./#...#/#...#/#...#/#...#/#...#/.###.",
    "P": "####./#...#/#...#/####./#..../#..../#....",
    "Q": ".###./#...#/#...#/#...#/#.#.#/#..#./.##.#",
    "R": "####./#...#/#...#/####./#.#../#..#./#...#",
    "S": ".####/#..../#..../.###./....#/....#/####.",
    "T": "#####/..#../..#../..#../..#../..#../..#..",
    "U": "#...#/#...#/#...#/#...#/#...#/#...#/.###.",
    "V": "#...#/#...#/#...#/#...#/#...#/.#.#./..#..",
    "W": "#...#/#...#/#...#/#.#.#/#.#.#/##.##/#...#",
    "X": "#...#/#...#/.#.#./..#../.#.#./#...#/#...#",
    "Y": "#...#/#...#/.#.#./..#../..#../..#../..#..",
    "Z": "#####/....#/...#./..#../.#.../#..../#####",
    "0": ".###./#...#/#..##/#.#.#/##..#/#...#/.###.",
    "1": "..#../.##../..#../..#../..#../..#../.###.",
    "2": ".###./#...#/....#/...#./..#../.#.../#####",
    "3": "#####/...#./..#../...#./....#/#...#/.###.",
    "4": "...#./..##./.#.#./#..#./#####/...#./...#.",
    "5": "#####/#..../####./....#/....#/#...#/.###.",
    "6": "..##./.#.../#..../####./#...#/#...#/.###.",
    "7": "#####/....#/...#./..#../.#.../.#.../.#...",
    "8": ".###./#...#/#...#/.###./#...#/#...#/.###.",
    "9": ".###./#...#/#...#/.####/....#/...#./.##..",
    "=": "...../#####/...../#####/...../...../.....",
    "-": "...../...../...../#####/...../...../.....",
    ".": "...../...../...../...../...../.##../.##..",
    ":": "...../.##../.##../...../.##../.##../.....",
    "/": "....#/...#./...#./..#../.#.../.#.../#....",
    " ": "...../...../...../...../...../...../.....",
}
FONT = {}
for _ch, _rows in _GLYPHS.items():
    FONT[_ch] = [row.replace("#", "1").replace(".", "0") for row in _rows.split("/")]
GLYPH_W, GLYPH_H = 5, 7


def _png(width, height, rows):
    """Encode 8-bit RGB scanlines (list of bytearray) as a PNG."""
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw += bytes(row)

    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def render_text_png(text, width, height, fg, bg, scale=None):
    """Render uppercase text centered on a solid background.

    ffmpeg 8 here ships without drawtext, so the harness draws its own glyphs
    with a hand-rolled 5x7 bitmap font. Falls back to a plain colour block if
    the text cannot fit.
    """
    text = "".join(ch.upper() if ch.upper() in FONT else " " for ch in text)
    if scale is None:
        by_height = (height - 4) // GLYPH_H
        by_width = (width - 4) // max(1, (GLYPH_W + 1) * len(text)) if text else 1
        scale = max(1, min(by_height, by_width)) if text else 1
    fg_rows = []
    for rows in (FONT.get(ch, FONT[" "]) for ch in text):
        fg_rows.append(rows)
    text_w = max(0, len(text) * (GLYPH_W + 1) - 1) * scale
    text_h = GLYPH_H * scale
    x0 = max(0, (width - text_w) // 2)
    y0 = max(0, (height - text_h) // 2)

    canvas = [bytearray(bytes(bg) * width) for _ in range(height)]
    for i, rows in enumerate(fg_rows):
        for gy in range(GLYPH_H):
            line = rows[gy]
            for gx in range(GLYPH_W):
                if line[gx] == "1":
                    px = x0 + (i * (GLYPH_W + 1) + gx) * scale
                    py = y0 + gy * scale
                    for dy in range(scale):
                        if py + dy >= height:
                            break
                        row = canvas[py + dy]
                        for dx in range(scale):
                            if px + dx >= width:
                                break
                            off = (px + dx) * 3
                            row[off:off + 3] = bytes(fg)
    return _png(width, height, canvas)


def pkg_color(pkg):
    """Deterministic, readable colour per package name."""
    digest = hashlib.md5(pkg.encode("utf-8")).digest()
    r = 64 + digest[0] % 160
    g = 64 + digest[1] % 160
    b = 64 + digest[2] % 160
    return (r, g, b)


LINK_SCHEMES = ("http", "https", "geo", "tel", "mailto")
LINK_MAX_BYTES = 8 * 1024

APK_NAME = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
APK_MAX_BYTES = 1 << 30
APK_FAKE_PKG = "dev.pocketdeck.fake.installed"
APK_FAKE_LABEL = "Tiny Demo"


def valid_link(raw):
    """The trimmed URL when link.open may view it (docs/design/links.md), else None."""
    if not isinstance(raw, str):
        return None
    url = raw.strip()
    if not url or len(url.encode("utf-8")) > LINK_MAX_BYTES:
        return None
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in url):
        return None
    scheme, sep, rest = url.partition(":")
    if not sep or not re.fullmatch(r"[A-Za-z][A-Za-z0-9+.-]*", scheme):
        return None
    scheme = scheme.lower()
    if scheme not in LINK_SCHEMES:
        return None
    if scheme in ("http", "https"):
        if not rest.startswith("//"):
            return None
        host = re.split(r"[/?#]", rest[2:], 1)[0].rpartition("@")[2].partition(":")[0]
        if not host:
            return None
    elif not rest:
        return None
    return url


def round16(value):
    value = int(value)
    if value < 16:
        return 16
    return value - (value % 16)


# --- JSON Lines event log --------------------------------------------------
class EventLog(object):
    """Writes the exact JSON Lines format other agents' tests consume."""

    def __init__(self, path):
        self._lock = threading.Lock()
        self._fp = open(path, "w") if path else None

    def _emit(self, obj):
        if self._fp is None:
            return
        line = json.dumps(obj, separators=(",", ":"))
        with self._lock:
            self._fp.write(line + "\n")
            self._fp.flush()

    def session(self, state):
        self._emit({"ev": "session", "state": state, "ts": time.time()})

    def rx(self, msg):
        self._emit({"ev": "rx", "msg": msg, "ts": time.time()})

    def touch(self, stream, action, pointer, nx, ny):
        self._emit({"ev": "input", "kind": "touch", "stream": stream, "action": action,
                    "pointer": pointer, "nx": nx, "ny": ny, "ts": time.time()})

    def scroll(self, stream, nx, ny, h, v):
        self._emit({"ev": "input", "kind": "scroll", "stream": stream, "nx": nx, "ny": ny,
                    "h": h, "v": v, "ts": time.time()})

    def key(self, stream, action, keycode, meta):
        self._emit({"ev": "input", "kind": "key", "stream": stream, "action": action,
                    "keycode": keycode, "meta": meta, "ts": time.time()})

    def video_config(self, stream, w, h):
        self._emit({"ev": "video", "stream": stream, "config": True, "w": w, "h": h,
                    "ts": time.time()})

    def audio_config(self, codec, sample_rate, channels):
        self._emit({"ev": "audio", "config": True, "codec": codec,
                    "sampleRate": sample_rate, "channels": channels,
                    "ts": time.time()})

    def quality(self, stream, bitrate, max_fps):
        self._emit({"ev": "quality", "stream": stream, "bitrate": bitrate,
                    "maxFps": max_fps, "ts": time.time()})

    def clip(self, direction, text):
        self._emit({"ev": "clip", "dir": direction, "text": text, "ts": time.time()})

    def link(self, stream, url):
        self._emit({"ev": "link", "stream": stream, "url": url, "ts": time.time()})

    def share(self, kind, value, **extra):
        event = {"ev": "share", "kind": kind, "value": value, "ts": time.time()}
        event.update(extra)
        self._emit(event)

    def apk(self, install_id, files, ok, code):
        self._emit({"ev": "apk", "id": install_id, "files": files, "ok": ok, "code": code,
                    "ts": time.time()})

    def close(self):
        with self._lock:
            if self._fp is not None:
                self._fp.close()
                self._fp = None


# --- persisted pairing state ----------------------------------------------
def scan_qr_uri(store, uri):
    """Simulate a QR scan: `pocketdeck://pair?c=&n=&k=` -> a paired client.

    Scanning is the consent (docs/UX.md): the phone stores the Mac's client id
    and key, so the Mac's next `auth` succeeds without any pair.request.
    """
    parsed = urllib.parse.urlparse(uri.strip())
    if parsed.scheme.lower() != "pocketdeck" or parsed.netloc.lower() != "pair":
        raise ValueError("not a PocketDeck pairing URI: %r" % uri)
    params = urllib.parse.parse_qs(parsed.query)
    client_id = (params.get("c") or [""])[0].strip()
    key_hex = (params.get("k") or [""])[0].strip()
    name = (params.get("n") or ["Mac"])[0]
    if not client_id or len(key_hex) != 64:
        raise ValueError("pairing URI needs ?c=<clientId>&k=<64 hex>")
    try:
        key = bytes.fromhex(key_hex)
    except ValueError:
        raise ValueError("pairing URI key is not hex: %r" % key_hex)
    store.add_client(client_id, name, key)
    print("QR scan: paired client %r (%s)" % (name, client_id))
    sys.stdout.flush()


class Store(object):
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.device_id = None
        self.clients = {}
        self._load()

    def _load(self):
        try:
            with open(self.path, "r") as fp:
                data = json.load(fp)
        except (IOError, OSError, ValueError):
            data = {}
        self.device_id = data.get("id") or proto.gen_device_id()
        self.clients = data.get("clients", {})

    def save(self):
        with self.lock:
            data = {"id": self.device_id, "clients": self.clients}
            tmp = self.path + ".tmp"
            with open(tmp, "w") as fp:
                json.dump(data, fp, indent=2)
            os.replace(tmp, self.path)

    def key_for(self, client_id):
        entry = self.clients.get(client_id)
        if not entry:
            return None
        try:
            return bytes.fromhex(entry["key"])
        except (KeyError, ValueError):
            return None

    def add_client(self, client_id, name, key):
        with self.lock:
            self.clients[client_id] = {"name": name, "key": key.hex()}
        self.save()


# --- outgoing send queue (priority + per-stream backpressure) --------------
class Sender(object):
    def __init__(self, sock, on_backlog_cleared):
        self._sock = sock
        self._on_backlog_cleared = on_backlog_cleared
        self._json = []
        self._key = []
        self._delta = []
        self._pending = {}          # stream -> queued delta count
        self._need_key = set()
        self._cv = threading.Condition()
        self._closed = False
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _put(self, prio, stream, data):
        with self._cv:
            if self._closed:
                return False
            if prio == 2:
                if self._pending.get(stream, 0) >= MAX_PENDING_DELTA:
                    self._need_key.add(stream)
                    return False
                self._pending[stream] = self._pending.get(stream, 0) + 1
                self._delta.append((stream, data))
            elif prio == 1:
                self._key.append((stream, data))
            else:
                self._json.append((stream, data))
            self._cv.notify()
            return True

    def send_json(self, obj):
        return self._put(0, obj.get("stream", 0) or 0, proto.pack_json(obj, obj.get("stream", 0) or 0))

    def send_in_order(self, data):
        """A pre-framed frame on the key lane: never dropped, FIFO with other key-lane frames
        (a shared file's JSON and SHARE_DATA must not overtake each other)."""
        return self._put(1, 0, data)

    def send_config(self, stream, codec, w, h, sps_pps):
        return self._put(1, stream, proto.pack_video_config(stream, codec, w, h, sps_pps))

    def send_frame(self, stream, pts_us, flags, access_unit):
        return self._put(2, stream, proto.pack_video_frame(stream, pts_us, flags, access_unit))

    def send_audio_config(self, codec, sample_rate, channels, frame_ms, setup=b""):
        return self._put(1, 0, proto.pack_audio_config(codec, sample_rate, channels, frame_ms, setup))

    def send_audio_frame(self, pts_us, packet):
        return self._put(2, 0, proto.pack_audio_frame(pts_us, packet))

    def forget_stream(self, stream):
        with self._cv:
            self._pending.pop(stream, None)
            self._need_key.discard(stream)
            self._delta = [item for item in self._delta if item[0] != stream]
            self._key = [item for item in self._key if item[0] != stream]

    def _run(self):
        while True:
            with self._cv:
                while not (self._json or self._key or self._delta) and not self._closed:
                    self._cv.wait()
                if self._closed:
                    return
                if self._json:
                    _stream, data = self._json.pop(0)
                elif self._key:
                    _stream, data = self._key.pop(0)
                else:
                    stream, data = self._delta.pop(0)
                    remaining = self._pending.get(stream, 1) - 1
                    self._pending[stream] = remaining
                    if remaining <= LOW_PENDING_DELTA and stream in self._need_key:
                        self._need_key.discard(stream)
                        self._cv.release()
                        try:
                            self._on_backlog_cleared(stream)
                        finally:
                            self._cv.acquire()
            try:
                self._sock.sendall(data)
            except OSError:
                with self._cv:
                    self._closed = True
                    self._cv.notify_all()
                return

    def close(self):
        with self._cv:
            self._closed = True
            self._cv.notify_all()


# --- one encoder-backed window stream -------------------------------------
class WindowStream(object):
    def __init__(self, phone, stream_id, w, h, dpi, mode, pkg=None, activity=None):
        self.phone = phone
        self.stream_id = stream_id
        self.w = round16(w)
        self.h = round16(h)
        self.dpi = dpi
        self.mode = mode
        self.pkg = pkg
        self.activity = activity
        self.display_id = phone.next_display_id()
        self.label = "PocketDeck Launcher" if mode == "phone" else (self._label_for(pkg) or pkg)
        self._enc = None
        self._reader = None
        self._configured = False
        self._au_index = 0
        self._paused = False
        self._lock = threading.Lock()

    @staticmethod
    def _label_for(pkg):
        for app in APPS:
            if app["pkg"] == pkg:
                return app["label"]
        return None

    def _source(self):
        if self.mode == "phone":
            return "smptehdbars=size=%dx%d:rate=%d" % (self.w, self.h, FRAME_RATE)
        return "testsrc2=size=%dx%d:rate=%d" % (self.w, self.h, FRAME_RATE)

    def _cmd(self):
        # -re paces the lavfi source to real time; without it ffmpeg encodes as
        # fast as the CPU allows (thousands of fps for cheap patterns).
        cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-re",
               "-f", "lavfi", "-i", self._source()]
        if self.phone.label_dir and self.h >= 48:
            text = "stream=%d %dx%d" % (self.stream_id, self.w, self.h)
            path = os.path.join(self.phone.label_dir,
                                "stream-%d-%dx%d.png" % (self.stream_id, self.w, self.h))
            if not os.path.exists(path):
                with open(path, "wb") as fp:
                    fp.write(render_text_png(text, 8 + len(text) * 12, 18,
                                             (255, 255, 255), (16, 16, 16), scale=2))
            cmd += ["-i", path, "-filter_complex", "[0:v][1:v]overlay=8:8[v]", "-map", "[v]"]
        cmd += ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                "-bf", "0", "-g", str(FRAME_RATE * 10), "-profile:v", "high",
                "-pix_fmt", "yuv420p", "-x264-params", "aud=1", "-an", "-f", "h264", "-"]
        return cmd

    def start(self):
        """(Re)start the encoder: used by open, resize, resume and keyframe."""
        with self._lock:
            self._stop_locked()
            self._configured = False
            self._au_index = 0
            self._paused = False
            self._enc = subprocess.Popen(self._cmd(), stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                                         bufsize=0)
            proc = self._enc
        self._reader = threading.Thread(target=self._read_loop, args=(proc,), daemon=True)
        self._reader.start()

    def pause(self):
        with self._lock:
            if not self._paused:
                self._stop_locked()
                self._paused = True

    def stop(self):
        with self._lock:
            self._stop_locked()
            self._paused = True

    def _stop_locked(self):
        proc = self._enc
        self._enc = None
        if proc is not None:
            try:
                proc.kill()
            except OSError:
                pass
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
        reader = self._reader
        self._reader = None
        if reader is not None and reader.is_alive() and reader is not threading.current_thread():
            reader.join(timeout=5)

    def _read_loop(self, proc):
        splitter = proto.AccessUnitSplitter()
        while True:
            if self._enc is not proc:
                return
            try:
                chunk = proc.stdout.read(65536)
            except (OSError, ValueError):
                return
            if not chunk:
                for au in splitter.flush():
                    if self._enc is proc:
                        self._emit(au)
                return
            for au in splitter.feed(chunk):
                if self._enc is not proc:
                    return
                self._emit(au)

    def _emit(self, access_unit):
        nals = proto.split_nals(access_unit)
        if not nals:
            return
        if not self._configured:
            sps_pps = proto.extract_sps_pps(nals)
            if sps_pps is None:
                return
            self._configured = True
            self.phone.sender.send_config(self.stream_id, proto.CODEC_H264, self.w, self.h, sps_pps)
            self.phone.events.video_config(self.stream_id, self.w, self.h)
        flags = proto.FRAME_FLAG_KEY if proto.is_idr(nals) else 0
        pts = self._au_index * (1000000 // FRAME_RATE)
        self._au_index += 1
        self.phone.sender.send_frame(self.stream_id, pts, flags, access_unit)


# --- device-wide audio tone (440 Hz sine → AAC, 48 kHz stereo) ---------------
class AudioTone(object):
    """One 440 Hz sine encoded to AAC-ADTS by ffmpeg, split into raw frames.

    Started on `audio.start`, stopped on `audio.stop` or session teardown.
    The ASC for AAC-LC 48 kHz stereo is 0x1190. pts advances 20 ms per frame.
    """

    SAMPLE_RATE = 48000
    CHANNELS = 2
    FRAME_MS = 20
    CODEC = 3  # AAC-LC
    ASC = b"\x11\x90"

    def __init__(self, phone):
        self.phone = phone
        self._thread = None
        self._stop = threading.Event()
        self._proc = None

    @property
    def running(self):
        return self._thread is not None and self._thread.is_alive()

    def start(self):
        if self.running:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        proc = self._proc
        if proc is not None:
            try:
                proc.kill()
            except OSError:
                pass
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=3.0)
        self._thread = None

    def _run(self):
        cmd = [FFMPEG, "-hide_banner", "-loglevel", "error",
               "-f", "lavfi", "-i",
               "sine=frequency=440:sample_rate=%d" % self.SAMPLE_RATE,
               "-c:a", "aac", "-b:a", "64k", "-ac", str(self.CHANNELS),
               "-ar", str(self.SAMPLE_RATE), "-f", "adts", "-"]
        try:
            self._proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                          stderr=subprocess.DEVNULL,
                                          stdin=subprocess.DEVNULL, bufsize=0)
        except OSError as exc:
            sys.stderr.write("fakephone: audio ffmpeg failed: %s\n" % exc)
            return
        sender = self.phone.sender
        if sender is None:
            return
        sender.send_audio_config(self.CODEC, self.SAMPLE_RATE, self.CHANNELS,
                                 self.FRAME_MS, self.ASC)
        self.phone.events.audio_config(self.CODEC, self.SAMPLE_RATE, self.CHANNELS)
        buf = bytearray()
        pts = 0
        proc = self._proc
        while not self._stop.is_set():
            if self.phone.sender is not sender:
                break
            try:
                chunk = proc.stdout.read(4096)
            except (OSError, ValueError):
                break
            if not chunk:
                break
            buf += chunk
            for frame in self._split_adts(buf):
                if self._stop.is_set() or self.phone.sender is not sender:
                    break
                sender.send_audio_frame(pts, frame)
                pts += self.FRAME_MS * 1000
                self._stop.wait(self.FRAME_MS / 1000.0)
            del buf[:self._consumed]
        try:
            proc.kill()
        except OSError:
            pass

    _consumed = 0

    def _split_adts(self, buf):
        """Yield raw AAC frames from ADTS bytes; sets self._consumed."""
        out = []
        pos = 0
        n = len(buf)
        while pos + 7 <= n:
            if buf[pos] != 0xFF or (buf[pos + 1] & 0xF0) != 0xF0:
                pos += 1
                continue
            length = ((buf[pos + 3] & 0x03) << 11) | (buf[pos + 4] << 3) | ((buf[pos + 5] & 0xE0) >> 5)
            if length < 7 or pos + length > n:
                break
            out.append(bytes(buf[pos + 7:pos + length]))
            pos += length
        self._consumed = pos
        return out


# --- session ---------------------------------------------------------------
class Session(object):
    def __init__(self, phone, conn, addr, on_end):
        self.phone = phone
        self.sock = conn
        self.addr = addr
        self._on_end = on_end
        self.sender = None
        self.client_id = None
        self.client_name = ""
        self.nonce = None
        self.windows = {}
        self._unknown_types = set()
        self.audio = AudioTone(phone)
        self._thread = threading.Thread(target=self._run, daemon=True)
    def start(self):
        self._thread.start()

    def close(self):
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass

    def _run(self):
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.phone.events.session("open")
        self.sender = Sender(self.sock, self.phone.on_backlog_cleared)
        self.phone.sender = self.sender
        try:
            if self._handshake():
                self._main_loop()
        except proto.ProtocolError as exc:
            sys.stderr.write("fakephone: session error: %s\n" % exc)
        except OSError:
            pass
        finally:
            self._teardown()

    def _teardown(self):
        try:
            self.audio.stop()
        except Exception:
            pass
        for stream_id in list(self.windows):
            self.windows[stream_id].stop()
        self.windows.clear()
        if self.sender:
            self.sender.close()
        if self.phone.sender is self.sender:
            self.phone.sender = None
        self.close()
        self.phone.events.session("closed")
        self._on_end()

    # -- handshake --
    def _send(self, obj):
        self.sender.send_json(obj)

    def _handshake(self):
        frame = proto.recv_frame(self.sock)
        if frame is None:
            return False
        if frame.type != proto.TYPE_JSON:
            self._send_error("protocol", "expected hello")
            return False
        msg = proto.unpack_json(frame)
        self.phone.events.rx(msg)
        if msg.get("t") != "hello":
            self._send_error("protocol", "expected hello")
            return False
        if msg.get("v") != 1:
            self._send_error("version")
            return False
        self.client_id = msg.get("clientId")
        self.client_name = msg.get("name", "")
        self.nonce = proto.gen_nonce_hex()
        self._send({"t": "challenge", "nonce": self.nonce, "id": self.phone.store.device_id})

        frame = proto.recv_frame(self.sock)
        if frame is None:
            return False
        if frame.type != proto.TYPE_JSON:
            self._send_error("protocol", "expected auth or pair.request")
            return False
        msg = proto.unpack_json(frame)
        self.phone.events.rx(msg)
        kind = msg.get("t")
        if kind == "auth":
            return self._auth(msg)
        if kind == "pair.request":
            return self._pair()
        self._send_error("protocol", "expected auth or pair.request")
        return False

    def _auth(self, msg):
        key = self.phone.store.key_for(self.client_id)
        got = msg.get("mac", "")
        if key is None or not hmac.compare_digest(proto.hmac_hex(key, self.nonce), got):
            self._send_error("auth_failed")
            return False
        self.phone.events.session("auth_ok")
        self._welcome()
        return True

    def _pair(self):
        """Numeric comparison: the code goes to the Mac in pair.code_shown, and
        the person's Allow (here: --auto-allow after --allow-delay, or the
        terminal prompt) is the only step. Nothing comes back from the Mac."""
        code = "%06d" % random.randrange(0, 1000000)
        self.phone.report_code(code)
        self._send({"t": "pair.code_shown", "code": code})
        allowed = self._decision()
        if allowed is None:
            return False
        if not allowed:
            self._send_error("pair_denied")
            return False
        key = proto.gen_key()
        self.phone.store.add_client(self.client_id, self.client_name, key)
        self._send({"t": "pair.ok", "key": key.hex()})
        self.phone.events.session("paired")
        self._welcome()
        return True

    def _decision(self):
        """True = Allow, False = Deny, None = the Mac hung up first (Cancel)."""
        if not self.phone.args.auto_allow:
            return self.phone.ask_allow(self.client_name)
        deadline = time.time() + self.phone.args.allow_delay
        while True:
            left = deadline - time.time()
            if left <= 0:
                return True
            ready, _, _ = select.select([self.sock], [], [], left)
            if ready:
                # The Mac says nothing while a person decides: readable means it hung up.
                return None

    def _welcome(self):
        self._send({"t": "welcome", "device": {
            "id": self.phone.store.device_id,
            "name": self.phone.name,
            "model": DEVICE_MODEL,
            "sdk": 36,
            "screen": {"w": SCREEN_W, "h": SCREEN_H, "dpi": SCREEN_DPI},
            "locked": True,
        }})
        self._send({"t": "state", "locked": True, "battery": BATTERY, "charging": False})
        if self.phone.args.clip_on_welcome is not None:
            text = self.phone.args.clip_on_welcome
            self._send({"t": "clip.set", "text": text})
            self.phone.events.clip("tx", text)
        if self.phone.args.share:
            threading.Thread(target=self._send_shares, daemon=True).start()

    def _send_shares(self):
        """--share: what a person shares with "Send to Mac" (docs/design/sharein.md)."""
        time.sleep(self.phone.args.share_delay)
        for share_id, spec in enumerate(self.phone.args.share, start=1):
            kind, _, value = spec.partition(":")
            sender = self.sender
            if sender is None:
                return
            if kind == "text":
                sender.send_json({"t": "share.text", "text": value})
                self.phone.events.share("text", value)
            elif kind == "image":
                with open(value, "rb") as handle:
                    data = handle.read()
                name = os.path.basename(value)
                mime = "image/png" if name.lower().endswith(".png") else "image/jpeg"
                sender.send_in_order(proto.pack_json({"t": "share.file", "id": share_id, "name": name, "mime": mime}))
                for offset in range(0, len(data), 256 * 1024):
                    sender.send_in_order(proto.pack_frame(proto.TYPE_SHARE_DATA, share_id, data[offset:offset + 256 * 1024]))
                digest = hashlib.sha256(data).hexdigest()
                sender.send_in_order(proto.pack_json({"t": "share.end", "id": share_id, "size": len(data), "sha256": digest}))
                self.phone.events.share("image", value, size=len(data), sha256=digest)
            time.sleep(0.5)

    # -- steady state --
    def _main_loop(self):
        while True:
            frame = proto.recv_frame(self.sock)
            if frame is None:
                return
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                self.phone.events.rx(msg)
                self._handle_json(msg)
            elif frame.type == proto.TYPE_TOUCH:
                action, pointer, nx, ny = proto.unpack_touch(frame)
                self.phone.events.touch(frame.stream, action, pointer, nx, ny)
            elif frame.type == proto.TYPE_SCROLL:
                nx, ny, h, v = proto.unpack_scroll(frame)
                self.phone.events.scroll(frame.stream, nx, ny, h, v)
            elif frame.type == proto.TYPE_KEY:
                action, keycode, meta = proto.unpack_key(frame)
                self.phone.events.key(frame.stream, action, keycode, meta)
            elif frame.type == proto.TYPE_APK_DATA:
                self._on_apk_data(frame.stream, frame.payload)
            elif frame.type not in self._unknown_types:
                self._unknown_types.add(frame.type)
                sys.stderr.write("fakephone: ignoring unknown frame type 0x%02x\n" % frame.type)

    def _handle_json(self, msg):
        kind = msg.get("t")
        handler = {
            "ping": self._on_ping,
            "apps.list": self._on_apps_list,
            "apps.icon": self._on_apps_icon,
            "window.open": self._on_window_open,
            "link.open": self._on_link_open,
            "window.resize": self._on_window_resize,
            "window.close": self._on_window_close,
            "window.pause": self._on_window_pause,
            "window.resume": self._on_window_resume,
            "window.keyframe": self._on_window_keyframe,
            "window.quality": self._on_window_quality,
            "window.launch": self._on_window_launch,
            "nav": self._on_nav,
            "text": self._on_noop,
            "clip.set": self._on_clip_set,
            "apk.install": self._on_apk_install,
            "apk.cancel": self._on_apk_cancel,
            "audio.start": self._on_audio_start,
            "audio.stop": self._on_audio_stop,
        }.get(kind)
        if handler is None:
            if kind not in self._unknown_types:
                self._unknown_types.add(kind)
                sys.stderr.write("fakephone: ignoring unknown message %r\n" % kind)
            return
        handler(msg)

    def _on_ping(self, msg):
        self._send({"t": "pong", "ts": msg.get("ts")})

    # -- APK install (docs/design/apk.md): acts like pm; a part holding the bytes
    # PD_FAKE_DOWNGRADE fails the commit with INSTALL_FAILED_VERSION_DOWNGRADE.
    def _on_apk_install(self, msg):
        files = msg.get("files") or []
        install_id = msg.get("id")
        if getattr(self, "_apk", None) is not None:
            self._send({"t": "apk.result", "id": install_id, "ok": False, "code": "busy",
                        "message": "another install is running"})
            return
        ok_names = all(isinstance(f, dict) and APK_NAME.match(str(f.get("name", "")))
                       and str(f.get("name")).endswith(".apk") for f in files)
        total = sum(int(f.get("size") or 0) for f in files) if ok_names else 0
        if not files or not ok_names or total <= 0 or total > APK_MAX_BYTES:
            self._send({"t": "apk.result", "id": install_id, "ok": False,
                        "code": "too_large" if total > APK_MAX_BYTES else "bad_request", "message": ""})
            return
        self._apk = {"id": install_id, "files": files, "total": total, "data": bytearray(),
                     "last": 0.0}

    def _on_apk_cancel(self, msg):
        apk = getattr(self, "_apk", None)
        if apk and apk["id"] == msg.get("id"):
            self._apk = None
            self.phone.events.apk(apk["id"], [], False, "cancelled")
            self._send({"t": "apk.result", "id": apk["id"], "ok": False, "code": "cancelled",
                        "message": "cancelled"})

    def _on_apk_data(self, install_id, payload):
        apk = getattr(self, "_apk", None)
        if not apk or apk["id"] != install_id:
            return
        apk["data"] += payload
        got = len(apk["data"])
        now = time.time()
        if got < apk["total"] and now - apk["last"] >= 0.25:
            apk["last"] = now
            self._send({"t": "apk.progress", "id": install_id, "bytes": got})
        if got < apk["total"]:
            return
        self._apk = None
        self._send({"t": "apk.progress", "id": install_id, "bytes": got})
        data, offset, report, code = bytes(apk["data"]), 0, [], None
        for f in apk["files"]:
            part = data[offset:offset + int(f["size"])]
            offset += int(f["size"])
            digest = hashlib.sha256(part).hexdigest()
            report.append({"name": f["name"], "size": len(part), "sha256": digest,
                           "match": digest == str(f.get("sha256", "")).lower()})
            if digest != str(f.get("sha256", "")).lower():
                code = code or "checksum"
            if b"PD_FAKE_DOWNGRADE" in part:
                code = code or "INSTALL_FAILED_VERSION_DOWNGRADE"
        if len(data) > apk["total"]:
            code = "failed"
        sys.stderr.write("fakephone: apk %r %d bytes -> %s\n" % (install_id, len(data), code or "Success"))
        self.phone.events.apk(install_id, report, code is None, code)
        if code:
            self._send({"t": "apk.result", "id": install_id, "ok": False, "code": code,
                        "message": "Downgrade detected" if code.startswith("INSTALL_") else code})
            return
        if not any(a["pkg"] == APK_FAKE_PKG for a in APPS):
            APPS.append({"pkg": APK_FAKE_PKG, "label": APK_FAKE_LABEL, "activity": APK_FAKE_PKG + "/.Main"})
            APPS.sort(key=lambda a: a["label"].lower())
        self._send({"t": "apk.result", "id": install_id, "ok": True, "pkg": APK_FAKE_PKG,
                    "label": APK_FAKE_LABEL, "version": "1.0"})

    def _on_clip_set(self, msg):
        self.phone.events.clip("rx", msg.get("text"))

    def _on_apps_list(self, _msg):
        apps = sorted(APPS, key=lambda a: a["label"].lower())
        self._send({"t": "apps", "apps": apps})

    def _on_apps_icon(self, msg):
        pkg = msg.get("pkg", "")
        png = self.phone.icon_png(pkg)
        self._send({"t": "icon", "pkg": pkg, "png": base64.b64encode(png).decode("ascii")})

    def _stream_or_error(self, msg):
        stream_id = msg.get("stream")
        window = self.windows.get(stream_id)
        if window is None:
            self._send_error("no_stream", "unknown stream %r" % (stream_id,), stream_id)
        return window

    def _send_error(self, code, message=None, stream=None):
        obj = {"t": "error", "code": code}
        if message:
            obj["message"] = message
        if stream is not None:
            obj["stream"] = stream
        self._send(obj)

    def _on_link_open(self, msg):
        url = valid_link(msg.get("url"))
        if url is None:
            self._send_error("bad_url", "link.open needs an http, https, geo, tel or mailto URL",
                             msg.get("stream"))
            return
        sys.stderr.write("fakephone: link.open stream %r %s\n" % (msg.get("stream"), url))
        self.phone.events.link(msg.get("stream"), url)
        self._on_window_open(dict(msg, pkg="link"))

    def _on_window_open(self, msg):
        stream_id = msg.get("stream")
        if stream_id is None:
            self._send_error("bad_request", "%s needs stream" % msg.get("t"))
            return
        if stream_id in self.windows:
            self._send_error("bad_request", "stream %r already open" % (stream_id,), stream_id)
            return
        w = msg.get("w", SCREEN_W)
        h = msg.get("h", SCREEN_H)
        dpi = msg.get("dpi", SCREEN_DPI)
        mode = "phone" if msg.get("mode") == "phone" else "app"
        window = WindowStream(self.phone, stream_id, w, h, dpi, mode,
                              pkg=msg.get("pkg"), activity=msg.get("activity"))
        self.windows[stream_id] = window
        self._send({"t": "window.opened", "stream": stream_id,
                    "displayId": window.display_id, "w": window.w, "h": window.h})
        window.start()

    def _on_window_resize(self, msg):
        window = self._stream_or_error(msg)
        if window is None:
            return
        window.w = round16(msg.get("w", window.w))
        window.h = round16(msg.get("h", window.h))
        window.dpi = msg.get("dpi", window.dpi)
        window.start()

    def _on_window_close(self, msg):
        window = self._stream_or_error(msg)
        if window is None:
            return
        window.stop()
        del self.windows[msg["stream"]]
        self.sender.forget_stream(msg["stream"])
        self._send({"t": "window.closed", "stream": msg["stream"], "reason": "requested"})
        if not self.windows:
            self.audio.stop()

    def _on_window_pause(self, msg):
        window = self._stream_or_error(msg)
        if window is not None:
            window.pause()

    def _on_window_resume(self, msg):
        window = self._stream_or_error(msg)
        if window is not None:
            window.start()

    def _on_window_keyframe(self, msg):
        window = self._stream_or_error(msg)
        if window is not None:
            window.start()

    def _on_window_quality(self, msg):
        # Accepted for protocol completeness; the fake's ffmpeg pipeline keeps
        # its bitrate. The event log records it so tests can assert delivery.
        window = self._stream_or_error(msg)
        if window is None:
            return
        self.phone.events.quality(msg.get("stream", 0),
                                  msg.get("bitrate"), msg.get("maxFps"))
        sys.stderr.write("fakephone: window.quality stream=%s bitrate=%s maxFps=%s (accepted)\n"
                         % (msg.get("stream"), msg.get("bitrate"), msg.get("maxFps")))

    def _on_window_launch(self, msg):
        window = self._stream_or_error(msg)
        if window is None:
            return
        window.pkg = msg.get("pkg", window.pkg)
        window.activity = msg.get("activity", window.activity)
        window.label = window._label_for(window.pkg) or window.pkg
        self._send({"t": "window.title", "stream": msg["stream"],
                    "label": window.label, "pkg": window.pkg})

    def _on_nav(self, msg):
        window = self._stream_or_error(msg)
        if window is None:
            return
        action = msg.get("action")
        keycode = {"back": proto.KEYCODE_BACK, "home": proto.KEYCODE_HOME,
                   "recents": proto.KEYCODE_APP_SWITCH}.get(action)
        if keycode is None:
            self._send_error("bad_request", "unknown nav action %r" % (action,), msg.get("stream"))
            return
        self.phone.events.key(msg.get("stream", 0), proto.KEY_DOWN, keycode, 0)
        self.phone.events.key(msg.get("stream", 0), proto.KEY_UP, keycode, 0)

    def _on_noop(self, _msg):
        return

    def _on_audio_start(self, msg):
        codecs = msg.get("codecs") or []
        if self.CODEC_CHOICE(codecs) is None:
            return
        if not self.windows:
            return
        self.audio.start()
        self._send({"t": "audio.state", "on": True, "codec": AudioTone.CODEC})

    def _on_audio_stop(self, _msg):
        self.audio.stop()
        self._send({"t": "audio.state", "on": False, "codec": 0})

    @staticmethod
    def CODEC_CHOICE(codecs):
        try:
            offered = [int(c) for c in codecs]
        except (TypeError, ValueError):
            return None
        if AudioTone.CODEC in offered:
            return AudioTone.CODEC
        return None


# --- mDNS registration -----------------------------------------------------
class MDNS(object):
    def __init__(self, name, port, device_id):
        self.name = name
        self.port = port
        self.device_id = device_id
        self.proc = None

    def start(self):
        cmd = [DNS_SD, "-R", self.name, SERVICE_TYPE, "local", str(self.port),
               "v=1", "id=" + self.device_id, "name=" + self.name, "model=" + DEVICE_MODEL]
        self.proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def stop(self):
        proc = self.proc
        self.proc = None
        if proc is None:
            return
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass


# --- the phone -------------------------------------------------------------
class FakePhone(object):
    def __init__(self, args):
        self.args = args
        self.name = args.name
        self.store = Store(args.state)
        if args.qr_uri:
            scan_qr_uri(self.store, args.qr_uri)
        self.events = EventLog(args.events)
        self.sender = None            # active session's sender
        self._session = None
        self._busy = threading.Event()
        self._stop = threading.Event()
        self._srv = None
        self._icon_cache = {}
        self._icon_lock = threading.Lock()
        self._display_seq = 100
        self._display_lock = threading.Lock()
        self._mdns = None
        self.label_dir = tempfile.mkdtemp(prefix="fakephone-") if args.labels else None

    def next_display_id(self):
        with self._display_lock:
            self._display_seq += 1
            return self._display_seq

    def icon_png(self, pkg):
        if pkg in NO_ICON_PKGS:
            return b""
        with self._icon_lock:
            cached = self._icon_cache.get(pkg)
            if cached is not None:
                return cached
        letter = ""
        for app in APPS:
            if app["pkg"] == pkg:
                letter = app["label"][:1]
                break
        if not letter:
            letter = (pkg.rsplit(".", 1)[-1] or "?")[:1]
        fg = (255, 255, 255)
        png = render_text_png(letter or "?", 96, 96, fg, pkg_color(pkg))
        with self._icon_lock:
            self._icon_cache[pkg] = png
        return png

    def report_code(self, code):
        try:
            print("Pairing code: %s" % code)
            sys.stdout.flush()
        except (IOError, OSError):
            pass

    def ask_allow(self, name):
        try:
            ans = input("Allow %r to pair? [y/N]: " % name)
        except EOFError:
            return False
        return ans.strip().lower() in ("y", "yes")

    # called from the sender thread when a stalled stream caught up
    def on_backlog_cleared(self, stream_id):
        session = self._session
        if session is None:
            return
        window = session.windows.get(stream_id)
        if window is not None:
            threading.Thread(target=window.start, daemon=True).start()

    def _reject_busy(self, conn):
        try:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            conn.sendall(proto.pack_json({"t": "error", "code": "busy",
                                          "message": "another session is active"}))
            try:
                conn.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            conn.settimeout(2.0)
            try:
                while conn.recv(4096):
                    pass
            except OSError:
                pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", self.args.port))
        port = srv.getsockname()[1]
        srv.listen(8)
        srv.settimeout(0.5)
        self._srv = srv
        print("fakephone %s listening on 0.0.0.0:%d" % (self.store.device_id, port),
              file=sys.stderr)
        if not self.args.no_mdns:
            self._mdns = MDNS(self.name, port, self.store.device_id)
            try:
                self._mdns.start()
                print("fakephone advertising %s as %r" % (SERVICE_TYPE, self.name),
                      file=sys.stderr)
            except OSError as exc:
                sys.stderr.write("fakephone: mDNS unavailable (%s)\n" % exc)
                self._mdns = None

        while not self._stop.is_set():
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if self._busy.is_set():
                threading.Thread(target=self._reject_busy, args=(conn,), daemon=True).start()
                continue
            self._busy.set()
            session = Session(self, conn, addr, self._busy.clear)
            self._session = session
            session.start()
        self.shutdown()

    def shutdown(self):
        self._stop.set()
        if self._srv is not None:
            try:
                self._srv.close()
            except OSError:
                pass
            self._srv = None
        if self._mdns is not None:
            self._mdns.stop()
            self._mdns = None
        session = self._session
        if session is not None:
            session.close()
            session._thread.join(timeout=5)
        self.events.close()
        if self.label_dir:
            shutil.rmtree(self.label_dir, ignore_errors=True)


def build_parser():
    p = argparse.ArgumentParser(description="Fake PocketDeck phone (protocol-faithful).")
    p.add_argument("--port", type=int, default=0, help="TCP port (0 = ephemeral)")
    p.add_argument("--name", default="FakePhone", help="device name advertised over mDNS")
    p.add_argument("--no-mdns", action="store_true", help="do not advertise over mDNS")
    p.add_argument("--auto-allow", action="store_true",
                   help="accept pairing requests without the terminal y/n prompt")
    p.add_argument("--allow-delay", type=float, default=0.0, metavar="SECONDS",
                   help="with --auto-allow, wait this long before tapping Allow (a person comparing codes)")
    p.add_argument("--state", default=DEFAULT_STATE, metavar="PATH",
                   help="paired-client state file (default: %(default)s)")
    p.add_argument("--events", metavar="PATH", help="write JSON Lines session events here")
    p.add_argument("--no-labels", dest="labels", action="store_false",
                   help="do not overlay the stream id/size label")
    p.add_argument("--demo-apps", type=int, default=0, metavar="N",
                   help="pad the app list to N apps (grid screenshots)")
    p.add_argument("--no-icon-every", type=int, default=0, metavar="K",
                   help="with --demo-apps, every K-th app has no icon")
    p.add_argument("--qr-uri", metavar="URI",
                   help="simulate a QR scan: register the client+key from a "
                        "pocketdeck://pair URI as paired, then authenticate normally")
    p.add_argument("--clip-on-welcome", metavar="TEXT", default=None,
                   help="send TEXT as clip.set right after welcome (the phone's clipboard)")
    p.add_argument("--share", metavar="KIND:VALUE", action="append", default=[],
                   help="after welcome, share with the Mac like Share -> Send to Mac: "
                        "text:<text or URL> or image:<path to .png/.jpg>; repeatable, sent in order")
    p.add_argument("--share-delay", type=float, default=2.0, metavar="SECONDS",
                   help="wait this long after welcome before the first --share")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    add_demo_apps(args.demo_apps, args.no_icon_every)
    phone = FakePhone(args)

    def _sig(_signum, _frame):
        phone._stop.set()
        if phone._srv is not None:
            try:
                phone._srv.close()
            except OSError:
                pass

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)
    try:
        phone.run()
    except OSError as exc:
        if exc.errno not in (errno.EBADF, errno.EINVAL):
            raise
        phone.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
