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
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import proto  # noqa: E402

DNS_SD = "/usr/bin/dns-sd"
SERVICE_TYPE = "_pocketdeck._tcp"
DEFAULT_STATE = os.path.expanduser("~/.pocketdeck-deckctl.json")
DEFAULT_TIMEOUT = 10.0
HANDSHAKE_TIMEOUT = 20.0
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

    # -- framing --
    def send_json(self, obj):
        self.sock.sendall(proto.pack_json(obj, obj.get("stream", 0) or 0))

    def send_raw(self, data):
        self.sock.sendall(data)

    def recv(self, timeout=DEFAULT_TIMEOUT):
        self.sock.settimeout(timeout)
        try:
            return proto.recv_frame(self.sock)
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


def open_session(host, port, state, code_provider, device_hint=None):
    """Return an authenticated Client. Tries stored keys, then pairing."""
    candidates = state.candidates(device_hint)
    last_error = None
    for device_id, key_hex in candidates:
        for attempt in range(4):
            sock = _connect_raw(host, port)
            client = Client(sock, state)
            try:
                client.authenticate(key_hex)
                client.device_id = client.challenge_id or device_id
                return client
            except Busy:
                client.close()
                if attempt == 3:
                    raise DeckError("phone busy: another session is active")
                time.sleep(0.2)
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
    for attempt in range(4):
        sock = _connect_raw(host, port)
        client = Client(sock, state)
        try:
            client.pair(code_provider)
            return client
        except Busy:
            client.close()
            if attempt == 3:
                raise DeckError("phone busy: another session is active")
            time.sleep(0.2)
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
            return _resolve_instance(instance, timeout)
        except DeckError as exc:
            last = exc
    raise last


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


# --- CLI -------------------------------------------------------------------
def make_code_provider(args):
    if args.code is None and not args.code_file:
        return None

    def provider():
        if args.code is not None:
            return args.code
        for _ in range(20):
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
    return p


COMMANDS = {
    "apps": cmd_apps,
    "icon": cmd_icon,
    "open": cmd_open,
    "resize-test": cmd_resize_test,
    "input-test": cmd_input_test,
    "pause-test": cmd_pause_test,
    "latency": cmd_latency,
}


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "open" and not args.phone and not args.target:
        sys.stderr.write("deckctl: error: open needs a package or --phone\n")
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
                              code_provider=make_code_provider(args), device_hint=device_hint)
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
