#!/usr/bin/env python3
"""The last rail pick in the grid dump (DECK-7's real click).

usage: deck-rail-pick.py GRID_DUMP LETTER
"""

import json
import sys


def main():
    if len(sys.argv) != 3:
        print("usage: deck-rail-pick.py GRID_DUMP LETTER")
        return 2
    lines = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
    picks = [line["rail"] for line in lines if "rail" in line]
    last = picks[-1] if picks else None
    if not last or last.get("letter") != sys.argv[2]:
        print("last pick: %s" % last)
        return 1
    print("last pick %s at index %s" % (sys.argv[2], last.get("index")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
