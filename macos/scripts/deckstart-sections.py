#!/usr/bin/env python3
"""The Deck start page's drawn sections, from --debug-deck-sections (e2e `deckstart`).

The app writes one JSON line per drawn geometry (`DeckGridProbe.reportSections`)
from the layout pass that placed the headers and cells. These checks read what
was drawn, not what the model would draw.

usage:
    deckstart-sections.py FILE kinds  open:3,pinned:8,all:40
    deckstart-sections.py FILE aligned WIDTH
    deckstart-sections.py FILE order   KIND PKG,PKG,...
    deckstart-sections.py FILE header  KIND px|none
    deckstart-sections.py FILE search

`kinds` checks the section list and its counts; `aligned` checks every drawn
cell sits on All Apps' column for its place in the row, that a header starts at
the grid's leading edge and that no row holds more cells than columns; `order`
checks a section's packages in drawn order; `header` checks one header's x;
`search` checks that a query collapsed the page to one headerless All Apps
section. Prints one line on success, the reason on failure.
"""
import json
import sys


def load(path):
    try:
        return [json.loads(line) for line in open(path) if line.strip()]
    except FileNotFoundError:
        return []


def newest(lines, width=None, sectioned=True):
    rows = [line for line in lines if "sections" in line]
    if width is not None:
        rows = [line for line in rows if int(round(line["width"])) == width]
    if sectioned:
        rows = [line for line in rows if len(line.get("sections", [])) > 1]
    return rows[-1] if rows else None


def kinds(args):
    line = newest(load(args[0]), sectioned=False)
    if line is None:
        print("no drawn sections")
        return 1
    want = []
    for item in args[1].split(","):
        kind, count = item.split(":")
        want.append((kind, None if count == "*" else int(count)))
    got = [(section["kind"], len(section["cells"])) for section in line["sections"]]
    if [name for name, _ in got] != [name for name, _ in want] or any(
            expected is not None and count != expected
            for (_, count), (_, expected) in zip(got, want)):
        print("sections:", got)
        return 1
    for section in line["sections"]:
        if section["kind"] != "all" and not section["header"]:
            print(section["kind"], "has no header")
            return 1
    print("sections: " + " ".join("%s=%d" % pair for pair in got))
    return 0


def aligned(args):
    width = int(args[1])
    lines = load(args[0])
    line = newest(lines, width=width)
    if line is None:
        print("no drawn sections at %d pt" % width)
        return 1
    if int(round(line["width"])) != width:
        print("the newest geometry is %s pt wide, not %d" % (line["width"], width))
        return 1
    columns = line["columns"]
    cell = line["cell"]
    gap = line["gap"]
    origin = line["originX"]
    sections = {section["kind"]: section for section in line["sections"]}
    all_apps = sections["all"]["cells"]
    if len(all_apps) < columns:
        print("All Apps draws only %d cells for %d columns" % (len(all_apps), columns))
        return 1
    if width > 700 and origin <= 0:
        print("the grid starts at the window's edge (%.2f): no margins to centre it" % origin)
        return 1
    for section in line["sections"]:
        if section["header"] and abs(section["headerX"] - origin) > 0.01:
            print("%s header at %.2f, the grid starts at %.2f"
                  % (section["kind"], section["headerX"], origin))
            return 1
        rows = {}
        for index, drawn in enumerate(section["cells"]):
            column = index % columns
            expected = origin + column * (cell + gap)
            if abs(drawn["x"] - expected) > 0.01:
                print("%s cell %d at x %.2f, All Apps column %d is at %.2f"
                      % (section["kind"], index, drawn["x"], column, expected))
                return 1
            if abs(drawn["x"] - all_apps[column]["x"]) > 0.01:
                print("%s cell %d is off All Apps' column %d" % (section["kind"], index, column))
                return 1
            if abs(drawn["width"] - cell) > 0.01:
                print("%s cell %d is %.2f wide, the grid's cells are %.2f"
                      % (section["kind"], index, drawn["width"], cell))
                return 1
            rows.setdefault(drawn["y"], 0)
            rows[drawn["y"]] += 1
        wide = [count for count in rows.values() if count > columns]
        if wide:
            print("%s has a row of %d cells over %d columns" % (section["kind"], wide[0], columns))
            return 1
    print("%d pt: %d columns at x %.1f, every section on All Apps' columns"
          % (width, columns, origin))
    return 0


def order(args):
    line = newest(load(args[0]), sectioned=False)
    if line is None:
        print("no drawn sections")
        return 1
    want = args[2].split(",") if args[2] else []
    sections = {section["kind"]: section for section in line["sections"]}
    if args[1] not in sections:
        print("no %s section" % args[1])
        return 1
    got = [drawn["pkg"] for drawn in sections[args[1]]["cells"]]
    if got != want:
        print("%s: %s" % (args[1], got))
        return 1
    print("%s: %s" % (args[1], " ".join(got)))
    return 0


def header(args):
    line = newest(load(args[0]), sectioned=False)
    if line is None:
        print("no drawn sections")
        return 1
    sections = {section["kind"]: section for section in line["sections"]}
    if args[1] not in sections:
        print("no %s section" % args[1])
        return 1
    section = sections[args[1]]
    if args[2] == "none":
        if section["header"]:
            print("%s has a header at %.2f" % (args[1], section.get("headerX", 0)))
            return 1
        print("%s has no header" % args[1])
        return 0
    if not section["header"]:
        print("%s has no header" % args[1])
        return 1
    if abs(section["headerX"] - float(args[2])) > 0.01:
        print("%s header at %.2f, wanted %.2f" % (args[1], section["headerX"], float(args[2])))
        return 1
    print("%s header at %.2f" % (args[1], section["headerX"]))
    return 0


def search(args):
    line = newest(load(args[0]), sectioned=False)
    if line is None:
        print("no drawn sections")
        return 1
    if [section["kind"] for section in line["sections"]] != ["all"]:
        print("sections while searching:", [section["kind"] for section in line["sections"]])
        return 1
    if line["sections"][0]["header"]:
        print("All Apps keeps its header while searching")
        return 1
    print("searching: only the %d results, no header" % len(line["sections"][0]["cells"]))
    return 0


def main(argv):
    modes = {"kinds": kinds, "aligned": aligned, "order": order,
             "header": header, "search": search}
    if len(argv) < 2 or argv[1] not in modes:
        print(__doc__)
        return 2
    return modes[argv[1]]([argv[0]] + argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
