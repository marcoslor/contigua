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
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import time

# --- frame types -----------------------------------------------------------
TYPE_JSON = 0x01
TYPE_VIDEO_CONFIG = 0x02
TYPE_VIDEO_FRAME = 0x03
TYPE_AUDIO_CONFIG = 0x04
TYPE_AUDIO_FRAME = 0x05
TYPE_VIDEO_CHUNK = 0x06
TYPE_TOUCH = 0x10
TYPE_SCROLL = 0x11
TYPE_KEY = 0x12
TYPE_HOVER = 0x13
TYPE_APK_DATA = 0x20
TYPE_SHARE_DATA = 0x21
TYPE_DROP_DATA = 0x22
TYPE_CLIP_DATA = 0x23
TYPE_FS_DATA = 0x24
TYPE_RELIABLE = 0x30
TYPE_ACK = 0x31

TYPE_NAMES = {
    TYPE_JSON: "JSON",
    TYPE_VIDEO_CONFIG: "VIDEO_CONFIG",
    TYPE_VIDEO_FRAME: "VIDEO_FRAME",
    TYPE_AUDIO_CONFIG: "AUDIO_CONFIG",
    TYPE_AUDIO_FRAME: "AUDIO_FRAME",
    TYPE_VIDEO_CHUNK: "VIDEO_CHUNK",
    TYPE_TOUCH: "TOUCH",
    TYPE_SCROLL: "SCROLL",
    TYPE_KEY: "KEY",
    TYPE_HOVER: "HOVER",
    TYPE_APK_DATA: "APK_DATA",
    TYPE_SHARE_DATA: "SHARE_DATA",
    TYPE_DROP_DATA: "DROP_DATA",
    TYPE_CLIP_DATA: "CLIP_DATA",
    TYPE_FS_DATA: "FS_DATA",
    TYPE_RELIABLE: "RELIABLE",
    TYPE_ACK: "ACK",
}

RELIABLE_TYPES = frozenset([
    TYPE_JSON, TYPE_TOUCH, TYPE_SCROLL, TYPE_KEY,
    TYPE_APK_DATA, TYPE_SHARE_DATA, TYPE_DROP_DATA, TYPE_CLIP_DATA,
    TYPE_FS_DATA,
])
BULK_TYPES = frozenset([
    TYPE_APK_DATA, TYPE_SHARE_DATA, TYPE_DROP_DATA, TYPE_CLIP_DATA,
    TYPE_FS_DATA,
])

HEADER = 5                 # type (1) + stream (4)
MAX_FRAME = 8 * 1024 * 1024  # PROTOCOL.md: a larger len closes the session
RELIABLE_WRAPPER = 13      # u64 seq | u8 innerType | u32 innerStream
MAX_INNER_PAYLOAD = MAX_FRAME - 5 - RELIABLE_WRAPPER

CODEC_H264 = 1
CODEC_HEVC = 2
CODEC_OPUS = 2
CODEC_AAC = 3

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


# --- RELIABLE / ACK (docs/PROTOCOL.md "Paths") -----------------------------
def is_reliable(type_):
    return type_ in RELIABLE_TYPES


def is_bulk(type_):
    return type_ in BULK_TYPES


def pack_reliable(seq, inner):
    """Wrap one reliable frame; the outer stream repeats the inner one."""
    if not is_reliable(inner.type):
        raise ProtocolError("not a reliable type: 0x%02x" % inner.type)
    if len(inner.payload) > MAX_INNER_PAYLOAD:
        raise ProtocolError("inner payload of %d bytes exceeds %d"
                            % (len(inner.payload), MAX_INNER_PAYLOAD))
    payload = struct.pack(">QB I", seq & 0xFFFFFFFFFFFFFFFF, inner.type,
                          inner.stream & 0xFFFFFFFF) + inner.payload
    return pack_frame(TYPE_RELIABLE, inner.stream, payload)


