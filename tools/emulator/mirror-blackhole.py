#!/usr/bin/env python3
"""mirror-blackhole.py — judge the direct-link confirmation boot's mirror phase.

The phase opens a phone mirror on the Mac, keeps the picture moving, black-holes
the current path A after 10 s, and watches 60 s. This analyser reads what the
three parties wrote and answers the brief's PASS list:

- the Mac logged an unplanned failover A -> B;
- the first frame that arrived over B after t0 arrived by t0 + 4.0 s
  (2 s ping interval + 1.5 s pong loss + the switch);
- after it, no empty run over 1.0 s until t0 + 60 s (RRR-1's regression would
  be a gap of up to ~40 s);
- the median frame rate in the last 30 s is at least 80 % of the 10 s before
  t0;
- no session ended, no Reconnecting/Phone offline, one session id, and A stayed
  a standby at the failover rather than being closed (PATH-21);
- the phone's paths-layer memory line, when the phone prints one, is under
  PATH-15's 28 MiB.

It also writes the 250 ms timeline (`mirror-frames.tsv`: frames and the path
seen in each bucket, plus the stall/offline flags) and the stall overlay's
appearances.

Usage:
  mirror-blackhole.py --frames TSV --mac-log FILE --chrome TSV --phone-log FILE
                      --t0 EPOCH [--a ID] [--b ID] [--stream N] --out DIR
  mirror-blackhole.py --self-test [--out DIR]

Frame lines are `<epoch>\t<stream>\t<path>`, chrome lines are
`<epoch>\t<the chrome state line>`. Exit 0 when every check passes.
"""
import argparse
import datetime
import os
import re
import statistics
import sys

WINDOW_S = 60.0          # the watch after t0
PRE_S = 10.0             # the steady stretch before t0
FIRST_FRAME_LIMIT_S = 4.0
MAX_GAP_S = 1.0
FPS_FLOOR = 0.80
BUCKET_S = 0.25
STANDBY_GRACE_S = 5.0    # A must not be closed at/with the failover
PATH15_MIB = 28.0

STAMP_RE = re.compile(r"^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d\.\d+)([+-])(\d\d)(\d\d)")


def parse_stamp(text):
    """Epoch seconds of a syslog line's own timestamp, or None."""
    match = STAMP_RE.match(text)
    if not match:
        return None
    date, clock, sign, hh, mm = match.groups()
    if "." in clock:
        head, frac = clock.split(".", 1)
        clock = head + "." + (frac + "000000")[:6]
    naive = datetime.datetime.strptime(date + " " + clock, "%Y-%m-%d %H:%M:%S.%f")
    epoch = (naive - datetime.datetime(1970, 1, 1)).total_seconds()
    offset = int(hh) * 3600 + int(mm) * 60
    return epoch - (offset if sign == "+" else -offset)


def read_frames(path):
    rows = []
    with open(path) as fp:
        for line in fp:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            try:
                rows.append((float(parts[0]), int(parts[1]), parts[2]))
            except ValueError:
                continue
    rows.sort()
    return rows


def read_mac(path):
    rows = []
    with open(path) as fp:
        for line in fp:
            stamp = parse_stamp(line)
            if stamp is not None:
                rows.append((stamp, line.rstrip("\n")))
    return rows


def read_chrome(path):
    rows = []
    with open(path) as fp:
        for line in fp:
            epoch, _, state = line.rstrip("\n").partition("\t")
            try:
                rows.append((float(epoch), state))
            except ValueError:
                continue
    return rows


def flag(state, name):
    match = re.search(r"\b" + re.escape(name) + r"=([^\s]+)", state)
    return match.group(1) if match else ""


def median(values):
    return statistics.median(values) if values else 0.0


def per_second(frames, start, end):
    """Frame counts in whole-second buckets that begin inside [start, end)."""
    counts = [0] * max(0, int(end - start))
    for ts, _stream, _path in frames:
        if start <= ts < end:
            index = int(ts - start)
            if 0 <= index < len(counts):
                counts[index] += 1
    return counts


def last_before(rows, stamp, key=None):
    found = None
    for at, text in rows:
        if at > stamp:
            break
        if key is None or key(text):
            found = text
    return found


