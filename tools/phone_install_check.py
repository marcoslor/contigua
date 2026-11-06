#!/usr/bin/env python3
"""Check that the running PocketDeck shell service maps the current base.apk.

`adb install -r` replaces the APK but does not restart the root/Shizuku
`:pocketdeck` service. The old process keeps the deleted base.apk mapped and
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

PACKAGE = "dev.pocketdeck"
SERVICE = PACKAGE + ":pocketdeck"


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


def _adb(adb, serial, *args, check=True):
    command = [adb]
    if serial:
        command += ["-s", serial]
    command += ["shell", *args]
    return subprocess.run(command, check=check, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def service_pid(adb, serial):
    result = _adb(adb, serial, "pidof", SERVICE, check=False)
    if result.returncode != 0:
        return None
    pids = result.stdout.split()
    return pids[0] if pids else None


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
    pid = service_pid(adb, serial)
    if not pid:
        return False, ("no %s process: launch %s once, then retry" % (SERVICE, PACKAGE))
    maps = read_maps(adb, serial, pid)
    if not maps:
        return False, "cannot read /proc/%s/maps" % pid
    deleted = deleted_base(maps)
    if deleted:
        return False, ("pid %s still maps the deleted %s; kill %s and launch the app"
                       % (pid, deleted, SERVICE))
    mapped = mapped_base(maps)
    current = current_base(adb, serial)
    if current and mapped and current != mapped:
        return False, ("pid %s maps %s, but pm path says %s; restart the service"
                       % (pid, mapped, current))
    if not mapped:
        return False, "pid %s maps no base.apk" % pid
    return True, "pid %s maps %s" % (pid, mapped)


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