def unpack_reliable(frame):
    """Return (seq, inner Frame); a mismatched outer stream is a protocol error."""
    if frame.type != TYPE_RELIABLE:
        raise ProtocolError("not a RELIABLE frame")
    if len(frame.payload) < RELIABLE_WRAPPER:
        raise ProtocolError("short RELIABLE payload")
    seq, inner_type, inner_stream = struct.unpack_from(">QBI", frame.payload, 0)
    if inner_stream != frame.stream:
        raise ProtocolError("outer stream %d differs from inner %d"
                            % (frame.stream, inner_stream))
    return seq, Frame(inner_type, inner_stream, frame.payload[RELIABLE_WRAPPER:])


def pack_ack(ack):
    return pack_frame(TYPE_ACK, 0, struct.pack(">Q", ack & 0xFFFFFFFFFFFFFFFF))


def unpack_ack(frame):
    if frame.type != TYPE_ACK or frame.stream != 0 or len(frame.payload) != 8:
        raise ProtocolError("bad ACK frame")
    return struct.unpack(">Q", frame.payload)[0]


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

# --- VIDEO_CHUNK -----------------------------------------------------------
VIDEO_CHUNK_BYTES = 16 * 1024


def pack_video_chunk(stream, pts_us, flags, index, count, data):
    payload = struct.pack(">QBHH", pts_us, flags, index, count) + data
    return pack_frame(TYPE_VIDEO_CHUNK, stream, payload)


def split_video_frame(stream, pts_us, flags, access_unit,
                      max_bytes=VIDEO_CHUNK_BYTES):
    """The wire frames for one access unit: whole when small, else chunks."""
    if len(access_unit) <= max_bytes:
        return [pack_video_frame(stream, pts_us, flags, access_unit)]
    pieces = [access_unit[i:i + max_bytes]
              for i in range(0, len(access_unit), max_bytes)]
    return [pack_video_chunk(stream, pts_us, flags, index, len(pieces), piece)
            for index, piece in enumerate(pieces)]


def unpack_video_chunk(frame):
    if frame.type != TYPE_VIDEO_CHUNK:
        raise ProtocolError("expected VIDEO_CHUNK, got %s" % frame.name)
    if len(frame.payload) < 13:
        raise ProtocolError("VIDEO_CHUNK payload too short")
    pts_us, flags, index, count = struct.unpack_from(">QBHH", frame.payload, 0)
    data = frame.payload[13:]
    if count < 1 or index >= count or len(data) > VIDEO_CHUNK_BYTES:
        raise ProtocolError("bad VIDEO_CHUNK index %d/%d, %d bytes"
                            % (index, count, len(data)))
    return pts_us, flags, index, count, data


class VideoAssembler(object):
    """Reassemble VIDEO_CHUNK fragments per stream (the Mac's assembler)."""

    def __init__(self):
        self._units = {}

    def add(self, frame):
        """Feed a VIDEO_CHUNK; return (stream, pts_us, flags, au) or None."""
        pts_us, flags, index, count, data = unpack_video_chunk(frame)
        unit = self._units.get(frame.stream)
        if (unit is None or unit["pts"] != pts_us or unit["flags"] != flags
                or unit["count"] != count):
            unit = {"pts": pts_us, "flags": flags, "count": count,
                    "parts": {}, "bytes": 0}
            self._units[frame.stream] = unit
        if index in unit["parts"]:
            return None
        unit["parts"][index] = data
        unit["bytes"] += len(data)
        if len(unit["parts"]) != count:
            return None
        del self._units[frame.stream]
        return (frame.stream, pts_us, flags,
                b"".join(unit["parts"][i] for i in range(count)))

    def forget(self, stream):
        self._units.pop(stream, None)


