#!/usr/bin/env python3
"""pdudpfault's directives, faults and ctl changes, on local UDP sockets.

The UDP media plane (P3.2) will hand its datagrams to this relay the way the
TCP planes use pdpathfault. These checks pin that it delivers both ways, that
loss/duplicate/reorder/delay/rate behave, and that a ctl-file line changes a
running relay.

Run: python3 tools/pdpathfault/test_udpfault.py
"""

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RELAY = os.path.join(HERE, "pdudpfault.py")
sys.path.insert(0, HERE)
import pdudpfault  # noqa: E402

FAILED = []


def fail(message):
    FAILED.append(message)
    print("UDPFAULT-CHECK FAIL: %s" % message)


def ok(message):
    print("UDPFAULT-CHECK PASS: %s" % message)


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class Echo(object):
    """A UDP echo peer that counts every datagram it receives."""

    def __init__(self):
        self.port = free_port()
        self.received = []
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", self.port))
        self.sock.settimeout(0.1)
        self.stop = False
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while not self.stop:
            try:
                data, peer = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                return
            self.received.append(data)
            try:
                self.sock.sendto(data, peer)
            except OSError:
                return

    def finish(self):
        self.stop = True
        self.thread.join(timeout=2)
        self.sock.close()


class Relay(object):
    def __init__(self, work, phone_port, args):
        self.events = os.path.join(work, "events-%d.jsonl" % time.time_ns())
        self.ctl = os.path.join(work, "ctl-%d" % time.time_ns())
        open(self.ctl, "w").close()
        self.port = free_port()
        command = [sys.executable, RELAY,
                   "--listen", "127.0.0.1:%d" % self.port,
                   "--connect", "127.0.0.1:%d" % phone_port,
                   "--events", self.events, "--ctl-file", self.ctl] + args
        self.proc = subprocess.Popen(command, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        self._wait_listening()

    def _wait_listening(self):
        deadline = time.time() + 5
        while time.time() < deadline:
            if os.path.exists(self.events):
                with open(self.events) as fp:
                    if any('"ev":"start"' in line for line in fp):
                        return
            time.sleep(0.02)
        raise RuntimeError("the relay did not start")

    def directives(self, *lines):
        with open(self.ctl, "a") as fp:
            for line in lines:
                fp.write(line + "\n")

    def lines(self):
        try:
            with open(self.events) as fp:
                return [json.loads(line) for line in fp if line.strip()]
        except (OSError, ValueError):
            return []

    def stats(self):
        found = [e for e in self.lines() if e.get("ev") == "stats"]
        return found[-1] if found else {}

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


def client(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.4)
    return sock


def recv_all(sock, seconds=0.5):
    out = []
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            continue
        except OSError:
            break
        out.append(data)
    return out


def check_directives():
    good = {
        "mode blackhole": ("mode", "blackhole"),
        "rate 2": ("rate", 2.0),
        "loss 5": ("loss", 5.0),
        "duplicate 10": ("duplicate", 10.0),
        "reorder 20": ("reorder", 20.0),
        "delay 120": ("delay", 120.0),
    }
    for line, expected in good.items():
        if pdudpfault.parse_directive(line) != expected:
            fail("directive %r did not parse as %r" % (line, expected))
    for line in ("mode nowhere", "loss", "loss 200", "rate 0", "nope 1", "delay -1"):
        try:
            pdudpfault.parse_directive(line)
        except ValueError:
            continue
        fail("accepted an invalid directive: %r" % line)
    ok("ctl directives parse and refuse bad modes, ranges and names")


def check_stall_calculations():
    args = argparse.Namespace(mode="stall", stall_ms=100, stall_every_ms=1000,
                              stall_long_ms=500, stall_long_at_ms=30000,
                              rate_mbit=8, delay_ms=100, loss_pct=0,
                              duplicate_pct=0, reorder_pct=0, seed=1,
                              events=None, ctl_file=None)
    relay = pdudpfault.Relay(args)
    relay.started_at = 100.0
    if abs(relay.stall_delay(100.05) - 0.05) < 0.001:
        ok("the stall schedule waits out the rest of a 100 ms pause")
    else:
        fail("stall delay at phase 0.05 was %r" % relay.stall_delay(100.05))
    if relay.stall_delay(100.5) == 0.0:
        ok("the stall schedule passes between pauses")
    else:
        fail("stall delay between pauses was %r" % relay.stall_delay(100.5))
    if abs(relay.stall_delay(130.1) - 0.4) < 0.001:
        ok("the long stall waits out its remaining 500 ms")
    else:
        fail("long stall delay was %r" % relay.stall_delay(130.1))


def check_pass_and_duplicate(work):
    phone = Echo()
    relay = Relay(work, phone.port, ["--duplicate-pct", "100"])
    try:
        sock = client(relay.port)
        for index in range(1, 6):
            sock.sendto(b"p%d" % index, ("127.0.0.1", relay.port))
        time.sleep(0.2)
        got = recv_all(sock, 0.4)
        sock.close()
        if sorted(got) == sorted([b"p1", b"p1", b"p1", b"p1", b"p2", b"p2", b"p2", b"p2",
                                  b"p3", b"p3", b"p3", b"p3", b"p4", b"p4", b"p4", b"p4",
                                  b"p5", b"p5", b"p5", b"p5"]):
            ok("pass relays both ways; duplicate 100%% doubles each direction")
        else:
            fail("duplicate delivery was %r" % sorted(got))
    finally:
        relay.stop()
        phone.finish()


def check_loss(work):
    phone = Echo()
    relay = Relay(work, phone.port, ["--loss-pct", "100"])
    try:
        sock = client(relay.port)
        for _ in range(5):
            sock.sendto(b"lost", ("127.0.0.1", relay.port))
        if recv_all(sock, 0.4) == []:
            ok("loss 100% delivered nothing")
        else:
            fail("loss 100% still delivered a datagram")
        time.sleep(0.8)
        stats = relay.stats()
        if stats.get("loss0") == 5 and stats.get("tx0") == 0:
            ok("the stats line counts the five loss drops")
        else:
            fail("loss stats were %r" % stats)
        sock.close()
    finally:
        relay.stop()
        phone.finish()


def check_ctl(work):
    phone = Echo()
    relay = Relay(work, phone.port, [])
    try:
        sock = client(relay.port)
        sock.sendto(b"a", ("127.0.0.1", relay.port))
        if recv_all(sock, 0.4) == [b"a"]:
            ok("the link passes before the ctl change")
        else:
            fail("no echo before the ctl change")
        relay.directives("mode blackhole")
        time.sleep(0.15)
        sock.sendto(b"b", ("127.0.0.1", relay.port))
        if recv_all(sock, 0.35) == []:
            ok("`mode blackhole` drops a running relay's datagrams")
        else:
            fail("blackhole echoed a datagram")
        relay.directives("mode pass")
        time.sleep(0.15)
        sock.sendto(b"c", ("127.0.0.1", relay.port))
        if recv_all(sock, 0.4) == [b"c"]:
            ok("`mode pass` brings the same relay back")
        else:
            fail("pass after blackhole did not deliver")
        lines = relay.lines()
        controls = [e.get("line") for e in lines if e.get("ev") == "ctl"]
        modes = [e.get("mode") for e in lines if e.get("ev") == "mode"]
        if controls == ["mode blackhole", "mode pass"] and modes == ["blackhole", "pass"]:
            ok("the events log every ctl line and each mode change")
        else:
            fail("ctl events %r, mode events %r" % (controls, modes))
        sock.close()
    finally:
        relay.stop()
        phone.finish()


def check_reorder(work):
    phone = Echo()
    relay = Relay(work, phone.port,
                  ["--reorder-pct", "50", "--reorder-delay-ms", "120", "--seed", "1"])
    try:
        sock = client(relay.port)
        sock.sendto(b"a", ("127.0.0.1", relay.port))
        time.sleep(0.01)
        sock.sendto(b"b", ("127.0.0.1", relay.port))
        got = recv_all(sock, 0.5)
        if got == [b"b", b"a"]:
            ok("reorder 50%% lets b overtake the held a (seed 1 holds one of two)")
        else:
            fail("reorder delivery was %r" % got)
        sock.close()
    finally:
        relay.stop()
        phone.finish()


def check_delay(work):
    phone = Echo()
    relay = Relay(work, phone.port, ["--mode", "delay", "--delay-ms", "150"])
    try:
        sock = client(relay.port)
        started = time.time()
        sock.sendto(b"d", ("127.0.0.1", relay.port))
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            data = None
        elapsed = time.time() - started
        if data == b"d" and 0.25 <= elapsed <= 0.8:
            ok("delay 150 ms each way took %.2f s round trip" % elapsed)
        else:
            fail("delay delivery %r in %.2f s" % (data, elapsed))
        sock.close()
    finally:
        relay.stop()
        phone.finish()


def check_rate(work):
    phone = Echo()
    # 0.08 Mbit/s is 10 KB/s: 8 KB takes 0.8 s each way.
    relay = Relay(work, phone.port, ["--mode", "throttle", "--rate-mbit", "0.08"])
    try:
        sock = client(relay.port)
        sock.settimeout(3.0)
        started = time.time()
        sock.sendto(b"r" * 8192, ("127.0.0.1", relay.port))
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            data = None
        elapsed = time.time() - started
        if data and 1.2 <= elapsed <= 3.0:
            ok("throttle 0.08 Mbit/s took %.2f s for 8 KB each way" % elapsed)
        else:
            fail("throttle delivery %d byte(s) in %.2f s"
                 % (len(data or b""), elapsed))
        sock.close()
    finally:
        relay.stop()
        phone.finish()


def main():
    check_directives()
    check_stall_calculations()
    work = tempfile.mkdtemp(prefix="pdudpfault.")
    try:
        check_pass_and_duplicate(work)
        check_loss(work)
        check_ctl(work)
        check_reorder(work)
        check_delay(work)
        check_rate(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if FAILED:
        print("UDPFAULT-CHECK FAIL: %d check(s)" % len(FAILED))
        return 1
    print("UDPFAULT-CHECK PASS: directives, both directions, loss, duplicate, reorder, delay, rate, ctl")
    return 0


if __name__ == "__main__":
    sys.exit(main())
