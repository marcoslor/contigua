#!/usr/bin/env python3
"""deckctl - fake Mac client and conformance tester for PocketDeck phones.

Talks docs/PROTOCOL.md v1 to any phone server (this repo's fake phone today,
the real Android server later). Exits non-zero with a clear message on any
protocol violation: wrong message order, bad sizes, a missing keyframe after a
CONFIG, or an unknown frame type.

Usage:
    python3 deckctl.py --host 127.0.0.1 --port 47811 apps
    python3 deckctl.py --discover open com.android.settings --w 1080 --h 2340 --dpi 450 --seconds 3 --out out.h264
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import pty
import random
import re
import select
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proto  # noqa: E402

DNS_SD = "/usr/bin/dns-sd"
SERVICE_TYPE = "_pocketdeck._tcp"
DEFAULT_STATE = os.path.expanduser("~/.pocketdeck-deckctl.json")
DEFAULT_TIMEOUT = 10.0
HANDSHAKE_TIMEOUT = 20.0
# A second session must fail with `busy` immediately (test_selfcheck.sh asserts
# that); --wait-for-free retries instead, for a phone another client is holding.
BUSY_RETRY_SLEEP = 0.5
TIMEOUT = object()   # sentinel: read timed out


class DeckError(Exception):
    """Fatal, user-facing problem (connection, auth, command misuse)."""


class AuthFailed(Exception):
    """Internal: a stored key was rejected; caller may try the next one."""


class Busy(Exception):
    """Internal: the phone already has a session."""


def round16(value):
    value = int(value)
    if value < 16:
        return 16
    return value - (value % 16)


# --- persisted client identity + per-Mac pins (v2) --------------------------
class ClientState(object):
    def __init__(self, path):
        self.path = path
        self.client_id = None
        self.name = None
        self.pins = {}          # device id -> the phone's point fingerprint (hex)
        self.order = []         # device ids, most recently used first
        self._load()

    def _load(self):
        try:
            with open(self.path, "r") as fp:
                data = json.load(fp)
        except (IOError, OSError, ValueError):
            data = {}
        self.client_id = data.get("clientId")
        self.name = data.get("name")
        # v1 carried shared keys; those authenticate nothing in v2 and must
        # not pass for pins: dropped (no reverse path — re-pair).
        self.pins = {k: v for k, v in (data.get("pins") or {}).items()
                     if isinstance(v, str) and len(v) == 64}
        self.order = data.get("order", list(self.pins.keys()))
        self.last_phone_fp = data.get("lastPhoneFp")
        self.fp_hex = None
        self.identity_dir = None

    def save(self):
        data = {"clientId": self.client_id, "name": self.name,
                "pins": self.pins, "order": self.order,
                "lastPhoneFp": self.last_phone_fp}
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fp:
            json.dump(data, fp, indent=2)
        os.replace(tmp, self.path)

    def ensure_identity(self, name):
        """The TLS identity (P-256 self-signed) in a dir beside this state file."""
        self.identity_dir = self.path + ".identity"
        self.fp_hex = proto.make_identity(self.identity_dir, cn="PocketDeck deckctl")
        if not self.client_id:
            self.client_id = str(uuid.uuid4())
        if name:
            self.name = name
        elif not self.name:
            self.name = socket.gethostname()
        self.save()
        return self.client_id, self.name

    def remember(self, device_id, pin_hex):
        self.pins[device_id] = pin_hex
        if device_id in self.order:
            self.order.remove(device_id)
        self.order.insert(0, device_id)
        self.save()


# --- socket client ---------------------------------------------------------
class Client(object):
    def __init__(self, sock, state, device_id=None):
        self.sock = sock
        self.state = state
        self.device_id = device_id
        self.device = None
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        # Keeps partial frames across timed reads (a stall can split a frame).
        self._reader = proto.FrameReader()

    # -- framing --
    def send_json(self, obj):
        self.sock.sendall(proto.pack_json(obj, obj.get("stream", 0) or 0))

    def send_raw(self, data):
        self.sock.sendall(data)

    def recv(self, timeout=DEFAULT_TIMEOUT):
        """Next complete frame, TIMEOUT if none arrived in time, None on EOF."""
        try:
            return self._reader.read(self.sock, timeout)
        except socket.timeout:
            return TIMEOUT

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    # -- handshake (v2: no challenge, no auth) --
    def send_hello(self):
        client_id, name = self.state.ensure_identity(self.state.name)
        # The Mac's identity rides the TLS handshake's client certificate; the
        # hello carries only the display identity (§4: no self-reported pin).
        self.send_json({"t": "hello", "v": 2, "clientId": client_id, "name": name})
        self.client_name = name

    def _next_frame(self, timeout=HANDSHAKE_TIMEOUT):
        frame = self.recv(timeout)
        if frame is TIMEOUT:
            raise DeckError("no answer from phone (timeout)")
        if frame is None:
            raise DeckError("phone closed the connection during handshake")
        if frame.type != proto.TYPE_JSON:
            raise DeckError("expected JSON handshake frame, got %s" % frame.name)
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            if msg.get("code") == "busy":
                raise Busy()
            raise DeckError("phone error: %s" % msg.get("code"))
        return msg

    def _welcome(self, timeout=HANDSHAKE_TIMEOUT):
        frame = self.recv(timeout)
        if frame is TIMEOUT:
            raise DeckError("no welcome from phone (timeout)")
        if frame is None:
            raise DeckError("phone closed before welcome")
        if frame.type != proto.TYPE_JSON:
            raise DeckError("expected welcome, got %s" % frame.name)
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            code = msg.get("code")
            if code == "bad_pin":
                raise AuthFailed()
            raise DeckError("phone error before welcome: %s" % code)
        if msg.get("t") != "welcome":
            raise DeckError("expected welcome, got %r" % msg.get("t"))
        self.device = msg.get("device", {})
        return msg

    def connect(self):
        """Pin-verifying reconnect: hello v2, then welcome without pairing."""
        self.send_hello()
        msg = self._next_frame()
        if msg.get("t") != "welcome":
            raise DeckError("expected welcome without pairing, got %r" % msg.get("t"))
        self.device = msg.get("device", {})
        device_id = self.device.get("id")
        # Mirror the Mac's pin check: the phone's handshake cert must be the
        # one stored for this device id (§1); anything else is a re-pair.
        pinned = self.state.pins.get(device_id)
        if pinned is None or not hmac.compare_digest(pinned, self.sock.phone_fp_hex):
            raise AuthFailed()
        self.device_id = device_id

    def pair(self, on_code, decision_timeout=130.0):
        """The §4 machine: pair.request → commit → nonce → reveal rehash → code."""
        self.send_hello()
        self.send_json({"t": "pair.request"})
        msg = self._next_frame()
        if msg.get("t") == "welcome":
            # The phone already knows this Mac (a leftover pin) — done.
            self.device = msg.get("device", {})
            self.device_id = self.device.get("id")
            return
        if msg.get("t") != "pair.commit" or not msg.get("c"):
            raise DeckError("expected pair.commit, got %r" % msg.get("t"))
        remote_commit = msg["c"]
        nm = os.urandom(16)
        self.send_json({"t": "pair.nonce", "n": nm.hex()})
        msg = self._next_frame()
        if msg.get("t") != "pair.reveal" or not msg.get("n"):
            raise DeckError("expected pair.reveal, got %r" % msg.get("t"))
        np = bytes.fromhex(msg["n"])
        phone_fp = bytes.fromhex(self.sock.phone_fp_hex)  # §1: from the handshake
        mac_fp = bytes.fromhex(self.state.fp_hex)
        expected = hashlib.sha256(b"pd-commit-v2" + np + phone_fp + mac_fp).hexdigest()
        if not hmac.compare_digest(expected, remote_commit):
            raise DeckError("pair commit mismatch: refuse (pair_commit)")
        self.state.last_phone_fp = self.sock.phone_fp_hex
        # deckctl (a stdlib TLS client) cannot reach the exporter; the phone
        # reports the real §4 code itself (fakephone's stdout). This digests
        # the wire facts only — a self-check trace, never asserted against.
        preimage = hashlib.sha256(b"pd-code-v2" + b"deckctl-no-exporter" +
                                  mac_fp + phone_fp + nm + np).digest()
        code = "%06d" % (int.from_bytes(preimage[:8], "big") % 1000000)
        on_code(code)
        msg = self._next_frame(decision_timeout)
        if msg.get("t") != "pair.ok" or not msg.get("phoneFP") or not msg.get("macFP"):
            raise DeckError("expected pair.ok with both pins, got %r" % msg.get("t"))
        if not hmac.compare_digest(msg["phoneFP"].lower(), self.sock.phone_fp_hex):
            raise DeckError("pair.ok phoneFP is not the handshake's certificate")
        self.state.last_phone_fp = msg["phoneFP"]
        self._welcome()
        device_id = self.device.get("id")
        self.state.remember(device_id, msg["phoneFP"])
        self.device_id = device_id


def _connect_host(host, port, state, timeout=DEFAULT_TIMEOUT):
    """A TLS 1.3 session to the phone: deckctl presents ITS identity as the
    client cert (the phone pins the Mac from the handshake, like the real Mac),
    then takes the phone's fingerprint from the presented server cert (§1:
    pins are handshake facts, not hello self-reports)."""
    state.ensure_identity(state.name)
    cert_path, key_path = proto.identity_paths(state.identity_dir)
    try:
        raw = socket.create_connection((host, port), timeout=timeout)
    except OSError as exc:
        raise DeckError("cannot connect to %s:%s (%s)" % (host, port, exc))
    try:
        raw.settimeout(timeout)
        context = proto.tls_client_context(cert_path, key_path)
        sock = context.wrap_socket(raw, server_hostname="fakephone.local")
    except (ssl.SSLError, OSError) as exc:
        try:
            raw.close()
        except OSError:
            pass
        raise DeckError("tls connect to %s:%s failed (%s)" % (host, port, exc))
    # The phone's point fingerprint comes from the presented certificate
    # (§1: the pin is the handshake's peer cert, not a hello self-report).
    peer = sock.getpeercert(binary_form=True)
    if not peer:
        sock.close()
        raise DeckError("phone did not present a certificate")
    try:
        sock.phone_fp_hex = proto.point_fp_from_der(peer)
    except ValueError as exc:
        sock.close()
        raise DeckError("phone cert not pin-form (%s)" % exc)
    return sock


def open_session(host, port, state, on_code, device_hint=None, busy_retries=1):
    """Return an authenticated Client (paired pin) — else pair when --pair was given."""
    last_error = None
    if state.pins:
        for attempt in range(busy_retries):
            sock = _connect_host(host, port, state)
            client = Client(sock, state)
            try:
                client.connect()
                return client
            except Busy:
                client.close()
                if attempt == busy_retries - 1:
                    raise DeckError("phone busy: another session is active")
                time.sleep(BUSY_RETRY_SLEEP)
                continue
            except AuthFailed:
                client.close()
                last_error = DeckError("pin rejected for device %s; re-pair needed" % device_hint)
                break
            except DeckError as exc:
                client.close()
                raise exc
    if on_code is None:
        if last_error:
            raise last_error
        raise DeckError("not paired with this phone; pass --pair")
    for attempt in range(busy_retries):
        sock = _connect_host(host, port, state)
        client = Client(sock, state)
        try:
            client.pair(on_code)
            return client
        except Busy:
            client.close()
            if attempt == busy_retries - 1:
                raise DeckError("phone busy: another session is active")
            time.sleep(BUSY_RETRY_SLEEP)
            continue
        except DeckError:
            client.close()
            raise
    raise DeckError("phone busy: another session is active")


# --- discovery -------------------------------------------------------------
class PtyProcess(object):
    """Run a command with stdout/stderr on a pty so dns-sd line-buffers.

    dns-sd block-buffers when its stdout is a pipe, which hides browse results
    until the process exits; a pty makes it flush per line.
    """

    def __init__(self, cmd):
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(cmd, stdout=slave, stderr=slave,
                                     stdin=subprocess.DEVNULL, close_fds=True)
        os.close(slave)
        self._buf = ""

    def readline(self, timeout):
        deadline = time.time() + timeout
        while "\n" not in self._buf:
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            ready, _w, _x = select.select([self.master], [], [], remaining)
            if not ready:
                continue
            try:
                data = os.read(self.master, 4096)
            except OSError:
                return None
            if not data:
                return None
            self._buf += data.decode("utf-8", "replace")
        line, self._buf = self._buf.split("\n", 1)
        return line.rstrip("\r")

    def close(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=3)
        except Exception:
            try:
                self.proc.kill()
            except OSError:
                pass
        try:
            os.close(self.master)
        except OSError:
            pass


def discover(timeout=6.0, instance_name=None):
    """Return (host, port, device_id) using the dns-sd browser/resolver."""
    instances = _browse_instances(timeout, instance_name)
    if not instances:
        raise DeckError("no %s service found over mDNS within %ss" % (SERVICE_TYPE, timeout))
    if instance_name:
        if instance_name not in instances:
            raise DeckError("mDNS instance %r not found" % instance_name)
        order = [instance_name] + [i for i in instances if i != instance_name]
    else:
        # Prefer a fake phone when a real app and a fake are both advertised.
        fakes = [i for i in instances if "fake" in i.lower()]
        order = fakes + [i for i in instances if i not in fakes]
    last = None
    for instance in order:
        try:
            host, port, device_id = _resolve_instance(instance, timeout)
            return _resolve_address(host), port, device_id
        except DeckError as exc:
            last = exc
    raise last


def _resolve_address(host, timeout=3.0):
    """Turn an advertised `.local` name into an address.

    The phone can advertise its SRV record before the Mac has cached the A
    record, so connect() on the raw name may fail with "No route to host".
    Resolving explicitly removes that flake.
    """
    if not host.endswith(".local"):
        return host
    resolver = PtyProcess([DNS_SD, "-G", "v4", host])
    ip = None
    try:
        deadline = time.time() + timeout
        while time.time() < deadline and ip is None:
            line = resolver.readline(deadline - time.time())
            if line is None:
                break
            if re.search(r"\bAdd\b", line):
                m = re.search(r"\b(\d+\.\d+\.\d+\.\d+)\b", line)
                if m:
                    ip = m.group(1)
    finally:
        resolver.close()
    return ip or host


def _browse_instances(timeout, want_name=None):
    browser = PtyProcess([DNS_SD, "-B", SERVICE_TYPE])
    instances = []
    first_seen = None
    try:
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = browser.readline(deadline - time.time())
            if line is None:
                break
            m = re.search(r"\bAdd\b.*_pocketdeck\._tcp\.\s+(.+?)\s*$", line)
            if not m:
                continue
            name = m.group(1).strip()
            if name and name not in instances:
                instances.append(name)
                if first_seen is None:
                    first_seen = time.time()
            if want_name and want_name in instances:
                break
            # All live services announce within milliseconds; don't burn the
            # whole timeout once we have at least one.
            if not want_name and first_seen and time.time() - first_seen > 0.6:
                break
    finally:
        browser.close()
    return instances


def _resolve_instance(instance, timeout):
    resolver = PtyProcess([DNS_SD, "-L", instance, SERVICE_TYPE, "local"])
    host = port = device_id = None
    try:
        deadline = time.time() + timeout
        while time.time() < deadline and (host is None or device_id is None):
            line = resolver.readline(deadline - time.time())
            if line is None:
                break
            m = re.search(r"can be reached at ([^:\s]+):(\d+)", line)
            if m:
                host, port = m.group(1).rstrip("."), int(m.group(2))
            m = re.search(r"\bid=([0-9a-fA-F]{16})\b", line)
            if m:
                device_id = m.group(1)
        if host is None:
            raise DeckError("could not resolve address for %r" % instance)
    finally:
        resolver.close()
    return host, port, device_id


# --- frame reading helpers -------------------------------------------------
def expect_json(client, want, timeout=DEFAULT_TIMEOUT, ignore_video=False):
    deadline = time.time() + timeout
    while True:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            raise DeckError("timed out waiting for %r" % want)
        if frame is None:
            raise DeckError("phone closed the connection while waiting for %r" % want)
        if frame.type != proto.TYPE_JSON:
            if ignore_video and frame.type in (proto.TYPE_VIDEO_FRAME, proto.TYPE_VIDEO_CONFIG):
                continue
            raise proto.ProtocolError("expected %r, got %s frame" % (want, frame.name))
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error %s: %s" %
                            (msg.get("code"), msg.get("message", "")))
        if want is None or msg.get("t") == want:
            return msg


# --- stream recording + frame dumping --------------------------------------
class StreamRecorder(object):
    """Background reader that demuxes each stream's video into phase files.

    deckctl's main thread keeps sending input on the same socket; only this
    thread reads. ``begin_phase(stream, path)`` opens a new raw Annex-B file,
    seeded with the stream's cached SPS/PPS, and skips delta frames until the
    next keyframe so every phase file decodes on its own. JSON messages and
    per-stream sizes/close reasons are kept for the caller to inspect.
    """

    def __init__(self, client):
        self.client = client
        self.lock = threading.RLock()
        self.files = {}
        self.sizes = {}
        self.csd = {}
        self.wait_key = {}
        self.phase_frames = {}
        self.total_frames = {}
        self.keys_seen = {}
        self.messages = []
        self.opened = {}
        self.closed_reason = {}
        # Per stream: when the latest VIDEO_CONFIG arrived and when the first
        # VIDEO_FRAME after it did, as (time, is_keyframe).
        self.config_at = {}
        self.first_frame_at = {}
        self.error = None
        self.reader_closed = False
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="deckctl-recorder")
        self._thread.daemon = True

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=3.0)

    # -- phase files --
    def begin_phase(self, stream, path):
        with self.lock:
            self._close_locked(stream)
            fp = open(path, "wb")
            csd = self.csd.get(stream)
            if csd:
                fp.write(csd)
            self.files[stream] = fp
            self.wait_key[stream] = True
            self.phase_frames[stream] = 0

    def end_phase(self, stream):
        with self.lock:
            frames = self.phase_frames.get(stream, 0)
            self._close_locked(stream)
            return frames

    def _close_locked(self, stream):
        fp = self.files.pop(stream, None)
        if fp is not None:
            try:
                fp.close()
            except OSError:
                pass

    # -- waits --
    def wait_for_size(self, stream, timeout, want=None):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if stream in self.csd:
                    size = self.sizes.get(stream)
                    if want is None or size == want:
                        return size
            self.raise_if_broken("waiting for VIDEO_CONFIG")
            time.sleep(0.05)
        raise DeckError("no VIDEO_CONFIG for stream %d" % stream)

    def wait_for_key(self, stream, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if not self.wait_key.get(stream, True):
                    return
            self.raise_if_broken("waiting for a keyframe")
            time.sleep(0.02)
        raise DeckError("no keyframe for stream %d (window.keyframe sent)" % stream)

    def raise_if_broken(self, what):
        if self.error is not None:
            raise self.error
        if self.reader_closed:
            raise DeckError("phone closed the connection while %s" % what)

    # -- reader --
    def _loop(self):
        try:
            while not self._stop.is_set():
                try:
                    frame = self.client.recv(0.2)
                except (OSError, proto.ProtocolError) as exc:
                    self.error = exc
                    self.reader_closed = True
                    return
                if frame is TIMEOUT:
                    continue
                if frame is None:
                    self.reader_closed = True
                    return
                self._on_frame(frame)
        except Exception as exc:  # keep the main thread informed, never hang it
            self.error = exc
            self.reader_closed = True

    def _on_frame(self, frame):
        with self.lock:
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                self.messages.append(msg)
                # JSON frames travel with stream 0; the payload field is
                # authoritative (PROTOCOL.md).
                if msg.get("t") == "window.opened":
                    self.opened[msg.get("stream")] = msg
                elif msg.get("t") == "window.closed":
                    self.closed_reason[msg.get("stream")] = msg.get("reason")
                return
            if frame.type == proto.TYPE_VIDEO_CONFIG:
                _codec, w, h, csd = proto.unpack_video_config(frame)
                self.sizes[frame.stream] = (w, h)
                self.csd[frame.stream] = csd
                self.config_at[frame.stream] = time.time()
                self.first_frame_at.pop(frame.stream, None)
                fp = self.files.get(frame.stream)
                if fp is not None:
                    fp.write(csd)
                    self.wait_key[frame.stream] = True
                return
            if frame.type == proto.TYPE_VIDEO_FRAME:
                _pts, flags, au = proto.unpack_video_frame(frame)
                self.total_frames[frame.stream] = self.total_frames.get(frame.stream, 0) + 1
                if flags & proto.FRAME_FLAG_KEY:
                    self.keys_seen[frame.stream] = self.keys_seen.get(frame.stream, 0) + 1
                if frame.stream not in self.first_frame_at:
                    self.first_frame_at[frame.stream] = (time.time(), bool(flags & proto.FRAME_FLAG_KEY))
                fp = self.files.get(frame.stream)
                if fp is None:
                    return
                if self.wait_key.get(frame.stream) and not (flags & proto.FRAME_FLAG_KEY):
                    return
                self.wait_key[frame.stream] = False
                fp.write(au)
                self.phase_frames[frame.stream] = self.phase_frames.get(frame.stream, 0) + 1


def ffmpeg_run(args):
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise DeckError("ffmpeg failed: %s" % proc.stderr.decode("utf-8", "replace").strip()[-400:])
    return proc


def dump_last_frame(h264_path, png_path):
    """Decode every frame, keep the last one: ffmpeg's image2 `-update 1`
    rewrites the same file per frame, so the final PNG is the final frame."""
    ffmpeg_run(["ffmpeg", "-loglevel", "error", "-y", "-i", h264_path,
                "-update", "1", "-f", "image2", png_path])
    return png_path


def _parse_step(spec):
    kind, _, arg = spec.partition(":")
    return kind.strip().lower(), arg.strip()


def _send_step(client, stream, kind, arg):
    """Execute one probe step and return a human description."""
    if kind == "tap":
        nx, ny = [float(v) for v in arg.split(",")]
        client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, nx, ny))
        time.sleep(0.05)
        client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, nx, ny))
        return "tap %.3f,%.3f" % (nx, ny)
    if kind == "scroll":
        vscroll = float(arg)
        client.send_raw(proto.pack_scroll(stream, 0.5, 0.5, 0.0, vscroll))
        return "scroll %.1f" % vscroll
    if kind == "text":
        client.send_json({"t": "text", "stream": stream, "text": arg})
        return "text %r" % arg
    if kind == "back":
        client.send_json({"t": "nav", "stream": stream, "action": "back"})
        return "nav back"
    if kind == "key":
        keycode = int(arg)
        client.send_raw(proto.pack_key(stream, proto.KEY_DOWN, keycode, 0))
        time.sleep(0.03)
        client.send_raw(proto.pack_key(stream, proto.KEY_UP, keycode, 0))
        return "key %d" % keycode
    if kind == "wait":
        time.sleep(float(arg))
        return "wait %ss" % arg
    raise DeckError("unknown probe step %r" % kind)


# --- commands --------------------------------------------------------------
CAM_TERMINAL = ("stopped", "evicted", "off", "busy", "locked", "disabled", "error")
CAM_DEFAULT_W = 1280
CAM_DEFAULT_H = 720
CAM_DEFAULT_FPS = 30


def _cam_state_line(msg):
    line = "cam.state stream=%s state=%s" % (msg.get("stream"), msg.get("state"))
    if msg.get("reason"):
        line += " reason=%s" % msg.get("reason")
    return line


def _cam_read_json(client, deadline, want):
    """Read JSON messages until one of t == want (a dict) or an error."""
    while time.time() < deadline:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            return None
        if frame is None:
            raise DeckError("phone closed while waiting for %s" % want)
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") == want:
            return msg
    return None


def cmd_cam(client, args):
    """docs/PROTOCOL.md "Camera": list, start (measure), stop. No image output."""
    if args.action == "list":
        client.send_json({"t": "cam.list"})
        msg = _cam_read_json(client, time.time() + args.wait, "cam.cams")
        if msg is None:
            raise DeckError("no cam.cams within %.1fs" % args.wait)
        cams = msg.get("cams") or []
        print("cam.cams count=%d" % len(cams))
        for cam in cams:
            print("cam.cam id=%s facing=%s %sx%s" % (cam.get("id"), cam.get("facing"),
                                                     cam.get("w"), cam.get("h")))
        return 0

    stream = args.stream
    if args.action == "stop":
        client.send_json({"t": "cam.stop", "stream": stream})
        print("cam.stop stream=%d" % stream)
        deadline = time.time() + args.wait
        state = None
        while time.time() < deadline:
            frame = client.recv(max(0.05, deadline - time.time()))
            if frame is TIMEOUT:
                break
            if frame is None:
                raise DeckError("phone closed while waiting for cam.state stopped")
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))
            if msg.get("t") != "cam.state":
                continue
            print(_cam_state_line(msg))
            state = msg.get("state")
            if state in CAM_TERMINAL:
                break
        if state != "stopped":
            raise DeckError("cam.stop answered %r, expected stopped" % (state,))
        return 0

    # start: measure frames, then cam.stop, and report every state on the way.
    request = {"t": "cam.start", "stream": stream}
    if args.camera_id:
        request["id"] = args.camera_id
    if args.facing:
        request["facing"] = args.facing
    if args.w:
        request["w"] = args.w
    if args.h:
        request["h"] = args.h
    if args.fps:
        request["fps"] = args.fps
    client.send_json(request)
    started = time.time()
    deadline = started + args.wait
    streamed_at = None
    measure_until = None
    frames = keys = 0
    byte_count = 0
    first_key = None
    first_has_sps = None
    key_times = []
    terminal = None
    terminal_at = None
    after_terminal_frames = 0
    busy_state = None
    busy_sent = False
    output = open(args.save_h264, "wb") if args.save_h264 else None

    def counting():
        return measure_until is None or time.time() < measure_until

    try:
        while True:
            now = time.time()
            if now >= deadline:
                break
            if terminal_at is not None and now >= terminal_at + args.after_terminal_wait:
                break
            measuring = measure_until is not None and now >= measure_until
            if measuring and not args.await_terminal and (not args.busy_stream or busy_sent):
                break
            frame = client.recv(min(0.5, max(0.02, deadline - now)))
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed the connection during a capture")
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                if msg.get("t") == "error":
                    raise DeckError("phone error %s: %s" %
                                    (msg.get("code"), msg.get("message", "")))
                if msg.get("t") != "cam.state":
                    continue
                print(_cam_state_line(msg))
                state = msg.get("state")
                if msg.get("stream") != stream:
                    # A second stream only reports here (the busy probe).
                    if args.busy_stream and msg.get("stream") == args.busy_stream:
                        busy_state = state
                    continue
                if state == "streaming" and streamed_at is None:
                    streamed_at = time.time()
                    measure_until = streamed_at + args.seconds
                elif state in CAM_TERMINAL:
                    terminal = state
                    terminal_at = time.time()
                    # Keep reading a moment: nothing of this capture may follow.
                    if args.after_terminal_wait <= 0:
                        break
                continue
            if frame.type != proto.TYPE_VIDEO_FRAME:
                raise proto.ProtocolError("unexpected frame type 0x%02x in a capture" % frame.type)
            if frame.stream != stream:
                raise proto.ProtocolError("VIDEO_FRAME on stream %d, expected %d" %
                                          (frame.stream, stream))
            pts, flags, au = proto.unpack_video_frame(frame)
            if not au or au[:3] not in (proto.START_CODE4[:3], proto.START_CODE3):
                raise proto.ProtocolError("camera VIDEO_FRAME payload is not Annex-B")
            key = bool(flags & proto.FRAME_FLAG_KEY)
            if terminal_at is not None:
                after_terminal_frames += 1
                continue
            if counting():
                frames += 1
                byte_count += len(au)
                if frames == 1:
                    first_key = key
                    first_has_sps = proto.extract_sps_pps(proto.split_nals(au)) is not None
                if key:
                    keys += 1
                    key_times.append(time.time())
                if output is not None:
                    output.write(au)
            if args.busy_stream and not busy_sent and frames >= 3:
                busy_sent = True
                client.send_json({"t": "cam.start", "stream": args.busy_stream})
    finally:
        if output is not None:
            output.close()

    measured_s = 0.0
    if streamed_at is not None:
        measured_s = max(1e-3, (measure_until or time.time()) - streamed_at)
    fps = frames / measured_s if measured_s > 0 else 0.0
    gap_ms = None
    if len(key_times) > 1:
        gap_ms = (key_times[-1] - key_times[0]) * 1000.0 / (len(key_times) - 1)
    print("cam.stats stream=%d frames=%d keys=%d fps=%.1f bytes=%d first_key=%s "
          "sps_pps=%s key_gap_ms=%s measured_s=%.2f" %
          (stream, frames, keys, fps, byte_count, first_key, first_has_sps,
           "%.0f" % gap_ms if gap_ms is not None else "none", measured_s))
    if args.busy_stream:
        print("cam.busy stream=%d state=%s" % (args.busy_stream, busy_state or "none"))
    if terminal_at is not None:
        print("cam.after_terminal frames=%d" % after_terminal_frames)
    if terminal is None:
        client.send_json({"t": "cam.stop", "stream": stream})
        print("cam.stop stream=%d" % stream)
        msg = _cam_read_json(client, time.time() + args.wait, "cam.state")
        if msg is not None:
            print(_cam_state_line(msg))
    else:
        print("cam.terminal state=%s" % terminal)
    return 0


def cmd_apps(client, _args):
    client.send_json({"t": "apps.list"})
    msg = expect_json(client, "apps")
    apps = msg.get("apps", [])
    for app in apps:
        print("%s\t%s" % (app.get("pkg"), app.get("label")))
    print("# %d apps" % len(apps))
    return 0


def cmd_icon(client, args):
    client.send_json({"t": "apps.icon", "pkg": args.pkg})
    msg = expect_json(client, "icon")
    raw = base64.b64decode(msg.get("png", ""))
    if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        raise proto.ProtocolError("icon payload is not a PNG")
    with open(args.out, "wb") as fp:
        fp.write(raw)
    print("icon %s -> %s (%d bytes)" % (args.pkg, args.out, len(raw)))
    return 0


def _open_request(args, stream):
    req = {"t": "window.open", "stream": stream, "w": args.w, "h": args.h, "dpi": args.dpi}
    if getattr(args, "url", None):
        req["t"] = "link.open"
        req["url"] = args.url
    elif args.phone:
        req["mode"] = "phone"
    else:
        req["pkg"] = args.target
    return req


def _read_video(client, deadline, output, stats):
    """Read frames until deadline. Writes CONFIG SPS/PPS + frames to *output*."""
    while time.time() < deadline:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed the connection during video")
        if frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
            if msg.get("t") == "window.opened":
                stats["opened"] = msg
            continue
        if frame.type == proto.TYPE_VIDEO_CONFIG:
            codec, w, h, sps_pps = proto.unpack_video_config(frame)
            if codec != proto.CODEC_H264:
                raise proto.ProtocolError("unsupported codec %d in VIDEO_CONFIG" % codec)
            if sps_pps[:4] not in (proto.START_CODE4, proto.START_CODE3):
                raise proto.ProtocolError("VIDEO_CONFIG SPS/PPS is not Annex-B")
            stats["configs"].append((w, h))
            stats["configured_at"] = time.time()
            if output is not None:
                output.write(sps_pps)
            continue
        if frame.type == proto.TYPE_VIDEO_FRAME:
            if not stats["configs"]:
                raise proto.ProtocolError("VIDEO_FRAME before any VIDEO_CONFIG")
            pts, flags, au = proto.unpack_video_frame(frame)
            if not au or au[:3] not in (proto.START_CODE4[:3], proto.START_CODE3):
                raise proto.ProtocolError("VIDEO_FRAME payload is not Annex-B")
            if stats["frames"] == 0 and not (flags & proto.FRAME_FLAG_KEY):
                raise proto.ProtocolError("first VIDEO_FRAME after CONFIG is not a keyframe")
            if stats["frames"] == 0:
                stats["first_frame_at"] = time.time()
            stats["frames"] += 1
            stats["bytes"] += len(au)
            if output is not None:
                output.write(au)
            continue
        raise proto.ProtocolError("unknown frame type 0x%02x" % frame.type)
    return stats


def _wait_for_key(client, size, deadline):
    """After a CONFIG(size), require that the next VIDEO_FRAME is a keyframe."""
    while time.time() < deadline:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            raise DeckError("timed out waiting for keyframe after CONFIG %dx%d" % size)
        if frame is None:
            raise DeckError("phone closed while waiting for keyframe")
        if frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))
            continue
        if frame.type == proto.TYPE_VIDEO_CONFIG:
            codec, w, h, _sp = proto.unpack_video_config(frame)
            size = (w, h)
            continue
        if frame.type == proto.TYPE_VIDEO_FRAME:
            _pts, flags, _au = proto.unpack_video_frame(frame)
            if not (flags & proto.FRAME_FLAG_KEY):
                raise proto.ProtocolError("first VIDEO_FRAME after CONFIG %dx%d is not a keyframe" % size)
            return True
        raise proto.ProtocolError("unknown frame type 0x%02x" % frame.type)
    return False


def cmd_open(client, args):
    stream = 1
    request = _open_request(args, stream)
    started = time.time()
    client.send_json(request)
    deadline = started + max(args.seconds, 0.5)
    output = open(args.out, "wb") if args.out else None
    stats = {"opened": None, "configs": [], "frames": 0, "bytes": 0, "first_frame_at": None}
    try:
        _read_video(client, deadline, output, stats)
    finally:
        if output is not None:
            output.close()
    elapsed = max(1e-3, time.time() - started)
    if stats["opened"] is None:
        raise DeckError("no window.opened from phone")
    if not stats["configs"]:
        raise DeckError("no VIDEO_CONFIG received")
    w, h = stats["configs"][0]
    # A phone-mode stream is mirrored into the box at the screen's aspect (the
    # phone floors it to 16 px), so its size is the one the phone announced.
    opened = stats["opened"]
    if args.phone and opened.get("w") and opened.get("h"):
        want = (int(opened["w"]), int(opened["h"]))
    else:
        want = (round16(args.w), round16(args.h))
    if (w, h) != want:
        raise proto.ProtocolError("VIDEO_CONFIG is %dx%d, expected %dx%d" % (w, h, want[0], want[1]))
    if stats["frames"] == 0:
        raise DeckError("no VIDEO_FRAME received")
    first_ms = (stats["first_frame_at"] - started) * 1000.0
    fps = stats["frames"] / elapsed
    kbps = stats["bytes"] * 8.0 / elapsed / 1000.0
    print("stream=%d size=%dx%d displayId=%s" %
          (stream, w, h, stats["opened"].get("displayId")))
    print("fps=%.1f kbps=%.1f first_frame_ms=%.1f frames=%d" %
          (fps, kbps, first_ms, stats["frames"]))
    client.send_json({"t": "window.close", "stream": stream})
    return 0


def cmd_resize_test(client, args):
    stream = 1
    client.send_json({"t": "window.open", "stream": stream,
                      "w": args.w, "h": args.h, "dpi": args.dpi, "pkg": "com.android.settings"})
    first_size = None
    deadline = time.time() + DEFAULT_TIMEOUT
    while time.time() < deadline and first_size is None:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            raise DeckError("no VIDEO_CONFIG for initial size")
        if frame is None:
            raise DeckError("phone closed before initial CONFIG")
        if frame.type == proto.TYPE_VIDEO_CONFIG:
            _codec, w, h, _sp = proto.unpack_video_config(frame)
            first_size = (w, h)
        elif frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))
    _wait_for_key(client, first_size, time.time() + DEFAULT_TIMEOUT)

    target = (round16(args.w2), round16(args.h2))
    client.send_json({"t": "window.resize", "stream": stream,
                      "w": args.w2, "h": args.h2, "dpi": args.dpi})
    deadline = time.time() + DEFAULT_TIMEOUT
    new_size = None
    while time.time() < deadline and new_size is None:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            raise DeckError("no VIDEO_CONFIG after resize")
        if frame is None:
            raise DeckError("phone closed during resize")
        if frame.type == proto.TYPE_VIDEO_CONFIG:
            _codec, w, h, _sp = proto.unpack_video_config(frame)
            if (w, h) == first_size:
                continue
            new_size = (w, h)
        elif frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))
    if new_size != target:
        raise proto.ProtocolError("post-resize CONFIG is %dx%d, expected %dx%d" %
                                  (new_size[0], new_size[1], target[0], target[1]))
    _wait_for_key(client, new_size, time.time() + DEFAULT_TIMEOUT)
    print("resize ok: %dx%d -> %dx%d (CONFIG + keyframe after each)" %
          (first_size[0], first_size[1], new_size[0], new_size[1]))
    client.send_json({"t": "window.close", "stream": stream})
    return 0


def cmd_input_test(client, args):
    stream = 1
    client.send_json({"t": "window.open", "stream": stream,
                      "w": args.w, "h": args.h, "dpi": args.dpi, "pkg": "com.android.settings"})
    _wait_for_key(client, None, time.time() + DEFAULT_TIMEOUT)

    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, 0.5, 0.5))
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_MOVE, 0, 0.55, 0.52))
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, 0.55, 0.52))
    client.send_raw(proto.pack_scroll(stream, 0.5, 0.5, 0.0, -3.0))
    client.send_raw(proto.pack_key(stream, proto.KEY_DOWN, proto.KEYCODE_BACK, 0))
    client.send_raw(proto.pack_key(stream, proto.KEY_UP, proto.KEYCODE_BACK, 0))
    client.send_json({"t": "nav", "stream": stream, "action": "back"})
    client.send_json({"t": "ping", "ts": 1})
    expect_json(client, "pong", timeout=DEFAULT_TIMEOUT, ignore_video=True)
    print("input ok: touch down/move/up, scroll, key down/up, nav back")
    client.send_json({"t": "window.close", "stream": stream})
    return 0


def cmd_pause_test(client, args):
    stream = 1
    client.send_json({"t": "window.open", "stream": stream,
                      "w": args.w, "h": args.h, "dpi": args.dpi, "pkg": "com.android.settings"})
    _wait_for_key(client, None, time.time() + DEFAULT_TIMEOUT)

    client.send_json({"t": "window.pause", "stream": stream})
    # Let frames already in flight drain, then require a quiet window.
    drain_until = time.time() + 0.4
    while time.time() < drain_until:
        frame = client.recv(max(0.05, drain_until - time.time()))
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed during pause")
        if frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))
    quiet_until = time.time() + 0.8
    while time.time() < quiet_until:
        frame = client.recv(max(0.05, quiet_until - time.time()))
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed during pause")
        if frame.type == proto.TYPE_VIDEO_FRAME:
            raise proto.ProtocolError("VIDEO_FRAME received while stream is paused")
        if frame.type == proto.TYPE_VIDEO_CONFIG:
            raise proto.ProtocolError("VIDEO_CONFIG received while stream is paused")
        if frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))

    client.send_json({"t": "window.resume", "stream": stream})
    got_config = False
    deadline = time.time() + DEFAULT_TIMEOUT
    while time.time() < deadline and not got_config:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            raise DeckError("no CONFIG after resume")
        if frame is None:
            raise DeckError("phone closed after resume")
        if frame.type == proto.TYPE_VIDEO_CONFIG:
            got_config = True
        elif frame.type == proto.TYPE_VIDEO_FRAME:
            raise proto.ProtocolError("VIDEO_FRAME before CONFIG after resume")
        elif frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))
    _wait_for_key(client, None, time.time() + DEFAULT_TIMEOUT)
    print("pause ok: no frames while paused; CONFIG + keyframe after resume")
    client.send_json({"t": "window.close", "stream": stream})
    return 0


def _motion_step(client, stream, mode, magnitude):
    """One motion event: a scroll burst, or a synthetic fling (down/moves/up).

    The fling keeps a list animating afterwards, which is what a nearly static
    app needs to produce frames the encoder can measure.
    """
    if mode == "drag":
        client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, 0.5, 0.85))
        for i in range(14):
            client.send_raw(proto.pack_touch(stream, proto.TOUCH_MOVE, 0, 0.5, 0.85 - 0.05 * (i + 1)))
            time.sleep(0.012)
        client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, 0.5, 0.15))
    else:
        client.send_raw(proto.pack_scroll(stream, 0.5, 0.5, 0.0, magnitude))


def _read_frames(client, seconds, stats, output, stream, motion, scroll_every,
                 report_every=0.0, read=True, motion_mode="scroll"):
    """Read (or deliberately skip reading) frames for `seconds`.

    With `read=False` the socket is left unread, which is how a backlog is
    simulated: the phone keeps encoding, its send queue fills and its
    backpressure path takes over. `motion` injects a scroll/fling every
    `scroll_every` seconds so a static app keeps producing frames.
    """
    deadline = time.time() + seconds
    next_motion = time.time()
    direction = 1
    window_frames = 0
    window_bytes = 0
    window_start = time.time()
    next_report = window_start + report_every if report_every else None
    phase_start = window_start
    while time.time() < deadline:
        if motion:
            now = time.time()
            if now >= next_motion:
                if motion_mode == "drag":
                    _motion_step(client, stream, "drag", motion)
                else:
                    _motion_step(client, stream, "scroll", direction * motion)
                    direction = -direction
                next_motion = now + scroll_every
        if read:
            frame = client.recv(0.1)
            if frame is TIMEOUT:
                pass
            elif frame is None:
                raise DeckError("phone closed the connection during video")
            elif frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                if msg.get("t") == "error":
                    raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
            elif frame.type == proto.TYPE_VIDEO_CONFIG:
                _codec, _w, _h, csd = proto.unpack_video_config(frame)
                stats["configs"] += 1
                if output is not None:
                    output.write(csd)
            elif frame.type == proto.TYPE_VIDEO_FRAME:
                _pts, flags, au = proto.unpack_video_frame(frame)
                stats["frames"] += 1
                stats["bytes"] += len(au)
                stats["sizes"].append(len(au))
                window_frames += 1
                window_bytes += len(au)
                if flags & proto.FRAME_FLAG_KEY:
                    stats["keys"] += 1
                if output is not None:
                    output.write(au)
        else:
            time.sleep(0.02)
        if next_report is not None and time.time() >= next_report:
            elapsed = max(1e-3, time.time() - window_start)
            print("  t+%4.0fs frames=%3d kbps=%7.1f avg=%5d B" % (
                time.time() - phase_start, window_frames,
                window_bytes * 8.0 / elapsed / 1000.0, window_bytes // max(1, window_frames)))
            window_frames = 0
            window_bytes = 0
            window_start = time.time()
            next_report = window_start + report_every


def cmd_quality_test(client, args):
    """Open a window, change the encoder quality live, then stall the socket.

    Phases: base, quality (after `window.quality`), stall (the socket is not
    read, which fills the phone's send queue) and recover. Each prints frames,
    kbps and the average frame size, so the effect of a bitrate request and of
    the phone's own backpressure adaptation is visible without decoding.
    """
    stream = 1
    # A real Mac keeps up; a small receive buffer makes the stall hit the
    # phone's ~250 ms send-queue budget quickly.
    try:
        client.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
    except OSError:
        pass
    stats = {"configs": 0, "frames": 0, "bytes": 0, "sizes": [], "keys": 0}
    output = open(args.out, "wb") if args.out else None
    request = {"t": "window.open", "stream": stream, "w": args.w, "h": args.h, "dpi": args.dpi}
    if args.phone:
        request["mode"] = "phone"
    else:
        request["pkg"] = args.target
    client.send_json(request)
    print("quality-test stream=%d %dx%d quality=%s bps/%s fps stall=%ss motion=%s" % (
        stream, args.w, args.h, args.quality_bps, args.quality_fps, args.stall,
        args.motion or "off"))
    try:
        # Warm up first: a fresh window spends its first seconds launching the
        # app and emitting an IDR, which would skew the base phase.
        if args.warmup_seconds > 0:
            warm = {"configs": 0, "frames": 0, "bytes": 0, "sizes": [], "keys": 0}
            _read_frames(client, args.warmup_seconds, warm, output, stream, args.motion,
                         args.scroll_every, 0, read=True, motion_mode=args.motion_mode)
            warm_avg = (sum(warm["sizes"]) // len(warm["sizes"])) if warm["sizes"] else 0
            print("warmup   frames=%4d avg_frame=%6d B" % (len(warm["sizes"]), warm_avg))

        def phase(name, seconds, read=True, send=None):
            before = len(stats["sizes"])
            started = time.time()
            if send is not None:
                send()
            if seconds > 0:
                _read_frames(client, seconds, stats, output, stream, args.motion,
                             args.scroll_every, args.report_every, read=read,
                             motion_mode=args.motion_mode)
            elapsed = max(1e-3, time.time() - started)
            got = stats["sizes"][before:]
            avg = (sum(got) / len(got)) if got else 0.0
            kbps = (sum(got) * 8.0 / elapsed / 1000.0) if got else 0.0
            print("phase %-8s frames=%4d kbps=%8.1f avg_frame=%6.0f B%s" % (
                name, len(got), kbps, avg, "" if read else " (socket not read)"))
            return len(got), avg

        phase("base", args.base_seconds)
        if args.seconds > 0:
            phase("quality", args.seconds,
                  send=lambda: client.send_json({"t": "window.quality", "stream": stream,
                                                 "bitrate": args.quality_bps,
                                                 "maxFps": args.quality_fps}))
        if args.stall > 0:
            if args.stall_bps > 0:
                phase("stall-pre", 0,
                      send=lambda: client.send_json({"t": "window.quality", "stream": stream,
                                                     "bitrate": args.stall_bps,
                                                     "maxFps": args.quality_fps}))
            phase("stall", args.stall, read=False)
        if args.recover_seconds > 0:
            phase("recover", args.recover_seconds)
        if args.cap_seconds > 0:
            phase("fpscap", args.cap_seconds,
                  send=lambda: client.send_json({"t": "window.quality", "stream": stream,
                                                 "maxFps": args.cap_fps}))
    finally:
        client.send_json({"t": "window.close", "stream": stream})
        if output is not None:
            output.close()
    print("quality-test totals frames=%d keys=%d configs=%d" %
          (stats["frames"], stats["keys"], stats["configs"]))
    return 0


def cmd_watch_state(client, args):
    """Print every `state` message as it arrives: event-driven evidence.

    Run it in the background, lock/unlock the phone, and count the lines: one
    per real change, nothing periodic. `dnd` is printed when the phone reports
    it (docs/design/focus.md); an old build omits it.
    """
    deadline = time.time() + args.seconds
    count = 0
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during watch-state")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "state":
            count += 1
            dnd = "" if "dnd" not in msg else " dnd=%s" % json.dumps(msg.get("dnd"))
            print("%s state #%d locked=%s battery=%s charging=%s%s" % (
                time.strftime("%H:%M:%S"), count, msg.get("locked"),
                msg.get("battery"), msg.get("charging"), dnd))
    print("# %d state messages in %ss" % (count, args.seconds))
    return 0


def cmd_dnd(client, args):
    """Send `phone.dnd` and print the state the phone reports afterwards."""
    # The state that follows welcome (the phone's mode before this command) is
    # not the answer: drain whatever is queued, then the next state is the reply.
    while True:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed during dnd")
    client.send_json({"t": "phone.dnd", "mode": args.mode})
    print("sent phone.dnd mode=%s" % args.mode)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during dnd")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error: %s (%s)" % (msg.get("code"), msg.get("message")))
        if msg.get("t") == "state" and "dnd" in msg:
            print("state dnd=%s" % json.dumps(msg.get("dnd")))
            return 0
    raise DeckError("no state with dnd within %ss (an old phone omits it)" % args.wait)


def cmd_clip_set(client, args):
    """Send `clip.set` as the Mac: the phone's clipboard takes the text."""
    client.send_json({"t": "clip.set", "text": args.text})
    print("sent clip.set %s" % json.dumps(args.text, ensure_ascii=False))
    return 0


def cmd_notify(client, args):
    """Notifications as the Mac (docs/design/notify.md, part 2).

    `action`/`dismiss` opt in on their own session first (the gate is per
    session), so they work after an earlier `watch` saw the ids. Nothing here
    prints notification or reply text: ids, indexes and lengths only.
    """
    what = args.what
    if what == "enable":
        on = args.on == "on"
        client.send_json({"t": "notify.enable", "on": on})
        print("sent notify.enable on=%s" % ("true" if on else "false"))
        return 0
    if what in ("action", "dismiss"):
        if not args.id:
            raise DeckError("notify %s needs an ID" % what)
        client.send_json({"t": "notify.enable", "on": True})
        if what == "action":
            if args.index is None:
                raise DeckError("notify action needs ID and INDEX")
            text = args.text or ""
            msg = {"t": "notify.action", "id": args.id, "i": args.index}
            if text:
                msg["text"] = text
            client.send_json(msg)
            print("sent notify.action id=%s i=%d textLen=%d" % (args.id, args.index, len(text)))
        else:
            client.send_json({"t": "notify.dismiss", "id": args.id})
            print("sent notify.dismiss id=%s" % args.id)
        return 0
    if what in ("image", "live", "end"):
        if not args.id:
            raise DeckError("notify %s needs an ID" % what)
        client.send_json({"t": "notify.enable", "on": True})
        if what == "image":
            client.send_json({"t": "notify.fake", "kind": "image", "id": args.id})
            print("sent notify.fake image id=%s" % args.id)
        elif what == "live":
            msg = {"t": "notify.fake", "kind": "live", "id": args.id,
                   "progress": args.progress}
            if args.chip:
                msg["chip"] = args.chip
            client.send_json(msg)
            print("sent notify.fake live id=%s progress=%.2f chipLen=%d"
                  % (args.id, args.progress, len(args.chip or "")))
        else:
            client.send_json({"t": "notify.fake", "kind": "end", "id": args.id})
            print("sent notify.fake end id=%s" % args.id)
        return 0
    # watch: opt in, then print the phone's notification events (lengths only).
    client.send_json({"t": "notify.enable", "on": True})
    print("sent notify.enable on=true (watching %.0fs)" % args.seconds)
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during notify watch")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        t = msg.get("t")
        if t == "notify.post":
            title = msg.get("title") or ""
            text = msg.get("text") or ""
            actions = msg.get("actions") or []
            live = msg.get("live")
            print("notify.post id=%s pkg=%s titleLen=%d textLen=%d actions=%d ongoing=%s live=%s"
                  % (msg.get("id"), msg.get("pkg"), len(title), len(text), len(actions),
                     "true" if msg.get("ongoing") else "false",
                     "-" if not isinstance(live, dict) else
                     "progress=%s chipLen=%d chrono=%s"
                     % (live.get("progress"), len(live.get("chip") or ""),
                        "true" if live.get("chrono") else "false")), flush=True)
        elif t == "notify.image":
            data = msg.get("data") or ""
            print("notify.image id=%s mime=%s w=%s h=%s size=%d"
                  % (msg.get("id"), msg.get("mime"), msg.get("w"), msg.get("h"),
                     len(data) * 3 // 4), flush=True)
        elif t == "notify.remove":
            print("notify.remove id=%s" % msg.get("id"), flush=True)
        elif t == "notify.state":
            print("notify.state on=%s" % ("true" if msg.get("on") else "false"), flush=True)
    return 0


def cmd_ring(client, args):
    """Send `phone.ring` (or stop it) and print the phone's ring.state answer."""
    if args.stop:
        client.send_json({"t": "phone.ring.stop"})
        print("sent phone.ring.stop")
    else:
        client.send_json({"t": "phone.ring", "seconds": args.seconds})
        print("sent phone.ring seconds=%d" % args.seconds)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during ring")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error: %s (%s)" % (msg.get("code"), msg.get("message")))
        if msg.get("t") == "ring.state":
            print("ring.state ringing=%s" % json.dumps(msg.get("ringing")))
            return 0
    raise DeckError("no ring.state within %ss" % args.wait)


def cmd_clip_watch(client, args):
    """Print every `clip.set` the phone sends, for `--seconds`."""
    deadline = time.time() + args.seconds
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during clip-watch")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "clip.set":
            print("%s clip.set %s" % (time.strftime("%H:%M:%S"),
                                      json.dumps(msg.get("text"), ensure_ascii=False)))
    return 0


def cmd_latency(client, args):
    samples = []
    for i in range(args.count):
        started = time.perf_counter()
        client.send_json({"t": "ping", "ts": i})
        while True:
            frame = client.recv(DEFAULT_TIMEOUT)
            if frame is TIMEOUT:
                raise DeckError("ping %d timed out" % i)
            if frame is None:
                raise DeckError("phone closed during latency test")
            if frame.type != proto.TYPE_JSON:
                raise proto.ProtocolError("unexpected %s frame during latency test" % frame.name)
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone error %s" % msg.get("code"))
            if msg.get("t") == "pong" and msg.get("ts") == i:
                break
        samples.append((time.perf_counter() - started) * 1000.0)
    samples.sort()

    def pct(p):
        idx = min(len(samples) - 1, int(round((p / 100.0) * (len(samples) - 1))))
        return samples[idx]

    print("latency n=%d p50=%.2fms p95=%.2fms min=%.2fms max=%.2fms" %
          (len(samples), pct(50), pct(95), samples[0], samples[-1]))
    return 0


def cmd_probe(client, args):
    """Open a window, run a step script, record one phase file per step."""
    stream = 1
    prefix = args.out_prefix or "/tmp/deckctl-probe"
    steps = [_parse_step(s) for s in (args.steps or "").split(";") if s.strip()]
    rec = StreamRecorder(client).start()
    request = {"t": "window.open", "stream": stream, "w": args.w, "h": args.h, "dpi": args.dpi}
    if args.phone:
        request["mode"] = "phone"
    else:
        request["pkg"] = args.target
    client.send_json(request)
    size = rec.wait_for_size(stream, 25.0)
    opened = rec.opened.get(stream, {})
    # A phone-mode stream is mirrored into the box at the screen's aspect (the
    # phone floors it to 16 px), so its size is the one the phone announced.
    if args.phone and opened.get("w") and opened.get("h"):
        want = (int(opened["w"]), int(opened["h"]))
    else:
        want = (round16(args.w), round16(args.h))
    if size != want:
        raise proto.ProtocolError("VIDEO_CONFIG is %dx%d, expected %dx%d" % (size[0], size[1], want[0], want[1]))
    print("stream=%d size=%dx%d displayId=%s" % (stream, size[0], size[1], opened.get("displayId")))

    def run_phase(name, action, duration=None):
        path = "%s-%s.h264" % (prefix, name)
        png = "%s-%s.png" % (prefix, name)
        seen_before = rec.total_frames.get(stream, 0)
        rec.begin_phase(stream, path)
        # Ask for an IDR first: the next frame the app redraws becomes the phase
        # file's opening keyframe. A fully static screen emits nothing, so this
        # is not a gate - the action below must not be blocked on it.
        client.send_json({"t": "window.keyframe", "stream": stream})
        time.sleep(args.settle)
        if action is not None:
            action()
            # The redraw the action causes (if any) carries the requested IDR.
            try:
                rec.wait_for_key(stream, args.key_wait)
            except DeckError:
                pass
        time.sleep(args.phase_seconds if duration is None else duration)
        frames = rec.end_phase(stream)
        seen = rec.total_frames.get(stream, 0) - seen_before
        if frames > 0:
            dump_last_frame(path, png)
        else:
            png = "(no frames - screen did not redraw)"
        print("phase %-10s written=%3d seen=%3d png=%s" % (name, frames, seen, png))
        if frames == 0 and name == "base":
            raise proto.ProtocolError("phase %s recorded no video frames" % name)
        return frames

    run_phase("base", None)
    for i, (kind, arg) in enumerate(steps):
        if kind == "wait":
            run_phase("wait%d" % i, None, duration=float(arg))
        else:
            print("step %d: %s" % (i, _describe_step(kind, arg)))
            run_phase("%02d-%s" % (i, kind),
                      lambda kind=kind, arg=arg: _send_step(client, stream, kind, arg))
    client.send_json({"t": "window.close", "stream": stream})
    time.sleep(0.5)
    rec.stop()
    return 0


def _describe_step(kind, arg):
    if kind == "tap":
        return "tap at %s (normalized)" % arg
    if kind == "scroll":
        return "scroll v=%s" % arg
    if kind == "text":
        return "text %r" % arg
    return kind


def _parse_resize(spec):
    stream, _, size = spec.partition(":")
    w, _, h = size.lower().partition("x")
    return int(stream), (round16(int(w)), round16(int(h)))


def cmd_multi(client, args):
    """Two windows in one session; every phase records both streams.

    Phases: p1 (both opened at --w/--h), p2 (only if a --resizeN is given: both
    streams after the resize, each checked against its new CONFIG), then one
    phase per step in --steps (stream 1) and --steps2 (stream 2).
    """
    pkg1, pkg2 = args.apps[0], args.apps[1]
    prefix = args.out_prefix or "/tmp/deckctl-multi"
    steps1 = [_parse_step(s) for s in (args.steps or "").split(";") if s.strip()]
    steps2 = [_parse_step(s) for s in (args.steps2 or "").split(";") if s.strip()]
    resizes = {}
    if args.resize1:
        resizes[1] = _parse_resize("1:" + args.resize1)[1]
    if args.resize2:
        resizes[2] = _parse_resize("2:" + args.resize2)[1]
    rec = StreamRecorder(client).start()
    for stream, pkg in ((1, pkg1), (2, pkg2)):
        client.send_json({"t": "window.open", "stream": stream,
                          "w": args.w, "h": args.h, "dpi": args.dpi, "pkg": pkg})
    size1 = rec.wait_for_size(1, 25.0)
    size2 = rec.wait_for_size(2, 25.0)
    want = (round16(args.w), round16(args.h))
    for stream, size in ((1, size1), (2, size2)):
        if size != want:
            raise proto.ProtocolError("stream %d CONFIG is %dx%d, expected %dx%d" %
                                      (stream, size[0], size[1], want[0], want[1]))
    id1 = rec.opened.get(1, {}).get("displayId")
    id2 = rec.opened.get(2, {}).get("displayId")
    if id1 == id2:
        raise proto.ProtocolError("both windows report displayId=%s" % id1)
    print("stream1 pkg=%s displayId=%s size=%dx%d" % (pkg1, id1, size1[0], size1[1]))
    print("stream2 pkg=%s displayId=%s size=%dx%d" % (pkg2, id2, size2[0], size2[1]))

    def run_phase(name, step=None, target_stream=0, resized=None, gate=False):
        for stream in (1, 2):
            rec.begin_phase(stream, "%s-s%d-%s.h264" % (prefix, stream, name))
        for stream in (1, 2):
            client.send_json({"t": "window.keyframe", "stream": stream})
        time.sleep(args.settle)
        desc = "none"
        if resized:
            for stream, (w, h) in sorted(resized.items()):
                client.send_json({"t": "window.resize", "stream": stream,
                                  "w": w, "h": h, "dpi": args.dpi})
            for stream, size in sorted(resized.items()):
                got = rec.wait_for_size(stream, args.key_wait + 20.0, want=size)
                desc = "resize stream%d -> %dx%d" % (stream, got[0], got[1])
        if step is not None:
            desc = _send_step(client, target_stream, *step)
        for stream in (1, 2):
            try:
                rec.wait_for_key(stream, args.key_wait)
            except DeckError:
                pass
        time.sleep(args.phase_seconds)
        for stream in (1, 2):
            path = "%s-s%d-%s.h264" % (prefix, stream, name)
            png = "%s-s%d-%s.png" % (prefix, stream, name)
            frames = rec.end_phase(stream)
            if frames > 0:
                dump_last_frame(path, png)
            else:
                png = "(no frames - screen did not redraw)"
            print("phase %-10s stream%d frames=%3d action=%s png=%s" % (name, stream, frames, desc, png))
            if gate and frames == 0:
                raise proto.ProtocolError("stream %d rendered no frames in phase %s" % (stream, name))

    run_phase("p1", gate=True)
    if resizes:
        run_phase("p2-resized", resized=resizes, gate=True)
    for i, step in enumerate(steps1):
        run_phase("s1-%02d-%s" % (i, step[0]), step, 1)
    for i, step in enumerate(steps2):
        run_phase("s2-%02d-%s" % (i, step[0]), step, 2)
    for stream in (1, 2):
        client.send_json({"t": "window.close", "stream": stream})
    time.sleep(0.5)
    rec.stop()
    return 0

def _png_size(path):
    with open(path, "rb") as fp:
        head = fp.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise DeckError("%s is not a PNG" % path)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def _stream_size_ok(got, want):
    """The phone may shrink a request to what its encoder takes: never larger,
    16-aligned, and the same shape within 10%."""
    if got is None or got[0] > want[0] or got[1] > want[1] or got[0] % 16 or got[1] % 16:
        return False
    return abs((got[0] / float(got[1])) / (want[0] / float(want[1])) - 1.0) < 0.10


def cmd_resize_stress(client, args):
    """Resize each app's window repeatedly across several sizes.

    Every resize must deliver a VIDEO_CONFIG of the new size and a decodable
    frame of that size within --deadline seconds, even when the app is idle
    (PROTOCOL.md: a resize is always answered with CONFIG + keyframe). One PNG
    per resize is written next to --out-prefix and its pixel size is checked.
    """
    sizes = [_parse_resize("1:" + spec)[1] for spec in args.sizes]
    if len(set(sizes)) < 2:
        raise DeckError("--sizes needs at least two distinct sizes")
    prefix = args.out_prefix or "/tmp/deckctl-stress"
    rec = StreamRecorder(client).start()
    results = []
    try:
        for index, pkg in enumerate(args.apps):
            stream = index + 1
            client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                              "dpi": args.dpi, "pkg": pkg})
            rec.wait_for_size(stream, 25.0)
            deadline = time.time() + 25.0
            while stream not in rec.first_frame_at and time.time() < deadline:
                rec.raise_if_broken("waiting for the first frame")
                time.sleep(0.05)
            if stream not in rec.first_frame_at:
                raise DeckError("%s: no frame after window.open" % pkg)
            time.sleep(args.launch_settle)
            current = rec.sizes[stream]
            for i in range(args.resizes):
                size = sizes[i % len(sizes)]
                if size == current:
                    size = sizes[(i + 1) % len(sizes)]
                tag = "%s-%02d-%dx%d" % (pkg.replace(".", "_"), i, size[0], size[1])
                path = "%s-%s.h264" % (prefix, tag)
                png = "%s-%s.png" % (prefix, tag)
                rec.begin_phase(stream, path)
                started = time.time()
                client.send_json({"t": "window.resize", "stream": stream,
                                  "w": size[0], "h": size[1], "dpi": args.dpi})
                give_up = started + args.deadline + args.grace
                while time.time() < give_up:
                    rec.raise_if_broken("waiting for the resized frame")
                    with rec.lock:
                        arrived = (_stream_size_ok(rec.sizes.get(stream), size)
                                   and rec.config_at.get(stream, 0) >= started
                                   and stream in rec.first_frame_at)
                    if arrived:
                        break
                    time.sleep(0.005)
                with rec.lock:
                    got_size = rec.sizes.get(stream)
                    fresh = rec.config_at.get(stream, 0) >= started
                    config_ms = (rec.config_at.get(stream, started) - started) * 1000.0
                    first = rec.first_frame_at.get(stream)
                got_ok = fresh and _stream_size_ok(got_size, size)
                frame_ms = (first[0] - started) * 1000.0 if first and got_ok else None
                time.sleep(args.settle)
                rec.end_phase(stream)
                decoded = None
                if frame_ms is not None:
                    try:
                        dump_last_frame(path, png)
                        decoded = _png_size(png)
                    except DeckError:
                        decoded = None
                key = bool(first and first[1] and frame_ms is not None)
                ok = (frame_ms is not None and frame_ms <= args.deadline * 1000.0
                      and key and decoded == got_size)
                results.append(ok)
                print("%-4s %-28s %2d -> %dx%d got=%s config=%s frame=%s key=%s png=%s" % (
                    "PASS" if ok else "FAIL", pkg, i, size[0], size[1],
                    ("%dx%d" % got_size) if got_ok else "-",
                    ("%.0fms" % config_ms) if got_ok else "none",
                    ("%.0fms" % frame_ms) if frame_ms is not None else "none",
                    key if frame_ms is not None else "-",
                    ("%dx%d" % decoded) if decoded else "-"))
                current = got_size if got_ok else current
                time.sleep(args.gap)
            client.send_json({"t": "window.close", "stream": stream})
            time.sleep(0.5)
    finally:
        rec.stop()
    failed = results.count(False)
    print("resize-stress: %d resizes, %d passed, %d failed" % (len(results), len(results) - failed, failed))
    return 1 if failed else 0


