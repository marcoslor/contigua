#!/usr/bin/env python3
"""pdudpfault - a UDP datagram fault relay for one Contigua media plane.

The TCP twin (pdpathfault.py) shapes a path's request bytes; this one shapes
the datagram media plane's packets, without terminating anything. It sits on a
local port in front of the phone's media port:

    pdudpfault.py --listen 47961 --connect 127.0.0.1:47960 \
                  --mode pass|delay|throttle|delay-throttle|blackhole|stall \
                  [--delay-ms 100] [--rate-mbit 8] [--loss-pct 0] \
                  [--duplicate-pct 0] [--reorder-pct 0] [--reorder-delay-ms 30] \
                  [--stall-ms 100] [--stall-every-ms 1000] \
                  [--stall-long-ms 0] [--stall-long-at-ms 0] \
                  [--ctl-file /tmp/pdudpfault.ctl] [--events /tmp/pdudpfault.jsonl] \
                  [--seed 1]

Modes:
    pass       datagrams both ways, unmodified
    delay      each direction delayed by --delay-ms
    throttle   each direction paced at --rate-mbit
    delay-throttle  both at once
    blackhole  reads and drops; nothing is written (the socket stays up)
    stall      a good link that goes off-channel: delivery pauses --stall-ms
               every --stall-every-ms, and --stall-long-ms once at
               --stall-long-at-ms, then bursts (the AWDL pattern)

The extra faults apply in every mode that delivers: `--loss-pct` drops each
datagram independently, `--duplicate-pct` sends a second copy, and
`--reorder-pct` holds a datagram for `--reorder-delay-ms` so the next one
overtakes it. The knobs can be changed at run time through --ctl-file, one
directive per line (`mode blackhole`, `rate 2`, `loss 5`, `duplicate 10`,
`reorder 20`, `delay 120`); every line appended since the last read is applied
in order. Events are JSON Lines: `start`, `client`, `mode`, `ctl`, one `stats`
line per second, and a final `stats` at exit.

Not wired to anything yet: P3.2's UdP media plane owns the wiring, and the
same ctl-file syntax lets that round's checks use this relay unchanged.
"""

import argparse
import heapq
import json
import os
import random
import select
import signal
import socket
import sys
import time

MODES = ("pass", "delay", "throttle", "delay-throttle", "blackhole", "stall")
DIRECTIONS = (0, 1)  # 0 = client -> phone, 1 = phone -> client


def parse_directive(line):
    """One ctl-file line: `(key, value)`, or raise ValueError."""
    parts = line.split()
    if not parts:
        raise ValueError("empty directive")
    key = parts[0]
    if key == "mode":
        if len(parts) != 2 or parts[1] not in MODES:
            raise ValueError("mode needs one of %s" % "|".join(MODES))
        return key, parts[1]
    if key in ("rate", "loss", "duplicate", "reorder", "delay"):
        if len(parts) != 2:
            raise ValueError("%s needs one number" % key)
        try:
            value = float(parts[1])
        except ValueError:
            raise ValueError("%s %r is not a number" % (key, parts[1]))
        if key == "rate" and value <= 0:
            raise ValueError("rate must be positive")
        if key != "rate" and key != "delay" and not (0.0 <= value <= 100.0):
            raise ValueError("%s must be 0...100" % key)
        if key == "delay" and value < 0:
            raise ValueError("delay cannot be negative")
        return key, value
    raise ValueError("unknown directive %r" % key)


