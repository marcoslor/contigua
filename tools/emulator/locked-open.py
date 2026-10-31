#!/usr/bin/env python3
"""One app window on a locked, screen-off phone: the locked-open check's driver.

Opens `window.open` for a package, times the first frame, taps the app through
the session's own input path (a real touch on the stream, the way the Mac sends
one) and reports what the picture did. The shell script around it reads the
phone's own logcat for the platform's verdict (a display that started asleep, an
input sink with no channel), so this file only ever speaks the protocol.

    locked-open.py --state <deckctl state> --host 127.0.0.1 --port <port> \
        --pkg com.android.settings --w 640 --h 480 --dpi 160 \
        --tap-after 3,5 --seconds 18 [--adb <adb> --serial <serial>]

Prints one `key=value` line per fact and exits 0 when the session ran; the
shell decides pass or fail. `--self-test` checks the gap and tap arithmetic on
fixtures, no device.

Why the log markers: the phone's logcat is the only clock both the phone and
this process share. Before each tap the driver writes `PocketDeckLockedOpen tapN`
and after the first frame `PocketDeckLockedOpen first-frame`; the shell then
reads that log in order, so "the tap opened a screen" and "the take-over ran
before the launch" are ordering facts, not clock comparisons between machines.
"""
import subprocess
import sys
import time

sys.path.insert(0, "tools/fakephone")

import deckctl  # noqa: E402
import proto  # noqa: E402

TAG = "PocketDeckLockedOpen"


def frame_gaps(times):
    """Consecutive-frame gaps in ms -> (count, max, count over 1500)."""
    gaps = [round((b - a) * 1000.0) for a, b in zip(times, times[1:])]
    over = [g for g in gaps if g > 1500]
    return len(gaps), (max(gaps) if gaps else 0), len(over)


def parse_taps(text):
    """`"3,5"` -> [3.0, 5.0]; empty string -> []."""
    out = []
    for part in (text or "").split(","):
        part = part.strip()
        if not part:
            continue
        value = float(part)
        if value <= 0:
            raise ValueError("tap offsets must be positive")
        out.append(value)
    return out


def tap_due(first_at, sent, offset, fallback):
    """When tap `offset` is due: after the first frame, else after the open.

    A tap sent before the app has drawn would test the phone's queue, not the
    app's input channel; but a window that never draws is exactly what this
    check is for, so the tap still goes, `fallback` seconds after the open.
    """
    return (first_at + offset) if first_at is not None else (sent + offset + fallback)


def mark(adb, serial, what):
    """One logcat marker line, on the phone's own clock (best effort)."""
    if not adb:
        return
    try:
        subprocess.run(
            [adb, "-s", serial, "shell", "log", "-t", TAG, what],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=10, check=False,
        )
    except Exception:  # noqa: BLE001 - a marker is evidence, never a failure
        pass


def self_test():
    count, top, over = frame_gaps([0.0, 0.4, 0.9, 3.0, 3.5])
    assert count == 4 and top == 2100 and over == 1, (count, top, over)
    count, top, over = frame_gaps([1.0])
    assert count == 0 and top == 0 and over == 0, (count, top, over)
    assert parse_taps("3,5") == [3.0, 5.0]
    assert parse_taps("") == []
    try:
        parse_taps("0")
    except ValueError:
        pass
    else:
        raise AssertionError("a zero tap offset was accepted")
    # A tap waits for its first frame; with none it falls back from the open.
    assert tap_due(10.0, 0.0, 3.0, 2.0) == 13.0
    assert tap_due(None, 0.0, 3.0, 2.0) == 5.0
    print("SELF-TEST OK: frame gaps, tap offsets, tap due time")
    return 0


def main(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=False)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int)
    parser.add_argument("--pkg", default="com.android.settings")
    parser.add_argument("--w", type=int, default=640)
    parser.add_argument("--h", type=int, default=480)
    parser.add_argument("--dpi", type=int, default=160)
    parser.add_argument("--tap-after", default="3,5", help="seconds after the first frame")
    parser.add_argument("--seconds", type=float, default=18.0)
    parser.add_argument("--stream", type=int, default=1)
    parser.add_argument("--adb")
    parser.add_argument("--serial")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.state or not args.port:
        parser.error("--state and --port are needed for a run")

    state = deckctl.ClientState(args.state)
    taps = parse_taps(args.tap_after)
    client = deckctl.open_session(args.host, args.port, state, on_code=None)
    stream = args.stream

    sent = time.time()
    client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                      "dpi": args.dpi, "pkg": args.pkg})
    frame_times = []
    configs = 0
    opened = None
    config_at = None
    first_at = None
    deadline = sent + args.seconds
    # The tap schedule hangs off the first frame (see tap_due).
    pending = list(taps)
    try:
        while time.time() < deadline:
            frame = client.recv(max(0.05, deadline - time.time()))
            if frame is None:
                print("closed=1")
                return 2
            if frame is not deckctl.TIMEOUT:
                if frame.type == proto.TYPE_JSON:
                    msg = proto.unpack_json(frame)
                    if msg.get("t") == "error":
                        print("error=%s" % msg.get("code"))
                        return 2
                    if msg.get("t") == "window.opened":
                        opened = msg
                elif frame.type == proto.TYPE_VIDEO_CONFIG:
                    configs += 1
                    if config_at is None:
                        config_at = time.time()
                elif frame.type == proto.TYPE_VIDEO_FRAME:
                    now = time.time()
                    frame_times.append(now)
                    if first_at is None:
                        first_at = now
                        mark(args.adb, args.serial, "first-frame")
            while pending and time.time() >= tap_due(first_at, sent, pending[0], 2.0):
                index = len(taps) - len(pending) + 1
                mark(args.adb, args.serial, "tap%d" % index)
                # Settings' own list: two rows well inside the content area.
                y = 0.35 if index % 2 == 1 else 0.55
                client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, 0.5, y))
                client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, 0.5, y))
                pending.pop(0)
    finally:
        try:
            client.send_json({"t": "window.close", "stream": stream})
        except OSError:
            pass
        client.close()

    gaps, top, over = frame_gaps(frame_times)
    print("opened=%d" % (1 if opened else 0))
    print("display=%s" % (opened.get("displayId") if opened else "none"))
    print("configs=%d" % configs)
    print("config_ms=%s" % ("none" if config_at is None else round((config_at - sent) * 1000.0)))
    print("first_frame_ms=%s" % ("none" if first_at is None else round((first_at - sent) * 1000.0)))
    print("frames=%d" % len(frame_times))
    print("gaps=%d" % gaps)
    print("max_gap_ms=%d" % top)
    print("gaps_over_ms=%d" % over)
    print("taps_sent=%d" % (len(taps) - len(pending)))
    return 0 if first_at is not None else 2


if __name__ == "__main__":
    sys.exit(main())
