#!/usr/bin/env python3
"""The Deck rail's click, from --debug-deck-grid (e2e `deck`).

A quiet e2e run cannot point at the rail, so `control deck-rail LETTER` runs the
same scroll the rail's click runs. The app reports the pick (letter and index)
and the row it landed on (railTop); the cell dump says which index the letter's
first app really has.

usage: deck-rail.py FILE LETTER [WAIT_S]

Exit 0 when the pick's index is that letter's first app and its row is on
screen. Prints one line on success, the reason on failure.
"""
import json
import sys
import time


def load(path):
    try:
        return [json.loads(line) for line in open(path) if line.strip()]
    except FileNotFoundError:
        return []


def files_under(label, letter):
    """The rail's bucketing: first letter A-Z, anything else under #."""
    label = label.strip()
    if not label:
        return letter == "#"
    first = label[0].upper()
    return first == letter if letter != "#" else not ("A" <= first <= "Z")


def main(path, letter, wait):
    deadline = time.time() + wait
    lines = []
    while time.time() < deadline:
        lines = load(path)
        picks = [(i, line["rail"]) for i, line in enumerate(lines)
                 if line.get("rail", {}).get("letter") == letter]
        if picks:
            index, pick = picks[-1]
            tops = [line["railTop"] for line in lines[index + 1:] if "railTop" in line]
            if tops:
                break
        time.sleep(0.25)
    else:
        print("no rail pick/landing yet")
        return 1

    cells = [line for line in lines if "items" in line][-1]["items"]
    expected = next((i for i, item in enumerate(cells)
                     if files_under(item.get("label", ""), letter)), None)
    if expected is None:
        print("the app list has no app under %s" % letter)
        return 1
    if pick.get("index") != expected:
        print("the pick scrolled to index %s, the first %s app is %d"
              % (pick.get("index"), letter, expected))
        return 1
    top = tops[-1].get("index")
    geometries = [line for line in lines if "cap" in line]
    columns = geometries[-1].get("columns", 1) if geometries else 1
    if not (top <= expected < top + columns):
        print("index %d is not on the row at %s (%d columns)"
              % (expected, top, columns))
        return 1
    top_letter = cells[top].get("label", "?").strip()[:1].upper() or "#"
    print("%s is index %d, its row starts at %d (%d columns, top letter %s)"
          % (letter, expected, top, columns, top_letter))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    wait = float(sys.argv[3]) if len(sys.argv) > 3 else 15
    sys.exit(main(sys.argv[1], sys.argv[2], wait))