def pad_access_unit(access_unit, target_bytes):
    """Append an H.264 filler NAL (type 12) until the unit reaches a size.

    The e2e pattern needs a fixed wire load; the picture is unchanged because
    every decoder ignores filler data. Never shrinks a unit.
    """
    need = target_bytes - len(access_unit)
    if need <= 8:
        return access_unit
    # 4-byte start code + 1-byte NAL header + payload + 0x80 trailing bits.
    payload = b"\xff" * (need - 6)
    return access_unit + b"\x00\x00\x00\x01\x0c" + payload + b"\x80"


# --- AUDIO_CONFIG ----------------------------------------------------------
def pack_audio_config(codec, sample_rate, channels, frame_ms, setup=b""):
    payload = struct.pack(">BI BH", codec, sample_rate, channels, frame_ms) + setup
    return pack_frame(TYPE_AUDIO_CONFIG, 0, payload)


def unpack_audio_config(frame):
    if frame.type != TYPE_AUDIO_CONFIG:
        raise ProtocolError("expected AUDIO_CONFIG, got %s" % frame.name)
    if len(frame.payload) < 8:
        raise ProtocolError("AUDIO_CONFIG payload too short")
    codec, sample_rate, channels, frame_ms = struct.unpack_from(">BI BH", frame.payload, 0)
    return codec, sample_rate, channels, frame_ms, frame.payload[8:]


# --- AUDIO_FRAME -----------------------------------------------------------
def pack_audio_frame(pts_us, packet):
    return pack_frame(TYPE_AUDIO_FRAME, 0, struct.pack(">Q", pts_us) + packet)


def unpack_audio_frame(frame):
    if frame.type != TYPE_AUDIO_FRAME:
        raise ProtocolError("expected AUDIO_FRAME, got %s" % frame.name)
    if len(frame.payload) < 8:
        raise ProtocolError("AUDIO_FRAME payload too short")
    pts_us = struct.unpack_from(">Q", frame.payload, 0)[0]
    return pts_us, frame.payload[8:]


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


HOVER_ENTER, HOVER_MOVE, HOVER_EXIT = 0, 1, 2


def pack_hover(stream, action, nx, ny):
    return pack_frame(TYPE_HOVER, stream, struct.pack(">Bff", action, nx, ny))


def unpack_hover(frame):
    if frame.type != TYPE_HOVER:
        raise ProtocolError("expected HOVER, got %s" % frame.name)
    if len(frame.payload) != 9:
        raise ProtocolError("HOVER payload must be 9 bytes, got %d" % len(frame.payload))
    action, nx, ny = struct.unpack(">Bff", frame.payload)
    return action, nx, ny


# --- auth (v1; the v2 TLS pin replaces it — tools/emulator/poc.py and the
# fakephone --legacy-phone mode still use these) ---------------------------
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


# --- v2 TLS identity (proto-common; fakephone.py + deckctl.py share it) -----
#
# identity dir layout: cert.pem / key.pem (0600), one self-signed P-256 cert
# generated by the openssl CLI (LibreSSL is fine; only Python's ssl *module*
# needs OpenSSL 3). The pin is SHA-256 over the 65-byte uncompressed point:
# a P-256 SPKI has a fixed 26-byte header, the point is the next 65 bytes.
# docs/design/e2ee.md §1; the same math lives in KeyPin/PinCheckV2/PointFingerprint.

P256_SPKI_HEADER = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")


def openssl_cli():
    return shutil.which("openssl") or "/usr/bin/openssl"


def identity_paths(dirpath):
    return os.path.join(dirpath, "cert.pem"), os.path.join(dirpath, "key.pem")


