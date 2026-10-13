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
import json
import os
import pty
import re
import select
import signal
import socket
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


# --- persisted client identity + per-device keys ---------------------------
class ClientState(object):
    def __init__(self, path):
        self.path = path
        self.client_id = None
        self.name = None
        self.keys = {}          # device id -> key hex
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
        self.keys = data.get("keys", {})
        self.order = data.get("order", list(self.keys.keys()))

    def save(self):
        data = {"clientId": self.client_id, "name": self.name,
                "keys": self.keys, "order": self.order}
        tmp = self.path + ".tmp"
        with open(tmp, "w") as fp:
            json.dump(data, fp, indent=2)
        os.replace(tmp, self.path)

    def ensure_identity(self, name):
        if not self.client_id:
            self.client_id = str(uuid.uuid4())
        if name:
            self.name = name
        elif not self.name:
            self.name = socket.gethostname()
        self.save()
        return self.client_id, self.name

    def remember(self, device_id, key_hex):
        self.keys[device_id] = key_hex
        if device_id in self.order:
            self.order.remove(device_id)
        self.order.insert(0, device_id)
        self.save()

    def candidates(self, device_hint=None):
        ids = list(self.order)
        if device_hint:
            ids = ([device_hint] if device_hint in self.keys else []) + \
                  [i for i in ids if i != device_hint]
        return [(i, self.keys[i]) for i in ids if i in self.keys]


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

    # -- handshake --
    def _hello_challenge(self, timeout=HANDSHAKE_TIMEOUT):
        client_id, name = self.state.ensure_identity(self.state.name)
        self.send_json({"t": "hello", "v": 1, "clientId": client_id, "name": name})
        frame = self.recv(timeout)
        if frame is TIMEOUT:
            raise DeckError("no challenge from phone (timeout)")
        if frame is None:
            raise DeckError("phone closed the connection during handshake")
        if frame.type != proto.TYPE_JSON:
            raise DeckError("expected JSON challenge, got %s" % frame.name)
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            if msg.get("code") == "busy":
                raise Busy()
            raise DeckError("phone error during handshake: %s" % msg.get("code"))
        if msg.get("t") != "challenge":
            raise DeckError("expected challenge, got %r" % msg.get("t"))
        self.challenge_id = msg.get("id")
        return msg["nonce"]

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
            if code == "auth_failed":
                raise AuthFailed()
            raise DeckError("phone error before welcome: %s" % code)
        if msg.get("t") != "welcome":
            raise DeckError("expected welcome, got %r" % msg.get("t"))
        self.device = msg.get("device", {})
        return msg

    def authenticate(self, key_hex):
        nonce = self._hello_challenge()
        # The challenge names the phone, so its stored key wins over the caller's guess.
        key_hex = self.state.keys.get(self.challenge_id, key_hex)
        mac = proto.hmac_hex(bytes.fromhex(key_hex), nonce)
        self.send_json({"t": "auth", "mac": mac})
        self._welcome()

    def pair(self, code_provider):
        nonce = self._hello_challenge()
        self.send_json({"t": "pair.request"})
        frame = self.recv(HANDSHAKE_TIMEOUT)
        if frame is TIMEOUT or frame is None:
            raise DeckError("no pair.code_shown from phone")
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("phone refused pairing: %s" % msg.get("code"))
        if msg.get("t") != "pair.code_shown":
            raise DeckError("expected pair.code_shown, got %r" % msg.get("t"))
        code = code_provider()
        self.send_json({"t": "pair.confirm", "code": str(code)})
        frame = self.recv(HANDSHAKE_TIMEOUT)
        if frame is TIMEOUT or frame is None:
            raise DeckError("no pair.ok from phone")
        msg = proto.unpack_json(frame)
        if msg.get("t") == "error":
            raise DeckError("pairing denied (%s)" % msg.get("code"))
        if msg.get("t") != "pair.ok" or "key" not in msg:
            raise DeckError("expected pair.ok with key, got %r" % msg.get("t"))
        self._welcome()
        device_id = self.device.get("id")
        self.state.remember(device_id, msg["key"])
        self.device_id = device_id


