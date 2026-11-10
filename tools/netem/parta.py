#!/usr/bin/env python3
"""Part A: parse the installed app's `stats stream=` 5 s lines (numbers only)."""
import re, statistics, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "data/stream-lines.txt"
KV = re.compile(r"(\w+)=(-?[\d.]+|-)")

def load(path):
    rows = []
    for line in open(path, errors="replace"):
        m = re.match(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+).*\[dev\.pocketdeck\.mac:video\] stats stream=(\d+) (.*)$", line)
        if not m:
            continue
        d = {"ts": m.group(1), "stream": int(m.group(2)), "pid": re.search(r"PocketDeck\[(\d+)", line).group(1)}
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

rows = load(PATH)
print(f"windows={len(rows)} pids={sorted({r['pid'] for r in rows})}")
hit = [r for r in rows if (r.get("hitch_n") or 0) > 0]
print(f"hitch windows={len(hit)}  hitch_n total={sum(r.get('hitch_n') or 0 for r in hit):.0f}  hitch_ms total={sum(r.get('hitch_ms') or 0 for r in hit):.0f}")

def show(label, sel, key):
    xs = [r.get(key) for r in sel if r.get(key) is not None]
    if not xs:
        return f"{label}: n=0"
    return (f"{label}: n={len(xs)} med={statistics.median(xs):.0f} p90={pct(xs,90):.0f} "
            f"max={max(xs):.0f} sum={sum(xs):.0f}")

for selname, sel in (("RTO>0", [r for r in hit if (r.get("ph_rto") or 0) > 0]),
                     ("RTO=0", [r for r in hit if (r.get("ph_rto") or 0) == 0])):
    print(f"--- hitch windows {selname}: n={len(sel)}")
    for k in ("max_gap_ms", "hitch_ms", "hitch_n", "freeze_ms", "queue_p95", "tcp_srtt", "tcp_rttvar", "ph_retrans", "ph_lost", "kbps", "target_kbps"):
        print("   ", show(k, sel, k))

hit_ms = sum(r.get("hitch_ms") or 0 for r in hit)
rto_ms = sum(r.get("hitch_ms") or 0 for r in hit if (r.get("ph_rto") or 0) > 0)
print(f"share of hitch_ms in RTO windows: {rto_ms:.0f}/{hit_ms:.0f} = {100*rto_ms/hit_ms:.1f}%" if hit_ms else "no hitch ms")

# max_gap_ms cluster 500-519
clu = [r for r in rows if 500 <= (r.get("max_gap_ms") or 0) <= 519]
print(f"max_gap 500-519 ms: n={len(clu)} of {len(rows)}  (hitch in these: {sum(1 for r in clu if (r.get('hitch_n') or 0)>0)})")
print("  ts:", ", ".join(r["ts"].split()[1][:8] for r in clu[:20]), "..." if len(clu) > 20 else "")
# how many exactly 503-514
clu2 = [r for r in rows if 503 <= (r.get("max_gap_ms") or 0) <= 514]
print(f"max_gap 503-514 ms: n={len(clu2)}; distinct values: {sorted({int(r['max_gap_ms']) for r in clu2})}")

# Queue p95 vs gaps
print("\nqueue_p95 buckets vs max_gap:")
for lo, hi in ((0, 50), (50, 150), (150, 300), (300, 10000)):
    sel = [r for r in rows if r.get("queue_p95") is not None and lo <= r["queue_p95"] < hi]
    if sel:
        print(f"  q {lo}-{hi}: n={len(sel)} max_gap med={statistics.median([r['max_gap_ms'] for r in sel if r.get('max_gap_ms') is not None]):.0f} "
              f"hitch_ms sum={sum(r.get('hitch_ms') or 0 for r in sel):.0f}")

# Top 10 windows by hitch_ms
print("\ntop hitch windows:")
for r in sorted(hit, key=lambda r: -(r.get("hitch_ms") or 0))[:10]:
    print(f"  {r['ts']} s{r['stream']} hitch_n={r['hitch_n']:.0f} hitch_ms={r['hitch_ms']:.0f} max_gap={r['max_gap_ms']} ph_rto={r.get('ph_rto')} ph_retrans={r.get('ph_retrans')} srtt={r.get('tcp_srtt')} q95={r.get('queue_p95')} kbps={r.get('kbps')}")

# Max gap distribution all windows
allmg = [r["max_gap_ms"] for r in rows if r.get("max_gap_ms") is not None]
print(f"\nall windows max_gap: n={len(allmg)} med={statistics.median(allmg):.0f} p90={pct(allmg,90):.0f} p99={pct(allmg,99):.0f} max={max(allmg):.0f}")
