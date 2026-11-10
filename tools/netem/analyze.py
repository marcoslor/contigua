#!/usr/bin/env python3
"""losslab Part B analysis: frame gaps, throughput, TCP counters, audio.

    python3 tools/netem/analyze.py /tmp/pd-losslab-<condition> [...]

Reads only the run's own files. Prints one line per run and a median row per
condition, plus a CSV with every run.
"""

import json
import os
import re
import statistics
import sys
import datetime


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return float("nan")
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def frames(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                parts = line.split("\t")
                if len(parts) >= 2:
                    out.append(float(parts[0]))
    except FileNotFoundError:
        pass
    return out


def kbps_from_stats(path, t0, t1):
    """The app's own stats stream= lines inside the measurement window."""
    vals, targets, e2e50, e2e95, q95 = [], [], [], [], []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if "stats stream=" not in line:
                    continue
                m = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
                if not m:
                    continue
                ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
                if ts < t0 or ts > t1:
                    continue
                for key, box in (("kbps", vals), ("target_kbps", targets),
                                 ("e2e_p50", e2e50), ("e2e_p95", e2e95),
                                 ("queue_p95", q95)):
                    r = re.search(r" %s=(-?[\d.]+|-) " % key, line)
                    if r and r.group(1) != "-":
                        box.append(float(r.group(1)))
    except FileNotFoundError:
        pass
    med = lambda xs: statistics.median(xs) if xs else float("nan")
    return {"kbps": med(vals), "target": med(targets),
            "e2e50_med": med(e2e50), "e2e50_max": max(e2e50) if e2e50 else float("nan"),
            "e2e95_max": max(e2e95) if e2e95 else float("nan"),
            "queue95_med": med(q95), "queue95_max": max(q95) if q95 else float("nan")}


def parse_ss(path):
    """Every sample's media socket (the most bytes_sent) counters."""
    samples = []
    cur_t, cur = None, None
    def flush():
        if cur is not None:
            samples.append(cur)
    for line in open(path, errors="replace"):
        if line.startswith("### "):
            flush()
            cur_t = float(line[4:])
            cur = None
            continue
        if line.startswith("ESTAB"):
            fields = line.split()
            cur = {"t": cur_t, "recvq": int(fields[1]) if len(fields) > 1 else 0,
                   "sendq": int(fields[2]) if len(fields) > 2 else 0}
        elif cur is not None and line.startswith("\t") and "bytes_sent:" in line:
            for key in ("rto", "rtt", "cwnd", "bytes_sent", "bytes_acked", "bytes_retrans",
                        "delivery_rate", "busy", "unacked", "segs_out", "minrtt", "notsent"):
                m = re.search(key + r":([0-9.]+)(?:/([0-9.]+))?", line)
                if m:
                    cur[key] = float(m.group(1))
            # ss prints retrans:<in flight>/<total>; the total is the counter.
            m = re.search(r"retrans:([0-9]+)/([0-9]+)", line)
            if m:
                cur["retrans"] = float(m.group(2))
            m = re.search(r" lost:([0-9]+)", line)
            if m:
                cur["lost"] = float(m.group(1))
    flush()
    if not samples:
        return {}
    # The media socket: the one that sent the most bytes.
    media = max(samples, key=lambda s: s.get("bytes_sent", 0))
    first = next((s for s in samples if s.get("bytes_sent")), media)
    return {"samples": samples, "media": media, "first": first}


def analyze_run(work):
    timeline = json.load(open(os.path.join(work, "timeline.json")))
    start = next((x for x in timeline if x.get("kind") == "start"), {"t0": 0})
    end = next((x for x in timeline if x.get("kind") == "end"), {"t1": 0})
    t0, t1 = start["t0"], end["t1"]
    ts = [t for t in frames(os.path.join(work, "frames.tsv")) if t0 - 1 <= t <= t1 + 1]
    gaps = [(b - a) * 1000 for a, b in zip(ts, ts[1:]) if b - a < 5]  # a session reconnect is not a picture gap
    over = [g for g in gaps if g > 100]
    audio = {}
    try:
        audio = json.load(open(os.path.join(work, "audio.json")))
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    ss = parse_ss(os.path.join(work, "ss.txt"))
    media, first = ss.get("media", {}), ss.get("first", {})
    seconds = media.get("t", 0) - first.get("t", 0)
    sent = media.get("bytes_sent", 0) - first.get("bytes_sent", 0)
    ss_kbps = sent * 8 / seconds / 1000 if seconds > 0 and sent > 0 else float("nan")
    retrans = media.get("retrans", 0)
    lost = media.get("lost", 0)
    rto_max = max((s.get("rto", 0) for s in ss.get("samples", [])), default=0)
    rto_med = statistics.median([s.get("rto", 0) for s in ss.get("samples", [])]) if ss.get("samples") else 0
    cwnd_min = min((s.get("cwnd", 0) for s in ss.get("samples", []) if s.get("cwnd")), default=0)
    sendq_max = max((s.get("sendq", 0) + s.get("notsent", 0) for s in ss.get("samples", [])), default=0)
    retrans_bytes = media.get("bytes_retrans", 0)
    # Pulses: the largest frame gap that overlaps each pulse.
    pulses = [x for x in timeline if x.get("kind") == "pulse"]
    excess = []
    for pulse in pulses:
        p0, p1 = pulse["t0"], pulse["t1"]
        overlap = [g for (a, b), g in
                   (((a, b), (b - a) * 1000) for a, b in zip(ts, ts[1:]))
                   if a < p1 and b > p0]
        if overlap:
            observed = max(overlap)
            excess.append(observed - pulse["hold_ms"])
    broken = 0
    try:
        broken = sum(1 for line in open(os.path.join(work, "unified.log"), errors="replace")
                     if "chain broken" in line)
    except FileNotFoundError:
        pass
    app = kbps_from_stats(os.path.join(work, "unified.log"), t0, t1)
    backlog_ms = sendq_max * 8 / ss_kbps if ss_kbps == ss_kbps and ss_kbps > 0 else None
    return {
        "work": work,
        "secs": round(seconds, 1),
        "frames": len(ts),
        "fps": round(len(ts) / seconds, 1) if seconds else 0,
        "kbps_app": round(app["kbps"], 0) if app["kbps"] == app["kbps"] else None,
        "target_kbps": round(app["target"], 0) if app["target"] == app["target"] else None,
        "kbps_ss": round(ss_kbps, 0) if ss_kbps == ss_kbps else None,
        "e2e50_med": round(app["e2e50_med"], 0) if app["e2e50_med"] == app["e2e50_med"] else None,
        "e2e50_max": round(app["e2e50_max"], 0) if app["e2e50_max"] == app["e2e50_max"] else None,
        "e2e95_max": round(app["e2e95_max"], 0) if app["e2e95_max"] == app["e2e95_max"] else None,
        "queue95_med": round(app["queue95_med"], 1) if app["queue95_med"] == app["queue95_med"] else None,
        "queue95_max": round(app["queue95_max"], 1) if app["queue95_max"] == app["queue95_max"] else None,
        "backlog_ms": round(backlog_ms, 0) if backlog_ms else None,
        "gap_max": round(max(gaps), 0) if gaps else None,
        "gap_p99": round(pct(gaps, 99), 0) if gaps else None,
        "gap_p50": round(pct(gaps, 50), 1) if gaps else None,
        "gaps_over_100": len(over),
        "stalled_ms": round(sum(over), 0),
        "rto_med": round(rto_med, 0),
        "rto_max": round(rto_max, 0),
        "retrans": retrans,
        "retrans_bytes": retrans_bytes,
        "lost": lost,
        "cwnd_min": round(cwnd_min, 0),
        "sendq_max": sendq_max,
        "pulses": len(pulses),
        "excess_med": round(statistics.median(excess), 0) if excess else None,
        "excess_max": round(max(excess), 0) if excess else None,
        "underrun": audio.get("underrun"),
        "concealed": audio.get("concealed"),
        "audio_dropped": audio.get("dropped"),
        "late_p95": round(audio.get("lateP95Ms", 0), 1) if audio else None,
        "chain_broken": broken,
    }


def main():
    dirs = sys.argv[1:]
    rows = []
    for base in dirs:
        cond = os.path.basename(base).replace("pd-losslab-", "")
        runs = sorted(d for d in os.listdir(base) if d.startswith("run")) if os.path.isdir(base) else []
        got = []
        for run in runs:
            r = analyze_run(os.path.join(base, run))
            r["condition"] = cond
            got.append(r)
            rows.append(r)
            print("%-13s %-5s fps=%-5s kbps_app=%-5s kbps_ss=%-6s max=%-5s p99=%-5s >100=%-3s stall=%-5s "
                  "rto=%s/%s retr=%s lost=%s cwnd=%-3s q=%-6s q95=%-5s bl=%-5s e2e=%-5s/%-5s exc=%s/%s under=%s conc=%s chain=%s" % (
                      cond, run, r["fps"], r["kbps_app"], r["kbps_ss"], r["gap_max"], r["gap_p99"],
                      r["gaps_over_100"], r["stalled_ms"], r["rto_med"], r["rto_max"], r["retrans"],
                      r["lost"], r["cwnd_min"], r["sendq_max"], r["queue95_med"], r["backlog_ms"],
                      r["e2e50_med"], r["e2e50_max"], r["excess_med"], r["excess_max"],
                      r["underrun"], r["concealed"], r["chain_broken"]))
        if got:
            def med(key):
                vals = [g[key] for g in got if isinstance(g.get(key), (int, float))]
                return round(statistics.median(vals), 1) if vals else None
            print("%-13s MED   fps=%s kbps_app=%s kbps_ss=%s max=%s p99=%s >100=%s stall=%s "
                  "retr=%s lost=%s cwnd=%s q=%s q95=%s bl=%s e2e=%s/%s exc=%s under=%s conc=%s chain=%s" % (
                      cond, med("fps"), med("kbps_app"), med("kbps_ss"), med("gap_max"),
                      med("gap_p99"), med("gaps_over_100"), med("stalled_ms"), med("retrans"),
                      med("lost"), med("cwnd_min"), med("sendq_max"), med("queue95_med"),
                      med("backlog_ms"), med("e2e50_med"), med("e2e50_max"), med("excess_med"),
                      med("underrun"), med("concealed"), med("chain_broken")))
    if rows:
        keys = ["condition", "work", "secs", "frames", "fps", "kbps_app", "target_kbps", "kbps_ss",
                "e2e50_med", "e2e50_max", "e2e95_max", "backlog_ms", "queue95_med", "queue95_max",
                "gap_max", "gap_p99", "gap_p50", "gaps_over_100", "stalled_ms", "rto_med", "rto_max",
                "retrans", "retrans_bytes", "lost", "cwnd_min", "sendq_max", "pulses",
                "excess_med", "excess_max", "underrun", "concealed", "audio_dropped", "late_p95",
                "chain_broken"]
        out = os.path.join(os.path.dirname(rows[0]["work"].rstrip("/")), "..", "losslab-runs.csv")
        with open(out, "w") as f:
            f.write(",".join(keys) + "\n")
            for r in rows:
                f.write(",".join(str(r.get(k, "")) for k in keys) + "\n")
        print("csv:", os.path.abspath(out))


if __name__ == "__main__":
    main()
