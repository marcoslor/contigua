"""PocketDeck wire-protocol codec (v1).

Mirrors docs/PROTOCOL.md. Everything here is transport-agnostic: it only turns
messages into bytes and back. Big-endian everywhere; f32 = IEEE-754 single BE.

Frame layout:
    u32 len      # bytes that follow (type + stream + payload)
    u8  type
    u32 stream   # 0 = session level, otherwise a window stream id
    u8[len-5] payload
"""

import hashlib
import hmac
import json
import os
import socket
import struct
import time

# --- frame types -----------------------------------------------------------
TYPE_JSON = 0x01
TYPE_VIDEO_CONFIG = 0x02
TYPE_VIDEO_FRAME = 0x03
TYPE_TOUCH = 0x10
TYPE_SCROLL = 0x11
TYPE_KEY = 0x12
TYPE_APK_DATA = 0x20

TYPE_NAMES = {
    TYPE_JSON: "JSON",
    TYPE_VIDEO_CONFIG: "VIDEO_CONFIG",
    TYPE_VIDEO_FRAME: "VIDEO_FRAME",
    TYPE_TOUCH: "TOUCH",
    TYPE_SCROLL: "SCROLL",
    TYPE_KEY: "KEY",
    TYPE_APK_DATA: "APK_DATA",
}

HEADER = 5                 # type (1) + stream (4)
MAX_FRAME = 8 * 1024 * 1024  # PROTOCOL.md: a larger len closes the session

CODEC_H264 = 1

TOUCH_DOWN, TOUCH_UP, TOUCH_MOVE, TOUCH_CANCEL = 0, 1, 2, 3
KEY_DOWN, KEY_UP = 0, 1

# Android keycodes used by the harness.
KEYCODE_BACK = 4
KEYCODE_HOME = 3
KEYCODE_APP_SWITCH = 187


class ProtocolError(Exception):
    """Raised on a frame/stream that violates PROTOCOL.md."""


class Frame(object):
    __slots__ = ("type", "stream", "payload")

    def __init__(self, type_, stream, payload):
        self.type = type_
        self.stream = stream
        self.payload = payload

    @property
    def name(self):
        return TYPE_NAMES.get(self.type, "0x%02x" % self.type)

    def __repr__(self):
        return "Frame(%s, stream=%d, %d bytes)" % (self.name, self.stream, len(self.payload))


# --- f32 helpers -----------------------------------------------------------
def pack_f32(x):
    return struct.pack(">f", x)


def unpack_f32(buf, offset=0):
    return struct.unpack_from(">f", buf, offset)[0]


# --- generic framing -------------------------------------------------------
def pack_frame(type_, stream, payload=b""):
    total = HEADER + len(payload)
    if total > MAX_FRAME:
        raise ProtocolError("frame of %d bytes exceeds %d" % (total, MAX_FRAME))
    return struct.pack(">IBI", total, type_, stream) + payload


def unpack_frame(data):
    if len(data) < 9:
        raise ProtocolError("short frame of %d bytes" % len(data))
    total, type_, stream = struct.unpack_from(">IBI", data, 0)
    if total + 4 != len(data):
        raise ProtocolError("len %d does not match %d bytes" % (total, len(data) - 4))
    return Frame(type_, stream, data[9:])


def recv_exact(sock, n):
    """Read exactly n bytes. Returns None on clean EOF before any byte."""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            if not buf:
                return None
            raise ProtocolError("connection closed with %d/%d bytes" % (len(buf), n))
        buf += chunk
    return bytes(buf)


def recv_frame(sock):
    """Read one frame. Returns None on clean EOF at a frame boundary."""
    header = recv_exact(sock, 4)
    if header is None:
        return None
    total = struct.unpack(">I", header)[0]
    if total < HEADER or total > MAX_FRAME:
        raise ProtocolError("bad frame length %d" % total)
    rest = recv_exact(sock, total)
    if rest is None:
        raise ProtocolError("connection closed mid-frame")
    type_, stream = struct.unpack_from(">BI", rest, 0)
    return Frame(type_, stream, rest[5:])


