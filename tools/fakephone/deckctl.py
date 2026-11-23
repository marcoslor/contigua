#!/usr/bin/env python3
"""deckctl - fake Mac client and conformance tester for Contigua phones.

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
import struct
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proto  # noqa: E402

DNS_SD = "/usr/bin/dns-sd"
SERVICE_TYPE = "_contigua._tcp"
DEFAULT_STATE = os.path.expanduser("~/.contigua-deckctl.json")
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
        self.fp_hex = proto.make_identity(self.identity_dir, cn="Contigua deckctl")
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
        # Protocol 4 paths (docs/PROTOCOL.md "Paths"): this client is one path
        # until a check opens a second one. Reliable frames get seqs, ACKs and
        # a replay list; JSON and the input types travel wrapped.
        self.path_id = "%08x" % random.getrandbits(32)
        self.current_path = self.path_id
        self.session_id = None
        self.out_seq = 1
        self.in_seq = 1
        self.in_buffer = {}
        self.unacked = {}
        self._inbox = []
        self._ack_pending = False
        self._ack_frames = 0
        self._last_ack = 0.0
        self.peer_switch = None
        self.hello_v = None
        # VIDEO_CHUNK fragments are reassembled here so every command keeps
        # seeing one VIDEO_FRAME per access unit, as the Mac does.
        self._video = proto.VideoAssembler()

    # -- framing --
    def _bare(self, obj):
        self.sock.sendall(proto.pack_json(obj, obj.get("stream", 0) or 0))

    def send_json(self, obj):
        if self.session_id is None:
            # Before the welcome only hello/pair.* exist; they are bare (§4).
            self._bare(obj)
            return
        stream = obj.get("stream", 0) or 0
        inner = proto.Frame(proto.TYPE_JSON, stream,
                            proto.pack_json(obj, stream)[9:])
        self._send_reliable(inner)

    def _send_reliable(self, inner):
        seq = self.out_seq
        wrapped = proto.pack_reliable(seq, inner)
        self.unacked[seq] = wrapped
        self.out_seq += 1
        self.sock.sendall(wrapped)

    def send_raw(self, data):
        """Send a pre-framed message; reliable types get the wrapper."""
        if self.session_id is None or len(data) < 5:
            self.sock.sendall(data)
            return
        type_ = data[4] & 0xFF
        if proto.is_reliable(type_):
            stream = struct.unpack_from(">I", data, 5)[0]
            self._send_reliable(proto.Frame(type_, stream, data[9:]))
        else:
            self.sock.sendall(data)

    def _send_ack(self):
        try:
            self.sock.sendall(proto.pack_ack(self.in_seq))
            self._last_ack = time.time()
            self._ack_pending = False
            self._ack_frames = 0
        except OSError:
            pass

    def _ack_later(self):
        self._ack_frames += 1
        self._ack_pending = True
        if self._ack_frames >= 16 or time.time() - self._last_ack >= 0.010:
            self._send_ack()

    def _path_frame(self, frame):
        """Handle one path-layer frame. Returns an inner Frame to deliver, or
        None when the frame was consumed (ACK, ping, pong, our own marker)."""
        if frame.type == proto.TYPE_ACK:
            try:
                ack = proto.unpack_ack(frame)
            except proto.ProtocolError:
                return None
            for seq in [seq for seq in self.unacked if seq < ack]:
                self.unacked.pop(seq, None)
            return None
        if frame.type == proto.TYPE_RELIABLE:
            seq, inner = proto.unpack_reliable(frame)
            if seq < self.in_seq:
                self._send_ack()
                return None
            self.in_buffer[seq] = inner
            while self.in_seq in self.in_buffer:
                item = self.in_buffer.pop(self.in_seq)
                self.in_seq += 1
                if item.type == proto.TYPE_JSON:
                    try:
                        msg = proto.unpack_json(item)
                    except Exception:
                        msg = None
                    if msg and msg.get("t") == "path.switch" and msg.get("path"):
                        # The phone's own marker: its next reliable seq.
                        self.peer_switch = (msg["path"], msg.get("seq") or 0)
                        self.current_path = msg["path"]
                self._inbox.append(item)
            self._ack_later()
            return None
        if frame.type == proto.TYPE_JSON:
            try:
                msg = proto.unpack_json(frame)
            except Exception:
                return frame
            kind = msg.get("t")
            if kind == "path.ping":
                self.sock.sendall(proto.pack_json(
                    {"t": "path.pong", "path": msg.get("path") or self.path_id,
                     "ts": msg.get("ts") or 0}))
                return None
            if kind == "path.pong":
                return None
            if kind == "path.switch":
                target = msg.get("path")
                if target:
                    self.peer_switch = (target, msg.get("seq") or 0)
                    self.current_path = target
                    # Answer with our own marker: the next reliable seq + 1.
                    marker = {"t": "path.switch", "path": target,
                              "seq": self.out_seq + 1}
                    self.send_json(marker)
                    for wrapped in list(self.unacked.values()):
                        self.sock.sendall(wrapped)
                return None
            return frame
        return frame

    def recv(self, timeout=DEFAULT_TIMEOUT):
        """Next complete message, TIMEOUT if none arrived, None on EOF."""
        deadline = None if timeout is None else time.time() + timeout
        while True:
            if self._inbox:
                return self._inbox.pop(0)
            if self._ack_pending and time.time() - self._last_ack >= 0.010:
                self._send_ack()
            remaining = None if deadline is None else max(0.0, deadline - time.time())
            if deadline is not None and remaining <= 0 and not self._inbox:
                return TIMEOUT
            try:
                frame = self._reader.read(self.sock, remaining)
            except socket.timeout:
                return TIMEOUT
            if frame is None:
                return None
            inner = self._path_frame(frame)
            if inner is not None:
                if inner.type == proto.TYPE_VIDEO_CHUNK:
                    done = self._video.add(inner)
                    if done is None:
                        # A partial unit is not a message yet; keep reading
                        # until the unit completes or the caller's time is up.
                        if deadline is not None and time.time() >= deadline:
                            return TIMEOUT
                        continue
                    stream, pts, flags, au = done
                    return proto.Frame(proto.TYPE_VIDEO_FRAME, stream,
                                       struct.pack(">QB", pts, flags) + au)
                return inner

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    # -- handshake (v4: no challenge, no auth) --
    def send_hello(self, pair=False):
        client_id, name = self.state.ensure_identity(self.state.name)
        # The Mac's identity rides the TLS handshake's client certificate; the
        # hello carries only the display identity and this path's id (§4).
        self.hello_v = 4
        hello = {"t": "hello", "v": 4, "clientId": client_id, "name": name,
                 "videoChunks": True,
                 # A current Mac decodes HEVC in hardware; without this the
                 # phone can never exercise the WIN-59 default on the rig.
                 "codecs": ["avc", "hevc"],
                 "path": self.path_id}
        # A user-driven pairing says so in its hello (PROTOCOL "Session
        # handshake" step 2): without it the phone answers an unknown Mac
        # `not_paired` at once, before any pair.request can be sent.
        if pair:
            hello["pair"] = True
        self.send_json(hello)
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
            if msg.get("code") == "version":
                raise DeckError("phone refused protocol 4 (it speaks %r)" % msg.get("v"))
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
        self.session_id = msg.get("session")
        return msg

    def connect(self):
        """Pin-verifying reconnect: hello v4, then welcome without pairing."""
        self.send_hello()
        msg = self._next_frame()
        if msg.get("t") != "welcome":
            raise DeckError("expected welcome without pairing, got %r" % msg.get("t"))
        self.device = msg.get("device", {})
        self.session_id = msg.get("session")
        device_id = self.device.get("id")
        # Mirror the Mac's pin check: the phone's handshake cert must be the
        # one stored for this device id (§1); anything else is a re-pair.
        pinned = self.state.pins.get(device_id)
        if pinned is None or not hmac.compare_digest(pinned, self.sock.phone_fp_hex):
            raise AuthFailed()
        self.device_id = device_id

    def pair(self, on_code, decision_timeout=130.0):
        """The §4 machine: pair.request → commit → nonce → reveal rehash → code."""
        self.send_hello(pair=True)
        self.send_json({"t": "pair.request"})
        msg = self._next_frame()
        if msg.get("t") == "welcome":
            # The phone already knows this Mac (a leftover pin) — done.
            self.device = msg.get("device", {})
            self.device_id = self.device.get("id")
            self.session_id = msg.get("session")
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
            m = re.search(r"\bAdd\b.*_contigua\._tcp\.\s+(.+?)\s*$", line)
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
        # Per stream, every CONFIG's time (the burst counts encoder attaches) and
        # when each VIDEO_FRAME arrived (the burst's gap).
        self.config_times = {}
        self.frame_times = {}
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
                self.config_times.setdefault(frame.stream, []).append(self.config_at[frame.stream])
                self.first_frame_at.pop(frame.stream, None)
                fp = self.files.get(frame.stream)
                if fp is not None:
                    fp.write(csd)
                    self.wait_key[frame.stream] = True
                return
            if frame.type == proto.TYPE_VIDEO_FRAME:
                _pts, flags, au = proto.unpack_video_frame(frame)
                self.frame_times.setdefault(frame.stream, []).append(time.time())
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
def cmd_apps(client, _args):
    client.send_json({"t": "apps.list"})
    msg = expect_json(client, "apps")
    apps = msg.get("apps", [])
    for app in apps:
        # WIN-24: the phone says per app whether a second instance can run.
        print("%s\t%s\t%s" % (app.get("pkg"), app.get("label"),
                               "multi" if app.get("multi") else "single"))
    print("# %d apps" % len(apps))
    return 0


def _png_side(raw):
    """The pixel side of a PNG, or 0 when the bytes are not one."""
    if len(raw) >= 24 and raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return struct.unpack(">I", raw[16:20])[0]
    return 0


def cmd_icon(client, args):
    request = {"t": "apps.icon", "pkg": args.pkg}
    if args.px is not None:
        request["px"] = args.px
    started = time.time()
    client.send_json(request)
    msg = expect_json(client, "icon")
    elapsed_ms = (time.time() - started) * 1000.0
    raw = base64.b64decode(msg.get("png", ""))
    if not raw.startswith(b"\x89PNG\r\n\x1a\n"):
        raise proto.ProtocolError("icon payload is not a PNG")
    with open(args.out, "wb") as fp:
        fp.write(raw)
    layers = []
    for name in ("fg", "bg", "mono"):
        if msg.get(name):
            data = base64.b64decode(msg[name])
            layers.append("%s=%dpx/%dB" % (name, _png_side(data), len(data)))
            if args.layers_dir:
                os.makedirs(args.layers_dir, exist_ok=True)
                with open(os.path.join(args.layers_dir, "%s-%s.png" % (args.pkg, name)), "wb") as fp:
                    fp.write(data)
    print("icon %s px=%s png=%dpx/%dB %s total_ms=%.0f -> %s"
          % (args.pkg, args.px if args.px is not None else "default", _png_side(raw), len(raw),
             " ".join(layers) if layers else "flat", elapsed_ms, args.out))
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
    if getattr(args, "new_instance", False):
        # WIN-32: another task of the same app, not a raise of its window.
        req["newInstance"] = True
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
    print("stream=%d size=%dx%d displayId=%s taskId=%s" %
          (stream, w, h, stats["opened"].get("displayId"), stats["opened"].get("taskId")))
    print("fps=%.1f kbps=%.1f first_frame_ms=%.1f frames=%d" %
          (fps, kbps, first_ms, stats["frames"]))
    client.send_json({"t": "window.close", "stream": stream})
    return 0


STATS_REQUIRED = ("windowMs", "frames", "kf", "kfReq", "bytes", "drop",
                   "dropEp", "skip", "targetBps")


def cmd_stats(client, args):
    """ISS-40 on the real server: open a window, ask for `stream.stats`, read
    the messages, and prove `pong.now` is a live monotonic-microsecond clock."""
    stream = 1
    client.send_json({"t": "window.open", "stream": stream,
                      "w": args.w, "h": args.h, "dpi": args.dpi,
                      "pkg": args.pkg})
    client.send_json({"t": "stream.stats", "on": True})
    deadline = time.time() + args.seconds
    next_ping = time.time()
    opened = False
    messages = []
    pongs = []      # (sent ts, now, receive monotonic)
    try:
        while time.time() < deadline and (len(messages) < args.messages or len(pongs) < 2):
            now = time.time()
            if now >= next_ping:
                sent_ts = int(now * 1000)
                client.send_json({"t": "ping", "ts": sent_ts,
                                  "monoUs": time.monotonic_ns() // 1000})
                next_ping = now + 0.5
            frame = client.recv(min(0.25, max(0.02, deadline - time.time())))
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed before the stats arrived")
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            kind = msg.get("t")
            if kind == "error":
                raise DeckError("phone error %s: %s"
                                % (msg.get("code"), msg.get("message", "")))
            if kind == "window.opened" and msg.get("stream") == stream:
                opened = True
            elif kind == "pong":
                value = msg.get("now")
                if not isinstance(value, int) or value <= 0:
                    raise DeckError("pong has no positive now: %r" % (value,))
                if msg.get("ts") != sent_ts and msg.get("ts") is not None:
                    # An older phone may echo a ping from before this request;
                    # only a pong for our own ts counts.
                    continue
                pongs.append((sent_ts, value, time.monotonic()))
                print("pong ts=%s now=%d" % (msg.get("ts"), value), flush=True)
            elif kind == "stream.stats" and msg.get("stream") == stream:
                missing = [key for key in STATS_REQUIRED if key not in msg]
                if missing:
                    raise DeckError("stream.stats lacks %s" % ", ".join(missing))
                if msg.get("windowMs") != 2000:
                    raise DeckError("stream.stats windowMs is %r, expected 2000"
                                    % (msg.get("windowMs"),))
                messages.append(msg)
                print("stream.stats " + json.dumps(msg, sort_keys=True), flush=True)
    finally:
        client.send_json({"t": "stream.stats", "on": False})
        client.send_json({"t": "window.close", "stream": stream})
    if not opened:
        raise DeckError("no window.opened")
    if len(messages) < args.messages:
        raise DeckError("only %d stream.stats messages, expected %d"
                        % (len(messages), args.messages))
    if len(pongs) < 2:
        raise DeckError("only %d pongs, expected 2" % len(pongs))
    # A monotonic clock measured 1+ s apart: now's own delta matches the
    # receive-side elapsed time (a random or wall-clock value would not).
    (_, first, first_at), (_, last, last_at) = pongs[0], pongs[-1]
    clock_delta = (last - first) / 1_000_000.0
    elapsed = last_at - first_at
    if elapsed < 0.9:
        raise DeckError("the two pongs are only %.1f s apart" % elapsed)
    if abs(clock_delta - elapsed) > 0.5:
        raise DeckError("pong.now advanced %.2f s over %.2f s of elapsed time"
                        % (clock_delta, elapsed))
    print("STATS OK messages=%d pongs=%d clock_delta=%.2fs elapsed=%.2fs"
          % (len(messages), len(pongs), clock_delta, elapsed), flush=True)
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
    if args.phone:
        client.send_json({"t": "window.open", "stream": 1, "w": args.w, "h": args.h,
                          "dpi": args.dpi, "mode": "phone"})
        deadline = time.time() + DEFAULT_TIMEOUT
        while time.time() < deadline:
            frame = client.recv(0.25)
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed while opening the phone window")
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise DeckError("phone window: %s" % msg.get("code"))
            if msg.get("t") == "window.opened":
                print("phone window opened displayId=%s" % msg.get("displayId"))
                break
        else:
            raise DeckError("no window.opened for the phone window")
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
            screen = "" if "screen" not in msg else " screen=%s" % json.dumps(msg.get("screen"))
            secure = "" if "secure" not in msg else " secure=%s" % json.dumps(msg.get("secure"))
            volume = "" if "volume" not in msg else " volume=%s/%s" % (
                msg.get("volume"), msg.get("volumeMax"))
            print("%s state #%d locked=%s battery=%s charging=%s%s%s%s%s" % (
                time.strftime("%H:%M:%S"), count, msg.get("locked"),
                msg.get("battery"), msg.get("charging"), dnd, screen, secure, volume))
    if args.phone:
        client.send_json({"t": "window.close", "stream": 1})
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


def cmd_volume(client, args):
    """Send `phone.volume` and print the state the phone reports afterwards."""
    # The post-welcome state is not the answer: drain it, then the next state
    # is the reply to this command.
    while True:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed during volume")
    client.send_json({"t": "phone.volume", "level": args.level})
    print("sent phone.volume level=%d" % args.level)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during volume")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error: %s (%s)" % (msg.get("code"), msg.get("message")))
        if msg.get("t") == "state" and "volume" in msg and "volumeMax" in msg:
            print("state volume=%s/%s" % (msg.get("volume"), msg.get("volumeMax")))
            return 0
    raise DeckError("no state with volume within %ss (an old phone omits it)" % args.wait)


def cmd_ui_tree(client, args):
    """`ui.tree` on the phone (docs/PROTOCOL.md "UI tree"): open a phone mirror,
    read its tree `--reads` times and print each reply as one JSON line, so a
    check can compare the keys (`k`) across reads (MCP-71)."""
    stream = 1
    client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                      "dpi": args.dpi, "mode": "phone"})
    _await_json(client, "window.opened", args.wait)
    for seq in range(1, args.reads + 1):
        request = {"t": "ui.tree", "stream": stream, "seq": seq}
        if args.offscreen:
            request["offscreen"] = True  # MCP-106: keep the off-screen rows
        client.send_json(request)
        msg = _await_json(client, "ui.tree", args.wait)
        print(json.dumps(msg, sort_keys=True))
    return 0


def cmd_ui_press(client, args):
    """`ui.press` on the phone (docs/PROTOCOL.md "UI tree" item 8): open a phone
    mirror, read its tree once, then press each `--k` with the tree's label as
    `expect` (or `--expect`), printing each reply as one JSON line."""
    stream = 1
    client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                      "dpi": args.dpi, "mode": "phone"})
    _await_json(client, "window.opened", args.wait)
    client.send_json({"t": "ui.tree", "stream": stream, "seq": 1})
    tree = _await_json(client, "ui.tree", args.wait)
    rows = {n.get("k"): n for n in tree.get("nodes", [])}
    for seq, k in enumerate(args.k, start=2):
        row = rows.get(k, {})
        msg = {"t": "ui.press", "stream": stream, "seq": seq, "k": k,
               "expect": args.expect if args.expect is not None else (row.get("text") or row.get("desc") or "")}
        if args.hold_ms:
            msg["holdMs"] = args.hold_ms
        client.send_json(msg)
        print(json.dumps(_await_json(client, "ui.press", args.wait), sort_keys=True))
    return 0


def cmd_ui_type(client, args):
    """`ui.type` on the phone (docs/PROTOCOL.md "UI tree" item 10): open a phone
    mirror and type `--text` into its focused field, printing the reply as one
    JSON line."""
    stream = 1
    client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                      "dpi": args.dpi, "mode": "phone"})
    _await_json(client, "window.opened", args.wait)
    msg = {"t": "ui.type", "stream": stream, "seq": 1, "text": args.text}
    if args.clear:
        msg["clear"] = True
    if args.submit:
        msg["submit"] = True
    client.send_json(msg)
    print(json.dumps(_await_json(client, "ui.type", args.wait), sort_keys=True))
    return 0


def _await_json(client, kind, wait):
    """The next JSON message of type `kind`; an `error` or a silence fails."""
    deadline = time.time() + wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed before %s" % kind)
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") == kind:
            return msg
    raise DeckError("no %s within %ss" % (kind, wait))


def cmd_ui_settle(client, args):
    """`ui.settle` on the phone (docs/PROTOCOL.md "UI tree" §7): open a phone
    mirror, ask the phone to settle it and print the reply (MCP-81's wire)."""
    stream = 1
    client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                      "dpi": args.dpi, "mode": "phone"})
    deadline = time.time() + args.wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed before window.opened")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") == "window.opened":
            break
    else:
        raise DeckError("no window.opened within %ss" % args.wait)

    started = time.monotonic()
    request = {"t": "ui.settle", "stream": stream, "seq": 1,
               "quietMs": args.quiet_ms, "timeoutMs": args.timeout_ms}
    if args.no_stream:
        del request["stream"]
    client.send_json(request)
    deadline = time.time() + args.wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during ui.settle")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") == "ui.settle":
            elapsed_ms = int((time.monotonic() - started) * 1000)
            print("ui.settle ok=%s settled=%s waitedMs=%s events=%s reason=%s elapsed_ms=%d" % (
                msg.get("ok"), msg.get("settled"), msg.get("waitedMs"), msg.get("events"),
                msg.get("reason"), elapsed_ms))
            if args.no_stream:
                print("ui.settle stream=%s code=%s" % (msg.get("stream"), msg.get("code")))
                return 0
            if msg.get("ok") is not True:
                raise DeckError("ui.settle failed: code=%s message=%s"
                                % (msg.get("code"), msg.get("message", "")))
            return 0
    raise DeckError("no ui.settle reply within %ss" % args.wait)


