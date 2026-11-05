#!/usr/bin/env python3
"""Checks for stats-summary.py (no Mac app, no phone).

    python3 macos/scripts/test_stats_summary.py

The line the bench and the reviewer read gains hitch/late/drop-gap fields; the
summary must sum the event counters and take the p99 as a median like every
other level.
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "stats-summary.py")

TWO_LINES = """\
2026-11-05 10:00:05.000000+0000 PocketDeck[1]: stats stream=1 size=100x100 view=100x100 place=fit rx_fps=60.0 shown_fps=59.0 int_p95=16.0 int_p99=17.0 freeze_n=0 freeze_ms=0 hitch_n=1 hitch_ms=290 late_p99=283.0 mac_drop=0 phone_drop=0 drop_ep=1 drop_ms=280 phone_n=2 skip=0 susp_n=0 susp_ms=0 refine_n=0 kf=0 kf_req=0 kbps=1000 target_kbps=8000 qp_p50=- qp_p95=- enc_p50=- enc_p95=- queue_p95=- e2e_p50=1.0 e2e_p95=2.0
2026-11-05 10:00:10.000000+0000 PocketDeck[1]: stats stream=1 size=100x100 view=100x100 place=fit rx_fps=60.0 shown_fps=59.0 int_p95=16.0 int_p99=17.0 freeze_n=0 freeze_ms=0 hitch_n=1 hitch_ms=300 late_p99=17.0 mac_drop=0 phone_drop=0 drop_ep=0 drop_ms=- phone_n=0 skip=0 susp_n=0 susp_ms=0 refine_n=0 kf=0 kf_req=0 kbps=- target_kbps=- qp_p50=- qp_p95=- enc_p50=- enc_p95=- queue_p95=- e2e_p50=1.0 e2e_p95=2.0
"""


def load_script():
    spec = importlib.util.spec_from_file_location("stats_summary", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StatsSummaryTest(unittest.TestCase):
    def setUp(self):
        self.summary = load_script()

    def test_the_parsed_line_keeps_a_missing_value_absent(self):
        rows = self.summary.parse_lines(TWO_LINES)["1"]
        self.assertEqual(len(rows), 2)
        self.assertIsNone(rows[1]["drop_ms"])
        self.assertEqual(rows[0]["drop_ms"], "280")

    def test_hitch_and_drop_gap_counters_are_summed(self):
        summary = self.summary.summarise(self.summary.parse_lines(TWO_LINES)["1"])
        fields = summary["fields"]
        self.assertEqual(fields["hitch_n"]["sum"], 2)
        self.assertEqual(fields["hitch_ms"]["sum"], 590)
        self.assertEqual(fields["drop_ms"]["sum"], 280)
        self.assertEqual(fields["drop_ep"]["sum"], 1)
        # A missing value on one line is not a zero sample.
        self.assertEqual(fields["drop_ms"]["samples"], 1)

    def test_late_p99_is_a_level_so_it_takes_the_median(self):
        summary = self.summary.summarise(self.summary.parse_lines(TWO_LINES)["1"])
        self.assertEqual(summary["fields"]["late_p99"]["median"], 150)
        self.assertEqual(summary["fields"]["late_p99"]["samples"], 2)

    def test_the_new_event_counters_are_clock_fields(self):
        for name in ("hitch_n", "hitch_ms", "drop_ms", "drop_ep", "phone_n"):
            self.assertIn(name, self.summary.CLOCK_FIELDS)
        self.assertNotIn("late_p99", self.summary.CLOCK_FIELDS)

    def test_phone_n_is_summed_and_a_zero_line_is_a_sample(self):
        summary = self.summary.summarise(self.summary.parse_lines(TWO_LINES)["1"])
        phone_n = summary["fields"]["phone_n"]
        self.assertEqual(phone_n["sum"], 2)
        self.assertEqual(phone_n["samples"], 2, "phone_n=0 is a sample, not a missing value")
        self.assertEqual(phone_n["median"], 1)

    def test_a_line_without_phone_n_is_not_a_sample(self):
        text = TWO_LINES.splitlines()[0].replace("phone_n=2 ", "") + "\n"
        summary = self.summary.summarise(self.summary.parse_lines(text)["1"])
        self.assertEqual(summary["fields"].get("phone_n", {"samples": 0})["samples"], 0)


if __name__ == "__main__":
    unittest.main()