def cmd_exit_test(client, args):
    """Back out of the app until it leaves its display; require app_exited."""
    stream = 1
    rec = StreamRecorder(client).start()
    client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                      "dpi": args.dpi, "pkg": args.target})
    rec.wait_for_size(stream, 25.0)
    print("opened %s displayId=%s" % (args.target, rec.opened.get(stream, {}).get("displayId")))
    time.sleep(args.launch_settle)
    for i in range(args.backs):
        if rec.closed_reason.get(stream) is not None:
            break
        client.send_json({"t": "nav", "stream": stream, "action": "back"})
        print("nav back %d" % (i + 1))
        deadline = time.time() + args.interval
        while time.time() < deadline and rec.closed_reason.get(stream) is None:
            rec.raise_if_broken("waiting for window.closed")
            time.sleep(0.1)
    reason = rec.closed_reason.get(stream)
    if reason is None:
        raise DeckError("no window.closed after %d backs (frames seen: %d)" %
                        (args.backs, rec.total_frames.get(stream, 0)))
    print("window.closed stream=%d reason=%s frames=%d" % (stream, reason, rec.total_frames.get(stream, 0)))
    rec.stop()
    if reason != "app_exited":
        raise DeckError("expected reason app_exited, got %r" % reason)
    return 0


def cmd_frame_png(_client, args):
    """Decode a frame from a recorded raw H.264 file to PNG (no session)."""
    if not os.path.exists(args.file):
        raise DeckError("no such file: %s" % args.file)
    if args.at is None:
        dump_last_frame(args.file, args.out)
        print("frame-png: last frame of %s -> %s" % (args.file, args.out))
    else:
        ffmpeg_run(["ffmpeg", "-loglevel", "error", "-y", "-i", args.file,
                    "-ss", str(args.at), "-frames:v", "1", "-update", "1", args.out])
        print("frame-png: frame at %ss of %s -> %s" % (args.at, args.file, args.out))
    return 0