class FrameReader(object):
    """Incremental frame reader for sockets that are read with a timeout.

    A timed read can split a frame, and `recv_exact` forgets the partial bytes,
    so the next read mistakes a frame's tail for a length header. This reader
    keeps them until the frame is complete, and reports a timeout only when no
    complete frame arrived.
    """

    def __init__(self):
        self._buf = bytearray()

    def read(self, sock, timeout=None):
        """Return the next Frame, None on clean EOF, or raise socket.timeout."""
        deadline = None if timeout is None else time.time() + timeout
        while True:
            frame = self._try()
            if frame is not None:
                return frame
            if deadline is not None:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise socket.timeout("frame not complete")
                sock.settimeout(remaining)
            chunk = sock.recv(65536)
            if not chunk:
                if not self._buf:
                    return None
                raise ProtocolError("connection closed mid-frame")
            self._buf += chunk

    def _try(self):
        if len(self._buf) < 4:
            return None
        total = struct.unpack(">I", bytes(self._buf[:4]))[0]
        if total < HEADER or total > MAX_FRAME:
            raise ProtocolError("bad frame length %d" % total)
        if len(self._buf) < 4 + total:
            return None
        rest = bytes(self._buf[4:4 + total])
        del self._buf[:4 + total]
        type_, stream = struct.unpack_from(">BI", rest, 0)
        return Frame(type_, stream, rest[5:])


# --- JSON ------------------------------------------------------------------
def pack_json(obj, stream=0):
    return pack_frame(TYPE_JSON, stream, json.dumps(obj, separators=(",", ":")).encode("utf-8"))


def unpack_json(frame):
    if frame.type != TYPE_JSON:
        raise ProtocolError("expected JSON frame, got %s" % frame.name)
    return json.loads(frame.payload.decode("utf-8"))


# --- VIDEO_CONFIG ----------------------------------------------------------
def pack_video_config(stream, codec, width, height, sps_pps):
    payload = struct.pack(">BHH", codec, width, height) + sps_pps
    return pack_frame(TYPE_VIDEO_CONFIG, stream, payload)


def unpack_video_config(frame):
    if frame.type != TYPE_VIDEO_CONFIG:
        raise ProtocolError("expected VIDEO_CONFIG, got %s" % frame.name)
    if len(frame.payload) < 5:
        raise ProtocolError("VIDEO_CONFIG payload too short")
    codec, width, height = struct.unpack_from(">BHH", frame.payload, 0)
    return codec, width, height, frame.payload[5:]


# --- VIDEO_FRAME -----------------------------------------------------------
def pack_video_frame(stream, pts_us, flags, access_unit):
    payload = struct.pack(">QB", pts_us, flags) + access_unit
    return pack_frame(TYPE_VIDEO_FRAME, stream, payload)


def unpack_video_frame(frame):
    if frame.type != TYPE_VIDEO_FRAME:
        raise ProtocolError("expected VIDEO_FRAME, got %s" % frame.name)
    if len(frame.payload) < 9:
        raise ProtocolError("VIDEO_FRAME payload too short")
    pts_us, flags = struct.unpack_from(">QB", frame.payload, 0)
    return pts_us, flags, frame.payload[9:]


FRAME_FLAG_KEY = 0x01


# --- input -----------------------------------------------------------------
def pack_touch(stream, action, pointer_id, nx, ny):
    return pack_frame(TYPE_TOUCH, stream, struct.pack(">BBff", action, pointer_id, nx, ny))


def unpack_touch(frame):
    if frame.type != TYPE_TOUCH:
        raise ProtocolError("expected TOUCH, got %s" % frame.name)
    if len(frame.payload) != 10:
        raise ProtocolError("TOUCH payload must be 10 bytes, got %d" % len(frame.payload))
    action, pointer_id, nx, ny = struct.unpack(">BBff", frame.payload)
    return action, pointer_id, nx, ny


def pack_scroll(stream, nx, ny, hscroll, vscroll):
    return pack_frame(TYPE_SCROLL, stream, struct.pack(">ffff", nx, ny, hscroll, vscroll))


def unpack_scroll(frame):
    if frame.type != TYPE_SCROLL:
        raise ProtocolError("expected SCROLL, got %s" % frame.name)
    if len(frame.payload) != 16:
        raise ProtocolError("SCROLL payload must be 16 bytes, got %d" % len(frame.payload))
    return struct.unpack(">ffff", frame.payload)


def pack_key(stream, action, keycode, meta_state):
    return pack_frame(TYPE_KEY, stream, struct.pack(">BII", action, keycode, meta_state))


def unpack_key(frame):
    if frame.type != TYPE_KEY:
        raise ProtocolError("expected KEY, got %s" % frame.name)
    if len(frame.payload) != 9:
        raise ProtocolError("KEY payload must be 9 bytes, got %d" % len(frame.payload))
    action, keycode, meta_state = struct.unpack(">BII", frame.payload)
    return action, keycode, meta_state


