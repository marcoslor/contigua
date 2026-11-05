#!/usr/bin/env python3
"""Stream bench (ISS-40): repeat a fixed swipe script against one Mac app and
summarise the per-window `stats …` lines each run wrote.

The app must already be running with its automation socket on (Settings ›
Automation, or the e2e bundle's `--mcp-enable`); this script only drives it
through the same stdio shim `mcp-driver.py` uses. It never launches, quits or
changes the Mac app.

    tools/stream-bench/bench.py --profile default --serial R58M1234 \
        --repeats 3 --out .agent/stats/bench.csv

Arms are named in arms.json: phone properties (`debug.pocketdeck.stream.*` via
`adb -s <serial> shell setprop`) and Mac defaults (`defaults write <domain>`)
are set before a run and restored after it. An arm with `"restart": true` is
left out of the default run: its key is read when the app dials, and the bench
never relaunches or reconnects the app (`--include-restart-arms` overrides).

The phone is addressed only through the given serial; the script refuses an
unreachable one and never runs `adb kill-server`. Nothing is changed on the
phone except the named `debug.pocketdeck.stream.*` properties, and those are
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
DEFAULT_SHIM = "/Applications/PocketDeck.app/Contents/Helpers/pocketdeck-mcp"
PROFILE_DOMAIN = "dev.pocketdeck.mac"
STATS_PREFIX = "debug.pocketdeck.stream."

# One row per arm; each cell is median (min–max) across the arm's runs.
# jank_* lead: what a person feels while the phone's content moves is a hitch
# on the Mac, a drop gap on the phone, or a suspend (Q1).
TABLE_FIELDS = ("jank_ms", "jank_n", "hitch_ms", "drop_ms", "susp_ms",
                "late_p99", "shown_fps", "kf", "kbps", "qp_p95", "e2e_p50",
                "e2e_p95")
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)([+-]\d{4})")


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
    """The app's own lines only: another PocketDeck process must never mix in.
    The pid comes from the profile's process, never from the subsystem alone."""
    return 'subsystem == "%s" AND processID == %d' % (PROFILE_DOMAIN, pid)


def profile_app_pid(ps_text, profile):
    """The pid of the app running this profile: the command starts with the
    bundle's `Contents/MacOS/PocketDeck` and carries `--profile <profile>`.
    A Dock shim or another profile's app never matches."""
    marker = re.compile(r"--profile\s+%s(?:\s|$)" % re.escape(profile))
    for line in ps_text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        command = parts[1].strip()
        if not command:
            continue
        executable = command.split()[0]
        if not executable.endswith("/Contents/MacOS/PocketDeck"):
            continue
        if marker.search(command):
            return int(parts[0])
    return None


def find_app_pid(profile):
    result = subprocess.run(["ps", "-axww", "-o", "pid=,command="],
                            capture_output=True, text=True)
    return profile_app_pid(result.stdout or "", profile)


def has_open_window(text):
    """True when a 5 s `stats stream=` line is in the given log text. The
    closing `stats total stream=` line is not a live window."""
    return any(" stats stream=" in line for line in text.splitlines())


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


def run_metrics(total, sampled=()):
    """A run's table values plus its marks, all from the closing totals line.

    The totals carry no phases: `shown_fps`, `late_p99` and both e2e levels are
    over the run's whole life. `kbps` is the phone's bytes over `secs`; a run
    whose `rx_frames / secs` is under 20 moved too little to compare strategies.
    A run with `covered_ms > 0` spent time hidden and is left out of the medians.
    `qp_p95` is a level, not a counter, and the totals line has none: it is the
    median over the 5 s lines that folded in a phone message.
    """
    secs = number(total, "secs") or 0.0
    covered_ms = number(total, "covered_ms") or 0.0
    active = max(0.0, secs - covered_ms / 1000.0)
    rx = number(total, "rx_frames") or 0
    shown = number(total, "shown_frames") or 0
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
        "kbps": phone_bytes * 8 / (secs * 1000) if secs > 0 else None,
        "qp_p95": median(qp),
        "e2e_p50": number(total, "e2e_p50"),
        "e2e_p95": number(total, "e2e_p95"),
        "low_motion": (rx / secs) < 20 if secs > 0 else True,
        "no_drop_ms": total.get("drop_ms") in (None, "-"),
        "phone_gaps": phone_n <= 0,
        "covered": covered_ms > 0,
        "failed": 0,
        "secs": secs,
        "rx_frames": rx,
        "shown_frames": shown,
        "phone_frames": number(total, "phone_frames"),
        "kf_req": number(total, "kf_req"),
        "bytes": phone_bytes,
        "covered_ms": covered_ms,
    }


def empty_metrics():
    """A failed run's cells: every number absent, its marks set."""
    values = {field: None for field in TABLE_FIELDS}
    values.update({"low_motion": 0, "no_drop_ms": 0, "phone_gaps": 0,
                   "covered": 0, "failed": 1, "secs": None, "rx_frames": None,
                   "shown_frames": None, "phone_frames": None, "kf_req": None,
                   "bytes": None, "covered_ms": None})
    return values


