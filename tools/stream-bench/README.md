# stream-bench — compare stream strategies run by run (ISS-40)

`bench.py` drives a **running** PocketDeck Mac app through its automation socket
with the same stdio shim `macos/scripts/mcp-driver.py` uses. It opens one app
window, runs the fixed script below, closes the window, and summarises that
run's **closing `stats total stream=…` line** itself. One table compares the
arms; `--out` keeps every run as CSV. `macos/scripts/stats-summary.py` still
summarises saved 5 s lines for a person reading a log; the bench no longer
needs it.

It never launches, quits or reconfigures the Mac app. Start the app (and turn
on Settings › Automation) first.

## Which profile reaches the person's app

**`--profile default`.** The person's installed app runs without `--profile`,
which is `Profile.default`: its support folder is `~/Library/Application
Support/PocketDeck` and its defaults domain is `dev.pocketdeck.mac` (not a
suffixed suite). `Profile.swift` has `defaultName = "default"`,
`supportDirectoryName` returns `PocketDeck` only for the default, and
`MCPAutomation.configSnippet` prints the shim command with no `--profile` for
it. The same file gives a named profile its own folder (`PocketDeck-<name>`)
and defaults suite (`dev.pocketdeck.mac.<name>`), which is what the e2e rigs
use (`--profile e2e`, `--profile stats`).

## Requirements

- Python 3.9 stdlib. The arm handling has a phone-free check:
  `python3 tools/stream-bench/test_bench.py`.
- `adb` on `PATH` (or `--adb PATH`); `--serial` is required and has no
  default. The bench refuses a serial that is not `device`.
- The shim at `/Applications/PocketDeck.app/Contents/Helpers/pocketdeck-mcp`, or
  `--shim PATH` for a built bundle.
- `/usr/bin/log` readable for the app's `dev.pocketdeck.mac` subsystem.

## One run

Before the first run the bench reads the app's PID from `ps` (the process whose
command starts with `Contents/MacOS/PocketDeck --profile <profile>`) and names
it in the `log show` predicate, so another PocketDeck process's lines never
mix in. It also refuses to start with `another window is open` when that app
logged a `stats stream=` line in the last 10 s: the person's own visible
window muddies every run.

1. `open_app` for `--package` (default `com.android.settings`), and wait for
   the first `stats` line for that window (the Mac logs one every 5 s while the
   window is visible).
2. The fixed script, through the app's own `swipe` MCP tool: 10 swipes at a
   steady pace (400 ms each), a 3 s still, 10 fast flings (150 ms each), a 3 s
   still. **Every swipe alternates direction** (up, down, up, …) in both the
   steady and the fling phase, so the list never rests at an end and the
   picture keeps moving.
3. `close_window`.
4. Wait for that run's closing `stats total stream=N …` line and score it (see
   Repeats). A run with no line in the timeout is marked **failed**; the bench
   goes on and still writes the table and the CSV.

## Arms

`arms.json` lists named arms:

```json
{"arms": [{"name": "baseline", "phone": {}, "mac": {}}]}
```

- `phone` keys become `debug.pocketdeck.stream.<key>` through
  `adb -s <serial> shell setprop` before the run. The previous value is read
  first and written back after the run (an empty value clears it).
- `mac` keys are written with `defaults write <domain> <key> <value>` and
  restored (or deleted when they did not exist) after the run. The domain is
  `dev.pocketdeck.mac` for the default profile, else
  `dev.pocketdeck.mac.<profile>`.
- An arm with `"restart": true` needs a fresh session for a key the app reads
  when it dials (N1's Mac side, `stream.net`) or the phone applies when it
  accepts the session's socket (N1's phone side, `tos`). The bench never quits,
  relaunches or reconnects the app, so these arms are left out of the default
  run; pass `--include-restart-arms` when you will restart the app between runs.
- Every arm restores every key it set, after each run and again on exit — an
  interruption does not leave a strategy switched on.
- An arm naming a property no build reads still runs: setting it is a no-op
  and the counters simply don't change.
- Nothing else on the phone is written. The bench never runs `adb kill-server`.

