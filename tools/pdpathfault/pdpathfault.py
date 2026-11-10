#!/usr/bin/env python3
"""pdpathfault - a TCP fault proxy in front of one PocketDeck path listener.

Sits between the Mac and the phone so a check can break a path exactly as a
person's Wi-Fi would, without touching the other paths:

    pdpathfault.py --listen 47961 --connect 127.0.0.1:47960 \
                   --mode pass|delay|blackhole|pass-new|rst|throttle|delay-throttle \
                   [--delay-ms 120] [--rate-mbit 2] [--ctl-file /tmp/pdpathfault.ctl] \
                   [--script /tmp/pdpathfault.timeline]

Modes (docs/design/paths.md §10.3):
    pass       bytes both ways, unmodified (the default)
    delay      each direction delayed by --delay-ms, in order
    blackhole  reads and drops, writes nothing (a dead radio, socket open)
    pass-new   connections already open keep dropping (a socket in TCP's
               retransmission backoff after the radio came back); connections
               accepted after the change pass, so a fresh path can carry the
               session while the old one stays silent
    rst        closes both sides with a reset at once
    throttle   caps each direction at --rate-mbit
    delay-throttle  both at once (a 100 ms, 3 Mbit/s link)
    stall      a good link at --rate-mbit that goes off-channel: delivery
               pauses --stall-ms every --stall-every-ms, and --stall-long-ms
               once at --stall-long-at-ms, then bursts (the AWDL pattern)

The mode can be changed at run time by writing one line to --ctl-file
(`mode blackhole`), so a check can kill a path at a precise byte of a transfer.
A timeline script changes it on a clock instead, for the link's own pattern:

    at 10 throttle 3      # from 10 s: cap each direction at 3 Mbit/s
    at 20 stall           # 20 s: the AWDL off-channel pattern (--stall-*)
    at 30 blackhole       # 30 s: read and drop, keep the socket open
    at 33 pass            # 33 s: bytes again
    at 40 rate 10         # a rate change alone

Each line is `at SECONDS ACTION [ARG|key=value ...]`; actions are any mode
name, `mode NAME`, `rate MBIT` or `delay MS`, with `stall_ms=`,
`stall_every_ms=`, `stall_long_ms=` and `stall_long_at_ms=` as settings.
Times are seconds from the proxy listening and must not go backwards.
Every accepted connection and each mode change is a JSON line on --events. A
peer's FIN is forwarded to the other side (the connection is half-closed, not
left hanging), and delivered bytes are reported per direction (`"ev":"bytes"`),
so a check can show where a transfer actually ran.
"""

import argparse
import json
import os
import queue
import signal
import socket
import struct
import sys
import threading
import time

MODES = ("pass", "delay", "blackhole", "pass-new", "rst", "throttle", "delay-throttle", "stall")
CHUNK = 65536
# Read at most this much ahead of the forwarder per direction: a real socket's
# receive buffer is bounded, and a proxy with an unbounded queue would hide the
# sender's own write buffer (the Mac's outbox never fills, so a check could not
# see back-pressure at all).
QUEUE_CAP = 256 * 1024
SETTING_KEYS = ("stall_ms", "stall_every_ms", "stall_long_ms", "stall_long_at_ms")


def _settings(parts, number):
    """`key=value` settings after a timeline action, validated."""
    out = {}
    for part in parts:
        if "=" not in part:
            raise ValueError("line %d: expected key=value, got %r" % (number, part))
        key, value = part.split("=", 1)
        if key in ("rate", "rate_mbit"):
            out["rate"] = float(value)
        elif key in ("delay", "delay_ms"):
            out["delay_ms"] = float(value)
        elif key in SETTING_KEYS:
            out[key] = float(value)
        else:
            raise ValueError("line %d: unknown setting %r" % (number, key))
    return out


def parse_script(text):
    """The `--script` timeline: [(seconds, settings)], in order.

    A settings dict holds any of `mode`, `rate`, `delay_ms` and the four
    `stall_*` knobs. Times are non-negative and never go backwards.
    """
    steps = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 3 or parts[0] != "at":
            raise ValueError("line %d: expected `at SECONDS ACTION ...`" % number)
        try:
            at = float(parts[1])
        except ValueError:
            raise ValueError("line %d: seconds %r is not a number" % (number, parts[1]))
        if at < 0:
            raise ValueError("line %d: seconds cannot be negative" % number)
        if steps and at < steps[-1][0]:
            raise ValueError("line %d: `at` goes backwards" % number)
        verb, tail = parts[2], parts[3:]
        settings = {}
        if verb == "rate":
            if len(tail) != 1:
                raise ValueError("line %d: `rate` needs one Mbit/s value" % number)
            settings["rate"] = float(tail[0])
        elif verb == "delay":
            if len(tail) != 1:
                raise ValueError("line %d: `delay` needs one millisecond value" % number)
            settings["delay_ms"] = float(tail[0])
        elif verb == "mode":
            if not tail:
                raise ValueError("line %d: `mode` needs a mode name" % number)
            settings["mode"] = tail[0]
            settings.update(_settings(tail[1:], number))
        elif verb in MODES:
            settings["mode"] = verb
            if tail and "=" not in tail[0]:
                settings["rate"] = float(tail[0])
                tail = tail[1:]
            settings.update(_settings(tail, number))
        else:
            raise ValueError("line %d: unknown action %r" % (number, verb))
        if "mode" in settings and settings["mode"] not in MODES:
            raise ValueError("line %d: unknown mode %r" % (number, settings["mode"]))
        steps.append((at, settings))
    return steps


