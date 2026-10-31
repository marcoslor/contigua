"""The fake phone's paths core (docs/PROTOCOL.md "Paths").

Mirrors the phone's Kotlin PathHub: a session's seq/ack/replay stream above
several TLS sockets, the 2 s ping, the switch marker and the credit that stops
a producer before the 16 MiB buffer overflows. Only the Mac decides a switch;
this side moves its sending path when the Mac's marker names it.
"""

import struct
import threading
import time

import proto

CURRENT_VERSION = 4

MAX_PATHS = 3
PING_MS = 2000
# D-1: one path is never pinged; with two or more, 2 s while the screen is on
# or a transfer runs, otherwise 15 s.
PING_IDLE_MS = 15000
TRANSFER_MS = 3000
PONG_TIMEOUT_MS = 1500
JOINED_PING_DROP_MS = 5000
ACK_MS = 10
ACK_FRAMES = 16


def now_ms():
    return int(time.monotonic() * 1000)


class Transport(object):
    """One TLS path. Writes are serialized per path; the hub owns routing."""

    def __init__(self, path_id, sock, plain=None):
        self.id = path_id
        self.sock = sock
        self.plain = plain if plain is not None else sock
        self.lock = threading.Lock()
        self.closed = False

    def send(self, data):
        if self.closed:
            raise OSError("path closed")
        with self.lock:
            self.sock.sendall(data)

    def close(self):
        self.closed = True
        for action in (lambda: self.plain.shutdown(1),
                       lambda: self.plain.shutdown(0),
                       lambda: self.plain.close(),
                       lambda: self.sock.close()):
            try:
                action()
            except OSError:
                pass


class ReplayBuffer(object):
    CAPACITY = 16 << 20
    BULK_CAPACITY = 12 << 20

    def __init__(self):
        self.last_ack = 1
        self.last_seq = 0
        self.held_bytes = 0
        self.bulk_bytes = 0
        self.entries = []

    @property
    def next_seq(self):
        return self.last_seq + 1

    def can_admit(self, size, bulk):
        if size < 0 or size > proto.MAX_FRAME + 4:
            return False
        if self.held_bytes + size > self.CAPACITY:
            return False
        return not bulk or self.bulk_bytes + size <= self.BULK_CAPACITY

    def append(self, seq, frame, bulk):
        if seq != self.next_seq:
            raise proto.ProtocolError("seq %d is not the next (%d)" % (seq, self.next_seq))
        if not self.can_admit(len(frame), bulk):
            raise proto.ProtocolError("replay buffer full for %d bytes" % len(frame))
        self.entries.append((seq, frame, bulk))
        self.last_seq = seq
        self.held_bytes += len(frame)
        if bulk:
            self.bulk_bytes += len(frame)

    def ack(self, next_expected):
        if next_expected <= self.last_ack:
            return 0
        self.last_ack = next_expected
        released = 0
        while self.entries:
            seq, frame, bulk = self.entries[0]
            if seq >= next_expected:
                break
            self.entries.pop(0)
            self.held_bytes -= len(frame)
            if bulk:
                self.bulk_bytes -= len(frame)
            released += 1
        return released

    def ack_above_sent(self, ack):
        return ack > self.last_seq + 1

    def unacked(self):
        return list(self.entries)


class ReorderWindow(object):
    MAX_FRAMES = 64
    MAX_BYTES = 4 << 20

    def __init__(self):
        self.expected = 1
        self.buffered = {}
        self.buffered_bytes = 0

    @property
    def ack(self):
        return self.expected

    def receive(self, seq, inner):
        """Return ("deliver", [inner...]), ("duplicate",) or ("full",)."""
        if seq < self.expected:
            return ("duplicate",)
        if seq == self.expected:
            out = [inner]
            self.expected += 1
            while self.expected in self.buffered:
                out.append(self.buffered.pop(self.expected))
                self.expected += 1
            self.buffered_bytes = sum(len(f.payload) for f in self.buffered.values())
            return ("deliver", out)
        if seq in self.buffered:
            return ("duplicate",)
        size = len(inner.payload)
        if len(self.buffered) >= self.MAX_FRAMES or self.buffered_bytes + size > self.MAX_BYTES:
            return ("full",)
        self.buffered[seq] = inner
        self.buffered_bytes += size
        return ("buffered",)


