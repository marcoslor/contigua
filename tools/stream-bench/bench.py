#!/usr/bin/env python3
"""Stream bench (ISS-40): repeat a fixed swipe script against one Mac app and
summarise the per-window `stats …` lines each run wrote.

The app must already be running with its automation socket on (Settings ›
Automation, or the e2e bundle's `--mcp-enable`); this script only drives it
through the same stdio shim `mcp-driver.py` uses. It never launches, quits or
changes the Mac app.

    tools/stream-bench/bench.py --profile default --serial R58M1234 \
        --repeats 3 --out .work/stats/bench.csv

Arms are named in arms.json: phone properties (`debug.contigua.stream.*` via
`adb -s <serial> shell setprop`) and Mac defaults (`defaults write <domain>`)
are set before a run and restored after it. An arm with `"restart": true` is
left out of the default run: its key is read when the app dials, and the bench
never relaunches or reconnects the app (`--include-restart-arms` overrides).

The phone is addressed only through the given serial; the script refuses an
unreachable one and never runs `adb kill-server`. Nothing is changed on the
phone except the named `debug.contigua.stream.*` properties, and those are
put back the way they were.
"""

import argparse
import csv
import datetime
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MACOS = os.path.join(ROOT, "macos")
DEFAULT_SHIM = "/Applications/Contigua.app/Contents/Helpers/contigua-mcp"
PROFILE_DOMAIN = "app.contigua.mac"
STATS_PREFIX = "debug.contigua.stream."

# The scripts are composable: swipe is today's exact sequence, and the others
# exercise one stage or one input path each.
SCRIPTS = ("swipe", "still", "typing", "video", "soak", "tap")
DEFAULT_SCRIPT = "swipe"
STILL_SECONDS = 6.0
VIDEO_SECONDS = 8.0
SOAK_SECONDS = 20 * 60.0
SAMPLE_SECONDS = 10.0
TYPING_POINT = {"x": 0.5, "y": 0.08}
TYPING_TEXT = "contigua bench typing"
PLAY_POINT = {"x": 0.5, "y": 0.5}
TAP_POINT = {"x": 0.5, "y": 0.5}

# One row per arm; each cell is median (min–max) across the arm's runs.
# jank_* lead: what a person feels while the phone's content moves is a hitch
# on the Mac, a drop gap on the phone, or a suspend (Q1).
TABLE_FIELDS = ("jank_ms", "jank_n", "hitch_ms", "drop_ms", "susp_ms",
                "late_p99", "shown_fps", "kf", "key_not_idr", "ph_key_not_idr",
                "kbps", "rx_kbps", "tcp_ooo_kb", "ph_retrans", "qp_p95",
                "qp_avg", "e2e_p50", "e2e_p95")
# The per-stage table columns are appended after the long-standing fields so a
# reader comparing rounds still finds the old columns where they were.
TABLE_EXTRA_FIELDS = ("app_fps", "vd_hz", "input_photon_ms")
# The stream's codec is a name, not a number: it gets its own table column.
TABLE_TEXT_FIELDS = ("codec",)
# One CSV row per run: the table fields plus the totals that are not table
# cells and the marks a reader needs to exclude a run. New columns go after
# the old ones, in the order the brief names them.
NEW_RUN_FIELDS = ("script", "input_photon_ms", "input_frames", "first_frame_ms",
                  "resize_ms", "app_fps", "app_jank_pct", "vd_hz", "battery_level",
                  "battery_temp_c", "thermal_status", "thermal_max_c",
                  "app_cpu_pct", "shell_cpu_pct", "app_pss_kb", "shell_pss_kb",
                  "wifi_rssi_dbm", "wifi_mbps", "wifi_mhz", "wifi_retries",
                  "wifi_bad")
CSV_FIELDS = (["repeat", "arm", "stream", "start", "end", "lines",
               "codec", "failed", "covered", "secs", "rx_frames", "shown_frames",
               "phone_frames", "kf_req", "bytes", "covered_ms", "max_gap_ms",
               "tcp_ooo_kb", "tcp_srtt_max", "ph_retrans", "ph_rto", "ph_lost"]
              + list(TABLE_FIELDS)
              + ["frozen", "low_motion", "no_drop_ms", "phone_gaps"]
              + list(NEW_RUN_FIELDS))
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)([+-]\d{4})")

STAGE_FIELDS = ("phone_fps", "app_fps", "rx_fps", "shown_fps", "vd_hz")
STAGE_NAMES = ("encoder", "app", "network", "display", "panel")
INTERVAL_FIELDS = ("int_p50", "int_p95", "int_p99",
                   "shown_p50", "shown_p95", "shown_p99")
PHONE_FIELDS = ("app_fps", "app_jank_pct", "vd_hz", "battery_level",
                "battery_temp_c", "thermal_status", "thermal_max_c",
                "app_cpu_pct", "shell_cpu_pct", "app_pss_kb", "shell_pss_kb",
                "wifi_rssi_dbm", "wifi_mbps", "wifi_mhz", "wifi_retries",
                "wifi_bad")
SAMPLE_FIELDS = ("at", "repeat", "arm", "sample_seconds") + PHONE_FIELDS
# label, run field, unit, decimals: one `phone` line per arm.
PHONE_COLUMNS = (("battery", "battery_level", "%", 0),
                 ("temp", "battery_temp_c", "C", 1),
                 ("thermal", "thermal_status", "", 0),
                 ("thermal max", "thermal_max_c", "C", 1),
                 ("app cpu", "app_cpu_pct", "%", 1),
                 ("shell cpu", "shell_cpu_pct", "%", 1),
                 ("app pss", "app_pss_kb", "kB", 0),
                 ("shell pss", "shell_pss_kb", "kB", 0),
                 ("wifi", "wifi_rssi_dbm", "dBm", 0),
                 ("wifi mbps", "wifi_mbps", "Mbps", 0),
                 ("wifi mhz", "wifi_mhz", "MHz", 0),
                 ("wifi retries", "wifi_retries", "", 0),
                 ("wifi bad", "wifi_bad", "", 0))


