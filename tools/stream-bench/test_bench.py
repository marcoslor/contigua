#!/usr/bin/env python3
"""Checks for the stream bench's arm handling (no phone, no Mac app).

    python3 tools/stream-bench/test_bench.py

The restore path is the one that must be exact: an arm's property has to go
back to `getprop`'s empty value after the run, and `adb shell setprop name ""`
is not enough (adb drops the empty argument before the device shell sees it).
"""

import datetime
import csv
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
        # N1's key is read at dial time on both sides: the default list leaves
        # those arms out (the README says the app must be restarted between them).
        default = [arm["name"] for arm in self.bench.selected_arms(arms)]
        self.assertIn("m1-paced", default)
        self.assertIn("m2-panel", default)
        self.assertNotIn("n1-mac-video", default)
        self.assertNotIn("n1-both", default)
        self.assertNotIn("n1-af41", default)
        restarted = [arm["name"] for arm in self.bench.selected_arms(arms, include_restart=True)]
        self.assertIn("n1-mac-video", restarted)
        self.assertIn("n1-both", restarted)
        self.assertIn("n1-af41", restarted)

    def test_combo_a_names_only_the_switches_an_interleaved_run_can_apply(self):
        arms = self.bench.read_arms(os.path.join(HERE, "arms.json"))
        combo = {arm["name"]: arm for arm in arms}["combo-a"]
        self.assertEqual(combo["phone"], {"overflow": "suspend", "queue_ms": "100",
                                          "rc": "cbr", "cap_kbps": "16000",
                                          "ir": "60", "refine": "on"})
        self.assertEqual(combo.get("restart", False), False)


class DriveTest(unittest.TestCase):
    """The script must never let the list rest at an end."""

    def test_every_swipe_alternates_direction_in_both_phases(self):
        bench = load_bench()
        calls = []

        class FakeMCP:
            def text(self, name, arguments):
                calls.append(arguments)

        phases = []
        bench.drive(FakeMCP(), 1, phases, sleep=lambda seconds: None)
        self.assertEqual(len(calls), 20)
        self.assertEqual(sum(1 for call in calls if call["y1"] == 0.78), 10)
        self.assertEqual(sum(1 for call in calls if call["y1"] == 0.22), 10)
        # up, down, up, ... within the steady phase, then again in the flings.
        for index, call in enumerate(calls):
            expected = 0.78 if index % 2 == 0 else 0.22
            self.assertEqual(call["y1"], expected, "swipe %d" % index)
        self.assertEqual([name for name, _ in phases],
                         ["swipes", "still", "flings", "settle"])


class ResendSummaryTest(unittest.TestCase):
    """X0's block: do resends line up with the hitches?"""

    def setUp(self):
        self.bench = load_bench()

    def line(self, **fields):
        row = {"at": 0}
        row.update({key: str(value) for key, value in fields.items()})
        return row

    def test_the_table_gains_the_two_resend_columns_and_the_csv_the_totals(self):
        self.assertIn("tcp_ooo_kb", self.bench.TABLE_FIELDS)
        self.assertIn("ph_retrans", self.bench.TABLE_FIELDS)
        for field in ("tcp_ooo_kb", "tcp_srtt_max", "ph_retrans", "ph_rto", "ph_lost",
                      "max_gap_ms"):
            self.assertIn(field, self.bench.CSV_FIELDS)

    def test_the_totals_carry_the_longest_gap_into_the_run(self):
        total = self.bench.parse_totals(
            "2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]: stats total stream=1 "
            "secs=10.0 rx_frames=600 max_gap_ms=1830\n", 1)
        self.assertEqual(self.bench.run_metrics(total)["max_gap_ms"], 1830)

    def test_the_key_counts_from_both_sides_reach_the_run(self):
        # The Mac's own count and the phone's, both on the closing totals line
        # (the phone's arrives through its 2 s messages).
        total = self.bench.parse_totals(
            "2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]: stats total stream=1 "
            "secs=10.0 rx_frames=600 key_not_idr=4 ph_key_not_idr=9\n", 1)
        run = self.bench.run_metrics(total)
        self.assertEqual(run["key_not_idr"], 4)
        self.assertEqual(run["ph_key_not_idr"], 9)

    def test_the_key_counts_are_table_and_csv_fields(self):
        for field in ("key_not_idr", "ph_key_not_idr"):
            self.assertIn(field, self.bench.TABLE_FIELDS)
            self.assertIn(field, self.bench.CSV_FIELDS)
        header = self.bench.table_header(8)
        self.assertIn("key_not_idr", header)

    def test_the_totals_carry_the_new_fields_into_the_run(self):
        total = self.bench.parse_totals(
            "2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]: stats total stream=1 "
            "secs=10.0 rx_frames=600 tcp_ooo_kb=3.5 tcp_srtt_max=42 "
            "ph_retrans=9 ph_rto=2 ph_lost=1\n", 1)
        run = self.bench.run_metrics(total)
        self.assertEqual(run["tcp_ooo_kb"], 3.5)
        self.assertEqual(run["tcp_srtt_max"], 42)
        self.assertEqual(run["ph_retrans"], 9)
        self.assertEqual(run["ph_rto"], 2)
        self.assertEqual(run["ph_lost"], 1)

    def test_hitch_and_clean_lines_are_counted_by_resends(self):
        rows = [
            # A hitch with a phone resend: the X0 correlation.
            self.line(phone_n=2, hitch_n=1, rx_fps=60, ph_retrans=3, tcp_ooo_kb="0.0"),
            # A hitch with only receiver out-of-order bytes.
            self.line(phone_n=2, hitch_n=2, rx_fps=60, ph_retrans=0, tcp_ooo_kb="0.4"),
            # A hitch with neither.
            self.line(phone_n=2, hitch_n=1, rx_fps=60, ph_retrans=0, tcp_ooo_kb="0.0"),
            # A clean moving line with a resend.
            self.line(phone_n=2, hitch_n=0, rx_fps=58, ph_retrans=1, tcp_ooo_kb="0.0"),
            # A clean moving line, no resend.
            self.line(phone_n=2, hitch_n=0, rx_fps=59, ph_retrans=0, tcp_ooo_kb="0.0"),
        ]
        counts = self.bench.resend_counts(rows)
        self.assertEqual(counts, (2, 3, 1, 2, 0))

    def test_a_still_line_is_neither_hitch_nor_clean_and_no_message_is_counted(self):
        rows = [
            # A still line (hitch_n=0, rx_fps < 20) is not a moving clean line.
            self.line(phone_n=2, hitch_n=0, rx_fps=4, ph_retrans=5, tcp_ooo_kb="0.0"),
            # No phone message: left out of both and counted.
            self.line(phone_n=0, hitch_n=1, rx_fps=60, ph_retrans="-", tcp_ooo_kb="0.0"),
        ]
        self.assertEqual(self.bench.resend_counts(rows), (0, 0, 0, 0, 1))

    def test_the_summary_line_names_both_counts_and_the_missing_messages(self):
        rows = [
            self.line(phone_n=2, hitch_n=1, rx_fps=60, ph_retrans=2, tcp_ooo_kb="0.0"),
            self.line(phone_n=0, hitch_n=0, rx_fps=0, ph_retrans="-", tcp_ooo_kb="-"),
        ]
        text = self.bench.resend_line("baseline", rows)
        self.assertIn("hitch lines with resends 1/1", text)
        self.assertIn("clean lines with resends 0/0", text)
        self.assertIn("no phone message: 1", text)


