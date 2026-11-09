#!/usr/bin/env python3
"""The shell service must run the APK on disk, not a deleted one (ISS-51).

`adb install -r` replaces the APK but leaves the Shizuku-hosted
`dev.pocketdeck:pocketdeck` app_process alive; it keeps the old, deleted
base.apk mapped and serves the build that was installed before. This is the
emulator half of `tools/phone_install_check.py`, which the real phone runs
after every install.

The decision is that script's (evaluate/read_maps/current_base); only the pid
list differs: `pidof` compares the 15-character comm, which cannot hold
`dev.pocketdeck:pocketdeck`, so the pids come from `ps` here.

    python3 tools/emulator/service-maps.py --adb <adb> --serial <serial>

One PASS/FAIL line; exit 0 only when every service pid maps `pm path`'s
current base.apk and none maps a deleted one.
"""
import argparse
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import phone_install_check as check  # noqa: E402

SERVICE = "dev.pocketdeck:pocketdeck"


def service_pids(adb, serial):
    result = subprocess.run([adb, "-s", serial, "shell", "ps", "-A", "-o", "PID,NAME"],
                            capture_output=True, text=True)
    return [line.split()[0] for line in result.stdout.splitlines() if SERVICE in line]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", required=True)
    args = parser.parse_args(argv)
    pids = service_pids(args.adb, args.serial)
    entries = [(pid, check.read_maps(args.adb, args.serial, pid)) for pid in pids]
    ok, message = check.evaluate(entries, check.current_base(args.adb, args.serial))
    print(("PASS: " if ok else "FAIL: ") + message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
