#!/usr/bin/env python3
"""The /proc/<pid>/maps parser behind phone_install_check.py (no adb needed)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from phone_install_check import deleted_base, mapped_base  # noqa: E402

FAILED = []


def check(name, actual, expected):
    if actual != expected:
        FAILED.append(name)
        print("INSTALL-CHECK FAIL: %s: expected %r, got %r" % (name, expected, actual))
    else:
        print("INSTALL-CHECK PASS: %s" % name)


def maps(*paths):
    lines = []
    for path in paths:
        lines.append("7f00-7f10 r--p 00000000 fd:01 1234 %s" % path)
    return "\n".join(lines) + "\n"


def main():
    base = "/data/app/~~abc/dev.pocketdeck-def/base.apk"
    check("a deleted base is named", deleted_base(maps(base + " (deleted)")), base)
    check("a live base is not deleted", deleted_base(maps(base)), None)
    check("another package's deleted base is ignored",
          deleted_base(maps("/data/app/~~x/com.example-y/base.apk (deleted)")), None)
    check("a split is not the base",
          deleted_base(maps("/data/app/~~x/dev.pocketdeck-y/split_config.arm64_v8a.apk (deleted)")), None)
    check("the live base is reported", mapped_base(maps(base)), base)
    check("a deleted base is not a live mapping",
          mapped_base(maps(base + " (deleted)")), None)
    check("malformed lines are ignored", deleted_base("not a maps line"), None)
    if FAILED:
        print("INSTALL-CHECK FAILED: %d" % len(FAILED))
        return 1
    print("INSTALL-CHECK PASS: all")
    return 0


if __name__ == "__main__":
    sys.exit(main())