The shipped arms are the ISS-40 switches: `baseline` (no properties), the Q1
and Q2 queue arms, R1's CBR, R2's two caps, R4's intra refresh, T1's refinement,
N1's traffic class (`n1-af41` on the phone, `n1-mac-video` on the Mac and
`n1-both` for both), the Mac's presentation and pixel switches (`m1-paced`,
`m2-panel`), `combo-a` with the phone ones except `tos`, and the round-2 stall
arms. Each phone switch is read at a stream's configure and logged as one
`stream N strategy: …` line (logcat); each Mac switch is read when a window
opens (or resizes) and logged as one `stream N mac strategy: …` line, so a run
also proves what the app applied.

The stall arms make the link stall on demand: `stall` (400 ms every 5 s),
`stall-q1` (plus `overflow=suspend`), `stall-q1q2-100` (plus a 100 ms queue),
`stall-q2-500` (a 500 ms queue), `stall-paced` (plus the Mac's paced
presentation) and `stall-ir60` (plus intra refresh). The phone logs one
`stream N injected stall 400` line per pause. `--arms-filter stall` runs these
six alone; `--arms-filter stall-q` runs the three queue variants.

`n1-mac-video`, `n1-both` and `n1-af41` set `stream.net`/`tos`, which the app
and the phone read once when the session starts (dial and socket accept).
Opening a new window does not reconnect, and there is no debug control that
reconnects a running app, so an interleaved run cannot apply them: restart the
app between those arms and pass `--include-restart-arms`.

## Repeats and the table

`--repeats N` (default 3) runs the arms **interleaved** — A B C A B C — because
the link changes minute to minute; a whole arm at a time would compare two
different networks. The table reports, per arm, the median of its runs and their
min–max.

What makes a run feel janky is the picture stopping **while the phone's content
moves**. Three causes are counted and added into one pair of numbers:

- `hitch_n` / `hitch_ms` (Mac): a frame handed to the display layer more than
  50 ms after its capture step (`late = shown gap − pts gap`), and how late.
  A still is no hitch: the heartbeat's pts gap matches its shown gap.
- `drop_ep` / `drop_ms` (phone): a send-queue drop episode, and the pts span
  from the last frame before it to the keyframe that ends it, less one frame.
  An older phone prints `drop_ms=-`; the bench counts it as 0 and marks the run
  `(no drop_ms)`.
- `susp_n` / `susp_ms` (phone): Q1's encoder-suspend episodes and their time.

Per run:

```
jank_n = hitch_n + drop_ep + susp_n
jank_ms = hitch_ms + drop_ms + susp_ms
```

Both come from the closing totals line and cover the window's whole life:
5 s samples and a config never reset them. `shown_fps` is `shown_frames` over
the run's active time (`secs` minus `covered_ms`), `late_p99` is every shown
frame, `kbps` is `bytes × 8 / secs`, and `kf` totals keyframes. **The totals
have no phases**, so there is no swipe/fling filter any more; a run that moved
too little shows up as low-motion below instead.

**`qp_p95` is the one sampled number**: a level, not a counter, and the totals
line has none. It is the median over the 5 s lines that folded in a phone
message (`phone_n ≥ 1`); a line with no message is no sample.

A run is marked **`low-motion`** (in the table and as `low_motion=1` in the CSV)
when `rx_frames / secs` is under 20: the content did not move, so the run cannot
compare strategies. A run is marked **`frozen`** (in the table and as
`frozen=1` in the CSV) when the totals' `max_gap_ms` is over 2,500: the picture
was gone for longer than that across the run, so its low jank score is an
accident, not a win. The totals cover the whole life, so a gap that falls
between two 5 s lines still counts. A log from before the field existed keeps
the older rule (a 5 s line in a swipe phase with `rx_fps < 10`). A run with
`covered_ms > 0` is
marked **`covered`**. `failed`, `covered`, `frozen` and `low-motion` runs are
all left out of the arm's medians, and the table's `valid` column says how many
runs made them. A run with no closing line is **`failed`**; its cells are `-`
and the table and CSV are still written. `phone gaps` marks a run that received
no phone message at all (`phone_n=0`), and `no drop_ms` a phone that sends no
`dropGapMs`. The phone's own `stream N totals:` line carries `susp_ms` too, and
counts a suspend still open at close.

