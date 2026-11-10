#!/usr/bin/env python3
"""Judge the switchquality emulator arm (PATH-46).

Reads the Mac app's own 5 s `stats stream=` lines, the phone's `drop episode`
transitions and the `--audio-stats` snapshots, then prints one PASS/FAIL line
per bound. The green arm must adapt (the target falls within PATH-36's
85%-of-goodput cap without a repeated drop cycle and climbs back within 10% of
its pre-step value inside five minutes); the red arm is the same timeline with
`debug.pocketdeck.stream.quality=off`, where the check must fail.

    switchquality_stats.py --arm green --mac mac-green.log \
        --phases phases.txt --audio-a audio-green-a.json \
        --audio-b audio-green-b.json
    switchquality_stats.py --self-test

Phase keys: base_start, base_end, step_start, step_end, back_start, back_end,
stall_start, stall_end and base_target. Times are epoch seconds; `back_start`
is the second the link returned to 20 Mbit/s and `back_end` the recovery
check's end (it may be a 300 s timeout).

The 3 Mbit/s step and the stall window are measured and reported, never
bounded: they are the link's own withholding. The 150 ms picture bound applies
to the two 20 Mbit/s windows. `chain_fed` and the chain-restore clock are
bounded over the whole arm, and audio underrun over the whole arm when the
emulator produced audio frames at all.
"""

import argparse
import json
import re
import statistics
import sys
from datetime import datetime

MAC_LINE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4})\s")
PHONE_LINE = re.compile(r"^(\d+\.\d+)\s")
EPISODE = re.compile(r"drop episode: flowing --dropped\(\d+\)--> waiting")
RESTORE = re.compile(r"chain restored after (\d+) ms")
BROKEN = re.compile(r"chain broken")


def parse_epoch(text):
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def parse_phases(path):
    out = {}
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        out[key.strip()] = value.strip()
    return out


def parse_mac(path):
    """[(epoch, {key: value})] for every `stats stream=` line."""
    rows = []
    try:
        handle = open(path, errors="replace")
    except OSError:
        return rows
    with handle:
        for line in handle:
            if "stats stream=" not in line:
                continue
            match = MAC_LINE.match(line)
            if not match:
                continue
            try:
                at = parse_epoch(match.group(1))
            except ValueError:
                continue
            fields = {}
            for token in line.split():
                if "=" not in token:
                    continue
                key, _, value = token.partition("=")
                fields[key] = value
            rows.append((at, fields))
    rows.sort()
    return rows


def parse_phone_episodes(path):
    """Epochs of new drop episodes, each `flowing --dropped--> waiting`."""
    out = []
    try:
        handle = open(path, errors="replace")
    except OSError:
        return out
    with handle:
        for line in handle:
            if not EPISODE.search(line):
                continue
            match = PHONE_LINE.match(line)
            if not match:
                continue
            try:
                out.append(float(match.group(1)))
            except ValueError:
                pass
    return out


def number(fields, key):
    try:
        value = fields.get(key, "-")
        if value in ("-", None):
            return None
        return float(value)
    except ValueError:
        return None


def inside(rows, start, end):
    return [(at, fields) for at, fields in rows if start <= at <= end]


def targets(rows):
    return [value for _, fields in rows
            for value in (number(fields, "target_kbps"),) if value is not None]


def max_field(rows, key):
    values = [value for _, fields in rows
              for value in (number(fields, key),) if value is not None]
    return max(values) if values else None


def stats_line(text, ok):
    out = "PASS" if ok else "FAIL"
    print("%s [PATH-46] SWITCHQUALITY%s" % (out, text))


