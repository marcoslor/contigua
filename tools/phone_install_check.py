#!/usr/bin/env python3
"""Check that every running Contigua shell service maps the current base.apk.

`adb install -r` replaces the APK but does not restart the root/Shizuku
`:contigua` service. The old process keeps the deleted base.apk mapped and
keeps the LAN listener, so the Mac's SYN never gets an answer while the phone
looks healthy. Run this after every install; it fails with the reinstall steps.

    python3 tools/phone_install_check.py --serial SERIAL
    python3 tools/phone_install_check.py --adb /path/to/adb --serial SERIAL

The adb server port is inherited from ANDROID_ADB_SERVER_PORT, so the wireless
phone uses the same 5038 server as the rounds.
"""

import argparse
import subprocess
import sys

PACKAGE = "app.contigua"
SERVICE = PACKAGE + ":contigua"


def deleted_base(maps_text, package=PACKAGE):
    """The deleted base.apk path in /proc/<pid>/maps, or None.

    A maps line is `addr perms offset dev inode pathname`; the pathname is the
    sixth whitespace-separated field and may end in ` (deleted)`.
    """
    for line in maps_text.splitlines():
        fields = line.split(None, 5)
        if len(fields) != 6:
            continue
        path = fields[5]
        if package not in path or "base.apk" not in path:
            continue
        if path.endswith(" (deleted)"):
            return path[:-len(" (deleted)")]
    return None


def mapped_base(maps_text, package=PACKAGE):
    """The live base.apk path in the maps, or None."""
    for line in maps_text.splitlines():
        fields = line.split(None, 5)
        if len(fields) != 6:
            continue
        path = fields[5]
        if package in path and "base.apk" in path and not path.endswith(" (deleted)"):
            return path
    return None


def evaluate(entries, current):
    """Decide from (pid, maps) pairs and `pm path`'s answer.

    `entries` is every running service pid with its maps text; `current` is
    the live base.apk path from `pm path`, or None/empty when pm knows nothing.
    This is pure so the parser's decision is tested without adb.
    """
    if not entries:
        return False, ("no %s process: launch %s once, then retry" % (SERVICE, PACKAGE))
    if not current:
        return False, "pm path returned no base.apk; install the app first"
    for pid, maps in entries:
        deleted = deleted_base(maps)
        if deleted:
            return False, ("pid %s still maps the deleted %s; kill every %s pid and launch the app"
                           % (pid, deleted, SERVICE))
    mapped = []
    for pid, maps in entries:
        base = mapped_base(maps)
        if not base:
            return False, "pid %s maps no base.apk" % pid
        if base != current:
            return False, ("pid %s maps %s, but pm path says %s; restart the service"
                           % (pid, base, current))
        mapped.append(base)
    return True, "pids %s map %s" % (",".join(pid for pid, _ in entries), mapped[0])


def _adb(adb, serial, *args, check=True):
    command = [adb]
    if serial:
        command += ["-s", serial]
    command += ["shell", *args]
    return subprocess.run(command, check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def service_pids(adb, serial):
    result = _adb(adb, serial, "pidof", SERVICE, check=False)
    if result.returncode != 0:
        return []
    return [pid for pid in result.stdout.split() if pid]


def read_maps(adb, serial, pid):
    result = _adb(adb, serial, "cat", "/proc/%s/maps" % pid, check=False)
    if result.returncode == 0 and result.stdout:
        return result.stdout
    # A shell that is not the service's UID may need root; KernelSU is present
    # on the person's phone. This is read-only.
    result = _adb(adb, serial, "su -c 'cat /proc/%s/maps'" % pid, check=False)
    return result.stdout if result.returncode == 0 else ""


def current_base(adb, serial):
    result = _adb(adb, serial, "pm", "path", PACKAGE, check=False)
    for line in result.stdout.splitlines():
        if line.startswith("package:") and line.endswith("/base.apk"):
            return line[len("package:"):]
    return None


def check(adb, serial):
    pids = service_pids(adb, serial)
    if not pids:
        return evaluate([], None)
    entries = [(pid, read_maps(adb, serial, pid)) for pid in pids]
    return evaluate(entries, current_base(adb, serial))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", default=None,
                        help="adb serial (the wireless phone's is required)")
    args = parser.parse_args(argv)
    ok, message = check(args.adb, args.serial)
    print(("PASS: " if ok else "FAIL: ") + message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
