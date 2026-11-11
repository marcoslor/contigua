#!/usr/bin/env python3
"""The rail's emphasis on the Deck's tiles, from `control deckrailemph` (DECK-32).

The app writes one JSON object after a pointer phase: the emphasis machine's
state and every page tile's drawn emphasis (the value the view applied, not a
recomputation). The check proves what the person sees:

  none                    the machine is at rest and every tile is at rest; a
                          hover is this mode (hover alone lights nothing)
  pressed:C source:B      the button is down on the empty B, whose jump lands
                          on C: the machine lights C, every All Apps tile filed
                          under C is lifted (1.08x, semibold, opaque) and every
                          other All Apps tile is dimmed (30%, regular); the
                          Open on this Mac and Pinned tiles are at rest
  lingering:C source:C    the same tiles after a click's release: the click's
                          emphasis stays for its 1000 ms

The entry transition is 0.12 s and the exit 0.2 s; the dump carries the
duration the machine chose, so a green run also pins the timing.

usage: deck-rail-emphasis.py FILE none [duration:SECS]
       deck-rail-emphasis.py FILE pressed:LETTER [source:POINTER]
       deck-rail-emphasis.py FILE lingering:LETTER [source:POINTER]
"""

import json
import sys

SECTIONS = ("open", "pinned", "all")
LIFT_SCALE = 1.08
DIM_OPACITY = 0.3
ENTER = 0.12
EXIT = 0.2


def fail(message):
    print(message)
    sys.exit(1)


def load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError) as error:
        fail("no emphasis dump: %s" % error)


def near(value, wanted, tolerance=0.001):
    try:
        return abs(float(value) - wanted) <= tolerance
    except (TypeError, ValueError):
        return False


def tiles_of(data, section=None):
    tiles = data.get("tiles") or []
    return [tile for tile in tiles if section is None or tile.get("section") == section]


def check_rest(tile):
    where = "%s %s" % (tile.get("section"), tile.get("label"))
    if tile.get("emphasis") != "rest":
        fail("%s should be at rest, is %r" % (where, tile.get("emphasis")))
    if not near(tile.get("opacity"), 1):
        fail("%s should be opaque, is %r" % (where, tile.get("opacity")))
    if not near(tile.get("scale"), 1):
        fail("%s should be at its drawn size, is %r" % (where, tile.get("scale")))


def check_lit(data, letter, state):
    if data.get("state") != state or data.get("letter") != letter:
        fail("the machine names %r/%r, wanted the %s letter %s"
             % (data.get("state"), data.get("letter"), state, letter))
    if not near(data.get("duration"), ENTER):
        fail("the entry should run 0.12 s, the machine chose %r" % data.get("duration"))

    tiles = tiles_of(data)
    all_apps = tiles_of(data, "all")
    if not all_apps:
        fail("no All Apps tiles in the dump")
    expected = [tile for tile in all_apps if tile.get("letter") == letter]
    if not expected:
        fail("no All Apps tile is filed under the emphasised letter %s" % letter)
    lifted = [tile for tile in all_apps if tile.get("emphasis") == "lift"]
    if {tile.get("id") for tile in lifted} != {tile.get("id") for tile in expected}:
        fail("the lifted tiles are not exactly All Apps' %s tiles (%d lifted, %d expected)"
             % (letter, len(lifted), len(expected)))
    for tile in lifted:
        if not near(tile.get("opacity"), 1):
            fail("%s is lifted but not opaque (%r)" % (tile.get("label"), tile.get("opacity")))
        if not near(tile.get("scale"), LIFT_SCALE):
            fail("%s is lifted at %r, wanted 1.08" % (tile.get("label"), tile.get("scale")))
        if tile.get("weight") != "semibold":
            fail("%s is lifted with %r, wanted a semibold label"
                 % (tile.get("label"), tile.get("weight")))
    for tile in all_apps:
        if tile.get("letter") == letter:
            continue
        if tile.get("emphasis") != "dim":
            fail("%s is not of %s but is %r, wanted dim"
                 % (tile.get("label"), letter, tile.get("emphasis")))
        if not near(tile.get("opacity"), DIM_OPACITY):
            fail("%s is dimmed at %r, wanted 0.30"
                 % (tile.get("label"), tile.get("opacity")))
        if not near(tile.get("scale"), 1):
            fail("%s is dimmed but scaled to %r" % (tile.get("label"), tile.get("scale")))
        if tile.get("weight") != "regular":
            fail("%s is dimmed with %r, wanted a regular label"
                 % (tile.get("label"), tile.get("weight")))

    for section in ("open", "pinned"):
        cells = tiles_of(data, section)
        if not cells:
            fail("the page has no %s tiles to prove untouched" % section)
        for tile in cells:
            check_rest(tile)

    print("%d All Apps tiles lifted (%.2fx, semibold) and %d dimmed (%.0f%%); "
          "%d open and %d pinned tiles at rest; %s, entry %.2f s"
          % (len(lifted), LIFT_SCALE, len(all_apps) - len(lifted), DIM_OPACITY * 100,
             len(tiles_of(data, "open")), len(tiles_of(data, "pinned")), state, ENTER))


def main(path, mode, source=None, duration=None):
    data = load(path)
    tiles = tiles_of(data)
    if not tiles:
        fail("the emphasis dump has no tiles")
    bad_sections = sorted({tile.get("section") for tile in tiles} - set(SECTIONS))
    if bad_sections:
        fail("a tile has an unknown section: %r" % bad_sections)

    if mode == "none":
        if data.get("state") != "none":
            fail("the rail should be at rest, the machine says %r" % data.get("state"))
        if duration is not None and not near(data.get("duration"), duration):
            fail("the leave should run %.2f s, the machine chose %r"
                 % (duration, data.get("duration")))
        for tile in tiles:
            check_rest(tile)
        event = (data.get("event") or "").split("(", 1)[0]
        print("%d tiles all at rest after %s (%.2f s out)"
              % (len(tiles), event, duration if duration is not None else EXIT))
        return

    if ":" not in mode or mode.split(":", 1)[0] not in ("pressed", "lingering"):
        fail("unknown mode %r" % mode)
    state, letter = mode.split(":", 1)
    if source is not None and data.get("pointer") != source:
        fail("the pointer should be on %s, the dump says %r"
             % (source, data.get("pointer")))
    check_lit(data, letter, state)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        fail(__doc__)
    source = None
    duration = None
    for arg in sys.argv[3:]:
        if arg.startswith("source:"):
            source = arg.split(":", 1)[1]
        elif arg.startswith("duration:"):
            duration = float(arg.split(":", 1)[1])
        else:
            fail("unknown option %r" % arg)
    main(sys.argv[1], sys.argv[2], source, duration)
