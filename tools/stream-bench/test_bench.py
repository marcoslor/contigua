#!/usr/bin/env python3
"""Checks for the stream bench's arm handling (no phone, no Mac app).

    python3 tools/stream-bench/test_bench.py

The restore path is the one that must be exact: an arm's property has to go
back to `getprop`'s empty value after the run, and `adb shell setprop name ""`
is not enough (adb drops the empty argument before the device shell sees it).
"""

import datetime
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
        for field in ("tcp_ooo_kb", "tcp_srtt_max", "ph_retrans", "ph_rto", "ph_lost"):
            self.assertIn(field, self.bench.CSV_FIELDS)

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
                     "stall-paced", "stall-ir60"):
            self.assertFalse(by_name[name].get("restart", False),
                             "%s must run interleaved" % name)

    def test_arms_filter_runs_only_matching_prefixes(self):
        arms = self.bench.read_arms(os.path.join(HERE, "arms.json"))
        names = [arm["name"] for arm in self.bench.selected_arms(arms, prefix="stall")]
        self.assertEqual(names, ["stall", "stall-q1", "stall-q1q2-100",
                                 "stall-q2-500", "stall-paced", "stall-ir60"])
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


if __name__ == "__main__":
    unittest.main()