class Proxy(object):
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.mode = args.mode
        self.connections = []
        self.stop = threading.Event()
        self.events_lock = threading.Lock()
        self.events_fp = open(args.events, "a") if args.events else None
        self.conn_seq = 0
        # `pass-new`: connections with an id at or below this were already
        # open when the lift happened and keep the black hole (a stale socket).
        self.split_at = 0
        self._ctl_mtime = None
        # `stall`: the off-channel clock starts with the proxy.
        self.started_at = time.monotonic()
        self.timeline = list(getattr(args, "timeline", None) or [])
        self.timeline_origin = self.started_at

    # -- events --
    def event(self, obj):
        if self.events_fp is None:
            return
        obj = dict(obj)
        obj.setdefault("ts", time.time())
        with self.events_lock:
            self.events_fp.write(json.dumps(obj, separators=(",", ":")) + "\n")
            self.events_fp.flush()

    # -- mode --
    def set_mode(self, mode):
        if mode not in MODES:
            self.event({"ev": "error", "message": "unknown mode %r" % (mode,)})
            return False
        with self.lock:
            if mode == self.mode:
                return True
            if mode == "pass-new":
                self.split_at = self.conn_seq
            self.mode = mode
            self.event({"ev": "mode", "mode": mode})
            connections = list(self.connections)
        if mode == "rst":
            for conn in connections:
                conn.reset()
        return True

    def get_mode(self):
        with self.lock:
            return self.mode

    def effective_mode(self, conn):
        """`pass-new` splits by connection age; every other mode is global."""
        with self.lock:
            if self.mode != "pass-new":
                return self.mode
            return "pass" if conn.id > self.split_at else "blackhole"

    def run_timeline(self):
        """Apply the `--script` steps at their seconds from listening."""
        for at, settings in self.timeline:
            while not self.stop.is_set():
                left = self.timeline_origin + at - time.monotonic()
                if left <= 0:
                    break
                if self.stop.wait(min(left, 1.0)):
                    return
            if self.stop.is_set():
                return
            self.apply_step(at, settings)

    def apply_step(self, at, settings):
        """One timeline step: settings first, then the mode it names."""
        now = time.monotonic() - self.timeline_origin
        action = dict(settings)
        self.event({"ev": "timeline", "at_plan": at,
                    "at": round(now, 3), "action": action})
        if "rate" in settings:
            self.args.rate_mbit = float(settings["rate"])
        if "delay_ms" in settings:
            self.args.delay_ms = float(settings["delay_ms"])
        for key in SETTING_KEYS:
            if key in settings:
                setattr(self.args, key, int(settings[key]))
        if "mode" in settings:
            self.set_mode(settings["mode"])

    def watch_ctl(self):
        path = self.args.ctl_file
        if not path:
            return
        while not self.stop.is_set():
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                mtime = None
            if mtime != self._ctl_mtime and mtime is not None:
                self._ctl_mtime = mtime
                try:
                    with open(path, "r") as fp:
                        lines = [line.strip() for line in fp if line.strip()]
                except OSError:
                    lines = []
                if lines:
                    last = lines[-1]
                    self.event({"ev": "ctl", "line": lines[-1]})
                    if last.startswith("rate "):
                        try:
                            self.args.rate_mbit = float(last[5:].strip())
                        except ValueError:
                            pass
                        continue
                    if last.startswith("mode "):
                        last = last[5:].strip()
                    self.set_mode(last)
            self.stop.wait(0.05)

    # -- connections --
    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", self.args.listen))
        srv.listen(16)
        srv.settimeout(0.25)
        self.event({"ev": "start", "listen": self.args.listen,
                    "connect": self.args.connect, "mode": self.mode,
                    "delay_ms": self.args.delay_ms, "rate_mbit": self.args.rate_mbit})
        self.timeline_origin = time.monotonic()
        threading.Thread(target=self.watch_ctl, daemon=True).start()
        if self.timeline:
            threading.Thread(target=self.run_timeline, daemon=True).start()
        print("pdpathfault 127.0.0.1:%d -> %s mode=%s"
              % (self.args.listen, self.args.connect, self.mode), file=sys.stderr)
        sys.stderr.flush()
        try:
            while not self.stop.is_set():
                try:
                    client, peer = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                thread = threading.Thread(target=self.handle, args=(client, peer),
                                          daemon=True)
                thread.start()
        finally:
            srv.close()
            self.stop.set()
            with self.lock:
                connections = list(self.connections)
            for conn in connections:
                conn.close()
            if self.events_fp is not None:
                self.events_fp.close()

    def handle(self, client, peer):
        with self.lock:
            self.conn_seq += 1
            conn_id = self.conn_seq
        try:
            host, port = self.args.connect.rsplit(":", 1)
            upstream = socket.create_connection((host, int(port)), timeout=5.0)
        except OSError as exc:
            self.event({"ev": "conn", "id": conn_id, "peer": "%s:%d" % peer,
                        "ok": False, "error": str(exc)})
            try:
                client.close()
            except OSError:
                pass
            return
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client.settimeout(None)
        upstream.settimeout(None)
        conn = Connection(self, conn_id, client, upstream, peer)
        with self.lock:
            self.connections.append(conn)
        self.event({"ev": "conn", "id": conn_id, "peer": "%s:%d" % peer,
                    "mode": self.get_mode(), "ok": True})
        try:
            if self.get_mode() == "rst":
                conn.reset()
                return
            conn.run()
        finally:
            with self.lock:
                if conn in self.connections:
                    self.connections.remove(conn)
            conn.close()


