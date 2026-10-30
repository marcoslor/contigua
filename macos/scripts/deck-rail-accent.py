#!/usr/bin/env python3
"""The rail's accent after a pick or a scroll, from --debug-deck-grid (e2e `deck`).

A quiet e2e run cannot click the rail, so `control deck-rail LETTER` runs the
rail's own scroll. The app reports the accent it draws (`railAccent`) with the
top row's letter and the machine's state. DECK-7: a pick settles holding the
letter it landed on — not the letter of the row it shares — until the grid is
scrolled by other means, and then the top row's letter is back.

usage: deck-rail-accent.py pick FILE LETTER [WAIT_S]
       deck-rail-accent.py top FILE SINCE [WAIT_S]

`SINCE` is the dump's line count before the scroll: only accents written after
it are read, so an old pick cannot pass for the new top row.

Exit 0 when the accent is the picked letter and settled (pick), or the top
row's letter again after a scroll (top). Prints one line on success, the reason
on failure.
"""
import json
import sys
import time


def load(path):
    try:
        return [json.loads(line) for line in open(path) if line.strip()]
    except FileNotFoundError:
        return []


def fresh(path, since, wait):
    """The newest accent written after line `since`."""
    deadline = time.time() + wait
    while time.time() < deadline:
        lines = load(path)
        accents = [line["railAccent"] for line in lines[min(since, len(lines)):]
                   if "railAccent" in line]
        if accents:
            return accents[-1]
        time.sleep(0.25)
    return None


def main(argv):
    mode, path = argv[0], argv[1]
    wait = 15.0
    if mode == "pick":
        letter = argv[2]
        if len(argv) > 3:
            wait = float(argv[3])
        # The landing is the first accent after the pick that settled.
        deadline = time.time() + wait
        while time.time() < deadline:
            lines = load(path)
            picks = [i for i, line in enumerate(lines)
                     if line.get("rail", {}).get("letter") == letter]
            if picks:
                landing = next((line["railAccent"] for line in lines[picks[-1] + 1:]
                                if line.get("railAccent", {}).get("state") == "picked"),
                               None)
                if landing is not None:
                    if landing.get("letter") != letter:
                        print("the pick on %s lit %r (its row is %r)"
                              % (letter, landing.get("letter"), landing.get("row")))
                        return 1
                    if landing.get("row") == letter:
                        print("the pick on %s shares its row's letter, so the row rule cannot see the bug"
                              % letter)
                        return 1
                    print("%s stays lit, its row is %s (top %s, %s columns)"
                          % (letter, landing.get("row"), landing.get("top"),
                             landing.get("columns")))
                    return 0
            time.sleep(0.25)
        lines = load(path)
        picks = [i for i, line in enumerate(lines)
                 if line.get("rail", {}).get("letter") == letter]
        last = None
        if picks:
            accents = [line["railAccent"] for line in lines[picks[-1] + 1:]
                       if "railAccent" in line]
            last = accents[-1] if accents else None
        print("no landing after the pick of %s; the accent is %r (%s)"
              % (letter, last.get("letter") if last else None,
                 last.get("state") if last else None))
        return 1

    since = int(argv[2])
    if len(argv) > 3:
        wait = float(argv[3])
    accent = fresh(path, since, wait)
    if accent is None:
        print("no accent after the scroll")
        return 1
    if accent.get("state") != "topRow":
        print("the accent is still %r (%s) at top %r, so the scroll did not hand it back"
              % (accent.get("letter"), accent.get("state"), accent.get("top")))
        return 1
    if accent.get("letter") != accent.get("row"):
        print("the accent is %r but the top row is %r"
              % (accent.get("letter"), accent.get("row")))
        return 1
    print("the top row's letter %s is back (top %s, %s columns)"
          % (accent.get("row"), accent.get("top"), accent.get("columns")))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[1] not in ("pick", "top"):
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
