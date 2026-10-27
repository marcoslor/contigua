#!/usr/bin/env python3
"""The Deck's double-click zoom and drag-resize, from --debug-deck-zoom (e2e
`deck`, NFR `deck_zoom_frame_p95_ms`).

`NSWindow.zoom` is the path the title bar's double-click takes; the drag phase
is the same window resized in scripted steps, the way a person drags its edge.
A display link samples the frames the window server draws during each phase
(zoom, unzoom, drag). A frame time above the limit is a dropped frame the person
feels.

Every sampled frame also carries the grid as drawn (each cell's frame, the
grid's visible bounds, the width it was given). The frame must fit the width it
was drawn at: no cell outside the visible bounds, one inset on both sides, and
the column count that width asks for. A layout that lags the window (the
person's clipped edges during the way back) fails here by name.

Exit 0 when every phase keeps p95 under the limit and every drawn frame fits.
"""
import json
import math
import sys

PHASES = ("zoom", "unzoom", "drag")


def main(path, limit, drag_limit=None, visible="0"):
    try:
        root = json.load(open(path))
    except (OSError, ValueError) as error:
        print("no readable measurement: %s" % error)
        return 1
    limit = float(limit)
    # The drag is the person's own live resize, so it has the tighter limit:
    # before this branch's grid the drag p95 was 19 ms, and +2 ms is the bar.
    drag_limit = float(drag_limit) if drag_limit is not None else limit
    problems = []
    # A visible run draws on the person's own display: the window server
    # composites the resized window at that display's refresh rate, and for a
    # live resize it may take every other refresh (measured 2026-10-27 on the
    # e2e host at 60 Hz: refresh 16.67 ms, the app's own drag step p95 16-17 ms,
    # and the drag's frame p95 23 ms in one run, 33 ms — every other frame — in
    # the next, with no code change between them). Two intervals is therefore
    # the visible floor for this phase; the app's part (the step) is held to one
    # interval below, and the quiet limit is never changed.
    refresh = float(root.get("refreshMs") or 0)
    if visible == "1" and refresh > 0:
        drag_limit = max(drag_limit, math.ceil(refresh * 2))
        # The step's own cost: setFrame plus the window server's synchronous
        # draw. Measured 15.3-17.5 ms at 60 Hz; 4 ms of headroom, so a layout
        # or drawing regression still fails.
        step_p95 = float((root.get("drag") or {}).get("stepP95", 0))
        if step_p95 > refresh + 4:
            problems.append("drag step p95 %.1f ms > one %.1f ms display interval + 4 ms"
                            % (step_p95, refresh))
    summary = ("refresh %.1f ms" % refresh) if refresh > 0 else "refresh unknown"
    for phase in PHASES:
        data = root.get(phase) or {}
        phase_limit = drag_limit if phase == "drag" else limit
        p95 = float(data.get("p95", 0))
        if p95 <= 0:
            problems.append("%s: no frames sampled" % phase)
        elif p95 > phase_limit:
            problems.append("%s p95 %.0f ms > %.0f ms (p50 %.0f, max %.0f, settle %.0f, %d frames)"
                            % (phase, p95, phase_limit, float(data.get("p50", 0)),
                               float(data.get("max", 0)), float(data.get("settleMax", 0)),
                               int(data.get("frames", 0))))
        # A freeze in the settle is still a freeze: one frame may lag, not half a second.
        elif float(data.get("settleMax", 0)) > 120:
            problems.append("%s settles with a %.0f ms frame"
                            % (phase, float(data.get("settleMax", 0))))
        # The grid's drawn layout: every frame of the window's change, not just
        # the settled one. Few frames is a broken measurement, not a pass.
        measured = int(data.get("measured", 0))
        bad = int(data.get("badFrames", 0))
        if measured < 20:
            problems.append("%s: only %d frames carry the grid as drawn" % (phase, measured))
        elif bad:
            problems.append("%s: %d of %d drawn frames do not fit the width they were drawn at (%s)"
                            % (phase, bad, measured,
                               "; ".join(str(example) for example in (data.get("examples") or []))))
    drag = root.get("drag") or {}
    summary += (", drag step p95 %.1f ms, frames %s" % (float(drag.get("stepP95", 0)),
                                                        drag.get("histogram")))
    if problems:
        print("; ".join(problems) + " [" + summary + "]")
        return 1
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2],
                  sys.argv[3] if len(sys.argv) > 3 else None,
                  sys.argv[4] if len(sys.argv) > 4 else "0"))