class RunMetricsTest(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()

    def total(self, **fields):
        row = self.bench.parse_totals(
            "2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]: stats total stream=1 "
            + " ".join("%s=%s" % item for item in fields.items()) + "\n", 1)
        return row

    def test_a_missing_drop_ms_is_zero_for_jank_and_marks_the_run(self):
        total = self.total(secs=10.0, rx_frames=600, drop_ep=2, drop_ms="-",
                           hitch_n=0, hitch_ms=0, susp_n=0, susp_ms=0)
        values = self.bench.run_metrics(total)
        self.assertEqual(values["jank_ms"], 0)
        self.assertEqual(values["jank_n"], 2)
        self.assertTrue(values["no_drop_ms"])
        total["drop_ms"] = "250"
        values = self.bench.run_metrics(total)
        self.assertEqual(values["jank_ms"], 250)
        self.assertFalse(values["no_drop_ms"])

    def test_phone_gaps_means_the_run_had_no_phone_message(self):
        total = self.total(secs=10.0, rx_frames=600, phone_n=0)
        self.assertTrue(self.bench.run_metrics(total)["phone_gaps"])
        total["phone_n"] = "2"
        self.assertFalse(self.bench.run_metrics(total)["phone_gaps"])

    def test_qp_comes_only_from_lines_with_a_phone_message(self):
        total = self.total(secs=10.0, rx_frames=600, phone_n=4)
        sampled = [{"at": 0, "phone_n": "0", "qp_p95": "1"},
                   {"at": 0, "phone_n": "2", "qp_p95": "20"},
                   {"at": 0, "phone_n": "2", "qp_p95": "40"}]
        self.assertEqual(self.bench.run_metrics(total, sampled)["qp_p95"], 30)

    def test_covered_runs_are_left_out_of_the_medians(self):
        clean = {"failed": 0, "covered": 0, "jank_ms": 10}
        covered = {"failed": 0, "covered": 1, "jank_ms": 999}
        for run in (clean, covered):
            run.update({"low_motion": 0, "no_drop_ms": 0, "phone_gaps": 0})
        cells = self.bench.summarise([clean, covered])
        self.assertEqual(cells["jank_ms"], (10, 10, 10))
        self.assertIn("covered", self.bench.table_line("stall", [clean, covered]))


class FrozenTest(unittest.TestCase):
    """Round 2: a frozen picture is not the best run, and neither a frozen nor
    a low-motion run may make an arm's median."""

    def setUp(self):
        self.bench = load_bench()

    def total(self, **fields):
        parts = ["2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]:",
                 "stats", "total", "stream=14"]
        for key, value in fields.items():
            parts.append("%s=%s" % (key, value))
        return self.bench.parse_totals(" ".join(parts) + "\n", 14)

    def metrics(self, jank_ms, **marks):
        values = {"failed": 0, "covered": 0, "frozen": 0, "low_motion": 0,
                  "jank_ms": jank_ms}
        values.update(marks)
        return values

    def test_stream_14_shaped_lines_are_frozen(self):
        # Round 2's stream 14: about 50 fps for 10.7 s, then a still picture
        # for the rest of the window, and no late frame to count as a hitch.
        text = (
            "2026-11-05 15:57:30.000000-0300 mac PocketDeck[7]: "
            "stats stream=14 rx_fps=60 shown_fps=60 phone_n=2\n"
            "2026-11-05 15:57:35.000000-0300 mac PocketDeck[7]: "
            "stats stream=14 rx_fps=0 shown_fps=0 phone_n=0\n"
            "2026-11-05 15:57:40.000000-0300 mac PocketDeck[7]: "
            "stats stream=14 rx_fps=0 shown_fps=0 phone_n=0\n"
            "2026-11-05 15:57:50.000000-0300 mac PocketDeck[7]: "
            "stats total stream=14 secs=21.6 rx_frames=540 shown_frames=540 "
            "hitch_n=0 hitch_ms=0 drop_ep=0 drop_ms=0 susp_n=0 susp_ms=0 "
            "phone_n=10 phone_frames=540 max_gap_ms=10800\n"
        )
        sampled = self.bench.parse_rows(text, 14)
        total = self.bench.parse_totals(text, 14)
        values = self.bench.run_metrics(total, sampled)
        self.assertTrue(values["frozen"])
        self.assertTrue(self.bench.is_frozen(total, sampled))
        self.assertFalse(values["low_motion"])

    def test_stream_15_shaped_lines_are_frozen_and_low_motion(self):
        # Stream 15: the encoder stayed suspended after the queue drained, so
        # the run produced 33 frames in 21.8 s and scored the best jank of
        # the round.
        total = self.total(secs=21.8, rx_frames=33, shown_frames=33,
                           hitch_n=0, hitch_ms=0, drop_ep=0, drop_ms=0,
                           susp_n=1, susp_ms=19, phone_n=10, phone_frames=33,
                           max_gap_ms=10700)
        sampled = [{"at": 0, "rx_fps": "60"},
                   {"at": 5, "rx_fps": "0"},
                   {"at": 10, "rx_fps": "0"}]
        values = self.bench.run_metrics(total, sampled)
        self.assertTrue(values["frozen"])
        self.assertTrue(values["low_motion"])

    def test_a_slow_still_phase_does_not_freeze_a_run(self):
        # The 3 s stills send heartbeat frames only; a 5 s line there is no
        # frozen picture while the content moves, and the whole run's longest
        # gap stays under the 2.5 s mark.
        phases = [("swipes", 1_000.0), ("still", 1_020.0),
                  ("flings", 1_030.0), ("settle", 1_040.0)]
        sampled = [{"at": 1_025.0, "rx_fps": "1"},
                   {"at": 1_035.0, "rx_fps": "60"}]
        total = self.total(secs=21.0, rx_frames=600, max_gap_ms=1200)
        self.assertFalse(self.bench.is_frozen(total, sampled, phases))

    def test_stream_2_shaped_run_under_the_gap_is_not_frozen(self):
        # Round 3's stream 2: one 5 s line with zero frames while a swipe ran,
        # then frames again. The run's longest gap was 1.8 s, so the picture
        # never stopped for 2.5 s: the old 5 s line rule called it frozen.
        total = self.total(secs=22.0, rx_frames=300, shown_frames=300,
                           drop_ep=1, drop_ms=383, max_gap_ms=1800)
        sampled = [{"at": 1.0, "rx_fps": "16.8"},
                   {"at": 6.0, "rx_fps": "0.0"},
                   {"at": 11.0, "rx_fps": "16.8"}]
        values = self.bench.run_metrics(total, sampled)
        self.assertFalse(values["frozen"])
        self.assertFalse(self.bench.is_frozen(total, sampled))

    def test_an_older_totals_line_without_max_gap_keeps_the_five_second_rule(self):
        # A log from before the field existed still marks a dead 5 s line.
        total = self.total(secs=22.0, rx_frames=300, shown_frames=300)
        sampled = [{"at": 6.0, "rx_fps": "0.0"}]
        self.assertTrue(self.bench.is_frozen(total, sampled))

    def test_frozen_and_low_motion_runs_leave_the_medians(self):
        clean = self.metrics(100)
        frozen = self.metrics(0, frozen=1)
        quiet = self.metrics(0, low_motion=1)
        cells = self.bench.summarise([clean, frozen, quiet])
        self.assertEqual(cells["jank_ms"], (100, 100, 100))
        self.assertEqual(self.bench.valid_runs([clean, frozen, quiet]), 1)

    def test_the_table_marks_them_and_counts_the_valid_runs(self):
        clean = self.metrics(100)
        frozen = self.metrics(0, frozen=1)
        quiet = self.metrics(0, low_motion=1)
        line = self.bench.table_line("stall-q1", [clean, frozen, quiet], width=8)
        label = line.split("  ")[0]
        self.assertIn("frozen", label)
        self.assertIn("low-motion", label)
        cells = line.split("  ", 1)[1].split()
        self.assertEqual(cells[0], "1")  # one valid run made the median
        header = self.bench.table_header(8)
        self.assertIn("valid", header)
        self.assertIn("jank_ms", header)


class TotalsTest(unittest.TestCase):
    """Round 2: every table number comes from the closing totals line."""

    def setUp(self):
        self.bench = load_bench()

    def totals_line(self, stream=1, **fields):
        parts = ["2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]:",
                 "stats", "total", "stream=%d" % stream]
        for key, value in fields.items():
            parts.append("%s=%s" % (key, value))
        return " ".join(parts) + "\n"

    def test_the_new_stall_arms_add_only_their_switches(self):
        arms = self.bench.read_arms(os.path.join(HERE, "arms.json"))
        by_name = {arm["name"]: arm for arm in arms}
        self.assertEqual(by_name["stall"]["phone"], {"stall_ms": "400"})
        self.assertEqual(by_name["stall-q1"]["phone"],
                         {"stall_ms": "400", "overflow": "suspend"})
        self.assertEqual(by_name["stall-q1q2-100"]["phone"],
                         {"stall_ms": "400", "overflow": "suspend", "queue_ms": "100"})
        self.assertEqual(by_name["stall-q2-500"]["phone"],
                         {"stall_ms": "400", "queue_ms": "500"})
        self.assertEqual(by_name["stall-paced"]["phone"], {"stall_ms": "400"})
        self.assertEqual(by_name["stall-paced"]["mac"], {"stream.present": "paced"})
        self.assertEqual(by_name["stall-ir60"]["phone"],
                         {"stall_ms": "400", "ir": "60"})
        for name in ("stall", "stall-q1", "stall-q1q2-100", "stall-q2-500",
                     "stall-paced", "stall-ir60", "stall-hevc"):
            self.assertFalse(by_name[name].get("restart", False),
                             "%s must run interleaved" % name)

    def test_the_hevc_arms_ask_only_for_the_codec(self):
        arms = self.bench.read_arms(os.path.join(HERE, "arms.json"))
        by_name = {arm["name"]: arm for arm in arms}
        self.assertEqual(by_name["c1-hevc"]["phone"], {"codec": "hevc"})
        self.assertEqual(by_name["c1-hevc"]["mac"], {})
        self.assertEqual(by_name["stall-hevc"]["phone"],
                         {"stall_ms": "400", "codec": "hevc"})
        self.assertEqual(by_name["stall-hevc"]["mac"], {})

    def test_the_totals_carry_the_codec_and_qp_avg(self):
        total = self.bench.parse_totals(self.totals_line(
            secs=10.0, codec="hevc", qp_avg="24.5"), 1)
        run = self.bench.run_metrics(total)
        self.assertEqual(run["codec"], "hevc")
        self.assertEqual(run["qp_avg"], 24.5)
        missing = self.bench.run_metrics(self.bench.parse_totals(
            self.totals_line(secs=10.0, codec="-", qp_avg="-"), 1))
        self.assertIsNone(missing["codec"])
        self.assertIsNone(missing["qp_avg"])

    def test_the_totals_carry_the_macs_received_rate(self):
        total = self.bench.parse_totals(self.totals_line(
            secs=10.0, rx_kbps="812.5"), 1)
        self.assertEqual(self.bench.run_metrics(total)["rx_kbps"], 812.5)

    def test_the_codec_qp_avg_and_received_rate_are_table_and_csv_fields(self):
        for field in ("qp_avg", "rx_kbps"):
            self.assertIn(field, self.bench.TABLE_FIELDS)
        self.assertIn("codec", self.bench.TABLE_TEXT_FIELDS)
        self.assertIn("codec", self.bench.table_header(8))
        for field in ("codec", "qp_avg", "rx_kbps"):
            self.assertIn(field, self.bench.CSV_FIELDS)

    def test_arms_filter_runs_only_matching_prefixes(self):
        arms = self.bench.read_arms(os.path.join(HERE, "arms.json"))
        names = [arm["name"] for arm in self.bench.selected_arms(arms, prefix="stall")]
        self.assertEqual(names, ["stall", "stall-q1", "stall-q1q2-100",
                                 "stall-q2-500", "stall-paced", "stall-ir60",
                                 "stall-hevc"])
        names = [arm["name"] for arm in self.bench.selected_arms(arms, prefix="stall-q")]
        self.assertEqual(names, ["stall-q1", "stall-q1q2-100", "stall-q2-500"])
        self.assertEqual(self.bench.selected_arms(arms, prefix="nope"), [])

    def test_the_totals_line_is_parsed_and_other_streams_are_ignored(self):
        text = (
            "2026-11-05 10:00:05.000000-0300 mac PocketDeck[7]: "
            "stats stream=1 rx_fps=60 shown_fps=60 phone_n=2\n"
            + self.totals_line(secs=10.0, rx_frames=300, shown_frames=290,
                               hitch_n=2, hitch_ms=80, late_p99=20.5,
                               phone_n=15, phone_frames=300, kf=2, kf_req=1,
                               drop_ep=1, drop_ms=120, susp_n=0, susp_ms=0,
                               bytes=1000000, e2e_p50=12.0, e2e_p95=30.0,
                               covered_ms=0)
            + self.totals_line(stream=2, secs=1.0, rx_frames=1)
        )
        row = self.bench.parse_totals(text, 1)
        self.assertIsNotNone(row)
        self.assertEqual(self.bench.number(row, "rx_frames"), 300)
        self.assertEqual(self.bench.number(row, "covered_ms"), 0)
        self.assertIsNone(self.bench.parse_totals(text, 9))

    def test_every_table_number_comes_from_the_totals(self):
        total = self.bench.parse_totals(self.totals_line(
            secs=10.0, rx_frames=300, shown_frames=290, hitch_n=2,
            hitch_ms=80, late_p99=20.5, phone_n=15, phone_frames=300,
            kf=2, kf_req=1, drop_ep=1, drop_ms=120, susp_n=1, susp_ms=40,
            bytes=1_000_000, e2e_p50=12.0, e2e_p95=30.0, covered_ms=2_000), 1)
        sampled = [{"at": 0, "phone_n": "2", "qp_p95": "24"},
                   {"at": 0, "phone_n": "2", "qp_p95": "30"},
                   {"at": 0, "phone_n": "0", "qp_p95": "1"}]
        run = self.bench.run_metrics(total, sampled)
        self.assertEqual(run["jank_n"], 4)       # 2 hitches + 1 drop ep + 1 susp
        self.assertEqual(run["jank_ms"], 240)    # 80 + 120 + 40
        self.assertEqual(run["kbps"], 800)       # 1,000,000 bytes × 8 / 10 s
        self.assertEqual(run["shown_fps"], 36.25)  # 290 / (10 - 2 covered)
        self.assertAlmostEqual(run["late_p99"], 20.5)
        self.assertEqual(run["qp_p95"], 27)      # a phone_n=0 line is no sample
        self.assertTrue(run["covered"])
        self.assertFalse(run["low_motion"])
        self.assertFalse(run["no_drop_ms"])

    def test_low_motion_comes_from_the_totals_rate(self):
        quiet = self.bench.parse_totals(self.totals_line(
            secs=10.0, rx_frames=199), 1)
        self.assertTrue(self.bench.run_metrics(quiet)["low_motion"])
        moving = self.bench.parse_totals(self.totals_line(
            secs=10.0, rx_frames=200), 1)
        self.assertFalse(self.bench.run_metrics(moving)["low_motion"])

    def test_a_failed_run_is_marked_and_the_table_and_csv_survive(self):
        good = self.bench.parse_totals(self.totals_line(
            secs=10.0, rx_frames=300, shown_frames=300, jank_n=0), 1)
        good_run = {"arm": "baseline", "repeat": 1, "failed": 0, "covered": 0}
        good_run.update(self.bench.run_metrics(good))
        failed = {"arm": "baseline", "repeat": 2, "failed": 1, "covered": 0}
        failed.update(self.bench.empty_metrics())
        text = self.bench.table_line("baseline", [good_run, failed])
        self.assertIn("failed", text.split("  ")[0])
        self.assertIn("30.0 (30.0-30.0)", text)

    def test_the_pid_is_found_from_the_profiles_app_only(self):
        ps_text = (
            "  101 /Applications/PocketDeck.app/Contents/MacOS/PocketDeck --profile default\n"
            "  202 /Users/x/pd-wt/bench2/macos/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck --profile bench2\n"
            "  303 /Users/x/pd-wt/bench2/macos/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck --profile bench20\n"
            "  404 /Users/x/PocketDeckShim.app/Contents/MacOS/PocketDeckShim --profile bench2\n"
        )
        self.assertEqual(self.bench.profile_app_pid(ps_text, "bench2"), 202)
        self.assertIsNone(self.bench.profile_app_pid(ps_text, "bench3"))

    def test_the_default_profile_is_the_app_launched_without_a_flag(self):
        # The person's installed app is opened from Finder or `open -a`: its
        # command line carries no --profile at all, and that is the default.
        ps_text = (
            "  101 /Applications/PocketDeck.app/Contents/MacOS/PocketDeck\n"
            "  202 /Users/x/pd-wt/bench2/macos/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck --profile bench2\n"
        )
        self.assertEqual(self.bench.profile_app_pid(ps_text, "default"), 101)
        self.assertEqual(self.bench.profile_app_pid(
            "  105 /Applications/PocketDeck.app/Contents/MacOS/PocketDeck --profile default\n",
            "default"), 105)
        self.assertIsNone(self.bench.profile_app_pid(ps_text, "bench3"))
        # A flagless app is never another profile's.
        self.assertIsNone(self.bench.profile_app_pid(
            "  101 /Applications/PocketDeck.app/Contents/MacOS/PocketDeck\n", "bench2"))

    def test_the_log_predicate_names_the_pid(self):
        self.assertIn("processID == 202", self.bench.log_predicate(202))
        self.assertIn('subsystem == "dev.pocketdeck.mac"',
                      self.bench.log_predicate(202))

    def test_another_windows_stats_line_refuses_the_run(self):
        text = ("2026-11-05 10:00:05.000000-0300 mac PocketDeck[7]: "
                "stats stream=1 rx_fps=60 phone_n=2\n")
        self.assertTrue(self.bench.has_open_window(text))
        self.assertFalse(self.bench.has_open_window(
            "2026-11-05 10:00:05.000000-0300 mac PocketDeck[7]: "
            "stats total stream=1 secs=10.0\n"))

    def test_a_stats_line_followed_by_that_streams_close_is_not_open(self):
        text = ("2026-11-05 10:00:05.000000-0300 mac PocketDeck[7]: "
                "stats stream=1 rx_fps=60 phone_n=2\n"
                "2026-11-05 10:00:06.000000-0300 mac PocketDeck[7]: "
                "stream 1: closed, stills=3\n")
        self.assertFalse(self.bench.has_open_window(text))

    def test_one_closed_stream_does_not_hide_another_open_one(self):
        text = ("2026-11-05 10:00:05.000000-0300 mac PocketDeck[7]: "
                "stats stream=1 rx_fps=60 phone_n=2\n"
                "2026-11-05 10:00:06.000000-0300 mac PocketDeck[7]: "
                "stream 1: closed, stills=3\n"
                "2026-11-05 10:00:07.000000-0300 mac PocketDeck[7]: "
                "stats stream=2 rx_fps=60 phone_n=2\n")
        self.assertTrue(self.bench.has_open_window(text))

    def test_dry_run_reads_the_arms_and_touches_no_device(self):
        import unittest.mock as mock
        argv = ["bench.py", "--dry-run", "--profile", "bench2",
                "--serial", "emulator-5554", "--arms-filter", "stall",
                "--arms", os.path.join(HERE, "arms.json"), "--repeats", "1",
                "--out", os.path.join(tempfile.gettempdir(), "bench-dry-run.csv")]
        with mock.patch.object(self.bench, "require_device",
                               side_effect=AssertionError("the dry run touched adb")), \
                mock.patch("sys.argv", argv):
            self.assertEqual(self.bench.main(), 0)
        self.assertFalse(os.path.exists(argv[-1]))


class ParseRowsTest(unittest.TestCase):
    def test_the_line_timestamp_is_an_absolute_instant(self):
        bench = load_bench()
        text = ("2026-11-05 10:00:05.000000-0300 mac PocketDeck[1]: "
                "stats stream=1 rx_fps=60 drop_ms=- drop_ep=0\n")
        row = bench.parse_rows(text, 1)[0]
        moment = datetime.datetime.fromtimestamp(row["at"], datetime.timezone.utc)
        self.assertEqual(moment, datetime.datetime(2026, 11, 5, 13, 0, 5,
                                                   tzinfo=datetime.timezone.utc))
        self.assertIsNone(bench.number(row, "drop_ms"))
        self.assertEqual(bench.number(row, "rx_fps"), 60)


OLD_CSV_FIELDS = ["repeat", "arm", "stream", "start", "end", "lines",
                  "codec", "failed", "covered", "secs", "rx_frames", "shown_frames",
                  "phone_frames", "kf_req", "bytes", "covered_ms", "max_gap_ms",
                  "tcp_ooo_kb", "tcp_srtt_max", "ph_retrans", "ph_rto", "ph_lost",
                  "jank_ms", "jank_n", "hitch_ms", "drop_ms", "susp_ms",
                  "late_p99", "shown_fps", "kf", "key_not_idr", "ph_key_not_idr",
                  "kbps", "rx_kbps", "tcp_ooo_kb", "ph_retrans", "qp_p95",
                  "qp_avg", "e2e_p50", "e2e_p95", "frozen", "low_motion",
                  "no_drop_ms", "phone_gaps"]

NEW_RUN_FIELDS = ["script", "input_photon_ms", "input_frames", "first_frame_ms",
                  "resize_ms", "app_fps", "app_jank_pct", "vd_hz", "battery_level",
                  "battery_temp_c", "thermal_status", "thermal_max_c",
                  "app_cpu_pct", "shell_cpu_pct", "app_pss_kb", "shell_pss_kb",
                  "wifi_rssi_dbm", "wifi_mbps", "wifi_mhz", "wifi_retries",
                  "wifi_bad"]


class ScriptPlanTest(unittest.TestCase):
    """The named scripts compose; swipe stays today's exact call sequence."""

    def setUp(self):
        self.bench = load_bench()

    def args(self, **overrides):
        import types
        values = dict(still_seconds=6, video_point={"x": 0.5, "y": 0.5},
                      video_seconds=8, soak_seconds=60, sample_seconds=10,
                      typing_point={"x": 0.5, "y": 0.08},
                      tap_point={"x": 0.5, "y": 0.5})
        values.update(overrides)
        return types.SimpleNamespace(**values)

    def run_calls(self, script, **overrides):
        calls = []

        class FakeMCP:
            def text(self, name, arguments):
                calls.append((name, arguments))

        phases = []
        self.bench.run_script(script, FakeMCP(), 3, phases,
                              self.args(**overrides), sleep=lambda seconds: None)
        return calls, phases

    def test_the_six_scripts_are_named_and_swipe_is_the_default(self):
        self.assertEqual(self.bench.SCRIPTS,
                         ("swipe", "still", "typing", "video", "soak", "tap"))
        self.assertEqual(self.bench.DEFAULT_SCRIPT, "swipe")

    def test_the_default_swipe_script_is_todays_exact_sequence(self):
        calls, phases = self.run_calls("swipe")
        self.assertEqual([name for name, _ in calls], ["swipe"] * 20)
        for index, (_, arguments) in enumerate(calls):
            self.assertEqual(arguments["y1"], 0.78 if index % 2 == 0 else 0.22)
            self.assertEqual(arguments["ms"], 400 if index < 10 else 150)
            self.assertEqual(arguments["window"], 3)
        self.assertEqual([name for name, _ in phases],
                         ["swipes", "still", "flings", "settle"])

    def test_the_still_script_sends_no_swipe(self):
        calls, phases = self.run_calls("still")
        self.assertEqual(calls, [])
        self.assertEqual([name for name, _ in phases], ["still"])

    def test_the_typing_script_taps_the_documented_point_then_types(self):
        calls, phases = self.run_calls("typing")
        self.assertEqual([name for name, _ in calls], ["tap", "type_text"])
        self.assertEqual(calls[0][1]["x"], self.bench.TYPING_POINT["x"])
        self.assertEqual(calls[0][1]["y"], self.bench.TYPING_POINT["y"])
        self.assertEqual(calls[0][1]["window"], 3)
        self.assertIn("pocketdeck", calls[1][1]["text"])
        self.assertEqual([name for name, _ in phases], ["typing"])

    def test_the_typing_point_can_follow_the_apps_search_field(self):
        calls, _ = self.run_calls("typing", typing_point={"x": 0.5, "y": 0.92})
        self.assertEqual((calls[0][1]["x"], calls[0][1]["y"]), (0.5, 0.92))

    def test_the_video_script_taps_the_play_point(self):
        calls, _ = self.run_calls("video", video_point={"x": 0.25, "y": 0.75})
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "tap")
        self.assertEqual((calls[0][1]["x"], calls[0][1]["y"]), (0.25, 0.75))

    def test_the_soak_script_samples_once_per_period(self):
        calls, phases = self.run_calls("soak", soak_seconds=60, sample_seconds=10)
        self.assertEqual([name for name, _ in calls], ["swipe"] * 6)
        self.assertEqual([name for name, _ in phases], ["soak", "soak-done"])

    def test_the_soak_cadence_uses_the_last_partial_period(self):
        steps = []
        calls = []

        class FakeMCP:
            def text(self, name, arguments):
                calls.append(name)

        phases = []
        self.bench.run_script(
            "soak", FakeMCP(), 3, phases, self.args(soak_seconds=25, sample_seconds=10),
            sleep=lambda seconds: steps.append(seconds),
            sample=lambda seconds: steps.append(-seconds))
        self.assertEqual(steps, [10, -10, 10, -10, 5, -5])
        self.assertEqual(len(calls), 3)


