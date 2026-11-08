#!/usr/bin/env python3
"""The overrun check's pass bar, over the Mac's stats lines and the phone log.

One arm per call. The numbers are the Mac app's own 5 s lines (fps, drop
episodes, key requests, broken-reference counts) and the phone's own lines
(the key frame's size against the queue budget, the goodput cap). Nothing here
touches a device, so `--self-test` proves the bar against synthetic logs.

    overrun_stats.py --arm a --stats mac.log --logcat phone.log --seconds 120
    overrun_stats.py --arm b --stats mac.log --logcat phone.log \
        --proxy proxy.jsonl --link-mbit 3
    overrun_stats.py --self-test
"""

import argparse
import json
import re
import sys

STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)([+-]\d{4})")


def fields(line):
    out = {}
    for word in line.split():
        if "=" in word:
            key, value = word.split("=", 1)
            out[key] = value
    return out


def number(row, key):
    raw = row.get(key)
    if raw in (None, "-"):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def stats_rows(text):
    """The Mac's 5 s lines for the stream, oldest first."""
    rows = []
    for line in text.splitlines():
        if " stats stream=" not in line or " stats total " in line:
            continue
        row = fields(line)
        row["at"] = STAMP.match(line.strip()).group(1) if STAMP.match(line.strip()) else ""
        rows.append(row)
    return rows


def totals_row(text):
    for line in text.splitlines():
        if " stats total stream=" in line:
            return fields(line)
    return None


def check(name, condition, message, failures):
    if condition:
        print("PASS %s: %s" % (name, message))
    else:
        print("FAIL %s: %s" % (name, message))
        failures.append(message)


def episodes_after_warmup(rows, warmup_lines=2):
    """The drop episodes in the windows after the first 10 s."""
    return sum(int(number(row, "drop_ep") or 0) for row in rows[warmup_lines:])


def key_requests_after_warmup(rows, warmup_lines=2):
    return sum(int(number(row, "kf_req") or 0) for row in rows[warmup_lines:])


def broken_references(totals):
    return (int(number(totals, "key_not_idr") or 0) +
            int(number(totals, "ph_key_not_idr") or 0))


def key_frame_ratio(text):
    """(bytes, budget) of the largest key frame the phone logged, or None."""
    best = None
    for match in re.finditer(r"stream \d+ key frame: bytes=(\d+) budget=(\d+)", text):
        size, budget = int(match.group(1)), int(match.group(2))
        if best is None or size > best[0]:
            best = (size, budget)
    return best


def goodput_caps(text):
    """The measured goodput (Mbps) of every recovery-cap line, oldest first."""
    return [float(value) for value in
            re.findall(r"recovery cap [0-9.]+ Mbps \(measured ([0-9.]+) Mbps\)", text)]


def proxy_rate(events_path, seconds):
    """Mbps the proxy delivered toward the Mac (dir 1) over the run."""
    if not events_path:
        return None
    total = 0
    with open(events_path, "r", encoding="utf-8") as handle:
        for line in handle:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("ev") == "bytes" and event.get("dir") == 1:
                total += int(event.get("n") or 0)
    return total * 8 / (seconds * 1_000_000) if seconds > 0 else None


def arm_a(stats, logcat, seconds):
    failures = []
    rows = stats_rows(stats)
    totals = totals_row(stats)
    if not rows or totals is None:
        check("arm-a", False, "no stats lines or no totals line", failures)
        return failures
    episodes = episodes_after_warmup(rows)
    check("arm-a", episodes <= 1,
          "drop episodes after the first 10 s: %d (at most 1)" % episodes, failures)
    requests = key_requests_after_warmup(rows)
    check("arm-a", requests <= 2,
          "key frame requests after the first 10 s: %d (at most 2)" % requests, failures)
    broken = broken_references(totals)
    check("arm-a", broken == 0,
          "broken-reference key frames: %d (none)" % broken, failures)
    secs = number(totals, "secs") or 0
    covered = (number(totals, "covered_ms") or 0) / 1000.0
    active = max(0.0, secs - covered)
    phone_fps = (number(totals, "phone_frames") or 0) / secs if secs else 0
    shown_fps = (number(totals, "shown_frames") or 0) / active if active else 0
    check("arm-a", secs >= 110, "the run was %.1f s (at least 110)" % secs, failures)
    check("arm-a", phone_fps >= 10,
          "the source moved: %.1f encoder fps (at least 10)" % phone_fps, failures)
    check("arm-a", shown_fps >= 0.8 * phone_fps,
          "Mac shown %.1f fps against the source's %.1f fps (at least 80 %%)"
          % (shown_fps, phone_fps), failures)
    key = key_frame_ratio(logcat)
    if key is None:
        check("arm-a", False, "no 'key frame: bytes= budget=' line on the phone", failures)
    else:
        size, budget = key
        check("arm-a", size <= budget,
              "largest key frame %d bytes against the budget %d (fits)"
              % (size, budget), failures)
    last = rows[-1]
    print("ARM A numbers: drop_ep=%d kf_req=%d shown=%.1f phone=%.1f kbps=%s "
          "target_kbps=%s key=%s"
          % (episodes, requests, shown_fps, phone_fps, last.get("kbps"),
             last.get("target_kbps"), "-" if key is None else "%d/%d" % key))
    return failures