def cmd_wake(client, args):
    """Send `phone.wake` and print the state the phone reports afterwards.

    The real phone answers the wake with a state as it is at that moment and
    sends the display's own change as the next one, so wait for `screen: on`
    rather than the first state.
    """
    # Drain the post-welcome state: the answer must be this command's.
    while True:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed during wake")
    client.send_json({"t": "phone.wake"})
    print("sent phone.wake")
    deadline = time.time() + args.wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during wake")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error: %s (%s)" % (msg.get("code"), msg.get("message")))
        if msg.get("t") == "state":
            print("state screen=%s locked=%s" % (json.dumps(msg.get("screen")), msg.get("locked")))
            if msg.get("screen") == "on":
                return 0
    raise DeckError("no state with screen on within %ss" % args.wait)


def cmd_wake_test(client, args):
    """One session for the emulator's phone.wake check: wait for `screen off`
    (the rig sleeps the panel), send `phone.wake`, wait for `screen on`."""
    deadline = time.time() + args.off_timeout
    saw_off = False
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed while waiting for screen off")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "state" and msg.get("screen") == "off":
            print("state screen=off locked=%s" % msg.get("locked"))
            saw_off = True
            break
    if not saw_off:
        raise DeckError("no state.screen off within %ss" % args.off_timeout)
    client.send_json({"t": "phone.wake"})
    print("sent phone.wake")
    deadline = time.time() + args.on_timeout
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed while waiting for screen on")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error: %s (%s)" % (msg.get("code"), msg.get("message")))
        if msg.get("t") == "state" and msg.get("screen") == "on":
            print("state screen=on locked=%s" % msg.get("locked"))
            return 0
    raise DeckError("no state.screen on within %ss" % args.on_timeout)


