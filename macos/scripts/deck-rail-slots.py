#!/usr/bin/env python3
"""The rail's drawn slots from `control deckrailslots` (e2e `deck`, DECK-7).

The app writes one JSON line in the rail's own points: the pitch, the rail's and
the container's heights, the pointer's state and y, the frozen span's top and
bottom, the tag's letter, and each slot's scale, y/height and glyph box. This
checks what the frozen span must hold:

  gaps         every gap is equal to every other and within 1 pt of the rest
               gap (pitch - 11 pt)
  frozen:REF   A's slot top and #'s slot bottom are REF's, to 0.01 pt
  centre       the slot under the pointer has the largest scale, and the tag
               names the letter drawn there
  centre:N     the drawn glyph centre of the Nth letter (0 = A), for the
               pointer
  clip         every slot and every glyph is inside the content inset
  rest         away, with every slot a rest box at the drawn pitch
  tag:X        the tag names X (tag:none when nothing shows)
  motion-off   effective Reduce Motion is off

usage: deck-rail-slots.py FILE gaps|frozen:REF|centre|centre:INDEX|clip|rest|
                            tag:LETTER|tag:none|motion-off
"""

import json
import sys

LETTER_BOX = 11.0
NAMES = [chr(ord("A") + i) for i in range(26)] + ["#"]


def fail(message):
    print(message)
    sys.exit(1)


def load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError) as error:
        fail("no rail slots: %s" % error)


def main():
    if len(sys.argv) != 3:
        fail("usage: deck-rail-slots.py FILE gaps|frozen:REF|centre|clip|rest|tag:LETTER")
    data = load(sys.argv[1])
    mode = sys.argv[2]
    slots = data.get("slots") or []
    if not slots:
        fail("the rail has no slots")
    pitch = data["pitch"]
    rail = data["railHeight"]
    container = data["containerHeight"]
    total = sum(slot["height"] for slot in slots)
    if abs(total - rail) > 0.5 and data.get("state") == "away":
        fail("the slots sum to %.1f, not the rail's %.1f" % (total, rail))
    if abs(rail - len(slots) * pitch) > 0.5:
        fail("%d slots at %.1f pt do not make the rail's %.1f" % (len(slots), pitch, rail))

    if mode == "gaps":
        gaps = [slot["height"] - LETTER_BOX * slot["scale"] for slot in slots]
        rest = pitch - LETTER_BOX
        spread = max(gaps) - min(gaps)
        if spread > 0.05:
            fail("the gaps are not equal: %.2f pt apart (%.2f..%.2f)"
                 % (spread, min(gaps), max(gaps)))
        if abs(gaps[0] - rest) > 1.0:
            fail("the gap is %.2f pt, not the rest gap's %.2f +/- 1" % (gaps[0], rest))
        print("%d equal gaps of %.2f pt (rest %.2f, spread %.2f)"
              % (len(gaps), gaps[0], rest, spread))
        return

    if mode.startswith("frozen:"):
        other = load(mode.split(":", 1)[1])
        mine = data["slots"]
        theirs = other.get("slots") or []
        if not theirs:
            fail("no slots in the reference")
        for name, index, offset in (("A's top", 0, "y"),
                                    ("# 's bottom", -1, "bottom")):
            def value(entry):
                slot = entry[index]
                return slot["y"] if offset == "y" else slot["y"] + slot["height"]
            if abs(value(mine) - value(theirs)) > 0.01:
                fail("%s moved: %.3f, was %.3f" % (name, value(mine), value(theirs)))
        print("A's top %.2f and #'s bottom %.2f are the enter's"
              % (mine[0]["y"], mine[-1]["y"] + mine[-1]["height"]))
        return

    if mode.startswith("centre:"):
        # The drawn glyph centre of one letter (its index in the alphabet), in
        # the rail's points: where a visible run puts the pointer.
        try:
            index = int(mode.split(":", 1)[1])
        except ValueError:
            fail("centre takes a letter's index")
        slot = [s for s in slots if s["first"] <= index < s["first"] + s["letters"]]
        if not slot:
            fail("no slot holds index %d" % index)
        s = slot[0]
        band = min(s["letters"] - 1, max(0, index - s["first"]))
        step = (s["glyphBottom"] - s["glyphTop"]) / s["letters"]
        print("%.3f" % (s["glyphTop"] + (band + 0.5) * step))
        return

    if mode == "centre":
        y = data.get("y", -1)
        under = [slot for slot in slots if slot["y"] <= y < slot["y"] + slot["height"]]
        if not under:
            fail("no drawn slot under the pointer at y %.2f" % y)
        slot = under[0]
        largest = max(s["scale"] for s in slots)
        if slot["scale"] < largest - 0.0001:
            fail("the slot under the pointer is at %.2fx, not the centre's %.2fx"
                 % (slot["scale"], largest))
        within = min(0.999999, max(0.0, (y - slot["y"]) / slot["height"]))
        band = min(slot["letters"] - 1, max(0, int(within * slot["letters"])))
        letter = NAMES[slot["first"] + band]
        if data.get("tag") != letter:
            fail("the tag names %s, not the drawn %s" % (data.get("tag"), letter))
        print("the slot under %.2f is %s at %.2fx, the largest; the tag names it"
              % (y, letter, slot["scale"]))
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

    if mode == "rest":
        if data.get("state") != "away":
            fail("the rail is not at rest: %s" % data.get("state"))
        if data.get("tag") is not None:
            fail("the tag shows %s at rest" % data.get("tag"))
        for index, slot in enumerate(slots):
            if abs(slot["height"] - pitch) > 0.01 or abs(slot["scale"] - 1) > 0.001:
                fail("slot %d is %.2f pt at %.2fx, not the rest %.2f pt"
                     % (index, slot["height"], slot["scale"], pitch))
        print("%d rest slots at %.2f pt, no tag" % (len(slots), pitch))
        return

    if mode == "motion-off":
        if data.get("reduceMotion"):
            fail("effective Reduce Motion is still on")
        print("effective Reduce Motion is off")
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

    fail("usage: deck-rail-slots.py FILE gaps|frozen:REF|centre|clip|rest|tag:LETTER")


if __name__ == "__main__":
    main()
