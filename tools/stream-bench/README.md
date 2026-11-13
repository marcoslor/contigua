# stream-bench — compare stream strategies run by run (ISS-40)

`bench.py` drives a **running** Contigua Mac app through its automation socket
with the same stdio shim `macos/scripts/mcp-driver.py` uses. It opens one app
window, runs one named script (default: the fixed swipe script below), closes
the window, and summarises that run's **closing `stats total stream=…` line**
itself. One table compares the arms; `--out` keeps every run as CSV.
`macos/scripts/stats-summary.py` still summarises saved 5 s lines for a person
reading a log; the bench no longer needs it.

It never launches, quits or reconfigures the Mac app. Start the app (and turn
on Settings › Automation) first.

## Which profile reaches the person's app

**`--profile default`.** The person's installed app runs without `--profile`,
which is `Profile.default`: its support folder is `~/Library/Application
Support/Contigua` and its defaults domain is `app.contigua.mac` (not a
suffixed suite). `Profile.swift` has `defaultName = "default"`,
`supportDirectoryName` returns `Contigua` only for the default, and
`MCPAutomation.configSnippet` prints the shim command with no `--profile` for
it. The same file gives a named profile its own folder (`Contigua-<name>`)
and defaults suite (`app.contigua.mac.<name>`), which is what the e2e rigs
use (`--profile e2e`, `--profile stats`).

## Requirements

- Python 3.9 stdlib. The parsers and the arm handling have phone-free checks:
  `python3 tools/stream-bench/test_phone.py` and
  `python3 tools/stream-bench/test_bench.py`.
- `adb` on `PATH` (or `--adb PATH`); `--serial` is required and has no
  default. The bench refuses a serial that is not `device`.
- The shim at `/Applications/Contigua.app/Contents/Helpers/contigua-mcp`, or
  `--shim PATH` for a built bundle.
- `--app PATH` brings that bundle to the front after each window opens. The
  phone pauses a stream whose Mac window is hidden, so a run on a window
  behind another app measures a still picture; activation is best effort and
  such a run is marked `low_motion`/`frozen`, never given a fake number.
- `/usr/bin/log` readable for the app's `app.contigua.mac` subsystem.

## One run

Before the first run the bench reads the app's PID from `ps` (the process whose
command starts with `Contents/MacOS/Contigua --profile <profile>`) and names
it in the `log show` predicate, so another Contigua process's lines never
mix in. It also refuses to start with `another window is open` when that app
logged a `stats stream=` line in the last 10 s: the person's own visible
window muddies every run.

1. `open_app` for `--package` (default `com.android.settings`), and wait for
   the first `stats` line for that window (the Mac logs one every 5 s while the
   window is visible).
2. The selected `--script` (default `swipe`): 10 swipes at a steady pace
   (400 ms each), a 3 s still, 10 fast flings (150 ms each), a 3 s still.
   **Every swipe alternates direction** (up, down, up, …) in both the steady
   and the fling phase, so the list never rests at an end and the picture keeps
   moving.
3. `close_window`.
4. Wait for that run's closing `stats total stream=N …` line and score it (see
   Repeats). A run with no line in the timeout is marked **failed**; the bench
   goes on and still writes the table and the CSV.

## Scripts

`--script` picks one of six named scripts. Only `swipe` moves a list; the
others isolate one stage, one input path or a long run, so their columns are
comparable to the same stage in a swipe run.

| `--script` | What it does | Why |
| --- | --- | --- |
| `swipe` (default) | Today's exact sequence: 10 steady swipes, a 3 s still, 10 fast flings, a 3 s still, every swipe alternating direction. No call or pause differs from the pre-`--script` bench. | The strategy comparison the table was built for |
| `still` | Opens the app, sends no input and holds for `--still-seconds` (default 6). | First-frame and resize baselines, settled picture, panel rate, phone idle health |
| `typing` | Taps the opened app's search field at `--typing-point` (default `0.5,0.08`) and types `contigua bench typing` through the app's own `type_text` tool, then holds 3 s. | Key input without a swipe; the text is a fixed bench string, never a person's |
| `video` | Taps `--video-point` (default `0.5,0.5`) and plays for `--video-seconds` (default 8). | Decoder and display work on moving video rather than a scrolling list |
| `soak` | Swipes continuously for `--soak-minutes` (default 20), one swipe per `--sample-seconds` (default 10) period, and writes one phone sample row per period. | Phone health over time: thermals, battery, CPU, PSS and Wi-Fi |
| `tap` | Calls the Mac's `input_probe` tool once with `--tap-point` (default `0.5,0.5`) and records its `changed_ms` as `input_photon_ms` and `frames` as `input_frames`. | Input-to-photon, the number a person feels |