class TapProbeTest(unittest.TestCase):
    """`tap` carries the Mac's input-to-photon number, or fails cleanly."""

    def setUp(self):
        self.bench = load_bench()

    def test_the_reply_becomes_the_photon_and_frame_count(self):
        class Probe:
            def text(self, name, arguments):
                self.call = (name, arguments)
                return {"ok": True, "window": 7, "sent_ms": 1000,
                        "changed_ms": 1042, "frames": 3}

        phases = []
        values = self.bench.drive_tap(Probe(), 7, phases)
        self.assertEqual(values["input_photon_ms"], 1042)
        self.assertEqual(values["input_frames"], 3)
        self.assertEqual([name for name, _ in phases], ["tap"])

    def test_a_missing_tool_fails_the_run_with_the_mark(self):
        class NoProbe:
            def text(self, name, arguments):
                raise RuntimeError("unknown tool input_probe")

        with self.assertRaises(self.bench.BenchFailure) as caught:
            self.bench.drive_tap(NoProbe(), 1, [])
        self.assertIn("no input_probe tool", str(caught.exception))

    def test_a_failed_tap_run_leaves_a_marked_row_and_a_table(self):
        run = {"arm": "tap", "repeat": 1, "script": "tap"}
        run.update(self.bench.empty_metrics())
        line = self.bench.table_line("tap", [run])
        self.assertIn("failed", line.split("  ")[0])
        self.assertIn("-", line)