def summarise(runs):
    """One cell per table field: the median and min–max of the runs that count.
    Failed and covered runs are excluded; no valid run leaves the cell `-`."""
    valid = [run for run in runs
             if not run.get("failed") and not run.get("covered")]
    cells = {}
    for field in TABLE_FIELDS:
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
    if any(run.get("low_motion") for run in runs):
        marks.append("low-motion")
    if any(run.get("no_drop_ms") for run in runs):
        marks.append("no drop_ms")
    if any(run.get("phone_gaps") for run in runs):
        marks.append("phone gaps")
    label = name + (" (%s)" % ", ".join(marks) if marks else "")
    cells = summarise(runs)
    rendered = []
    for field in TABLE_FIELDS:
        cell = cells[field]
        if cell is None:
            rendered.append("-".rjust(10))
        else:
            middle, low, high = cell
            rendered.append(("%.1f (%.1f-%.1f)" % (middle, low, high)).rjust(10))
    return "%-*s  %s" % (width, label, "  ".join(rendered))


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


class BenchFailure(Exception):
    """One run failed: the bench marks it and goes on."""


def main():
    parser = argparse.ArgumentParser(description="PocketDeck stream bench (ISS-40).")
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
    parser.add_argument("--shim", default=DEFAULT_SHIM,
                        help="pocketdeck-mcp stdio shim (default: the installed app's)")
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

    arms = read_arms(args.arms)
    run_arms = selected_arms(arms, args.include_restart_arms, args.arms_filter)
    if not run_arms:
        fail("%s lists no arms for this run" % args.arms)
    if args.dry_run:
        print("dry-run: %d arm(s) x %d repeat(s): %s"
              % (len(run_arms), args.repeats, ", ".join(arm["name"] for arm in run_arms)))
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
        fail("no PocketDeck app is running the profile %r" % args.profile)
    predicate = log_predicate(pid)
    if has_open_window(recent_lines(predicate, 10)):
        fail("another window is open")
    MCP = load_mcp()
    settings = ArmSettings(args.adb, args.serial, domain)

    rows = []
    summary_rows = {arm["name"]: [] for arm in run_arms}
    try:
        for repeat in range(args.repeats):
            for arm in run_arms:
                name = arm["name"]
                log("run %d/%d arm=%s" % (repeat + 1, args.repeats, name))
                began = time.strftime("%Y-%m-%d %H:%M:%S")
                run = {"repeat": repeat + 1, "arm": name, "stream": 0,
                       "start": began, "end": "", "lines": 0}
                client = None
                try:
                    settings.apply(arm)
                    client = MCP(args.shim, args.profile)
                    opened = client.text("open_app", {"app": args.package})
                    stream = int(opened["window"])
                    run["stream"] = stream
                    if not wait_for_first_line(stream, began, predicate,
                                               args.first_line_timeout):
                        raise BenchFailure("no stats line for stream %d" % stream)
                    drive(client, stream, [])
                    client.text("close_window", {"window": stream})
                    client.close()
                    client = None
                    run["end"] = time.strftime("%Y-%m-%d %H:%M:%S")
                    total = wait_for_totals(stream, began, predicate,
                                            args.first_line_timeout)
                    if total is None:
                        raise BenchFailure("no totals line for stream %d" % stream)
                    sampled = parse_rows(stats_lines(began, predicate), stream)
                    run["lines"] = len(sampled)
                    run.update(run_metrics(total, sampled))
                except Exception as error:  # one failed run never stops the table
                    log("run failed: %s" % error)
                    run.update(empty_metrics())
                finally:
                    if client is not None:
                        client.close()
                    settings.restore()
                for key in ("low_motion", "no_drop_ms", "phone_gaps",
                            "covered", "failed"):
                    run[key] = 1 if run.get(key) else 0
                rows.append(run)
                summary_rows[name].append(run)
                log("run done: " + " ".join("%s=%s" % (field, run[field])
                                            for field in TABLE_FIELDS))
    finally:
        settings.restore()

    fieldnames = (["repeat", "arm", "stream", "start", "end", "lines",
                   "failed", "covered", "secs", "rx_frames", "shown_frames",
                   "phone_frames", "kf_req", "bytes", "covered_ms"]
                  + list(TABLE_FIELDS) + ["low_motion", "no_drop_ms", "phone_gaps"])
    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    # One row per arm: median of the runs that count and their min–max.
    text_rows = [table_line(arm["name"], summary_rows[arm["name"]]) for arm in run_arms]
    width = max([len(row.split("  ", 1)[0]) for row in text_rows] + [3])
    print()
    print("%-*s  %s" % (width, "arm", "  ".join(field.rjust(10) for field in TABLE_FIELDS)))
    for arm, row in zip(run_arms, text_rows):
        label, cells = row.split("  ", 1)
        print("%-*s  %s" % (width, label.strip(), cells))
    print()
    print("CSV: %s" % args.out)
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
