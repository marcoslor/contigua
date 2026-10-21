#!/usr/bin/env python3
"""Display 0's power state from a platform dump.

API 36's `dumpsys power` prints `Display Power: com.android.server.power.
PowerManagerService$1@…` instead of `Display Power: state=ON`, so the old grep
never matched and the wake check failed on a working phone. `dumpsys display`
says it two ways: the `Display 0:` block's `mState` and the `Display Power
State:` section's `mScreenState`. This reads both, and keeps the old
`Display Power: state=` line as the alternative for builds that still print it.

    display-state.py <display-dump> [--power <power-dump>]
    display-state.py --self-test

Prints `<STATE>\\t<the matched line>`, STATE being ON, OFF, DOZE or UNKNOWN.
Exit 0 when a state was read, 1 when nothing in the dumps says it.
"""
import re
import sys

# A `Display <id>:` or `Display Power State:` header sits inside a section, so
# it is indented; a top-level header (`Logical Displays:`, `Photonic Modulator
# State:`) starts at column 0 and ends the block above it.
BLOCK_HEAD = re.compile(r"^(?P<indent>[ \t]*)(?P<name>Display (?P<id>\d+)|Display Power State):[ \t]*$", re.M)
TOP_LEVEL = re.compile(r"^(?P<name>[A-Z][^:\n]*):[ \t]*$", re.M)
STATE_LINE = re.compile(r"^[ \t]*(?P<key>mState|mScreenState)=(?P<value>[A-Z_]+)[ \t]*$", re.M)
STATES_LINE = re.compile(r"^[ \t]*mDisplayStates=\[(?P<values>[0-9,\t ]*)\][ \t]*$", re.M)
LEGACY = re.compile(r"Display Power: state=(?P<state>[A-Z_]+)")

# Display.STATE_* indices, in mDisplayStates order.
INDEX_STATES = {0: "OFF", 1: "ON", 2: "DOZE", 3: "DOZE_SUSPEND", 4: "ON_SUSPEND"}

ON = {"ON", "ON_SUSPEND"}


def block_after(text, head):
    """The indented lines after <head>, up to the next header at any level."""
    end = len(text)
    for m in BLOCK_HEAD.finditer(text, head.end()):
        end = min(end, m.start())
    for m in TOP_LEVEL.finditer(text, head.end()):
        end = min(end, m.start())
    return text[head.end():end]


def find_block(text, want):
    """The body of the first `<want>` block (display 0 or Display Power State)."""
    for m in BLOCK_HEAD.finditer(text):
        if want == "display 0":
            if m.group("id") != "0":
                continue
        elif m.group("name") != want:
            continue
        return block_after(text, m)
    return None


def read(text, power_text=None):
    """(state, evidence) for display 0; state UNKNOWN when the dumps are silent."""
    zero = find_block(text, "display 0")
    if zero:
        m = STATE_LINE.search(zero)
        if m:
            value = m.group("value")
            return ("ON" if value in ON else value, "%s=%s" % (m.group("key"), value))
    power_state = find_block(text, "Display Power State")
    if power_state:
        m = STATE_LINE.search(power_state)
        if m:
            value = m.group("value")
            return ("ON" if value in ON else value, "%s=%s" % (m.group("key"), value))
    if zero:
        m = STATES_LINE.search(zero)
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
    # API 36 `dumpsys display` (trimmed): the display block and the power
    # controller's section, woken panel.
    (
        "Logical Displays: size=1\n"
        "  Display 0:\n"
        "    mDisplayId=0\n"
        "    mState=ON\n"
        "    mBaseDisplayInfo=DisplayInfo{...}\n"
        "\n"
        "Display Power State:\n"
        "  mStopped=false\n"
        "  mScreenState=ON\n"
        "\n"
        "Photonic Modulator State:\n"
        "  mScreenState=ON\n",
        "ON",
    ),
    # The same dump with the panel asleep, including a second display that is
    # ON: display 0 decides, and its block ends at the next top-level header.
    (
        "Logical Displays: size=2\n"
        "  Display 0:\n"
        "    mDisplayId=0\n"
        "    mState=OFF\n"
        "  Display 1:\n"
        "    mDisplayId=1\n"
        "    mState=ON\n"
        "\n"
        "Display Power State:\n"
        "  mScreenState=OFF\n",
        "OFF",
    ),
    # Only the power controller's section says it.
    ("Logical Displays: size=1\nDisplay Power State:\n  mScreenState=ON\n", "ON"),
    # Older builds spell it mScreenState in the display block, others only the
    # state array.
    ("Display 0:\n  mScreenState=ON\n", "ON"),
    ("Display 0:\n  mDisplayStates=[0]\n", "OFF"),
    ("Display 0:\n  mDisplayStates=[1]\n", "ON"),
    # The old dumpsys power line stays a valid alternative.
    ("", "ON", "Power Manager State:\nDisplay Power: state=ON\n"),
    # API 36's dumpsys power prints a binder, and a dozing panel is not ON.
    ("", "UNKNOWN", "Display Power: com.android.server.power.PowerManagerService$1@1a2b\n"),
    ("Display 0:\n  mState=DOZE\n", "DOZE"),
    # A dump that only describes another display says nothing about display 0.
    ("Display 1:\n  mState=ON\n", "UNKNOWN"),
]


def self_test():
    for case in SELF_TESTS:
        text, want = case[0], case[1]
        power = case[2] if len(case) > 2 else None
        got = read(text, power)[0]
        assert got == want, "want %s, got %s for %r" % (want, got, text or power)
    print("SELF-TEST OK: display 0 state parsing (mState/mScreenState, ON/OFF/DOZE, legacy line)")


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
