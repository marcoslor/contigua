#!/usr/bin/env python3
"""Read one locked-multi run: display states and the phone log's facts.

`dumpsys display` gives each logical display a `Display <id>:` block with
`mState=`; the virtual displays created by the session are logical displays too.
The log facts are the episode's own lines and SurfaceFlinger's physical power
mode writes, plus the driver's `PocketDeckLockedMulti` markers.

    locked-multi-read.py --state <dump> <displayId>
    locked-multi-read.py --facts <logcat> <display1> <display2>
    locked-multi-read.py --self-test
"""

import re
import sys

TAG = "PocketDeckLockedMulti"
INDEX_STATES = {0: "OFF", 1: "ON", 2: "DOZE", 3: "DOZE_SUSPEND", 4: "ON_SUSPEND"}
SF_MODE = re.compile(r"Setting power mode (\d+) on physical display")
# logcat's `MM-DD HH:MM:SS.mmm`; parsed by hand because a day without a year is
# ambiguous to strptime on newer Pythons (and only differences matter here).
STAMP = re.compile(r"^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d\d\d)")


def display_state(text, display_id):
    """The logical display's state, or UNKNOWN when its block is not there."""
    parts = re.split(r"(?m)^\s*Display (\d+):\s*$", text)
    for i in range(1, len(parts), 2):
        if int(parts[i]) != int(display_id):
            continue
        body = parts[i + 1]
        m = re.search(r"mState=([A-Z_]+)", body)
        if m:
            return "ON" if m.group(1) == "ON_SUSPEND" else m.group(1)
        m = re.search(r"mDisplayStates=\[([0-9,\t ]+)\]", body)
        if m:
            values = [v.strip() for v in m.group(1).split(",") if v.strip()]
            if values:
                return INDEX_STATES.get(int(values[0]), "UNKNOWN")
    return "UNKNOWN"


def stamp(line):
    """Seconds since an arbitrary epoch: only differences between lines matter."""
    m = STAMP.match(line)
    if not m:
        return None
    day, hour, minute, second, millis = (int(m.group(i)) for i in range(2, 7))
    return ((day * 24 + hour) * 60 + minute) * 60 + second + millis / 1000.0


def facts(lines, display1, display2):
    def marker(name):
        for i, line in enumerate(lines):
            if TAG in line and line.rstrip().endswith(name):
                return i
        return None

    one = marker("one-open")
    two = marker("two-open")
    tap = marker("tap")
    resume = marker("one-resume")
    settled = marker("settled")
    takeover = next((i for i, l in enumerate(lines) if "power: episode take-over:" in l), None)
    end = settled if settled is not None else len(lines)

    def between(a, b):
        if a is None or b is None:
            return []
        return list(range(a + 1, b))

    # A release at the second open is the bug: count from the first window.
    window = between(one, end)
    released = [i for i in window if "display wake lock released (display %s)" % display1 in lines[i]]
    sleeps = [i for i in window if "phone back to sleep after the last stream" in lines[i]]
    panel_on = [i for i in between(takeover, end) if "power: panel ON ->" in lines[i]]
    keepalive = [i for i in between(resume, end)
                 if "keepalive step" in lines[i] and "displayLocks=1" in lines[i]]

    modes = [(i, int(m.group(1))) for i, line in enumerate(lines) for m in [SF_MODE.search(line)] if m]
    take_modes = [(i, mode) for i, mode in modes if takeover is not None and i > takeover]
    lit_ms = -1
    on_again = 0
    first_on = next((k for k, (_, mode) in enumerate(take_modes) if mode == 2), None)
    if first_on is not None:
        first_off = next((k for k in range(first_on + 1, len(take_modes)) if take_modes[k][1] == 0), None)
        if first_off is not None:
            a = stamp(lines[take_modes[first_on][0]])
            b = stamp(lines[take_modes[first_off][0]])
            if a is not None and b is not None:
                lit_ms = int(round((b - a) * 1000.0))
            on_again = sum(1 for _, mode in take_modes[first_off + 1:] if mode == 2)

    return {
        "one_marker": one if one is not None else -1,
        "two_marker": two if two is not None else -1,
        "takeover_marker": takeover if takeover is not None else -1,
        "released_while_open": len(released),
        "sleeps_while_open": len(sleeps),
        "panel_on_after_takeover": len(panel_on),
        "panel_off_writes": sum(1 for l in lines if "panel power mode -> OFF" in l),
        "lit_ms": lit_ms,
        "on_again_after_off": on_again,
        "keepalive_locks1_after_resume": len(keepalive),
        "sink_lines": sum(1 for l in lines if "NO_INPUT_CHANNEL" in l),
        "tap_started": 1 if any("START u0" in lines[i] for i in between(tap, settled)) else 0,
    }


