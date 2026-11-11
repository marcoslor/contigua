#!/usr/bin/env python3
"""Summarise the Mac's `stats stream=…` lines (ISS-40).

Reads `/usr/bin/log show` output for a time range, or a saved file, and prints
one block per stream: the median and maximum of every numeric field, and the
sum for the counters that accumulate across lines (`freeze_n`, `hitch_n`,
`hitch_ms`, `drop_ep`, `drop_ms`, `phone_n`, `kf`, `key_not_idr`,
`ph_key_not_idr`, `susp_n`, `susp_ms`, `refine_n`). `--json` is the machine
form the stream bench reads.

    macos/scripts/stats-summary.py --last 10m
    macos/scripts/stats-summary.py --start "2026-11-05 10:00:00" \
        --end "2026-11-05 10:05:00" --file "$WORK/app.log"
    macos/scripts/stats-summary.py --file saved.log --json

No third-party packages. Values of `-` (no measurement) are not samples.
"""

import argparse
import json
import re
import statistics
import subprocess
import sys

FIELD = re.compile(r"^(stats|[a-z0-9_]+)=([^\s]+)$")
CLOCK_FIELDS = ("freeze_n", "hitch_n", "hitch_ms", "drop_ep", "drop_ms",
                "phone_n", "kf", "key_not_idr", "ph_key_not_idr",
                "susp_n", "susp_ms", "refine_n")
SUBSYSTEM = "app.contigua.mac"


def parse_lines(text):
    """{(stream: str): [ {field: value-or-None}, ... ]} in file order."""
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if " stats stream=" not in line:
            continue
        fields = {}
        for word in line.split():
            match = FIELD.match(word)
            if not match:
                continue
            key, raw = match.groups()
            if key == "stats":
                continue
            fields[key] = None if raw == "-" else raw
        stream = fields.pop("stream", None)
        if stream is None:
            continue
        out.setdefault(stream, []).append(fields)
    return out


def numeric(fields, key):
    raw = fields.get(key)
    if raw is None:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def summarise(rows):
    keys = []
    for row in rows:
        for key in row:
            if key not in keys:
                keys.append(key)
    fields = {}
    for key in keys:
        values = [value for value in (numeric(row, key) for row in rows) if value is not None]
        if not values:
            fields[key] = {"samples": 0, "median": None, "max": None, "sum": None}
            continue
        fields[key] = {
            "samples": len(values),
            "median": round(statistics.median(values), 3),
            "max": round(max(values), 3),
            "sum": round(sum(values), 3),
        }
    return {"lines": len(rows), "fields": fields}


def read_range(start, end, predicate):
    if not start or not end:
        raise SystemExit("stats-summary: give --file, or both --start and --end")
    args = [
        "/usr/bin/log", "show",
        "--start", start, "--end", end,
        "--info", "--style", "syslog",
        "--predicate", predicate or 'subsystem == "%s"' % SUBSYSTEM,
    ]
    try:
        return subprocess.run(args, capture_output=True, text=True, check=False).stdout
    except OSError as error:
        raise SystemExit("stats-summary: cannot run log show: %s" % error)


def main():
    parser = argparse.ArgumentParser(description="Summarise Contigua stats lines.")
    parser.add_argument("--file", metavar="PATH",
                        help="read this saved log output (default: run log show)")
    parser.add_argument("--start", metavar="TIME", help="log show --start")
    parser.add_argument("--end", metavar="TIME", help="log show --end")
    parser.add_argument("--last", metavar="TIME",
                        help="log show --last (e.g. 10m); ignored with --start/--end")
    parser.add_argument("--predicate", metavar="PREDICATE",
                        help="log show predicate (default: subsystem %s)" % SUBSYSTEM)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    args = parser.parse_args()

    if args.file:
        with open(args.file, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    elif args.last:
        command = ["/usr/bin/log", "show", "--last", args.last, "--info", "--style", "syslog",
                   "--predicate", args.predicate or 'subsystem == "%s"' % SUBSYSTEM]
        text = subprocess.run(command, capture_output=True, text=True, check=False).stdout
    else:
        text = read_range(args.start, args.end, args.predicate)

    streams = {stream: summarise(rows) for stream, rows in parse_lines(text).items()}
    if args.json:
        print(json.dumps({"streams": streams}, indent=2, sort_keys=True))
        return 0

    if not streams:
        print("stats-summary: no stats lines")
        return 1
    for stream in sorted(streams, key=lambda value: int(value) if value.isdigit() else value):
        summary = streams[stream]
        print("stream %s: %d lines" % (stream, summary["lines"]))
        for key, values in summary["fields"].items():
            if values["samples"] == 0:
                continue
            if key in CLOCK_FIELDS:
                print("  %-12s sum %-10g (%d samples, max %g)"
                      % (key, values["sum"], values["samples"], values["max"]))
            else:
                print("  %-12s median %-10g max %g (%d samples)"
                      % (key, values["median"], values["max"], values["samples"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