def analyse(frames, mac, chrome, phone_text, t0, a_id, b_id, stream=None):
    checks = []
    notes = []
    end = t0 + WINDOW_S

    def add(tag, passed, detail):
        checks.append((tag, passed, detail))

    if stream is None:
        counts = {}
        for _ts, s, _p in frames:
            counts[s] = counts.get(s, 0) + 1
        stream = max(counts, key=counts.get) if counts else 0
    mine = [row for row in frames if row[1] == stream]

    if not a_id:
        before = [p for ts, _s, p in mine if ts < t0]
        a_id = before[-1] if before else ""
    switch_re = re.compile(r"paths: sending ([0-9a-f]+) -> ([0-9a-f]+) \(([a-z-]+)\)")
    switches = []
    for at, text in mac:
        match = switch_re.search(text)
        if match and at >= t0 - 1.0:
            switches.append((at, match.group(1), match.group(2), match.group(3)))
    failover = next((row for row in switches if row[1] == a_id and row[3] != "planned"), None)
    if not b_id and failover:
        b_id = failover[2]
    if not b_id:
        after = [p for ts, _s, p in mine if ts >= t0 and p != a_id]
        b_id = after[0] if after else ""

    add("MIRROR-1", failover is not None,
        "the Mac logged an unplanned failover %s -> %s%s" % (
            a_id or "?", b_id or "?",
            "" if not failover else " at t0%+.3f s (%s)" % (failover[0] - t0, failover[3])))

    after = [(ts, path) for ts, _s, path in mine if ts >= t0]
    first_b = next((ts for ts, path in after if path == b_id), None)
    add("MIRROR-2", first_b is not None and first_b - t0 <= FIRST_FRAME_LIMIT_S,
        "the first frame over B after t0 arrived %s (limit %.1f s)" % (
            "never" if first_b is None else "at t0+%.3f s" % (first_b - t0),
            FIRST_FRAME_LIMIT_S))

    if first_b is None:
        add("MIRROR-3", False, "no frame over B after t0, so the 60 s gap cannot be measured")
        add("MIRROR-4", False, "no frame over B after t0, so the last-30-s rate is 0")
    else:
        points = [first_b] + sorted(ts for ts, _p in after if ts >= first_b) + [end]
        gaps = [b - a for a, b in zip(points, points[1:])]
        worst = max(gaps) if gaps else end - first_b
        add("MIRROR-3", worst <= MAX_GAP_S,
            "the largest empty run after the first frame over B was %.3f s (limit %.1f s)" % (
                worst, MAX_GAP_S))
        pre = per_second(mine, t0 - PRE_S, t0)
        post = per_second(mine, t0 + 30.0, end)
        pre_med = median(pre)
        post_med = median(post)
        ratio = (post_med / pre_med) if pre_med else 0.0
        add("MIRROR-4", pre_med > 0 and ratio >= FPS_FLOOR,
            "median %.1f fps in the last 30 s vs %.1f fps before t0 (%.0f%%, floor %.0f%%)" % (
                post_med, pre_med, ratio * 100.0, FPS_FLOOR * 100.0))

    window_mac = [text for at, text in mac if t0 - 1.0 <= at <= end + 2.0]
    ended = [text for text in window_mac
             if "session failed" in text or "session ended" in text or "paths: ended" in text]
    offline = [state for at, state in chrome
               if t0 - 1.0 <= at <= end + 2.0 and flag(state, "bar_offline") == "1"]
    welcomes = re.findall(r"session ([0-9a-f]+): welcome", phone_text)
    add("MIRROR-5", not ended and not offline and len(set(welcomes)) == 1,
        "session end %d, Reconnecting/offline samples %d, session ids %s" % (
            len(ended), len(offline), ",".join(sorted(set(welcomes))) or "none"))

    down_re = re.compile(r"paths: path down ([0-9a-f]+)")
    downed = [(at, text) for at, text in mac
              if down_re.search(text) and down_re.search(text).group(1) == a_id]
    at_failover = [at for at, _t in downed
                   if failover is None or at <= failover[0] + STANDBY_GRACE_S]
    phone_down = re.findall(r"path down: ([0-9a-f]+)", phone_text)
    phone_ended = bool(re.search(r"session superseded|paths: ended", phone_text))
    phone_a_down = a_id in phone_down
    add("MIRROR-6", not at_failover and not phone_a_down and not phone_ended,
        "A (%s) closed at the failover: %d, the phone kept A: %s" % (
            a_id or "?", len(at_failover), "no" if (phone_a_down or phone_ended) else "yes"))
    later = [at for at, _t in downed if failover is not None and at > failover[0] + STANDBY_GRACE_S]
    if later:
        notes.append("A's black-holed socket gave up at t0%+.1f s (its own keepalive, after the failover)"
                     % (later[0] - t0))

    memory = re.findall(r"(?:paths: (?:mem|memory|heap)[^\n]*?([0-9]+(?:\.[0-9]+)?)\s*MiB)", phone_text,
                        re.IGNORECASE)
    if memory:
        worst = max(float(value) for value in memory)
        add("MIRROR-7", worst < PATH15_MIB,
            "the phone's paths memory line reads %.1f MiB (limit %.0f MiB)" % (worst, PATH15_MIB))
    else:
        notes.append("the phone prints no paths-layer memory line; the limit is unmeasured here")

    # The stall overlay: appearances and when, for the report.
    stalls = []
    previous = "0"
    for at, state in sorted(chrome):
        if at < t0 - 1.0 or at > end + 2.0:
            continue
        now = flag(state, "stall_pill") or flag(state, "stall")
        if now == "1" and previous != "1":
            stalls.append(at)
        previous = now
    detail = "the stall overlay appeared %d time(s)%s" % (
        len(stalls), "".join(" at t0%+.1f s" % (at - t0) for at in stalls))
    if len(stalls) > 1 or any((failover is None or at > failover[0] + 1.0) for at in stalls):
        notes.append(detail + " (expected at most one, between t0 and the failover)")
    else:
        notes.append(detail)

    stats = {
        "t0": t0, "stream": stream, "a": a_id, "b": b_id,
        "failover_at": None if not failover else failover[0] - t0,
        "first_b_at": None if first_b is None else first_b - t0,
        "frames": len(mine),
    }
    return checks, notes, stats


