#!/usr/bin/env python3
"""The locked-multi driver: two app windows on a locked phone, one covered.

Runs one session against the rig `tools/emulator/locked-multi.sh` booted and
paired, and leaves the phone as it found it: the caller owns the boot and the
log parsing. It gathers the state dumps and markers that the shell check reads:

  display-*.txt   `dumpsys display` at the named moment (raw)
  markers         `log -t PocketDeckLockedMulti` lines on the phone's clock

The scenario is the 11-01 field log: window 1 opens on the locked phone; the Mac
covers it (window.pause) when window 2 takes the focus; window 2 closes; the Mac
resumes window 1. The phone must keep window 1's display ON and the episode
alive (docs/specs/controls.md CTRL-14).
"""

import argparse
import subprocess
import sys
import time

sys.path.insert(0, "tools/fakephone")
import deckctl  # noqa: E402
import proto  # noqa: E402

TAG = "PocketDeckLockedMulti"


def mark(adb, serial, what):
    """One marker line on the phone's own clock (best effort, never a failure)."""
    try:
        subprocess.run([adb, "-s", serial, "shell", "log", "-t", TAG, what],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=10, check=False)
    except Exception:  # noqa: BLE001 - evidence only
        pass


class Phone(object):
    def __init__(self, adb, serial, out):
        self.adb = adb
        self.serial = serial
        self.out = out

    def dump(self, name):
        path = "%s/display-%s.txt" % (self.out, name)
        with open(path, "w") as fp:
            subprocess.run([self.adb, "-s", self.serial, "shell", "dumpsys", "display"],
                           stdout=fp, stderr=subprocess.DEVNULL, timeout=60, check=False)
        return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--out", required=True)
    parser.add_argument("--pkg1", default="com.android.settings")
    parser.add_argument("--pkg2", default="acr.browser.lightning")
    parser.add_argument("--w", type=int, default=640)
    parser.add_argument("--h", type=int, default=480)
    parser.add_argument("--dpi", type=int, default=160)
    parser.add_argument("--settle", type=float, default=2.0)
    args = parser.parse_args(argv)

    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(args.host, args.port, state, None)
    phone = Phone(args.adb, args.serial, args.out)
    rec = deckctl.StreamRecorder(client).start()
    try:
        # 1. one window on the locked phone
        client.send_json({"t": "window.open", "stream": 1, "w": args.w, "h": args.h,
                          "dpi": args.dpi, "pkg": args.pkg1})
        size1 = rec.wait_for_size(1, 25.0)
        time.sleep(args.settle)
        d1 = rec.opened.get(1, {}).get("displayId")
        mark(args.adb, args.serial, "one-open")
        phone.dump("one")
        print("stream1 displayId=%s size=%dx%d frames=%d" %
              (d1, size1[0], size1[1], rec.total_frames.get(1, 0)))

        # 2. the Mac covers window 1 when window 2 takes the focus
        client.send_json({"t": "window.pause", "stream": 1})
        time.sleep(0.4)
        mark(args.adb, args.serial, "one-paused")
        # A different package: two windows of one package can share a task, and
        # closing the second then ends the first's app (seen on the first run).
        client.send_json({"t": "window.open", "stream": 2, "w": args.w, "h": args.h,
                          "dpi": args.dpi, "pkg": args.pkg2})
        size2 = rec.wait_for_size(2, 25.0)
        time.sleep(args.settle)
        d2 = rec.opened.get(2, {}).get("displayId")
        mark(args.adb, args.serial, "two-open")
        phone.dump("two")
        print("stream2 displayId=%s size=%dx%d frames=%d" %
              (d2, size2[0], size2[1], rec.total_frames.get(2, 0)))

        # A tap on the visible window: the sink-line evidence (item 4). The
        # marker lets the shell tell this tap's app reaction from the open's.
        mark(args.adb, args.serial, "tap")
        client.send_raw(proto.pack_touch(2, proto.TOUCH_DOWN, 0, 0.5, 0.35))
        time.sleep(0.05)
        client.send_raw(proto.pack_touch(2, proto.TOUCH_UP, 0, 0.5, 0.35))
        time.sleep(1.5)

        # 3. window 2 closes; the Mac resumes the covered window 1
        frames_before = rec.total_frames.get(1, 0)
        client.send_json({"t": "window.close", "stream": 2})
        mark(args.adb, args.serial, "two-close")
        time.sleep(0.4)
        client.send_json({"t": "window.resume", "stream": 1})
        mark(args.adb, args.serial, "one-resume")
        time.sleep(3.0)
        mark(args.adb, args.serial, "settled")
        phone.dump("after")
        frames_after = rec.total_frames.get(1, 0)
        print("display1=%s" % d1)
        print("display2=%s" % d2)
        print("frames1_before_resume=%d frames1_after_resume=%d" % (frames_before, frames_after))
        print("frames2_total=%d" % rec.total_frames.get(2, 0))

        client.send_json({"t": "window.close", "stream": 1})
        time.sleep(0.3)
        mark(args.adb, args.serial, "closed")
        return 0
    finally:
        try:
            rec.stop()
        finally:
            client.close()


if __name__ == "__main__":
    sys.exit(main())