# --- CLI -------------------------------------------------------------------
def make_code_sink(args):
    """Pairing is on with --pair or --code-file; the shown code goes to stderr
    (and to --code-file, for a helper that taps Allow on the phone)."""
    if not args.pair and not args.code_file:
        return None

    def sink(code):
        sys.stderr.write("deckctl: phone shows code %s; tap Allow on the phone\n" % code)
        sys.stderr.flush()
        if args.code_file:
            with open(args.code_file, "w") as fp:
                fp.write(code + "\n")

    return sink


def _fs_id():
    return random.SystemRandom().randint(1, 0xFFFFFFFF)


def _fs_wait(client, fs_id, timeout=90.0):
    """Next JSON reply for [fs_id]; FS_DATA-only frames are not JSON."""
    while True:
        frame = client.recv(timeout)
        if frame is TIMEOUT:
            raise DeckError("no answer for fs id %d (timeout)" % fs_id)
        if frame is None:
            raise DeckError("phone closed the connection during fs id %d" % fs_id)
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("id") != fs_id:
            continue
        if msg.get("t") == "error":
            raise DeckError("fs error: %s (%s)" % (msg.get("code"), msg.get("message", "")))
        return msg


def _fs_list_all(client, path):
    """Every page of one listing, following the phone's cursor."""
    fs_id = _fs_id()
    items = []
    page = None
    while True:
        request = {"t": "fs.list", "id": fs_id, "path": path}
        if page is not None:
            request["page"] = page
        client.send_json(request)
        msg = _fs_wait(client, fs_id)
        if msg.get("t") != "fs.items":
            raise DeckError("expected fs.items, got %r" % msg.get("t"))
        items.extend(msg.get("items") or [])
        page = msg.get("page")
        if page is None:
            return items