class PathHub(object):
    """The phone's path layer. The session thread consumes the events."""

    def __init__(self, log=lambda _line: None, now=now_ms, on_seq=None):
        self.log = log
        self.now = now
        self.on_seq = on_seq
        self.lock = threading.RLock()
        self.cv = threading.Condition(self.lock)
        self.paths = {}
        self.current = None
        self.replay = ReplayBuffer()
        self.reorder = ReorderWindow()
        self.ack_frames = 0
        self.last_ack_at = 0
        self.last_ping_at = 0
        self.last_bulk_at = 0
        self.ping_sent_at = {}
        self.joined_waiting = {}
        self.closed = False
        # --pong-mode overrides: path -> True (off) / milliseconds (delay).
        self.pong_modes = {}

    # -- paths --
    @property
    def path_count(self):
        with self.lock:
            return len(self.paths)

    @property
    def current_path(self):
        with self.lock:
            return self.current

    def start(self, transport):
        with self.lock:
            if self.paths:
                return
            self.paths[transport.id] = transport
            self.current = transport.id

    def attach(self, transport, joined=True):
        with self.lock:
            if self.closed or len(self.paths) >= MAX_PATHS or transport.id in self.paths:
                return False
            self.paths[transport.id] = transport
            if self.current is None:
                self.current = transport.id
            if joined:
                self.joined_waiting[transport.id] = self.now()
            return True

    def has_path(self, path_id):
        with self.lock:
            return path_id in self.paths

    def detach(self, path_id):
        with self.lock:
            transport = self.paths.pop(path_id, None)
            if transport is None:
                return False
            if self.current == path_id:
                self.current = None
            self.ping_sent_at.pop(path_id, None)
            self.joined_waiting.pop(path_id, None)
            transport.close()
            self.cv.notify_all()
            return True

    def close_all(self):
        with self.lock:
            self.closed = True
            all_paths = list(self.paths.values())
            self.paths.clear()
            self.current = None
            self.ping_sent_at.clear()
            self.joined_waiting.clear()
            self.cv.notify_all()
        for transport in all_paths:
            transport.close()

    def same_path(self, path_id):
        with self.lock:
            return self.paths.get(path_id)

    # -- sending --
    def send(self, data):
        """Send one framed message: reliable wrapped and kept, lossy bare."""
        if not data:
            return False
        type_ = data[4] & 0xFF
        if not proto.is_reliable(type_):
            target = self.same_path(self.current) if self.current else None
            if target is None:
                return False
            try:
                target.send(data)
                return True
            except OSError:
                self._failed(target.id)
                return False
        bulk = proto.is_bulk(type_)
        size = len(data) + proto.RELIABLE_WRAPPER
        with self.cv:
            while not self.closed and not self.replay.can_admit(size, bulk):
                self.cv.wait(0.1)
            if self.closed:
                return False
            seq = self.replay.next_seq
            inner = proto.Frame(type_, struct.unpack_from(">I", data, 5)[0], data[9:])
            wrapped = proto.pack_reliable(seq, inner)
            self.replay.append(seq, wrapped, bulk)
            if bulk:
                self.last_bulk_at = self.now()
            target = self.paths.get(self.current) if self.current else None
        if target is not None:
            try:
                target.send(wrapped)
            except OSError:
                self._failed(target.id)
        return True

    def send_bare_on(self, path_id, data):
        transport = self.same_path(path_id)
        if transport is None:
            return False
        try:
            transport.send(data)
            return True
        except OSError:
            self._failed(path_id)
            return False

    def send_json_on(self, path_id, obj):
        return self.send_bare_on(path_id, proto.pack_json(obj))

    def send_marker(self, to):
        self.send_marker_on(to, to)

    def send_marker_on(self, on_path, to):
        """The marker is reliable frame N; its `seq` field names N + 1."""
        with self.cv:
            if self.closed:
                return False
            while not self.replay.can_admit(64, False):
                self.cv.wait(0.1)
                if self.closed:
                    return False
            seq = self.replay.next_seq
            inner = proto.Frame(proto.TYPE_JSON, 0, proto.pack_json(
                {"t": "path.switch", "path": to, "seq": seq + 1})[9:])
            wrapped = proto.pack_reliable(seq, inner)
            self.replay.append(seq, wrapped, False)
        transport = self.same_path(on_path)
        if transport is not None:
            try:
                transport.send(wrapped)
            except OSError:
                self._failed(on_path)
        return True

    def replay_on_current(self):
        with self.lock:
            transport = self.paths.get(self.current) if self.current else None
            frames = [entry[1] for entry in self.replay.unacked()]
        if transport is None:
            return
        for frame in frames:
            try:
                transport.send(frame)
            except OSError:
                self._failed(transport.id)
                return

    def move_to(self, to):
        """Move the sending path. The old path is a standby, never closed:
        the Mac decides a path's life, and only a socket error or the Mac's
        close ends one (E-3)."""
        with self.lock:
            if to not in self.paths:
                return
            self.current = to

    def _failed(self, path_id):
        self.log("path down: %s" % path_id)
        self.detach(path_id)

    # -- receiving --
    def receive(self, path_id, frame):
        events = []
        if frame.type == proto.TYPE_ACK:
            try:
                ack = proto.unpack_ack(frame)
            except proto.ProtocolError:
                return [("ack_above",)]
            with self.cv:
                if self.replay.ack_above_sent(ack):
                    return [("ack_above",)]
                self.replay.ack(ack)
                self.cv.notify_all()
            return events
        if frame.type == proto.TYPE_RELIABLE:
            try:
                seq, inner = proto.unpack_reliable(frame)
            except proto.ProtocolError:
                return [("down", path_id)]
            with self.lock:
                result = self.reorder.receive(seq, inner)
                if result[0] in ("deliver", "buffered") and self.on_seq is not None:
                    # Duplicates are dropped before this: the log's seqs are
                    # what the stream actually delivered (possibly buffered
                    # until a gap fills, hence not sorted here).
                    self.on_seq(path_id, seq)
                if result[0] == "deliver":
                    if any(proto.is_bulk(f.type) for f in result[1]):
                        self.last_bulk_at = self.now()
                    for inner_frame in result[1]:
                        # A marker travels reliable, like every JSON frame: the
                        # inner path.switch is the peer's switch, not a message
                        # for the session (PATH-9).
                        marker = None
                        if inner_frame.type == proto.TYPE_JSON:
                            try:
                                marker = proto.unpack_json(inner_frame)
                            except Exception:
                                marker = None
                        if marker and marker.get("t") == "path.switch":
                            target = marker.get("path")
                            if target and self.has_path(target):
                                events.append(("peer_switch", target,
                                               marker.get("seq") or 0, path_id))
                            else:
                                self.log("path.switch for unknown path ignored")
                        else:
                            events.append(("deliver", inner_frame))
                    self.cv.notify_all()
                elif result[0] == "duplicate":
                    self._send_ack_now(path_id)
                elif result[0] == "full":
                    return [("backpressure",)]
            self._ack_later(path_id)
            return events
        if frame.type == proto.TYPE_JSON:
            try:
                msg = proto.unpack_json(frame)
            except Exception:
                msg = None
            if msg is not None:
                kind = msg.get("t")
                if kind == "path.ping":
                    ping_path = msg.get("path") or path_id
                    ts = msg.get("ts") or 0
                    if self.has_path(ping_path):
                        self._answer_ping(path_id, ping_path, ts)
                        events.append(("ping", ping_path))
                    return events
                if kind == "path.pong":
                    pong_path = msg.get("path") or path_id
                    if self.has_path(pong_path):
                        with self.lock:
                            sent = self.ping_sent_at.pop(pong_path, None)
                            self.joined_waiting.pop(pong_path, None)
                        rtt = max(0, self.now() - sent) if sent is not None else 0
                        events.append(("pong", pong_path, float(rtt)))
                    return events
                if kind == "path.switch":
                    target = msg.get("path")
                    seq = msg.get("seq") or 0
                    if target and self.has_path(target):
                        events.append(("peer_switch", target, seq, path_id))
                    else:
                        self.log("path.switch for unknown path ignored")
                    return events
        events.append(("deliver", frame))
        return events

    def _answer_ping(self, on_path, ping_path, ts):
        mode = self.pong_modes.get(ping_path)
        self.log("pong %s mode=%r" % (ping_path, mode))
        if mode is True or mode == "off":
            return
        if isinstance(mode, (int, float)) and mode > 0:
            threading.Timer(float(mode) / 1000.0, self.send_json_on,
                            args=(on_path, {"t": "path.pong", "path": ping_path, "ts": ts})).start()
            return
        self.send_json_on(on_path, {"t": "path.pong", "path": ping_path, "ts": ts})

    def set_pong_mode(self, path_id, mode):
        with self.lock:
            self.pong_modes[path_id] = mode

    def _send_ack_now(self, path_id):
        with self.lock:
            ack = self.reorder.ack
            self.last_ack_at = self.now()
            self.ack_frames = 0
        self.send_bare_on(path_id, proto.pack_ack(ack))

    def _ack_later(self, path_id):
        with self.lock:
            self.ack_frames += 1
            due = self.ack_frames >= ACK_FRAMES or self.now() - self.last_ack_at >= ACK_MS
            if due:
                self.ack_frames = 0
                self.last_ack_at = self.now()
        if due:
            self._send_ack_now(path_id)

    def await_reorder_space(self):
        with self.cv:
            while not self.closed and (
                    len(self.reorder.buffered) >= ReorderWindow.MAX_FRAMES or
                    self.reorder.buffered_bytes >= ReorderWindow.MAX_BYTES):
                self.cv.wait(0.05)

    # -- ping and the grace --
    def ping_now(self, path_id):
        """One immediate ping that counts as this round's (--ping-on-welcome).

        The real ticker pings a path the moment it is attached; this sends the
        same frame at the same point without waiting for the 2 s gate."""
        at = now_ms()
        with self.lock:
            if self.closed:
                return
            if path_id not in self.paths:
                return
            self.last_ping_at = at
            self.ping_sent_at[path_id] = at
        self.send_json_on(path_id, {"t": "path.ping", "path": path_id, "ts": at})

    def transfer_active(self):
        with self.lock:
            return self.now() - self.last_bulk_at <= TRANSFER_MS

    def ping_all(self, active=True):
        at = self.now()
        with self.lock:
            if self.closed:
                return
            if len(self.paths) < 2:
                # D-1: a one-path session is never pinged (TCP keepalive and
                # the session's own ping cover it).
                self.last_ping_at = at
                return
            interval = PING_MS if (active or at - self.last_bulk_at <= TRANSFER_MS) else PING_IDLE_MS
            if at - self.last_ping_at < interval:
                return
            self.last_ping_at = at
            targets = list(self.paths.keys())
        for path_id in targets:
            with self.lock:
                if path_id in self.paths:
                    self.ping_sent_at[path_id] = at
            self.send_json_on(path_id, {"t": "path.ping", "path": path_id, "ts": at})

    def pong_timeouts(self):
        at = self.now()
        with self.lock:
            lost = [pid for pid, sent in self.ping_sent_at.items()
                    if at - sent > PONG_TIMEOUT_MS]
            for path_id in lost:
                self.ping_sent_at.pop(path_id, None)
        return lost

    def joined_timeouts(self):
        at = self.now()
        with self.lock:
            lost = [pid for pid, joined in self.joined_waiting.items()
                    if at - joined > JOINED_PING_DROP_MS]
            for path_id in lost:
                self.joined_waiting.pop(path_id, None)
        return lost