FIXTURE_DISPLAY = """Logical Displays: size=2
  Display 0:
    mDisplayId=0
    mState=OFF
  Display 69:
    mDisplayId=69
    mState=ON
  Display 70:
    mDisplayId=70
    mState=OFF
"""

FIXTURE_LOG = """11-01 12:30:25.886 I/PocketDeckSvc(10429): stream 7 vd=70 1792x1200 dpi=319
11-01 12:30:25.890 I/PocketDeckLockedMulti: one-open
11-01 12:30:25.891 I/PocketDeckLockedMulti: one-paused
11-01 12:30:25.892 I/PocketDeckLockedMulti: two-open
11-01 12:30:25.893 I/PocketDeckSvc(10429): display wake lock released (display 69)
11-01 12:30:25.894 I/PocketDeckSvc(10429): display wake lock held (display 70, SCREEN_BRIGHT, display-scoped)
11-01 12:30:25.900 I/PocketDeckSvc(10429): power: episode take-over: display 70 woken before the launch; panel off owed
11-01 12:30:25.955 D/SurfaceFlinger( 1872): Setting power mode 2 on physical display 42
11-01 12:30:26.454 D/SurfaceFlinger( 1872): Setting power mode 0 on physical display 42
11-01 12:30:29.694 I/PocketDeckSvc(10429): power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=false)
11-01 12:30:30.000 I/PocketDeckLockedMulti: tap
11-01 12:30:50.560 I/PocketDeckLockedMulti: two-close
11-01 12:30:50.560 I/PocketDeckLockedMulti: one-resume
11-01 12:30:50.546 I/PocketDeckSvc(10429): phone back to sleep after the last stream
11-01 12:30:51.560 I/PocketDeckSvc(10429): keepalive step 2 interval=2000ms displayLocks=1
11-01 12:30:53.570 I/ActivityManager( 2328): START u0 {cmp=com.android.settings/.Settings}
11-01 12:30:53.580 W/InputDispatcher( 2328): Not sending touch gesture to x ActivityRecordInputSink com.android.settings because it has config NO_INPUT_CHANNEL
11-01 12:30:53.590 I/PocketDeckLockedMulti: settled
11-01 12:30:53.600 I/PocketDeckLockedMulti: closed
"""


def self_test():
    assert display_state(FIXTURE_DISPLAY, 0) == "OFF"
    assert display_state(FIXTURE_DISPLAY, 69) == "ON"
    assert display_state(FIXTURE_DISPLAY, 70) == "OFF"
    assert display_state(FIXTURE_DISPLAY, 71) == "UNKNOWN"
    got = facts(FIXTURE_LOG.splitlines(), 69, 70)
    assert got["released_while_open"] == 1, got
    assert got["sleeps_while_open"] == 1, got
    assert got["panel_on_after_takeover"] == 1, got
    assert got["lit_ms"] == 499, got
    assert got["on_again_after_off"] == 0, got
    assert got["keepalive_locks1_after_resume"] == 1, got
    assert got["sink_lines"] == 1 and got["tap_started"] == 1, got
    assert got["one_marker"] == 1 and got["two_marker"] == 3, got
    print("SELF-TEST OK: display blocks, markers, wake releases, sleeps, panel lines, SurfaceFlinger window")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) == 4 and argv[1] == "--state":
        with open(argv[2], "r", encoding="utf-8", errors="replace") as fp:
            print(display_state(fp.read(), int(argv[3])))
        return 0
    if len(argv) == 5 and argv[1] == "--facts":
        with open(argv[2], "r", encoding="utf-8", errors="replace") as fp:
            lines = fp.read().splitlines()
        for key, value in facts(lines, argv[3], argv[4]).items():
            print("%s=%s" % (key, value))
        return 0
    print(__doc__.strip().splitlines()[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
