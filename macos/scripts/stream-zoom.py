#!/usr/bin/env python3
"""A live stream window's double-click zoom and drag-resize, from
--debug-stream-zoom (e2e `zoom`, NFR `stream_zoom_frame_p95_ms`).

Every phase must keep the display-link frame time at or under the NFR limit,
and the zoom must be handled like a live resize: the window takes its new
shape while the last frame fills it (no black band, no letterbox jump), and the
phone is asked for the new size once, at the end, not on every animation step.

The `window.resize` requests are the fake phone's own event log (`ev:rx`),
correlated with the phase's wall-clock window: what the phone received, not
what the app meant to send.
"""

import json
import sys

USAGE = "usage: stream-zoom.py REPORT.json EVENTS.jsonl LIMIT_MS"


def events_between(path, start, end):
    resizes = []
    try:
        handle = open(path, errors="replace")
    except OSError:
        return resizes
    with handle:
        for line in handle:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("ev") != "rx":
                continue
            msg = event.get("msg") or {}
            if msg.get("t") != "window.resize":
                continue
            when = event.get("ts", 0)
            if start <= when <= end:
                resizes.append((msg.get("w"), msg.get("h"), msg.get("dpi")))
    return resizes


def phase_line(name, phase, resizes):
    return (
        "%s p95=%sms steps=%s frames=%s windowSteps=%s drawnSteps=%s modeChanges=%s%s "
        "gapMax=%s settle95=%sms resizes=%s"
        % (
            name,
            phase.get("p95"),
            phase.get("steps"),
            phase.get("framesDuringSteps"),
            phase.get("windowSteps"),
            phase.get("drawnSteps"),
            phase.get("modeChanges"),
            "(%s)" % ",".join(phase.get("modes") or []),
            phase.get("gapMax"),
            phase.get("settleP95"),
            ",".join("%sx%s" % (w, h) for w, h, _ in resizes) or "none",
        )
    )


def main(argv):
    if len(argv) != 4:
        print(USAGE, file=sys.stderr)
        return 2
    report_path, events_path, limit_text = argv[1], argv[2], argv[3]
    limit = float(limit_text)
    with open(report_path) as handle:
        report = json.load(handle)

    failed = False
    lines = []

    for name in ("zoom", "unzoom", "drag"):
        phase = report.get(name)
        if not phase:
            lines.append("%s missing from the report" % name)
            failed = True
            continue
        resizes = events_between(events_path, phase["startedAt"], phase["endedAt"])
        lines.append(phase_line(name, phase, resizes))
        # A sanity check both ways: a window that never changed size or never
        # drew a frame would pass every other rule by measuring nothing.
        if phase.get("windowSteps", 0) < 8 or phase.get("steps", 0) < 8:
            lines.append("%s did not resize enough to measure (%s steps, %s size changes)"
                         % (name, phase.get("steps"), phase.get("windowSteps")))
            failed = True
        if float(phase.get("p95", 0)) > limit:
            lines.append("%s p95 %s ms is over %s ms" % (name, phase.get("p95"), limit_text))
            failed = True
        if phase.get("gapFrames", 0) > 0:
            lines.append("%s showed a black band for %s frames (max %s px)"
                         % (name, phase.get("gapFrames"), phase.get("gapMax")))
            failed = True

    for name in ("zoom", "unzoom"):
        phase = report.get(name) or {}
        if not phase:
            continue
        resizes = events_between(events_path, phase["startedAt"], phase["endedAt"])
        # WIN-37: at most one request in flight and one waiting; a zoom that
        # is handled like a live resize asks once, when it ends.
        # The picture must keep arriving while the window animates: AppKit's
        # own zoom animation holds the main run loop for its life, and no
        # decoded frame reaches the display layer until it ends.
        if phase.get("framesDuringSteps", 0) < 5:
            lines.append("%s froze the picture while animating (%s frames)"
                         % (name, phase.get("framesDuringSteps")))
            failed = True
        if len(resizes) > 1:
            lines.append("%s sent %d window.resize requests, not one at the end"
                         % (name, len(resizes)))
            failed = True
        if phase.get("modeChanges", 0) > 1:
            lines.append("%s jumped between letterbox and fill %d times"
                         % (name, phase.get("modeChanges")))
            failed = True

    print("\n".join(lines))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