```
arm                 valid   jank_ms    jank_n   hitch_ms    drop_ms   susp_ms   late_p99  ...
stall                  2    310 (…-…)  5 (…-…)  110 (…-…)   150 (…-…)  50 (…-…)  283 (…-…)
stall-q1 (frozen)      0      -          -         -           -         -          -
```

Two columns read the connection's own counter deltas from the totals:
`tcp_ooo_kb` (the Mac's out-of-order bytes over the run, the receiver's trace
of a hole TCP is holding) and `ph_retrans` (the phone's system-wide
retransmitted segments over the run). `key_not_idr` is the Mac's count of
frames the phone flagged key whose units held no IDR, and `ph_key_not_idr` is
the phone's own count from its messages; both are NAL-type counts, never bytes.
A run with either above 0 has a resuming frame a decoder cannot restart on, and
the field log names its types (`stream N key nal=6,1`).

Under the table, each arm gets one **resend block**, over all its 5 s lines:

```
baseline   hitch lines with resends 7/12   clean lines with resends 2/40   no phone message: 1
```

A **hitch line** has `hitch_n ≥ 1`; a **clean line** has `hitch_n = 0` and
moving content (`rx_fps ≥ 20`); a line is **with resends** when
`ph_retrans ≥ 1` or `tcp_ooo_kb > 0`. That block is X0: if hitch lines carry
resends far more often than clean motion does, TCP's head-of-line blocking is
behind the hitches. Lines that folded in no phone message are left out of both
counts and reported as `no phone message`; a phone that could not read its
`/proc/net` files contributes no resend, so its clean/hitch rates read lower.

The CSV (`--out`) has every run with the same fields plus `failed`, `covered`,
`frozen`, `secs`, `rx_frames`, `shown_frames`, `phone_frames`, `kf_req`,
`bytes`, `covered_ms`, `max_gap_ms`, `tcp_ooo_kb`, `tcp_srtt_max`, `ph_retrans`,
`ph_rto`, `ph_lost`, `low_motion`, `no_drop_ms` and `phone_gaps`.

## Usage

```sh
tools/stream-bench/bench.py --profile default --serial R58M1234 \
    --repeats 3 --out .agent/stats/bench.csv
```

`arms.json` ships every strategy arm. To compare them all, run three repeats
(interleaved) so the link's minute-to-minute changes average out:

```sh
tools/stream-bench/bench.py --profile stats --serial R58M1234 \
    --repeats 3 --out .agent/strat/bench.csv
```

The table prints one row per arm. With `--repeats 1` it is a smoke test that
every switch applies, not a comparison.

To run only the stall arms (the reviewer's round-2 list):

```sh
tools/stream-bench/bench.py --profile stats --serial emulator-5554 \
    --arms-filter stall --repeats 1 --out .agent/stats/stall.csv
```

`--arms-filter <prefix>` keeps the arms whose name starts with the prefix,
before the restart-arm filter.

## Host proof without a phone

The bench's phone-property path only needs an adb that answers `get-state` for
the serial; the scripts in `tools/` document the fake-phone proof:

```sh
# a stub adb for host runs; the real bench path is unchanged
cat > /tmp/fake-adb <<'EOF'
#!/bin/sh
case "$*" in
  *"get-state"*) echo device ;;
  *"getprop"*) echo "" ;;
esac
EOF
chmod +x /tmp/fake-adb

tools/stream-bench/bench.py --profile stats --serial fake-phone \
    --adb /tmp/fake-adb --repeats 2 --out /tmp/bench.csv \
    --shim macos/build/e2e/PocketDeck.app/Contents/Helpers/pocketdeck-mcp
```

The fake phone's `swipe` moves nothing, but its encoder keeps producing frames
at 60 fps, so the swipe/fling lines still see `rx_fps ≥ 30` and none of those
runs is marked `low-motion`; the table fills with real `shown_fps`, `late_p99`
and the jank counters. Start it with `--no-backlog-restart`: otherwise every
cleared sender backlog rebuilds its encoder, and each rebuild resets the Mac's
2 s stats window around a new config, so the table reads zero frames.
