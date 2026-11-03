#!/usr/bin/env python3
"""The fake phone's switch rule (PATH-9, E-3): the Mac decides a switch.

A `path.switch` moves the fake's sending path and replays from the last ack,
and it **never closes the old path**: the old path stays attached as a
standby, still read and still answering pings. Only its own socket error or
EOF, or the Mac closing it, ends a path. Run with the same TLS-capable python
that starts fakephone: python3.11 tools/fakephone/test_paths_switch.py
"""

import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import paths  # noqa: E402


class FakeTransport(object):
    def __init__(self, path_id):
        self.id = path_id
        self.writes = []
        self.closed = False

    def send(self, data):
        if self.closed:
            raise OSError("path closed")
        self.writes.append(data)

    def close(self):
        self.closed = True


class PathSwitchTests(unittest.TestCase):
    def testASwitchKeepsTheOldPathAsAStandby(self):
        clock = {"now": 1_000}
        hub = paths.PathHub(now=lambda: clock["now"])
        old, new = FakeTransport("aaaa0001"), FakeTransport("bbbb0002")
        hub.start(old)
        hub.attach(new, joined=True)
        # The marker arrived on the path being left (the planned case).
        hub.move_to("bbbb0002")
        hub.replay_on_current()
        self.assertEqual("bbbb0002", hub.current_path)
        # The session's 250 ms tick ran and the 2 s backstop passed. The fake
        # used to drain the old path here (the old phone's rule); the phone
        # keeps it as a standby now, and only the Mac may close it.
        clock["now"] += 5_000
        tick = getattr(hub, "close_drained", None)
        if tick is not None:
            tick()
        self.assertEqual(2, hub.path_count, "the switch detached the old path")
        self.assertFalse(old.closed, "the phone closed the old path on a switch")

    def testAnUnplannedSwitchAlsoKeepsTheOldPath(self):
        hub = paths.PathHub(now=lambda: 1_000)
        old, new = FakeTransport("aaaa0001"), FakeTransport("bbbb0002")
        hub.start(old)
        hub.attach(new, joined=True)
        hub.move_to("bbbb0002")
        self.assertEqual(2, hub.path_count)
        self.assertFalse(old.closed)


if __name__ == "__main__":
    unittest.main()
