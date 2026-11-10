#!/usr/bin/env python3
"""pdpathfault's `--script` timeline: the parser and a live mode change.

The S4 link check needs pass -> throttle -> stall -> blackhole -> pass on one
clock, not five shell sleeps racing a ctl-file write. These checks pin the
grammar, the refusals, and that a running proxy really changes its delivery at
the scripted seconds.

Run: python3 tools/pdpathfault/test_script.py
"""

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
PROXY = os.path.join(HERE, "pdpathfault.py")
sys.path.insert(0, HERE)
import pdpathfault  # noqa: E402

FAILED = []


def fail(message):
    FAILED.append(message)
    print("SCRIPT-CHECK FAIL: %s" % message)


def ok(message):
    print("SCRIPT-CHECK PASS: %s" % message)


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class Echo(object):
    """A TCP peer that echoes every chunk until the client hangs up."""

    def __init__(self):
        self.port = free_port()
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", self.port))
        self.srv.listen(2)
        self.srv.settimeout(5)
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        try:
            conn, _ = self.srv.accept()
        except OSError:
            return
        conn.settimeout(3)
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                conn.sendall(data)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def stop(self):
        try:
            self.srv.close()
        except OSError:
            pass


class Proxy(object):
    def __init__(self, work, phone_port, script):
        self.events = os.path.join(work, "events.jsonl")
        self.script = os.path.join(work, "timeline.txt")
        with open(self.script, "w") as fp:
            fp.write(script)
        self.port = free_port()
        self.proc = subprocess.Popen(
            [sys.executable, PROXY, "--listen", str(self.port),
             "--connect", "127.0.0.1:%d" % phone_port,
             "--mode", "pass", "--script", self.script, "--events", self.events],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self._wait_listening()

    def _wait_listening(self):
        deadline = time.time() + 5
        while time.time() < deadline:
            if os.path.exists(self.events):
                with open(self.events) as fp:
                    if any('"ev":"start"' in line for line in fp):
                        return
            time.sleep(0.02)
        raise RuntimeError("the proxy did not listen")

    def lines(self):
        try:
            with open(self.events) as fp:
                return [json.loads(line) for line in fp if line.strip()]
        except (OSError, ValueError):
            return []

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


def echoed(conn, payload, seconds):
    """True when the echo server answers the payload inside the bound."""
    conn.settimeout(seconds)
    try:
        conn.sendall(payload)
        return conn.recv(len(payload)) == payload
    except OSError:
        return False


def check_parse():
    text = """\
# the brief's S4 timeline
at 10 throttle 3
at 20 stall
at 30 mode blackhole
at 33 pass
at 40 rate 10
at 45 stall stall_ms=80 stall_every_ms=500 stall_long_ms=400 stall_long_at_ms=2000
"""
    steps = pdpathfault.parse_script(text)
    expected = [
        (10.0, {"mode": "throttle", "rate": 3.0}),
        (20.0, {"mode": "stall"}),
        (30.0, {"mode": "blackhole"}),
        (33.0, {"mode": "pass"}),
        (40.0, {"rate": 10.0}),
        (45.0, {"mode": "stall", "stall_ms": 80.0, "stall_every_ms": 500.0,
                "stall_long_ms": 400.0, "stall_long_at_ms": 2000.0}),
    ]
    if steps == expected:
        ok("the timeline parses the brief's actions, comments and settings")
    else:
        fail("parsed %r, expected %r" % (steps, expected))

    bad = [
        "at 5 pass\nat 4 stall\n",
        "at 5 nonsense\n",
        "at 5 mode nowhere\n",
        "at 5 rate fast\n",
        "at 5 throttle\nat 6 mode pass extra=1\n",
        "5 pass\n",
    ]
    for text in bad:
        try:
            pdpathfault.parse_script(text)
        except ValueError:
            continue
        fail("accepted an invalid timeline: %r" % text)
    ok("the timeline refuses backwards times, unknown actions and settings")


def check_live(work):
    phone = Echo()
    proxy = Proxy(work, phone.port,
                  "at 0.3 blackhole\n"
                  "at 0.7 pass\n")
    try:
        client = socket.create_connection(("127.0.0.1", proxy.port), timeout=3)
        if echoed(client, b"a", 1.0):
            ok("the link passes before the scripted black hole")
        else:
            fail("no echo before the scripted black hole")
        time.sleep(0.45)
        if not echoed(client, b"b", 0.3):
            ok("the scripted black hole drops both directions")
        else:
            fail("the scripted black hole echoed a byte")
        time.sleep(0.5)
        if echoed(client, b"c", 1.0):
            ok("the link passes again after the script's pass step")
        else:
            fail("no echo after the script's pass step")
        client.close()
        time.sleep(0.2)
        lines = proxy.lines()
        timeline = [e for e in lines if e.get("ev") == "timeline"]
        plans = [e.get("at_plan") for e in timeline]
        modes = [e.get("mode") for e in lines if e.get("ev") == "mode"]
        if plans == [0.3, 0.7] and modes == ["blackhole", "pass"]:
            ok("the timeline logged both steps and the two mode changes")
        else:
            fail("timeline events %r, mode events %r" % (timeline, modes))
        if all(isinstance(e.get("at"), (int, float)) and e["at"] >= e["at_plan"] - 0.01
               for e in timeline):
            ok("each applied step names its planned and applied second")
        else:
            fail("a step applied before its planned second: %r" % timeline)
    finally:
        proxy.stop()
        phone.stop()


def main():
    check_parse()
    work = tempfile.mkdtemp(prefix="pdpathfault-script.")
    try:
        check_live(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if FAILED:
        print("SCRIPT-CHECK FAIL: %d check(s)" % len(FAILED))
        return 1
    print("SCRIPT-CHECK PASS: timeline parser and live mode changes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