def make_identity(dirpath, cn="PocketDeck", fresh=False):
    """Generates the self-signed identity once per dir; returns the fp hex."""
    cert_path, key_path = identity_paths(dirpath)
    if not fresh and os.path.exists(cert_path) and os.path.exists(key_path):
        return point_fingerprint_hex(cert_path)
    os.makedirs(dirpath, exist_ok=True)
    openssl = openssl_cli()
    subprocess.run(
        [openssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout",
         "-out", key_path], check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(
        [openssl, "req", "-new", "-x509", "-key", key_path, "-days", "366",
         "-subj", "/CN=%s" % cn, "-out", cert_path], check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.chmod(key_path, 0o600)
    return point_fingerprint_hex(cert_path)


def point_fingerprint_hex(cert_path):
    """SHA-256 over the 04||X||Y point stored in the cert's SPKI."""
    der = subprocess.run([openssl_cli(), "x509", "-in", cert_path, "-outform", "DER"],
                         check=True, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL).stdout
    return point_fp_from_der(der)


def point_fp_from_der(cert_der):
    """The canonical pin of a certificate's DER (works for live peers, too:
    python exposes the server cert bytes even with verification off)."""
    at = cert_der.find(P256_SPKI_HEADER)
    if at < 0 or at + len(P256_SPKI_HEADER) + 65 > len(cert_der):
        raise ValueError("no P-256 point in the certificate")
    point = cert_der[at + len(P256_SPKI_HEADER): at + len(P256_SPKI_HEADER) + 65]
    return hashlib.sha256(point).hexdigest()


def tls_guard():
    """Fails fast when this interpreter cannot serve protocol v2 TLS.

    v2 needs TLS 1.3: the system python3 links LibreSSL and has none, so
    check-e2e.sh starts fakephone with `PD_FAKE_TLS_PYTHON` (python3.11). The
    server wrap additionally uses pyOpenSSL because the phone contract
    (ShellTls.kt) requests any client certificate and lets the protocol layer
    pin it — the stdlib `verify_mode` cannot express that and aborts a
    self-signed client cert instead.
    """
    if getattr(ssl, "OPENSSL_VERSION", "").startswith("LibreSSL"):
        tls_unavailable("no TLS 1.3 in %s (%s); set PD_FAKE_TLS_PYTHON to a "
                        "python3.11+ built on OpenSSL 3"
                        % (sys.executable, ssl.OPENSSL_VERSION))
    try:
        from OpenSSL import SSL as osl
        probe = osl.Context(osl.TLS_SERVER_METHOD)
        probe.set_min_proto_version(osl.TLS1_3_VERSION)
        probe.set_max_proto_version(osl.TLS1_3_VERSION)
    except ImportError:
        tls_unavailable("pyOpenSSL missing in %s; run: python -m pip install "
                        "--user --break-system-packages pyopenssl"
                        % sys.executable)
    except (ValueError, AttributeError):
        tls_unavailable("TLS 1.3 unavailable in %s" % sys.executable)
    return True


def tls_unavailable(reason):
    sys.stderr.write("fakephone needs TLS 1.3: %s\n" % reason)
    sys.exit(3)


def tls_server_session(cert_path, key_path, raw, handshake_seconds=15):
    """Wraps one accepted socket as the phone: TLS 1.3 only, a permissive
    client-cert.request (the SSLContext is per connection, so the captured
    client leaf never mixes sessions).

    Silences nothing: handshake failures (an aborted or plaintext connection)
    propagate so the caller decides how loudly to treat them.
    Returns a TlsServerSession; `.client_der` is the client cert's DER when
    the client presented one.
    """
    from OpenSSL import SSL as osl
    context = osl.Context(osl.TLS_SERVER_METHOD)
    # TLS 1.3 only (no resumption/0-RTT: R3). The Mac client never caches a
    # session ticket and python contexts are per connection, so every accept
    # is a full handshake.
    context.set_min_proto_version(osl.TLS1_3_VERSION)
    context.set_max_proto_version(osl.TLS1_3_VERSION)
    context.use_certificate_chain_file(cert_path)
    context.use_privatekey_file(key_path)
    capture = {}

    def verify(_conn, x509, _err, depth, _ok):
        # Depth 0 is the client's leaf: keep it; protocol code pins its point.
        if depth == 0 and x509 is not None:
            capture["leaf"] = x509
        return True

    context.set_verify(osl.VERIFY_PEER | osl.VERIFY_CLIENT_ONCE, verify)
    session = TlsServerSession(osl, context, raw, capture, handshake_seconds)
    session.handshake()
    return session


class TlsServerSession(object):
    """The accepted-and-wrapped phone socket. Mirrors the socket interface the
    session loop uses (recv/sendall/close/shutdown, NODELAY lives on the raw
    socket before the wrap) plus the captured client certificate."""

    def __init__(self, osl, context, raw, capture, handshake_seconds):
        self._osl = osl
        self._raw = raw
        self._handshake_seconds = int(handshake_seconds)
        # Blocking socket + SO_RCVTIMEO: a stalled handshake (aborted
        # connection, port scan) undoes itself instead of holding the accept
        # thread. pyOpenSSL 26's Connection owns no timeout knob of its own.
        raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                       struct.pack("ll", self._handshake_seconds, 0))
        self._conn = osl.Connection(context, raw)
        self._conn.set_accept_state()
        self._capture = capture
        self.client_der = None
        self._timeout = None

    def handshake(self):
        # Blocking: OpenSSL retries the syscall itself; SO_RCVTIMEO bounds a
        # client that never finishes.
        self._conn.do_handshake()
        # SO_RCVTIMEO is a kernel option and socket.settimeout() does not clear
        # it, so the handshake deadline would otherwise end a live path after
        # 15 s of silence (the 20 s probe check black-holes one that long).
        self._raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVTIMEO,
                             struct.pack("ll", 0, 0))
        from OpenSSL.crypto import FILETYPE_ASN1, dump_certificate
        leaf = self._capture.get("leaf")
        self.client_der = dump_certificate(FILETYPE_ASN1, leaf) if leaf else None

    def raw_socket(self):
        """The underlying socket (select() needs a real fd: decoded TLS bytes
        can sit in the SSL buffer without the fd going readable)."""
        return self._raw

    def exporter(self, label, length):
        """The RFC 8446 §7.5 keying material of this session (the same bytes
        both ends derive). Reason for a failure is reported by callers."""
        return self._conn.export_keying_material(label, length)

    def setsockopt(self, level, optname, value):
        return self._raw.setsockopt(level, optname, value)

    def settimeout(self, seconds):
        """A read deadline, like `socket.settimeout`. pyOpenSSL's Connection has
        no timeout of its own, so the raw socket carries SO_RCVTIMEO; a read
        that runs out is reported as socket.timeout, which is what a plain
        socket raises and what FrameReader documents."""
        self._timeout = seconds
        self._raw.settimeout(seconds)

    def recv(self, size):
        try:
            return self._conn.recv(size)
        except self._osl.WantReadError:
            if self._timeout is None:
                raise
            raise socket.timeout("no data within the socket timeout")

    def sendall(self, data):
        self._conn.sendall(data)

    def shutdown(self, how):
        try:
            self._conn.shutdown()
        except (self._osl.Error, OSError):
            pass
        try:
            self._raw.shutdown(how)
        except OSError:
            pass

    def close(self):
        try:
            self._conn.shutdown()
        except (self._osl.Error, OSError):
            pass
        try:
            self._raw.close()
        except (self._osl.Error, OSError):
            pass


