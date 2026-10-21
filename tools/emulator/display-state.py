#!/usr/bin/env python3
"""Display 0's power state from a platform dump.

API 36's `dumpsys power` prints `Display Power: com.android.server.power.
PowerManagerService$1@…` instead of `Display Power: state=ON`, so the old grep
never matched and the wake check failed on a working phone. This reads the
display's own dump (`dumpsys display`, display 0's `mState`) and keeps the old
`Display Power: state=` line as the alternative when a build still prints it.

    display-state.py <display-dump> [--power <power-dump>]
    display-state.py --self-test

Prints `<STATE>\\t<the matched line>`, STATE being ON, OFF, DOZE or UNKNOWN.
Exit 0 when a state was read, 1 when nothing in the dumps says it.
"""
import re
import sys

HEAD = re.compile(r"^(?P<indent>[ \t]*)Display (?P<id>\d+):[ \t]*$", re.M)
STATE_LINE = re.compile(r"^[ \t]*(?P<key>mState|mScreenState)=(?P<value>[A-Z_]+)[ \t]*$", re.M)
STATES_LINE = re.compile(r"^[ \t]*mDisplayStates=\[(?P<values>[0-9,\t ]*)\][ \t]*$", re.M)
LEGACY = re.compile(r"Display Power: state=(?P<state>[A-Z_]+)")

# Display.STATE_* indices, in mDisplayStates order.
INDEX_STATES = {0: "OFF", 1: "ON", 2: "DOZE", 3: "DOZE_SUSPEND", 4: "ON_SUSPEND"}

ON = {"ON", "ON_SUSPEND"}


def display_zero_block(text):
    """The text of the `Display 0:` block (Logical Displays), or None."""
    heads = list(HEAD.finditer(text))
    for pos, head in enumerate(heads):
        if head.group("id") != "0":
            continue
        end = heads[pos + 1].start() if pos + 1 < len(heads) else len(text)
        return text[head.end():end]
    return None


def read(text, power_text=None):
    """(state, evidence) for display 0; state UNKNOWN when the dumps are silent."""
    block = display_zero_block(text)
    if block:
        m = STATE_LINE.search(block)
        if m:
            value = m.group("value")
            return ("ON" if value in ON else value, "%s=%s" % (m.group("key"), value))
        m = STATES_LINE.search(block)
        if m:
            values = [v.strip() for v in m.group("values").split(",") if v.strip()]
            if values:
                idx = int(values[0])
                return (INDEX_STATES.get(idx, "UNKNOWN"), "mDisplayStates=[%s]" % ",".join(values))
    for blob in (text, power_text or ""):
        m = LEGACY.search(blob)
        if m:
            value = m.group("state")
            return ("ON" if value in ON else value, "Display Power: state=%s" % value)
    return ("UNKNOWN", "no display-0 state line")


SELF_TESTS = [
    # API 36 `dumpsys display`, woken panel.
    (
        "Logical Displays: size=2\n"
        "  Display 0:\n"
        "    mDisplayId=0\n"
        "    mState=ON\n"
        "    mBaseDisplayInfo=DisplayInfo{...}\n"
        "  Display 1:\n"
        "    mDisplayId=1\n"
        "    mState=OFF\n",
        "ON",
    ),
    # Same dump with the panel off: display 0 decides, never display 1.
    (
        "Logical Displays: size=2\n"
        "  Display 0:\n"
        "    mDisplayId=0\n"
        "    mState=OFF\n"
        "  Display 1:\n"
        "    mDisplayId=1\n"
        "    mState=ON\n",
        "OFF",
    ),
    # Older builds spell it mScreenState, others only the state array.
    ("Display 0:\n  mScreenState=ON\n", "ON"),
    ("Display 0:\n  mDisplayStates=[0]\n", "OFF"),
    ("Display 0:\n  mDisplayStates=[1]\n", "ON"),
    # The old dumpsys power line stays a valid alternative.
    ("", "ON", "Power Manager State:\nDisplay Power: state=ON\n"),
    # API 36's dumpsys power prints a binder, and a dozing panel is not ON.
    ("", "UNKNOWN", "Display Power: com.android.server.power.PowerManagerService$1@1a2b\n"),
    ("Display 0:\n  mState=DOZE\n", "DOZE"),
]


def self_test():
    for case in SELF_TESTS:
        text, want = case[0], case[1]
        power = case[2] if len(case) > 2 else None
        got = read(text, power)[0]
        assert got == want, "want %s, got %s for %r" % (want, got, text or power)
    print("SELF-TEST OK: display 0 state parsing (ON/OFF/DOZE, legacy line)")


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        self_test()
        return 0
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    path = argv[1]
    power_path = argv[3] if len(argv) >= 4 and argv[2] == "--power" else None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fp:
            text = fp.read()
        power_text = None
        if power_path:
            with open(power_path, "r", encoding="utf-8", errors="replace") as fp:
                power_text = fp.read()
    except OSError as exc:
        print("display-state: %s" % exc, file=sys.stderr)
        return 1
    state, evidence = read(text, power_text)
    print("%s\t%s" % (state, evidence))
    return 0 if state != "UNKNOWN" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
