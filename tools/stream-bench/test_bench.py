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


class MacArmTest(unittest.TestCase):
    """The Mac keys go to the profile's own suite and come back after a run."""

    def setUp(self):
        self.bench = load_bench()
        self.directory = tempfile.TemporaryDirectory()
        self.state = os.path.join(self.directory.name, "state")
        self.bindir = os.path.join(self.directory.name, "bin")
        os.makedirs(self.state)
        os.makedirs(self.bindir)
        self.log = os.path.join(self.directory.name, "defaults.log")
        self.defaults = os.path.join(self.bindir, "defaults")
        script = """#!/bin/sh
printf '%s\\n' "$*" >> LOG
case "$1" in
  read)
    file="STATE/$2.$3"
    if [ -f "$file" ]; then cat "$file"; else exit 1; fi ;;
  write)
    file="STATE/$2.$3"
    shift 4
    printf '%s' "$*" > "$file" ;;
  delete)
    rm -f "STATE/$2.$3" ;;
esac
"""
        with open(self.defaults, "w", encoding="utf-8") as handle:
            handle.write(script.replace("LOG", self.log).replace("STATE", self.state))
        os.chmod(self.defaults, 0o755)
        self.old_path = os.environ["PATH"]
        os.environ["PATH"] = self.bindir + ":" + self.old_path

    def tearDown(self):
        os.environ["PATH"] = self.old_path
        self.directory.cleanup()

    def commands(self):
        with open(self.log, "r", encoding="utf-8") as handle:
            return [line.split() for line in handle.read().splitlines() if line.strip()]

    def read_state(self, domain, key):
        path = os.path.join(self.state, "%s.%s" % (domain, key))
        if not os.path.exists(path):
            return None
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    def test_mac_keys_write_to_the_profile_domain_and_restore(self):
        domain = "dev.pocketdeck.mac.e2e"
        settings = self.bench.ArmSettings(None, "fake-phone", domain)
        settings.apply({"phone": {}, "mac": {"stream.present": "paced",
                                             "stream.pixels": "panel"}})
        self.assertEqual(self.read_state(domain, "stream.present"), "paced")
        self.assertEqual(self.read_state(domain, "stream.pixels"), "panel")
        settings.restore()
        self.assertIsNone(self.read_state(domain, "stream.present"))
        self.assertIsNone(self.read_state(domain, "stream.pixels"))
        # Every read/write/delete names this profile's suite, never the
        # person's own `dev.pocketdeck.mac`.
        domains = [command[1] for command in self.commands()
                   if len(command) > 2 and command[0] in ("read", "write", "delete")]
        self.assertTrue(domains)
        self.assertEqual(set(domains), {domain})

    def test_an_existing_value_comes_back_after_the_arm(self):
        domain = "dev.pocketdeck.mac.e2e"
        path = os.path.join(self.state, "%s.stream.pixels" % domain)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("backing")
        settings = self.bench.ArmSettings(None, "fake-phone", domain)
        settings.apply({"phone": {}, "mac": {"stream.pixels": "panel"}})
        self.assertEqual(self.read_state(domain, "stream.pixels"), "panel")
        settings.restore()
        self.assertEqual(self.read_state(domain, "stream.pixels"), "backing")

    def test_the_profile_selects_the_persons_domain_or_its_suite(self):
        self.assertEqual(self.bench.profile_domain("default"), "dev.pocketdeck.mac")
        self.assertEqual(self.bench.profile_domain("e2e"), "dev.pocketdeck.mac.e2e")
        self.assertEqual(self.bench.profile_domain("stratmac"),
                         "dev.pocketdeck.mac.stratmac")

    def test_the_mac_arms_exist_and_n1_needs_a_fresh_session(self):
        arms = self.bench.read_arms(os.path.join(HERE, "arms.json"))
        by_name = {arm["name"]: arm for arm in arms}
        self.assertEqual(by_name["m1-paced"]["mac"], {"stream.present": "paced"})
        self.assertEqual(by_name["m2-panel"]["mac"], {"stream.pixels": "panel"})
        self.assertEqual(by_name["n1-mac-video"]["mac"], {"stream.net": "video"})
        self.assertEqual(by_name["n1-both"]["mac"], {"stream.net": "video"})
        self.assertEqual(by_name["n1-both"]["phone"], {"tos": "136"})
        # N1's key is read at dial time: the default list leaves those arms out
        # (the README says the app must be restarted between them).
        default = [arm["name"] for arm in self.bench.selected_arms(arms)]
        self.assertIn("m1-paced", default)
        self.assertIn("m2-panel", default)
        self.assertNotIn("n1-mac-video", default)
        self.assertNotIn("n1-both", default)
        restarted = [arm["name"] for arm in self.bench.selected_arms(arms, include_restart=True)]
        self.assertIn("n1-mac-video", restarted)
        self.assertIn("n1-both", restarted)


if __name__ == "__main__":
    unittest.main()
