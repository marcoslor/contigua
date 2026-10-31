#!/usr/bin/env python3
"""pdpathfault's close forwarding and byte accounting, without an emulator.

Boot 8 lost 6 s to a make-believe handshake: the phone closed a connection and
the proxy stopped at its own read loop, so the Mac's socket stayed open until
its 6 s connect timeout. These checks pin the two TCP duties a path check
relies on:

  * a FIN from the phone reaches the client at once (and the `eof` event says
    which direction it came from);
  * a FIN from the client reaches the phone at once;
  * delivered bytes are reported per direction (`bytes` events), so a drop
    check can show which proxy carried the transfer;
  * `blackhole` still delivers nothing, while the socket stays open.

Run: python3 tools/pdpathfault/test_close.py
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
FAILED = []


def fail(message):
    FAILED.append(message)
    print("CLOSE-CHECK FAIL: %s" % message)


def ok(message):
    print("CLOSE-CHECK PASS: %s" % message)


def free_port():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class Phone(object):
    """A one-connection TCP peer whose handler runs in a thread."""

    def __init__(self, handler):
        self.port = free_port()
        self.handler = handler
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", self.port))
        self.srv.listen(2)
        self.srv.settimeout(5)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        try:
            conn, _ = self.srv.accept()
        except OSError:
            return
        try:
            self.handler(conn)
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
    def __init__(self, work, phone_port, mode):
        self.events = os.path.join(work, "events-%s.jsonl" % mode)
        self.ctl = os.path.join(work, "ctl-%s" % mode)
        self.port = free_port()
        # A previous scenario used the same names: a stale `start` line would
        # pass the readiness wait before this proxy has bound.
        for path in (self.events, self.ctl):
            try:
                os.remove(path)
            except OSError:
                pass
        self.proc = subprocess.Popen(
            [sys.executable, PROXY, "--listen", str(self.port),
             "--connect", "127.0.0.1:%d" % phone_port,
             "--mode", mode, "--events", self.events, "--ctl-file", self.ctl],
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


def phone_closes(conn):
    """Reads the client's byte, then hangs up: the client must see the FIN."""
    conn.settimeout(3)
    try:
        conn.recv(16)
    except OSError:
        pass
    time.sleep(0.05)


def phone_reads_to_eof(conn, seen):
    conn.settimeout(3)
    try:
        while conn.recv(4096):
            pass
        seen["eof"] = True
    except OSError:
        pass


def check_phone_fin(work):
    phone = Phone(phone_closes)
    proxy = Proxy(work, phone.port, "pass")
    try:
        client = socket.create_connection(("127.0.0.1", proxy.port), timeout=3)
        client.sendall(b"x")
        client.settimeout(3)
        started = time.time()
        try:
            data = client.recv(16)
        except OSError as exc:
            data = None
            fail("phone FIN: the client saw an error, not EOF: %s" % exc)
        elapsed = time.time() - started
        if data == b"":
            ok("the phone's FIN reached the client in %.2f s" % elapsed)
        else:
            fail("phone FIN: the client read %r instead of EOF" % (data,))
        client.close()
        time.sleep(0.15)
        events = proxy.lines()
        if any(e.get("ev") == "eof" and e.get("dir") == 1 for e in events):
            ok("the events name the phone-side EOF (dir 1)")
        else:
            fail("no phone-side eof event: %s" % events)
        if any(e.get("ev") == "bytes" and e.get("dir") == 0 and e.get("n", 0) >= 1
               for e in events):
            ok("delivered client bytes are counted (dir 0)")
        else:
            fail("no delivered-byte event: %s" % events)
    finally:
        proxy.stop()
        phone.stop()


def check_client_fin(work):
    seen = {}
    phone = Phone(lambda conn: phone_reads_to_eof(conn, seen))
    proxy = Proxy(work, phone.port, "pass")
    try:
        client = socket.create_connection(("127.0.0.1", proxy.port), timeout=3)
        client.sendall(b"y")
        client.shutdown(socket.SHUT_WR)
        deadline = time.time() + 3
        while time.time() < deadline and not seen.get("eof"):
            time.sleep(0.02)
        if seen.get("eof"):
            ok("the client's FIN reached the phone")
        else:
            fail("the phone never saw the client's FIN")
        client.close()
    finally:
        proxy.stop()
        phone.stop()


def check_blackhole(work):
    seen = {"data": b"", "error": None}

    def handler(conn):
        conn.settimeout(1.0)
        try:
            seen["data"] = conn.recv(4096)
        except OSError:
            pass

    phone = Phone(handler)
    proxy = Proxy(work, phone.port, "blackhole")
    try:
        client = socket.create_connection(("127.0.0.1", proxy.port), timeout=3)
        client.sendall(b"z" * 4096)
        time.sleep(1.2)
        if not seen["data"]:
            ok("blackhole delivered nothing and kept the socket open")
        else:
            fail("blackhole delivered %d bytes" % len(seen["data"]))
        if any(e.get("ev") == "bytes" and e.get("n", 0) > 0 for e in proxy.lines()):
            fail("blackhole counted bytes as delivered")
        client.close()
    finally:
        proxy.stop()
        phone.stop()


def main():
    work = tempfile.mkdtemp(prefix="pdpathfault-close.")
    try:
        check_phone_fin(work)
        check_client_fin(work)
        check_blackhole(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if FAILED:
        print("CLOSE-CHECK FAIL: %d check(s)" % len(FAILED))
        return 1
    print("CLOSE-CHECK PASS: FIN forwarded both ways, bytes counted, blackhole drops")
    return 0


if __name__ == "__main__":
    sys.exit(main())
