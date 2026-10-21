#!/usr/bin/env python3
"""The Deck's double-click zoom, from --debug-deck-zoom (e2e `deck`).

`NSWindow.zoom` is the path the title bar's double-click takes. A display link
samples the frames the window server draws during the zoom and the unzoom; a
frame time above the limit is a dropped frame the person feels, and the way back
is where the window shrinks and the grid lays itself out again.

Exit 0 when both p95 values are under the limit (ms, from nfr-limits.json).
"""
import json
import sys


def main(path, limit):
    try:
        root = json.load(open(path))
    except (OSError, ValueError) as error:
        print("no readable measurement: %s" % error)
        return 1
    limit = float(limit)
    problems = []
    # The grid's own layout passes: one per display frame was the stutter's
    # cause (the width went straight into the grid's state). A coalesced grid
    # takes it a few times per zoom, plus the settle.
    relayouts = int(root.get("relayouts", 0))
    frames = sum(int((root.get(phase) or {}).get("frames", 0)) for phase in ("zoom", "unzoom"))
    budget = max(12, frames // 3)
    if relayouts > budget:
        problems.append("%d grid relayouts for %d frames (budget %d): the grid re-lays out every frame"
                        % (relayouts, frames, budget))
    for phase in ("zoom", "unzoom"):
        data = root.get(phase) or {}
        p95 = float(data.get("p95", 0))
        if p95 <= 0:
            problems.append("%s: no frames sampled" % phase)
        elif p95 > limit:
            problems.append("%s p95 %.0f ms > %.0f ms (p50 %.0f, max %.0f, settle %.0f, %d frames)"
                            % (phase, p95, limit, float(data.get("p50", 0)),
                               float(data.get("max", 0)), float(data.get("settleMax", 0)),
                               int(data.get("frames", 0))))
        # A freeze in the settle is still a freeze: one frame may lag, not half a second.
        elif float(data.get("settleMax", 0)) > 120:
            problems.append("%s settles with a %.0f ms frame"
                            % (phase, float(data.get("settleMax", 0))))
    if problems:
        print("; ".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