class NewFieldsTest(unittest.TestCase):
    """New CSV columns are appended; the old columns keep their places."""

    def setUp(self):
        self.bench = load_bench()

    def test_the_new_run_fields_are_appended_in_the_documented_order(self):
        self.assertEqual(list(self.bench.CSV_FIELDS[-len(NEW_RUN_FIELDS):]),
                         NEW_RUN_FIELDS)

    def test_the_old_csv_prefix_is_byte_for_byte_the_same(self):
        self.assertEqual(list(self.bench.CSV_FIELDS[:len(OLD_CSV_FIELDS)]),
                         OLD_CSV_FIELDS)

    def test_every_new_field_is_a_run_cell(self):
        values = self.bench.empty_metrics()
        for field in NEW_RUN_FIELDS:
            self.assertIn(field, values)

    def test_the_table_gains_app_fps_vd_hz_and_the_photon(self):
        self.assertEqual(list(self.bench.TABLE_EXTRA_FIELDS),
                         ["app_fps", "vd_hz", "input_photon_ms"])
        header = self.bench.table_header(8)
        for field in self.bench.TABLE_EXTRA_FIELDS:
            self.assertIn(field, header)

    def test_the_totals_carry_rx_fps_and_the_interval_levels(self):
        total = self.bench.parse_totals(
            "2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]: stats total stream=1 "
            "secs=10.0 rx_frames=600 int_p50=12 int_p95=20 int_p99=30 "
            "shown_p50=8 shown_p95=16 shown_p99=24\n", 1)
        values = self.bench.run_metrics(total)
        self.assertEqual(values["rx_fps"], 60)
        self.assertEqual((values["int_p50"], values["int_p95"], values["int_p99"]),
                         (12, 20, 30))
        self.assertEqual((values["shown_p50"], values["shown_p95"], values["shown_p99"]),
                         (8, 16, 24))
        missing = self.bench.run_metrics(self.bench.parse_totals(
            "2026-11-05 10:00:10.000000-0300 mac PocketDeck[7]: stats total stream=1 "
            "secs=10.0 rx_frames=600\n", 1))
        self.assertIsNone(missing["int_p50"])

    def test_the_app_lines_fill_first_frame_and_resize(self):
        text = ("2026-11-06 10:00:01.000000-0300 mac PocketDeck[7]: "
                "stream 3: first frame, 123.5 ms\n"
                "2026-11-06 10:00:02.000000-0300 mac PocketDeck[7]: "
                "stream 3 resize ack 720x1280 dpi=320 (applied) 42 ms\n")
        values = self.bench.app_line_values(text, 3)
        self.assertEqual(values["first_frame_ms"], 123.5)
        self.assertEqual(values["resize_ms"], 42)
        self.assertIsNone(self.bench.app_line_values(text, 9)["first_frame_ms"])