The `tap` script needs a Mac build with the `input_probe` tool. A build without
it does not crash the table: the run is marked **failed** and its log says
`no input_probe tool`, while the other runs and the CSV are still written.

`soak` writes `<out>.samples.csv` beside the run CSV. Its header is
`at, repeat, arm, sample_seconds, app_fps, app_jank_pct, vd_hz,
battery_level, battery_temp_c, thermal_status, thermal_max_c, app_cpu_pct,
shell_cpu_pct, app_pss_kb, shell_pss_kb, wifi_rssi_dbm, wifi_mbps, wifi_mhz,
wifi_retries, wifi_bad`; one row per sample period, and the run's own row uses
the medians of those samples.

## Arms

`arms.json` lists named arms:

```json
{"arms": [{"name": "baseline", "phone": {}, "mac": {}}]}
```

- `phone` keys become `debug.contigua.stream.<key>` through
  `adb -s <serial> shell setprop` before the run. The previous value is read
  first and written back after the run (an empty value clears it).
- `mac` keys are written with `defaults write <domain> <key> <value>` and
  restored (or deleted when they did not exist) after the run. The domain is
  `app.contigua.mac` for the default profile, else
  `app.contigua.mac.<profile>`.
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

The shipped arms are the ISS-40 switches: `baseline` (no properties), C1's HEVC
arm (`c1-hevc`, `codec=hevc`), the Q1
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
presentation), `stall-ir60` (plus intra refresh) and `stall-hevc` (plus C1's
HEVC). The phone logs one
`stream N injected stall 400` line per pause. `--arms-filter stall` runs these
seven alone; `--arms-filter stall-q` runs the three queue variants.

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
frame, `kbps` is the phone's `bytes × 8 / secs`, `rx_kbps` is the Mac's own
received frame bytes × 8 / secs, `codec` is the stream's codec, and `kf` totals
keyframes. **The totals have no phases**, so there is no swipe/fling filter any
more; a run that moved too little shows up as low-motion below instead.

**`qp_p95` is the one sampled QP level**: a level, not a counter, and the
totals line has none. It is the median over the 5 s lines that folded in a phone
message (`phone_n ≥ 1`); a line with no message is no sample. The totals line
does carry `qp_avg`, the phone's frame-weighted mean over the window's whole
life (`-` when the encoder reported none), and the table shows it as one more
column. `codec` is a name (`avc`/`hevc`), so its column prints the arm's codec
rather than a median.

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
all left out of the arm's medians (a `tap` run counts: its idle screen is the
measurement), and the table's `valid` column says how many runs made them. A run with no closing line is **`failed`**; its cells are `-`
and the table and CSV are still written. `phone gaps` marks a run that received
no phone message at all (`phone_n=0`), and `no drop_ms` a phone that sends no
`dropGapMs`. The phone's own `stream N totals:` line carries `susp_ms` too, and
counts a suspend still open at close.