def tls_client_context(cert_path=None, key_path=None):
    """TLS 1.3 client for the conformance drivers; with an identity it presents
    the Mac-side client cert the phone pins from the handshake (§1)."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    if cert_path:
        context.load_cert_chain(certfile=cert_path, keyfile=key_path)
    return context


# --- Annex-B -------------------------------------------------------------
START_CODE4 = b"\x00\x00\x00\x01"
START_CODE3 = b"\x00\x00\x01"

VCL_TYPES = (1, 2, 3, 4, 5)
# Non-VCL NAL types that begin a new access unit when they follow VCL data.
AU_START_AFTER_VCL = (6, 7, 8, 9, 14, 15, 16, 17, 18)

# HEVC's slices are 0–31; every parameter set, SEI and AUD is non-VCL, so any
# of them after a slice begins the next access unit. Its AUD is 35.
HEVC_VCL_TYPES = tuple(range(0, 32))
HEVC_AU_START_AFTER_VCL = tuple(range(32, 64))
HEVC_AUD = 35


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


def nal_type(nal, codec=CODEC_H264):
    """NAL unit type from a blob (with or without a leading start code)."""
    off = _nal_offset(nal)
    if off >= len(nal):
        return -1
    return (nal[off] & 0x1F) if codec == CODEC_H264 else ((nal[off] >> 1) & 0x3F)


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
    """Concatenate the AVC SPS (7) and PPS (8) NALs, start codes kept."""
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


def extract_hevc_parameter_sets(nal_blobs):
    """Concatenate HEVC VPS (32), SPS (33) and PPS (34), in that order."""
    vps = None
    sps = None
    pps = None
    for nal in nal_blobs:
        t = nal_type(nal, CODEC_HEVC)
        if t == 32 and vps is None:
            vps = nal
        elif t == 33 and sps is None:
            sps = nal
        elif t == 34 and pps is None:
            pps = nal
    if vps is None or sps is None or pps is None:
        return None
    return vps + sps + pps


def hevc_starts_picture(nal):
    """HEVC's first_slice_segment_in_pic_flag is the MSB of the byte after the
    two-byte NAL header. The encoder emits no AUD, so this is the boundary."""
    off = _nal_offset(nal)
    return off + 2 < len(nal) and bool(nal[off + 2] & 0x80)


def is_idr(nal_blobs, codec=CODEC_H264):
    """A decoder can start on AVC 5 or HEVC 19/20; a HEVC CRA (21) is not one."""
    if codec == CODEC_H264:
        return any(nal_type(nal) == 5 for nal in nal_blobs)
    return any(nal_type(nal, codec) in (19, 20) for nal in nal_blobs)


class AccessUnitSplitter(object):
    """Streaming Annex-B -> access-unit splitter for an encoder stdout pipe.

    Start codes bound NALs, but the final NAL in a buffer may be truncated, so a
    NAL is only complete once the *next* start code has arrived. Access units are
    cut at an AUD (9 for AVC, 35 for HEVC) or at any non-VCL NAL that follows
    VCL data (the standard boundary rule), which also works when the encoder
    emits no AUD.
    """

    def __init__(self, codec=CODEC_H264):
        # Both the wire byte and the stream token are accepted, so a caller
        # cannot silently get the AVC rules for an HEVC stream.
        self.codec = (CODEC_HEVC if codec == "hevc"
                      else CODEC_H264 if codec == "avc" else codec)
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
        aud = HEVC_AUD if self.codec == CODEC_HEVC else 9
        vcl = HEVC_VCL_TYPES if self.codec == CODEC_HEVC else VCL_TYPES
        after_vcl = (HEVC_AU_START_AFTER_VCL if self.codec == CODEC_HEVC
                     else AU_START_AFTER_VCL)
        for nal in nals:
            t = nal_type(nal, self.codec)
            boundary = t == aud or (t in after_vcl and self._seen_vcl)
            if (not boundary and self.codec == CODEC_HEVC and self._seen_vcl
                    and t in vcl and hevc_starts_picture(nal)):
                boundary = True
            if self._cur and boundary:
                units.append(bytes(self._cur))
                self._cur = bytearray()
                self._seen_vcl = False
            self._cur += nal
            if t in vcl:
                self._seen_vcl = True
        if flush and self._cur:
            units.append(bytes(self._cur))
            self._cur = bytearray()
            self._seen_vcl = False
        return units