def _fs_result(client, request, timeout=120.0):
    """Sends one fs.* write-side request and prints the fs.result."""
    fs_id = request["id"]
    client.send_json(request)
    while True:
        frame = client.recv(timeout)
        if frame is TIMEOUT:
            raise DeckError("fs.%s timed out" % request.get("t"))
        if frame is None:
            raise DeckError("phone closed the connection during %s" % request.get("t"))
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("id") != fs_id:
            continue
        if msg.get("t") == "error":
            raise DeckError("fs error: %s (%s)" % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") != "fs.result":
            continue
        print(json.dumps(msg, indent=None, separators=(",", ":"), sort_keys=True))
        if not msg.get("ok"):
            return 1
        return 0


def _fs_write(client, path, local):
    with open(local, "rb") as handle:
        data = handle.read()
    digest = hashlib.sha256(data).hexdigest()
    fs_id = _fs_id()
    request = {"t": "fs.write", "id": fs_id, "path": path,
               "size": len(data), "sha256": digest}
    client.send_json(request)
    sent = 0
    while sent < len(data):
        payload = data[sent:sent + 256 * 1024]
        client.send_raw(proto.pack_frame(proto.TYPE_FS_DATA, fs_id, payload))
        sent += len(payload)
    while True:
        frame = client.recv(180.0)
        if frame is TIMEOUT:
            raise DeckError("fs.write timed out after %d bytes" % sent)
        if frame is None:
            raise DeckError("phone closed the connection during fs.write")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("id") != fs_id:
            continue
        if msg.get("t") == "error":
            raise DeckError("fs error: %s (%s)" % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") != "fs.result":
            continue
        print(json.dumps(msg, indent=None, separators=(",", ":"), sort_keys=True))
        return 0 if msg.get("ok") else 1


def cmd_fs(client, args):
    """Phone files (docs/PROTOCOL.md "Phone files"): list/stat/read and the
    write side (write/mkdir/move/delete/setattrs)."""
    if args.action == "write":
        return _fs_write(client, args.path, args.out)
    if args.action == "mkdir":
        return _fs_result(client, {"t": "fs.mkdir", "id": _fs_id(), "path": args.path})
    if args.action == "move":
        request = {"t": "fs.move", "id": _fs_id(), "from": args.path, "to": args.to}
        if args.etag:
            request["etag"] = args.etag
        return _fs_result(client, request)
    if args.action == "delete":
        return _fs_result(client, {"t": "fs.delete", "id": _fs_id(), "path": args.path,
                                   "recursive": bool(args.recursive)})
    if args.action == "setattrs":
        return _fs_result(client, {"t": "fs.setAttrs", "id": _fs_id(), "path": args.path,
                                   "mtime": args.mtime})
    if args.action in ("watch", "unwatch"):
        paths = list(args.paths or ([args.path] if args.path else []))
        request = {"t": "fs.watch" if args.action == "watch" else "fs.unwatch",
                   "id": _fs_id(), "paths": paths}
        rc = _fs_result(client, request)
        print("watch ok" if args.action == "watch" and rc == 0 else "unwatch ok")
        if rc != 0 or not args.hold:
            return rc
        # Keep the session open so the watch lives: print each coalesced batch
        # (counts only), optionally unwatch part-way and report anything after.
        deadline = time.time() + args.hold
        off_at = time.time() + args.off_after if args.off_after else None
        off = False
        while True:
            now = time.time()
            if off_at is not None and now >= off_at:
                _fs_result(client, {"t": "fs.unwatch", "id": _fs_id(), "paths": paths})
                print("watch off")
                sys.stdout.flush()
                off_at = None
                off = True
            if now >= deadline:
                break
            frame = client.recv(min(0.2, max(0.05, deadline - now)))
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed the connection while watching")
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            if msg.get("t") == "fs.changes":
                print("%s %d" % ("change after-off" if off else "change",
                                 len(msg.get("paths") or [])))
                sys.stdout.flush()
        return 0
    if args.action == "changes":
        # The next coalesced fs.changes; printed as a count (no names).
        deadline = time.time() + (args.timeout or 10.0)
        while time.time() < deadline:
            frame = client.recv(max(0.1, deadline - time.time()))
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed the connection")
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            if msg.get("t") == "fs.changes":
                print("changes %d" % len(msg.get("paths") or []))
                return 0
        raise DeckError("no fs.changes within %ss" % (args.timeout or 10.0))
    if args.action == "list":
        items = _fs_list_all(client, args.path)
        print(json.dumps(items, indent=None, separators=(",", ":"), sort_keys=True))
        return 0
    if args.action == "stat":
        fs_id = _fs_id()
        client.send_json({"t": "fs.stat", "id": fs_id, "path": args.path})
        msg = _fs_wait(client, fs_id)
        if msg.get("t") != "fs.item":
            raise DeckError("expected fs.item, got %r" % msg.get("t"))
        print(json.dumps(msg.get("item") or {}, indent=None, separators=(",", ":"), sort_keys=True))
        return 0
    # read
    length = args.length
    if length is None:
        stat_id = _fs_id()
        client.send_json({"t": "fs.stat", "id": stat_id, "path": args.path})
        item = _fs_wait(client, stat_id).get("item") or {}
        length = int(item.get("size", 0)) - args.offset
        if length < 0:
            raise DeckError("offset is past the end of the file")
    fs_id = _fs_id()
    request = {"t": "fs.read", "id": fs_id, "path": args.path,
               "offset": args.offset, "length": length}
    if args.etag:
        request["etag"] = args.etag
    client.send_json(request)
    digest = hashlib.sha256()
    got = 0
    with open(args.out, "wb") as handle:
        while True:
            frame = client.recv(60.0)
            if frame is TIMEOUT:
                raise DeckError("fs.read timed out after %d bytes" % got)
            if frame is None:
                raise DeckError("phone closed the connection during fs.read")
            if frame.type == proto.TYPE_FS_DATA:
                if frame.stream != fs_id:
                    continue
                handle.write(frame.payload)
                digest.update(frame.payload)
                got += len(frame.payload)
                continue
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            if msg.get("id") != fs_id:
                continue
            if msg.get("t") == "error":
                raise DeckError("fs error: %s (%s)" % (msg.get("code"), msg.get("message", "")))
            if msg.get("t") != "fs.read.end":
                continue
            want = digest.hexdigest()
            if msg.get("size") != got or msg.get("sha256") != want:
                raise DeckError("fs.read.end disagrees: size %r/%d, sha %r/%s"
                                % (msg.get("size"), got, msg.get("sha256"), want))
            print(json.dumps({"bytes": got, "sha256": want}))
            return 0


def build_parser():
    p = argparse.ArgumentParser(description="Fake Mac client / conformance tester for PocketDeck.",
                                allow_abbrev=False)
    p.add_argument("--host", help="phone host")
    p.add_argument("--port", type=int, help="phone port")
    p.add_argument("--discover", action="store_true", help="find the phone over mDNS")
    p.add_argument("--instance", help="mDNS instance name to use with --discover")
    p.add_argument("--pair", action="store_true",
                   help="pair when no stored key works: print the code the phone shows and wait for Allow")
    p.add_argument("--code-file", help="like --pair, and also write the code the phone shows to this file")
    p.add_argument("--state", default=DEFAULT_STATE, help="state file (default: %(default)s)")
    p.add_argument("--name", help="client name sent in hello")
    p.add_argument("--wait-for-free", type=float, default=0.0, metavar="SECONDS",
                   help="retry while another session is active, up to this long "
                        "(default: fail immediately with 'busy')")

    spp = {"allow_abbrev": False}
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("apps", help="list launchable apps", **spp)

    sp = sub.add_parser("icon", help="fetch an app icon PNG", **spp)
    sp.add_argument("pkg")
    sp.add_argument("--out", required=True, help="write the PNG here")

    sp = sub.add_parser("open", help="open a window and record video", **spp)
    sp.add_argument("target", nargs="?", help="package to launch")
    sp.add_argument("--phone", action="store_true", help="phone mode instead of an app")
    sp.add_argument("--url", help="open this link (link.open) instead of an app")
    sp.add_argument("--w", type=int, required=True)
    sp.add_argument("--h", type=int, required=True)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--seconds", type=float, default=3.0)
    sp.add_argument("--out", help="write raw Annex-B H.264 here")

    sp = sub.add_parser("resize-test", help="open, resize, check new CONFIG + keyframe", **spp)
    sp.add_argument("--w", type=int, default=1080)
    sp.add_argument("--h", type=int, default=2340)
    sp.add_argument("--w2", type=int, default=720)
    sp.add_argument("--h2", type=int, default=1280)
    sp.add_argument("--dpi", type=int, default=450)

    sp = sub.add_parser("input-test", help="open and send touch/scroll/key input", **spp)
    sp.add_argument("--w", type=int, default=1080)
    sp.add_argument("--h", type=int, default=2340)
    sp.add_argument("--dpi", type=int, default=450)

    sp = sub.add_parser("pause-test", help="open, pause, resume", **spp)
    sp.add_argument("--w", type=int, default=1080)
    sp.add_argument("--h", type=int, default=2340)
    sp.add_argument("--dpi", type=int, default=450)

    sp = sub.add_parser("latency", help="ping round-trip latency", **spp)
    sp.add_argument("--count", type=int, default=20)

    sp = sub.add_parser("quality-test", help="live window.quality + socket stall; per-phase frame stats", **spp)
    sp.add_argument("target", nargs="?", help="package to launch")
    sp.add_argument("--phone", action="store_true", help="phone mode instead of an app")
    sp.add_argument("--w", type=int, required=True)
    sp.add_argument("--h", type=int, required=True)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--warmup-seconds", type=float, default=6.0,
                    help="read (and discard) frames until the app has settled")
    sp.add_argument("--base-seconds", type=float, default=3.0, help="unmodified baseline phase")
    sp.add_argument("--seconds", type=float, default=4.0,
                    help="phase after window.quality (0 skips the message)")
    sp.add_argument("--quality-bps", type=int, default=1000000)
    sp.add_argument("--quality-fps", type=int, default=30)
    sp.add_argument("--stall", type=float, default=2.5, help="seconds without reading the socket")
    sp.add_argument("--stall-bps", type=int, default=0,
                    help="bitrate target to request just before the stall (0 = keep the current one)")
    sp.add_argument("--recover-seconds", type=float, default=6.0)
    sp.add_argument("--cap-seconds", type=float, default=0.0,
                    help="final phase: set --cap-fps and measure the frames that still arrive")
    sp.add_argument("--cap-fps", type=int, default=1,
                    help="fps cap for the final phase (frames above it are dropped)")
    sp.add_argument("--motion", type=float, default=6.0,
                    help="scroll magnitude / fling switch injected to keep frames flowing (0 = off)")
    sp.add_argument("--motion-mode", choices=("scroll", "drag"), default="scroll",
                    help="scroll: wheel bursts; drag: synthetic fling (animates a static list)")
    sp.add_argument("--scroll-every", type=float, default=0.5)
    sp.add_argument("--report-every", type=float, default=30.0, help="progress line interval (0 = off)")
    sp.add_argument("--rcvbuf", type=int, default=32768, help="client receive buffer during the test")
    sp.add_argument("--out", help="write the whole run's raw Annex-B H.264 here")

    sp = sub.add_parser("watch-state", help="print every state message; lock/unlock while it runs", **spp)
    sp.add_argument("--seconds", type=float, default=30.0)

    sp = sub.add_parser("dnd", help="phone.dnd: set the phone's DND, print the state",
                        **spp)
    sp.add_argument("mode", choices=["priority", "alarms", "none", "off"])
    sp.add_argument("--wait", type=float, default=10.0,
                    help="seconds to wait for a state carrying dnd")

    sp = sub.add_parser("clip-set", help="send clip.set TEXT: put TEXT on the phone's clipboard", **spp)
    sp.add_argument("text")

    sp = sub.add_parser("ring", help="phone.ring: ring the phone (or --stop), print ring.state", **spp)
    sp.add_argument("--seconds", type=int, default=30, help="ring for 1..30 s (default 30)")
    sp.add_argument("--stop", action="store_true", help="send phone.ring.stop instead")
    sp.add_argument("--wait", type=float, default=10.0, help="seconds to wait for ring.state")

    sp = sub.add_parser("clip-watch", help="print every clip.set the phone sends", **spp)
    sp.add_argument("--seconds", type=float, default=30.0)

    sp = sub.add_parser("notify", help="notifications: enable/action/dismiss/watch/image/live/end (ids and lengths only)", **spp)
    sp.add_argument("what", choices=["enable", "action", "dismiss", "watch", "image", "live", "end"])
    sp.add_argument("id", nargs="?")
    sp.add_argument("index", nargs="?", type=int)
    sp.add_argument("--text", default="", help="reply text for notify action (never printed)")
    sp.add_argument("--on", choices=["on", "off"], default="on")
    sp.add_argument("--seconds", type=float, default=20.0)
    sp.add_argument("--progress", type=float, default=0.5, help="live update fraction 0..1")
    sp.add_argument("--chip", default=None, help="live update chip text (length only is printed)")

    sp = sub.add_parser("probe", help="open, run steps, record one phase file per step", **spp)
    sp.add_argument("target", nargs="?", help="package to launch")
    sp.add_argument("--phone", action="store_true", help="phone mode instead of an app")
    sp.add_argument("--w", type=int, required=True)
    sp.add_argument("--h", type=int, required=True)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--steps", default="",
                    help="';'-separated: tap:NX,NY / scroll:V / text:STR / back / key:CODE / wait:S")
    sp.add_argument("--out-prefix", default="/tmp/deckctl-probe")
    sp.add_argument("--phase-seconds", type=float, default=2.0)
    sp.add_argument("--settle", type=float, default=0.5)
    sp.add_argument("--key-wait", type=float, default=4.0, help="max wait for the requested IDR")

    sp = sub.add_parser("multi", help="two windows in one session with independent input", **spp)
    sp.add_argument("--apps", nargs=2, required=True, metavar=("PKG1", "PKG2"))
    sp.add_argument("--w", type=int, required=True)
    sp.add_argument("--h", type=int, required=True)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--steps", default="", help="';'-separated steps for stream 1")
    sp.add_argument("--steps2", default="", help="';'-separated steps for stream 2")
    sp.add_argument("--resize1", metavar="WxH", help="resize stream 1 after the base phase")
    sp.add_argument("--resize2", metavar="WxH", help="resize stream 2 after the base phase")
    sp.add_argument("--out-prefix", default="/tmp/deckctl-multi")
    sp.add_argument("--phase-seconds", type=float, default=2.0)
    sp.add_argument("--settle", type=float, default=0.5)
    sp.add_argument("--key-wait", type=float, default=4.0, help="max wait for the requested IDR")

    sp = sub.add_parser("resize-stress", help="resize apps repeatedly; every resize needs a new-size frame in time", **spp)
    sp.add_argument("--apps", nargs="+", required=True, metavar="PKG")
    sp.add_argument("--w", type=int, default=1792)
    sp.add_argument("--h", type=int, default=1200)
    sp.add_argument("--dpi", type=int, default=320)
    sp.add_argument("--sizes", nargs="+", default=["1280x800", "2320x1200", "1024x1200", "2080x1200", "1600x900"],
                    metavar="WxH")
    sp.add_argument("--resizes", type=int, default=20, help="resizes per app")
    sp.add_argument("--deadline", type=float, default=1.0, help="max seconds from window.resize to a frame")
    sp.add_argument("--grace", type=float, default=4.0, help="extra wait so a late frame is reported, not just missing")
    sp.add_argument("--gap", type=float, default=0.5, help="idle seconds between resizes")
    sp.add_argument("--settle", type=float, default=0.3, help="seconds recorded after the first frame")
    sp.add_argument("--launch-settle", type=float, default=2.0)
    sp.add_argument("--out-prefix", default="/tmp/deckctl-stress")

    sp = sub.add_parser("exit-test", help="back out of the app; require app_exited", **spp)
    sp.add_argument("target")
    sp.add_argument("--w", type=int, default=1080)
    sp.add_argument("--h", type=int, default=2340)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--backs", type=int, default=5)
    sp.add_argument("--interval", type=float, default=2.5)
    sp.add_argument("--launch-settle", type=float, default=2.0)

    sp = sub.add_parser("fs", help="phone files: list/stat/read/write/mkdir/move/delete/setattrs (docs/PROTOCOL.md)", **spp)
    sp.add_argument("action", choices=["list", "stat", "read", "write", "mkdir", "move",
                                       "delete", "setattrs", "watch", "unwatch", "changes"])
    sp.add_argument("path", nargs="?", help="path relative to the phone's shared storage ('' = the root)")
    sp.add_argument("out", nargs="?", help="read: write the range here; write: the local file")
    sp.add_argument("--to", help="move: the destination path")
    sp.add_argument("--recursive", action="store_true", help="delete: a whole folder")
    sp.add_argument("--mtime", type=int, help="setattrs: milliseconds since the epoch")
    sp.add_argument("--offset", type=int, default=0, help="read: first byte (default 0)")
    sp.add_argument("--length", type=int, default=None, help="read: byte count (default: offset..EOF via stat)")
    sp.add_argument("--etag", help="read: the version the Mac believes (fs_stale on mismatch)")
    sp.add_argument("--paths", nargs="+", help="watch/unwatch: the folders (relative)")
    sp.add_argument("--timeout", type=float, default=10.0,
                    help="changes: seconds to wait for a change (default 10)")
    sp.add_argument("--hold", type=float, default=0.0,
                    help="watch: keep the session open this many seconds and print each change")
    sp.add_argument("--off-after", type=float, default=0.0,
                    help="watch --hold: unwatch this many seconds in, report what comes after")

    sp = sub.add_parser("cam", help="camera: list/start/stop; frames, keyframes and states only "
                                    "(docs/PROTOCOL.md \"Camera\")", **spp)
    sp.add_argument("action", choices=["list", "start", "stop"])
    sp.add_argument("--stream", type=int, default=7, help="the camera stream id (default 7)")
    sp.add_argument("--id", dest="camera_id", help="a camera id from cam.list")
    sp.add_argument("--facing", choices=["back", "front"])
    sp.add_argument("--w", type=int)
    sp.add_argument("--h", type=int)
    sp.add_argument("--fps", type=int)
    sp.add_argument("--seconds", type=float, default=3.0, help="start: measure this long")
    sp.add_argument("--wait", type=float, default=10.0,
                    help="start/stop: seconds to wait for the state (start: also the "
                         "window in which a terminal state is still read)")
    sp.add_argument("--busy-stream", type=int, default=None, metavar="STREAM",
                    help="start: also ask for a second capture there (expect busy)")
    sp.add_argument("--save-h264", help="start: write the received Annex-B here (no decoding)")
    sp.add_argument("--await-terminal", action="store_true",
                    help="start: after measuring, keep reading until a terminal state "
                         "(eviction) or --wait expires")
    sp.add_argument("--after-terminal-wait", type=float, default=1.0, metavar="SECONDS",
                    help="start: after a terminal state (evicted/off/...), keep reading "
                         "this long and count anything that still arrives")

    sp = sub.add_parser("frame-png", help="decode a frame of a recorded .h264 to PNG (no session)", **spp)
    sp.add_argument("file")
    sp.add_argument("--out", required=True)
    sp.add_argument("--at", type=float, default=None, help="seconds into the file (default: last frame)")
    return p


