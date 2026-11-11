#!/usr/bin/env python3
"""The rail's accent after a pick or a scroll, from --debug-deck-grid (e2e `deck`).

A quiet e2e run cannot click the rail, so `control deck-rail LETTER` runs the
rail's own scroll. The app reports the accent it draws (`railAccent`) with the
top row's letter and the machine's state. DECK-7: a pick settles holding the
letter it landed on — not the letter of the row it shares — until the grid is
scrolled by other means, and then the top row's letter is back.

usage: deck-rail-accent.py pick FILE LETTER [WAIT_S]
       deck-rail-accent.py settle FILE SINCE LETTER [WAIT_S]
       deck-rail-accent.py top FILE SINCE [WAIT_S]

`SINCE` is the dump's line count before the scroll: only accents written after
it are read, so an old pick cannot pass for the new top row.

`settle` samples every accent the app writes from a click's pick line until the
jump's last frame, and fails if any of them lights a letter other than the one
clicked (or the one the rail lit before the click). `pick` reads only the first
settled frame, so it cannot see a flash on the way.

Exit 0 when the accent is the picked letter and settled (pick), when the pick's
whole jump lit only the clicked letter (settle), or when the top row's letter is
back after a scroll (top). Prints one line on success, the reason on failure.
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

    if mode == "settle":
        return settle(path, int(argv[2]), argv[3],
                      float(argv[4]) if len(argv) > 4 else 8.0)

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


def settle(path, since, letter, wait):
    """Every accent from the click's pick to the jump's last frame.

    The app writes an accent only when what it draws changes, so a flash is a
    line: the pick line, then the letters the scroll passes, then the settle.
    The jump has settled when the last accent says `picked` and no new line has
    arrived for 0.4 s; a click that never picks, or a jump that never settles,
    fails with the last accent it saw.
    """
    deadline = time.time() + wait
    quiet_since = None
    seen = None
    while time.time() < deadline:
        lines = load(path)
        new = lines[min(since, len(lines)):]
        picks = [i for i, line in enumerate(new)
                 if line.get("rail", {}).get("letter") == letter]
        if picks:
            before = ""
            for line in new[:picks[-1]]:
                if "railAccent" in line:
                    before = line["railAccent"].get("letter", "")
            accents = [(i, line["railAccent"]) for i, line in enumerate(new)
                       if i > picks[-1] and "railAccent" in line]
            if accents:
                seen = accents
                last = accents[-1][1]
                if last.get("state") == "picked" and last.get("letter") == letter:
                    if quiet_since is None:
                        quiet_since = time.time()
                    elif time.time() - quiet_since >= 0.4:
                        return settle_verdict(letter, before, accents)
                else:
                    quiet_since = None
        time.sleep(0.1)
    if seen is None:
        print("no accent was written after the %s pick" % letter)
        return 1
    return settle_verdict(letter, "", seen, incomplete=True)


def settle_verdict(letter, before, accents, incomplete=False):
    allowed = {letter} | ({before} if before else set())
    for _, accent in accents:
        got = accent.get("letter", "")
        if got not in allowed:
            print("the %s pick lit %r on its way (state %r at top %r, offset %r)"
                  % (letter, got, accent.get("state"), accent.get("top"),
                     accent.get("offset")))
            return 1
    last = accents[-1][1]
    if last.get("letter") != letter:
        print("the %s pick settled on %r (state %r, its row is %r)"
              % (letter, last.get("letter"), last.get("state"), last.get("row")))
        return 1
    if last.get("state") != "picked":
        print("the %s jump never settled (state %r, offset %r, max %r)"
              % (letter, last.get("state"), last.get("offset"), last.get("max")))
        return 1
    if incomplete:
        print("the %s jump did not stop changing within the wait" % letter)
        return 1
    print("%s stayed lit through %d accent frames to the settle (its row is %s)"
          % (letter, len(accents), last.get("row") or "?"))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 4 or sys.argv[1] not in ("pick", "settle", "top"):
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
