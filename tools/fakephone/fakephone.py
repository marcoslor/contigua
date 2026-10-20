#!/usr/bin/env python3
"""fakephone - a protocol-faithful fake PocketDeck phone (protocol v2).

Runs the docs/PROTOCOL.md v2 flow over TLS 1.3: its own self-signed P-256
identity, no resumption, framing byte-identical to v1. The pairing material —
the §4 code and the R2 pair.qr HMAC — derives from the REAL TLS exporter via
pyOpenSSL's export_keying_material (the same RFC 8446 §7.5 formula both stacks
run), so the code on the fakephone's screen equals the Mac's. It advertises
over mDNS via the macOS `dns-sd` CLI and produces real H.264 out of ffmpeg
(one process per window stream). It is the reference server the macOS app and
the Android server are tested against, so the wire format here is the contract.

Precondition: TLS 1.3 needs OpenSSL 3 (the system `python3` links LibreSSL
2.8/3.3, which has no TLS 1.3), and the phone-style permissive client-cert
trust needs pyOpenSSL. Start fakephone with a TLS-capable interpreter —
check-e2e.sh reads `PD_FAKE_TLS_PYTHON`; a wrong interpreter exits 3 with the
hint.

Usage:
    python3.11 fakephone.py --port 0 --auto-allow --events /tmp/ev.jsonl
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
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proto  # noqa: E402  (codec + the shared v2 TLS identity helpers)

tls_guard = proto.tls_guard
make_identity = proto.make_identity
identity_paths = proto.identity_paths
tls_server_session = proto.tls_server_session

FFMPEG = os.environ.get("FFMPEG") or shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
DNS_SD = "/usr/bin/dns-sd"

SERVICE_TYPE = "_pocketdeck._tcp"
DEVICE_MODEL = "FakePhone"
SCREEN_W, SCREEN_H, SCREEN_DPI = 1080, 2340, 450
BATTERY = 87
FRAME_RATE = 60

# Backpressure: at most ~250 ms of delta frames pending per stream (60 fps).
MAX_BULK_BYTES = 1024 * 1024  # the phone's SendQueue bulk bound
MAX_PENDING_DELTA = 15
LOW_PENDING_DELTA = 4

FAKE_DEBUG = os.environ.get("FAKE_DEBUG")

# The counters the NFR checks read (docs/NFR.md): a write is a request that
# changes what the phone stores or shows (a file write/move/delete, the
# clipboard, a drop, an APK, a link, a media command, a notification action);
# input is every event a person's pointer, keys or a control's action sends
# (touch/scroll/key/hover frames, nav, text). Read-only flows (lists, icons,
# window open/close, files list/stat/read, pause/resume, media state) are in
# neither set.
WRITE_TYPES = frozenset([
    "clip.set", "link.open", "apk.install", "apk.cancel",
    "drop.start", "drop.cancel", "clip.image.start", "clip.image.end",
    "clip.image.abort", "fs.write", "fs.move", "fs.delete", "fs.mkdir",
    "fs.setAttrs", "media.command", "media.choose", "notify.action",
    "notify.dismiss", "notify.enable", "notify.open", "phone.dnd",
    "phone.ringer", "phone.ring", "phone.ring.stop", "window.launch",
    "task.continue",
])

# A control's action (Back/Home/Recents, typing) is input, not a write: the
# frozen-mode checks read it to prove a control reached the phone only when it
# was allowed to.
INPUT_TYPES = frozenset(["nav", "text"])

def dbg(message):
    if FAKE_DEBUG:
        sys.stderr.write("fakephone: %s\n" % message)
        sys.stderr.flush()

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


# The notifications the phone posts once the Mac opts in, and the media session
# that shows in the Mac's Now Playing (docs/design/notify.md). The titles/texts
# are markers the e2e check greps every log for to prove they never leave the
# wire; the event log carries ids, package names and lengths only.
NOTIFY_POSTS = [
    {"id": "pd-n1", "pkg": "com.android.settings",
     "title": "pd-notify-title-1", "text": "pd-notify-text-1"},
    {"id": "pd-n2", "pkg": "com.whatsapp",
     "title": "pd-notify-title-2", "text": "pd-notify-text-2"},
]
NOTIFY_REMOVE = "pd-n2"
# Part 2 shapes (docs/design/notify.md): a reply-capable chat, two buttons, an
# ongoing service notification, a sign-in code and a package for the mute test.
# The code in pd-a4 is a fake fixture; no log ever carries text.
NOTIFY_SHAPES = [
    {"id": "pd-a1", "pkg": "com.whatsapp", "title": "pd-notify-title-3", "text": "pd-notify-text-3",
     "actions": [{"i": 0, "title": "Mark as read"}, {"i": 1, "title": "Reply", "reply": True}]},
    {"id": "pd-a2", "pkg": "com.android.settings", "title": "pd-notify-title-4", "text": "pd-notify-text-4",
     "actions": [{"i": 0, "title": "Mark as read"}, {"i": 1, "title": "Archive"}]},
    {"id": "pd-a3", "pkg": "com.android.settings", "title": "pd-notify-title-5", "text": "pd-notify-text-5",
     "ongoing": True},
    {"id": "pd-a4", "pkg": "com.whatsapp", "title": "pd-notify-title-6",
     "text": "pd-notify-text-6 code 482913"},
    {"id": "pd-a5", "pkg": "com.slack", "title": "pd-notify-title-7", "text": "pd-notify-text-7"},
]
# The fake reply the e2e sends; only its length is ever recorded.
NOTIFY_REPLY_INDEX = 1
NOTIFY_REPLY_TEXT = "pd-reply-1"

# Part 2b (docs/design/notify.md): pictures and Android 16 Live Updates. The
# picture is a generated 160x120 test card (nobody's content); only its mime,
# size and dimensions ever reach a log. `image: "bad"` sends an oversized one
# the Mac must refuse while still showing the banner.
NOTIFY_IMAGE = {
    "mime": "image/jpeg",
    "w": 160,
    "h": 120,
    "data": base64.b64decode(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQY"
        "GBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYa"
        "KCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAAR"
        "CAB4AKADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAA"
        "AgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK"
        "FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWG"
        "h4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl"
        "5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREA"
        "AgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYk"
        "NOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOE"
        "hYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk"
        "5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDgqKKK+5PlAooooAKKKKACiiigAooooAKK"
        "KKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiig"
        "AooooAKKKKACirmnXkFp5nn6daXu7GPPaUbMZ6bHXr756Vc/tey/6F3Sv+/l1/8AHqlya6fk"
        "NJPqY9FbH9r2X/Qu6V/38uv/AI9R/a9l/wBC7pX/AH8uv/j1LmfZ/h/mPlXf8zHorY/tey/6"
        "F3Sv+/l1/wDHqP7Xsv8AoXdK/wC/l1/8eo5n2f4f5hyrv+Zj0Vsf2vZf9C7pX/fy6/8Aj1H9"
        "r2X/AELulf8Afy6/+PUcz7P8P8w5V3/Mx6K2P7Xsv+hd0r/v5df/AB6j+17L/oXdK/7+XX/x"
        "6jmfZ/h/mHKu/wCZj0Vsf2vZf9C7pX/fy6/+PUf2vZf9C7pX/fy6/wDj1HM+z/D/ADDlXf8A"
        "Mx6K2P7Xsv8AoXdK/wC/l1/8eo/tey/6F3Sv+/l1/wDHqOZ9n+H+Ycq7/mY9FbH9r2X/AELu"
        "lf8Afy6/+PVT1G8gu/L8jTrSy25z5DSnfnHXe7dPbHWmpN9PyE0u5ToooqhBRRRQBc06PT5P"
        "M/tK6u7fGNnkWyzbuuc5kTHb1/Crn2fw/wD9BPVf/BdH/wDH6x6Klxb6/kNNLobH2fw//wBB"
        "PVf/AAXR/wDx+j7P4f8A+gnqv/guj/8Aj9Y9FLlfd/h/kPmXb8zY+z+H/wDoJ6r/AOC6P/4/"
        "R9n8P/8AQT1X/wAF0f8A8frHoo5X3f4f5BzLt+ZsfZ/D/wD0E9V/8F0f/wAfo+z+H/8AoJ6r"
        "/wCC6P8A+P1j0Ucr7v8AD/IOZdvzNj7P4f8A+gnqv/guj/8Aj9H2fw//ANBPVf8AwXR//H6x"
        "6KOV93+H+Qcy7fmbH2fw/wD9BPVf/BdH/wDH6Ps/h/8A6Ceq/wDguj/+P1j0Ucr7v8P8g5l2"
        "/M2Ps/h//oJ6r/4Lo/8A4/R9n8P/APQT1X/wXR//AB+seijlfd/h/kHMu35mx9n8P/8AQT1X"
        "/wAF0f8A8fqnqMenx+X/AGbdXdxnO/z7ZYdvTGMSPnv6fjVOimotdfyE2uwUUUVQgooooAKK"
        "KKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiig"
        "AooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKK"
        "KKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA//2Q==",
    ),
}
NOTIFY_MEDIA_POSTS = [
    {"id": "pd-m1", "pkg": "com.whatsapp", "title": "pd-notify-title-8",
     "text": "pd-notify-text-8", "image": "good", "removeAfter": 8},
    {"id": "pd-m2", "pkg": "com.whatsapp", "title": "pd-notify-title-9",
     "text": "pd-notify-text-9", "image": "bad"},
    {"id": "pd-l1", "pkg": "com.uber", "title": "pd-notify-title-10",
     "text": "pd-notify-text-10", "live": {"progress": 0.1, "chip": "4 min"}, "tick": True},
    {"id": "pd-l2", "pkg": "com.uber", "title": "pd-notify-title-11",
     "text": "pd-notify-text-11", "live": {"chrono": "future", "countDown": True}},
]
NOTIFY_IMAGE_MAX = 200 * 1024
NOTIFY_LIVE_INTERVAL = 2.0
NOTIFY_LIVE_TICKS = 5

NOTIFY_MEDIA_STATE = {"playing": True, "pkg": "com.spotify.music", "title": "Fake Song",
                      "artist": "Fake Artist", "album": "Fake Album", "durationMs": 30000,
                      "positionMs": 0, "rate": 1.0}

# "Media part 2" (v0.2 #9, docs/design/notify.md): two playing apps, a seekable
# position, an absolute volume and artwork. The two rows are what the Mac's
# "Playing on phone" submenu should list; the title/artist/album are markers the
# e2e greps every log for to prove they never leave the wire, and the artwork is
# the same generated test card the notification picture uses.
MEDIA_SESSION_ROWS = [
    {"key": "s1", "pkg": "com.spotify.music", "app": "Spotify", "playing": True},
    {"key": "s2", "pkg": "com.google.android.youtube", "app": "YouTube", "playing": False},
]
MEDIA_TITLE = "pd-media-title-9"
MEDIA_ARTIST = "pd-media-artist-9"
MEDIA_ALBUM = "pd-media-album-9"
MEDIA_DURATION_MS = 30_000
MEDIA_MAX_VOLUME = 15


class FakeMedia(object):
    """The fake phone's Now Playing (docs/design/notify.md "Media part 2"): the
    session list, the chosen one, its position and its absolute volume. Every
    command it receives is logged by the event log (numbers and keys only)."""

    def __init__(self):
        self.rows = [dict(row) for row in MEDIA_SESSION_ROWS]
        self.chosen = self.rows[0]["key"]
        self.position = 0
        self.volume = 8
        self.playing = True
        self.art_sent_for = None
        self.art_sends = 0

    def current(self):
        return next(row for row in self.rows if row["key"] == self.chosen)

    def _playing(self):
        row = self.current()
        return bool(self.playing and row["playing"])

    def state(self):
        row = self.current()
        return {
            "t": "media.state", "playing": self._playing(), "pkg": row["pkg"],
            "key": row["key"], "title": MEDIA_TITLE, "artist": MEDIA_ARTIST,
            "album": MEDIA_ALBUM, "durationMs": MEDIA_DURATION_MS,
            "positionMs": self.position, "rate": 1.0 if self._playing() else 0.0,
            "canSeek": True, "volume": self.volume, "volumeMax": MEDIA_MAX_VOLUME,
        }

    def older_state(self):
        """What a phone that predates "Media part 2" sends: today's shape."""
        return {
            "t": "media.state", "playing": True, "pkg": "com.spotify.music",
            "title": MEDIA_TITLE, "artist": MEDIA_ARTIST, "album": MEDIA_ALBUM,
            "durationMs": MEDIA_DURATION_MS, "positionMs": self.position, "rate": 1.0,
        }

    def sessions_message(self):
        return {"t": "media.sessions", "list": [dict(row) for row in self.rows],
                "chosen": self.chosen}

    def art_message(self):
        return {"t": "media.art", "key": self.chosen, "mime": NOTIFY_IMAGE["mime"],
                "w": NOTIFY_IMAGE["w"], "h": NOTIFY_IMAGE["h"],
                "data": base64.b64encode(NOTIFY_IMAGE["data"]).decode("ascii")}


# The phone's zen modes (docs/design/focus.md): the wire names and their real
# Settings.Global.zen_mode values, kept here so the fake applies the same
# restore rule as ZenControl.
ZEN_MODES = {"off": 0, "priority": 1, "none": 2, "alarms": 3}
ZEN_NAMES = {code: name for name, code in ZEN_MODES.items()}


RINGER_MODES = {"silent": 0, "vibrate": 1, "normal": 2}


class FakeRinger(object):
    """The fake phone's ringer mode (docs/design/controls.md). A real phone at
    API 36 refuses a ringer change while DND is on, because that can end an
    "alarms" DND; the fake keeps the same rule."""

    def __init__(self, supported=True):
        self.supported = supported
        self.mode = "normal"

    def apply_from_mac(self, name, dnd):
        if not self.supported:
            return "unsupported"
        if name not in RINGER_MODES:
            return "bad_request"
        if dnd != "off":
            return "dnd_on"
        self.mode = name
        return None


class FakeZen(object):
    """The fake phone's DND setting plus the setByMac memory: the restore rule
    never turns off a DND the person set themselves."""

    def __init__(self, person=None, supported=True):
        self.supported = supported
        self.mode = ZEN_MODES[person] if person else ZEN_MODES["off"]
        # The mode PocketDeck turned on, or None when the DND is the person's.
        self.set_by_mac = None

    def name(self):
        return ZEN_NAMES[self.mode]

    def apply_from_mac(self, name):
        """Applies one phone.dnd mode (the phone's restore rule)."""
        code = ZEN_MODES[name]
        if code == ZEN_MODES["off"]:
            if self.set_by_mac is not None and self.mode == self.set_by_mac:
                self.mode = ZEN_MODES["off"]
            self.set_by_mac = None
        elif self.mode == code and self.set_by_mac == code:
            pass  # already ours (a reconnect must not re-apply it)
        elif self.mode != ZEN_MODES["off"]:
            self.set_by_mac = None  # the person's own DND: leave it alone
        else:
            self.mode = code
            self.set_by_mac = code



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