# --- auth ------------------------------------------------------------------
def hmac_hex(key, nonce_hex):
    """HMAC-SHA256(key = raw key bytes, message = UTF-8 bytes of nonce hex)."""
    return hmac.new(key, nonce_hex.encode("utf-8"), hashlib.sha256).hexdigest()


def gen_key():
    """32 random raw key bytes."""
    return os.urandom(32)


def gen_nonce_hex():
    """32 hex chars (16 random bytes) as used in challenge.nonce."""
    return os.urandom(16).hex()


def gen_device_id():
    """Stable 16-hex-char device id."""
    return os.urandom(8).hex()


# --- Annex-B -------------------------------------------------------------
START_CODE4 = b"\x00\x00\x00\x01"
START_CODE3 = b"\x00\x00\x01"

VCL_TYPES = (1, 2, 3, 4, 5)
# Non-VCL NAL types that begin a new access unit when they follow VCL data.
AU_START_AFTER_VCL = (6, 7, 8, 9, 14, 15, 16, 17, 18)


def scan_start_codes(data):
    """Return [(index, start_code_len), ...] for every Annex-B start code."""
    positions = []
    i = 0
    n = len(data)
    while i + 3 <= n:
        if data[i] == 0 and data[i + 1] == 0:
            if i + 4 <= n and data[i + 2] == 0 and data[i + 3] == 1:
                positions.append((i, 4))
                i += 4
                continue
            if data[i + 2] == 1:
                positions.append((i, 3))
                i += 3
                continue
        i += 1
    return positions


def _nal_offset(blob):
    if blob.startswith(START_CODE4):
        return 4
    if blob.startswith(START_CODE3):
        return 3
    return 0


def nal_type(nal):
    """NAL unit type from a NAL blob (with or without leading start code)."""
    off = _nal_offset(nal)
    if off >= len(nal):
        return -1
    return nal[off] & 0x1F


def split_nals(data):
    """Split Annex-B bytes into NAL blobs, each retaining its start code."""
    positions = scan_start_codes(data)
    nals = []
    n = len(data)
    for idx, (pos, _sc) in enumerate(positions):
        end = positions[idx + 1][0] if idx + 1 < len(positions) else n
        nals.append(data[pos:end])
    return nals


def extract_sps_pps(nal_blobs):
    """Concatenate the SPS (7) and PPS (8) NALs, in that order, start codes kept."""
    sps = None
    pps = None
    for nal in nal_blobs:
        t = nal_type(nal)
        if t == 7 and sps is None:
            sps = nal
        elif t == 8 and pps is None:
            pps = nal
    if sps is None or pps is None:
        return None
    return sps + pps


def is_idr(nal_blobs):
    return any(nal_type(nal) == 5 for nal in nal_blobs)


class AccessUnitSplitter(object):
    """Streaming Annex-B -> access-unit splitter for an encoder stdout pipe.

    Start codes bound NALs, but the final NAL in a buffer may be truncated, so a
    NAL is only complete once the *next* start code has arrived. Access units are
    cut at an AUD (9) or at any non-VCL NAL that follows VCL data (the standard
    H.264 boundary rule), which also works when the encoder emits no AUD.
    """

    def __init__(self):
        self._buf = bytearray()
        self._cur = bytearray()
        self._seen_vcl = False

    def feed(self, data):
        """Feed bytes; return a list of complete access units (Annex-B blobs)."""
        self._buf += data
        return self._drain(False)

    def flush(self):
        """Flush the buffer at end-of-stream; returns any remaining AU."""
        return self._drain(True)

    def _drain(self, flush):
        if not self._buf:
            return []
        data = bytes(self._buf)
        positions = scan_start_codes(data)
        if not positions:
            return []
        nals = []
        for idx in range(len(positions) - 1):
            pos = positions[idx][0]
            end = positions[idx + 1][0]
            nals.append(data[pos:end])
        last = positions[-1][0]
        remainder = data[last:]
        if flush:
            nals.append(data[last:])
            remainder = b""
        self._buf = bytearray(remainder)

        units = []
        for nal in nals:
            t = nal_type(nal)
            if self._cur and (t == 9 or (t in AU_START_AFTER_VCL and self._seen_vcl)):
                units.append(bytes(self._cur))
                self._cur = bytearray()
                self._seen_vcl = False
            self._cur += nal
            if t in VCL_TYPES:
                self._seen_vcl = True
        if flush and self._cur:
            units.append(bytes(self._cur))
            self._cur = bytearray()
            self._seen_vcl = False
        return units
