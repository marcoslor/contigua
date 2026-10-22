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

# The fake phone's app list: 200 apps (-demo-apps, a grid bigger than the
# person's phone) plus the duplicate launcher entry.
EXPECTED_CELLS = int(sys.argv[2]) if len(sys.argv) > 2 else 201
DUPLICATE = "com.android.settings/"
LABEL_LESS = "com.spotify.music/"


def main(path):
    lines = [json.loads(line) for line in open(path) if line.strip()]
    # Geometry lines share the file; the cell dump is the newest line with items.
    cells = [line for line in lines if "items" in line]
    if not cells:
        print("no grid dump yet")
        return 1
    items = cells[-1]["items"]
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