def _png_rgba(width, height, rows):
    """Encode 8-bit RGBA scanlines (a layer keeps around its transparent corners)."""
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw += bytes(row)

    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data +
                struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
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


def render_disc_png(size, rgba, radius_fraction=0.32):
    """The fg layer of the fake adaptive icons: a filled disc with a white
    "plane" triangle through the centre, on a transparent canvas. With a white
    bg layer this looks like the familiar example app (white squircle, blue
    circle, white plane) and lets a check tell the layers apart: the exact
    centre is the bg colour, just off it the fg colour."""
    radius = max(1.0, size * radius_fraction)
    centre = (size - 1) / 2.0
    plane = (255, 255, 255, 255)
    x0, x1 = size * 0.34, size * 0.63
    half = size * 0.16
    canvas = []
    for y in range(size):
        row = bytearray(size * 4)
        dy = y - centre
        for x in range(size):
            dx = x - centre
            if dx * dx + dy * dy <= radius * radius:
                colour = rgba
                if x0 <= x <= x1 and abs(dy) <= half * (x1 - x) / (x1 - x0):
                    colour = plane
                off = x * 4
                row[off:off + 4] = bytes(colour)
        canvas.append(row)
    return _png_rgba(size, size, canvas)


ADAPTIVE_EVERY = 3


def is_adaptive_pkg(pkg):
    """Every 3rd app of the label list uses an adaptive icon, like most real
    launchers; the others keep their flat one so the Deck shows both kinds."""
    for position, app in enumerate(sorted(APPS, key=lambda a: a["label"].lower())):
        if app["pkg"] == pkg:
            return position % ADAPTIVE_EVERY == 1
    return False


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
DROP_NAME = re.compile(r"^[A-Za-z0-9 ._\-]{1,100}$")
DROP_MAX_BYTES = 200 * 1024 * 1024
# The drop's PD_FAKE_DOWNGRADE: a chunk carrying these bytes answers too_large,
# so the cap rule is testable without a 200 MiB file.
DROP_FAKE_DOWNSIZE = b"PD_FAKE_DOWNSIZE"
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


def mirror_fit(w, h, screen_w, screen_h):
    """The phone mirror's size: inside w x h at the screen's aspect, never above the screen.

    round16 floors, so taking both sides from the same scale would stretch the
    aspect by up to 15 px of the short side: a 352x752 box gave 336x752 (2.238)
    for a 1080x2340 screen (2.167, the MIRROR check). The short side floors and
    the long side follows it at the screen's aspect, which is what a mirror does;
    the window shows the little that is left as bars.
    """
    scale = min(float(w) / screen_w, float(h) / screen_h, 1.0)
    if screen_w <= screen_h:
        fit_w = round16(screen_w * scale)
        return fit_w, round16(fit_w * screen_h / screen_w)
    fit_h = round16(screen_h * scale)
    return round16(fit_h * screen_w / screen_h), fit_h


def turn_box(w, h, screen_w, screen_h):
    """A Mac window box turned to the screen's current orientation."""
    return (w, h) if (h >= w) == (screen_h >= screen_w) else (h, w)


def round16(value):
    value = int(value)
    if value < 16:
        return 16
    return value - (value % 16)


# --- JSON Lines event log --------------------------------------------------
def redact_pairing(msg):
    """Pairing nonces, commitments and proofs never reach the event log
    (hard rule: lengths only); everything else is logged verbatim."""
    if not str(msg.get("t", "")).startswith("pair."):
        return msg
    return {k: ("<%d hex>" % len(v) if k in ("n", "c", "m") and isinstance(v, str) else v)
            for k, v in msg.items()}


def redact_event(msg):
    """The event log's privacy rule: notification and reply text never land in
    it (docs/design/notify.md). `notify.action`'s reply keeps its length only."""
    msg = redact_pairing(msg)
    if msg.get("t") == "notify.action" and isinstance(msg.get("text"), str):
        msg = dict(msg)
        msg["text"] = "<%d chars>" % len(msg["text"])
    # The test hook's chip is notification text too: its length only.
    if msg.get("t") == "notify.fake" and isinstance(msg.get("chip"), str):
        msg = dict(msg)
        msg["chip"] = "<%d chars>" % len(msg["chip"])
    return msg


class EventLog(object):
    """Writes the exact JSON Lines format other agents' tests consume."""

    def __init__(self, path):
        self._lock = threading.Lock()
        # Append mode on a file emptied here: a harness may empty the log
        # between two checks while this phone runs on, and every line still
        # lands at the new end (a plain "w" offset would leave a hole before it).
        if path:
            open(path, "w").close()
        self._fp = open(path, "a") if path else None
        self._writes = 0
        self._input = 0
        self._last_write = ""
        self._last_input = ""

    def _emit(self, obj):
        if self._fp is None:
            return
        line = json.dumps(obj, separators=(",", ":"))
        with self._lock:
            self._fp.write(line + "\n")
            self._fp.flush()

    def counters(self):
        """The cumulative NFR counters: every mutating request and every input
        event. A check reads the newest line at any point, so a flow's side
        effects are the difference between two reads."""
        return {"ev": "counters", "writes": self._writes, "input": self._input,
                "last_write": self._last_write, "last_input": self._last_input,
                "ts": time.time()}

    def emit_counters(self):
        self._emit(self.counters())

    def write(self, kind=""):
        """One mutating request reached the phone (WRITE_TYPES)."""
        self._writes += 1
        self._last_write = kind
        self._emit(self.counters())

    def input(self, kind=""):
        """One input event (touch/scroll/key/hover, nav, text) reached the phone."""
        self._input += 1
        self._last_input = kind
        self._emit(self.counters())

    def session(self, state):
        self._emit({"ev": "session", "state": state, "ts": time.time()})

    def dnd(self, mode, by_mac):
        """The phone's DND after a Mac command (mode name only, never a person)."""
        self._emit({"ev": "dnd", "mode": mode, "byMac": by_mac, "ts": time.time()})

    def ringer(self, mode):
        """The phone's ringer after a Mac command (mode name only)."""
        self._emit({"ev": "ringer", "mode": mode, "ts": time.time()})

    def ring(self, seconds):
        """phone.ring (seconds) or phone.ring.stop (0); never any phone data."""
        self._emit({"ev": "ring", "seconds": seconds, "ts": time.time()})

    def tx(self, msg):
        self._emit({"ev": "tx", "msg": redact_event(msg), "ts": time.time()})

    def screen(self, state):
        """Display 0's power state changed (`state.screen`)."""
        self._emit({"ev": "screen", "state": state, "ts": time.time()})

    def stall(self, stream, frames):
        """--stall-after: the stream stopped sending frames with the session
        still up; the check times the window's "not live" state from here."""
        self._emit({"ev": "stall", "stream": stream, "frames": frames,
                    "ts": time.time()})

    def rx(self, msg):
        self._emit({"ev": "rx", "msg": redact_event(msg), "ts": time.time()})
        # Every request leaves a fresh counters line, so a check that starts
        # reading after a log truncation still sees the cumulative values.
        self.emit_counters()

    def touch(self, stream, action, pointer, nx, ny):
        self._emit({"ev": "input", "kind": "touch", "stream": stream, "action": action,
                    "pointer": pointer, "nx": nx, "ny": ny, "ts": time.time()})

    def scroll(self, stream, nx, ny, h, v):
        self._emit({"ev": "input", "kind": "scroll", "stream": stream, "nx": nx, "ny": ny,
                    "h": h, "v": v, "ts": time.time()})

    def key(self, stream, action, keycode, meta):
        self._emit({"ev": "input", "kind": "key", "stream": stream, "action": action,
                    "keycode": keycode, "meta": meta, "ts": time.time()})

    def hover(self, stream, action, nx, ny):
        self._emit({"ev": "input", "kind": "hover", "stream": stream, "action": action,
                    "nx": nx, "ny": ny, "ts": time.time()})

    def frames(self, stream, n):
        """--frame-events: the stream's cumulative frame count, once a second."""
        self._emit({"ev": "frames", "stream": stream, "n": n, "ts": time.time()})

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

    def resize_held(self, stream, ms):
        """A window.resize is received and its answer held back (--resize-delay-ms)."""
        self._emit({"ev": "resize", "held": True, "stream": stream, "ms": ms,
                    "ts": time.time()})

    def clip(self, direction, text):
        self._emit({"ev": "clip", "dir": direction, "text": text, "ts": time.time()})

    def icon(self, pkg, png_bytes, layers, px=None):
        """an icon reply: packages and lengths only (no base64 in the log)."""
        self._emit({"ev": "icon", "pkg": pkg, "bytes": png_bytes, "layers": layers,
                    "px": px, "ts": time.time()})

    def link(self, stream, url):
        self._emit({"ev": "link", "stream": stream, "url": url, "ts": time.time()})

    def share(self, kind, value, **extra):
        event = {"ev": "share", "kind": kind, "value": value, "ts": time.time()}
        event.update(extra)
        self._emit(event)

    def apk(self, install_id, files, ok, code):
        self._emit({"ev": "apk", "id": install_id, "files": files, "ok": ok, "code": code,
                    "ts": time.time()})

    def task_continue(self, stream, mode, started):
        self._emit({"ev": "task.continue", "stream": stream, "mode": mode,
                    "started": started, "ts": time.time()})

    def drop(self, drop_id, files, ok, code):
        self._emit({"ev": "drop", "id": drop_id, "files": files, "ok": ok, "code": code,
                    "ts": time.time()})

    def clip_image(self, direction, name, **extra):
        event = {"ev": "clipimage", "dir": direction, "name": name, "ts": time.time()}
        event.update(extra)
        self._emit(event)

    def notify(self, kind, **fields):
        """notification events the phone sent: ids, packages and lengths only,
        never the notification's title or text (privacy, docs/design/notify.md)."""
        event = {"ev": "notify", "kind": kind, "ts": time.time()}
        event.update(fields)
        self._emit(event)

    def media(self, kind, **fields):
        """media events: the command it received (action, position, level) and the
        artwork it sent (dimensions and bytes only). Never any artwork bytes."""
        event = {"ev": "media", "kind": kind, "ts": time.time()}
        event.update(fields)
        self._emit(event)

    def fs(self, kind, **fields):
        event = {"ev": "fs", "kind": kind, "ts": time.time()}
        event.update(fields)
        self._emit(event)

    def close(self):
        with self._lock:
            if self._fp is not None:
                self._fp.close()
                self._fp = None


# --- read-only phone files (docs/PROTOCOL.md "Phone files") ----------------
# Same rules as the phone's FsPaths/FsView: paths relative to the root, one
# canonical target under it, Android/ and dot-prefixed top-level entries
# refused, pages of 1000 items / 1 MiB of JSON, etag = 16 bytes of
# (ino, size, mtime).
FS_MAX_PATH = 4096
FS_MAX_COMPONENTS = 32
FS_PAGE_ITEMS = 1000
FS_PAGE_BYTES = 1 << 20
FS_CHUNK = 256 * 1024
FS_MAX_WRITE = 1 << 30
FS_TEMP_PREFIX = ".pocketdeck-"
FS_TEMP_SUFFIX = ".part"


def fs_temp_name(name):
    return name.startswith(FS_TEMP_PREFIX) and name.endswith(FS_TEMP_SUFFIX) \
        and len(name) > len(FS_TEMP_PREFIX) + len(FS_TEMP_SUFFIX)


class FsError(Exception):
    def __init__(self, code, message=""):
        Exception.__init__(self, message or code)
        self.code = code
        self.message = message or code