def cmd_panel(client, args):
    """Send `phone.panel` as the Mac and print the `state.panel` it reports."""
    while True:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed during panel")
    off = args.mode == "off"
    client.send_json({"t": "phone.panel", "off": off})
    print("sent phone.panel off=%s" % json.dumps(off))
    want = "off" if off else "on"
    deadline = time.time() + args.wait
    while time.time() < deadline:
        frame = client.recv(0.25)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed during panel")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error: %s (%s)" % (msg.get("code"), msg.get("message")))
        if msg.get("t") == "state":
            print("state panel=%s screen=%s" % (json.dumps(msg.get("panel")),
                                               json.dumps(msg.get("screen"))))
            if msg.get("panel") == want:
                return 0
    raise DeckError("no state with panel %s within %ss" % (want, args.wait))


def cmd_panel_test(client, args):
    """One session for the emulator's panel checks (docs/design/phone-mirror.md):

    (a) an app window paused for a few seconds and resumed, (b) a phone window
    beside an app window, (c) phone.panel off/on with the mirror's frames counted
    while the panel is off. Prints counts and states only; the shell check reads
    the phone's own log for the panel plans (the session cannot).
    """
    frames = {}
    states = []
    opened = set()

    def drain(seconds, want=None):
        deadline = time.time() + seconds
        while True:
            if want is not None and want():
                return True
            remaining = deadline - time.time()
            if remaining <= 0:
                return want is None
            frame = client.recv(max(0.05, min(0.25, remaining)))
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed during panel-test")
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                if msg.get("t") == "error":
                    raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
                if msg.get("t") == "window.opened":
                    opened.add(int(msg.get("stream") or 0))
                elif msg.get("t") == "state":
                    states.append(msg)
                continue
            if frame.type == proto.TYPE_VIDEO_FRAME:
                frames[frame.stream] = frames.get(frame.stream, 0) + 1

    def panel_state():
        for msg in reversed(states):
            if msg.get("panel") is not None:
                return msg.get("panel")
        return None

    # (a) covered and uncovered inside the grace period
    if args.phase in ("all", "pause"):
        client.send_json({"t": "window.open", "stream": 1, "w": 1280, "h": 800, "dpi": 240,
                          "pkg": args.target})
        if not drain(args.open_timeout, lambda: 1 in opened and frames.get(1, 0) > 0):
            raise DeckError("the app window never sent a frame")
        drain(args.settle)
        client.send_json({"t": "window.pause", "stream": 1})
        print("paused")
        drain(args.pause_seconds)
        client.send_json({"t": "window.resume", "stream": 1})
        print("resumed")
        if not drain(args.resume_seconds, lambda: frames.get(1, 0) > 2):
            raise DeckError("no frame after the resume")
        client.send_json({"t": "window.close", "stream": 1})
        drain(1.0)
        opened.discard(1)
    if args.phase == "pause":
        return 0

    # (b) the mirror plus an app window on the panel's group
    client.send_json({"t": "window.open", "stream": 2, "w": 400, "h": 800, "dpi": 160, "mode": "phone"})
    if not drain(args.open_timeout, lambda: 2 in opened):
        raise DeckError("the phone window never opened")
    client.send_json({"t": "window.open", "stream": 1, "w": 1280, "h": 800, "dpi": 240,
                      "pkg": args.target})
    if not drain(args.open_timeout, lambda: 1 in opened and frames.get(2, 0) > 0):
        raise DeckError("the app window never opened beside the mirror")
    drain(args.settle)

    # (c) the person asks for the mirrored panel to stay off
    client.send_json({"t": "phone.panel", "off": True})
    if not drain(args.panel_timeout, lambda: panel_state() == "off"):
        raise DeckError("no state with panel off")
    print("state-panel=off")
    before = frames.get(2, 0)
    drain(args.off_seconds)
    print("frames-while-off=%d" % (frames.get(2, 0) - before))
    client.send_json({"t": "phone.panel", "off": False})
    if not drain(args.panel_timeout, lambda: panel_state() == "on"):
        raise DeckError("no state with panel on")
    print("state-panel=on")
    client.send_json({"t": "window.close", "stream": 2})
    client.send_json({"t": "window.close", "stream": 1})
    drain(1.0)
    print("frames-mirror=%d" % frames.get(2, 0))
    return 0


def cmd_panel_hold(client, args):
    """The bug's own shape: a lone phone window (no app window), `phone.panel
    off`, the window stays open, then `phone.panel on`. The shell reads the phone
    log for the power mode NORMAL that must follow the on, and for keep-alive
    steps 1-3 while held."""
    opened = set()
    frames = [0]
    states = []

    def drain(seconds, want=None):
        deadline = time.time() + seconds
        while True:
            if want is not None and want():
                return True
            remaining = deadline - time.time()
            if remaining <= 0:
                return want is None
            frame = client.recv(max(0.05, min(0.25, remaining)))
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed during panel-hold")
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                if msg.get("t") == "error":
                    raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
                if msg.get("t") == "window.opened":
                    opened.add(int(msg.get("stream") or 0))
                elif msg.get("t") == "state":
                    states.append(msg)
                continue
            frames[0] += 1

    def panel_state():
        for msg in reversed(states):
            if msg.get("panel") is not None:
                return msg.get("panel")
        return None

    client.send_json({"t": "window.open", "stream": 3, "w": 400, "h": 800, "dpi": 160, "mode": "phone"})
    if not drain(args.open_timeout, lambda: 3 in opened and frames[0] > 0):
        raise DeckError("the phone window never opened")

    client.send_json({"t": "phone.panel", "off": True})
    if not drain(args.panel_timeout, lambda: panel_state() == "off"):
        raise DeckError("no state with panel off (the hold did not apply)")
    print("state-panel=off")

    before = frames[0]
    if not drain(args.hold_seconds):
        raise DeckError("the session closed while the panel was held")
    print("frames-while-held=%d" % (frames[0] - before))
    if frames[0] == before:
        raise DeckError("the mirror stopped sending frames while the panel was held")

    client.send_json({"t": "phone.panel", "off": False})
    if not drain(args.panel_timeout, lambda: panel_state() == "on"):
        raise DeckError("no state with panel on (the hold did not end)")
    print("state-panel=on")
    client.send_json({"t": "window.close", "stream": 3})
    drain(1.0)
    return 0