def write_timeline(path, frames, chrome, t0, stream):
    start = t0 - PRE_S
    count = int((WINDOW_S + PRE_S) / BUCKET_S) + 1
    rows = []
    for index in range(count):
        rows.append({"frames": 0, "paths": [], "stall": "", "stall_pill": "", "bar_offline": ""})
    for ts, s, p in frames:
        if s != stream or ts < start or ts > t0 + WINDOW_S:
            continue
        index = int((ts - start) / BUCKET_S)
        row = rows[index]
        row["frames"] += 1
        if p not in row["paths"]:
            row["paths"].append(p)
    for at, state in chrome:
        if at < start or at > t0 + WINDOW_S:
            continue
        index = int((at - start) / BUCKET_S)
        for name in ("stall", "stall_pill", "bar_offline"):
            row = rows[index]
            row[name] = flag(state, name) or row[name]
    with open(path, "w") as fp:
        fp.write("t_rel_s\tframes\tpaths\tstall\tstall_pill\tbar_offline\n")
        for index, row in enumerate(rows):
            rel = index * BUCKET_S - PRE_S
            fp.write("%.2f\t%d\t%s\t%s\t%s\t%s\n" % (
                rel, row["frames"], ",".join(row["paths"]) or "-",
                row["stall"] or "-", row["stall_pill"] or "-", row["bar_offline"] or "-"))


# --- self-test -------------------------------------------------------------

def frame_lines(t0, pre=True, recovery=3.4, hole=None, post_fps=30.0, path_b="bbbbbbbb"):
    rows = []
    if pre:
        for index in range(int(15.0 * 30.0)):
            rows.append((t0 - 15.0 + index / 30.0, 1, "aaaaaaaa"))
    at = t0 + recovery
    step = 1.0 / post_fps if post_fps else 0.0
    while at < t0 + WINDOW_S and step:
        if not (hole and hole[0] <= at <= hole[1]):
            rows.append((at, 1, path_b))
        at += step
    rows.sort()
    return ["%.6f\t%d\t%s" % row for row in rows]


def mac_lines(t0, events):
    out = []
    for at, text in events:
        stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f")
        out.append("%s+0000  localhost Contigua[1]: [app.contigua.mac:session] %s" % (stamp, text))
    return out


def chrome_lines(t0, offline=None, stall=None):
    rows = []
    for offset in range(-15, 62):
        state = "stall=0 stall_pill=0 bar_offline=0 loading=0"
        if offline is not None and offset == offline:
            state = "stall=0 stall_pill=0 bar_offline=1 loading=0"
        if stall is not None and offset == stall:
            state = "stall=1 stall_pill=1 bar_offline=0 loading=0"
        rows.append("%.6f\t%s" % (t0 + offset, state))
    return rows


def run_case(directory, name, frames, mac, chrome, phone, t0, expect_fail):
    paths = {}
    for key, lines in (("frames.tsv", frames), ("mac.log", mac),
                       ("chrome.tsv", chrome), ("phone.log", phone)):
        paths[key] = os.path.join(directory, name + "-" + key)
        with open(paths[key], "w") as fp:
            fp.write("\n".join(lines) + ("\n" if lines else ""))
    checks, notes, _stats = analyse(
        read_frames(paths["frames.tsv"]), read_mac(paths["mac.log"]),
        read_chrome(paths["chrome.tsv"]), "\n".join(phone), t0, "aaaaaaaa", "bbbbbbbb", 1)
    failed = [tag for tag, ok, _detail in checks if not ok]
    if expect_fail is None:
        return not failed, "no failing check" if not failed else "failed %s" % failed
    return expect_fail in failed, "expected %s, failed %s" % (expect_fail, failed or "none")