class PhoneValuesTest(unittest.TestCase):
    """The sampler maps read-only dumps into the new run cells."""

    TEXTS = {
        "gfxinfo": (
            "Total frames rendered: 2\nJanky frames: 1 (50.00%)\n"
            "---PROFILEDATA---\n"
            "Flags,IntendedVsync,Vsync,OldestInputEvent,NewestInputEvent,"
            "HandleInputStart,AnimationStart,PerformTraversalsStart,DrawStart,"
            "SyncStart,IssueDrawCommandsStart,SwapBuffers,FrameCompleted,\n"
            "0,1000000000,1001000000,0,0,0,0,0,0,0,0,0,1016000000,\n"
            "0,1002000000,1003000000,0,0,0,0,0,0,0,0,0,1020000000,\n"
            "---PROFILEDATA---\n"),
        "display": '    DisplayDeviceInfo{"Built-in Screen": uniqueId="local:0", '
                   '1080 x 2400, modeId 1, renderFrameRate 48.0}\n'
                   '    DisplayDeviceInfo{"pocketdeck-1": '
                   'uniqueId="virtual:com.android.shell,0,pocketdeck-1,145", '
                   '1800 x 1200, modeId 254, renderFrameRate 60.0}\n',
        "battery": "  level: 73\n  temperature: 291\n  voltage: 4021\n"
                   "  USB powered: true\n",
        "thermal": "  Thermal Status: 2\n  Temperature{mValue=35.5, mType=0}\n",
        "cpu": "  12.0% 1000/com.example.app: 8.0% user + 4.0% kernel\n"
               "   1.5% 2000/dev.pocketdeck: 1.0% user + 0.5% kernel\n",
        "app_mem": "TOTAL PSS:    8000\n",
        "shell_mem": "TOTAL PSS:   24000\n",
        "wifi": "RSSI: -55, Link speed: 433Mbps, Frequency: 5180MHz "
                "txRetries=7 txBad=3\n",
    }

    def setUp(self):
        self.bench = load_bench()

    def test_the_dumps_fill_every_phone_cell(self):
        values = self.bench.phone_values(self.TEXTS, 10.0, "com.example.app")
        self.assertAlmostEqual(values["app_fps"], 0.2)
        self.assertAlmostEqual(values["app_jank_pct"], 50.0)
        self.assertAlmostEqual(values["vd_hz"], 60.0)
        self.assertEqual(values["battery_level"], 73)
        self.assertAlmostEqual(values["battery_temp_c"], 29.1)
        self.assertEqual(values["thermal_status"], 2)
        self.assertAlmostEqual(values["thermal_max_c"], 35.5)
        self.assertAlmostEqual(values["app_cpu_pct"], 12.0)
        self.assertAlmostEqual(values["shell_cpu_pct"], 1.5)
        self.assertEqual(values["app_pss_kb"], 8000)
        self.assertEqual(values["shell_pss_kb"], 24000)
        self.assertEqual(values["wifi_rssi_dbm"], -55)
        self.assertEqual(values["wifi_mbps"], 433)
        self.assertEqual(values["wifi_mhz"], 5180)
        self.assertEqual(values["wifi_retries"], 7)
        self.assertEqual(values["wifi_bad"], 3)

    def test_absent_dumps_leave_empty_cells(self):
        values = self.bench.phone_values({}, 10.0, "com.example.app")
        for field in ("app_fps", "vd_hz", "battery_level", "thermal_status",
                      "app_cpu_pct", "app_pss_kb", "wifi_rssi_dbm"):
            self.assertIsNone(values[field])

    def test_the_sampler_runs_read_only_dumps_only(self):
        commands = []

        def shell(*args):
            commands.append(args)
            return self.TEXTS.get({
                ("dumpsys", "gfxinfo", "com.example.app", "framestats"): "gfxinfo",
                ("dumpsys", "display"): "display",
                ("dumpsys", "battery"): "battery",
                ("dumpsys", "thermalservice"): "thermal",
                ("dumpsys", "cpuinfo"): "cpu",
                ("dumpsys", "meminfo", "com.example.app"): "app_mem",
                ("dumpsys", "meminfo", "dev.pocketdeck"): "shell_mem",
                ("dumpsys", "wifi"): "wifi",
            }.get(args), "")

        sampler = self.bench.PhoneSampler("adb", "emulator-5554", "com.example.app",
                                          shell=shell)
        sampler.reset()
        sampler.sample(10.0)
        self.assertIn(("dumpsys", "gfxinfo", "com.example.app", "reset"), commands)
        self.assertIn(("dumpsys", "gfxinfo", "com.example.app", "framestats"), commands)
        self.assertIn(("dumpsys", "meminfo", "dev.pocketdeck"), commands)
        for command in commands:
            self.assertEqual(command[0], "dumpsys")
            for forbidden in ("setprop", "settings", "cmd", "input", "screencap"):
                self.assertNotIn(forbidden, command)


