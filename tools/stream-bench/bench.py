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
are set before a run and restored after it. This release ships only the empty
`baseline` arm; an arm with a property no build reads is still a valid no-op.

The phone is addressed only through the given serial; the script refuses an
unreachable one and never runs `adb kill-server`. Nothing is changed on the
phone except the named `debug.pocketdeck.stream.*` properties, and those are
put back the way they were.
"""

import argparse
import csv
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MACOS = os.path.join(ROOT, "macos")
SUMMARY = os.path.join(MACOS, "scripts", "stats-summary.py")
DEFAULT_SHIM = "/Applications/PocketDeck.app/Contents/Helpers/pocketdeck-mcp"
PROFILE_DOMAIN = "dev.pocketdeck.mac"
STATS_PREFIX = "debug.pocketdeck.stream."

# One row per arm; each cell is median (min–max) across the arm's runs.
ARM_FIELDS = ("shown_fps", "int_p99", "freeze_n", "freeze_ms", "drop_ep",
              "qp_p95", "kbps", "e2e_p95")
# A run's value: counters total across its lines, everything else the median.
RUN_SUM = {"freeze_n", "freeze_ms", "drop_ep"}

PHASES = ("opening", "warming", "swipes", "still", "flings", "settle", "closing")


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
    adb(adb_path, serial, "shell", "setprop", STATS_PREFIX + key, str(value))


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


def parse_stats(text, stream):
    """The summary dict for one stream's lines, or None."""
    marker = " stats stream=%s " % stream
    rows = [line for line in text.splitlines() if marker in line + " "]
    if not rows:
        return None
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False,
                                     encoding="utf-8") as handle:
        handle.write("\n".join(rows) + "\n")
        path = handle.name
    try:
        result = run_command([sys.executable, SUMMARY, "--file", path, "--json"])
        data = json.loads(result.stdout)
        return data["streams"].get(str(stream))
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def wait_for_first_line(stream, began, predicate, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        summary = parse_stats(stats_lines(began, predicate), stream)
        if summary and summary["lines"] >= 1:
            return True
        time.sleep(0.5)
    return False


def read_run(stream, began, ended, predicate):
    """Wait for the log to settle, then summarise the run's own lines."""
    deadline = time.time() + 20
    last = 0
    stable_since = None
    summary = None
    while time.time() < deadline:
        summary = parse_stats(stats_lines(began, predicate), stream)
        count = summary["lines"] if summary else 0
        if count != last:
            last = count
            stable_since = time.time()
        elif count > 0 and stable_since and time.time() - stable_since >= 2:
            break
        time.sleep(1)
    if not summary or summary["lines"] == 0:
        return None
    return summary


def run_value(summary, field):
    values = summary["fields"].get(field)
    if not values or values["samples"] == 0:
        return None
    return values["sum"] if field in RUN_SUM else values["median"]


def drive(mcp, window):
    """The swipe script, through the app's own MCP `swipe` tool."""
    for index in range(10):
        mcp.text("swipe", {"window": window, "x1": 0.5, "y1": 0.78,
                           "x2": 0.5, "y2": 0.22, "ms": 400})
        time.sleep(0.25)
    log("still 3 s")
    time.sleep(3)
    for index in range(10):
        mcp.text("swipe", {"window": window, "x1": 0.5, "y1": 0.78,
                           "x2": 0.5, "y2": 0.22, "ms": 150})
        time.sleep(0.15)
    log("still 3 s")
    time.sleep(3)


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
    parser.add_argument("--first-line-timeout", type=float, default=30.0)
    args = parser.parse_args()
    if args.repeats < 1:
        fail("--repeats must be at least 1")

    require_device(args.adb, args.serial)
    arms = read_arms(args.arms)
    if not os.path.exists(args.shim):
        fail("no shim at %s" % args.shim)
    domain = PROFILE_DOMAIN if args.profile == "default" else "%s.%s" % (PROFILE_DOMAIN, args.profile)
    predicate = 'subsystem == "%s"' % PROFILE_DOMAIN
    MCP = load_mcp()
    settings = ArmSettings(args.adb, args.serial, domain)

    rows = []
    summary_rows = {arm["name"]: [] for arm in arms}
    try:
        for repeat in range(args.repeats):
            for arm in arms:
                name = arm["name"]
                log("run %d/%d arm=%s" % (repeat + 1, args.repeats, name))
                settings.apply(arm)
                began = time.strftime("%Y-%m-%d %H:%M:%S")
                mcp = MCP(args.shim, args.profile)
                try:
                    opened = mcp.text("open_app", {"app": args.package})
                    stream = int(opened["window"])
                    if not wait_for_first_line(stream, began, predicate, args.first_line_timeout):
                        fail("arm %s: no stats line for stream %d" % (name, stream))
                    drive(mcp, stream)
                    mcp.text("close_window", {"window": stream})
                finally:
                    mcp.close()
                ended = time.strftime("%Y-%m-%d %H:%M:%S")
                summary = read_run(stream, began, ended, predicate)
                if summary is None:
                    fail("arm %s: no stats lines after the run" % name)
                run = {"repeat": repeat + 1, "arm": name, "stream": stream,
                       "start": began, "end": ended, "lines": summary["lines"]}
                for field in ARM_FIELDS:
                    run[field] = run_value(summary, field)
                rows.append(run)
                summary_rows[name].append(run)
                settings.restore()
                log("run done: " + " ".join("%s=%s" % (field, run[field])
                                            for field in ARM_FIELDS))
    finally:
        settings.restore()

    with open(args.out, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["repeat", "arm", "stream", "start",
                                                    "end", "lines"] + list(ARM_FIELDS))
        writer.writeheader()
        writer.writerows(rows)

    # One row per arm: median of the runs and their min–max.
    width = max([len(arm["name"]) for arm in arms] + [3])
    print()
    print("%-*s  %s" % (width, "arm", "  ".join(field.rjust(10) for field in ARM_FIELDS)))
    for arm in arms:
        cells = []
        runs = summary_rows[arm["name"]]
        for field in ARM_FIELDS:
            values = [run[field] for run in runs if run[field] is not None]
            if not values:
                cells.append("-".rjust(10))
                continue
            median = statistics.median(values)
            low, high = min(values), max(values)
            cells.append(("%.1f (%.1f-%.1f)" % (median, low, high)).rjust(10))
        print("%-*s  %s" % (width, arm["name"], "  ".join(cells)))
    print()
    print("CSV: %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