def audio(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return {}


def judge_green(phases, mac, episodes, audio_a, audio_b):
    failures = 0
    arm = "green"

    def expect(ok, message):
        nonlocal failures
        stats_line("(%s) %s" % (arm, message), ok)
        if not ok:
            failures += 1

    base_start = float(phases["base_start"])
    base_end = float(phases["base_end"])
    step_start = float(phases["step_start"])
    step_end = float(phases["step_end"])
    back_end = float(phases.get("back_end", step_end))

    base = inside(mac, base_start, base_end)
    step = inside(mac, step_start, step_end)
    back = inside(mac, float(phases.get("recovered", back_end)) if phases.get("recovered") else back_end,
                  back_end)

    base_values = targets(base)
    base_target = statistics.median(base_values) if base_values else None
    low_values = targets(step)
    low_target = statistics.median(low_values[-2:]) if low_values else None
    recovered = phases.get("recovered", "")
    recovery_ok = bool(recovered)
    back_values = targets(back)
    back_target = statistics.median(back_values[-2:]) if back_values else None

    # The target at the end of the 3 Mbit/s step, within PATH-36's 85% cap
    # (10% slack for the meter's own estimate) and clearly below the step's
    # starting value.
    cap_ok = (low_target is not None and low_target <= 0.85 * 3.0 * 1000.0 * 1.10)
    drop_ok = (low_target is not None and base_target is not None and
               low_target <= 0.9 * base_target)
    expect(cap_ok and drop_ok,
           "the target fell to %s kbps at the 3 Mbit/s step (base %s, cap 2805)"
           % (fmt(low_target), fmt(base_target)))

    # At most one drop episode after the first 10 s of the low step. The
    # phone's own transition log is the only source: the Mac's `drop_ep` field
    # is a per-window count, not a cumulative one, so a delta across lines is
    # meaningless.
    cutoff = step_start + 10.0
    later = [at for at in episodes if cutoff < at <= step_end]
    count = len(later) if episodes else None
    expect(count is not None and count <= 1,
           "the 3 Mbit/s step started %s new drop episode(s) after its first 10 s (%s)"
           % (count if count is not None else "?",
              "phone log" if episodes else "no phone log"))

    # Recovery: the target is back within 10% of the pre-step value, measured
    # from the moment the link returned.
    if recovery_ok and base_target is not None and back_target is not None:
        seconds = float(phases["recovered"]) - step_end
        expect(seconds <= 300.0 and back_target >= 0.9 * base_target,
               "the target climbed back to %s kbps %s s after the link returned"
               % (fmt(back_target), fmt(seconds)))
    else:
        expect(False, "the target did not climb back to within 10%% of %s kbps "
                      "within 300 s" % fmt(base_target))

    # Picture: no gap above 150 ms in the two 20 Mbit/s windows. The step and
    # the stall window are the link's own withholding and are reported below.
    for label, rows in (("before", base), ("after recovery", back)):
        gap = max_field(rows, "max_gap_ms")
        expect(gap is not None and gap <= 150,
               "the longest gap %s was %s ms (limit 150)" % (label, fmt(gap)))

    chain_fed = max_field(mac, "chain_fed")
    expect(chain_fed in (0.0, 0), "chain_fed stayed %s (limit 0)" % fmt(chain_fed))

    restores = []
    broken = 0
    try:
        handle = open(phases["mac_path"], errors="replace")
    except (OSError, KeyError):
        handle = None
    if handle is not None:
        with handle:
            for line in handle:
                for match in restore_matches(line):
                    restores.append(int(match))
                if BROKEN.search(line):
                    broken += 1
    expect(all(value <= 600 for value in restores),
           ("every chain restored after at most %d ms (limit 600)" % max(restores))
           if restores else "no chain restore was logged")
    expect(broken == 0, "no chain broken (%d)" % broken)

    frames_a = number(audio_a, "frames") or 0
    frames_b = number(audio_b, "frames") or 0
    underrun = (number(audio_b, "underrun") or 0) - (number(audio_a, "underrun") or 0)
    concealed = (number(audio_b, "concealed") or 0) - (number(audio_a, "concealed") or 0)
    dropped = (number(audio_b, "dropped") or 0) - (number(audio_a, "dropped") or 0)
    if frames_b > frames_a:
        expect(underrun == 0,
               "audio underrun stayed %d with %d frames (concealed %+d, dropped %+d)"
               % (underrun, frames_b - frames_a, concealed, dropped))
    else:
        print("watch [PATH-46] SWITCHQUALITY(green) audio ran no frames "
              "(the emulator rig has no audible source); underrun not exercised")

    # Report-only windows.
    for label, start_key, end_key in (("3 Mbit/s", "step_start", "step_end"),
                                      ("stall", "stall_start", "stall_end")):
        if start_key not in phases or end_key not in phases:
            continue
        rows = inside(mac, float(phases[start_key]), float(phases[end_key]))
        if not rows:
            continue
        low = targets(rows)
        print("report [PATH-46] SWITCHQUALITY(green) %s window: "
              "target %s..%s kbps, longest gap %s ms, drop_ep %s..%s"
              % (label, fmt(min(low) if low else None),
                 fmt(max(low) if low else None),
                 fmt(max_field(rows, "max_gap_ms")),
                 fmt(min_field(rows, "drop_ep")),
                 fmt(max_field(rows, "drop_ep"))))
    return failures


def judge_red(phases, mac, episodes):
    step_start = float(phases["step_start"])
    step_end = float(phases["step_end"])
    base = inside(mac, float(phases["base_start"]), float(phases["base_end"]))
    step = inside(mac, step_start, step_end)
    base_values = targets(base)
    base_target = statistics.median(base_values) if base_values else None
    low_values = targets(step)
    low_target = statistics.median(low_values[-2:]) if low_values else None

    cutoff = step_start + 10.0
    later = [at for at in episodes if cutoff < at <= step_end]
    count = len(later) if episodes else None

    adapted = (low_target is not None and base_target is not None and
               low_target <= 0.9 * base_target)
    quiet = count is not None and count <= 1
    broken = not adapted or not quiet
    print("report [PATH-46] SWITCHQUALITY(red) base target %s kbps, "
          "step target %s kbps, %s episode(s) after 10 s"
          % (fmt(base_target), fmt(low_target), count if count is not None else "?"))
    stats_line("(red) the broken build never adapted and repeated the drop cycle",
               broken)
    return 0 if broken else 1


def min_field(rows, key):
    values = [value for _, fields in rows
              for value in (number(fields, key),) if value is not None]
    return min(values) if values else None


def restore_matches(line):
    return RESTORE.findall(line)


def fmt(value):
    if value is None:
        return "?"
    if isinstance(value, float):
        return "%.0f" % value if abs(value - round(value)) < 0.05 else "%.1f" % value
    return str(value)


def self_test():
    """Synthetic Mac and phone logs: green passes, a flat target fails, the
    red arm is recognised as broken and a red that adapted is a failure."""
    import os
    import tempfile

    def mac_line(at, **fields):
        stamp = datetime.fromtimestamp(at).astimezone().strftime("%Y-%m-%d %H:%M:%S.%f%z")
        body = " ".join("%s=%s" % (key, value) for key, value in fields.items())
        return "%s  localhost PocketDeck[1]: [dev.pocketdeck.mac:stream] stats stream=1 %s\n" % (stamp, body)

    def run(label, lines, episodes, expect_rc):
        work = tempfile.mkdtemp(prefix="switchquality-")
        mac = os.path.join(work, "mac.log")
        phone = os.path.join(work, "phone.log")
        phases_path = os.path.join(work, "phases.txt")
        with open(mac, "w") as handle:
            handle.write("".join(lines))
        with open(phone, "w") as handle:
            for at, _ in episodes:
                handle.write("%.3f  1 1 I PocketDeckSvc: stream 1 drop episode: "
                             "flowing --dropped(3)--> waiting\n" % at)
        phase = {"base_start": 100, "base_end": 110, "step_start": 111,
                 "step_end": 171, "back_start": 172, "back_end": 190,
                 "stall_start": 191, "stall_end": 201,
                 "mac_path": mac}
        if label == "green":
            phase["recovered"] = 175
        with open(phases_path, "w") as handle:
            for key, value in phase.items():
                handle.write("%s=%s\n" % (key, value))
        audio = os.path.join(work, "audio.json")
        with open(audio, "w") as handle:
            json.dump({"frames": 10, "underrun": 0, "concealed": 0, "dropped": 0}, handle)
        argv = ["prog", "--arm", label.split("-")[0], "--mac", mac,
                "--phone", phone, "--phases", phases_path,
                "--audio-a", audio, "--audio-b", audio]
        old = sys.argv
        sys.argv = argv
        try:
            rc = main()
        finally:
            sys.argv = old
        if rc != expect_rc:
            raise SystemExit("self-test %s: rc %d, wanted %d" % (label, rc, expect_rc))
        print("self-test %s OK" % label)

    base = [mac_line(100 + i, target_kbps=8000, max_gap_ms=40, drop_ep=0,
                     chain_fed=0) for i in range(11)]
    step_good = [mac_line(115 + 5 * i, target_kbps=2400, max_gap_ms=120,
                          drop_ep=1 if i == 2 else 2, chain_fed=0)
                 for i in range(12)]
    back = [mac_line(176 + 2 * i, target_kbps=7900, max_gap_ms=45,
                     drop_ep=2, chain_fed=0) for i in range(6)]
    step_flat = [mac_line(115 + 5 * i, target_kbps=8000, max_gap_ms=900,
                          drop_ep=10 + i, chain_fed=0) for i in range(12)]
    episodes_good = [(116, 1)]
    episodes_flat = [(116 + i, 1) for i in range(0, 50, 4)]

    run("green", base + step_good + back, episodes_good, 0)
    run("green-flat", base + step_flat + back, episodes_flat, 1)
    # red: same flat step, but now the failure is the expected result.
    run("red", base + step_flat + back, episodes_flat, 0)
    run("red-adapted", base + step_good + back, episodes_good, 1)
    print("switchquality_stats self-test PASS")


def main():
    parser = argparse.ArgumentParser(description="judge a switchquality arm")
    parser.add_argument("--arm", choices=("green", "red"))
    parser.add_argument("--mac")
    parser.add_argument("--phone")
    parser.add_argument("--phases")
    parser.add_argument("--audio-a")
    parser.add_argument("--audio-b")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not (args.arm and args.mac and args.phases):
        parser.error("--arm, --mac and --phases are required")
    phases = parse_phases(args.phases)
    mac = parse_mac(args.mac)
    episodes = parse_phone_episodes(args.phone) if args.phone else []
    if args.arm == "green":
        failures = judge_green(phases, mac, episodes,
                               audio(args.audio_a), audio(args.audio_b))
        print("passed=%d failed=%d" % (0, failures) if failures else "passed=1 failed=0")
        return 1 if failures else 0
    return judge_red(phases, mac, episodes)


if __name__ == "__main__":
    sys.exit(main())