COMMANDS = {
    "apps": cmd_apps,
    "icon": cmd_icon,
    "open": cmd_open,
    "resize-test": cmd_resize_test,
    "input-test": cmd_input_test,
    "pause-test": cmd_pause_test,
    "latency": cmd_latency,
    "quality-test": cmd_quality_test,
    "watch-state": cmd_watch_state,
    "dnd": cmd_dnd,
    "ring": cmd_ring,
    "clip-set": cmd_clip_set,
    "clip-watch": cmd_clip_watch,
    "notify": cmd_notify,
    "probe": cmd_probe,
    "multi": cmd_multi,
    "resize-stress": cmd_resize_stress,
    "exit-test": cmd_exit_test,
    "fs": cmd_fs,
    "cam": cmd_cam,
    "frame-png": cmd_frame_png,
}


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "open" and not args.phone and not args.target and not args.url:
        sys.stderr.write("deckctl: error: open needs a package, --phone or --url\n")
        return 2
    if args.command == "probe" and not args.phone and not args.target:
        sys.stderr.write("deckctl: error: probe needs a package or --phone\n")
        return 2
    if args.command == "quality-test" and not args.phone and not args.target:
        sys.stderr.write("deckctl: error: quality-test needs a package or --phone\n")
        return 2
    if args.command == "frame-png":
        try:
            return cmd_frame_png(None, args)
        except (DeckError, proto.ProtocolError) as exc:
            sys.stderr.write("deckctl: error: %s\n" % exc)
            return 2

    # Make sure a SIGTERM/SIGINT unwinds `finally` blocks (closing the socket
    # and any dns-sd child) instead of leaving orphans.
    def _terminate(_signum, _frame):
        raise SystemExit(1)

    signal.signal(signal.SIGTERM, _terminate)
    state = ClientState(args.state)
    device_hint = None
    try:
        if args.discover:
            host, port, device_hint = discover(instance_name=args.instance)
        else:
            if not args.host or not args.port:
                raise DeckError("need --host and --port, or --discover")
            host, port = args.host, args.port
        client = open_session(host, port, state,
                              on_code=make_code_sink(args), device_hint=device_hint,
                              busy_retries=max(1, int(args.wait_for_free / BUSY_RETRY_SLEEP) + 1))
    except (DeckError, proto.ProtocolError) as exc:
        sys.stderr.write("deckctl: error: %s\n" % exc)
        return 2

    try:
        return COMMANDS[args.command](client, args)
    except (DeckError, proto.ProtocolError) as exc:
        sys.stderr.write("deckctl: protocol error: %s\n" % exc)
        return 3
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