def load_phone():
    """The parser module; loaded by path so the bench runs from any cwd."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "phone.py")
    spec = importlib.util.spec_from_file_location("stream_phone", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


phone = load_phone()


def profile_domain(profile):
    """The defaults suite a run's Mac keys go to: the person's own domain for
    the default profile, else that profile's suffixed suite."""
    return PROFILE_DOMAIN if profile == "default" else "%s.%s" % (PROFILE_DOMAIN, profile)


def selected_arms(arms, include_restart=False, prefix=None):
    """The arms a run executes. An arm marked `restart` needs a fresh session
    for a key that is read at dial time (N1's Mac side); the default list leaves
    it out because the bench never quits or reconnects the app. `prefix` runs
    only the arms whose name starts with it (`--arms-filter`)."""
    chosen = list(arms)
    if prefix:
        chosen = [arm for arm in chosen if arm["name"].startswith(prefix)]
    if include_restart:
        return chosen
    return [arm for arm in chosen if not arm.get("restart", False)]


def log(message):
    print("bench: " + message, flush=True)


def fail(message):
    print("bench: FAIL " + message, file=sys.stderr, flush=True)
    raise SystemExit(2)


class BenchFailure(Exception):
    """One run failed: the bench marks it and goes on."""


def load_mcp():
    """The stdio MCP client mcp-driver.py already proves against the app."""
    path = os.path.join(MACOS, "scripts", "mcp-driver.py")
    spec = importlib.util.spec_from_file_location("pd_mcp_driver", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.MCP


def run_command(command, check=True):
    result = subprocess.run(command, capture_output=True, text=True)
    if check and result.returncode != 0:
        fail("%s failed: %s" % (" ".join(command), (result.stderr or result.stdout).strip()))
    return result


def adb(adb_path, serial, *args, check=True):
    return run_command([adb_path, "-s", serial] + list(args), check=check)


def require_device(adb_path, serial):
    result = adb(adb_path, serial, "get-state", check=False)
    state = (result.stdout or "").strip()
    if state != "device":
        fail("serial %s is not reachable (adb get-state: %r)" % (serial, state or result.stderr.strip()))


def read_arms(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    arms = data.get("arms") or []
    if not arms:
        fail("%s lists no arms" % path)
    for arm in arms:
        arm.setdefault("phone", {})
        arm.setdefault("mac", {})
    return arms


def set_phone_property(adb_path, serial, key, value):
    name = STATS_PREFIX + key
    text = str(value)
    if text == "":
        # adb drops an empty argument before the device shell parses it, so
        # `setprop name` alone is a usage error. The clearing form goes as one
        # quoted remote command: the device shell then passes the empty value.
        adb(adb_path, serial, "shell", 'setprop %s ""' % name)
    else:
        adb(adb_path, serial, "shell", "setprop", name, text)


def get_phone_property(adb_path, serial, key):
    result = adb(adb_path, serial, "shell", "getprop", STATS_PREFIX + key, check=False)
    return (result.stdout or "").strip()


def set_mac_default(domain, key, value):
    run_command(["defaults", "write", domain, key, "-string", str(value)])


def get_mac_default(domain, key):
    result = run_command(["defaults", "read", domain, key], check=False)
    return (result.stdout or "").strip() if result.returncode == 0 else None


def restore_mac_default(domain, key, old):
    if old is None:
        run_command(["defaults", "delete", domain, key], check=False)
    else:
        set_mac_default(domain, key, old)


class ArmSettings:
    """Set an arm on both sides and put both back exactly as they were."""

    def __init__(self, adb_path, serial, domain):
        self.adb_path = adb_path
        self.serial = serial
        self.domain = domain
        self.phone_old = {}
        self.mac_old = {}

    def apply(self, arm):
        for key, value in arm["phone"].items():
            self.phone_old[key] = get_phone_property(self.adb_path, self.serial, key)
            set_phone_property(self.adb_path, self.serial, key, value)
        for key, value in arm["mac"].items():
            self.mac_old[key] = get_mac_default(self.domain, key)
            set_mac_default(self.domain, key, value)

    def restore(self):
        for key, old in self.phone_old.items():
            # An empty value clears the property, as it was before the arm.
            set_phone_property(self.adb_path, self.serial, key, old)
        for key, old in self.mac_old.items():
            restore_mac_default(self.domain, key, old)
        self.phone_old = {}
        self.mac_old = {}


def stats_lines(start, predicate):
    command = ["/usr/bin/log", "show", "--start", start, "--info", "--style", "syslog",
               "--predicate", predicate]
    result = subprocess.run(command, capture_output=True, text=True)
    return result.stdout or ""


def recent_lines(predicate, seconds=10):
    """The app's lines in the last `seconds`, for the open-window guard."""
    command = ["/usr/bin/log", "show", "--last", "%ds" % seconds, "--info",
               "--style", "syslog", "--predicate", predicate]
    result = subprocess.run(command, capture_output=True, text=True)
    return result.stdout or ""


def log_predicate(pid):
    """The app's own lines only: another Contigua process must never mix in.
    The pid comes from the profile's process, never from the subsystem alone."""
    return 'subsystem == "%s" AND processID == %d' % (PROFILE_DOMAIN, pid)


def profile_app_pid(ps_text, profile):
    """The pid of the app running this profile: the command starts with the
    bundle's `Contents/MacOS/Contigua` and carries `--profile <profile>`.
    A Dock shim or another profile's app never matches."""
    marker = re.compile(r"--profile\s+%s(?:\s|$)" % re.escape(profile))
    any_profile = re.compile(r"--profile(?:\s|=|$)")
    for line in ps_text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        command = parts[1].strip()
        if not command:
            continue
        executable = command.split()[0]
        if not executable.endswith("/Contents/MacOS/Contigua"):
            continue
        if marker.search(command):
            return int(parts[0])
        # The person's installed app, opened from Finder or `open -a`, carries
        # no flag at all: that process is the default profile.
        if profile == "default" and not any_profile.search(command):
            return int(parts[0])
    return None


def find_app_pid(profile):
    result = subprocess.run(["ps", "-axww", "-o", "pid=,command="],
                            capture_output=True, text=True)
    return profile_app_pid(result.stdout or "", profile)


def has_open_window(text):
    """True when a live stream has a `stats stream=` line and no later close.

    The closing `stats total stream=` line and the app's `stream N: closed`
    line both end a stream; a stale stats line must not refuse the next run.
    """
    open_streams = set()
    for line in text.splitlines():
        found = re.search(r" stats stream=(\d+)\b", line)
        if found:
            open_streams.add(int(found.group(1)))
            continue
        found = re.search(r" stats total stream=(\d+)\b", line)
        if found:
            open_streams.discard(int(found.group(1)))
            continue
        found = re.search(r" stream (\d+): closed\b", line)
        if found:
            open_streams.discard(int(found.group(1)))
    return bool(open_streams)


def fields_from_line(line):
    fields = {}
    for word in line.split():
        if "=" not in word:
            continue
        key, value = word.split("=", 1)
        fields[key] = value
    return fields


def row_timestamp(line):
    match = STAMP.match(line.strip())
    if not match:
        return None
    try:
        return datetime.datetime.strptime(
            match.group(1) + match.group(2),
            "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
    except ValueError:
        return None


def parse_rows(text, stream):
    """One dict per `stats stream=<stream>` line, with its wall-clock time."""
    marker = " stats stream=%s " % stream
    rows = []
    for line in text.splitlines():
        if marker not in line + " ":
            continue
        at = row_timestamp(line)
        if at is None:
            continue
        fields = {"at": at}
        fields.update(fields_from_line(line))
        rows.append(fields)
    return rows


def parse_totals(text, stream):
    """The one `stats total stream=<stream>` line, or None."""
    marker = " stats total stream=%s " % stream
    for line in text.splitlines():
        if marker not in line + " ":
            continue
        if row_timestamp(line) is None:
            continue
        return fields_from_line(line)
    return None


def wait_for_totals(stream, began, predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        total = parse_totals(stats_lines(began, predicate), stream)
        if total is not None:
            return total
        time.sleep(0.5)
    return None


def number(row, key):
    raw = row.get(key)
    if raw in (None, "-"):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def median(values):
    return statistics.median(values) if values else None


SWIPE_PHASES = ("swipes", "flings")


def swipe_windows(phases):
    """[(start, end)] of the script's two swipe phases; [] when unknown."""
    if not phases:
        return []
    windows = []
    for index, (name, start) in enumerate(phases):
        if name not in SWIPE_PHASES:
            continue
        end = phases[index + 1][1] if index + 1 < len(phases) else float("inf")
        windows.append((start, end))
    return windows


# A picture gone for longer than this across the run is frozen. The 5 s line
# is a 2 s sample, so it can miss a gap that falls between two lines; the
# totals' max_gap_ms covers the whole life.
FROZEN_GAP_MS = 2500


def is_frozen(total, sampled, phases=None):
    """True when the run's picture was gone for over 2.5 s.

    `max_gap_ms` on the closing totals line is the run's longest interval
    between received frames, outside covered time: it sees a freeze that a
    5 s line's 2 s window can miss. An older log has no such field, so then a
    5 s line in a swipe phase under 10 fps still marks the run frozen. The
    still phases carry heartbeat frames only and never count; without phases
    (a fixture) every sampled line is a swipe line.
    """
    gap = number(total or {}, "max_gap_ms")
    if gap is not None:
        return gap > FROZEN_GAP_MS
    windows = swipe_windows(phases)
    for row in sampled:
        fps = number(row, "rx_fps")
        if fps is None or fps >= 10:
            continue
        at = row.get("at")
        if windows and at is not None:
            if not any(start <= at <= end for start, end in windows):
                continue
        return True
    return False


def counted(run):
    """The runs that make an arm's medians: not failed, covered or frozen.

    A low-motion run is left out too, except the `tap` script: its screen is
    idle by design and its `input_photon_ms` is the measurement."""
    if run.get("failed") or run.get("covered") or run.get("frozen"):
        return False
    return run.get("script") == "tap" or not run.get("low_motion")


def valid_runs(runs):
    return sum(1 for run in runs if counted(run))


def run_metrics(total, sampled=(), phases=None):
    """A run's table values plus its marks, all from the closing totals line.

    The totals carry no phases: `shown_fps`, `late_p99` and both e2e levels are
    over the run's whole life. `kbps` is the phone's bytes over `secs`; a run
    whose `rx_frames / secs` is under 20 moved too little to compare strategies.
    A run with `covered_ms > 0` spent time hidden and is left out of the medians.
    A run whose 5 s line in a swipe phase is under 10 fps is `frozen`: the
    picture stopped while the content moved.
    `qp_p95` is a level, not a counter, and the totals line has none: it is the
    median over the 5 s lines that folded in a phone message.
    """
    secs = number(total, "secs") or 0.0
    covered_ms = number(total, "covered_ms") or 0.0
    active = max(0.0, secs - covered_ms / 1000.0)
    rx = number(total, "rx_frames") or 0
    shown = number(total, "shown_frames") or 0
    phone_frames = number(total, "phone_frames")
    hitch_n = int(number(total, "hitch_n") or 0)
    hitch_ms = number(total, "hitch_ms") or 0
    drop_ep = int(number(total, "drop_ep") or 0)
    drop_ms = number(total, "drop_ms")
    susp_n = int(number(total, "susp_n") or 0)
    susp_ms = number(total, "susp_ms") or 0
    phone_bytes = number(total, "bytes") or 0
    phone_n = int(number(total, "phone_n") or 0)
    qp = [number(row, "qp_p95") for row in sampled
          if (number(row, "phone_n") or 0) >= 1]
    qp = [value for value in qp if value is not None]
    return {
        "jank_ms": hitch_ms + (drop_ms or 0) + susp_ms,
        "jank_n": hitch_n + drop_ep + susp_n,
        "hitch_ms": hitch_ms,
        "drop_ms": drop_ms or 0,
        "susp_ms": susp_ms,
        "late_p99": number(total, "late_p99"),
        "shown_fps": shown / active if active > 0 else None,
        "kf": number(total, "kf"),
        "key_not_idr": number(total, "key_not_idr"),
        "ph_key_not_idr": number(total, "ph_key_not_idr"),
        "kbps": phone_bytes * 8 / (secs * 1000) if secs > 0 else None,
        "rx_kbps": number(total, "rx_kbps"),
        "qp_p95": median(qp),
        "qp_avg": number(total, "qp_avg"),
        "codec": total.get("codec") if total.get("codec") not in (None, "-") else None,
        "e2e_p50": number(total, "e2e_p50"),
        "e2e_p95": number(total, "e2e_p95"),
        "rx_fps": rx / secs if secs > 0 else None,
        "phone_fps": (phone_frames / secs
                      if secs > 0 and phone_frames is not None else None),
        "int_p50": number(total, "int_p50"),
        "int_p95": number(total, "int_p95"),
        "int_p99": number(total, "int_p99"),
        "shown_p50": number(total, "shown_p50"),
        "shown_p95": number(total, "shown_p95"),
        "shown_p99": number(total, "shown_p99"),
        "frozen": is_frozen(total, sampled, phases),
        "low_motion": (rx / secs) < 20 if secs > 0 else True,
        "no_drop_ms": total.get("drop_ms") in (None, "-"),
        "phone_gaps": phone_n <= 0,
        "covered": covered_ms > 0,
        "failed": 0,
        "secs": secs,
        "rx_frames": rx,
        "shown_frames": shown,
        "phone_frames": phone_frames,
        "kf_req": number(total, "kf_req"),
        "bytes": phone_bytes,
        "covered_ms": covered_ms,
        "max_gap_ms": number(total, "max_gap_ms"),
        "tcp_ooo_kb": number(total, "tcp_ooo_kb"),
        "tcp_srtt_max": number(total, "tcp_srtt_max"),
        "ph_retrans": number(total, "ph_retrans"),
        "ph_rto": number(total, "ph_rto"),
        "ph_lost": number(total, "ph_lost"),
    }


def empty_metrics():
    """A failed run's cells: every number absent, its marks set."""
    values = {field: None for field in TABLE_FIELDS + TABLE_EXTRA_FIELDS}
    values.update({field: None for field in NEW_RUN_FIELDS})
    values.update({field: None for field in
                   ("rx_fps", "int_p50", "int_p95", "int_p99",
                    "shown_p50", "shown_p95", "shown_p99")})
    values.update({"frozen": 0, "low_motion": 0, "no_drop_ms": 0, "phone_gaps": 0,
                   "covered": 0, "failed": 1, "secs": None, "rx_frames": None,
                   "shown_frames": None, "phone_frames": None, "phone_fps": None,
                   "kf_req": None,
                   "bytes": None, "covered_ms": None, "max_gap_ms": None,
                   "codec": None})
    return values


def table_fields():
    """The table's numeric columns: the long-standing ones, then the stages."""
    return TABLE_FIELDS + TABLE_EXTRA_FIELDS


def summarise(runs):
    """One cell per table field: the median and min–max of the runs that count.
    Failed, covered, frozen and low-motion runs are excluded; no valid run
    leaves the cell `-`."""
    valid = [run for run in runs if counted(run)]
    cells = {}
    for field in table_fields():
        values = [run[field] for run in valid if run.get(field) is not None]
        cells[field] = (statistics.median(values), min(values), max(values)) if values else None
    return cells


def table_line(name, runs, width=3):
    """One arm's table row, with the marks a reader must not miss."""
    marks = []
    if any(run.get("failed") for run in runs):
        marks.append("failed")
    if any(run.get("covered") for run in runs):
        marks.append("covered")
    if any(run.get("frozen") for run in runs):
        marks.append("frozen")
    if any(run.get("low_motion") for run in runs):
        marks.append("low-motion")
    if any(run.get("no_drop_ms") for run in runs):
        marks.append("no drop_ms")
    if any(run.get("phone_gaps") for run in runs):
        marks.append("phone gaps")
    label = name + (" (%s)" % ", ".join(marks) if marks else "")
    codecs = sorted({run.get("codec") for run in runs if run.get("codec")})
    codec = "/".join(codecs) if codecs else "-"
    cells = summarise(runs)
    rendered = []
    for field in table_fields():
        cell = cells[field]
        if cell is None:
            rendered.append("-".rjust(10))
        else:
            middle, low, high = cell
            rendered.append(("%.1f (%.1f-%.1f)" % (middle, low, high)).rjust(10))
    return "%-*s  %5d  %-6s  %s" % (width, label, valid_runs(runs), codec,
                                    "  ".join(rendered))


def table_header(width=3):
    """The table's one header row, with the valid count before the medians."""
    return "%-*s  %5s  %-6s  %s" % (width, "arm", "valid", "codec",
                                    "  ".join(field.rjust(10)
                                              for field in table_fields()))


def _stage_values(runs, field):
    values = [run.get(field) for run in runs if run.get(field) is not None]
    return values


def _stage_cell(values):
    if not values:
        return "-"
    return "%.1f (%.1f-%.1f)" % (statistics.median(values), min(values), max(values))


def stage_runs(runs):
    """Runs a stage median may use: no failed or covered run.

    A still is low-motion by design and a frozen run is still a measurement;
    the stage block is descriptive, so both stay (the table's own medians keep
    their stricter marks).
    """
    return [run for run in runs if not run.get("failed") and not run.get("covered")]


def stage_header(width=3):
    """The stage block's header: five stages and six interval levels."""
    parts = ["%-*s" % (width, "stage")]
    parts.extend(name.rjust(9) for name in STAGE_NAMES)
    parts.extend(field.rjust(12) for field in INTERVAL_FIELDS)
    return "  ".join(parts)


def stage_line(name, runs, width=3):
    """One arm's stage line: encoder, app, network, display, panel, intervals."""
    valid = stage_runs(runs)
    parts = ["%-*s" % (width, name)]
    for field in STAGE_FIELDS:
        parts.append(_stage_cell(_stage_values(valid, field)).rjust(9))
    for field in INTERVAL_FIELDS:
        parts.append(("%s=%s" % (field, _stage_cell(
            _stage_values(valid, field)))).rjust(12))
    return "  ".join(parts)


def _phone_cell(values, decimals):
    if not values:
        return "-"
    middle, low, high = statistics.median(values), min(values), max(values)
    pattern = "%%.%df (%%.%df-%%.%df)" % (decimals, decimals, decimals)
    return pattern % (middle, low, high)


def phone_line(name, runs, width=3):
    """One arm's phone-health line: battery, thermal, CPU, PSS and Wi-Fi."""
    valid = [run for run in runs
             if not run.get("failed") and not run.get("covered")]
    parts = []
    for label, field, unit, decimals in PHONE_COLUMNS:
        values = [run.get(field) for run in valid if run.get(field) is not None]
        cell = _phone_cell(values, decimals)
        parts.append("%s %s%s" % (label, cell, (" " + unit) if unit else ""))
    return "%-*s  %s" % (width, name, "  ".join(parts))



def resend_counts(rows):
    """X0's answer, over an arm's 5 s lines: (hitch with resends, hitch lines,
    clean with resends, clean lines, no phone message). A hitch line has
    `hitch_n >= 1`; a clean line has `hitch_n = 0` and moving content
    (`rx_fps >= 20`). A line "with resends" has `ph_retrans >= 1` or
    `tcp_ooo_kb > 0`. A line that folded in no phone message is left out of
    both and counted instead."""
    hitch_with = hitch_total = clean_with = clean_total = no_phone = 0
    for row in rows:
        if int(number(row, "phone_n") or 0) < 1:
            no_phone += 1
            continue
        resends = (number(row, "ph_retrans") or 0) >= 1 or (number(row, "tcp_ooo_kb") or 0) > 0
        if (number(row, "hitch_n") or 0) >= 1:
            hitch_total += 1
            if resends:
                hitch_with += 1
        elif (number(row, "rx_fps") or 0) >= 20:
            clean_total += 1
            if resends:
                clean_with += 1
    return hitch_with, hitch_total, clean_with, clean_total, no_phone


def resend_line(name, rows, width=3):
    """One arm's X0 block: the two rates side by side decide whether TCP is in
    the hitches."""
    hitch_with, hitch_total, clean_with, clean_total, no_phone = resend_counts(rows)
    return ("%-*s  hitch lines with resends %d/%d  clean lines with resends %d/%d"
            "  no phone message: %d"
            % (width, name, hitch_with, hitch_total, clean_with, clean_total, no_phone))


SWIPE_UP = {"x1": 0.5, "y1": 0.78, "x2": 0.5, "y2": 0.22}
SWIPE_DOWN = {"x1": 0.5, "y1": 0.22, "x2": 0.5, "y2": 0.78}


def drive(mcp, window, phases, sleep=time.sleep):
    """The swipe script, through the app's own MCP `swipe` tool.

    Every swipe alternates direction in both the steady and the fling phase,
    so the list cannot park at one end and become a still picture.
    """
    phases.append(("swipes", time.time()))
    for index in range(10):
        swipe = SWIPE_UP if index % 2 == 0 else SWIPE_DOWN
        mcp.text("swipe", {"window": window, "ms": 400, **swipe})
        sleep(0.25)
    phases.append(("still", time.time()))
    log("still 3 s")
    sleep(3)
    phases.append(("flings", time.time()))
    for index in range(10):
        swipe = SWIPE_UP if index % 2 == 0 else SWIPE_DOWN
        mcp.text("swipe", {"window": window, "ms": 150, **swipe})
        sleep(0.15)
    phases.append(("settle", time.time()))
    log("still 3 s")
    sleep(3)


def drive_still(mcp, window, phases, sleep=time.sleep, seconds=STILL_SECONDS):
    """The baseline: no input, straight to the app's own first-frame line."""
    phases.append(("still", time.time()))
    log("still %g s" % seconds)
    sleep(seconds)


def drive_typing(mcp, window, phases, sleep=time.sleep, point=None, text=TYPING_TEXT):
    """Tap the opened app's search field and type: key input without a swipe."""
    point = point or TYPING_POINT
    phases.append(("typing", time.time()))
    mcp.text("tap", {"window": window, **point})
    mcp.text("type_text", {"window": window, "text": text})
    sleep(3)


def drive_video(mcp, window, phases, sleep=time.sleep, point=None, seconds=VIDEO_SECONDS):
    """Open `--package`, tap its play point and watch the decoder, not a list."""
    point = point or PLAY_POINT
    phases.append(("video", time.time()))
    mcp.text("tap", {"window": window, **point})
    log("video %g s" % seconds)
    sleep(seconds)


def drive_tap(mcp, window, phases, point=None):
    """One tap through the Mac's `input_probe`; returns its photon number.

    The probe is the lead's new Mac tool. A build without it raises here and
    the run is marked `failed`; the table and the CSV still get written.
    """
    point = point or TAP_POINT
    phases.append(("tap", time.time()))
    try:
        reply = mcp.text("input_probe", {"window": window, **point})
    except Exception as error:  # a missing tool must mark the run, not crash it
        raise BenchFailure("no input_probe tool (%s)" % error)
    if not isinstance(reply, dict) or not reply.get("ok"):
        raise BenchFailure("no input_probe tool (bad reply %r)" % (reply,))
    return {
        "input_photon_ms": number(reply, "changed_ms"),
        "input_frames": number(reply, "frames"),
    }


def drive_soak(mcp, window, phases, sleep=time.sleep, seconds=SOAK_SECONDS,
               sample_seconds=SAMPLE_SECONDS, sample=None):
    """Keep the list moving and call `sample(step)` once per sample period.

    The caller resets its counters and writes one sample row in the callback;
    a final short period still produces one sample, so the ring's length is
    `ceil(seconds / sample_seconds)`.
    """
    phases.append(("soak", time.time()))
    remaining = float(seconds)
    index = 0
    while remaining > 0:
        step = min(float(sample_seconds), remaining)
        swipe = SWIPE_UP if index % 2 == 0 else SWIPE_DOWN
        mcp.text("swipe", {"window": window,
                           "ms": min(400, max(1, int(step * 1000))), **swipe})
        sleep(step)
        remaining -= step
        index += 1
        if sample is not None:
            sample(step)
    phases.append(("soak-done", time.time()))


def run_script(name, mcp, window, phases, args, sleep=time.sleep, sample=None):
    """Run one named script. `swipe` is today's drive() with no extra call."""
    if name == "swipe":
        drive(mcp, window, phases, sleep=sleep)
    elif name == "still":
        drive_still(mcp, window, phases, sleep=sleep, seconds=args.still_seconds)
    elif name == "typing":
        drive_typing(mcp, window, phases, sleep=sleep, point=args.typing_point)
    elif name == "video":
        drive_video(mcp, window, phases, sleep=sleep,
                    point=args.video_point, seconds=args.video_seconds)
    elif name == "soak":
        drive_soak(mcp, window, phases, sleep=sleep, seconds=args.soak_seconds,
                   sample_seconds=args.sample_seconds, sample=sample)
    elif name == "tap":
        return drive_tap(mcp, window, phases, point=args.tap_point)
    else:
        raise BenchFailure("unknown script %s" % name)
    return None


def parse_point(text):
    """`0.5,0.5` → normalized point; a person's typo is a usage error."""
    parts = text.split(",")
    if len(parts) != 2:
        fail("point must be x,y: %r" % text)
    try:
        return {"x": float(parts[0]), "y": float(parts[1])}
    except ValueError:
        fail("point must be x,y: %r" % text)


def app_line_values(logtext, stream):
    """The app's own first-frame and resize milliseconds for this stream."""
    return {
        "first_frame_ms": phone.first_frame_ms(logtext, stream),
        "resize_ms": phone.resize_ack_ms(logtext, stream),
    }


def phone_values(texts, seconds, package, display_id=None):
    """Map one set of read-only dumps into the run's phone cells."""
    gfx = texts.get("gfxinfo", "")
    frames = phone.framestats(gfx, seconds)
    summary = phone.gfxinfo_summary(gfx)
    display = phone.display_refresh(texts.get("display", ""), display_id) or {}
    battery = phone.battery(texts.get("battery", "")) or {}
    thermal = phone.thermal(texts.get("thermal", "")) or {}
    cpu = phone.cpu(texts.get("cpu", ""), (package, "app.contigua"))
    wifi_values = phone.wifi(texts.get("wifi", "")) or {}
    return {
        "app_fps": frames["fps"] if gfx.strip() else None,
        "app_jank_pct": summary["janky_pct"],
        "vd_hz": display.get("hz"),
        "battery_level": battery.get("level"),
        "battery_temp_c": battery.get("temp_c"),
        "thermal_status": thermal.get("status"),
        "thermal_max_c": thermal.get("max_c"),
        "app_cpu_pct": cpu.get(package),
        "shell_cpu_pct": cpu.get("app.contigua"),
        "app_pss_kb": phone.meminfo(texts.get("app_mem", "")),
        "shell_pss_kb": phone.meminfo(texts.get("shell_mem", "")),
        "wifi_rssi_dbm": wifi_values.get("rssi_dbm"),
        "wifi_mbps": wifi_values.get("mbps"),
        "wifi_mhz": wifi_values.get("mhz"),
        "wifi_retries": wifi_values.get("retries"),
        "wifi_bad": wifi_values.get("bad"),
    }


class PhoneSampler:
    """The read-only phone sampling every run records.

    `reset` clears gfxinfo before the script, `sample` reads the dumps after
    it. Nothing here writes the phone: no setprop, settings, cmd, input or
    screenshot call is made.
    """

    def __init__(self, adb_path, serial, package, display_id=None, shell=None):
        self.adb_path = adb_path
        self.serial = serial
        self.package = package
        self.display_id = display_id
        self._shell = shell or self._adb_shell

    def _adb_shell(self, *args):
        result = adb(self.adb_path, self.serial, "shell", *args, check=False)
        return result.stdout or ""

    def reset(self):
        self._shell("dumpsys", "gfxinfo", self.package, "reset")

    def sample(self, seconds):
        texts = {
            "gfxinfo": self._shell("dumpsys", "gfxinfo", self.package, "framestats"),
            "display": self._shell("dumpsys", "display"),
            "battery": self._shell("dumpsys", "battery"),
            "thermal": self._shell("dumpsys", "thermalservice"),
            "cpu": self._shell("dumpsys", "cpuinfo"),
            "app_mem": self._shell("dumpsys", "meminfo", self.package),
            "shell_mem": self._shell("dumpsys", "meminfo", "app.contigua"),
            "wifi": self._shell("dumpsys", "wifi"),
        }
        return phone_values(texts, seconds, self.package, self.display_id)


def activate_app(path, run=subprocess.run):
    """Bring the app at `path` to the front.

    The phone pauses a stream whose Mac window is hidden (the encoder keeps
    running, nothing goes out), so a run on a window behind another app
    measures a still picture. Best effort: a run without it shows up as
    `low_motion`/`frozen`, never as a fake number.
    """
    try:
        run(["open", "-a", path], check=False, timeout=10)
    except Exception:
        pass


def median_fields(rows, fields):
    """Per field, the median over the rows that measured it (else None)."""
    values = {}
    for field in fields:
        measured = [row[field] for row in rows if row.get(field) is not None]
        values[field] = statistics.median(measured) if measured else None
    return values


def main():
    parser = argparse.ArgumentParser(description="Contigua stream bench (ISS-40).")
    parser.add_argument("--profile", required=True,
                        help="Mac profile whose automation socket to drive "
                             "(default is the person's own app)")
    parser.add_argument("--serial", required=True, help="adb serial of the phone under test")
    parser.add_argument("--out", required=True, help="CSV of every run")
    parser.add_argument("--repeats", type=int, default=3, help="runs per arm, interleaved")
    parser.add_argument("--arms", default=os.path.join(os.path.dirname(__file__), "arms.json"))
    parser.add_argument("--arms-filter", default=None,
                        help="run only the arms whose name starts with this prefix "
                             "(e.g. stall)")
    parser.add_argument("--package", default="com.android.settings",
                        help="app to open for a run (default: Settings)")
    parser.add_argument("--script", choices=SCRIPTS, default=DEFAULT_SCRIPT,
                        help="run script (default: swipe, today's sequence)")
    parser.add_argument("--still-seconds", type=float, default=STILL_SECONDS,
                        help="the still script's hold (default: %(default)s)")
    parser.add_argument("--typing-point", default="0.5,0.08",
                        help="typing script's normalized search-field point "
                             "(default: 0.5,0.08)")
    parser.add_argument("--video-point", default="0.5,0.5",
                        help="video script's normalized play point (default: 0.5,0.5)")
    parser.add_argument("--video-seconds", type=float, default=VIDEO_SECONDS,
                        help="video script's play hold (default: %(default)s)")
    parser.add_argument("--soak-minutes", type=float, default=SOAK_SECONDS / 60.0,
                        help="soak script's length in minutes (default: %(default)s)")
    parser.add_argument("--sample-seconds", type=float, default=SAMPLE_SECONDS,
                        help="soak sample period in seconds (default: %(default)s)")
    parser.add_argument("--tap-point", default="0.5,0.5",
                        help="tap script's normalized probe point (default: 0.5,0.5)")
    parser.add_argument("--display-id", type=int, default=None,
                        help="physical display id; default reads the mirror's "
                             "contigua virtual display")
    parser.add_argument("--shim", default=DEFAULT_SHIM,
                        help="contigua-mcp stdio shim (default: the installed app's)")
    parser.add_argument("--app", default=None,
                        help="app bundle to bring to the front after opening a window "
                             "(a hidden stream pauses); e.g. a profile build's .app")
    parser.add_argument("--adb", default="adb", help="adb binary (default: adb)")
    parser.add_argument("--include-restart-arms", action="store_true",
                        help="also run arms marked restart (they need the app restarted "
                             "between runs; N1's Mac side is read at dial time)")
    parser.add_argument("--first-line-timeout", type=float, default=30.0)
    parser.add_argument("--dry-run", action="store_true",
                        help="read and filter the arms, print the plan and exit; "
                             "no adb, no Mac app, no log")
    args = parser.parse_args()
    if args.repeats < 1:
        fail("--repeats must be at least 1")
    if args.sample_seconds <= 0:
        fail("--sample-seconds must be positive")
    if args.soak_minutes <= 0:
        fail("--soak-minutes must be positive")
    if args.still_seconds < 0 or args.video_seconds < 0:
        fail("script holds must not be negative")
    args.typing_point = parse_point(args.typing_point)
    args.video_point = parse_point(args.video_point)
    args.tap_point = parse_point(args.tap_point)
    args.soak_seconds = args.soak_minutes * 60.0

    arms = read_arms(args.arms)
    run_arms = selected_arms(arms, args.include_restart_arms, args.arms_filter)
    if not run_arms:
        fail("%s lists no arms for this run" % args.arms)
    if args.dry_run:
        print("dry-run: script=%s %d arm(s) x %d repeat(s): %s"
              % (args.script, len(run_arms), args.repeats,
                 ", ".join(arm["name"] for arm in run_arms)))
        return 0

    require_device(args.adb, args.serial)
    skipped = [arm["name"] for arm in arms if arm not in run_arms]
    if skipped:
        log("skipping arms (restart arms need the app restarted; "
            "--arms-filter narrows the list): " + ", ".join(skipped))
    if not os.path.exists(args.shim):
        fail("no shim at %s" % args.shim)
    domain = profile_domain(args.profile)
    pid = find_app_pid(args.profile)
    if pid is None:
        fail("no Contigua app is running the profile %r" % args.profile)
    predicate = log_predicate(pid)
    if has_open_window(recent_lines(predicate, 10)):
        fail("another window is open")
    MCP = load_mcp()
    settings = ArmSettings(args.adb, args.serial, domain)
    sampler = PhoneSampler(args.adb, args.serial, args.package, args.display_id)

    rows = []
    all_samples = []
    summary_rows = {arm["name"]: [] for arm in run_arms}
    try:
        for repeat in range(args.repeats):
            for arm in run_arms:
                name = arm["name"]
                log("run %d/%d arm=%s script=%s"
                    % (repeat + 1, args.repeats, name, args.script))
                began = time.strftime("%Y-%m-%d %H:%M:%S")
                run = {"repeat": repeat + 1, "arm": name, "stream": 0,
                       "start": began, "end": "", "lines": 0, "sampled": [],
                       "script": args.script, "samples": []}
                run.update({field: None for field in
                            list(table_fields()) + list(NEW_RUN_FIELDS)})
                client = None
                try:
                    settings.apply(arm)
                    sampler.reset()
                    reset_at = time.time()
                    client = MCP(args.shim, args.profile)
                    opened = client.text("open_app", {"app": args.package})
                    stream = int(opened["window"])
                    run["stream"] = stream
                    if args.app:
                        activate_app(args.app)
                    if not wait_for_first_line(stream, began, predicate,
                                               args.first_line_timeout):
                        raise BenchFailure("no stats line for stream %d" % stream)
                    phases = []
                    probe = None
                    soak_samples = []
                    if args.script == "soak":
                        def on_sample(step):
                            values = sampler.sample(step)
                            values.update({"at": time.strftime("%Y-%m-%d %H:%M:%S"),
                                           "repeat": repeat + 1, "arm": name,
                                           "sample_seconds": step})
                            soak_samples.append(values)
                            sampler.reset()
                        run_script(args.script, client, stream, phases, args,
                                   sample=on_sample)
                    else:
                        probe = run_script(args.script, client, stream, phases, args)
                        # While the app is still alive and its window open:
                        # gfxinfo/meminfo describe the run, not the close.
                        run.update(sampler.sample(time.time() - reset_at))
                    client.text("close_window", {"window": stream})
                    client.close()
                    client = None
                    run["end"] = time.strftime("%Y-%m-%d %H:%M:%S")
                    total = wait_for_totals(stream, began, predicate,
                                            args.first_line_timeout)
                    if total is None:
                        raise BenchFailure("no totals line for stream %d" % stream)
                    logtext = stats_lines(began, predicate)
                    sampled = parse_rows(logtext, stream)
                    run["lines"] = len(sampled)
                    run["sampled"] = sampled
                    run.update(run_metrics(total, sampled, phases))
                    run.update(app_line_values(logtext, stream))
                    if probe:
                        run.update(probe)
                    if args.script == "soak":
                        run["samples"] = soak_samples
                        all_samples.extend(soak_samples)
                        run.update(median_fields(soak_samples, PHONE_FIELDS))
                except Exception as error:  # one failed run never stops the table
                    log("run failed: %s" % error)
                    run.update(empty_metrics())
                finally:
                    if client is not None:
                        client.close()
                    settings.restore()
                run["script"] = args.script
                for key in ("frozen", "low_motion", "no_drop_ms", "phone_gaps",
                            "covered", "failed"):
                    run[key] = 1 if run.get(key) else 0
                rows.append(run)
                summary_rows[name].append(run)
                log("run done: codec=%s " % (run.get("codec") or "-")
                    + " ".join("%s=%s" % (field, run.get(field))
                               for field in table_fields()))
    finally:
        settings.restore()

    fieldnames = CSV_FIELDS
    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    samples_path = args.out + ".samples.csv"
    if all_samples:
        with open(samples_path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=SAMPLE_FIELDS,
                                    extrasaction="ignore")
            writer.writeheader()
            writer.writerows(all_samples)

    # One row per arm: median of the runs that count and their min–max.
    text_rows = [table_line(arm["name"], summary_rows[arm["name"]]) for arm in run_arms]
    width = max([len(row.split("  ", 1)[0]) for row in text_rows] + [3])
    print()
    print(table_header(width))
    for arm, row in zip(run_arms, text_rows):
        label, cells = row.split("  ", 1)
        print("%-*s  %s" % (width, label.strip(), cells))
    print()
    print("resends (X0): does a resend line up with a hitch?")
    for arm in run_arms:
        rows = [row for run in summary_rows[arm["name"]]
                for row in run.get("sampled", [])]
        print(resend_line(arm["name"], rows, width))
    print()
    print("phone:")
    for arm in run_arms:
        print(phone_line(arm["name"], summary_rows[arm["name"]], width))
    print()
    print("stages:")
    print(stage_header(width))
    for arm in run_arms:
        print(stage_line(arm["name"], summary_rows[arm["name"]], width))
    print()
    print("CSV: %s" % args.out)
    if all_samples:
        print("samples CSV: %s" % samples_path)
    return 0


def wait_for_first_line(stream, began, predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if parse_rows(stats_lines(began, predicate), stream):
            return True
        time.sleep(0.5)
    return False


if __name__ == "__main__":
    sys.exit(main())