def self_test(out_dir):
    t0 = 1_800_000_000.0
    switch = [(t0 + 3.2, "paths: sending aaaaaaaa -> bbbbbbbb (failure)"),
              (t0 - 2.0, "paths: attached bbbbbbbb (paths 2)")]
    phone = ["11-01 21:00:00.000 I/ContiguaSvc( 1): session 1f8f4b53: welcome (protocol 4)",
             "11-01 21:00:00.100 I/ContiguaSvc( 1): paths: joined bbbbbbbb (paths 2)"]
    mac = mac_lines(t0, switch)
    cases = []
    cases.append(("good", frame_lines(t0), mac, chrome_lines(t0, stall=2), phone, None))
    cases.append(("slow-recovery", frame_lines(t0, recovery=5.0), mac,
                  chrome_lines(t0), phone, "MIRROR-2"))
    cases.append(("forty-second-hole", frame_lines(t0, hole=(t0 + 10.0, t0 + 50.0)), mac,
                  chrome_lines(t0), phone, "MIRROR-3"))
    cases.append(("third-rate", frame_lines(t0, post_fps=10.0), mac,
                  chrome_lines(t0), phone, "MIRROR-4"))
    cases.append(("reconnecting", frame_lines(t0), mac,
                  chrome_lines(t0, offline=20), phone, "MIRROR-5"))
    cases.append(("a-closed", frame_lines(t0),
                  mac_lines(t0, switch + [(t0 + 3.25, "paths: path down aaaaaaaa (tls)")]),
                  chrome_lines(t0), phone, "MIRROR-6"))
    cases.append(("session-failed", frame_lines(t0),
                  mac_lines(t0, switch + [(t0 + 20.0, "session failed: tls")]),
                  chrome_lines(t0), phone, "MIRROR-5"))
    failed = 0
    for name, frames, mac_lines_, chrome, phone_lines, expect in cases:
        ok, detail = run_case(out_dir, name, frames, mac_lines_, chrome, phone_lines, t0, expect)
        print("%s %s: %s" % ("SELF-TEST OK" if ok else "SELF-TEST FAIL", name, detail))
        failed += 0 if ok else 1
    return failed


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames")
    parser.add_argument("--mac-log")
    parser.add_argument("--chrome")
    parser.add_argument("--phone-log")
    parser.add_argument("--t0", type=float)
    parser.add_argument("--a")
    parser.add_argument("--b")
    parser.add_argument("--stream", type=int)
    parser.add_argument("--out")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    out_dir = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "..", "..", ".work", "direct-link", "p1-confirm")
    os.makedirs(out_dir, exist_ok=True)
    if args.self_test:
        return self_test(out_dir)
    if not (args.frames and args.mac_log and args.chrome and args.phone_log) or args.t0 is None:
        parser.error("--frames, --mac-log, --chrome, --phone-log and --t0 are required")
    frames = read_frames(args.frames)
    mac = read_mac(args.mac_log)
    chrome = read_chrome(args.chrome)
    with open(args.phone_log) as fp:
        phone_text = fp.read()
    checks, notes, stats = analyse(frames, mac, chrome, phone_text, args.t0,
                                   args.a or "", args.b or "", args.stream)
    write_timeline(os.path.join(out_dir, "mirror-frames.tsv"), frames, chrome,
                   args.t0, stats["stream"])
    report = os.path.join(out_dir, "mirror-blackhole.txt")
    with open(report, "w") as fp:
        fp.write("t0 %.6f stream %d A %s B %s frames %d\n" % (
            stats["t0"], stats["stream"], stats["a"] or "?", stats["b"] or "?", stats["frames"]))
        for tag, ok, detail in checks:
            fp.write("%s [%s] %s\n" % ("PASS" if ok else "FAIL", tag, detail))
        for note in notes:
            fp.write("NOTE %s\n" % note)
    for tag, ok, detail in checks:
        print("%s [%s] %s" % ("PASS" if ok else "FAIL", tag, detail))
    for note in notes:
        print("NOTE %s" % note)
    print("timeline %s" % os.path.join(out_dir, "mirror-frames.tsv"))
    return 0 if all(ok for _tag, ok, _detail in checks) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