class Relay(object):
    def __init__(self, args):
        self.args = args
        self.mode = args.mode
        self.rate_mbit = float(args.rate_mbit)
        self.delay_ms = float(args.delay_ms)
        self.loss_pct = float(args.loss_pct)
        self.duplicate_pct = float(args.duplicate_pct)
        self.reorder_pct = float(args.reorder_pct)
        self.stall_ms = float(args.stall_ms)
        self.stall_every_ms = float(args.stall_every_ms)
        self.stall_long_ms = float(args.stall_long_ms)
        self.stall_long_at_ms = float(args.stall_long_at_ms)
        self.rng = random.Random(args.seed)
        self.started_at = time.monotonic()
        self.heap = []
        self.sequence = 0
        self.next_send = {0: 0.0, 1: 0.0}
        self.client = None
        self.stop = False
        self.ctl_offset = 0
        self.ctl_inode = None
        self.stats = {0: {"rx": 0, "tx": 0, "loss": 0, "blackhole": 0},
                      1: {"rx": 0, "tx": 0, "loss": 0, "blackhole": 0}}
        self.last_stats = time.monotonic()
        self.events_fp = open(args.events, "a") if args.events else None

    # -- events --
    def event(self, obj):
        if self.events_fp is None:
            return
        obj = dict(obj)
        obj.setdefault("ts", time.time())
        self.events_fp.write(json.dumps(obj, separators=(",", ":")) + "\n")
        self.events_fp.flush()

    def flush_stats(self):
        now = time.monotonic()
        self.last_stats = now
        a, b = self.stats[0], self.stats[1]
        self.event({"ev": "stats", "rx0": a["rx"], "tx0": a["tx"],
                    "loss0": a["loss"], "drop0": a["blackhole"],
                    "rx1": b["rx"], "tx1": b["tx"],
                    "loss1": b["loss"], "drop1": b["blackhole"]})

    # -- mode --
    def set_mode(self, mode):
        if mode not in MODES:
            self.event({"ev": "error", "message": "unknown mode %r" % (mode,)})
            return False
        if mode != self.mode:
            self.mode = mode
            self.event({"ev": "mode", "mode": mode})
        return True

    def apply_directive(self, key, value):
        if key == "mode":
            self.set_mode(value)
        elif key == "rate":
            self.rate_mbit = value
        elif key == "delay":
            self.delay_ms = value
        elif key == "loss":
            self.loss_pct = value
        elif key == "duplicate":
            self.duplicate_pct = value
        elif key == "reorder":
            self.reorder_pct = value

    def watch_ctl(self):
        path = self.args.ctl_file
        if not path:
            return
        try:
            info = os.stat(path)
        except OSError:
            return
        if self.ctl_inode != info.st_ino:
            self.ctl_inode = info.st_ino
            self.ctl_offset = 0
        if info.st_size < self.ctl_offset:
            self.ctl_offset = 0
        if info.st_size == self.ctl_offset:
            return
        try:
            with open(path, "r") as fp:
                fp.seek(self.ctl_offset)
                lines = fp.readlines()
                self.ctl_offset = fp.tell()
        except OSError:
            return
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            self.event({"ev": "ctl", "line": line})
            try:
                key, value = parse_directive(line)
            except ValueError as exc:
                self.event({"ev": "error", "message": str(exc)})
                continue
            self.apply_directive(key, value)

    # -- scheduling --
    def pace_due(self, direction, now, size):
        """Pacing: each direction's next send is size / rate later."""
        if self.mode not in ("throttle", "delay-throttle", "stall"):
            return now
        rate = max(0.001, self.rate_mbit) * 1000 * 1000 / 8.0
        self.next_send[direction] = max(self.next_send.get(direction, 0.0), now)
        self.next_send[direction] += size / rate
        return self.next_send[direction]

    def stall_delay(self, now):
        if self.mode != "stall":
            return 0.0
        elapsed = now - self.started_at
        long_at = self.stall_long_at_ms / 1000.0
        if self.stall_long_ms > 0 and long_at <= elapsed < long_at + self.stall_long_ms / 1000.0:
            return long_at + self.stall_long_ms / 1000.0 - elapsed
        every = self.stall_every_ms / 1000.0
        if every <= 0 or self.stall_ms <= 0:
            return 0.0
        phase = elapsed % every
        if phase < self.stall_ms / 1000.0:
            return self.stall_ms / 1000.0 - phase
        return 0.0

    def schedule(self, direction, data, now):
        """Fault and queue one datagram; returns False when it was dropped."""
        stats = self.stats[direction]
        stats["rx"] += 1
        if self.mode == "blackhole":
            stats["blackhole"] += 1
            return False
        if self.loss_pct > 0 and self.rng.random() * 100.0 < self.loss_pct:
            stats["loss"] += 1
            return False
        copies = 2 if (self.duplicate_pct > 0
                       and self.rng.random() * 100.0 < self.duplicate_pct) else 1
        for _ in range(copies):
            due = now
            if self.mode in ("delay", "delay-throttle"):
                due += self.delay_ms / 1000.0
            due = max(due, self.pace_due(direction, now, len(data)))
            due += self.stall_delay(now)
            if self.reorder_pct > 0 and self.rng.random() * 100.0 < self.reorder_pct:
                due += max(1.0, self.args.reorder_delay_ms) / 1000.0
            self.sequence += 1
            heapq.heappush(self.heap, (due, self.sequence, direction, data))
        return True

    # -- loop --
    def run(self):
        listen_host, listen_port = self.args.listen.rsplit(":", 1)
        upstream_host, upstream_port = self.args.connect.rsplit(":", 1)
        sock_in = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock_in.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock_in.bind((listen_host, int(listen_port)))
        sock_up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock_up.bind(("127.0.0.1", 0))
        upstream = (socket.gethostbyname(upstream_host), int(upstream_port))
        self.event({"ev": "start", "listen": self.args.listen,
                    "connect": self.args.connect, "mode": self.mode})
        print("pdudpfault %s -> %s mode=%s"
              % (self.args.listen, self.args.connect, self.mode), file=sys.stderr)
        sys.stderr.flush()
        try:
            while not self.stop:
                self.watch_ctl()
                now = time.monotonic()
                timeout = 0.05
                if self.heap:
                    timeout = max(0.0, min(timeout, self.heap[0][0] - now))
                try:
                    ready, _, _ = select.select([sock_in, sock_up], [], [], timeout)
                except OSError:
                    break
                if sock_in in ready:
                    try:
                        data, peer = sock_in.recvfrom(65535)
                    except OSError:
                        break
                    if self.client != peer:
                        self.client = peer
                        self.event({"ev": "client", "peer": "%s:%d" % peer})
                    self.schedule(0, data, time.monotonic())
                if sock_up in ready:
                    try:
                        data, _ = sock_up.recvfrom(65535)
                    except OSError:
                        break
                    if self.client is not None:
                        self.schedule(1, data, time.monotonic())
                now = time.monotonic()
                while self.heap and self.heap[0][0] <= now:
                    _, _, direction, data = heapq.heappop(self.heap)
                    try:
                        if direction == 0:
                            sock_up.sendto(data, upstream)
                            self.stats[0]["tx"] += 1
                        elif self.client is not None:
                            sock_in.sendto(data, self.client)
                            self.stats[1]["tx"] += 1
                    except OSError:
                        continue
                if now - self.last_stats >= 1.0:
                    self.flush_stats()
        finally:
            self.flush_stats()
            sock_in.close()
            sock_up.close()
            if self.events_fp is not None:
                self.events_fp.close()


