#!/usr/bin/env python3
"""The fake phone sets the real phone's TCP_NOTSENT_LOWAT on every path socket.

The real phone applies it to the raw socket before TLS (Server.serve), so the
kernel holds at most 16 KiB of unsent video and the application's own send
queue sees the backlog. Without it the fake phone's kernel held megabytes and
losslab read a rig artifact as the link's queue.

TCP_NOTSENT_LOWAT is Linux's tcp.h option 25; Python has no constant for it and
macOS refuses the option, exactly like a kernel without it on the phone.

    python3.11 tools/fakephone/test_notsent_lowat.py
"""

import errno
import os
import socket
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fakephone  # noqa: E402


class RecordingSocket:
    """Just the calls configure_socket makes, so the host's kernel is not needed."""

    def __init__(self, refuse=None):
        self.calls = []
        self.refuse = refuse

    def setsockopt(self, level, option, value):
        self.calls.append((level, option, value))
        if self.refuse is not None:
            raise OSError(self.refuse, os.strerror(self.refuse))


class NotSentLowatTest(unittest.TestCase):
    def test_the_option_is_the_real_phones(self):
        sock = RecordingSocket()
        self.assertEqual(0, fakephone.set_notsent_lowat(sock))
        self.assertIn((socket.IPPROTO_TCP, 25, 16 * 1024), sock.calls)

    def test_a_kernel_without_it_is_an_errno_not_a_crash(self):
        sock = RecordingSocket(refuse=errno.ENOPROTOOPT)
        self.assertEqual(errno.ENOPROTOOPT, fakephone.set_notsent_lowat(sock))

    def test_configure_socket_sets_both_options_before_tls(self):
        sock = RecordingSocket()
        fakephone.configure_socket(sock)
        self.assertIn((socket.IPPROTO_TCP, socket.TCP_NODELAY, 1), sock.calls)
        self.assertIn((socket.IPPROTO_TCP, 25, 16 * 1024), sock.calls)

    def test_a_real_socket_keeps_nodelay_and_the_lowat_where_linux_has_it(self):
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        try:
            client = socket.create_connection(listener.getsockname(), timeout=2)
            server, _ = listener.accept()
        finally:
            listener.close()
        try:
            fakephone.configure_socket(server)
            # Darwin reads back 4 for a set TCP_NODELAY; only "set" matters here.
            self.assertNotEqual(0, server.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY))
            if sys.platform.startswith("linux"):
                self.assertEqual(16 * 1024,
                                 server.getsockopt(socket.IPPROTO_TCP, 25))
            else:
                with self.assertRaises(OSError):
                    server.getsockopt(socket.IPPROTO_TCP, 25)
                self.assertNotEqual(0, fakephone.set_notsent_lowat(server))
        finally:
            server.close()
            client.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