class Connection(object):
    """One proxied TCP pair. Each direction may be delayed, dropped or capped."""

    def __init__(self, proxy, conn_id, client, upstream, peer):
        self.proxy = proxy
        self.id = conn_id
        self.client = client
        self.upstream = upstream
        self.peer = peer
        self.stop = threading.Event()
        self.queues = {0: queue.Queue(), 1: queue.Queue()}
        self.threads = []
        self.token = {0: 0.0, 1: 0.0}
        # Delivered bytes per direction: a drop check has to show the data
        # moving on one proxy and then on the other, not just the final hash.
        self.bytes = {0: 0, 1: 0}
        self.pending_bytes = {0: 0, 1: 0}
        self.queued = {0: 0, 1: 0}
        self.queue_cv = threading.Condition()
        self.last_bytes_event = {0: 0.0, 1: 0.0}

    def reset(self):
        for sock in (self.client, self.upstream):
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct.pack("ii", 1, 0))
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass
        self.stop.set()

    def close(self):
        self.stop.set()
        for direction in (0, 1):
            self._flush_bytes(direction)
        for sock in (self.client, self.upstream):
            try:
                sock.close()
            except OSError:
                pass
        self.proxy.event({"ev": "close", "id": self.id})

    # -- byte accounting --
    def _count_bytes(self, direction, size):
        now = time.time()
        self.bytes[direction] += size
        self.pending_bytes[direction] += size
        if now - self.last_bytes_event[direction] >= 0.5:
            self._flush_bytes(direction, now)

    def _flush_bytes(self, direction, now=None):
        size = self.pending_bytes[direction]
        if size <= 0:
            return
        now = time.time() if now is None else now
        self.pending_bytes[direction] = 0
        self.last_bytes_event[direction] = now
        self.proxy.event({"ev": "bytes", "id": self.id, "dir": direction,
                          "n": size, "total": self.bytes[direction], "ts": now})

    def run(self):
        for direction in (0, 1):
            self.threads.append(threading.Thread(target=self._forward,
                                                 args=(direction,), daemon=True))
        self.threads.append(threading.Thread(target=self._control, daemon=True))
        for thread in self.threads:
            thread.start()
        self.threads[0].join()
        self.threads[1].join()

    # direction 0 = client -> upstream, 1 = upstream -> client
    def _read_loop(self, direction):
        src = self.client if direction == 0 else self.upstream
        while not self.stop.is_set():
            try:
                data = src.recv(CHUNK)
            except OSError:
                break
            if not data:
                break
            # Only a throttled link models a bounded buffer: `pass` is a wire,
            # and capping it would throttle the checks that stream video and
            # file data through it side by side.
            if self.proxy.get_mode() in ("throttle", "delay-throttle", "stall"):
                with self.queue_cv:
                    while self.queued[direction] >= QUEUE_CAP and not self.stop.is_set():
                        self.queue_cv.wait(0.02)
                    self.queued[direction] += len(data)
            self.queues[direction].put((time.time(), data))
        # The peer's FIN: the other side of this proxy has to see it. A path
        # check once waited out the Mac's whole 6 s connect timeout because a
        # phone-side close stopped here (it looked like a stalled handshake).
        self.proxy.event({"ev": "eof", "id": self.id, "dir": direction})
        self.queues[direction].put(None)

    def _forward(self, direction):
        reader = threading.Thread(target=self._read_loop, args=(direction,), daemon=True)
        reader.start()
        dst = self.upstream if direction == 0 else self.client
        while not self.stop.is_set():
            item = self.queues[direction].get()
            if item is None:
                # Half-close: the peer ended this direction; pass the FIN on
                # and let the other direction keep carrying bytes.
                self._flush_bytes(direction)
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return
            enqueued, data = item
            mode = self.proxy.effective_mode(self)
            if mode == "rst":
                self.reset()
                return
            if mode == "blackhole":
                self._released(direction, len(data))
                continue
            if mode in ("delay", "delay-throttle"):
                due = enqueued + self.proxy.args.delay_ms / 1000.0
                left = due - time.time()
                if left > 0 and self.stop.wait(min(left, 1.0)):
                    return
            if mode in ("throttle", "delay-throttle", "stall"):
                self._throttle(direction, len(data))
            if mode == "stall":
                self._stall_wait()
            try:
                dst.sendall(data)
            except OSError:
                # A broken destination makes the other direction pointless.
                self.stop.set()
                return
            self._released(direction, len(data))
            self._count_bytes(direction, len(data))

    def _released(self, direction, size):
        with self.queue_cv:
            self.queued[direction] = max(0, self.queued[direction] - size)
            self.queue_cv.notify_all()

    def _throttle(self, direction, size):
        rate = max(0.001, float(self.proxy.args.rate_mbit)) * 1000 * 1000 / 8.0
        due = time.time() + size / rate
        now = time.time()
        if self.token[direction] < now:
            self.token[direction] = now
        self.token[direction] = max(self.token[direction], due)
        sleep_for = self.token[direction] - now
        if sleep_for > 0:
            self.stop.wait(min(sleep_for, 1.0))

    def _stall_wait(self):
        """Hold delivery while the radio is off-channel, then burst (AWDL).

        The schedule is fixed from the proxy's start: a short pause every
        `--stall-every-ms` and one long pause at `--stall-long-at-ms`. Bytes
        are read and queued throughout, exactly as the access point buffers
        them while the Mac's radio is on another channel.
        """
        args = self.proxy.args
        elapsed = time.monotonic() - self.proxy.started_at
        long_at = args.stall_long_at_ms / 1000.0
        if args.stall_long_ms > 0 and long_at <= elapsed < long_at + args.stall_long_ms / 1000.0:
            self.stop.wait(long_at + args.stall_long_ms / 1000.0 - elapsed)
            return
        every = args.stall_every_ms / 1000.0
        if every <= 0 or args.stall_ms <= 0:
            return
        phase = elapsed % every
        if phase < args.stall_ms / 1000.0:
            self.stop.wait(args.stall_ms / 1000.0 - phase)

    def _control(self):
        while not self.stop.wait(0.1):
            if self.proxy.get_mode() == "rst":
                self.reset()
                return