def cmd_panel_press(client, args):
    """The person's power press: the shell reads `ready` (the hold is applied)
    and presses the phone's power key; the phone must end the hold by itself and
    report `state.panel on`."""
    opened = set()
    states = []

    def drain(seconds, want=None):
        deadline = time.time() + seconds
        while True:
            if want is not None and want():
                return True
            remaining = deadline - time.time()
            if remaining <= 0:
                return want is None
            frame = client.recv(max(0.05, min(0.25, remaining)))
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed during panel-press")
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                if msg.get("t") == "error":
                    raise DeckError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
                if msg.get("t") == "window.opened":
                    opened.add(int(msg.get("stream") or 0))
                elif msg.get("t") == "state":
                    states.append(msg)

    def panel_state():
        for msg in reversed(states):
            if msg.get("panel") is not None:
                return msg.get("panel")
        return None

    client.send_json({"t": "window.open", "stream": 4, "w": 400, "h": 800, "dpi": 160, "mode": "phone"})
    if not drain(args.open_timeout, lambda: 4 in opened):
        raise DeckError("the phone window never opened")
    client.send_json({"t": "phone.panel", "off": True})
    if not drain(args.panel_timeout, lambda: panel_state() == "off"):
        raise DeckError("no state with panel off (the hold did not apply)")
    print("ready")
    sys.stdout.flush()
    if not drain(args.press_timeout, lambda: panel_state() == "on"):
        raise DeckError("the power press did not end the hold")
    print("panel-on=1")
    client.send_json({"t": "window.close", "stream": 4})
    drain(1.0)
    return 0


def cmd_clip_set(client, args):
    """Send `clip.set` as the Mac: the phone's clipboard takes the text.

    Waits for the phone to ACK the reliable frame before closing: a socket
    closed with unread frames can RST the connection and discard the clip.set
    still queued, so an early return would report a copy the phone never got.
    Prints only the length, never the text.
    """
    seq = client.out_seq
    client.send_json({"t": "clip.set", "text": args.text})
    deadline = time.time() + DEFAULT_TIMEOUT
    while seq in client.unacked:
        if time.time() >= deadline:
            raise DeckError("the phone did not acknowledge clip.set")
        if client.recv(0.25) is None:
            raise DeckError("phone closed before acknowledging clip.set")
    print("sent clip.set chars=%d" % len(args.text))
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


