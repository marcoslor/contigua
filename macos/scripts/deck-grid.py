#!/usr/bin/env python3
"""The Deck grid's drawn cells, from --debug-deck-grid (e2e `deck`).

A phone can be reached through more than one launcher activity for the same
package, and it can send an entry with no label. Equal cell ids made SwiftUI
draw neither of the two (the person's empty slot), and an empty label leaves a
tile with nothing under it. The dump is one JSON object per change; the last
one is the grid as drawn.

Exit 0 when every cell has its own id and words, the repeated package has two
cells, and the label-less entry falls back to its package's last part.
"""
import json
import sys

EXPECTED_CELLS = 14  # the fake phone's 13 apps plus the duplicate launcher entry
DUPLICATE = "com.android.settings/"
LABEL_LESS = "com.spotify.music/"


def main(path):
    lines = [json.loads(line) for line in open(path) if line.strip()]
    if not lines:
        print("no grid dump yet")
        return 1
    items = lines[-1].get("items", [])
    problems = []
    if len(items) != EXPECTED_CELLS:
        problems.append("cells=%d, the phone sent %d apps" % (len(items), EXPECTED_CELLS))
    ids = [item.get("id", "") for item in items]
    if len(set(ids)) != len(ids):
        problems.append("two cells share one id")
    for item in items:
        if not item.get("label", "").strip():
            problems.append("a cell has no words (%s)" % item.get("id"))
    duplicate = [item for item in items if item.get("id", "").startswith(DUPLICATE)]
    if len(duplicate) != 2:
        problems.append("%d cell(s) for the repeated package" % len(duplicate))
    elif duplicate[0]["label"] == duplicate[1]["label"]:
        problems.append("the two entries of the repeated package share one label")
    label_less = [item for item in items if item.get("id", "").startswith(LABEL_LESS)]
    if not label_less or label_less[0]["label"] != "music":
        problems.append("the label-less entry did not fall back to its package")
    if problems:
        print("; ".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