```
arm                 valid codec  jank_ms    jank_n   hitch_ms    drop_ms   susp_ms   late_p99  ...
stall                  2   avc   310 (…-…)  5 (…-…)  110 (…-…)   150 (…-…)  50 (…-…)  283 (…-…)
stall-q1 (frozen)      0   avc     -          -         -           -         -          -
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
`ph_rto`, `ph_lost`, `low_motion`, `no_drop_ms` and `phone_gaps`. The table's
`codec`, `qp_avg` and `rx_kbps` are columns too, so a C1 row says which codec
produced the numbers and what rate the Mac actually received.

The new run columns are appended after those, in this order:
`script`, `input_photon_ms`, `input_frames`, `first_frame_ms`, `resize_ms`,
`app_fps`, `app_jank_pct`, `vd_hz`, `battery_level`, `battery_temp_c`,
`thermal_status`, `thermal_max_c`, `app_cpu_pct`, `shell_cpu_pct`,
`app_pss_kb`, `shell_pss_kb`, `wifi_rssi_dbm`, `wifi_mbps`, `wifi_mhz`,
`wifi_retries`, `wifi_bad`. A missing measurement is an empty cell, never a
zero.

## What each stage number means

The table gains three stage columns after the long-standing ones:

- `app_fps` — frames the streamed app's own UI rendered per second, from
  `dumpsys gfxinfo <package> framestats` after the run. The bench resets that
  counter before the run, samples while the app is still alive (before the
  window closes), and computes the rate over that interval.
- `vd_hz` — the refresh rate of the mirror's virtual display (the phone names
  it `contigua-N`, a `virtual:` display) from `dumpsys display`; the panel
  the VD mirrors is not the stream's rate. `--display-id N` reads a physical
  `local:N` instead. A device that does not print a rate is `-`.
- `input_photon_ms` — the `tap` script's `changed_ms`: send to the first
  displayed frame that changed in the probed region. `input_frames` is how many
  displayed-frame samples the probe saw.

After the resend block the bench prints one **phone** line per arm: medians of
battery level and temperature, thermal status and the hottest reported
temperature, the streamed app's CPU share and Contigua's, both PSS totals,
and RSSI / link speed / frequency / tx retries / tx bad. The sampler is
read-only: `dumpsys gfxinfo` (reset before, framestats after), `dumpsys
display`, `dumpsys battery`, `dumpsys thermalservice`, `dumpsys cpuinfo`,
`dumpsys meminfo` for the app and for `app.contigua`, and `dumpsys wifi`. It
never runs `settings put`, `cmd wifi`, a wake, an input event outside the app
window, a screenshot, `adb kill-server` or a `setprop` of its own. The Wi-Fi
parser returns numeric link facts only: the SSID, BSSID, IP and MAC never
reach the CSV.

The last block is **stages**, one line per arm:

```
stage          encoder        app    network    display      panel       int_p50 ...
baseline    600.0 (…-…)   59.0 (…-…)  60.0 (…-…)  59.0 (…-…)  60.0 (…-…)
```

`encoder` is the phone's `phone_frames` over the run's `secs` (its
output fps), `app` the app's own `app_fps`,
`network` the Mac's `rx_fps`, `display` its `shown_fps` and `panel` the
`vd_hz`. `int_p50/int_p95/int_p99` are the arrival interval and
`shown_p50/shown_p95/shown_p99` the display interval levels; they stay `-`
until a Mac build logs them on the closing totals line. Failed and covered runs
are left out of these medians; low-motion and frozen runs stay because a still
or a dead picture is exactly the stage being measured.

## Usage

```sh
tools/stream-bench/bench.py --profile default --serial R58M1234 \
    --repeats 3 --out .work/stats/bench.csv
```

`arms.json` ships every strategy arm. To compare them all, run three repeats
(interleaved) so the link's minute-to-minute changes average out:

```sh
tools/stream-bench/bench.py --profile stats --serial R58M1234 \
    --repeats 3 --out .work/strat/bench.csv
```

The table prints one row per arm. With `--repeats 1` it is a smoke test that
every switch applies, not a comparison.

To run only the stall arms (the reviewer's round-2 list):

```sh
tools/stream-bench/bench.py --profile stats --serial emulator-5554 \
    --arms-filter stall --repeats 1 --out .work/stats/stall.csv
```

`--arms-filter <prefix>` keeps the arms whose name starts with the prefix,
before the restart-arm filter.

A first-frame baseline and a one-minute soak need no arm comparison:

```sh
tools/stream-bench/bench.py --profile stats --serial emulator-5554 \
    --script still --repeats 1 --out .work/stats/still.csv
tools/stream-bench/bench.py --profile stats --serial emulator-5554 \
    --script soak --soak-minutes 1 --sample-seconds 10 \
    --repeats 1 --out .work/stats/soak.csv
```

`--dry-run` prints the chosen script, the arms and the repeat count without
touching adb, the Mac app or the log.

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
    --shim macos/build/e2e/Contigua.app/Contents/Helpers/contigua-mcp
```

The fake phone's `swipe` moves nothing, but its encoder keeps producing frames
at 60 fps, so the swipe/fling lines still see `rx_fps ≥ 30` and none of those
runs is marked `low-motion`; the table fills with real `shown_fps`, `late_p99`
and the jank counters. Start it with `--no-backlog-restart`: otherwise every
cleared sender backlog rebuilds its encoder, and each rebuild resets the Mac's
2 s stats window around a new config, so the table reads zero frames.