def _connect_raw(host, port, timeout=DEFAULT_TIMEOUT):
    try:
        return socket.create_connection((host, port), timeout=timeout)
    except OSError as exc:
        raise DeckError("cannot connect to %s:%s (%s)" % (host, port, exc))


def open_session(host, port, state, code_provider, device_hint=None, busy_retries=1):
    """Return an authenticated Client. Tries stored keys, then pairing."""
    candidates = state.candidates(device_hint)
    last_error = None
    for device_id, key_hex in candidates:
        for attempt in range(busy_retries):
            sock = _connect_raw(host, port)
            client = Client(sock, state)
            try:
                client.authenticate(key_hex)
                client.device_id = client.challenge_id or device_id
                return client
            except Busy:
                client.close()
                if attempt == busy_retries - 1:
                    raise DeckError("phone busy: another session is active")
                time.sleep(BUSY_RETRY_SLEEP)
                continue
            except AuthFailed:
                client.close()
                last_error = DeckError("stored key for device %s was rejected" % device_id)
                break
            except DeckError as exc:
                client.close()
                raise exc
    if code_provider is None:
        if last_error:
            raise last_error
        raise DeckError("not paired with this phone; pass --code/--code-file")
    for attempt in range(busy_retries):
        sock = _connect_raw(host, port)
        client = Client(sock, state)
        try:
            client.pair(code_provider)
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
    if args.phone:
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
    per real change, nothing periodic.
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
            print("%s state #%d locked=%s battery=%s charging=%s" % (
                time.strftime("%H:%M:%S"), count, msg.get("locked"),
                msg.get("battery"), msg.get("charging")))
    print("# %d state messages in %ss" % (count, args.seconds))
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
    want = (round16(args.w), round16(args.h))
    if size != want:
        raise proto.ProtocolError("VIDEO_CONFIG is %dx%d, expected %dx%d" % (size[0], size[1], want[0], want[1]))
    opened = rec.opened.get(stream, {})
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
def make_code_provider(args):
    if args.code is None and not args.code_file:
        return None

    def provider():
        if args.code is not None:
            return args.code
        # A human reads the code off the phone screen: allow enough time for
        # that (and for a poller that writes the file from outside).
        for _ in range(100):
            try:
                with open(args.code_file) as fp:
                    value = fp.read().strip()
                if value:
                    return value
            except (IOError, OSError):
                pass
            time.sleep(0.1)
        raise DeckError("could not read pairing code from %s" % args.code_file)

    return provider


def build_parser():
    p = argparse.ArgumentParser(description="Fake Mac client / conformance tester for PocketDeck.",
                                allow_abbrev=False)
    p.add_argument("--host", help="phone host")
    p.add_argument("--port", type=int, help="phone port")
    p.add_argument("--discover", action="store_true", help="find the phone over mDNS")
    p.add_argument("--instance", help="mDNS instance name to use with --discover")
    p.add_argument("--code", help="pairing code (pairs instead of using a stored key)")
    p.add_argument("--code-file", help="read the pairing code from this file")
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

    sp = sub.add_parser("exit-test", help="back out of the app; require app_exited", **spp)
    sp.add_argument("target")
    sp.add_argument("--w", type=int, default=1080)
    sp.add_argument("--h", type=int, default=2340)
    sp.add_argument("--dpi", type=int, default=450)
    sp.add_argument("--backs", type=int, default=5)
    sp.add_argument("--interval", type=float, default=2.5)
    sp.add_argument("--launch-settle", type=float, default=2.0)

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
    "probe": cmd_probe,
    "multi": cmd_multi,
    "exit-test": cmd_exit_test,
    "frame-png": cmd_frame_png,
}


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "open" and not args.phone and not args.target:
        sys.stderr.write("deckctl: error: open needs a package or --phone\n")
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
                              code_provider=make_code_provider(args), device_hint=device_hint,
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
