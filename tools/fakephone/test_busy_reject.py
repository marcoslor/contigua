#!/usr/bin/env python3
"""Unit checks for the fake phone's own plumbing: no video, no ffmpeg.

Run it with a TLS 1.3 python (the same one check-e2e.sh starts fakephone with):

    python3.11 tools/fakephone/test_busy_reject.py

The case here is the busy rejection of a second connection
(`FakePhone._reject_busy`). It wraps TLS and then bounds a drain with a socket
timeout; the wrapped session had no `settimeout`, so every rejected reconnect
died with AttributeError in its thread instead of closing quietly.
"""

import os
import socket
import ssl
import sys
import tempfile
import threading
import time
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fakephone  # noqa: E402
import proto  # noqa: E402


class BusyRejectionTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="fakephone-busy-")
        proto.make_identity(self.work)
        self.cert, self.key = proto.identity_paths(self.work)

    def phone(self):
        """The bits of FakePhone `_reject_busy` touches: the TLS wrap and no_tls."""
        cert, key = self.cert, self.key

        class Stub:
            args = types.SimpleNamespace(no_tls=False)

            @staticmethod
            def accept_tls(raw):
                return proto.tls_server_session(cert, key, raw, handshake_seconds=5)

        return Stub()

    def testARejectedConnectionStaysQuietWhileTheClientStalls(self):
        # A real TCP pair: the busy path sets TCP_NODELAY, as it does for the
        # Mac's connection (a UNIX socketpair refuses it).
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client = socket.create_connection(listener.getsockname())
        server, _ = listener.accept()
        listener.close()
        failures, received = [], []

        def serve():
            try:
                fakephone.FakePhone._reject_busy(self.phone(), server)
            except BaseException as exc:  # the thread's death is the bug
                failures.append(exc)

        def stall():
            # A stalled reconnect: the Mac reads the rejection, then sits on the
            # socket for a while before hanging up, as a wedged retry would.
            context = proto.tls_client_context()
            wrapped = None
            try:
                wrapped = context.wrap_socket(client, server_hostname=None)
                received.append(proto.recv_frame(wrapped))
                time.sleep(1.5)
            except (OSError, ssl.SSLError) as exc:
                failures.append(exc)
            finally:
                for sock in (wrapped, client):
                    try:
                        sock.close()
                    except (OSError, AttributeError):
                        pass

        threads = [threading.Thread(target=serve), threading.Thread(target=stall)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(20)

        self.assertEqual(failures, [], "the busy rejection raised: %r" % (failures,))
        self.assertTrue(received and received[0] is not None, "no rejection reached the client")
        message = proto.unpack_json(received[0])
        self.assertEqual(message.get("code"), "busy", "the rejection is not 'busy': %r" % (message,))
        self.assertEqual(message.get("t"), "error")


if __name__ == "__main__":
    unittest.main(verbosity=2)
