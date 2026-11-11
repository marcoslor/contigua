#!/usr/bin/env python3
"""Part A tables: the installed app's own 5 s stats lines (numbers only)."""
import re
import statistics
import sys
import collections

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/stream-lines.txt"
KV = re.compile(r"(\w+)=(-?[\d.]+|-)")
ROW = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+).*\[dev\.contigua\.mac:video\] stats stream=(\d+) (.*)$")


def load(path):
    rows = []
    for line in open(path, errors="replace"):
        m = ROW.match(line)
        if not m:
            continue
        d = {"ts": m.group(1), "stream": int(m.group(2)),
             "pid": re.search(r"Contigua\[(\d+)", line).group(1)}
        for k, v in KV.findall(m.group(3)):
            d[k] = None if v == "-" else float(v)
        rows.append(d)
    return rows


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def dist(label, rows, key):
    xs = [r.get(key) for r in rows if r.get(key) is not None]
    if not xs:
        return f"{label} {key}: n=0"
    return (f"{label} {key}: n={len(xs)} med={statistics.median(xs):.0f} "
            f"p90={pct(xs, 90):.0f} max={max(xs):.0f}")


rows = load(PATH)
hit = [r for r in rows if (r.get("hitch_n") or 0) > 0]
hit_ms = sum(r.get("hitch_ms") or 0 for r in hit)
print(f"windows={len(rows)}  hitch windows={len(hit)}  hitches={sum(r.get('hitch_n') or 0 for r in hit):.0f}  "
      f"hitch_ms={hit_ms:.0f}")

rto = [r for r in hit if (r.get("ph_rto") or 0) > 0]
nor = [r for r in hit if (r.get("ph_rto") or 0) == 0]
for label, sel in (("RTO>0", rto), ("RTO=0", nor)):
    print(f"\n{label}: windows={len(sel)} of hitch windows "
          f"({100*len(sel)/len(hit):.0f}%)")
    for key in ("max_gap_ms", "hitch_ms", "hitch_n", "freeze_ms", "queue_p95", "tcp_srtt", "ph_retrans"):
        print("  " + dist(label, sel, key))

rto_ms = sum(r.get("hitch_ms") or 0 for r in rto)
print(f"\nshare of hitch_ms in RTO windows: {rto_ms:.0f}/{hit_ms:.0f} = {100*rto_ms/hit_ms:.1f}%")
print(f"share of ph_rto in RTO windows: {sum(r.get('ph_rto') or 0 for r in rows):.0f} total, "
      f"{sum(r.get('ph_rto') or 0 for r in rto):.0f} in hitch windows")
print(f"windows with ph_rto>0 (all): {sum(1 for r in rows if (r.get('ph_rto') or 0)>0)} of {len(rows)}; "
      f"of those, with a hitch: {sum(1 for r in rows if (r.get('ph_rto') or 0)>0 and (r.get('hitch_n') or 0)>0)}")

qhi = [r for r in hit if (r.get("queue_p95") or 0) >= 100]
print(f"\nqueue_p95>=100 among hitch windows: {len(qhi)} windows, "
      f"{sum(r.get('hitch_ms') or 0 for r in qhi):.0f} ms = "
      f"{100*sum(r.get('hitch_ms') or 0 for r in qhi)/hit_ms:.0f}% of hitch time; "
      f"RTO>0 in {sum(1 for r in qhi if (r.get('ph_rto') or 0)>0)} of them")
qlo = [r for r in hit if (r.get("queue_p95") or 0) < 100]
print(f"queue_p95<100 among hitch windows: {len(qlo)} windows, "
      f"{sum(r.get('hitch_ms') or 0 for r in qlo):.0f} ms = "
      f"{100*sum(r.get('hitch_ms') or 0 for r in qlo)/hit_ms:.0f}%; "
      f"RTO>0 in {sum(1 for r in qlo if (r.get('ph_rto') or 0)>0)}")

clu = [r for r in rows if 500 <= (r.get("max_gap_ms") or 0) <= 520]
print(f"\nmax_gap 500-520: {len(clu)} windows; rx_fps of those: "
      f"med={statistics.median([r.get('rx_fps') or 0 for r in clu]):.1f} "
      f"max={max(r.get('rx_fps') or 0 for r in clu):.1f}; "
      f"windows with rx_fps<=10: {sum(1 for r in clu if (r.get('rx_fps') or 0)<=10)}/{len(clu)}")
print("  values:", sorted({int(r["max_gap_ms"]) for r in clu}))
print("  rx_fps:", [round(r.get("rx_fps") or 0, 1) for r in clu])

tot = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+).*stats total (.*)$")
print("\ntotals with max_gap 490-520:")
for line in open(sys.argv[2] if len(sys.argv) > 2 else "data/total-lines.txt", errors="replace"):
    m = tot.match(line)
    if not m:
        continue
    d = {k: (None if v == "-" else float(v)) for k, v in KV.findall(m.group(2))}
    if d.get("max_gap_ms") and 490 <= d["max_gap_ms"] <= 520:
        print(f"  {m.group(1)[5:]} secs={d.get('secs'):.0f} gap={d['max_gap_ms']:.0f} "
              f"rx={d.get('rx_frames'):.0f} shown={d.get('shown_frames'):.0f} "
              f"hitch_n={d.get('hitch_n'):.0f} covered={d.get('covered_ms'):.0f} kf={d.get('kf'):.0f}")