def cmd_media(client, args):
    """Media control as the Mac (docs/design/notify.md "Media part 2").

    `watch` opts in on its own session first (the gate is per session) and
    prints the phone's media events: session counts, the opaque keys, the
    position, the volume, the artwork's dimensions and bytes. Never a title,
    an artist, an album or a package name (the emulator log stays textless).
    """
    what = args.what
    if what == "drive":
        # One session, a scripted sequence (the emulator check): opt in, then
        # seek, set the volume and choose the other session a few seconds
        # apart, printing every media message as it arrives. The phone allows
        # one session, so the commands cannot come from separate processes.
        client.send_json({"t": "notify.enable", "on": True})
        print("sent notify.enable on=true (driving %.0fs)" % args.seconds)
        started = time.time()
        plan = [(3.0, "seek"), (6.0, "volume"), (9.0, "choose")]
        chosen, keys = None, []
        deadline = started + args.seconds
        while time.time() < deadline:
            frame = client.recv(0.25)
            if frame is not TIMEOUT:
                if frame is None:
                    raise DeckError("phone closed during media drive")
                if frame.type == proto.TYPE_JSON:
                    msg = proto.unpack_json(frame)
                    t = msg.get("t")
                    if t == "media.state":
                        print("media.state playing=%s key=%s titleLen=%d durationMs=%s "
                              "positionMs=%s rate=%.2f canSeek=%s volume=%s/%s"
                              % ("true" if msg.get("playing") else "false", msg.get("key") or "-",
                                 len(msg.get("title") or ""), msg.get("durationMs"),
                                 msg.get("positionMs"), (msg.get("rate") or 0.0),
                                 "true" if msg.get("canSeek") else "false",
                                 msg.get("volume"), msg.get("volumeMax")), flush=True)
                    elif t == "media.sessions":
                        rows = msg.get("list") or []
                        chosen = msg.get("chosen")
                        keys = [row.get("key") for row in rows]
                        print("media.sessions n=%d playing=%d chosen=%s keys=%s"
                              % (len(rows), sum(1 for row in rows if row.get("playing")),
                                 chosen or "-", ",".join(str(k) for k in keys) or "-"),
                              flush=True)
                    elif t == "media.art":
                        data = msg.get("data") or ""
                        print("media.art key=%s mime=%s w=%s h=%s size=%d"
                              % (msg.get("key"), msg.get("mime"), msg.get("w"), msg.get("h"),
                                 len(data) * 3 // 4), flush=True)
                    elif t == "error":
                        # Silence looked like "the phone sent nothing" once; an
                        # error code is the phone's own answer and never content.
                        print("error code=%s" % msg.get("code"), flush=True)
            elapsed = time.time() - started
            while plan and elapsed >= plan[0][0]:
                _, step = plan.pop(0)
                if step == "seek":
                    client.send_json({"t": "media.command", "action": "seek",
                                      "positionMs": args.position})
                    print("sent media.command seek positionMs=%d" % args.position, flush=True)
                elif step == "volume":
                    client.send_json({"t": "media.command", "action": "volume",
                                      "level": args.level})
                    print("sent media.command volume level=%d" % args.level, flush=True)
                elif step == "choose":
                    other = next((k for k in keys if k != chosen), None)
                    if other:
                        client.send_json({"t": "media.choose", "key": other})
                        print("sent media.choose key=%s" % other, flush=True)
        return 0
    if what == "watch":
        client.send_json({"t": "notify.enable", "on": True})
        print("sent notify.enable on=true (watching %.0fs)" % args.seconds)
        deadline = time.time() + args.seconds
        while time.time() < deadline:
            frame = client.recv(0.25)
            if frame is TIMEOUT:
                continue
            if frame is None:
                raise DeckError("phone closed during media watch")
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            t = msg.get("t")
            if t == "media.state":
                print("media.state playing=%s key=%s titleLen=%d durationMs=%s "
                      "positionMs=%s rate=%.2f canSeek=%s volume=%s/%s"
                      % ("true" if msg.get("playing") else "false", msg.get("key") or "-",
                         len(msg.get("title") or ""), msg.get("durationMs"),
                         msg.get("positionMs"), (msg.get("rate") or 0.0),
                         "true" if msg.get("canSeek") else "false",
                         msg.get("volume"), msg.get("volumeMax")), flush=True)
            elif t == "media.sessions":
                rows = msg.get("list") or []
                playing = sum(1 for row in rows if row.get("playing"))
                keys = ",".join(str(row.get("key")) for row in rows)
                print("media.sessions n=%d playing=%d chosen=%s keys=%s"
                      % (len(rows), playing, msg.get("chosen") or "-", keys or "-"),
                      flush=True)
            elif t == "media.art":
                data = msg.get("data") or ""
                print("media.art key=%s mime=%s w=%s h=%s size=%d"
                      % (msg.get("key"), msg.get("mime"), msg.get("w"), msg.get("h"),
                         len(data) * 3 // 4), flush=True)
            elif t == "notify.state":
                print("notify.state on=%s" % ("true" if msg.get("on") else "false"), flush=True)
            elif t == "error":
                # An error code is the phone's own answer and never content.
                print("error code=%s" % msg.get("code"), flush=True)
        return 0
    client.send_json({"t": "notify.enable", "on": True})
    if what == "seek":
        msg = {"t": "media.command", "action": "seek", "positionMs": args.position}
        if args.key:
            msg["key"] = args.key
        client.send_json(msg)
        print("sent media.command seek positionMs=%d key=%s"
              % (args.position, args.key or "-"))
    elif what == "volume":
        msg = {"t": "media.command", "action": "volume", "level": args.level}
        if args.key:
            msg["key"] = args.key
        client.send_json(msg)
        print("sent media.command volume level=%d key=%s" % (args.level, args.key or "-"))
    elif what == "choose":
        if not args.key:
            raise DeckError("media choose needs --key")
        client.send_json({"t": "media.choose", "key": args.key})
        print("sent media.choose key=%s" % args.key)
    else:
        raise DeckError("media %s is not a command" % what)
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


def _mime_of(path):
    ext = os.path.splitext(path)[1].lower()
    return {
        ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".pdf": "application/pdf", ".txt": "text/plain", ".zip": "application/zip",
        ".mp4": "video/mp4", ".mp3": "audio/mpeg",
    }.get(ext, "application/octet-stream")


def _wait_json(client, deadline, wanted, ident=None):
    """The next JSON message of a wanted type (and id), or an error at the deadline."""
    while time.time() < deadline:
        frame = client.recv(1.0)
        if frame is TIMEOUT:
            continue
        if frame is None:
            raise DeckError("phone closed while waiting for %s" % "/".join(wanted))
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") in wanted and (ident is None or msg.get("id") == ident):
            return msg
    raise DeckError("timed out waiting for %s" % "/".join(wanted))


def cmd_clipimage(client, args):
    """Put an image on the phone's clipboard through the real clip.image.* path.

    `paste:true` is A1's explicit ⌘V: the phone's sync gate steps aside and the
    answer is clip.image.done. Prints the bytes and the phone's answer.
    """
    with open(args.path, "rb") as handle:
        data = handle.read()
    mime = _mime_of(args.path)
    if not data or mime not in ("image/png", "image/jpeg"):
        raise DeckError("clipimage needs a non-empty PNG or JPEG")
    client.send_json({"t": "clip.image.start", "id": args.id, "mime": mime,
                      "size": len(data), "paste": True})
    offset = 0
    while offset < len(data):
        end = min(offset + (256 << 10), len(data))
        client.send_raw(proto.pack_frame(proto.TYPE_CLIP_DATA, args.id, data[offset:end]))
        offset = end
    client.send_json({"t": "clip.image.end", "id": args.id, "size": len(data),
                      "sha256": hashlib.sha256(data).hexdigest()})
    msg = _wait_json(client, time.time() + args.timeout, {"clip.image.done"}, args.id)
    print("clip.image.done id=%d ok=%s bytes=%d mime=%s"
          % (args.id, msg.get("ok"), len(data), mime))
    return 0 if msg.get("ok") is True else 1


def cmd_drop(client, args):
    """Send one file drop as the Mac, with the window's target and batch fields."""
    with open(args.path, "rb") as handle:
        data = handle.read()
    if not data:
        raise DeckError("drop needs a non-empty file")
    name = os.path.basename(args.path)
    mime = _mime_of(args.path)
    message = {"t": "drop.start", "id": args.id, "name": name, "mime": mime,
               "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
               "index": args.index, "count": args.count}
    if args.target:
        message["target"] = args.target
    client.send_json(message)
    _wait_json(client, time.time() + 15, {"drop.progress"}, args.id)
    offset = 0
    while offset < len(data):
        end = min(offset + (256 << 10), len(data))
        client.send_raw(proto.pack_frame(proto.TYPE_DROP_DATA, args.id, data[offset:end]))
        offset = end
    msg = _wait_json(client, time.time() + args.timeout, {"drop.result"}, args.id)
    print("drop id=%d name=%s target=%s index=%d/%d ok=%s code=%s path=%s"
          % (args.id, name, args.target or "-", args.index, args.count,
             msg.get("ok"), msg.get("code") or "-", msg.get("path") or "-"))
    return 0 if msg.get("ok") is True else 1



def cmd_dropbatch(client, args):
    """Send one gesture's drops in one session (the Mac's multi-file batch)."""
    with open(args.path, "rb") as handle:
        data = handle.read()
    if not data:
        raise DeckError("dropbatch needs a non-empty file")
    base = os.path.basename(args.path)
    mime = _mime_of(args.path)
    sha = hashlib.sha256(data).hexdigest()
    ok = True
    for index in range(1, args.count + 1):
        ident = args.id + index
        name = "batch-%d-%s" % (index, base)
        message = {"t": "drop.start", "id": ident, "name": name, "mime": mime,
                   "size": len(data), "sha256": sha, "index": index, "count": args.count}
        if args.target:
            message["target"] = args.target
        client.send_json(message)
        _wait_json(client, time.time() + 15, {"drop.progress"}, ident)
        offset = 0
        while offset < len(data):
            end = min(offset + (256 << 10), len(data))
            client.send_raw(proto.pack_frame(proto.TYPE_DROP_DATA, ident, data[offset:end]))
            offset = end
        result = _wait_json(client, time.time() + args.timeout, {"drop.result"}, ident)
        print("drop batch id=%d name=%s index=%d/%d ok=%s code=%s"
              % (ident, name, index, args.count, result.get("ok"),
                 result.get("code") or "-"))
        ok = ok and result.get("ok") is True
    return 0 if ok else 1


def cmd_clip_watch(client, args):
    """Print every `clip.set` the phone sends for `--seconds`, length only.

    `--enable` first turns the Mac's clipboard gate on and waits for a pong, so
    the phone has applied it before the caller copies. Never prints clip text.
    """
    if args.enable:
        client.send_json({"t": "clip.enable", "on": True})
        client.send_json({"t": "ping", "ts": 7301})
        # Pong carries the ping's ts, not an id, and FIFO proves the gate applied.
        _wait_json(client, time.time() + 10, {"pong"})
        print("clip.enable on")
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
            print("%s clip.set chars=%d" % (time.strftime("%H:%M:%S"),
                                            len(msg.get("text") or "")))
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


def cmd_density_burst(client, args):
    """Ten identical resizes in about a second — the 10-27 ⌘+/⌘- burst.

    On an idle app every one of them built a new encoder on the phone and
    re-attached the display, so frames stopped for seconds (the person's log:
    seven seconds with no frame). The phone must answer the first with a resize
    and the rest with `window.resize.ack` "same", and the picture must keep
    coming: one encoder attach, no gap over `density_burst_stall_ms`, and the
    frame after the last request within `density_burst_first_frame_ms`.
    """
    stream = 1
    rec = StreamRecorder(client).start()
    try:
        client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                          "dpi": args.dpi, "pkg": args.apps[0]})
        rec.wait_for_size(stream, 25.0)
        deadline = time.time() + 25.0
        while stream not in rec.first_frame_at and time.time() < deadline:
            rec.raise_if_broken("waiting for the first frame")
            time.sleep(0.05)
        if stream not in rec.first_frame_at:
            raise DeckError("no frame after window.open")
        time.sleep(args.launch_settle)

        with rec.lock:
            seen_messages = len(rec.messages)

        started = time.time()
        burst_dpi = args.burst_dpi if args.burst_dpi is not None else args.dpi
        for _ in range(args.presses):
            client.send_json({"t": "window.resize", "stream": stream,
                              "w": args.burst_w, "h": args.burst_h, "dpi": burst_dpi})
            time.sleep(args.interval_ms / 1000.0)
        last = time.time()
        # Let the last answer and the frames that follow it arrive.
        time.sleep(args.settle)

        with rec.lock:
            acks = [m for m in rec.messages[seen_messages:]
                    if m.get("t") == "window.resize.ack" and m.get("stream") == stream]
            outcomes = {}
            for ack in acks:
                outcomes[ack.get("outcome")] = outcomes.get(ack.get("outcome"), 0) + 1
            configs = sum(1 for t in rec.config_times.get(stream, []) if t >= started)
            frames = [t for t in rec.frame_times.get(stream, []) if started <= t <= last + args.settle]
            after = [t for t in frames if t >= last]

        gap_ms = 0.0
        previous = started
        for when in frames + [last + args.settle]:
            gap_ms = max(gap_ms, (when - previous) * 1000.0)
            previous = when
        first_after_ms = (after[0] - last) * 1000.0 if after else None
        print("density-burst: presses=%d acks=%d outcomes=%s configs=%d frames=%d max_gap_ms=%.0f "
              "first_frame_after_last_ms=%s" % (
                  args.presses, len(acks), outcomes, configs, len(frames), gap_ms,
                  ("%.0f" % first_after_ms) if first_after_ms is not None else "none"))
        problems = []
        if len(acks) != args.presses:
            problems.append("%d of %d resizes answered" % (len(acks), args.presses))
        if configs > 1:
            problems.append("%d encoder rebuilds for one new size" % configs)
        if outcomes.get("same", 0) < args.presses - 1:
            problems.append("%d of the repeats were not no-ops" % (args.presses - 1 - outcomes.get("same", 0)))
        if gap_ms > args.stall_ms:
            problems.append("no frame for %.0f ms" % gap_ms)
        if first_after_ms is None or first_after_ms > args.frame_ms:
            problems.append("the frame after the last press took %s" % (
                ("%.0f ms" % first_after_ms) if first_after_ms is not None else "forever"))
        for problem in problems:
            print("FAIL " + problem)
        if not problems:
            print("PASS density-burst: one attach, %d no-ops, gap %.0f ms, frame after the last press %.0f ms"
                  % (outcomes.get("same", 0), gap_ms, first_after_ms or 0))
        return 1 if problems else 0
    finally:
        rec.stop()
        client.send_json({"t": "window.close", "stream": stream})


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


def _fs_thumb(client, path, out, size):
    """`fs.thumb` (docs/PROTOCOL.md "Phone files" > "Thumbnails"): the bytes go
    to OUT, the reply's mime/size/hash and the duration are printed as JSON."""
    fs_id = _fs_id()
    started = time.time()
    client.send_json({"t": "fs.thumb", "id": fs_id, "path": path, "size": size})
    data = bytearray()
    while True:
        frame = client.recv(90)
        if frame is TIMEOUT:
            raise DeckError("no answer for fs thumb id %d (timeout)" % fs_id)
        if frame is None:
            raise DeckError("phone closed the connection during fs thumb id %d" % fs_id)
        if frame.type == proto.TYPE_FS_DATA:
            if frame.stream == fs_id:
                data.extend(frame.payload)
            continue
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("id") != fs_id:
            continue
        if msg.get("t") == "error":
            raise DeckError("fs error: %s (%s)" % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") != "fs.thumb.end":
            continue
        digest = hashlib.sha256(bytes(data)).hexdigest()
        if msg.get("size") != len(data) or (msg.get("sha256") or "").lower() != digest:
            raise DeckError("thumbnail differs from its fs.thumb.end")
        if out:
            with open(out, "wb") as handle:
                handle.write(data)
        elapsed = int((time.time() - started) * 1000)
        print(json.dumps({"mime": msg.get("mime"), "bytes": len(data),
                          "sha256": digest, "ms": elapsed}, sort_keys=True))
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
    if args.action == "thumb":
        return _fs_thumb(client, args.path, args.out, args.size)
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
    if args.action == "digest":
        paths = list(args.paths or ([args.path] if args.path is not None else []))
        fs_id = _fs_id()
        client.send_json({"t": "fs.digest", "id": fs_id, "paths": paths})
        msg = _fs_wait(client, fs_id)
        if msg.get("t") != "fs.digest":
            raise DeckError("expected fs.digest, got %r" % msg.get("t"))
        print(json.dumps(msg.get("digests") or {}, indent=None, separators=(",", ":"),
                         sort_keys=True))
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
    p = argparse.ArgumentParser(description="Fake Mac client / conformance tester for Contigua.",
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
    sub.add_parser("version", help="print the protocol hello/session/path ids", **spp)
    sub.add_parser("paths", help="list the phone's live paths (fakephone)", **spp)
    sp = sub.add_parser("switch", help="send path.switch and wait for the phone's marker", **spp)
    sp.add_argument("path", help="a path id, or 'current' for this client's path")
    sp.add_argument("--timeout", type=float, default=3.0, metavar="SECONDS")
    sp = sub.add_parser("kill-path", help="close a path (fakephone debug verb)", **spp)
    sp.add_argument("path")
    sp = sub.add_parser("pong-mode", help="a path's ping answer (fakephone debug verb)", **spp)
    sp.add_argument("path")
    sp.add_argument("mode", choices=["on", "off", "delay"])
    sp.add_argument("--ms", type=int, default=300)

    sp = sub.add_parser("icon", help="fetch an app icon PNG", **spp)
    sp.add_argument("pkg")
    sp.add_argument("--out", required=True, help="write the PNG here")
    sp.add_argument("--px", type=int, help="the 108 dp layer size to ask for (apps.icon's px)")
    sp.add_argument("--layers-dir", help="also write fg/bg/mono layer PNGs here")

    sp = sub.add_parser("open", help="open a window and record video", **spp)
    sp.add_argument("--new-instance", action="store_true", dest="new_instance",
                    help="ask the phone for another task of the app (window.open newInstance)")
    sp.add_argument("target", nargs="?", help="package to launch")
    sp.add_argument("--phone", action="store_true", help="phone mode instead of an app")
    sp.add_argument("--url", help="open this link (link.open) instead of an app")
    sp.add_argument("--w", type=int, required=True)
    sp.add_argument("--h", type=int, required=True)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--seconds", type=float, default=3.0)
    sp.add_argument("--out", help="write raw Annex-B H.264 here")

    sp = sub.add_parser("adopt",
                        help="tap the app's own New window, adopt the reported task and "
                             "prove both streams, Back/close and the launcher case (WIN-44…49)",
                        **spp)
    sp.add_argument("--pkg", default="com.android.chrome")
    sp.add_argument("--w", type=int, default=1280)
    sp.add_argument("--h", type=int, default=800)
    sp.add_argument("--dpi", type=int, default=160)
    sp.add_argument("--source-stream", type=int, default=1, dest="source_stream")
    sp.add_argument("--adopt-stream", type=int, default=2, dest="adopt_stream")
    sp.add_argument("--settle", type=float, default=2.0,
                    help="seconds to let the page load before the menu tap")
    sp.add_argument("--attempts", type=int, default=3)
    sp.add_argument("--task-timeout", type=float, default=8.0, dest="task_timeout")
    sp.add_argument("--adopt-timeout", type=float, default=25.0, dest="adopt_timeout")
    sp.add_argument("--phase-seconds", type=float, default=5.0, dest="phase_seconds")
    sp.add_argument("--out-prefix", default="/tmp/deckctl-adopt", dest="out_prefix")
    sp.add_argument("--adb", default="adb", help="adb binary for the launcher case")
    sp.add_argument("--serial", default="emulator-5554")
    sp.add_argument("--skip-launcher", action="store_true", dest="skip_launcher")

    sp = sub.add_parser("stats",
                        help="open a window, read stream.stats and prove pong.now", **spp)
    sp.add_argument("--pkg", default="com.android.settings")
    sp.add_argument("--w", type=int, default=900)
    sp.add_argument("--h", type=int, default=600)
    sp.add_argument("--dpi", type=int, default=160)
    sp.add_argument("--messages", type=int, default=3)
    sp.add_argument("--seconds", type=float, default=20.0)

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

    sp = sub.add_parser("ui-tree", help="open a phone mirror and read ui.tree N times", **spp)
    sp.add_argument("--w", type=int, default=400)
    sp.add_argument("--h", type=int, default=800)
    sp.add_argument("--dpi", type=int, default=160)
    sp.add_argument("--reads", type=int, default=2)
    sp.add_argument("--offscreen", action="store_true",
                    help="ask with offscreen: true, so off-screen rows are sent marked off (MCP-106)")
    sp.add_argument("--wait", type=float, default=5.0, help="seconds to wait for each reply")

    sp = sub.add_parser("ui-press", help="open a phone mirror, read ui.tree and ui.press keys", **spp)
    sp.add_argument("--w", type=int, default=400)
    sp.add_argument("--h", type=int, default=800)
    sp.add_argument("--dpi", type=int, default=160)
    sp.add_argument("--k", type=int, action="append", required=True, help="a key to press (repeat)")
    sp.add_argument("--expect", default=None, help="send this expect instead of the tree's label")
    sp.add_argument("--hold-ms", type=int, default=0, dest="hold_ms")
    sp.add_argument("--wait", type=float, default=5.0, help="seconds to wait for each reply")

    sp = sub.add_parser("ui-type", help="open a phone mirror and ui.type into its focused field", **spp)
    sp.add_argument("--w", type=int, default=400)
    sp.add_argument("--h", type=int, default=800)
    sp.add_argument("--dpi", type=int, default=160)
    sp.add_argument("--text", required=True)
    sp.add_argument("--clear", action="store_true")
    sp.add_argument("--submit", action="store_true")
    sp.add_argument("--wait", type=float, default=5.0, help="seconds to wait for the reply")

    sp = sub.add_parser("ui-settle", help="open a phone mirror and read ui.settle", **spp)
    sp.add_argument("--w", type=int, default=400)
    sp.add_argument("--h", type=int, default=800)
    sp.add_argument("--dpi", type=int, default=160)
    sp.add_argument("--quiet-ms", type=int, default=300, dest="quiet_ms")
    sp.add_argument("--timeout-ms", type=int, default=2000, dest="timeout_ms")
    sp.add_argument("--wait", type=float, default=5.0, help="seconds to wait for the reply")
    sp.add_argument("--no-stream", action="store_true", dest="no_stream",
                    help="send ui.settle without a stream and print the failure's stream and code")

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
    sp.add_argument("--phone", action="store_true",
                    help="open a phone window first, so state.secure is polled")
    sp.add_argument("--w", type=int, default=400)
    sp.add_argument("--h", type=int, default=800)
    sp.add_argument("--dpi", type=int, default=160)

    sp = sub.add_parser("wake-test",
                        help="phone.wake on one session: wait for screen off, wake, wait for on",
                        **spp)
    sp.add_argument("--off-timeout", type=float, default=40.0)
    sp.add_argument("--on-timeout", type=float, default=20.0)

    sp = sub.add_parser("wake", help="phone.wake: wake the phone's screen, print the state",
                        **spp)
    sp.add_argument("--wait", type=float, default=15.0,
                    help="seconds to wait for a state carrying screen on")

    sp = sub.add_parser("panel-test",
                        help="panel checks on one session: pause/resume, mirror + app, phone.panel off/on",
                        **spp)
    sp.add_argument("target", nargs="?", default="com.android.settings",
                    help="package the app window launches")
    sp.add_argument("--open-timeout", type=float, default=30.0)
    sp.add_argument("--settle", type=float, default=3.0, help="seconds each window gets to settle")
    sp.add_argument("--pause-seconds", type=float, default=4.0, help="inside the 30 s grace period")
    sp.add_argument("--resume-seconds", type=float, default=10.0, help="bound on the frame after a resume")
    sp.add_argument("--panel-timeout", type=float, default=10.0)
    sp.add_argument("--off-seconds", type=float, default=6.0,
                    help="seconds the mirror's frames are counted while the panel is off")
    sp.add_argument("--phase", choices=["all", "pause", "panel"], default="all",
                    help="pause: (a) only; panel: (b)+(c) only")

    sp = sub.add_parser("panel-hold",
                        help="mirror-only hold: off, keep the window open, then on (the NORMAL log line follows)",
                        **spp)
    sp.add_argument("--open-timeout", type=float, default=30.0)
    sp.add_argument("--panel-timeout", type=float, default=10.0)
    sp.add_argument("--hold-seconds", type=float, default=7.0,
                    help="seconds the panel is held with only the mirror open (3+ keep-alive steps)")

    sp = sub.add_parser("panel-press",
                        help="mirror-only hold, then wait for the person's power press to end it (prints ready first)",
                        **spp)
    sp.add_argument("--open-timeout", type=float, default=30.0)
    sp.add_argument("--panel-timeout", type=float, default=10.0)
    sp.add_argument("--press-timeout", type=float, default=20.0,
                    help="seconds to wait for state.panel on after the shell's power press")

    sp = sub.add_parser("panel", help="phone.panel: hold the mirrored panel off/on, print the state",
                        **spp)
    sp.add_argument("mode", choices=["off", "on"])
    sp.add_argument("--wait", type=float, default=15.0,
                    help="seconds to wait for a state carrying panel")

    sp = sub.add_parser("volume", help="phone.volume: set the music stream, print the state",
                        **spp)
    sp.add_argument("level", type=int)
    sp.add_argument("--wait", type=float, default=10.0,
                    help="seconds to wait for a state carrying volume")

    sp = sub.add_parser("dnd", help="phone.dnd: set the phone's DND, print the state",
                        **spp)
    sp.add_argument("mode", choices=["priority", "alarms", "none", "off"])
    sp.add_argument("--wait", type=float, default=10.0,
                    help="seconds to wait for a state carrying dnd")

    sp = sub.add_parser("clip-set", help="send clip.set TEXT: put TEXT on the phone's clipboard", **spp)
    sp.add_argument("text")

    sp = sub.add_parser("clipimage", help="send an image through clip.image.* (paste:true), print the done answer", **spp)
    sp.add_argument("path")
    sp.add_argument("--id", type=int, default=9001)
    sp.add_argument("--timeout", type=float, default=20.0)

    sp = sub.add_parser("drop", help="send one drop.start + DROP_DATA, print the result", **spp)
    sp.add_argument("path")
    sp.add_argument("--target", default=None, help="the app window's package (SHARE-17)")
    sp.add_argument("--index", type=int, default=1)
    sp.add_argument("--count", type=int, default=1)
    sp.add_argument("--id", type=int, default=9002)
    sp.add_argument("--timeout", type=float, default=90.0)

    sp = sub.add_parser("dropbatch", help="send one gesture's drops in one session (the Mac's batch)", **spp)
    sp.add_argument("path")
    sp.add_argument("--target", default=None, help="the app window's package (SHARE-17)")
    sp.add_argument("--count", type=int, default=3)
    sp.add_argument("--id", type=int, default=9100)
    sp.add_argument("--timeout", type=float, default=90.0)

    sp = sub.add_parser("ring", help="phone.ring: ring the phone (or --stop), print ring.state", **spp)
    sp.add_argument("--seconds", type=int, default=30, help="ring for 1..30 s (default 30)")
    sp.add_argument("--stop", action="store_true", help="send phone.ring.stop instead")
    sp.add_argument("--wait", type=float, default=10.0, help="seconds to wait for ring.state")

    sp = sub.add_parser("clip-watch", help="print every clip.set the phone sends (lengths only)", **spp)
    sp.add_argument("--seconds", type=float, default=30.0)
    sp.add_argument("--enable", action="store_true",
                    help="turn the Mac's clipboard gate on first")

    sp = sub.add_parser("notify", help="notifications: enable/action/dismiss/watch/image/live/end (ids and lengths only)", **spp)
    sp.add_argument("what", choices=["enable", "action", "dismiss", "watch", "image", "live", "end"])
    sp.add_argument("id", nargs="?")
    sp.add_argument("index", nargs="?", type=int)
    sp.add_argument("--text", default="", help="reply text for notify action (never printed)")
    sp.add_argument("--on", choices=["on", "off"], default="on")
    sp.add_argument("--seconds", type=float, default=20.0)
    sp.add_argument("--progress", type=float, default=0.5, help="live update fraction 0..1")
    sp.add_argument("--chip", default=None, help="live update chip text (length only is printed)")

    sp = sub.add_parser("media", help="media: watch/seek/volume/choose (counts, keys and numbers only)", **spp)
    sp.add_argument("what", choices=["watch", "seek", "volume", "choose", "drive"])
    sp.add_argument("--seconds", type=float, default=20.0, help="watch window")
    sp.add_argument("--position", type=int, default=0, help="seek target in ms")
    sp.add_argument("--level", type=int, default=0, help="volume level")
    sp.add_argument("--key", default=None, help="session key (optional for commands)")

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

    sp = sub.add_parser("density-burst", help="ten identical resizes in a second: one attach, no no-op lost, no frame gap", **spp)
    sp.add_argument("--apps", nargs="+", default=["com.android.settings"], metavar="PKG")
    sp.add_argument("--w", type=int, default=1600)
    sp.add_argument("--h", type=int, default=1200)
    sp.add_argument("--dpi", type=int, default=480)
    sp.add_argument("--burst-w", type=int, default=1920, help="the size every press asks for")
    sp.add_argument("--burst-h", type=int, default=1200)
    sp.add_argument("--burst-dpi", type=int, default=None,
                    help="the dpi every press asks for (default --dpi: a size-only burst)")
    sp.add_argument("--presses", type=int, default=10)
    sp.add_argument("--interval-ms", type=int, default=100, help="between presses (ten in one second)")
    sp.add_argument("--settle", type=float, default=2.0, help="seconds recorded after the last press")
    sp.add_argument("--launch-settle", type=float, default=1.5)
    sp.add_argument("--frame-ms", type=float, default=600, help="density_burst_first_frame_ms (docs/NFR.md)")
    sp.add_argument("--stall-ms", type=float, default=1500, help="density_burst_stall_ms (docs/NFR.md)")

    sp = sub.add_parser("exit-test", help="back out of the app; require app_exited", **spp)
    sp.add_argument("target")
    sp.add_argument("--w", type=int, default=1080)
    sp.add_argument("--h", type=int, default=2340)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--backs", type=int, default=5)
    sp.add_argument("--interval", type=float, default=2.5)
    sp.add_argument("--launch-settle", type=float, default=2.0)

    sp = sub.add_parser("fs", help="phone files: list/stat/digest/read/thumb/write/mkdir/move/delete/setattrs (docs/PROTOCOL.md)", **spp)
    sp.add_argument("action", choices=["list", "stat", "digest", "read", "thumb", "write", "mkdir", "move",
                                       "delete", "setattrs", "watch", "unwatch", "changes"])
    sp.add_argument("path", nargs="?", help="path relative to the phone's shared storage ('' = the root)")
    sp.add_argument("out", nargs="?", help="read: write the range here; write: the local file")
    sp.add_argument("--to", help="move: the destination path")
    sp.add_argument("--recursive", action="store_true", help="delete: a whole folder")
    sp.add_argument("--mtime", type=int, help="setattrs: milliseconds since the epoch")
    sp.add_argument("--offset", type=int, default=0, help="read: first byte (default 0)")
    sp.add_argument("--length", type=int, default=None, help="read: byte count (default: offset..EOF via stat)")
    sp.add_argument("--etag", help="read: the version the Mac believes (fs_stale on mismatch)")
    sp.add_argument("--size", type=int, default=512,
                    help="thumb: the wanted long side in pixels (1-4096, default 512)")
    sp.add_argument("--paths", nargs="+", help="watch/unwatch: the folders (relative)")
    sp.add_argument("--timeout", type=float, default=10.0,
                    help="changes: seconds to wait for a change (default 10)")
    sp.add_argument("--hold", type=float, default=0.0,
                    help="watch: keep the session open this many seconds and print each change")
    sp.add_argument("--off-after", type=float, default=0.0,
                    help="watch --hold: unwatch this many seconds in, report what comes after")

    sp = sub.add_parser("frame-png", help="decode a frame of a recorded .h264 to PNG (no session)", **spp)
    sp.add_argument("file")
    sp.add_argument("--out", required=True)
    sp.add_argument("--at", type=float, default=None, help="seconds into the file (default: last frame)")
    return p


# --- adopt: the app's own New window becomes another window (WIN-44…WIN-49) --
#
# The tap path the spike proved on the 1280×800 rig: Chrome's ⋮ at (1249, 68)
# and "New window" at (1068, 228), both normalised so the command follows the
# stream's own size.
TAP_MENU = (1249.0 / 1280.0, 68.0 / 800.0)
TAP_NEW_WINDOW = (1068.0 / 1280.0, 228.0 / 800.0)


def _adopt_tap(client, stream, point):
    nx, ny = point
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, nx, ny))
    time.sleep(0.06)
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, nx, ny))


