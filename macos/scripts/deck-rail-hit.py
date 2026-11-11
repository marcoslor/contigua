#!/usr/bin/env python3
"""The rail's hit column against its letters (DECK-34), from the probes.

`deckrailslots` reports the letters' drawn column and the rect the rail's
pointer takes (the view's own `RailHit`). DECK-34: the hit rect is the letters'
column widened by at most 4 pt each side, so the strip right of the letters is
the grid's — no hover, no press, no jump, no emphasis.

usage: deck-rail-hit.py rect FILE
       deck-rail-hit.py state FILE away|hovering|dragging
       deck-rail-hit.py none FILE            (an emphasis dump, state none)
       deck-rail-hit.py nopick FILE SINCE    (a grid dump: no pick, no accent)
       deck-rail-hit.py picked FILE SINCE LETTER

Exit 0 on success, prints one line; otherwise prints the reason and exits 1.
"""
import json
import sys
import time

PADDING = 4


def fail(message):
    print(message)
    sys.exit(1)


def load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError) as error:
        fail("cannot read %s: %s" % (path, error))


def load_lines(path):
    try:
        return [json.loads(line) for line in open(path) if line.strip()]
    except (OSError, ValueError) as error:
        fail("cannot read %s: %s" % (path, error))


def main(argv):
    mode, path = argv[0], argv[1]

    if mode == "rect":
        data = load(path)
        letters, hit = data.get("letters"), data.get("hit")
        if not letters or not hit:
            fail("the rail dump has no letters/hit rect")
        for side, wanted in (("left", letters["left"] - PADDING),
                             ("right", letters["right"] + PADDING),
                             ("top", letters["top"] - PADDING),
                             ("bottom", letters["bottom"] + PADDING)):
            if side in ("left", "top"):
                bad = hit[side] < wanted - 0.001
            else:
                bad = hit[side] > wanted + 0.001
            if bad:
                fail("the hit %s is %.2f, the letters' %s is %.2f: more than %d pt apart"
                     % (side, hit[side], side, letters[side], PADDING))
        print("letters %.1f..%.1f x %.1f..%.1f, hit %.1f..%.1f x %.1f..%.1f"
              % (letters["left"], letters["right"], letters["top"], letters["bottom"],
                 hit["left"], hit["right"], hit["top"], hit["bottom"]))
        return 0

    if mode == "state":
        data = load(path)
        expected = argv[2]
        if data.get("state") != expected:
            fail("the rail's pointer is %r, wanted %r" % (data.get("state"), expected))
        print("the rail's pointer is %s" % expected)
        return 0

    if mode == "none":
        data = load(path)
        if data.get("state") != "none":
            fail("the emphasis is %r/%r, wanted none"
                 % (data.get("state"), data.get("letter")))
        print("the emphasis is none")
        return 0

    if mode == "nopick":
        since = int(argv[2])
        lines = load_lines(path)[since:]
        picks = [line["rail"] for line in lines if "rail" in line]
        if picks:
            fail("the pointer made the rail jump: %r" % picks[-1])
        accents = [line["railAccent"] for line in lines if "railAccent" in line]
        if accents:
            fail("the pointer changed the accent: %r" % accents[-1])
        print("no pick and no accent change after the pointer")
        return 0

    if mode == "picked":
        since = int(argv[2])
        letter = argv[3]
        deadline = time.time() + 5
        while time.time() < deadline:
            lines = load_lines(path)[since:]
            picks = [line["rail"] for line in lines if "rail" in line]
            if any(pick.get("letter") == letter for pick in picks):
                accents = [line["railAccent"] for line in lines if "railAccent" in line]
                if accents and accents[-1].get("letter") == letter:
                    print("the glyph click picked %s (index %s)"
                          % (letter, next(p.get("index") for p in picks
                                          if p.get("letter") == letter)))
                    return 0
            time.sleep(0.1)
        fail("the glyph click on %s did not pick it" % letter)

    fail("unknown mode %r" % mode)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
