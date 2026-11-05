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
# A run's value: these counters total across its lines.
RUN_SUM = {"jank_ms", "jank_n", "hitch_ms", "drop_ms", "susp_ms", "kf"}
# These levels are read only while the script's swipes or flings move the list.
MOTION_PHASES = ("swipes", "flings")

PHASES = ("opening", "warming", "swipes", "still", "flings", "settle", "closing")
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)([+-]\d{4})")


def profile_domain(profile):
    """The defaults suite a run's Mac keys go to: the person's own domain for
    the default profile, else that profile's suffixed suite."""
    return PROFILE_DOMAIN if profile == "default" else "%s.%s" % (PROFILE_DOMAIN, profile)


def selected_arms(arms, include_restart=False):
    """The arms a run executes. An arm marked `restart` needs a fresh session
    for a key that is read at dial time (N1's Mac side); the default list leaves
    it out because the bench never quits or reconnects the app."""
    if include_restart:
        return list(arms)
    return [arm for arm in arms if not arm.get("restart", False)]


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


def parse_rows(text, stream):
    """One dict per `stats stream=<stream>` line, with its wall-clock time."""
    marker = " stats stream=%s " % stream
    rows = []
    for line in text.splitlines():
        if marker not in line + " ":
            continue
        match = STAMP.match(line.strip())
        if not match:
            continue
        try:
            at = datetime.datetime.strptime(
                match.group(1) + match.group(2),
                "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        except ValueError:
            continue
        fields = {"at": at}
        for word in line.split():
            if "=" not in word:
                continue
            key, value = word.split("=", 1)
            fields[key] = value
        rows.append(fields)
    return rows


def number(row, key):
    raw = row.get(key)
    if raw in (None, "-"):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def phase_at(at, phases):
    """The last phase whose start is at or before `at`."""
    current = phases[0][0] if phases else PHASES[0]
    for name, start in phases:
        if at >= start:
            current = name
        else:
            break
    return current


def read_run(stream, began, predicate):
    """Wait for the log to settle, then return the run's own lines."""
    deadline = time.time() + 20
    last = 0
    stable_since = None
    rows = []
    while time.time() < deadline:
        rows = parse_rows(stats_lines(began, predicate), stream)
        count = len(rows)
        if count != last:
            last = count
            stable_since = time.time()
        elif count > 0 and stable_since and time.time() - stable_since >= 2:
            break
        time.sleep(1)
    return rows


def median(values):
    return statistics.median(values) if values else None


def run_metrics(rows, phases):
    """One run's table values plus its low-motion, no-drop_ms and phone-gap marks.

    `jank_*` and the other counters total the whole run; shown_fps and
    late_p99 are levels of the lines while the script's swipes/flings move the
    list. A run where no motion line saw 30 fps moved nothing and cannot
    compare strategies. `kbps` and `qp_p95` are the phone's numbers, so only a
    line that folded in a `stream.stats` message carries them; a line after the
    first with `phone_n=0` marks the run `(phone gaps)`.
    """
    totals = {key: 0.0 for key in RUN_SUM}
    motion = {"shown_fps": [], "late_p99": []}
    mac_levels = {"e2e_p50": [], "e2e_p95": []}
    phone_kbps = []
    motion_qp = []
    no_drop_ms = False
    low_motion = True
    phone_gaps = False
    for index, row in enumerate(rows):
        phase = phase_at(row["at"], phases)
        row["phase"] = phase
        log("line %s phase=%s rx_fps=%s shown_fps=%s phone_n=%d" %
            (time.strftime("%H:%M:%S", time.localtime(row["at"])), phase,
             row.get("rx_fps", "-"), row.get("shown_fps", "-"),
             number(row, "phone_n") or 0))
        phone_n = number(row, "phone_n") or 0
        if index > 0 and phone_n <= 0:
            phone_gaps = True
        hitch_n = number(row, "hitch_n") or 0
        hitch_ms = number(row, "hitch_ms") or 0
        drop_ep = number(row, "drop_ep") or 0
        drop_ms = number(row, "drop_ms")
        if drop_ms is None:
            no_drop_ms = True
            drop_ms = 0
        susp_n = number(row, "susp_n") or 0
        susp_ms = number(row, "susp_ms") or 0
        totals["hitch_ms"] += hitch_ms
        totals["drop_ms"] += drop_ms
        totals["susp_ms"] += susp_ms
        totals["jank_ms"] += hitch_ms + drop_ms + susp_ms
        totals["jank_n"] += hitch_n + drop_ep + susp_n
        totals["kf"] += number(row, "kf") or 0
        if phase in MOTION_PHASES:
            if (number(row, "rx_fps") or 0) >= 30:
                low_motion = False
            for key in motion:
                value = number(row, key)
                if value is not None:
                    motion[key].append(value)
            # A still screen encodes at QP ~1, which is no quality signal.
            if phone_n >= 1:
                value = number(row, "qp_p95")
                if value is not None:
                    motion_qp.append(value)
        if phone_n >= 1:
            value = number(row, "kbps")
            if value is not None:
                phone_kbps.append(value)
        for key in mac_levels:
            value = number(row, key)
            if value is not None:
                mac_levels[key].append(value)
    values = dict(totals)
    for key, samples in motion.items():
        values[key] = median(samples)
    for key, samples in mac_levels.items():
        values[key] = median(samples)
    values["kbps"] = median(phone_kbps)
    values["qp_p95"] = median(motion_qp)
    values["low_motion"] = low_motion
    values["phone_gaps"] = phone_gaps
    values["no_drop_ms"] = no_drop_ms
    return values


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


def main():
    parser = argparse.ArgumentParser(description="PocketDeck stream bench (ISS-40).")
    parser.add_argument("--profile", required=True,
                        help="Mac profile whose automation socket to drive "
                             "(default is the person's own app)")
    parser.add_argument("--serial", required=True, help="adb serial of the phone under test")
    parser.add_argument("--out", required=True, help="CSV of every run")
    parser.add_argument("--repeats", type=int, default=3, help="runs per arm, interleaved")
    parser.add_argument("--arms", default=os.path.join(os.path.dirname(__file__), "arms.json"))
    parser.add_argument("--package", default="com.android.settings",
                        help="app to open for a run (default: Settings)")
    parser.add_argument("--shim", default=DEFAULT_SHIM,
                        help="pocketdeck-mcp stdio shim (default: the installed app's)")
    parser.add_argument("--adb", default="adb", help="adb binary (default: adb)")
    parser.add_argument("--include-restart-arms", action="store_true",
                        help="also run arms marked restart (they need the app restarted "
                             "between runs; N1's Mac side is read at dial time)")
    parser.add_argument("--first-line-timeout", type=float, default=30.0)
    args = parser.parse_args()
    if args.repeats < 1:
        fail("--repeats must be at least 1")

    require_device(args.adb, args.serial)
    arms = read_arms(args.arms)
    run_arms = selected_arms(arms, args.include_restart_arms)
    if not run_arms:
        fail("%s lists no arms for this run" % args.arms)
    skipped = [arm["name"] for arm in arms if arm not in run_arms]
    if skipped:
        log("skipping restart arms (restart the app between them; "
            "--include-restart-arms runs them anyway): " + ", ".join(skipped))
    if not os.path.exists(args.shim):
        fail("no shim at %s" % args.shim)
    domain = profile_domain(args.profile)
    predicate = 'subsystem == "%s"' % PROFILE_DOMAIN
    MCP = load_mcp()
    settings = ArmSettings(args.adb, args.serial, domain)

    rows = []
    summary_rows = {arm["name"]: [] for arm in run_arms}
    try:
        for repeat in range(args.repeats):
            for arm in run_arms:
                name = arm["name"]
                log("run %d/%d arm=%s" % (repeat + 1, args.repeats, name))
                settings.apply(arm)
                began = time.strftime("%Y-%m-%d %H:%M:%S")
                phases = [("opening", time.time())]
                mcp = MCP(args.shim, args.profile)
                try:
                    opened = mcp.text("open_app", {"app": args.package})
                    stream = int(opened["window"])
                    if not wait_for_first_line(stream, began, predicate, args.first_line_timeout):
                        fail("arm %s: no stats line for stream %d" % (name, stream))
                    phases.append(("warming", time.time()))
                    drive(mcp, stream, phases)
                    mcp.text("close_window", {"window": stream})
                    phases.append(("closing", time.time()))
                finally:
                    mcp.close()
                ended = time.strftime("%Y-%m-%d %H:%M:%S")
                run_rows = read_run(stream, began, predicate)
                if not run_rows:
                    fail("arm %s: no stats lines after the run" % name)
                run = {"repeat": repeat + 1, "arm": name, "stream": stream,
                       "start": began, "end": ended, "lines": len(run_rows)}
                run.update(run_metrics(run_rows, phases))
                run["low_motion"] = 1 if run["low_motion"] else 0
                run["no_drop_ms"] = 1 if run["no_drop_ms"] else 0
                run["phone_gaps"] = 1 if run["phone_gaps"] else 0
                rows.append(run)
                summary_rows[name].append(run)
                settings.restore()
                log("run done: " + " ".join("%s=%s" % (field, run[field])
                                            for field in TABLE_FIELDS))
    finally:
        settings.restore()

    fieldnames = (["repeat", "arm", "stream", "start", "end", "lines"]
                  + list(TABLE_FIELDS) + ["low_motion", "no_drop_ms", "phone_gaps"])
    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    # One row per arm: median of the runs and their min–max.
    labels = {}
    for arm in run_arms:
        name = arm["name"]
        marks = []
        if any(run["low_motion"] for run in summary_rows[name]):
            marks.append("low-motion")
        if any(run["no_drop_ms"] for run in summary_rows[name]):
            marks.append("no drop_ms")
        if any(run["phone_gaps"] for run in summary_rows[name]):
            marks.append("phone gaps")
        labels[name] = name + (" (%s)" % ", ".join(marks) if marks else "")
    width = max([len(label) for label in labels.values()] + [3])
    print()
    print("%-*s  %s" % (width, "arm", "  ".join(field.rjust(10) for field in TABLE_FIELDS)))
    for arm in run_arms:
        cells = []
        runs = summary_rows[arm["name"]]
        for field in TABLE_FIELDS:
            values = [run[field] for run in runs if run[field] is not None]
            if not values:
                cells.append("-".rjust(10))
                continue
            middle = statistics.median(values)
            low, high = min(values), max(values)
            cells.append(("%.1f (%.1f-%.1f)" % (middle, low, high)).rjust(10))
        print("%-*s  %s" % (width, labels[arm["name"]], "  ".join(cells)))
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
