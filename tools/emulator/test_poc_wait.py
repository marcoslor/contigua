#!/usr/bin/env python3
"""Repro for boot 9's 60 s pairing timeout, without a device.

The phone showed its pair code 1.5 s after `wait-prompt` started, while the
command was still taking its first UI dump. `read_new_code` snapshots the code
it sees before the loop as "stale" (a prompt left by an earlier aborted
request), so the only prompt was treated as old and ignored until the timeout.
The Mac had already derived the same code; no tap ever happened.

`poc.py pair` already passes "" for a request it knows raises a fresh prompt.
`wait-prompt` now takes `--stale none` for the same reason (the boot's pair
phase starts on a fresh device), and this check pins both halves: the flag is
accepted, and a code shown during the first dump is new, while a genuinely
earlier code is still ignored.

Run: python3 tools/emulator/test_poc_wait.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import poc  # noqa: E402

DIALOG = '<hierarchy><node text="Pair with this Mac"><node text="477 346"/></node></hierarchy>'
FAILED = []


class FakeAdb(object):
    """No notifications; every UI dump shows the freshly-shown dialog."""

    def out(self, *args):
        return ""

    def sh(self, *args, **kwargs):
        class Result(object):
            stdout = ""
            stderr = ""
        result = Result()
        if args and args[0] == "uiautomator":
            result.stdout = "UI hierarchy dumped to /sdcard/contigua-ui.xml"
        elif args and args[0] == "cat":
            result.stdout = DIALOG
        return result


def check(label, condition):
    print(("POC-WAIT PASS: " if condition else "POC-WAIT FAIL: ") + label)
    if not condition:
        FAILED.append(label)


def main():
    parser = poc.build_parser()
    args = parser.parse_args(["wait-prompt", "--stale", "none"])
    check("wait-prompt takes --stale none", args.stale == "none")

    # The auto baseline reproduces boot 9: the first dump is the prompt, so it
    # becomes "stale" and the loop never accepts it.
    auto = poc.read_new_code(FakeAdb(), 0.05, 0.01)
    check("auto baseline swallows a prompt shown during its first dump", auto is None)

    # What the boot does now: no earlier prompt exists, so the first code is new.
    fresh = poc.read_new_code(FakeAdb(), 0.2, 0.01, stale="")
    check("a fresh-boot prompt is accepted (%r)" % (fresh,), fresh == "477346")

    # A genuinely leftover prompt is still ignored.
    leftover = poc.read_new_code(FakeAdb(), 0.05, 0.01, stale="477346")
    check("a leftover code is still ignored", leftover is None)

    if FAILED:
        print("POC-WAIT FAIL: %d check(s)" % len(FAILED))
        return 1
    print("POC-WAIT PASS: --stale none accepts the fresh prompt, auto still ignores a leftover")
    return 0


if __name__ == "__main__":
    sys.exit(main())