def arm_b(stats, logcat, proxy, seconds, link_mbit):
    failures = []
    rows = stats_rows(stats)
    totals = totals_row(stats)
    if not rows or totals is None:
        check("arm-b", False, "no stats lines or no totals line", failures)
        return failures
    episodes = episodes_after_warmup(rows)
    check("arm-b", episodes <= 1,
          "drop episodes after the first 10 s: %d (at most 1)" % episodes, failures)
    broken = broken_references(totals)
    check("arm-b", broken == 0,
          "broken-reference key frames: %d (none)" % broken, failures)
    caps = goodput_caps(logcat)
    check("arm-b", bool(caps),
          "the phone measured a goodput cap (%s)"
          % (("%.2f Mbps" % caps[-1]) if caps else "none"), failures)
    last = rows[-1]
    target = number(last, "target_kbps")
    actual = number(last, "kbps")
    if caps:
        measured = caps[-1]
        check("arm-b", target is not None and target <= measured * 1000,
              "the bitrate target %s kbps is below the measured goodput %.2f Mbps"
              % (last.get("target_kbps"), measured), failures)
        check("arm-b", actual is not None and actual <= measured * 1000,
              "the encoder put out %s kbps, below the measured goodput %.2f Mbps"
              % (last.get("kbps"), measured), failures)
    check("arm-b", actual is not None and actual > 500,
          "the stream carried video: %s kbps (at least 500)" % last.get("kbps"), failures)
    rate = proxy_rate(proxy, seconds)
    if rate is None:
        check("arm-b", False, "no proxy byte events", failures)
    else:
        check("arm-b", 1.5 <= rate <= link_mbit + 0.3,
              "the shaped link delivered %.2f Mbps (%.1f Mbit/s link)"
              % (rate, link_mbit), failures)
    print("ARM B numbers: drop_ep=%d kbps=%s target_kbps=%s cap=%s link=%.2f Mbps"
          % (episodes, last.get("kbps"), last.get("target_kbps"),
             ("%.2f" % caps[-1]) if caps else "-", rate if rate is not None else 0))
    return failures


def synthetic(rows, totals, logcat, proxy=None):
    text = "\n".join(
        "2026-11-08 12:00:%02d.000-0300 stats stream=1 " % index + row
        for index, row in enumerate(rows))
    text += "\n2026-11-08 12:02:00.000-0300 stats total stream=1 " + totals
    return text, logcat, proxy


def self_test():
    """The bar against two synthetic runs: the pre-fix spiral and the fix."""
    base = "rx_fps=60.0 shown_fps=60.0 drop_ep=%d kf_req=%d kbps=24000 target_kbps=8000"
    bad_rows = [base % (0, 0)] * 2 + [base % (3, 3)] * 22
    bad_totals = ("secs=120.0 rx_frames=1200 shown_frames=1200 phone_frames=7200 "
                  "key_not_idr=0 ph_key_not_idr=0 kf_req=66 drop_ep=66 covered_ms=0")
    bad_log = "stream 1 key frame: bytes=500000 budget=262144\n"
    stats, log, _ = synthetic(bad_rows, bad_totals, bad_log)
    bad = arm_a(stats, log, 120)
    if not bad:
        print("SELF-TEST FAIL: the pre-fix arm A passed")
        return 1
    good_rows = [base % (0, 0)] * 24
    good_totals = ("secs=120.0 rx_frames=7100 shown_frames=7000 phone_frames=7200 "
                   "key_not_idr=0 ph_key_not_idr=0 kf_req=12 drop_ep=0 covered_ms=0")
    good_log = "stream 1 key frame: bytes=500000 budget=1350000\n"
    stats, log, _ = synthetic(good_rows, good_totals, good_log)
    if arm_a(stats, log, 120):
        print("SELF-TEST FAIL: the fixed arm A failed")
        return 1
    b_rows = ["rx_fps=60.0 shown_fps=60.0 drop_ep=0 kf_req=1 kbps=2500 target_kbps=2550"] * 24
    b_totals = ("secs=120.0 rx_frames=7000 shown_frames=7000 phone_frames=7100 "
                "key_not_idr=0 ph_key_not_idr=0 kf_req=1 drop_ep=1 covered_ms=0")
    b_log = "stream 1 quality: recovery cap 2.5 Mbps (measured 3.0 Mbps)\n"
    proxy = "/tmp/overrun-selftest-proxy.jsonl"
    with open(proxy, "w", encoding="utf-8") as handle:
        for _ in range(120):
            handle.write(json.dumps({"ev": "bytes", "dir": 1, "n": 375000}) + "\n")
    stats, log, events = synthetic(b_rows, b_totals, b_log, proxy)
    if arm_b(stats, log, events, 120, 3.0):
        print("SELF-TEST FAIL: the fixed arm B failed")
        return 1
    b_bad = b_log.replace("measured 3.0", "measured 1.0")
    stats, log, events = synthetic(b_rows, b_totals, b_bad, proxy)
    if not arm_b(stats, log, events, 120, 3.0):
        print("SELF-TEST FAIL: a bitrate above the measured goodput passed")
        return 1
    print("SELF-TEST PASS")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="The overrun check's pass bar.")
    parser.add_argument("--arm", choices=("a", "b"))
    parser.add_argument("--stats")
    parser.add_argument("--logcat")
    parser.add_argument("--proxy")
    parser.add_argument("--seconds", type=float, default=120.0)
    parser.add_argument("--link-mbit", type=float, default=3.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.arm or not args.stats or not args.logcat:
        parser.error("--arm, --stats and --logcat are required")
    with open(args.stats, "r", encoding="utf-8") as handle:
        stats = handle.read()
    with open(args.logcat, "r", encoding="utf-8") as handle:
        logcat = handle.read()
    if args.arm == "a":
        failures = arm_a(stats, logcat, args.seconds)
    else:
        failures = arm_b(stats, logcat, args.proxy, args.seconds, args.link_mbit)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