def _adopt_poke(client, stream, direction=3.0):
    client.send_raw(proto.pack_scroll(stream, 0.5, 0.5, 0.0, direction))


def _adopt_messages(rec):
    with rec.lock:
        return list(rec.messages)


def _adopt_wait(rec, predicate, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rec.raise_if_broken(what)
        for message in _adopt_messages(rec):
            if predicate(message):
                return message
        time.sleep(0.05)
    return None


def _adopt_closed(rec, stream):
    with rec.lock:
        return rec.closed_reason.get(stream)


def _adopt_wait_closed(rec, stream, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        reason = _adopt_closed(rec, stream)
        if reason is not None:
            return reason
        rec.raise_if_broken("waiting for stream %d to close" % stream)
        time.sleep(0.05)
    return None


def _adopt_phase(rec, client, streams, seconds, prefix, name):
    """Poke each stream and count what it drew; decode the last frame."""
    for stream in streams:
        rec.begin_phase(stream, "%s-s%d-%s.h264" % (prefix, stream, name))
        client.send_json({"t": "window.keyframe", "stream": stream})
    deadline = time.time() + seconds
    direction = 3.0
    while time.time() < deadline:
        for stream in streams:
            _adopt_poke(client, stream, direction)
        direction = -direction
        time.sleep(0.4)
    frames = {}
    for stream in streams:
        frames[stream] = rec.end_phase(stream)
        path = "%s-s%d-%s.h264" % (prefix, stream, name)
        if frames[stream] > 0:
            try:
                dump_last_frame(path, "%s-s%d-%s.png" % (prefix, stream, name))
            except DeckError:
                pass
    return frames


def _adb_input(args, *command):
    if not args.adb:
        return False
    result = subprocess.run([args.adb, "-s", args.serial, "shell"] + [str(c) for c in command],
                            capture_output=True, text=True, timeout=60)
    return result.returncode == 0


def _adb_shell(args, *command, timeout=90):
    if not args.adb:
        return None
    return subprocess.run([args.adb, "-s", args.serial, "shell"] + [str(c) for c in command],
                          capture_output=True, text=True, timeout=timeout)


def _dump_ui(args, display, path):
    """A display's hierarchy; tries every spelling uiautomator has had."""
    remote = "/data/local/tmp/pd-deckctl-ui.xml"
    for command in (("uiautomator", "dump", "--display", str(display), remote),
                    ("uiautomator", "dump", remote, "--display", str(display)),
                    ("uiautomator", "dump", remote)):
        _adb_shell(args, *command)
        cat = _adb_shell(args, "cat", remote)
        text = (cat.stdout if cat else "") or ""
        if text.startswith("<?xml") or "<hierarchy" in text:
            try:
                with open(path, "w") as fp:
                    fp.write(text)
            except OSError:
                pass
            return text
    return None


def _ui_nodes(text):
    nodes = []
    for match in re.finditer(r"<node [^>]*>", text or ""):
        tag = match.group(0)
        node = {}
        for name in ("text", "content-desc", "resource-id", "bounds"):
            found = re.search(r'%s="([^"]*)"' % name, tag)
            node[name] = found.group(1) if found else ""
        nodes.append(node)
    return nodes


def _toolbar_desc(text):
    """Chrome's ⋮ label on this dump, or None. The resource id is exact; the
    description is "More options", with an update banner in front when one is
    pending (boot 9). A first-run screen has neither."""
    for node in _ui_nodes(text):
        desc = node["content-desc"].strip()
        if node["resource-id"].endswith(":id/menu_button") or "more options" in desc.lower():
            return desc or node["resource-id"]
    return None


def _adopt_toolbar(args, display, prefix):
    """Prove the streamed page has Chrome's toolbar before the New-window taps.

    Boot 3 burned a boot on a cleared Chrome sitting on its first-run screen:
    no toolbar, so the ⋮ tap hit nothing and no task was ever created. This
    names that state instead of retrying the tap three times."""
    if not args.adb:
        return None
    path = "%s-s%d-toolbar.xml" % (prefix, display)
    for attempt in range(3):
        label = _toolbar_desc(_dump_ui(args, display, path))
        if label is not None:
            return label
        if attempt < 2:
            time.sleep(2.0)
    return None


def cmd_adopt(client, args):
    """Stream the app, tap its own New window, adopt the reported task, and prove
    both streams, Back/close and the launcher's moved_to_phone (WIN-44…WIN-49)."""
    source = args.source_stream
    adopted_stream = args.adopt_stream
    prefix = args.out_prefix or "/tmp/deckctl-adopt"
    rec = StreamRecorder(client).start()
    task_reports = []

    def report(message):
        return message.get("t") == "window.task" and message.get("stream") == source

    try:
        client.send_json({"t": "window.open", "stream": source, "w": args.w,
                          "h": args.h, "dpi": args.dpi, "pkg": args.pkg})
        size = rec.wait_for_size(source, 25.0)
        print("source stream=%d size=%dx%d" % (source, size[0], size[1]), flush=True)
        deadline = time.time() + 20.0
        while time.time() < deadline:
            with rec.lock:
                if source in rec.first_frame_at:
                    break
            rec.raise_if_broken("waiting for the source's first frame")
            time.sleep(0.05)
        else:
            raise DeckError("the source stream drew no first frame")
        time.sleep(max(0.0, args.settle))

        # A fresh Chrome shows a notification promo; one Back dismisses it and
        # is a no-op on the new-tab page. The toolbar probe follows it: while
        # the promo's modal is up, uiautomator's dump contains that window
        # only, so a correct page would look toolbar-less (boot 4, 11:49).
        client.send_json({"t": "nav", "stream": source, "action": "back"})
        time.sleep(1.0)

        toolbar = _adopt_toolbar(args, source, prefix)
        if toolbar is None:
            raise DeckError(
                "no Chrome toolbar on stream %d after the first-run warm "
                "(uiautomator found no menu_button in %s-s%d-toolbar.xml); "
                "stopping before the New-window trigger"
                % (source, prefix, source))
        print("toolbar on stream %d: %s" % (source, toolbar), flush=True)

        task = None
        for attempt in range(1, args.attempts + 1):
            _adopt_tap(client, source, TAP_MENU)
            time.sleep(1.2)
            _adopt_tap(client, source, TAP_NEW_WINDOW)
            task = _adopt_wait(rec, report, args.task_timeout, "waiting for window.task")
            if task is not None:
                break
            print("attempt %d: no window.task; closing the menu" % attempt, flush=True)
            client.send_json({"t": "nav", "stream": source, "action": "back"})
            time.sleep(1.0)
        if task is None:
            raise DeckError("no window.task after %d attempts" % args.attempts)
        task_reports.append(task)
        print("PASS [WIN-44] window.task once stream=%s taskId=%s pkg=%s labelLen=%d"
              % (task.get("stream"), task.get("taskId"), task.get("pkg"),
                 len(task.get("label") or "")), flush=True)
        task_id = task.get("taskId")

        client.send_json({"t": "window.adopt", "stream": adopted_stream,
                          "taskId": task_id, "pkg": task.get("pkg"),
                          "w": args.w, "h": args.h, "dpi": args.dpi})
        opened = _adopt_wait(rec, lambda m: m.get("t") == "window.opened"
                             and m.get("stream") == adopted_stream,
                             args.adopt_timeout, "waiting for the adopt's window.opened")
        if opened is None:
            raise DeckError("window.adopt got no window.opened")
        if opened.get("started") != "moved" or opened.get("taskId") != task_id:
            raise DeckError("window.adopt answered started=%r taskId=%r, expected moved/%r"
                            % (opened.get("started"), opened.get("taskId"), task_id))
        print("PASS [WIN-46] window.opened stream=%s displayId=%s taskId=%s started=moved"
              % (opened.get("stream"), opened.get("displayId"), opened.get("taskId")), flush=True)

        frames = _adopt_phase(rec, client, [source, adopted_stream],
                              args.phase_seconds, prefix, "both")
        print("phase both: source frames=%d adopted frames=%d"
              % (frames[source], frames[adopted_stream]), flush=True)
        if frames[source] < 3 or frames[adopted_stream] < 3:
            raise DeckError("both streams did not draw (source %d, adopted %d)"
                            % (frames[source], frames[adopted_stream]))
        print("PASS [WIN-47] both streams drew after the adopt", flush=True)

        for press in (1, 2):
            client.send_json({"t": "nav", "stream": adopted_stream, "action": "back"})
            time.sleep(1.5)
            reason = _adopt_closed(rec, adopted_stream)
            print("adopted Back %d: closed=%s" % (press, reason), flush=True)
            if reason is not None:
                break
        if _adopt_closed(rec, adopted_stream) is None:
            client.send_json({"t": "window.close", "stream": adopted_stream})
            reason = _adopt_wait_closed(rec, adopted_stream, 10.0)
            if reason is None:
                raise DeckError("the adopted window did not close")
            print("adopted window.close answered reason=%s" % reason, flush=True)

        source_frames = _adopt_phase(rec, client, [source], args.phase_seconds, prefix,
                                     "source-after")
        print("phase source-after: frames=%d" % source_frames[source], flush=True)
        if source_frames[source] < 1:
            raise DeckError("the first stream stopped drawing after the adopted window closed")
        print("PASS [WIN-47] the first stream kept its picture", flush=True)

        if not args.skip_launcher:
            # The person opens the streamed app from the phone's launcher: the
            # same task id changes display. This is Home, then the Chrome icon
            # (the spike's own path); monkey is the fallback if the icon moved.
            _adb_input(args, "input", "-d", "0", "keyevent", "3")
            time.sleep(1.5)
            _adb_input(args, "input", "-d", "0", "tap", "663", "1970")
            reason = _adopt_wait_closed(rec, source, 12.0)
            if reason is None:
                _adb_input(args, "monkey", "-p", args.pkg, "-c",
                           "android.intent.category.LAUNCHER", "1")
                reason = _adopt_wait_closed(rec, source, 12.0)
            if reason != "moved_to_phone":
                raise DeckError("the launcher case closed the source as %r, expected moved_to_phone"
                                % (reason,))
            task_reports = [m for m in _adopt_messages(rec) if report(m)]
            if len(task_reports) != 1:
                raise DeckError("the launcher case reported %d tasks, expected none beyond the one"
                                % (len(task_reports) - 1))
            print("PASS [WIN-49] the launcher moved the task to the phone "
                  "(window.closed moved_to_phone) with no window.task", flush=True)
        print("ADOPT OK", flush=True)
        return 0
    finally:
        rec.stop()


def cmd_version(client, _args):
    print("hello.v=%s session=%s path=%s protocol=4"
          % (client.hello_v, client.session_id, client.path_id))
    return 0


def _debug_wait(client, want, timeout=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed while waiting for %r" % want)
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone error %s: %s"
                            % (msg.get("code"), msg.get("message", "")))
        if msg.get("t") == want:
            return msg
    return None


def cmd_paths(client, _args):
    """List the phone's live paths (fakephone answers debug.paths)."""
    reply = None
    if client.session_id is not None:
        client.send_json({"t": "debug.paths"})
        try:
            reply = _debug_wait(client, "paths.list", 2.0)
        except (DeckError, socket.timeout):
            reply = None
    if reply is None:
        print("%s%s (local; the phone did not list paths)"
              % (client.path_id, " *current*" if client.current_path == client.path_id else ""))
        return 0
    current = reply.get("current")
    for path_id in reply.get("paths") or []:
        print("%s%s" % (path_id, " *current*" if path_id == current else ""))
    return 0


def cmd_switch(client, args):
    target = args.path
    if target in ("current", "self"):
        target = client.current_path
    marker = {"t": "path.switch", "path": target, "seq": client.out_seq + 1}
    client.send_json(marker)
    deadline = time.time() + max(1.0, args.timeout)
    while time.time() < deadline:
        if client.peer_switch is not None:
            print("switched to %s (phone marker seq %s)"
                  % (client.peer_switch[0], client.peer_switch[1]))
            return 0
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is TIMEOUT:
            break
        if frame is None:
            raise DeckError("phone closed before its switch marker")
    sys.stderr.write("deckctl: no path.switch answer for %s\n" % target)
    return 1


def cmd_kill_path(client, args):
    target = args.path
    if target == client.path_id:
        client.close()
        print("closed %s (this client's only path)" % target)
        return 0
    client.send_json({"t": "debug.kill-path", "path": target})
    print("asked the fake phone to close %s" % target)
    return 0


def cmd_pong_mode(client, args):
    mode = args.mode
    client.send_json({"t": "debug.pong", "path": args.path, "mode": mode,
                      "ms": args.ms})
    print("pong-mode %s %s%s" % (args.path, mode,
                                  (" %dms" % args.ms) if mode == "delay" else ""))
    return 0


COMMANDS = {
    "apps": cmd_apps,
    "version": cmd_version,
    "paths": cmd_paths,
    "switch": cmd_switch,
    "kill-path": cmd_kill_path,
    "pong-mode": cmd_pong_mode,
    "icon": cmd_icon,
    "open": cmd_open,
    "stats": cmd_stats,
    "resize-test": cmd_resize_test,
    "input-test": cmd_input_test,
    "pause-test": cmd_pause_test,
    "ui-tree": cmd_ui_tree,
    "ui-press": cmd_ui_press,
    "ui-settle": cmd_ui_settle,
    "ui-type": cmd_ui_type,
    "latency": cmd_latency,
    "quality-test": cmd_quality_test,
    "watch-state": cmd_watch_state,
    "dnd": cmd_dnd,
    "volume": cmd_volume,
    "ring": cmd_ring,
    "wake": cmd_wake,
    "wake-test": cmd_wake_test,
    "panel": cmd_panel,
    "panel-hold": cmd_panel_hold,
    "panel-press": cmd_panel_press,
    "panel-test": cmd_panel_test,
    "clip-set": cmd_clip_set,
    "clipimage": cmd_clipimage,
    "drop": cmd_drop,
    "dropbatch": cmd_dropbatch,
    "clip-watch": cmd_clip_watch,
    "notify": cmd_notify,
    "media": cmd_media,
    "probe": cmd_probe,
    "multi": cmd_multi,
    "adopt": cmd_adopt,
    "resize-stress": cmd_resize_stress,
    "density-burst": cmd_density_burst,
    "exit-test": cmd_exit_test,
    "fs": cmd_fs,
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
    if args.name:
        state.name = args.name
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
