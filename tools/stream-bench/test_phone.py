#!/usr/bin/env python3
"""Checks for the phone-side parsers (no adb, no device).

    python3 tools/stream-bench/test_phone.py

Every fixture invents its values and names `com.example.app`; a real device's
text never reaches these tests.
"""

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))


def load_phone():
    spec = importlib.util.spec_from_file_location("stream_phone", os.path.join(HERE, "phone.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GFXINFO = """Graphics info for pid 4321 [com.example.app]:

Stats since: 1000000000ns
Total frames rendered: 600
Janky frames: 12 (2.00%)
50th percentile: 8ms
90th percentile: 14ms
95th percentile: 18ms
99th percentile: 32ms
"""

FRAMESTATS = """Graphics info for pid 4321 [com.example.app]:

Total frames rendered: 5
---PROFILEDATA---
Flags,IntendedVsync,Vsync,OldestInputEvent,NewestInputEvent,HandleInputStart,AnimationStart,PerformTraversalsStart,DrawStart,SyncStart,IssueDrawCommandsStart,SwapBuffers,FrameCompleted,
0,1000000000,1001000000,0,0,0,0,0,0,0,0,0,1010000000,
0,1002000000,1003000000,0,0,0,0,0,0,0,0,0,1020000000,
0,1004000000,1005000000,0,0,0,0,0,0,0,0,0,1024000000,
0,1006000000,1007000000,0,0,0,0,0,0,0,0,0,1026000000,
0,1008000000,1009000000,0,0,0,0,0,0,0,0,0,1058000000,
0,1010000000,1011000000,0,0,0,0,0,0,0,0,0,1010000000,
---PROFILEDATA---
"""

DISPLAY = """DISPLAY MANAGER (dumpsys display)
  Display Devices
    DisplayDeviceInfo{"Built-in Screen": uniqueId="local:0", 1080 x 2400, modeId 1, renderFrameRate 60.000004, defaultModeId 1, density 420}
    DisplayDeviceInfo{"Virtual Screen": uniqueId="local:2", 720 x 1280, modeId 2, renderFrameRate 90.0, defaultModeId 2, density 320}
"""

BATTERY = """Current Battery Service state:
  AC powered: false
  USB powered: true
  Wireless powered: false
  status: 2
  health: 2
  present: true
  level: 83
  scale: 100
  voltage: 4021
  temperature: 291
  technology: Li-ion
"""

THERMAL = """Thermal Service (dumpsys thermalservice)
  Thermal Status: 2
  Thermal Status valid: true
  Current temperatures:
    Temperature{mValue=28.4, mType=0, mName=CPU}
    Temperature{mValue=36.5, mType=1, mName=GPU}
"""

CPU = """Load: 2.1 / 2.0 / 1.9
CPU usage from 1000ms to 2000ms ago (2026-11-06 10:00:00.000 to 2026-11-06 10:00:01.000):
  12.3% 1000/com.example.app: 7.0% user + 5.3% kernel
   4.0% 1000/com.example.app:remote: 1.0% user + 3.0% kernel
   1.2% 2000/dev.pocketdeck: 0.5% user + 0.7% kernel
   0.4% 1/init: 0.1% user + 0.3% kernel
"""

MEMINFO = """Applications Memory Usage (in Kilobytes):
Uptime: 12345 Realtime: 12345

** MEMINFO in pid 1000 [com.example.app] **
                   Pss  Private  Private  SwapPss      Rss
                 Total    Dirty    Clean    Dirty    Total
  Native Heap     1024     1000        0        0     1200
  Dalvik Heap     2048     2000        0        0     2100
        TOTAL     8000     7000      100      0      9000
       TOTAL PSS:    8000            TOTAL RSS:    9000       TOTAL SWAP PSS:      0
"""

WIFI = """Wi-Fi is enabled
WifiInfo: SSID: "Test Network", BSSID: 02:00:00:00:00:01, MAC: 02:00:00:00:00:02, IP: /192.0.2.10, Supplicant state: COMPLETED, Wi-Fi standard: 5, RSSI: -55, Link speed: 433Mbps, Tx Link speed: 390Mbps, Rx Link speed: 433Mbps, Frequency: 5180MHz
WifiLinkLayerStats: txRetries=7 txBad=3
"""

LOG = """2026-11-06 10:00:01.000000-0300 mac PocketDeck[7]: stream 3: first frame, opening cover off
2026-11-06 10:00:01.250000-0300 mac PocketDeck[7]: stream 3: first frame 123.5 ms
2026-11-06 10:00:05.000000-0300 mac PocketDeck[7]: stream 3 resize ack 720x1280 dpi=320 (applied) 42 ms
2026-11-06 10:00:06.000000-0300 mac PocketDeck[7]: stream 4: first frame 200 ms
"""


class GfxinfoTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_the_summary_gives_rendered_janky_and_percent(self):
        values = self.phone.gfxinfo_summary(GFXINFO)
        self.assertEqual(values["frames"], 600)
        self.assertEqual(values["janky_frames"], 12)
        self.assertAlmostEqual(values["janky_pct"], 2.0)

    def test_an_empty_summary_is_absent_not_zero(self):
        values = self.phone.gfxinfo_summary("")
        self.assertIsNone(values["frames"])
        self.assertIsNone(values["janky_frames"])
        self.assertIsNone(values["janky_pct"])

    def test_framestats_percentiles_and_fps_come_from_the_rows(self):
        values = self.phone.framestats(FRAMESTATS, 2.0)
        # Durations: 10, 10, 20, 20, 50 ms; the zero-length row is no frame.
        self.assertEqual(values["frames"], 5)
        self.assertEqual(values["p50_ms"], 20)
        self.assertEqual(values["p95_ms"], 50)
        self.assertEqual(values["p99_ms"], 50)
        self.assertEqual(values["fps"], 2.5)

    def test_no_framestats_block_is_absent(self):
        values = self.phone.framestats("Total frames rendered: 0\n", 10.0)
        self.assertEqual(values["frames"], 0)
        self.assertIsNone(values["p50_ms"])
        self.assertIsNone(values["p95_ms"])
        self.assertIsNone(values["p99_ms"])
        self.assertEqual(values["fps"], 0.0)


class DisplayTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_the_display_line_gives_refresh_and_size(self):
        values = self.phone.display_refresh(DISPLAY, 0)
        self.assertAlmostEqual(values["hz"], 60.000004)
        self.assertEqual((values["width"], values["height"]), (1080, 2400))

    def test_another_display_is_read_by_its_own_id(self):
        values = self.phone.display_refresh(DISPLAY, 2)
        self.assertAlmostEqual(values["hz"], 90.0)
        self.assertEqual((values["width"], values["height"]), (720, 1280))

    def test_a_missing_display_is_nil(self):
        self.assertIsNone(self.phone.display_refresh(DISPLAY, 9))
        self.assertIsNone(self.phone.display_refresh("", 0))

    def test_the_mirror_virtual_display_is_the_default(self):
        # The phone names its mirror VD "pocketdeck-N" with a virtual uniqueId;
        # that is the display whose rate the stream sets.
        text = DISPLAY + (
            '    DisplayDeviceInfo{"pocketdeck-2": '
            'uniqueId="virtual:com.android.shell,0,pocketdeck-2,145", '
            '1800 x 1200, modeId 254, renderFrameRate 60.0, defaultModeId 254, '
            'density 320}\n')
        values = self.phone.display_refresh(text)
        self.assertAlmostEqual(values["hz"], 60.0)
        self.assertEqual((values["width"], values["height"]), (1800, 1200))

    def test_no_mirror_display_is_nil_even_with_a_physical_one(self):
        self.assertIsNone(self.phone.display_refresh(DISPLAY))


class BatteryTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_level_temperature_voltage_and_charging(self):
        values = self.phone.battery(BATTERY)
        self.assertEqual(values["level"], 83)
        self.assertAlmostEqual(values["temp_c"], 29.1)
        self.assertEqual(values["voltage"], 4021)
        self.assertTrue(values["charging"])

    def test_an_empty_battery_dump_is_nil(self):
        self.assertIsNone(self.phone.battery("Current Battery Service state:\n"))

    def test_ac_power_also_counts_as_charging(self):
        text = "Current Battery Service state:\n  AC powered: true\n  level: 50\n"
        self.assertTrue(self.phone.battery(text)["charging"])


class ThermalTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_status_and_the_hottest_temperature(self):
        values = self.phone.thermal(THERMAL)
        self.assertEqual(values["status"], 2)
        self.assertEqual(values["max_c"], 36.5)

    def test_an_empty_thermal_dump_is_nil(self):
        self.assertIsNone(self.phone.thermal("Thermal Service (dumpsys thermalservice)\n"))


class CpuTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_each_package_sums_its_processes(self):
        values = self.phone.cpu(CPU)
        self.assertAlmostEqual(values["com.example.app"], 16.3)
        self.assertAlmostEqual(values["dev.pocketdeck"], 1.2)

    def test_a_zero_share_with_a_plus_prefix_is_zero_not_nil(self):
        # `dumpsys cpuinfo` prints an idle process as `+0%`, not ` 0%`.
        values = self.phone.cpu("+0% 1234/com.example.app: 0% user + 0% kernel\n")
        self.assertEqual(values["com.example.app"], 0.0)

    def test_an_absent_package_is_nil(self):
        values = self.phone.cpu("Load: 0.0 / 0.0 / 0.0\n")
        self.assertIsNone(values["com.example.app"])
        self.assertIsNone(values["dev.pocketdeck"])

    def test_a_custom_package_can_be_asked_for(self):
        values = self.phone.cpu(CPU, ("com.example.app",))
        self.assertEqual(set(values), {"com.example.app"})


class MeminfoTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_total_pss_is_kilobytes(self):
        self.assertEqual(self.phone.meminfo(MEMINFO), 8000)

    def test_the_older_total_line_still_parses(self):
        self.assertEqual(self.phone.meminfo("TOTAL 123456\n"), 123456)

    def test_an_empty_meminfo_is_nil(self):
        self.assertIsNone(self.phone.meminfo(""))


class WifiTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_numeric_link_facts_and_no_names(self):
        values = self.phone.wifi(WIFI)
        self.assertEqual(values["rssi_dbm"], -55)
        self.assertEqual(values["mbps"], 433)
        self.assertEqual(values["mhz"], 5180)
        self.assertEqual(values["retries"], 7)
        self.assertEqual(values["bad"], 3)
        self.assertTrue(values["pass"])
        rendered = repr(values)
        for forbidden in ("Test Network", "02:00:00:00:00:01", "02:00:00:00:00:02",
                          "192.0.2.10"):
            self.assertNotIn(forbidden, rendered)

    def test_an_empty_wifi_dump_is_nil(self):
        self.assertIsNone(self.phone.wifi("Wi-Fi is enabled\n"))


class AppLinesTest(unittest.TestCase):
    def setUp(self):
        self.phone = load_phone()

    def test_first_frame_ms_is_the_streams_own_number(self):
        self.assertEqual(self.phone.first_frame_ms(LOG, 3), 123.5)
        self.assertEqual(self.phone.first_frame_ms(LOG, 4), 200.0)

    def test_an_older_first_frame_line_without_a_number_is_none(self):
        text = "2026-11-06 10:00:01.000000-0300 mac PocketDeck[7]: stream 3: first frame, opening cover off\n"
        self.assertIsNone(self.phone.first_frame_ms(text, 3))
        self.assertIsNone(self.phone.first_frame_ms(LOG, 9))

    def test_resize_ack_ms_is_the_streams_own_number(self):
        self.assertEqual(self.phone.resize_ack_ms(LOG, 3), 42.0)
        self.assertIsNone(self.phone.resize_ack_ms(LOG, 4))


if __name__ == "__main__":
    unittest.main()
