#!/usr/bin/env python3
"""Checks for the stream bench's arm handling (no phone, no Mac app).

    python3 tools/stream-bench/test_bench.py

The restore path is the one that must be exact: an arm's property has to go
back to `getprop`'s empty value after the run, and `adb shell setprop name ""`
is not enough (adb drops the empty argument before the device shell sees it).
"""

import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load_bench():
    spec = importlib.util.spec_from_file_location("stream_bench", os.path.join(HERE, "bench.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ArmSettingsTest(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()
        self.directory = tempfile.TemporaryDirectory()
        self.log = os.path.join(self.directory.name, "adb.log")
        self.adb = os.path.join(self.directory.name, "adb")
        with open(self.adb, "w", encoding="utf-8") as handle:
            handle.write(
                "#!/bin/sh\n"
                "for arg in \"$@\"; do printf '[%%s]\\n' \"$arg\" >> %s; done\n"
                "case \"$*\" in\n"
                "  *get-state*) echo device ;;\n"
                "  *getprop*) echo \"\" ;;\n"
                "esac\n" % self.log
            )
        os.chmod(self.adb, 0o755)

    def tearDown(self):
        self.directory.cleanup()

    def calls(self):
        with open(self.log, "r", encoding="utf-8") as handle:
            text = handle.read()
        invocations, current = [], []
        for line in text.splitlines():
            if not (line.startswith("[") and line.endswith("]")):
                continue
            arg = line[1:-1]
            if arg == "-s":
                if current:
                    invocations.append(current)
                current = ["-s"]
            else:
                current.append(arg)
        if current:
            invocations.append(current)
        return invocations

    def test_apply_then_restore_sets_and_clears_each_key(self):
        settings = self.bench.ArmSettings(self.adb, "emulator-5554", "dev.pocketdeck.mac.test")
        settings.apply({"phone": {"overflow": "suspend", "queue_ms": "100"}, "mac": {}})
        settings.restore()
        calls = self.calls()
        commands = [" ".join(call) for call in calls]
        self.assertIn(
            "-s emulator-5554 shell setprop debug.pocketdeck.stream.overflow suspend", commands)
        self.assertIn(
            "-s emulator-5554 shell setprop debug.pocketdeck.stream.queue_ms 100", commands)
        # The clear is one quoted remote command; a bare empty argv is dropped.
        self.assertIn(
            '-s emulator-5554 shell setprop debug.pocketdeck.stream.overflow ""', commands)
        self.assertIn(
            '-s emulator-5554 shell setprop debug.pocketdeck.stream.queue_ms ""', commands)
        self.assertNotIn("-s emulator-5554 shell setprop", commands)
        self.assertNotIn("-s emulator-5554 shell setprop debug.pocketdeck.stream.overflow", commands)


if __name__ == "__main__":
    unittest.main()