class PhoneBlockTest(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()

    def runrow(self, **fields):
        values = {"failed": 0, "covered": 0, "battery_level": 70,
                  "battery_temp_c": 30.0, "thermal_status": 1,
                  "thermal_max_c": 35.0, "app_cpu_pct": 10.0,
                  "shell_cpu_pct": 1.0, "app_pss_kb": 8000,
                  "shell_pss_kb": 24000, "wifi_rssi_dbm": -55,
                  "wifi_mbps": 400, "wifi_mhz": 5180,
                  "wifi_retries": 5, "wifi_bad": 2}
        values.update(fields)
        return values

    def test_the_block_reports_medians_for_battery_thermal_cpu_pss_and_wifi(self):
        line = self.bench.phone_line("baseline", [self.runrow(), self.runrow(
            battery_level=76, battery_temp_c=32.0, app_cpu_pct=14.0,
            app_pss_kb=9000, wifi_rssi_dbm=-49)])
        for label in ("battery", "thermal", "app cpu", "shell cpu",
                      "app pss", "shell pss", "wifi"):
            self.assertIn(label, line)
        self.assertIn("73", line)
        self.assertIn("31.0", line)
        self.assertIn("-52", line)

    def test_failed_and_covered_runs_do_not_move_the_medians(self):
        line = self.bench.phone_line("baseline", [self.runrow(), self.runrow(
            failed=1, battery_level=0, thermal_status=9, app_cpu_pct=99.0)])
        self.assertIn("70", line)
        self.assertNotIn("99", line)


class StageBlockTest(unittest.TestCase):
    """One stage block: encoder, app, network, display, panel, intervals."""

    def setUp(self):
        self.bench = load_bench()

    def runrow(self, **fields):
        values = {"failed": 0, "covered": 0, "frozen": 0, "low_motion": 0,
                  "phone_frames": 540, "app_fps": 58.0, "rx_fps": 59.0,
                  "shown_fps": 58.5, "vd_hz": 60.0,
                  "int_p50": 12.0, "int_p95": 20.0, "int_p99": 30.0,
                  "shown_p50": 8.0, "shown_p95": 16.0, "shown_p99": 24.0}
        values.update(fields)
        return values

    def test_the_header_names_every_stage_and_interval(self):
        header = self.bench.stage_header(8)
        for word in ("encoder", "app", "network", "display", "panel",
                     "int_p50", "int_p95", "int_p99",
                     "shown_p50", "shown_p95", "shown_p99"):
            self.assertIn(word, header)

    def test_the_line_shows_the_medians(self):
        line = self.bench.stage_line("baseline", [self.runrow(),
                                                  self.runrow(phone_frames=600,
                                                              app_fps=60.0)])
        self.assertIn("570.0", line)     # encoder
        self.assertIn("59.0", line)      # app
        self.assertIn("60.0", line)      # panel
        self.assertIn("int_p50=12.0", line)

    def test_missing_interval_levels_print_a_dash(self):
        line = self.bench.stage_line("still", [self.runrow(
            int_p50=None, int_p95=None, int_p99=None,
            shown_p50=None, shown_p95=None, shown_p99=None)])
        self.assertIn("int_p50=-", line)
        self.assertIn("shown_p99=-", line)

    def test_failed_and_covered_runs_are_left_out(self):
        line = self.bench.stage_line("baseline", [
            self.runrow(),
            self.runrow(failed=1, phone_frames=0, app_fps=0.0),
            self.runrow(covered=1, phone_frames=999, app_fps=999.0)])
        self.assertIn("540.0", line)
        self.assertNotIn("999", line)

    def test_a_low_motion_still_run_still_has_stage_numbers(self):
        line = self.bench.stage_line("still", [self.runrow(
            low_motion=1, phone_frames=0, app_fps=0.0, rx_fps=0.0,
            shown_fps=0.0)])
        self.assertIn("0.0", line)


class DryRunEveryScriptTest(unittest.TestCase):
    def test_every_script_dry_runs_without_a_device(self):
        import contextlib
        import io
        import unittest.mock as mock
        bench = load_bench()
        for script in bench.SCRIPTS:
            argv = ["bench.py", "--dry-run", "--script", script,
                    "--profile", "bench2", "--serial", "emulator-5554",
                    "--out", os.path.join(tempfile.gettempdir(), "bench-script.csv"),
                    "--repeats", "1"]
            output = io.StringIO()
            with mock.patch.object(bench, "require_device",
                                   side_effect=AssertionError("dry run touched adb")), \
                    mock.patch("sys.argv", argv), \
                    contextlib.redirect_stdout(output):
                self.assertEqual(bench.main(), 0)
            self.assertIn("script=%s" % script, output.getvalue())


class ActivateAppTest(unittest.TestCase):
    def test_activate_brings_the_named_bundle_to_the_front(self):
        bench = load_bench()
        calls = []

        def run(argv, **kwargs):
            calls.append((argv, kwargs))

        bench.activate_app("/x/PocketDeck.app", run=run)
        self.assertEqual(calls[0][0], ["open", "-a", "/x/PocketDeck.app"])
        self.assertFalse(calls[0][1].get("check", True))

    def test_an_activation_failure_is_best_effort(self):
        bench = load_bench()

        def boom(argv, **kwargs):
            raise OSError("open is gone")

        bench.activate_app("/x/PocketDeck.app", run=boom)


class BenchMainStillTest(unittest.TestCase):
    """One `still` run through main(): table, phone line, stages, CSV cells."""

    LOG = (
        "2026-11-06 10:00:05.000000-0300 mac PocketDeck[7]: "
        "stats stream=1 rx_fps=60 shown_fps=60 phone_n=2\n"
        "2026-11-06 10:00:06.000000-0300 mac PocketDeck[7]: "
        "stream 1: first frame, 123.5 ms\n"
        "2026-11-06 10:00:07.000000-0300 mac PocketDeck[7]: "
        "stream 1 resize ack 720x1280 dpi=320 (applied) 42 ms\n"
        "2026-11-06 10:00:10.000000-0300 mac PocketDeck[7]: "
        "stats total stream=1 secs=10.0 rx_frames=600 shown_frames=590 "
        "phone_frames=600 hitch_n=0 hitch_ms=0 drop_ep=0 drop_ms=0 "
        "susp_n=0 susp_ms=0 phone_n=5 int_p50=12 int_p95=20 int_p99=30 "
        "shown_p50=8 shown_p95=16 shown_p99=24 codec=avc\n"
    )

    def test_one_still_run_samples_before_the_close_and_writes_the_cells(self):
        import contextlib
        import io
        import unittest.mock as mock
        bench = load_bench()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        adb = os.path.join(directory.name, "adb")
        shim = os.path.join(directory.name, "shim")
        out = os.path.join(directory.name, "still.csv")
        with open(shim, "w", encoding="utf-8") as handle:
            handle.write("")
        with open(adb, "w", encoding="utf-8") as handle:
            handle.write("""#!/bin/sh
case "$*" in
  *get-state*) echo device ;;
  *getprop*) echo "" ;;
  *"dumpsys gfxinfo com.android.settings framestats"*)
    echo "Total frames rendered: 10"
    echo "Janky frames: 1 (10.00%)"
    echo "---PROFILEDATA---"
    echo "Flags,IntendedVsync,Vsync,OldestInputEvent,NewestInputEvent,HandleInputStart,AnimationStart,PerformTraversalsStart,DrawStart,SyncStart,IssueDrawCommandsStart,SwapBuffers,FrameCompleted,"
    i=0
    while [ $i -lt 10 ]; do
      echo "0,1000000000,1001000000,0,0,0,0,0,0,0,0,0,1010000000,"
      i=$((i + 1))
    done
    echo "---PROFILEDATA---" ;;
  *"dumpsys gfxinfo"*)
    echo "Total frames rendered: 10"
    echo "Janky frames: 1 (10.00%)" ;;
  *"dumpsys display"*)
    echo 'DisplayDeviceInfo{"Built-in Screen": uniqueId="local:0", 1080 x 2400, renderFrameRate 48.0}'
    echo 'DisplayDeviceInfo{"pocketdeck-1": uniqueId="virtual:com.android.shell,0,pocketdeck-1,145", 1800 x 1200, renderFrameRate 60.0}' ;;
  *"dumpsys battery"*)
    printf '  level: 73\\n  temperature: 291\\n  USB powered: true\\n' ;;
  *"dumpsys thermalservice"*)
    printf '  Thermal Status: 2\\n  Temperature{mValue=35.5, mType=0}\\n' ;;
  *"dumpsys cpuinfo"*)
    printf '  12.0%% 1000/com.android.settings: 8.0%% user + 4.0%% kernel\\n'
    printf '   1.5%% 2000/dev.pocketdeck: 1.0%% user + 0.5%% kernel\\n' ;;
  *"dumpsys meminfo com.android.settings"*) echo "TOTAL PSS:    8000" ;;
  *"dumpsys meminfo dev.pocketdeck"*) echo "TOTAL PSS:   24000" ;;
  *"dumpsys wifi"*)
    echo "RSSI: -55, Link speed: 433Mbps, Frequency: 5180MHz txRetries=7 txBad=3" ;;
esac
""")
        os.chmod(adb, 0o755)

        order = []

        class FakeMCP:
            def __init__(self, shim_path, profile):
                pass

            def text(self, name, arguments):
                order.append(name)
                if name == "open_app":
                    return {"window": 1}
                return {}

            def close(self):
                pass

        real_sampler = bench.PhoneSampler

        class OrderedSampler(real_sampler):
            def reset(self):
                order.append("reset")
                return super().reset()

            def sample(self, seconds):
                order.append("sample")
                # The stub script finishes instantly; a real run's interval is
                # measured, this test's own framestats fixture covers 10 s.
                return super().sample(10.0)

        argv = ["bench.py", "--profile", "bench2", "--serial", "emulator-5554",
                "--adb", adb, "--shim", shim, "--script", "still",
                "--still-seconds", "0", "--repeats", "1",
                "--arms-filter", "baseline", "--out", out,
                "--app", "/x/PocketDeck.app",
                "--package", "com.android.settings"]
        activated = []
        output = io.StringIO()
        with mock.patch.object(bench, "require_device", lambda *a: None), \
                mock.patch.object(bench, "find_app_pid", lambda profile: 123), \
                mock.patch.object(bench, "recent_lines", lambda *a, **k: ""), \
                mock.patch.object(bench, "stats_lines", lambda *a, **k: self.LOG), \
                mock.patch.object(bench, "load_mcp", lambda: FakeMCP), \
                mock.patch.object(bench, "PhoneSampler", OrderedSampler), \
                mock.patch.object(bench, "activate_app",
                                  lambda path, **k: activated.append(path)), \
                mock.patch("sys.argv", argv), \
                contextlib.redirect_stdout(output):
            self.assertEqual(bench.main(), 0)
        self.assertEqual(activated, ["/x/PocketDeck.app"])
        self.assertLess(order.index("sample"), order.index("close_window"),
                        "the phone is sampled while the app is alive")

        text = output.getvalue()
        self.assertIn("phone:", text)
        self.assertIn("stages:", text)
        self.assertIn("still", text)
        with open(out, "r", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["script"], "still")
        self.assertEqual(row["failed"], "0")
        self.assertEqual(row["battery_level"], "73")
        self.assertAlmostEqual(float(row["battery_temp_c"]), 29.1)
        self.assertAlmostEqual(float(row["vd_hz"]), 60.0)
        self.assertAlmostEqual(float(row["first_frame_ms"]), 123.5)
        self.assertAlmostEqual(float(row["resize_ms"]), 42.0)
        self.assertAlmostEqual(float(row["app_fps"]), 1.0)


if __name__ == "__main__":
    unittest.main()
