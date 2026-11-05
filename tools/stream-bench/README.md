# stream-bench — compare stream strategies run by run (ISS-40)

`bench.py` drives a **running** PocketDeck Mac app through its automation socket
with the same stdio shim `macos/scripts/mcp-driver.py` uses. It opens one app
window, runs the fixed script below, closes the window, and summarises that
run's `stats stream=…` lines with `macos/scripts/stats-summary.py`. One table
compares the arms; `--out` keeps every run as CSV.

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

1. `open_app` for `--package` (default `com.android.settings`), and wait for
   the first `stats` line for that window (the Mac logs one every 5 s while the
   window is visible).
2. The fixed script, through the app's own `swipe` MCP tool: 10 swipes at a
   steady pace (400 ms each), a 3 s still, 10 fast flings (150 ms each), a 3 s
   still.
3. `close_window`.
4. Read that run's `stats` lines with `stats-summary.py`.

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
  when it dials (N1's Mac side, `stream.net`). The bench never quits, relaunches
  or reconnects the app, so these arms are left out of the default run; pass
  `--include-restart-arms` when you will restart the app between runs.
- Every arm restores every key it set, after each run and again on exit — an
  interruption does not leave a strategy switched on.
- An arm naming a property no build reads still runs: setting it is a no-op
  and the counters simply don't change.
- Nothing else on the phone is written. The bench never runs `adb kill-server`.

The shipped arms are the ISS-40 switches: `baseline` (no properties), the Q1
and Q2 queue arms, R1's CBR, R2's two caps, R4's intra refresh, T1's refinement,
N1's traffic class (`n1-af41` on the phone, `n1-mac-video` on the Mac and
`n1-both` for both), the Mac's presentation and pixel switches (`m1-paced`,
`m2-panel`), and `combo-a` with all the phone ones. Each phone switch is read at
a stream's configure and logged as one `stream N strategy: …` line (logcat);
each Mac switch is read when a window opens (or resizes) and logged as one
`stream N mac strategy: …` line, so a run also proves what the app applied.

`n1-mac-video` and `n1-both` set `stream.net`, which the Mac reads once when a
session dials. Opening a new window does not dial, and there is no debug control
that reconnects a running app, so an interleaved run cannot apply it: restart
the app between those arms and pass `--include-restart-arms`. The phone side of
N1 (`tos`) has the same session-lifetime limit, since the phone applies it when
it accepts the session's socket.

## Repeats

`--repeats N` (default 3) runs the arms **interleaved** — A B C A B C — because
the link changes minute to minute; a whole arm at a time would compare two
different networks. A single run's value is the median of its `stats` lines,
except `freeze_n`, `freeze_ms` and `drop_ep`, which are summed over the lines
(a freeze is one event, not a per-line level). The table reports, per arm,
the median of its runs and their min–max.

```
arm        shown_fps   int_p99   freeze_n  ...
baseline   59.9 (…-…)  16.9 (…)  0.0 (…)
```

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

The fake phone's `swipe` moves nothing, but its encoder keeps producing frames,
so the table fills with real `shown_fps`, intervals and `int_p99`.