class FsFake(object):
    def __init__(self, root):
        self.root = os.path.realpath(root)
        self.sweep_temps()

    def sweep_temps(self):
        """Removes a write's staging file a killed process left behind."""
        for base, _dirs, names in os.walk(self.root):
            for name in names:
                if fs_temp_name(name):
                    try:
                        os.unlink(os.path.join(base, name))
                    except OSError:
                        pass

    def resolve(self, rel):
        if rel is None:
            rel = ""
        if not isinstance(rel, str):
            raise FsError("fs_denied", "bad path")
        if rel.startswith("/"):
            raise FsError("fs_denied", "absolute path")
        if "\x00" in rel:
            raise FsError("fs_denied", "NUL in path")
        if "\\" in rel:
            raise FsError("fs_denied", "backslash in path")
        if len(rel.encode("utf-8")) > FS_MAX_PATH:
            raise FsError("fs_denied", "path too long")
        if rel == "":
            return self.root
        parts = rel.split("/")
        if len(parts) > FS_MAX_COMPONENTS:
            raise FsError("fs_denied", "too many components")
        for part in parts:
            if part in ("", ".", ".."):
                raise FsError("fs_denied", "bad component")
            if fs_temp_name(part):
                raise FsError("fs_denied", "staging name")
        if parts[0].startswith("."):
            raise FsError("fs_denied", "hidden entry")
        if parts[0] == "Android":
            raise FsError("fs_denied", "Android")
        target = os.path.realpath(os.path.join(self.root, rel))
        if target != self.root and not target.startswith(self.root + os.sep):
            raise FsError("fs_denied", "outside the root")
        return target

    def meta(self, path):
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            raise FsError("fs_not_found", "no such file")
        except OSError:
            raise FsError("fs_denied", "unreadable")
        is_dir = stat.S_ISDIR(st.st_mode)
        size = 0 if is_dir else st.st_size
        etag = hashlib.sha256(
            ("%d:%d:%d" % (st.st_ino, st.st_size, st.st_mtime_ns)).encode("ascii")
        ).hexdigest()[:32]
        return {"dir": is_dir, "size": size,
                "mtime": st.st_mtime_ns // 1000000, "ino": st.st_ino, "etag": etag}

    def list(self, rel, page):
        path = self.resolve(rel)
        meta = self.meta(path)
        if not meta["dir"]:
            raise FsError("fs_not_a_dir", "not a directory")
        try:
            names = os.listdir(path)
        except OSError:
            raise FsError("fs_denied", "unreadable directory")
        top = path == self.root
        names = sorted(n for n in names
                       if not fs_temp_name(n)
                       and (not top or not (n.startswith(".") or n == "Android")))
        start = 0
        if isinstance(page, str) and page.isdigit() and int(page) < len(names):
            start = int(page)
        items, used, index = [], 0, start
        while index < len(names) and len(items) < FS_PAGE_ITEMS:
            name = names[index]
            index += 1
            try:
                m = self.meta(os.path.join(path, name))
            except FsError:
                continue  # deleted since the listing
            item = dict(m)
            item["name"] = name
            cost = len(json.dumps(item, separators=(",", ":"))) + 1
            if items and used + cost > FS_PAGE_BYTES:
                index -= 1
                break
            items.append(item)
            used += cost
        return {"items": items, "page": str(index) if index < len(names) else None}

    def stat(self, rel):
        path = self.resolve(rel)
        meta = self.meta(path)
        item = dict(meta)
        item["name"] = "" if path == self.root else os.path.basename(path)
        return item

    def read_plan(self, rel, offset, length, etag):
        path = self.resolve(rel)
        meta = self.meta(path)
        if meta["dir"]:
            raise FsError("fs_not_a_dir", "not a directory")
        if not isinstance(offset, int) or not isinstance(length, int) \
                or offset < 0 or length < 0:
            raise FsError("fs_denied", "bad range")
        if isinstance(etag, str) and etag != meta["etag"]:
            raise FsError("fs_stale", "the file changed")
        size = meta["size"]
        if offset > size or length > size - offset:
            raise FsError("fs_denied", "range outside the file")
        return path


    # -- writes (docs/PROTOCOL.md "Phone files") ---------------------------
    def write_plan(self, rel, size, sha256, etag, exclusive=False):
        """The target and its hidden temp, or the refusal. Nothing is created."""
        if not isinstance(size, int) or size < 0:
            raise FsError("fs_denied", "no size")
        if size > FS_MAX_WRITE:
            raise FsError("fs_too_large", "over the write cap")
        if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
            raise FsError("fs_denied", "bad digest")
        target = self.resolve(rel)
        if target == self.root:
            raise FsError("fs_denied", "the root is not a file")
        meta = None
        try:
            meta = self.meta(target)
        except FsError as exc:
            if exc.code != "fs_not_found":
                raise
            if not os.path.isdir(os.path.dirname(target)):
                raise
        if meta is not None and meta["dir"]:
            raise FsError("fs_denied", "a directory is not a file")
        # A create never replaces what is there; a replace names the version it
        # replaces (docs/design/files.md §4).
        if exclusive or etag is None:
            if meta is not None:
                raise FsError("fs_exists", "that name is taken")
        elif etag != meta["etag"]:
            raise FsError("fs_stale", "the file changed")
        temp = os.path.join(os.path.dirname(target),
                            FS_TEMP_PREFIX + uuid.uuid4().hex + FS_TEMP_SUFFIX)
        return target, temp

    def finish_write(self, target, temp, size, sha256, etag, exclusive=False):
        """Verifies the temp, re-checks the target and renames into place."""
        try:
            if os.path.getsize(temp) != size:
                raise FsError("fs_denied", "the file arrived damaged")
            digest = hashlib.sha256()
            with open(temp, "rb") as handle:
                for block in iter(lambda: handle.read(1 << 20), b""):
                    digest.update(block)
            if digest.hexdigest() != str(sha256).lower():
                raise FsError("fs_denied", "the file arrived damaged")
            if exclusive:
                # Checked again right here: a file that appeared while the
                # bytes streamed is never replaced.
                if os.path.lexists(target):
                    raise FsError("fs_exists", "that name is taken")
            elif etag is not None:
                try:
                    meta = self.meta(target)
                except FsError:
                    raise FsError("fs_stale", "the file changed")
                if meta["dir"] or meta["etag"] != etag:
                    raise FsError("fs_stale", "the file changed")
            os.replace(temp, target)
        finally:
            if os.path.exists(temp):
                try:
                    os.unlink(temp)
                except OSError:
                    pass
        return self._item_at(target)

    def move(self, src, dst, etag):
        source = self.resolve(src)
        if source == self.root:
            raise FsError("fs_denied", "the root does not move")
        meta = self.meta(source)
        if etag is not None and etag != meta["etag"]:
            raise FsError("fs_stale", "the file changed")
        target = self.resolve(dst)
        if target == source:
            return self._item_at(target)
        if os.path.exists(target) or os.path.islink(target):
            raise FsError("fs_exists", "that name is taken")
        if meta["dir"] and target.startswith(source + os.sep):
            raise FsError("fs_denied", "a folder cannot move into itself")
        os.rename(source, target)
        return self._item_at(target)

    def delete(self, rel, recursive, etag=None):
        path = self.resolve(rel)
        if path == self.root:
            raise FsError("fs_denied", "the root does not delete")
        meta = self.meta(path)
        # Right before the delete: a change since the Mac's stat is fs_stale.
        if etag is not None and etag != meta["etag"]:
            raise FsError("fs_stale", "the file changed")
        if meta["dir"]:
            children = os.listdir(path)
            if children and not recursive:
                raise FsError("fs_denied", "the folder is not empty")
            _delete_tree(path)
        else:
            os.unlink(path)
        return meta

    def mkdir(self, rel):
        path = self.resolve(rel)
        if path == self.root or os.path.lexists(path):
            raise FsError("fs_exists", "that name is taken")
        parent = os.path.dirname(path)
        if not os.path.isdir(parent):
            raise FsError("fs_not_found", "no such folder")
        os.mkdir(path)
        return self._item_at(path)

    def set_attrs(self, rel, mtime):
        path = self.resolve(rel)
        self.meta(path)
        if isinstance(mtime, (int, float)) and mtime >= 0:
            st = os.stat(path)
            os.utime(path, ns=(st.st_atime_ns, int(mtime) * 1000000))
        return self._item_at(path)

    def _item_at(self, path):
        item = self.meta(path)
        item["name"] = "" if path == self.root else os.path.basename(path)
        return item


def _delete_tree(path):
    """Deletes a tree without following a symlink out of it."""
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        for name in os.listdir(path):
            _delete_tree(os.path.join(path, name))
        os.rmdir(path)
    else:
        os.unlink(path)


class FsWatchFake(object):
    """The phone's folder watcher (docs/PROTOCOL.md "Watching").

    A real phone uses one inotify watch per folder; the fake polls the tree,
    which gives the same observable behaviour: only requested folders, a
    coalesced ``fs.changes`` with the folders whose contents moved, and nothing
    at all while the set is empty. A ``.pocketdeck-*.part`` staging file is not
    a change. Names never reach the log: counts only.
    """

    POLL_S = 0.4

    def __init__(self, fs):
        self.fs = fs
        self.paths = []                 # wanted folders, in request order
        self.snapshots = {}
        self.lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = None
        self._sink = None

    def on_changes(self, sink):
        self._sink = sink

    def watch(self, paths):
        folders = [self._folder(rel) for rel in paths]
        with self.lock:
            for rel in folders:
                if rel in self.paths:
                    continue
                self.paths.append(rel)
                self.snapshots[rel] = self._snapshot(rel)
            if self.paths and self._thread is None:
                self._stop.clear()
                self._thread = threading.Thread(target=self._run, daemon=True)
                self._thread.start()
            return len(self.paths)

    def unwatch(self, paths):
        folders = [self._folder(rel) for rel in paths]
        with self.lock:
            for rel in folders:
                if rel in self.paths:
                    self.paths.remove(rel)
                    self.snapshots.pop(rel, None)
            count = len(self.paths)
            if count == 0:
                self._stop.set()
                self._thread = None
            return count

    def close(self):
        with self.lock:
            self.paths = []
            self.snapshots = {}
            self._stop.set()
            self._thread = None

    # -- internals -------------------------------------------------------

    def _folder(self, rel):
        target = self.fs.resolve(rel)
        meta = self.fs.meta(target)
        if not meta["dir"]:
            raise FsError("fs_not_a_dir", "not a directory")
        return "" if target == self.fs.root else os.path.relpath(target, self.fs.root)

    def _snapshot(self, rel):
        try:
            target = self.fs.resolve(rel)
            with os.scandir(target) as entries:
                out = {}
                for entry in entries:
                    if fs_temp_name(entry.name):
                        continue
                    try:
                        st = entry.stat(follow_symlinks=False)
                    except OSError:
                        continue
                    out[entry.name] = (st.st_mtime_ns, st.st_size, 1 if entry.is_dir() else 0)
                return out
        except (FsError, OSError):
            return None

    def _run(self):
        while not self._stop.wait(self.POLL_S):
            with self.lock:
                paths = list(self.paths)
            changed = []
            for rel in paths:
                now = self._snapshot(rel)
                with self.lock:
                    if rel not in self.paths:
                        continue
                    if self.snapshots.get(rel) == now:
                        continue
                    self.snapshots[rel] = now
                changed.append(rel)
            if changed and self._sink is not None:
                sys.stderr.write("fakephone: changes %d\n" % len(changed))
                sys.stderr.flush()
                self._sink(changed)


def _fs_id(msg):
    value = msg.get("id")
    if isinstance(value, int) and 0 < value <= 0xFFFFFFFF:
        return value
    return None


# --- TLS 1.3 identity (docs/design/e2ee.md §1/§2) --------------------------
# shared with proto.py's v2 section: identity generation, fingerprint, contexts.
PENDING_QR_TTL = 300  # the phone's copy expires with the Mac's sheet


def scan_qr_uri(store, uri):
    """Simulate the QR scan (review R2): `pocketdeck://pair?c=&n=&f=&s=`.

    The phone pins the Mac by `f` until a Mac whose certificate fingerprint
    matches connects; it then answers with pair.qr = HMAC(s, exporter||phoneFP)
    and waits for the Mac's pair.ok before the Allow gate. Nothing is paired
    from the scan itself.
    """
    parsed = urllib.parse.urlparse(uri.strip())
    if parsed.scheme.lower() != "pocketdeck" or parsed.netloc.lower() != "pair":
        raise ValueError("not a PocketDeck pairing URI: %r" % uri)
    params = urllib.parse.parse_qs(parsed.query)
    client_id = (params.get("c") or [""])[0].strip()
    fp_hex = (params.get("f") or [""])[0].strip()
    secret_hex = (params.get("s") or [""])[0].strip()
    name = (params.get("n") or ["Mac"])[0]
    if not client_id or len(fp_hex) != 64 or len(secret_hex) != 32:
        raise ValueError("pairing URI needs ?c=<clientId>&f=<64 hex>&s=<32 hex>")
    try:
        bytes.fromhex(fp_hex)
        bytes.fromhex(secret_hex)
    except ValueError:
        raise ValueError("pairing URI fingerprint/secret is not hex")
    store.set_pending_qr({"clientId": client_id, "name": name,
                          "macFp": fp_hex.lower(), "secret": secret_hex.lower(),
                          "at": time.time()})
    print("QR scan staged for %r (%s), expires with the QR" % (name, client_id))
    sys.stdout.flush()


class Store(object):
    """v2 pin state: per-Mac fingerprint pins (no shared secrets, v1 files die)."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.device_id = None
        self.clients = {}
        self.pending_qr = None
        self._load()

    def _load(self):
        try:
            with open(self.path, "r") as fp:
                data = json.load(fp)
        except (IOError, OSError, ValueError):
            data = {}
        self.device_id = data.get("id") or proto.gen_device_id()
        clients = {}
        for client_id, entry in data.get("clients", {}).items():
            # v1 entries carry a shared key and pin nothing in v2: dropped.
            if isinstance(entry, dict) and entry.get("macFp"):
                clients[client_id] = {"name": entry.get("name", "Mac"),
                                      "macFp": entry["macFp"]}
        self.clients = clients

    def save(self):
        with self.lock:
            data = {"id": self.device_id, "clients": self.clients}
            tmp = self.path + ".tmp"
            with open(tmp, "w") as fp:
                json.dump(data, fp, indent=2)
            os.replace(tmp, self.path)

    def set_pending_qr(self, pending):
        # Memory only, like the phone's 5-minute PendingQr: the one-time
        # secret never reaches the state file.
        self.pending_qr = pending

    def pinned_for(self, client_id):
        entry = self.clients.get(client_id)
        if not entry:
            return None
        return entry["macFp"]

    def add_pinned_client(self, client_id, name, mac_fp_hex):
        # The slot assignment is atomic; save() owns the lock (a client is
        # never torn read-modify-write across threads by anything else).
        self.clients[client_id] = {"name": name, "macFp": mac_fp_hex}
        self.pending_qr = None  # the scan is consumed
        self.save()


# --- outgoing send queue (priority + per-stream backpressure) --------------
class Sender(object):
    def __init__(self, sock, on_backlog_cleared):
        self._sock = sock
        self._on_backlog_cleared = on_backlog_cleared
        self._json = []
        self._key = []
        self._delta = []
        self._bulk = []             # (stream, data) phone->mac bulk: FS_DATA first-ish
        self._bulk_bytes = 0
        self._bulk_cancelled = set()
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

    def send_bulk(self, stream, data):
        """Phone->mac bulk data (FS_DATA and the JSON closing it): FIFO among
        itself, the lowest priority, and bounded at 1 MiB like the real phone's
        bulk lane, so the producer waits instead of buffering a file."""
        with self._cv:
            while not self._closed and self._bulk_bytes > 0 \
                    and self._bulk_bytes + len(data) > MAX_BULK_BYTES:
                self._cv.wait()
            if self._closed:
                return False
            if stream in self._bulk_cancelled:
                return False
            self._bulk.append((stream, data))
            self._bulk_bytes += len(data)
            self._cv.notify()
            return True

    def cancel_bulk(self, stream):
        """fs.cancel: drop what is queued for that read; nothing more is taken."""
        with self._cv:
            self._bulk_cancelled.add(stream)
            keep = [item for item in self._bulk if item[0] != stream]
            self._bulk_bytes = sum(len(data) for _stream, data in keep)
            self._bulk = keep
            self._cv.notify()

    def forget_stream(self, stream):
        with self._cv:
            self._pending.pop(stream, None)
            self._need_key.discard(stream)
            self._delta = [item for item in self._delta if item[0] != stream]
            self._key = [item for item in self._key if item[0] != stream]

    def _run(self):
        while True:
            with self._cv:
                while not (self._json or self._key or self._bulk or self._delta) \
                        and not self._closed:
                    self._cv.wait()
                if self._closed:
                    return
                if self._json:
                    stream, data = self._json.pop(0)
                elif self._key:
                    stream, data = self._key.pop(0)
                elif self._bulk:
                    stream, data = self._bulk.pop(0)
                    self._bulk_bytes -= len(data)
                    self._cv.notify_all()
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
                # The e2e cancel rule needs the write, not the enqueue: a frame
                # dropped from the queue must leave no line behind.
                if len(data) >= 9 and (data[4] & 0xFF) == proto.TYPE_FS_DATA:
                    sys.stderr.write("fakephone: fs sent id=%d %d bytes\n" % (stream, len(data) - 9))
                    sys.stderr.flush()
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
        if mode == "phone":
            # A mirror of the phone's own screen: display 0, at the screen's aspect.
            self.w, self.h = mirror_fit(*turn_box(w, h, *phone.screen) + phone.screen)
            self.display_id = 0
        else:
            self.display_id = phone.next_display_id()
        self.label = "Home" if mode == "phone" else (self._label_for(pkg) or pkg)
        self._enc = None
        self._reader = None
        self._configured = False
        self._resize_timer = None
        self._au_index = 0
        # Cumulative across encoder restarts (pause/resume, keyframes), so the
        # e2e can tell that frames flowed again after a resume.
        self._frames_sent = 0
        self._paused = False
        # --secure-after: the encoder sends solid black while a secure surface
        # would be blanked in the mirror.
        self._black = False
        self._stall_timer = None
        self._lock = threading.Lock()

    @staticmethod
    def _label_for(pkg):
        for app in APPS:
            if app["pkg"] == pkg:
                return app["label"]
        return None

    def _source(self):
        if self._black:
            return "color=c=black:size=%dx%d:rate=%d" % (self.w, self.h, FRAME_RATE)
        if self.mode == "phone":
            return "smptehdbars=size=%dx%d:rate=%d" % (self.w, self.h, FRAME_RATE)
        return "testsrc2=size=%dx%d:rate=%d" % (self.w, self.h, FRAME_RATE)

    def _cmd(self):
        # -re paces the lavfi source to real time; without it ffmpeg encodes as
        # fast as the CPU allows (thousands of fps for cheap patterns).
        cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-re",
               "-f", "lavfi", "-i", self._source()]
        # Still overlays, in order: the stream id/size label and, with
        # --text-frame, a large word on a white band for Live Text's analyser.
        overlays = []
        if self.phone.label_dir and self.h >= 48:
            text = "stream=%d %dx%d" % (self.stream_id, self.w, self.h)
            path = os.path.join(self.phone.label_dir,
                                "stream-%d-%dx%d.png" % (self.stream_id, self.w, self.h))
            if not os.path.exists(path):
                with open(path, "wb") as fp:
                    fp.write(render_text_png(text, 8 + len(text) * 12, 18,
                                             (255, 255, 255), (16, 16, 16), scale=2))
            overlays.append((path, "8:8"))
        word = getattr(self.phone.args, "text_frame", None)
        if word:
            digest = hashlib.md5(word.encode("utf-8")).hexdigest()[:8]
            path = os.path.join(self.phone.label_dir or tempfile.gettempdir(),
                                "livetext-%s-%dx%d.png" % (digest, self.w, self.h))
            band = max(64, self.h // 3)
            if not os.path.exists(path):
                with open(path, "wb") as fp:
                    fp.write(render_text_png(word, self.w, band,
                                             (16, 16, 16), (255, 255, 255)))
            # The band is static for the whole stream: the word never moves,
            # so an analysis taken at any moment sees the same picture.
            overlays.append((path, "0:%d" % ((self.h - band) // 2)))
        for index, (path, position) in enumerate(overlays):
            cmd += ["-i", path]
        if overlays:
            chain = []
            source = "[0:v]"
            for index, (_, position) in enumerate(overlays, start=1):
                out = "[v]" if index == len(overlays) else "[v%d]" % index
                chain.append("%s[%d:v]overlay=%s%s" % (source, index, position, out))
                source = out
            cmd += ["-filter_complex", ";".join(chain), "-map", "[v]"]
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

    def black_for(self, seconds, alive):
        """Solid black frames for a secure surface, then the normal picture.

        alive() says whether this window is still open; a closed window must not
        be restarted by the timer.
        """
        self._black = True
        self.start()
        time.sleep(seconds)
        self._black = False
        if alive():
            self.start()

    def pause(self):
        with self._lock:
            if not self._paused:
                self._stop_locked()
                self._paused = True

    def _stall(self):
        """--stall-after: stop the encoder but keep the session and its socket."""
        self.pause()
        self.phone.events.stall(self.stream_id, self._frames_sent)

    def stop(self):
        with self._lock:
            if self._stall_timer is not None:
                self._stall_timer.cancel()
                self._stall_timer = None
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
            if self.phone.args.stall_after and self._stall_timer is None:
                # The phone's picture freezes while the session stays up: the
                # stale-picture and frozen-mode checks start here.
                self._stall_timer = threading.Timer(
                    self.phone.args.stall_after, self._stall)
                self._stall_timer.daemon = True
                self._stall_timer.start()
        flags = proto.FRAME_FLAG_KEY if proto.is_idr(nals) else 0
        pts = self._au_index * (1000000 // FRAME_RATE)
        self._au_index += 1
        self.phone.sender.send_frame(self.stream_id, pts, flags, access_unit)
        self._frames_sent += 1
        if self.phone.args.frame_events and self._frames_sent % FRAME_RATE == 0:
            self.phone.events.frames(self.stream_id, self._frames_sent)


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
        self.client_name = None
        self.mac_fp_hex = None          # the Mac's point fingerprint (hello `fp`)
        self.windows = {}
        self._unknown_types = set()
        self.audio = AudioTone(phone)
        self._fs_jobs = {}              # id -> {"cancel": Event, "thread": Thread}
        self._fs_write = None           # the one fs.write in flight
        self._fs_lock = threading.Lock()
        # The folders the Mac has open (docs/PROTOCOL.md "Watching"); nothing
        # is watched before fs.watch and everything stops with the session.
        self._watcher = FsWatchFake(phone.fs) if phone.fs is not None else None
        if self._watcher is not None:
            self._watcher.on_changes(self._on_fs_changes)
        # Fake Live Updates (docs/design/notify.md): one ticker per session and
        # the same one-per-second coalescing the real phone applies.
        self._live_thread = None
        self._live_stop = threading.Event()
        self._live_lock = threading.Lock()
        self._live_last = {}
        self._live_pending = {}
        self._live_flusher = None
        self._thread = threading.Thread(target=self._run, daemon=True)
    def start(self):
        self._thread.start()

    def close(self):
        for sock in (getattr(self, "sock", None),):
            if sock is None:
                continue
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass

    def _run(self):
        """TLS wrap first (docs/design/e2ee.md §2): nothing speaks plaintext.

        Anything that dies before the first session byte — an aborted client
        (the Mac's Bonjour resolve opens a connection and closes it: review
        R4-b), a plaintext probe, a port scan — stays quiet: no error-level
        log, no pairing prompt, no counted failed attempt. A debug hint under
        FAKE_DEBUG only.
        """
        try:
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if self.phone.args.no_tls:
                self.phone.events.session("open")
                self._handshake_serve()
                return
            conn = self.phone.accept_tls(self.sock)
            self.sock = conn
            self.phone.events.session("open")
            self._handshake_serve()
        except proto.ProtocolError as exc:
            sys.stderr.write("fakephone: session error: %s\n" % exc)
        except Exception as exc:
            dbg("tls handshake dropped: %s: %s" % (type(exc).__name__, exc))
        finally:
            self._teardown()

    def _handshake_serve(self):
        self.sender = Sender(self.sock, self.phone.on_backlog_cleared)
        self.phone.sender = self.sender
        if self.handshake():
            self._main_loop()

    def _teardown(self):
        self._live_stop.set()
        try:
            self.audio.stop()
        except Exception:
            pass
        self._cancel_fs_reads()
        if self._watcher is not None:
            self._watcher.close()
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
        # Pairing sends get their own event line (the e2e `tls` matrix reads
        # the phone's side of the flow verbatim); feature traffic is rx-only,
        # so the older event counts stay unchanged.
        if str(obj.get("t", "")).startswith("pair."):
            self.phone.events.tx(obj)
        self.sender.send_json(obj)

    def handshake(self):
        """The v2 greeting (parity with the phone's Session.kt): hello v2 names
        the client; the Mac's fingerprint comes from the TLS handshake's client
        certificate, never from a hello field. A pinned Mac that still presents
        its stored fingerprint gets `welcome`; anything else pairs via §4 or
        the R2 QR."""
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
        version = msg.get("v")
        if not self.phone.args.legacy_phone:
            if version != 2:
                self._send_error("version")
                return False
        self.client_id = msg.get("clientId")
        self.client_name = msg.get("name", "")
        if self.phone.args.refuse_connections:
            # The phone's master switch: every Mac, paired or not.
            return self._refuse("connections_off", "refused_connections")
        if self.phone.args.refuse_pairings and self.phone.store.pinned_for(self.client_id) is None:
            # The pairing switch: unknown Macs only, before any code exists.
            return self._refuse("pairing_off", "refused_pairing")
        if self.phone.args.legacy_phone:
            # A v1 phone answers hello with its challenge and then waits for
            # auth like any v1 phone would; the v2 Mac surfaces the version
            # mismatch and hangs up. Kill the read only when the Mac goes.
            self.mac_fp_hex = ""
            self.nonce = proto.gen_nonce_hex()
            self._send({"t": "challenge", "nonce": self.nonce, "id": self.phone.store.device_id})
            while True:
                frame = proto.recv_frame(self.sock)
                if frame is None:
                    return False
        # §1: the phone pins what the handshake presented; no self-report.
        self.mac_fp_hex = (proto.point_fp_from_der(self.sock.client_der)
                           if getattr(self.sock, "client_der", None) else "")
        pinned = self.phone.store.pinned_for(self.client_id)
        if pinned is not None:
            if not hmac.compare_digest(pinned, self.mac_fp_hex):
                self._send_error("bad_pin", "this Mac's certificate changed; pair again")
                # The Mac must read the error before the close lands: hold the
                # with the same write-then-close shape Session.kt uses.
                while True:
                    try:
                        if proto.recv_frame(self.sock) is None:
                            break
                    except (proto.ProtocolError, OSError):
                        break
                return False
            self.phone.events.session("auth_ok")
            self.welcome()
            return True
        pending = self.phone.store.pending_qr
        if self._pending_qr_fresh(pending) and (pending["macFp"] or "").lower() == self.mac_fp_hex:
            return self.pair_qr_flow(pending)
        return self.pair_request_flow()

    def _pending_qr_fresh(self, pending):
        if not pending:
            return False
        at = float(pending.get("at") or 0)
        return 0 <= time.time() - at <= PENDING_QR_TTL

    # -- v2 code pairing (§4): the Mac asks (pair.request), the phone commits --
    def pair_request_flow(self):
        """The Mac's pair.request is the pairing intent; the phone answers with
        pair.commit (fresh Np, phoneFP‖macFP bound) before the Mac releases its
        nonce, then reveals and shows the code with its Allow prompt."""
        frame = proto.recv_frame(self.sock)
        if frame is None:
            return False
        if frame.type != proto.TYPE_JSON:
            self._send_error("protocol", "expected pair.request")
            return False
        msg = proto.unpack_json(frame)
        self.phone.events.rx(msg)
        if msg.get("t") != "pair.request":
            self._send_error("protocol", "expected pair.request")
            return False
        self.np = os.urandom(16)
        phone_fp = bytes.fromhex(self.phone.fp_hex)
        mac_fp = bytes.fromhex(self.mac_fp_hex)
        commit = hashlib.sha256(b"pd-commit-v2" + self.np + phone_fp + mac_fp).digest()
        self._send({"t": "pair.commit", "c": commit.hex()})
        frame = proto.recv_frame(self.sock)
        if frame is None:
            return False
        if frame.type != proto.TYPE_JSON:
            self._send_error("protocol", "expected pair.nonce")
            return False
        msg = proto.unpack_json(frame)
        self.phone.events.rx(msg)
        if msg.get("t") != "pair.nonce":
            self._send_error("pair_commit", "expected pair.nonce")
            return False
        try:
            nm = bytes.fromhex(msg.get("n") or "")
        except ValueError:
            nm = b""
        if len(nm) != 16:
            self._send_error("pair_commit", "bad nonce")
            return False
        dbg("reveal sent; decision next")
        self._send({"t": "pair.reveal", "n": self.np.hex()})
        # §4: the code derives from the REAL TLS exporter on both ends —
        # pyOpenSSL's export_keying_material is the same RFC 8446 §7.5 formula
        # ExporterV2 runs on the Mac, so the screens show the same code (the
        # e2e `pair` check asserts the equality; K4 asserts it on-device).
        exporter = self.exporter()
        if exporter is None:
            raise proto.ProtocolError("pair.reveal: no exporter from TLS")
        preimage = hashlib.sha256(b"pd-code-v2" + exporter +
                                  mac_fp + phone_fp + nm + self.np).digest()
        code = int.from_bytes(preimage[:8], "big") % 1000000
        code = "%06d" % code
        self.phone.report_code(code)
        if not self.decision():
            dbg("decision false")
            return False
        dbg("decision true; storing pin")
        self.phone.store.add_pinned_client(self.client_id, self.client_name, self.mac_fp_hex)
        dbg("pin stored; sending pair.ok")
        self._send({"t": "pair.ok", "phoneFP": self.phone.fp_hex, "macFP": self.mac_fp_hex})
        dbg("pair.ok sent")
        self.phone.events.session("paired")
        self.welcome()
        return True

    # -- R2 QR pairing --
    def pair_qr_flow(self, pending):
        """The phone proved the scan (pair.qr HMAC over the REAL exporter, the
        same bytes the Mac derives); the Mac verifies, pins and sends
        pair.ok {macFP}; the Allow prompt still gates."""
        exporter = self.exporter()
        if exporter is None:
            raise proto.ProtocolError("pair.qr: no exporter from TLS")
        phone_fp = bytes.fromhex(self.phone.fp_hex)
        mac = hmac.new(bytes.fromhex(pending["secret"]),
                       b"pd-qr-v2" + exporter + phone_fp, hashlib.sha256).hexdigest()
        self._send({"t": "pair.qr", "m": mac})
        frame = proto.recv_frame(self.sock)
        if frame is None:
            return False
        if frame.type != proto.TYPE_JSON:
            self._send_error("protocol", "expected pair.ok")
            return False
        msg = proto.unpack_json(frame)
        self.phone.events.rx(msg)
        if msg.get("t") != "pair.ok":
            self._send_error("protocol", "expected pair.ok")
            return False
        # Parity with the phone: the Mac's pair.ok must name THIS session's
        # Mac fingerprint (the handshake's client cert).
        if not hmac.compare_digest((msg.get("macFP") or "").lower(), self.mac_fp_hex):
            self._send_error("pair_commit", "pair.ok does not match the session")
            return False
        if not self.decision():
            return False
        self.phone.store.add_pinned_client(self.client_id, self.client_name, self.mac_fp_hex)
        # Same shape the phone always sends (Session.kt completePairing): the
        # Mac cross-checks phoneFP against the handshake pin it learned.
        self._send({"t": "pair.ok", "phoneFP": self.phone.fp_hex, "macFP": self.mac_fp_hex})
        self.phone.events.session("paired")
        self.welcome()
        return True

    def exporter(self):
        """The REAL RFC 8446 §7.5 exporter of this TLS session (32 bytes):
        pyOpenSSL's export is the formula both stacks agree on. Never logged;
        memory only."""
        material = getattr(self.sock, "exporter", None)
        if material is None:
            dbg("no exporter on %r (sock type %s)" % (self.sock, type(self.sock).__name__))
            return None
        try:
            data = material(b"EXPORTER-pocketdeck-pair", 32)
        except Exception as exc:
            dbg("exporter unavailable: %s: %s" % (type(exc).__name__, exc))
            return None
        if not data or len(data) != 32:
            dbg("exporter came back %r" % data)
            return None
        return data

    def decision(self):
        """True = Allow, False = Deny, None = the Mac hung up first (Cancel)."""
        if not self.phone.args.auto_allow:
            result = self.phone.ask_allow(self.client_name)
            return result
        deadline = time.time() + self.phone.args.allow_delay
        while True:
            left = deadline - time.time()
            if left <= 0:
                return True
            # The TLS layer may hold decoded bytes: select the raw socket.
            readable = getattr(self.sock, "raw_socket", lambda: self.sock)()
            ready, _, _ = select.select([readable], [], [], left)
            if ready:
                # The Mac says nothing while a person decides: readable means it hung up.
                return None

    def welcome(self):
        self._send({"t": "welcome", "device": {
            "id": self.phone.store.device_id,
            "name": self.phone.name,
            "model": DEVICE_MODEL,
            "sdk": 36,
            "screen": {"w": SCREEN_W, "h": SCREEN_H, "dpi": SCREEN_DPI},
            "locked": True,
        }})
        self.send_state()
        if self.phone.args.clip_on_welcome is not None:
            text = self.phone.args.clip_on_welcome
            self._send({"t": "clip.set", "text": text})
            self.phone.events.clip("tx", text)
        if self.phone.args.share:
            threading.Thread(target=self._send_shares, daemon=True).start()

    def send_state(self):
        """The `state` message, with `dnd` only when the phone supports it."""
        state = {"t": "state", "locked": True, "battery": BATTERY, "charging": False,
                 "screen": self.phone.screen_state}
        if self.phone.secure_state is not None:
            state["secure"] = self.phone.secure_state
        if self.phone.zen.supported:
            state["dnd"] = self.phone.zen.name()
        if self.phone.fake_ringer.supported:
            state["ringer"] = self.phone.fake_ringer.mode
        self._send(state)

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
                if msg.get("t") in WRITE_TYPES:
                    self.phone.events.write(msg.get("t"))
                # Back/Home/Recents and typed text reach the phone as one
                # message, not as key frames: they are input events too.
                if msg.get("t") in INPUT_TYPES:
                    self.phone.events.input(msg.get("t"))
                self._handle_json(msg)
            elif frame.type == proto.TYPE_TOUCH:
                action, pointer, nx, ny = proto.unpack_touch(frame)
                self.phone.events.input("touch")
                self.phone.events.touch(frame.stream, action, pointer, nx, ny)
            elif frame.type == proto.TYPE_SCROLL:
                nx, ny, h, v = proto.unpack_scroll(frame)
                self.phone.events.input("scroll")
                self.phone.events.scroll(frame.stream, nx, ny, h, v)
            elif frame.type == proto.TYPE_KEY:
                action, keycode, meta = proto.unpack_key(frame)
                self.phone.events.input("key")
                self.phone.events.key(frame.stream, action, keycode, meta)
            elif frame.type == proto.TYPE_HOVER:
                action, nx, ny = proto.unpack_hover(frame)
                self.phone.events.input("hover")
                self.phone.events.hover(frame.stream, action, nx, ny)
            elif frame.type == proto.TYPE_APK_DATA:
                self._on_apk_data(frame.stream, frame.payload)
            elif frame.type == proto.TYPE_DROP_DATA:
                self._on_drop_data(frame.stream, frame.payload)
            elif frame.type == proto.TYPE_CLIP_DATA:
                self._on_clip_data(frame.stream, frame.payload)
            elif frame.type == proto.TYPE_FS_DATA:
                self._on_fs_data(frame.stream, frame.payload)
            elif frame.type not in self._unknown_types:
                self._unknown_types.add(frame.type)
                sys.stderr.write("fakephone: ignoring unknown frame type 0x%02x\n" % frame.type)

    def _handle_json(self, msg):
        kind = msg.get("t")
        handlers = {
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
            "task.continue": self._on_task_continue,
            "nav": self._on_nav,
            "text": self._on_noop,
            "clip.set": self._on_clip_set,
            "apk.install": self._on_apk_install,
            "apk.cancel": self._on_apk_cancel,
            "drop.start": self._on_drop_start,
            "drop.cancel": self._on_drop_cancel,
            "clip.image.start": self._on_clip_image_start,
            "clip.image.end": self._on_clip_image_end,
            "clip.image.abort": self._on_clip_image_abort,
            "audio.start": self._on_audio_start,
            "audio.stop": self._on_audio_stop,
            "notify.enable": self._on_notify_enable,
            "notify.open": self._on_notify_open,
            "notify.action": self._on_notify_action,
            "notify.dismiss": self._on_notify_dismiss,
            "notify.fake": self._on_notify_fake,
            "media.command": self._on_media_command,
            "media.choose": self._on_media_choose,
            "fs.list": self._on_fs_list,
            "fs.stat": self._on_fs_stat,
            "fs.read": self._on_fs_read,
            "fs.write": self._on_fs_write,
            "fs.move": self._on_fs_move,
            "fs.delete": self._on_fs_delete,
            "fs.mkdir": self._on_fs_mkdir,
            "fs.setAttrs": self._on_fs_set_attrs,
            "fs.watch": self._on_fs_watch,
            "fs.unwatch": self._on_fs_unwatch,
            "fs.cancel": self._on_fs_cancel,
        }
        # A phone without DND support keeps phone.dnd unknown (logged once).
        if self.phone.zen.supported:
            handlers["phone.dnd"] = self._on_phone_dnd
        # Likewise an old build has no ringer: state carries none, phone.ringer
        # is an unknown message, and the events log stays silent about it.
        if self.phone.fake_ringer.supported:
            handlers["phone.ringer"] = self._on_phone_ringer
        handlers["phone.wake"] = self._on_phone_wake
        handlers["phone.ring"] = self._on_phone_ring
        handlers["phone.ring.stop"] = self._on_phone_ring_stop
        handler = handlers.get(kind)
        if handler is None:
            if kind not in self._unknown_types:
                self._unknown_types.add(kind)
                sys.stderr.write("fakephone: ignoring unknown message %r\n" % kind)
            return
        handler(msg)

    def _on_ping(self, msg):
        self._send({"t": "pong", "ts": msg.get("ts")})

    def _on_phone_dnd(self, msg):
        """phone.dnd (docs/design/focus.md): the fake applies the phone's own
        restore rule and reports the mode it holds; a real change sends state."""
        mode = msg.get("mode")
        if mode not in ZEN_MODES:
            self._send_error("bad_request", "phone.dnd needs mode priority|alarms|none|off")
            return
        self.phone.zen.apply_from_mac(mode)
        self.phone.events.dnd(self.phone.zen.name(), self.phone.zen.set_by_mac is not None)
        # Like the real phone, the answer is a new state even when the mode did
        # not move (the person's own DND is left alone but the Mac gets truth).
        self.send_state()

    def _on_phone_ringer(self, msg):
        """phone.ringer (docs/design/controls.md): one exact mode, never a
        volume; refused while DND is on (the shell control has the same rule)."""
        mode = msg.get("mode")
        error = self.phone.fake_ringer.apply_from_mac(mode, self.phone.zen.name())
        if error == "bad_request":
            self._send_error("bad_request", "phone.ringer needs mode normal|vibrate|silent")
            return
        if error == "dnd_on":
            self._send_error("dnd_on", "phone.ringer needs Do Not Disturb off")
            return
        if error == "unsupported":
            self._send_error("unsupported", "phone.ringer needs the shell service")
            return
        self.phone.events.ringer(self.phone.fake_ringer.mode)
        self.send_state()

    def _on_phone_wake(self, _msg):
        """phone.wake: display 0 comes back on and the mirror repaints. The fake
        has no keyguard to keep; it reports the panel state the real phone does."""
        self.phone.screen_state = "on"
        self.phone.events.screen("on")
        for window in self.windows.values():
            if window.mode == "phone":
                window.start()
        self.send_state()

    def _on_phone_ring(self, msg):
        """phone.ring: the app process rings; the fake answers the same
        ring.state the real phone does (the e2e checks the request arrived)."""
        seconds = int(msg.get("seconds") or 30)
        self.phone.events.ring(max(1, min(30, seconds)))
        self._send({"t": "ring.state", "ringing": True})

    def _on_phone_ring_stop(self, _msg):
        self.phone.events.ring(0)
        self._send({"t": "ring.state", "ringing": False})

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

    # -- file drops (docs/design/dragdrop.md): acts like Downloads/PocketDeck; a
    # part whose bytes carry PD_FAKE_DOWNSIZE trips the size rule, and the
    # announced sha256 decides the result like the real receiver.
    def _on_drop_start(self, msg):
        drop_id = msg.get("id")
        name = msg.get("name")
        size = msg.get("size")
        sha = msg.get("sha256")
        if getattr(self, "_drop", None) is not None:
            self._send({"t": "drop.result", "id": drop_id, "ok": False, "code": "busy",
                        "message": "another drop is running"})
            return
        if not isinstance(drop_id, int) or drop_id <= 0 or not DROP_NAME.match(str(name or "")) \
                or not re.fullmatch(r"[0-9a-f]{64}", str(sha or "")):
            self._send({"t": "drop.result", "id": drop_id, "ok": False, "code": "bad_request",
                        "message": "drop.start needs id, name, size, sha256"})
            return
        if not isinstance(size, int) or size <= 0 or size > DROP_MAX_BYTES:
            self._send({"t": "drop.result", "id": drop_id, "ok": False, "code": "too_large",
                        "message": "size must be 1..%d bytes" % DROP_MAX_BYTES})
            return
        if int(msg.get("resume") or 0) > 0:
            # The fake keeps no temp between drops, so it answers like a phone
            # with an empty Downloads/PocketDeck: the Mac starts over at zero.
            sys.stderr.write("fakephone: drop %r resume %r ignored (no temp)\n"
                             % (drop_id, msg["resume"]))
        self._drop = {"id": drop_id, "name": name, "mime": msg.get("mime") or "application/octet-stream",
                      "size": size, "sha": sha, "data": bytearray(), "last": 0.0,
                      "last_progress": 0}
        self.phone._finished_drops.clear()
        self._send({"t": "drop.progress", "id": drop_id, "bytes": 0})

    def _finished(self, drop, code):
        """Remembers [drop] so a tail re-sent after its result is not ignored."""
        self.phone._finished_drops[drop["id"]] = {"name": drop["name"], "size": drop["size"],
                                                  "extra": 0, "reported": False, "code": code}

    def _on_drop_data(self, drop_id, payload):
        drop = getattr(self, "_drop", None)
        if not drop or drop["id"] != drop_id:
            done = self.phone._finished_drops.get(drop_id)
            if done:
                done["extra"] += len(payload)
                if not done["reported"]:
                    done["reported"] = True
                    sys.stderr.write("fakephone: drop %r more bytes than announced "
                                     "(%d > %d)\n" % (drop_id, done["size"] + done["extra"], done["size"]))
                    sys.stderr.flush()
                    self.phone.events.drop(drop_id, [{"name": done["name"],
                                                      "size": done["size"] + done["extra"]}],
                                           False, "too_many_bytes")
            return
        drop["data"] += payload
        got = len(drop["data"])
        if got > drop["size"]:
            # The real receiver's rule: every byte must fit the announcement.
            self._drop = None
            self._finished(drop, "too_many_bytes")
            sys.stderr.write("fakephone: drop %r more bytes than announced (%d > %d)\n"
                             % (drop_id, got, drop["size"]))
            sys.stderr.flush()
            self.phone.events.drop(drop_id, [{"name": drop["name"], "size": got}],
                                   False, "too_many_bytes")
            self._send({"t": "drop.result", "id": drop_id, "ok": False, "code": "too_many_bytes",
                        "message": "more bytes than announced"})
            return
        if DROP_FAKE_DOWNSIZE in payload:
            self._drop = None
            self._finished(drop, "too_large")
            sys.stderr.write("fakephone: drop %r tripped PD_FAKE_DOWNSIZE\n" % drop_id)
            self.phone.events.drop(drop_id, [{"name": drop["name"], "size": got}], False, "too_large")
            self._send({"t": "drop.result", "id": drop_id, "ok": False, "code": "too_large",
                        "message": "the file is bigger than the phone's cap"})
            return
        now = time.time()
        if got < drop["size"] and now - drop["last"] >= 0.25:
            drop["last"] = now
            drop["last_progress"] = got
            self._send({"t": "drop.progress", "id": drop_id, "bytes": got})
        if got < drop["size"]:
            return
        if self.phone.args.drop_ack_delay > 0:
            # The confirmation for the tail lands late: the Mac's reader is at
            # EOF by then, and the stale offset must not move it back.
            self._send({"t": "drop.progress", "id": drop_id, "bytes": drop["last_progress"]})
            time.sleep(self.phone.args.drop_ack_delay)
        self._drop = None
        data, sha = bytes(drop["data"]), drop["sha"]
        digest = hashlib.sha256(data).hexdigest()
        ok = digest == sha
        self._finished(drop, "ok" if ok else "checksum")
        sys.stderr.write("fakephone: drop %r %d bytes (%s) -> %s\n"
                         % (drop_id, len(data), drop["name"], "sha ok" if ok else "checksum"))
        if ok:
            fake_path = "/sdcard/Download/PocketDeck/%s" % drop["name"]
            self.phone.events.drop(drop_id, [{"name": drop["name"], "size": len(data),
                                              "mime": drop["mime"], "sha256": digest,
                                              "match": True}], True, None)
            self._send({"t": "drop.result", "id": drop_id, "ok": True, "path": fake_path})
        else:
            self.phone.events.drop(drop_id, [{"name": drop["name"], "size": len(data),
                                              "sha256": digest, "match": False,
                                              "want": sha}], False, "checksum")
            self._send({"t": "drop.result", "id": drop_id, "ok": False, "code": "checksum",
                        "message": "the file arrived damaged"})

    def _on_drop_cancel(self, msg):
        drop = getattr(self, "_drop", None)
        if drop and drop["id"] == msg.get("id"):
            self._drop = None
            self._finished(drop, "cancelled")
            self.phone.events.drop(drop["id"], [{"name": drop["name"],
                                                 "size": len(drop["data"])}], False, "cancelled")
            self._send({"t": "drop.result", "id": drop["id"], "ok": False, "code": "cancelled",
                        "message": "cancelled"})

    # -- read-only phone files (docs/PROTOCOL.md "Phone files") --
    def _fs_error(self, read_id, error):
        self.phone.events.fs("error", id=read_id, code=error.code)
        self._send({"t": "error", "code": error.code, "message": error.message, "id": read_id})

    def _on_fs_list(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_error(read_id, FsError("fs_denied", "files are not served"))
        try:
            page = fs.list(msg.get("path"), msg.get("page"))
        except FsError as exc:
            return self._fs_error(read_id, exc)
        self._send({"t": "fs.items", "id": read_id, "page": page["page"], "items": page["items"]})
        self.phone.events.fs("list", id=read_id, items=len(page["items"]),
                             more=page["page"] is not None)

    def _on_fs_stat(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_error(read_id, FsError("fs_denied", "files are not served"))
        try:
            item = fs.stat(msg.get("path"))
        except FsError as exc:
            return self._fs_error(read_id, exc)
        self._send({"t": "fs.item", "id": read_id, "item": item})
        self.phone.events.fs("stat", id=read_id, dir=item["dir"], size=item["size"])

    def _on_fs_read(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_error(read_id, FsError("fs_denied", "files are not served"))
        try:
            path = fs.read_plan(msg.get("path"), msg.get("offset"), msg.get("length"),
                                msg.get("etag"))
        except FsError as exc:
            return self._fs_error(read_id, exc)
        job = {"cancel": threading.Event()}
        with self._fs_lock:
            if len(self._fs_jobs) >= 8 or read_id in self._fs_jobs:
                busy = True
            else:
                self._fs_jobs[read_id] = job
                busy = False
        if busy:
            return self._fs_error(read_id, FsError("fs_busy", "too many reads"))
        self.phone.events.fs("read", id=read_id, bytes=msg.get("length"))
        thread = threading.Thread(target=self._run_fs_read,
                                  args=(read_id, path, msg.get("offset"), msg.get("length"), job),
                                  daemon=True)
        job["thread"] = thread
        thread.start()

    def _run_fs_read(self, read_id, path, offset, length, job):
        digest = hashlib.sha256()
        done = 0
        try:
            with open(path, "rb") as handle:
                handle.seek(offset)
                while done < length:
                    if job["cancel"].is_set():
                        self.phone.events.fs("xfer", id=read_id, bytes=done, cancelled=True)
                        return
                    data = handle.read(min(FS_CHUNK, length - done))
                    if not data:
                        raise FsError("fs_stale", "the file shrank")
                    digest.update(data)
                    if not self.sender.send_bulk(read_id,
                                                 proto.pack_frame(proto.TYPE_FS_DATA, read_id, data)):
                        return
                    done += len(data)
                    if self.phone.args.fs_chunk_delay_ms > 0:
                        # A slow reader (e2e cancel): the cancel arrives mid-file.
                        time.sleep(self.phone.args.fs_chunk_delay_ms / 1000.0)
            end = {"t": "fs.read.end", "id": read_id, "size": done,
                   "sha256": digest.hexdigest()}
            self.sender.send_bulk(0, proto.pack_json(end))
            self.phone.events.fs("end", id=read_id, bytes=done)
            sys.stderr.write("fakephone: fs read id=%d %d bytes\n" % (read_id, done))
            sys.stderr.flush()
        except FsError as exc:
            self._fs_error(read_id, exc)
        except Exception as exc:  # a read that dies is a failed request, not a session
            sys.stderr.write("fakephone: fs read id=%d failed: %s\n"
                             % (read_id, type(exc).__name__))
            sys.stderr.flush()
            self._fs_error(read_id, FsError("fs_denied", "the file could not be read"))
        finally:
            with self._fs_lock:
                self._fs_jobs.pop(read_id, None)

    def _on_fs_cancel(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        write = self._fs_write
        if write is not None and write["id"] == read_id:
            # A cancelled write leaves nothing: the temp goes, no reply follows.
            self._fail_write(write, "cancelled", "cancelled", silent=True)
            self.phone.events.fs("cancel", id=read_id, kind="write")
            return
        with self._fs_lock:
            job = self._fs_jobs.get(read_id)
        if job is None:
            return
        job["cancel"].set()
        # The marker first: every FS_DATA line logged after it is a frame the
        # cancel was too late for (at most the one already on the wire).
        sys.stderr.write("fakephone: fs cancel id=%d\n" % read_id)
        sys.stderr.flush()
        if self.sender:
            self.sender.cancel_bulk(read_id)
        self.phone.events.fs("cancel", id=read_id)

    # -- fs.* writes: temp + verify + etag + rename, like the phone ---------
    def _fs_result(self, read_id, item=None, code=None, message=""):
        if code:
            sys.stderr.write("fakephone: fs id=%d %s\n" % (read_id, code))
            sys.stderr.flush()
            self._send({"t": "fs.result", "id": read_id, "ok": False,
                        "code": code, "message": message or code})
        else:
            reply = {"t": "fs.result", "id": read_id, "ok": True}
            if item is not None:
                reply["item"] = item
                reply["etag"] = item.get("etag")
            self._send(reply)

    def _on_fs_write(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_result(read_id, code="fs_denied", message="files are not served")
        if self._fs_write is not None:
            return self._fs_result(read_id, code="fs_busy", message="another write is running")
        size, sha, etag = msg.get("size"), msg.get("sha256"), msg.get("etag")
        exclusive = msg.get("exclusive") is True
        try:
            target, temp = fs.write_plan(msg.get("path"), size, sha, etag, exclusive)
        except FsError as exc:
            self.phone.events.fs("write", id=read_id, ok=False, code=exc.code)
            return self._fs_result(read_id, code=exc.code, message=exc.message)
        try:
            handle = open(temp, "xb")
        except OSError:
            return self._fs_result(read_id, code="fs_denied", message="could not stage the file")
        self._fs_write = {"id": read_id, "target": target, "temp": temp, "size": size,
                          "sha256": sha, "etag": etag, "exclusive": exclusive,
                          "received": 0,
                          "handle": handle, "digest": hashlib.sha256(),
                          "last": time.time() - 1.0}
        self.phone.events.fs("write.start", id=read_id, size=size)

    def _on_fs_data(self, write_id, payload):
        job = self._fs_write
        if job is None or job["id"] != write_id or not payload:
            return
        if job["received"] + len(payload) > job["size"]:
            self._fail_write(job, "fs_denied", "more bytes than announced")
            return
        try:
            job["handle"].write(payload)
        except OSError:
            self._fail_write(job, "fs_denied", "the write failed")
            return
        job["digest"].update(payload)
        job["received"] += len(payload)
        if self.phone.args.fs_write_delay_ms > 0:
            time.sleep(self.phone.args.fs_write_delay_ms / 1000.0)
        now = time.time()
        if job["received"] == job["size"]:
            self._finish_write(job)
        elif now - job["last"] >= 0.25:
            job["last"] = now
            self._send({"t": "fs.progress", "id": job["id"], "bytes": job["received"]})

    def _finish_write(self, job):
        self._fs_write = None
        try:
            job["handle"].flush()
            os.fsync(job["handle"].fileno())
            job["handle"].close()
        except OSError:
            pass
        self._send({"t": "fs.progress", "id": job["id"], "bytes": job["size"]})
        fs = self.phone.fs
        try:
            item = fs.finish_write(job["target"], job["temp"], job["size"],
                                   job["sha256"], job["etag"], job["exclusive"])
        except FsError as exc:
            self.phone.events.fs("write", id=job["id"], size=job["size"], ok=False,
                                 code=exc.code)
            return self._fs_result(job["id"], code=exc.code, message=exc.message)
        except OSError:
            return self._fs_result(job["id"], code="fs_denied", message="the write failed")
        self.phone.events.fs("write", id=job["id"], size=job["size"], ok=True,
                             name=os.path.basename(job["target"]))
        self._fs_result(job["id"], item=item)

    def _fail_write(self, job, code, message, silent=False):
        if self._fs_write is job:
            self._fs_write = None
        try:
            job["handle"].close()
        except OSError:
            pass
        try:
            os.unlink(job["temp"])
        except OSError:
            pass
        self.phone.events.fs("write", id=job["id"], size=job["received"], ok=False, code=code)
        if not silent:
            self._fs_result(job["id"], code=code, message=message)

    def _on_fs_move(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_result(read_id, code="fs_denied", message="files are not served")
        try:
            item = fs.move(msg.get("from"), msg.get("to"), msg.get("etag"))
        except FsError as exc:
            self.phone.events.fs("move", id=read_id, ok=False, code=exc.code)
            return self._fs_result(read_id, code=exc.code, message=exc.message)
        except OSError:
            return self._fs_result(read_id, code="fs_denied", message="the move failed")
        self.phone.events.fs("move", id=read_id, ok=True, **{
            "from": msg.get("from"), "to": msg.get("to")})
        self._fs_result(read_id, item=item)

    def _on_fs_delete(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_result(read_id, code="fs_denied", message="files are not served")
        recursive = bool(msg.get("recursive"))
        try:
            meta = fs.delete(msg.get("path"), recursive, msg.get("etag"))
        except FsError as exc:
            self.phone.events.fs("delete", id=read_id, ok=False, code=exc.code)
            return self._fs_result(read_id, code=exc.code, message=exc.message)
        except OSError:
            return self._fs_result(read_id, code="fs_denied", message="the delete failed")
        self.phone.events.fs("delete", id=read_id, ok=True, dir=bool(meta["dir"]),
                             recursive=recursive, path=msg.get("path"))
        self._fs_result(read_id)

    def _on_fs_mkdir(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_result(read_id, code="fs_denied", message="files are not served")
        try:
            item = fs.mkdir(msg.get("path"))
        except FsError as exc:
            self.phone.events.fs("mkdir", id=read_id, ok=False, code=exc.code)
            return self._fs_result(read_id, code=exc.code, message=exc.message)
        except OSError:
            return self._fs_result(read_id, code="fs_denied", message="could not create the folder")
        self.phone.events.fs("mkdir", id=read_id, ok=True, path=msg.get("path"))
        self._fs_result(read_id, item=item)

    def _on_fs_watch(self, msg):
        self._fs_watch(msg, on=True)

    def _on_fs_unwatch(self, msg):
        self._fs_watch(msg, on=False)

    def _fs_watch(self, msg, on):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        if self._watcher is None:
            return self._fs_result(read_id, code="fs_denied", message="files are not served")
        paths = msg.get("paths")
        if not isinstance(paths, list) or not all(isinstance(p, str) for p in paths):
            return self._fs_result(read_id, code="fs_denied", message="bad paths")
        try:
            count = self._watcher.watch(paths) if on else self._watcher.unwatch(paths)
        except FsError as exc:
            return self._fs_result(read_id, code=exc.code, message=exc.message)
        except OSError:
            return self._fs_result(read_id, code="fs_denied", message="the watch failed")
        sys.stderr.write("fakephone: watch %s %d\n" % ("on" if on else "off", count))
        sys.stderr.flush()
        self.phone.events.fs("watch", on=on, count=count)
        self._fs_result(read_id)

    def _on_fs_changes(self, paths):
        """One coalesced `fs.changes` for the folders whose contents moved."""
        self.phone.events.fs("changes", count=len(paths))
        try:
            self._send({"t": "fs.changes", "paths": paths})
        except Exception:
            pass

    def _on_fs_set_attrs(self, msg):
        read_id = _fs_id(msg)
        if read_id is None:
            return
        fs = self.phone.fs
        if fs is None:
            return self._fs_result(read_id, code="fs_denied", message="files are not served")
        try:
            item = fs.set_attrs(msg.get("path"), msg.get("mtime"))
        except FsError as exc:
            self.phone.events.fs("setattrs", id=read_id, ok=False, code=exc.code)
            return self._fs_result(read_id, code=exc.code, message=exc.message)
        except OSError:
            return self._fs_result(read_id, code="fs_denied", message="could not set the time")
        self.phone.events.fs("setattrs", id=read_id, ok=True)
        self._fs_result(read_id, item=item)

    def _cancel_fs_reads(self):
        if self._fs_write is not None:
            self._fail_write(self._fs_write, "closed", "the session ended", silent=True)
        with self._fs_lock:
            jobs = list(self._fs_jobs.items())
        for read_id, job in jobs:
            job["cancel"].set()
            if self.sender:
                self.sender.cancel_bulk(read_id)

    # -- clipboard images (docs/design/dragdrop.md): the fake receives like the
    # shell does (cap 8 MiB, one per direction) and logs the outcome.
    def _on_clip_image_start(self, msg):
        clip_id = msg.get("id")
        size = msg.get("size")
        if not isinstance(clip_id, int) or not isinstance(size, int) or size <= 0 \
                or size > (8 * 1024 * 1024) \
                or msg.get("mime") not in ("image/png", "image/jpeg"):
            sys.stderr.write("fakephone: clip.image.start refused (%r %r %r)\n"
                             % (clip_id, msg.get("mime"), size))
            self._clip = None
            return
        self._clip = {"id": clip_id, "mime": msg["mime"], "size": size, "data": bytearray()}

    def _on_clip_data(self, clip_id, payload):
        clip = getattr(self, "_clip", None)
        if not clip or clip["id"] != clip_id:
            return
        clip["data"] += payload
        if len(clip["data"]) >= clip["size"]:
            data = bytes(clip["data"])
            self._clip = None
            digest = hashlib.sha256(data).hexdigest()
            self.phone.events.clip_image("rx", "fake-%d.%s" % (clip_id, "png" if clip["mime"] == "image/png" else "jpg"),
                                         size=len(data), sha256=digest, mime=clip["mime"])
            sys.stderr.write("fakephone: clip image %r %d bytes -> %s\n" % (clip_id, len(data), digest))

    def _on_clip_image_end(self, msg):
        clip = getattr(self, "_clip", None)
        if clip and clip["id"] == msg.get("id"):
            # The tail arrived without enough chunks: drop it as the phone does.
            sys.stderr.write("fakephone: clip.image.end for %r with %d/%s bytes\n"
                             % (clip["id"], len(clip["data"]), clip["size"]))

    def _on_clip_image_abort(self, msg):
        clip = getattr(self, "_clip", None)
        if clip and clip["id"] == msg.get("id"):
            self._clip = None
            self.phone.events.clip_image("abort", "clip-%d" % clip["id"])

    def _on_clip_set(self, msg):
        self.phone.events.clip("rx", msg.get("text"))

    # -- notifications + media (docs/design/notify.md): the Mac's per-session
    # opt-in is what makes the phone post; the phone's own toggle gates it in the
    # app. On opting in the phone posts two notifications, takes one away again
    # and reports its playing session. Titles and texts never reach any log.
    def _on_notify_enable(self, msg):
        on = msg.get("on") is True
        self.phone.events.notify("enable", on=on)
        if not on:
            return
        only = getattr(self.phone.args, "notify_only", None)
        media = bool(getattr(self.phone.args, "notify_media", False))
        if only:
            # Any shape can be asked for by id, media ones included (the VM
            # check shows one picture banner at a time).
            posts = [p for p in NOTIFY_POSTS + NOTIFY_SHAPES + NOTIFY_MEDIA_POSTS
                     if p["id"] == only]
        else:
            posts = NOTIFY_POSTS + NOTIFY_SHAPES + (NOTIFY_MEDIA_POSTS if media else [])
        for post in posts:
            live = post.get("live")
            if isinstance(live, dict):
                live = self._live_wire(live)
            wire = dict(post, t="notify.post", when=int(time.time() * 1000))
            wire.pop("image", None)
            wire.pop("tick", None)
            wire.pop("removeAfter", None)
            if live is not None:
                wire["live"] = live
            self._send(wire)
            actions = post.get("actions", [])
            self.phone.events.notify("post", id=post["id"], pkg=post["pkg"],
                                     titleLen=len(post["title"]), bodyLen=len(post["text"]),
                                     actions=len(actions),
                                     reply=1 if any(a.get("reply") for a in actions) else 0,
                                     ongoing=1 if post.get("ongoing") or live is not None else 0,
                                     live=1 if live is not None else 0)
            if post.get("image"):
                self._send_notify_image(post["id"], post["image"])
            if post.get("tick"):
                self._start_live(post)
            if post.get("removeAfter"):
                self._remove_later(post["id"], post["removeAfter"])
        if not only:
            self._send({"t": "notify.remove", "id": NOTIFY_REMOVE})
            self.phone.events.notify("remove", id=NOTIFY_REMOVE)
        if self._media_mode():
            self._send_media()
        else:
            self._send(dict(NOTIFY_MEDIA_STATE, t="media.state"))
            self.phone.events.notify("media.state", playing=NOTIFY_MEDIA_STATE["playing"],
                                     titleLen=len(NOTIFY_MEDIA_STATE["title"]),
                                     durationMs=NOTIFY_MEDIA_STATE["durationMs"])

    def _media_mode(self):
        return bool(getattr(self.phone.args, "media", False))

    def _older_phone(self):
        return bool(getattr(self.phone.args, "older_phone", False))

    def _send_media(self):
        """The part 2 shapes in wire order: sessions, state, then the artwork
        once per change. `--older-phone` sends today's media.state only."""
        media = self.phone.media
        if self._older_phone():
            self._send(media.older_state())
            self.phone.events.notify("media.state", playing=True,
                                     titleLen=len(MEDIA_TITLE), durationMs=MEDIA_DURATION_MS)
            return
        self._send(media.sessions_message())
        self.phone.events.media("sessions", n=len(media.rows), chosen=media.chosen)
        self._send(media.state())
        self.phone.events.media("state", key=media.chosen, positionMs=media.position,
                                volume=media.volume, canSeek=1)
        self._send_media_art()

    def _send_media_art(self):
        media = self.phone.media
        if self._older_phone() or media.art_sent_for == media.chosen:
            return
        media.art_sent_for = media.chosen
        media.art_sends += 1
        self._send(media.art_message())
        self.phone.events.media("art", key=media.chosen, w=NOTIFY_IMAGE["w"],
                                h=NOTIFY_IMAGE["h"], size=len(NOTIFY_IMAGE["data"]),
                                sends=media.art_sends)

    def _remove_later(self, notify_id, delay):
        """The app took the picture notification away after a while."""
        def run():
            time.sleep(delay)
            if self.sender is None or self._live_stop.is_set():
                return
            self._send({"t": "notify.remove", "id": notify_id})
            self.phone.events.notify("remove", id=notify_id)

        threading.Thread(target=run, daemon=True).start()

    def _live_wire(self, live):
        """The live object with a chronometer's epoch filled in; no text logs."""
        out = dict(live)
        if out.get("chrono") == "future":
            out["chrono"] = int(time.time() * 1000) + 5 * 60 * 1000
        out.pop("tick", None)
        return out

    def _send_notify_image(self, notify_id, kind):
        """`notify.image` right after the post; bad means over the Mac's cap."""
        if kind == "bad":
            data = b"\\x00" * (NOTIFY_IMAGE_MAX + 1)
            mime, w, h = NOTIFY_IMAGE["mime"], NOTIFY_IMAGE["w"], NOTIFY_IMAGE["h"]
        else:
            data = NOTIFY_IMAGE["data"]
            mime, w, h = NOTIFY_IMAGE["mime"], NOTIFY_IMAGE["w"], NOTIFY_IMAGE["h"]
        self._send({"t": "notify.image", "id": notify_id, "mime": mime, "w": w, "h": h,
                    "data": base64.b64encode(data).decode("ascii")})
        self.phone.events.notify("image", id=notify_id, mime=mime, w=w, h=h, size=len(data),
                                 refused=1 if kind == "bad" else 0)

    def _start_live(self, post):
        """Advance a fake Live Update every 2 s, then end it (a ride's ETA)."""
        if self._live_thread is not None:
            return

        def run():
            progress = post["live"]["progress"]
            for tick in range(NOTIFY_LIVE_TICKS):
                time.sleep(NOTIFY_LIVE_INTERVAL)
                if self._live_stop.is_set() or self.sender is None:
                    return
                progress = min(0.98, progress + 0.15)
                self._post_live(post, progress, "3 min" if tick % 2 == 0 else "2 min")
            time.sleep(NOTIFY_LIVE_INTERVAL)
            if self._live_stop.is_set() or self.sender is None:
                return
            self._live_stop.set()
            self._send({"t": "notify.remove", "id": post["id"]})
            self.phone.events.notify("live.end", id=post["id"])

        self._live_thread = threading.Thread(target=run, daemon=True)
        self._live_thread.start()

    def _post_live(self, post, progress, chip=None):
        """One in-place update, coalesced to at most one per second per id."""
        live = {"progress": round(min(1.0, max(0.0, progress)), 3)}
        if chip:
            live["chip"] = chip
        live_id = post["id"]
        now = time.time()
        with self._live_lock:
            last = self._live_last.get(live_id)
            if last is not None and now - last < 1.0:
                self._live_pending[live_id] = (post, live)
                self._live_flusher_start()
                return
            self._live_last[live_id] = now
        self._send_live_now(post, live)

    def _live_flusher_start(self):
        if self._live_flusher is not None:
            return
        self._live_flusher = threading.Thread(target=self._live_flush_loop, daemon=True)
        self._live_flusher.start()

    def _live_flush_loop(self):
        while not self._live_stop.is_set():
            time.sleep(0.2)
            now = time.time()
            ready = []
            with self._live_lock:
                for live_id, (post, live) in list(self._live_pending.items()):
                    if now - self._live_last.get(live_id, 0) >= 1.0:
                        self._live_pending.pop(live_id, None)
                        self._live_last[live_id] = now
                        ready.append((post, live))
            for post, live in ready:
                try:
                    self._send_live_now(post, live)
                except Exception:
                    return

    def _send_live_now(self, post, live):
        message = {k: v for k, v in post.items()
                   if k not in ("image", "tick", "live", "removeAfter")}
        message.update({"t": "notify.post", "when": int(time.time() * 1000), "live": live})
        self._send(message)
        self.phone.events.notify(
            "live", id=post["id"], progress=int(round(live.get("progress", 0) * 100)),
            chipLen=len(live["chip"]) if live.get("chip") else 0, update=1)

    def _on_notify_action(self, msg):
        # A Mac pressed an advertised action: id, index and the reply's length.
        text = msg.get("text")
        self.phone.events.notify("action", id=msg.get("id"), i=msg.get("i"),
                                 textLen=len(text) if isinstance(text, str) else 0)

    def _on_notify_dismiss(self, msg):
        self.phone.events.notify("dismiss", id=msg.get("id"))

    def _on_notify_fake(self, msg):
        """Test-only hook (deckctl `notify image|live|end`): make the fake phone
        post a picture or advance/finish a Live Update. The real phone decides
        these itself; this is how the e2e drives one deterministically."""
        kind = msg.get("kind")
        notify_id = msg.get("id")
        post = next((p for p in NOTIFY_MEDIA_POSTS if p["id"] == notify_id), None)
        if post is None or kind not in ("image", "live", "end"):
            self._send_error("bad_request", "notify.fake needs a media shape id")
            return
        if kind == "image":
            wire = {k: v for k, v in post.items()
                    if k not in ("image", "tick", "live", "removeAfter")}
            wire.update({"t": "notify.post", "when": int(time.time() * 1000)})
            self._send(wire)
            self.phone.events.notify("post", id=post["id"], pkg=post["pkg"],
                                     titleLen=len(post["title"]), bodyLen=len(post["text"]),
                                     actions=0, reply=0, ongoing=0, live=0)
            self._send_notify_image(notify_id, "good")
        elif kind == "live":
            try:
                progress = float(msg.get("progress", 0.5))
            except (TypeError, ValueError):
                progress = 0.5
            self._post_live(post, progress, msg.get("chip"))
        else:
            self._send({"t": "notify.remove", "id": notify_id})
            self.phone.events.notify("live.end", id=notify_id)

    def _on_media_command(self, msg):
        """`media.command` from the Mac: log the action and its numbers, apply
        it, and answer with the next media.state (which confirms it)."""
        media = self.phone.media
        action = msg.get("action")
        key = msg.get("key")
        position = msg.get("positionMs")
        level = msg.get("level")
        self.phone.events.media("rx", action=action, key=key,
                                positionMs=position if isinstance(position, int) else -1,
                                level=level if isinstance(level, int) else -1)
        notes = ""
        if not self._media_mode():
            return
        if key and key != media.chosen:
            # A command for a session that is not the chosen one moves nothing.
            self.phone.events.media("rx", action=action, key=key, skipped=1)
            return
        if action == "seek" and isinstance(position, int):
            media.position = max(0, min(position, MEDIA_DURATION_MS))
        elif action == "volume" and isinstance(level, int):
            media.volume = max(0, min(level, MEDIA_MAX_VOLUME))
        elif action in ("play", "pause"):
            media.playing = action == "play"
            for row in media.rows:
                row["playing"] = action == "play" and row["key"] == media.chosen
        elif action in ("next", "prev"):
            notes = "-"
        if self.sender is not None:
            self._send(media.state())
            self.phone.events.media("state", key=media.chosen, positionMs=media.position,
                                    volume=media.volume, canSeek=1)

    def _on_media_choose(self, msg):
        """`media.choose`: the Mac picked a session. An unknown key changes
        nothing, as on the phone."""
        media = self.phone.media
        key = msg.get("key")
        known = any(row["key"] == key for row in media.rows)
        self.phone.events.media("choose", key=key, ok=1 if known else 0)
        if not known:
            return
        media.chosen = key
        media.art_sent_for = None
        if self.sender is None:
            return
        self._send(media.sessions_message())
        self._send(media.state())
        self._send_media_art()

    def _on_notify_open(self, msg):
        # A Mac banner click: the id and where it runs, never any text.
        self.phone.events.notify("open", id=msg.get("id"), target=msg.get("target"),
                                 stream=msg.get("stream"))

    def _on_apps_list(self, _msg):
        apps = sorted(APPS, key=lambda a: a["label"].lower())
        self._send({"t": "apps", "apps": apps})

    def _on_apps_icon(self, msg):
        pkg = msg.get("pkg", "")
        px = msg.get("px")
        if px is not None:
            try:
                px = int(px)
            except (TypeError, ValueError):
                px = None
        png = self.phone.icon_png(pkg, px)
        reply = {"t": "icon", "pkg": pkg, "png": base64.b64encode(png).decode("ascii")}
        layers = self.phone.icon_layers(pkg, px)
        self.phone.events.icon(pkg, len(png), layers is not None, self.phone.layer_size(px))
        if layers is not None:
            reply["fg"] = layers["fg"]
            reply["bg"] = layers["bg"]
        self._send(reply)

    def _stream_or_error(self, msg):
        stream_id = msg.get("stream")
        window = self.windows.get(stream_id)
        if window is None:
            self._send_error("no_stream", "unknown stream %r" % (stream_id,), stream_id)
        return window

    def _refuse(self, code, state):
        """Send a gate refusal and hold the socket until the Mac reads it and
        closes (the same write-then-close shape the real phone uses)."""
        self.phone.events.session(state)
        self._send_error(code, "the phone is not accepting %s" %
                         ("connections" if code == "connections_off" else "new pairings"))
        while True:
            try:
                if proto.recv_frame(self.sock) is None:
                    break
            except (proto.ProtocolError, OSError):
                break
        return False

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
        if mode == "phone" and self.phone.args.rotate_after > 0:
            threading.Thread(target=self._rotate_later, args=(window,), daemon=True).start()
        if mode == "phone" and self.phone.args.screen_off_after > 0:
            threading.Thread(target=self._screen_off_later, args=(window,), daemon=True).start()
        if mode == "phone" and self.phone.args.secure_after > 0:
            threading.Thread(target=self._secure_later, args=(window,), daemon=True).start()

    def _rotate_later(self, window):
        """The phone turns to landscape: the mirror turns with it (new VIDEO_CONFIG)."""
        time.sleep(self.phone.args.rotate_after)
        if self.windows.get(window.stream_id) is not window:
            return
        screen_w, screen_h = self.phone.screen
        self.phone.screen = (screen_h, screen_w)
        box = turn_box(window.w, window.h, *self.phone.screen)
        window.w, window.h = mirror_fit(*box + self.phone.screen)
        window.start()

    def _secure_later(self, window):
        """A secure surface covers display 0: state.secure true and black frames,
        then false and the normal picture again (docs/PROTOCOL.md "Secure screens")."""
        time.sleep(self.phone.args.secure_after)
        if self.windows.get(window.stream_id) is not window or self.phone.secure_state:
            return
        self.phone.secure_state = True
        self.send_state()
        window.black_for(5, lambda: self.windows.get(window.stream_id) is window)
        if self.windows.get(window.stream_id) is not window:
            return
        self.phone.secure_state = False
        self.send_state()

    def _screen_off_later(self, window):
        """The panel times out: `state.screen off` and no more mirror frames."""
        time.sleep(self.phone.args.screen_off_after)
        if self.windows.get(window.stream_id) is not window or self.phone.screen_state == "off":
            return
        self.phone.screen_state = "off"
        self.phone.events.screen("off")
        for other in self.windows.values():
            if other.mode == "phone":
                other.pause()
        self.send_state()

    # -- task.continue (docs/design/handoff.md): the Mac wants a window for the
    # app in the foreground on the phone. The default foreground is Settings;
    # --handoff-mode stages moved/fresh/nothing so every answer shape is testable.
    def _on_task_continue(self, msg):
        stream_id = msg.get("stream")
        if stream_id is None:
            self._send_error("bad_request", "task.continue needs stream")
            return
        mode = self.phone.args.handoff_mode
        pkg = self.phone.args.foreground_pkg
        if mode == "nothing" or pkg == "none":
            sys.stderr.write("fakephone: nothing continuable in the foreground\n")
            self.phone.events.task_continue(stream_id, mode, None)
            self._send_error("nothing_to_continue", "the phone's screen has nothing to continue",
                             stream_id)
            return
        if stream_id in self.windows:
            self._send_error("bad_request", "stream %r already open" % (stream_id,), stream_id)
            return
        started = "fresh" if mode == "fresh" else "moved"
        sys.stderr.write("fakephone: task.continue stream %r -> %s (%s)\n"
                         % (stream_id, pkg, mode))
        w = msg.get("w", SCREEN_W)
        h = msg.get("h", SCREEN_H)
        dpi = msg.get("dpi", SCREEN_DPI)
        window = WindowStream(self.phone, stream_id, w, h, dpi, "app", pkg=pkg)
        self.windows[stream_id] = window
        self.phone.events.task_continue(stream_id, mode, started)
        self._send({"t": "window.opened", "stream": stream_id, "displayId": window.display_id,
                    "w": window.w, "h": window.h, "started": started})
        window.start()
        # The real phone's title watcher reports the top app of every display;
        # the Mac titles the window ("Settings (FakePhone)") from it.
        self._send({"t": "window.title", "stream": stream_id,
                    "label": window.label, "pkg": pkg})

    def _on_window_resize(self, msg):
        window = self._stream_or_error(msg)
        if window is None:
            return
        delay = getattr(self.phone.args, "resize_delay_ms", 0)
        if delay > 0:
            # Hold the answer: the Mac keeps the old frame in the new window
            # shape until the timer restarts the encoder (the live-resize fill).
            # A newer resize replaces the held one.
            self.phone.events.resize_held(window.stream_id, delay)
            timer = getattr(window, "_resize_timer", None)
            if timer is not None:
                timer.cancel()
            timer = threading.Timer(delay / 1000.0, self._apply_window_resize, args=(window, msg))
            timer.daemon = True
            window._resize_timer = timer
            timer.start()
            return
        self._apply_window_resize(window, msg)

    def _apply_window_resize(self, window, msg):
        if window.stream_id not in self.windows:
            return
        if window.mode == "phone":
            box = turn_box(msg.get("w", window.w), msg.get("h", window.h), *self.phone.screen)
            window.w, window.h = mirror_fit(*box + self.phone.screen)
        else:
            window.w = round16(msg.get("w", window.w))
            window.h = round16(msg.get("h", window.h))
        window.dpi = msg.get("dpi", window.dpi)
        window.start()

    def _on_window_close(self, msg):
        window = self._stream_or_error(msg)
        if window is None:
            return
        if window._resize_timer is not None:
            window._resize_timer.cancel()
            window._resize_timer = None
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
        # The screen as it is turned now (the phone mirror follows it).
        self.screen = (SCREEN_W, SCREEN_H)
        # Display 0's power state (`state.screen`).
        self.screen_state = "on"
        # None until --secure-after puts a secure surface over display 0.
        self.secure_state = None
        tls_guard()
        self.store = Store(args.state)
        if args.qr_uri:
            scan_qr_uri(self.store, args.qr_uri)
        # One identity per state file's directory, so restarts keep serving the
        # same cert the Mac pins; `--tls-identity` overrides (the rotated-cert
        # case points at a different dir).
        self.tls_identity_dir = args.tls_identity or (args.state + ".identity")
        self.fp_hex = None
        if not args.no_tls:
            self.fp_hex = make_identity(self.tls_identity_dir)
        self.events = EventLog(args.events)
        # A zero line first: a check that reads before anything happened still
        # sees both counters.
        self.events.emit_counters()
        # DND (docs/design/focus.md): --dnd-unsupported acts like an old build
        # (no state.dnd, phone.dnd is an unknown message); --dnd-person starts
        # in a mode the person set, which the restore rule must leave alone.
        self.zen = FakeZen(person=args.dnd_person, supported=not args.dnd_unsupported)
        # Now Playing (v0.2 #9): the two fake sessions, their position and volume.
        self.media = FakeMedia()
        self.fake_ringer = FakeRinger(supported=not args.ringer_unsupported)
        # The fake /sdcard (docs/design/files.md §6): the e2e check builds a
        # tree here and the fs.* handlers serve it with the phone's rules.
        self.fs = FsFake(args.fs_root) if args.fs_root else None
        self.sender = None            # active session's sender
        self._session = None
        self._busy = threading.Event()
        self._stop = threading.Event()
        self._srv = None
        self._icon_cache = {}
        self._layers_cache = {}
        self._icon_lock = threading.Lock()
        self._display_seq = 100
        self._display_lock = threading.Lock()
        self._mdns = None
        self.label_dir = tempfile.mkdtemp(prefix="fakephone-") if args.labels else None
        # Drops that finished, so bytes arriving after the result (a re-sent
        # tail) are reported like the real receiver's "more bytes than announced".
        self._finished_drops = {}

    def accept_tls(self, raw):
        """One TLS 1.3 handshake per connection (the SSLContext is per
        connection, so the captured client cert only ever belongs to it)."""
        cert_path, key_path = identity_paths(self.tls_identity_dir)
        return proto.tls_server_session(cert_path, key_path, raw)

    def next_display_id(self):
        with self._display_lock:
            self._display_seq += 1
            return self._display_seq

    # The sizes the Mac may ask for (`apps.icon`'s optional px): the phone
    # clamps to what a launcher draws, exactly like the real one.
    @staticmethod
    def layer_size(px):
        if px is None:
            return 216
        return max(216, min(1296, int(px)))

    def flat_size(self, px):
        return 96 if px is None else self.layer_size(px) * 2 // 3

    def icon_png(self, pkg, px=None):
        if pkg in NO_ICON_PKGS:
            return b""
        size = self.flat_size(px)
        key = (pkg, size)
        with self._icon_lock:
            cached = self._icon_cache.get(key)
            if cached is not None:
                return cached
        png = render_text_png(self._icon_letter(pkg) or "?", size, size, (255, 255, 255), pkg_color(pkg))
        with self._icon_lock:
            self._icon_cache[key] = png
        return png

    def icon_layers(self, pkg, px=None):
        """fg/bg of the adaptive icons (base64), like the real phone's `icon`
        message fields, rendered at the asked size; None for a flat icon or one
        without an icon at all. The pattern is a white bg layer and a blue disc
        fg layer, so a rendered icon's centre colour says which one is on top."""
        if pkg in NO_ICON_PKGS or not is_adaptive_pkg(pkg):
            return None
        size = self.layer_size(px)
        key = (pkg, size)
        with self._icon_lock:
            cached = self._layers_cache.get(key)
        if cached is not None:
            return cached
        fg = render_disc_png(size, (51, 144, 236, 255))
        bg = _png(size, size, [bytearray(b"\xff\xff\xff" * size) for _ in range(size)])
        layers = {"fg": base64.b64encode(fg).decode("ascii"),
                  "bg": base64.b64encode(bg).decode("ascii"),
                  "px": size}
        with self._icon_lock:
            self._layers_cache[key] = layers
        return layers

    def _icon_letter(self, pkg):
        for app in APPS:
            if app["pkg"] == pkg:
                return app["label"][:1]
        return (pkg.rsplit(".", 1)[-1] or "?")[:1]

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
            if not self.args.no_tls:
                try:
                    conn = self.accept_tls(conn)
                except Exception as exc:
                    dbg("busy tls wrap failed: %s: %s" % (type(exc).__name__, exc))
                    try:
                        conn.close()
                    except OSError:
                        pass
                    return
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
    p.add_argument("--refuse-connections", action="store_true",
                   help="refuse every Mac at the handshake (the phone's Allow connections switch is off)")
    p.add_argument("--refuse-pairings", action="store_true",
                   help="refuse unknown Macs at the handshake (the phone's Allow new pairings switch is off)")
    p.add_argument("--auto-allow", action="store_true",
                   help="accept pairing requests without the terminal y/n prompt")
    p.add_argument("--allow-delay", type=float, default=0.0, metavar="SECONDS",
                   help="with --auto-allow, wait this long before tapping Allow (a person comparing codes)")
    p.add_argument("--state", default=DEFAULT_STATE, metavar="PATH",
                   help="paired-client state file (default: %(default)s)")
    p.add_argument("--events", metavar="PATH", help="write JSON Lines session events here")
    p.add_argument("--no-labels", dest="labels", action="store_false",
                   help="do not overlay the stream id/size label")
    p.add_argument("--text-frame", metavar="WORD", default=None,
                   help="draw WORD large on a white band in every app stream "
                        "(a stable frame for the Live Text check)")
    p.add_argument("--frame-events", action="store_true",
                   help="log each stream's cumulative frame count once a second")
    p.add_argument("--demo-apps", type=int, default=0, metavar="N",
                   help="pad the app list to N apps (grid screenshots)")
    p.add_argument("--no-icon-every", type=int, default=0, metavar="K",
                   help="with --demo-apps, every K-th app has no icon")
    p.add_argument("--screen-off-after", type=float, default=0.0, metavar="SECONDS",
                   help="after the phone window opens, the panel times out: send state.screen off and stop frames")
    p.add_argument("--secure-after", type=float, default=0.0, metavar="SECONDS",
                   help="after the phone window opens, a secure surface covers display 0: "
                        "send state.secure true and solid black frames for 5 s, then false "
                        "and the normal frames")
    p.add_argument("--stall-after", type=float, default=0.0, metavar="SECONDS",
                   help="after a stream's first frame, stop sending frames but keep the session up (a hung phone)")
    p.add_argument("--rotate-after", type=float, default=0.0, metavar="SECONDS",
                   help="turn the screen to landscape this long after a phone window opens")
    p.add_argument("--qr-uri", metavar="URI",
                   help="simulate the v2 QR scan (R2): stage a pocketdeck://pair "
                        "c/n/f/s URI; a Mac whose TLS fingerprint matches f gets "
                        "the pair.qr proof, then the Allow gate still applies")
    p.add_argument("--no-tls", action="store_true",
                   help="serve plaintext (the e2e plaintext refusal case: the "
                        "Mac must refuse to speak and never pair)")
    p.add_argument("--legacy-phone", action="store_true",
                   help="behave like a v1 phone (challenge after hello): the "
                        "v2 Mac surfaces the version mismatch and hangs up")
    p.add_argument("--dnd-person", choices=sorted(ZEN_MODES), metavar="MODE",
                   help="the phone starts in that Do Not Disturb mode, set by the "
                        "person (the restore rule must leave it alone)")
    p.add_argument("--dnd-unsupported", action="store_true",
                   help="act like a build without Focus support: state carries no "
                        "dnd and phone.dnd is an unknown message")
    p.add_argument("--ringer-unsupported", action="store_true",
                   help="act like a build without ringer support: state carries no "
                        "ringer and phone.ringer is an unknown message")
    p.add_argument("--tls-identity", metavar="DIR", default=None,
                   help="TLS identity dir (cert.pem/key.pem; generated once); "
                        "default is next to --state, so restarts keep the pin. "
                        "A different dir is a rotated server certificate")
    p.add_argument("--clip-on-welcome", metavar="TEXT", default=None,
                   help="send TEXT as clip.set right after welcome (the phone's clipboard)")
    p.add_argument("--share", metavar="KIND:VALUE", action="append", default=[],
                   help="after welcome, share with the Mac like Share -> Send to Mac: "
                        "text:<text or URL> or image:<path to .png/.jpg>; repeatable, sent in order")
    p.add_argument("--share-delay", type=float, default=2.0, metavar="SECONDS",
                   help="wait this long after welcome before the first --share")
    p.add_argument("--handoff-mode", choices=["moved", "fresh", "nothing"], default="moved",
                   help="what task.continue answers: the foreground app moved to the new "
                        "display, relaunched fresh (the move was refused) or nothing "
                        "continuable in the foreground")
    p.add_argument("--foreground-pkg", default="com.android.settings", metavar="PKG",
                   help="the package task.continue reports as the foreground app "
                        "('none' means nothing continuable)")
    p.add_argument("--fs-root", default=os.environ.get("PD_FAKE_FS_ROOT"),
                   metavar="DIR",
                   help="serve read-only phone files from DIR (default: PD_FAKE_FS_ROOT, "
                        "else fs.* is refused)")
    p.add_argument("--fs-chunk-delay-ms", type=int, default=0, metavar="MS",
                   help="pause after each FS_DATA chunk (a slow phone, so a cancel "
                        "can land mid-file in the e2e check)")
    p.add_argument("--fs-write-delay-ms", type=int, default=0, metavar="MS",
                   help="pause after each incoming FS_DATA chunk of a write (a slow "
                        "phone, so the e2e check can kill it mid-write)")
    p.add_argument("--drop-ack-delay", type=float, default=0.0, metavar="SECONDS",
                   help="repeat the last drop.progress and hold the result this long, "
                        "so the phone's confirmation for the tail lands after the Mac "
                        "has sent everything (a slow phone)")
    p.add_argument("--notify-only", default=None, metavar="ID",
                   help="on notify.enable post only this shape (pd-a1 reply, pd-a2 "
                        "buttons, pd-a3 ongoing, pd-a4 code, pd-m1 picture, pd-m2 "
                        "refused picture, pd-l1/pd-l2 Live Updates, pd-n1/n2 plain); "
                        "the VM check needs one banner at a time")
    p.add_argument("--media", action="store_true",
                   help="serve 'Media part 2' (v0.2 #9): two sessions, artwork, a "
                        "seekable position and an absolute volume; media.choose picks")
    p.add_argument("--older-phone", action="store_true",
                   help="pretend a phone that predates 'Media part 2': only today's "
                        "media.state, no media.sessions, no artwork, no canSeek/volume")
    p.add_argument("--notify-media", action="store_true",
                   help="on notify.enable also post the picture and Live Update shapes "
                        "(pd-m1, pd-m2, pd-l1, pd-l2) and advance pd-l1 every 2 s")
    p.add_argument("--resize-delay-ms", type=int, default=0, metavar="MS",
                   help="hold back a window's new VIDEO_CONFIG this long after "
                        "window.resize (the Mac's live-resize fill); 0 answers at once")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    add_demo_apps(args.demo_apps, args.no_icon_every)
    phone = FakePhone(args)
    if phone.fp_hex:
        print("fakephone identity fp: %s" % phone.fp_hex, file=sys.stderr)
        sys.stderr.flush()

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
