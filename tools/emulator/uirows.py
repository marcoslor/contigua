#!/usr/bin/env python3
"""The paired-Mac rows in a uiautomator dump, read by screen position.

The rig greps for "Connected now" anywhere in the dump, which is exactly what
fails when the live Mac's row sits below the fold: uiautomator only dumps what
is drawn, so a row that is not on screen does not exist for the check. Reading
the rows in y order lets the section assert on the row nearest the top, which
is where a person looks first.

    uirows.py top <dump.xml>       # "<y>\t<status text>" of the topmost row
    uirows.py list <dump.xml>      # every row status, top to bottom
    uirows.py --self-test          # the parser against inline dumps

Exit status is 0 when at least one row was found, 1 otherwise. Only the row's
status line is printed: never a Mac's name.
"""
import os
import re
import sys

STATUS = re.compile(r"^(Connected now|Last connected)\b")
NODE = re.compile(r"<node\b[^>]*>")
BOUNDS = re.compile(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]")


def attr(tag, name):
    m = re.search(r'\b%s="([^"]*)"' % name, tag)
    return m.group(1) if m else ""


def rows(xml):
    """(y, x, status) for every drawn status line, top to bottom."""
    found = []
    for tag in NODE.findall(xml):
        text = attr(tag, "text")
        if not text or not STATUS.match(text):
            continue
        m = BOUNDS.search(attr(tag, "bounds"))
        if m:
            found.append((int(m.group(2)), int(m.group(1)), text))
    found.sort()
    return found


DUMP = (
    '<hierarchy rotation="0"><node index="0" text="" bounds="[0,0][1080,2400]">'
    '<node text="Paired Macs" bounds="[42,1651][285,1714]" />'
    '<node text="%(a)s" bounds="[189,%(ya)s][776,%(y1)s]" />'
    '<node text="%(b)s" bounds="[189,%(yb)s][776,%(y2)s]" />'
    '<node text="%(c)s" bounds="[189,%(yc)s][776,%(y3)s]" />'
    "</node></hierarchy>"
)


def self_test():
    stacked = DUMP % dict(
        a="Connected now", ya=1772, y1=1835,
        b="Last connected Yesterday", yb=1964, y2=2027,
        c="Last connected 21 hours ago", yc=2156, y3=2219,
    )
    got = rows(stacked)
    assert [r[2] for r in got] == [
        "Connected now", "Last connected Yesterday", "Last connected 21 hours ago",
    ], got
    assert got[0][0] == 1772, got

    # A dump where the live row was drawn below two stale ones must still be
    # read in y order, not in document order.
    shuffled = DUMP % dict(
        a="Last connected 23 hours ago", ya=1772, y1=1835,
        b="Last connected Yesterday", yb=1964, y2=2027,
        c="Connected now", yc=2156, y3=2219,
    )
    assert [r[2] for r in rows(shuffled)] == [
        "Last connected 23 hours ago", "Last connected Yesterday", "Connected now",
    ]
    # A screen without the paired list has no rows, and that is not a crash.
    assert rows('<hierarchy><node text="Contigua" bounds="[0,0][10,10]" /></hierarchy>') == []
    print("SELF-TEST OK: uirows top-to-bottom status parsing")


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        self_test()
        return 0
    if len(argv) != 3 or argv[1] not in ("top", "list"):
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    path = argv[2]
    if not os.path.exists(path):
        print("uirows: no dump at %s" % path, file=sys.stderr)
        return 1
    with open(path, "r", encoding="utf-8", errors="replace") as fp:
        found = rows(fp.read())
    if not found:
        print("uirows: no paired-Mac row in the dump", file=sys.stderr)
        return 1
    for y, _x, text in found[:1] if argv[1] == "top" else found:
        print("%d\t%s" % (y, text))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
