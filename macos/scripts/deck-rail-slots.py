#!/usr/bin/env python3
"""The rail's drawn slots from `control deckrailslots` (e2e `deck`, DECK-7).

The app writes one JSON line in the rail's own points: the pitch, the rail and
container heights, the state and the tag's letter, and each slot's y/height with
its glyph box. This checks the three things the spacing must hold:

  gaps   the whitespace above and below M is the pure function's 17.7 pt, and
         the slots still fill the rail
  clip   every slot and every glyph is inside the content inset
  tag:X  the tag names X (tag:none when nothing shows)

usage: deck-rail-slots.py FILE gaps|clip|tag:LETTER|tag:none
"""

import json
import sys


def fail(message):
    print(message)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        fail("usage: deck-rail-slots.py FILE gaps|clip|tag:LETTER")
    try:
        data = json.load(open(sys.argv[1]))
    except (OSError, ValueError) as error:
        fail("no rail slots: %s" % error)
    mode = sys.argv[2]
    slots = data.get("slots") or []
    if not slots:
        fail("the rail has no slots")
    pitch = data["pitch"]
    rail = data["railHeight"]
    container = data["containerHeight"]
    total = sum(slot["height"] for slot in slots)
    if abs(total - rail) > 0.5:
        fail("the slots sum to %.1f, not the rail's %.1f" % (total, rail))
    if abs(rail - len(slots) * pitch) > 0.5:
        fail("%d slots at %.1f pt do not make the rail's %.1f" % (len(slots), pitch, rail))

    if mode == "gaps":
        by_index = {slot["first"]: slot for slot in slots}
        m, l, n = by_index.get(12), by_index.get(11), by_index.get(13)
        if not m or not l or not n:
            fail("no M/L/N slots")
        above = m["glyphTop"] - l["glyphBottom"]
        below = n["glyphTop"] - m["glyphBottom"]
        for name, gap in (("above", above), ("below", below)):
            if abs(gap - 17.7) > 1.0:
                fail("the gap %s M is %.1f pt, not 17.7 +/- 1" % (name, gap))
        print("pitch %.1f, gaps above/below M %.1f/%.1f pt, slots sum %.1f"
              % (pitch, above, below, total))
        return

    if mode == "clip":
        slack = (container - rail) / 2
        if slack < 0:
            fail("the rail is taller than its content (%.1f > %.1f)" % (rail, container))
        low = min(min(s["y"], s["glyphTop"]) for s in slots)
        high = max(max(s["y"] + s["height"], s["glyphBottom"]) for s in slots)
        if low < -slack - 0.5 or high > rail + slack + 0.5:
            fail("a slot reaches %.1f..%.1f, the clip is %.1f..%.1f"
                 % (low, high, -slack, rail + slack))
        print("%d slots inside the clip (%.1f..%.1f); reach %.1f..%.1f, slack %.1f"
              % (len(slots), -slack, rail + slack, low, high, slack))
        return

    if mode.startswith("tag:"):
        want = mode.split(":", 1)[1]
        got = data.get("tag")
        if want == "none":
            if got is not None:
                fail("the tag shows %s where it must not" % got)
            print("no tag (%s)" % data.get("state"))
        else:
            if got != want:
                fail("the tag names %s, not %s" % (got, want))
            print("tag names %s" % got)
        return

    fail("usage: deck-rail-slots.py FILE gaps|clip|tag:LETTER")


if __name__ == "__main__":
    main()