def build_parser():
    p = argparse.ArgumentParser(description="A TCP fault proxy for one PocketDeck path.")
    p.add_argument("--listen", type=int, required=True, help="port to listen on")
    p.add_argument("--connect", required=True, metavar="HOST:PORT",
                   help="the path listener behind the proxy")
    p.add_argument("--mode", choices=MODES, default="pass")
    p.add_argument("--delay-ms", type=int, default=120)
    p.add_argument("--rate-mbit", type=float, default=2.0)
    p.add_argument("--stall-ms", type=int, default=100,
                   help="stall mode: delivery pause length")
    p.add_argument("--stall-every-ms", type=int, default=1000,
                   help="stall mode: pause cadence")
    p.add_argument("--stall-long-ms", type=int, default=0,
                   help="stall mode: one longer pause")
    p.add_argument("--stall-long-at-ms", type=int, default=0,
                   help="stall mode: when the long pause starts")
    p.add_argument("--ctl-file", default=None,
                   help="write `mode blackhole` here to change the mode")
    p.add_argument("--script", default=None,
                   help="timeline file: `at 10 throttle 3`")
    p.add_argument("--events", default=None, help="JSON Lines events here")
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    args.timeline = []
    if args.script:
        try:
            with open(args.script, "r") as fp:
                args.timeline = parse_script(fp.read())
        except (OSError, ValueError) as exc:
            print("pdpathfault: --script: %s" % exc, file=sys.stderr)
            return 2

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    Proxy(args).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