def build_parser():
    p = argparse.ArgumentParser(description="A UDP fault relay for one media plane.")
    p.add_argument("--listen", required=True, metavar="HOST:PORT",
                   help="address to listen on (127.0.0.1:PORT)")
    p.add_argument("--connect", required=True, metavar="HOST:PORT",
                   help="the phone's media address")
    p.add_argument("--mode", choices=MODES, default="pass")
    p.add_argument("--delay-ms", type=float, default=100)
    p.add_argument("--rate-mbit", type=float, default=8)
    p.add_argument("--loss-pct", type=float, default=0)
    p.add_argument("--duplicate-pct", type=float, default=0)
    p.add_argument("--reorder-pct", type=float, default=0)
    p.add_argument("--reorder-delay-ms", type=float, default=30)
    p.add_argument("--stall-ms", type=float, default=100)
    p.add_argument("--stall-every-ms", type=float, default=1000)
    p.add_argument("--stall-long-ms", type=float, default=0)
    p.add_argument("--stall-long-at-ms", type=float, default=0)
    p.add_argument("--ctl-file", default=None,
                   help="write `mode blackhole`, `loss 5`, ... lines here")
    p.add_argument("--events", default=None, help="JSON Lines events here")
    p.add_argument("--seed", type=int, default=1,
                   help="the loss/duplicate/reorder RNG's seed")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    def stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    Relay(args).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
