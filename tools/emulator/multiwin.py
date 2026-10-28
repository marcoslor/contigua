#!/usr/bin/env python3
"""The multiwin emulator check: several windows of one app on API 36.

Runs against the rig `tools/emulator/start.sh` already booted and leaves it
running: the caller owns the emulator's whole life in one heavy.sh call (see
tools/emulator/multiwin.sh). Nothing here boots or kills anything.

Proves, with a PASS/FAIL line each, the plane the JVM cannot show:

  [WIN-24] apps says per app whether a second instance can run;
  [WIN-25] two window.open for Chrome (the second with newInstance) are two
           tasks on two displays, both render and both take a tap;
  [WIN-28] a label change reaches the fake Mac as window.title within 2 s;
  [WIN-31] window.close on A: B keeps streaming, recents loses one task,
           Chrome keeps running;
  [WIN-32] the fifth app open answers too_many_windows and makes no display;
  [cost]   frames/s per window and the encoder count at 1/2/3/4 windows.

Usage (inside the rig's boot call):
  multiwin.py --host 127.0.0.1 --port 47811 --state <deckctl state> \
      --adb <adb> --serial emulator-5554 --wt <worktree> --out <dir>
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import http.server

PACKAGE = "dev.pocketdeck"
CHROME = "com.android.chrome"
CHROME_MAIN = "com.android.chrome/com.google.android.apps.chrome.Main"
SETTINGS = "com.android.settings"
LABEL_PAGE_TITLE = "PocketDeck multiwin"
MEASURE_S = 8.0
RESULTS = []


def check(ok, tag, message):
    RESULTS.append((bool(ok), tag, message))
    print("%s [%s] %s" % ("PASS" if ok else "FAIL", tag, message), flush=True)
    return bool(ok)


def log(message):
    print("[multiwin] %s" % message, flush=True)


class Dev(object):
    """The emulator side: dumps, screencaps, process ids, am."""

    def __init__(self, adb, serial, out):
        self.adb = adb
        self.serial = serial
        self.out = out

    def sh(self, *args, **kw):
        cmd = [self.adb, "-s", self.serial, "shell"] + [str(a) for a in args]
        try:
            return subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=kw.get("timeout", 60))
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(cmd, 124, "", "timeout")

    def out_of(self, *args):
        return self.sh(*args).stdout.replace("\r", "")

    def adb_run(self, *args):
        """An adb command that is not a shell command (reverse, forward)."""
        return subprocess.run([self.adb, "-s", self.serial] + [str(a) for a in args],
                              capture_output=True, text=True, timeout=60)

    def am_start(self, display, *args, **kw):
        cmd = ["am", "start", "--display", str(display)] + [str(a) for a in args]
        res = self.sh(*cmd, timeout=kw.get("timeout", 45))
        return (res.stdout + res.stderr).strip().replace("\n", " | ")

    def screencap(self, display, tag):
        remote = "/data/local/tmp/pd-mw-%s.png" % tag
        local = os.path.join(self.out, "shot-%s.png" % tag)
        for _attempt in (1, 2):
            res = self.sh("screencap", "-d", str(display), "-p", remote, timeout=60)
            if res.returncode == 0:
                pull = subprocess.run([self.adb, "-s", self.serial, "pull", remote, local],
                                      capture_output=True, timeout=120)
                if pull.returncode == 0:
                    return local
                log("screencap %s pull failed: %s" % (tag, pull.stderr[:120]))
            else:
                log("screencap %s display %s failed: %s"
                    % (tag, display, (res.stderr or res.stdout).strip()[:120]))
            time.sleep(0.8)
        return None

    def luma(self, png):
        return _ffmpeg_gray(png, None)

    def diff(self, a, b):
        return _ffmpeg_gray(a, b)

    def cpu(self):
        text = self.out_of("dumpsys", "cpuinfo")
        procs = {}
        total = None
        for line in text.splitlines():
            m = re.match(r"\s*([0-9.]+)%\s+(\d+)/(\S+?):", line)
            if m:
                name = m.group(3).split(":")[0]
                procs[name] = procs.get(name, 0.0) + float(m.group(1))
                continue
            m = re.match(r"\s*([0-9.]+)%\s+TOTAL:", line)
            if m:
                total = float(m.group(1))
        return {"total": total, "procs": procs}

    def pss_kb(self, pkg):
        text = self.out_of("dumpsys", "meminfo", pkg)
        m = re.search(r"TOTAL PSS:\s+(\d+)", text) or re.search(r"^\s*TOTAL\s+(\d+)", text, re.M)
        return int(m.group(1)) if m else None

    def pid(self, pkg):
        return self.out_of("pidof", pkg).strip()

    def dump(self, name, *args):
        path = os.path.join(self.out, "%s.txt" % name)
        with open(path, "w") as fp:
            fp.write(self.out_of(*args))
        return path


def _ffmpeg_gray(path_a, path_b):
    """Mean luma of one PNG (0-255) or mean absolute difference of two."""
    if path_a is None or (path_b is None and not os.path.exists(path_a)):
        return None
    if path_b is None:
        cmd = ["ffmpeg", "-v", "error", "-i", path_a, "-vf", "scale=1:1",
               "-f", "rawvideo", "-pix_fmt", "gray", "-"]
    else:
        cmd = ["ffmpeg", "-v", "error", "-i", path_a, "-i", path_b,
               "-filter_complex", "[0][1]blend=all_mode=difference,scale=1:1",
               "-f", "rawvideo", "-pix_fmt", "gray", "-"]
    res = subprocess.run(cmd, capture_output=True, timeout=120)
    return res.stdout[0] if res.stdout else None


# --- dumpsys parsing --------------------------------------------------------

def recents_tasks(text):
    """{taskId: pkg} from `dumpsys activity recents`."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"\s*\* Recent #\d+: Task\{\S+ #(\d+) type=\S+ A=\d+:(\S+)\}", line)
        if m:
            out[int(m.group(1))] = m.group(2)
    return out


def activity_tasks(text):
    """[(displayId, taskId, pkg)] from `dumpsys activity activities`."""
    tasks = []
    display = None
    for line in text.splitlines():
        m = re.match(r"\s*Display #(\d+) \(activities", line)
        if m:
            display = int(m.group(1))
            continue
        m = re.match(r"\s*\* Task\{[^#]*#(\d+) type=\S+ A=\d+:(\S+)\}", line)
        if m:
            tasks.append((display, int(m.group(1)), m.group(2)))
    return tasks


def pocketdeck_displays(text):
    """The rig's virtual displays, by their names in `dumpsys display`."""
    return sorted(set(re.findall(r"pocketdeck-\d+", text)))


def tasks_on_display(display):
    return sorted(task for d, task, _pkg in activity_tasks(display) if d == display)


def recents(dev):
    return recents_tasks(dev.out_of("dumpsys", "activity", "recents"))


def displays(dev):
    return pocketdeck_displays(dev.out_of("dumpsys", "display"))


# --- the fake Mac's view ----------------------------------------------------

class Phone(object):
    """The session, the recorder and the messages the fake Mac saw."""

    def __init__(self, client, recorder):
        self.client = client
        self.rec = recorder
        self.titles = []

    def opened(self, stream, timeout=40.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.rec.lock:
                msg = self.rec.opened.get(stream)
            if msg:
                return msg
            err = self._error()
            if err:
                raise RuntimeError("phone error %s waiting for window.opened %d"
                                   % (err.get("code"), stream))
            if self.rec.reader_closed:
                raise RuntimeError("phone closed the connection")
            time.sleep(0.02)
        raise RuntimeError("no window.opened for stream %d" % stream)

    def _error(self):
        with self.rec.lock:
            for msg in reversed(self.rec.messages):
                if msg.get("t") == "error":
                    return msg
        return None

    def wait_error(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            err = self._error()
            if err:
                return err
            time.sleep(0.02)
        return None

    def wait_title(self, stream, want, timeout=6.0):
        """(title, elapsed_s) once this stream's title carries [want], else (None, elapsed)."""
        started = time.time()
        deadline = started + timeout
        while time.time() < deadline:
            with self.rec.lock:
                for msg in reversed(self.rec.messages):
                    if msg.get("t") != "window.title" or msg.get("stream") != stream:
                        continue
                    title = msg.get("title")
                    if title and want in title:
                        return title, time.time() - started
            time.sleep(0.02)
        return None, time.time() - started

    def frames(self, stream):
        with self.rec.lock:
            return self.rec.total_frames.get(stream, 0)

    def clear_errors(self):
        with self.rec.lock:
            self.rec.messages[:] = [m for m in self.rec.messages if m.get("t") != "error"]


def open_window(phone, dev, stream, pkg, new_instance=False):
    request = {"t": "window.open", "stream": stream, "w": 1280, "h": 800, "dpi": 160, "pkg": pkg}
    if new_instance:
        request["newInstance"] = True
    phone.clear_errors()
    phone.client.send_json(request)
    return phone.opened(stream)


def close_window(phone, stream, timeout=15.0):
    phone.client.send_json({"t": "window.close", "stream": stream})
    deadline = time.time() + timeout
    while time.time() < deadline:
        with phone.rec.lock:
            if phone.rec.closed_reason.get(stream) is not None:
                return phone.rec.closed_reason[stream]
        time.sleep(0.02)
    return None


def send_tap(client, stream, nx, ny):
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, nx, ny))
    time.sleep(0.05)
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, nx, ny))


def tap(phone, dev, stream, display, tag):
    """A tap through the product's own input path, proved by the picture."""
    before = dev.screencap(display, "%s-before" % tag)
    luma = dev.luma(before)
    for nx, ny in ((0.5, 0.06), (0.5, 0.5)):
        send_tap(phone.client, stream, nx, ny)
        time.sleep(1.2)
        after = dev.screencap(display, "%s-after" % tag)
        changed = dev.diff(before, after)
        if changed:
            return {"luma": luma, "diff": changed, "at": "%.2f,%.2f" % (nx, ny),
                    "before": before, "after": after}
    return {"luma": luma, "diff": None, "at": None, "before": before, "after": after}


class LocalPage(object):
    """A page with a known <title>, served to the emulator through `adb reverse`."""

    def __init__(self, dev, out):
        self.dev = dev
        self.dir = os.path.join(out, "page")
        os.makedirs(self.dir, exist_ok=True)
        with open(os.path.join(self.dir, "label.html"), "w") as fp:
            fp.write("<!doctype html><html><head><title>%s</title></head>"
                     "<body style='font-size:48px;padding:40px'>multiwin</body></html>\n"
                     % LABEL_PAGE_TITLE)
        sock = socket.socket()
        sock.bind(("127.0.0.1", 0))
        self.port = sock.getsockname()[1]
        sock.close()
        handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=self.dir, **kw)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.reversed = self.dev.adb_run("reverse", "tcp:%d" % self.port,
                                         "tcp:%d" % self.port).returncode == 0

    def url(self):
        return "http://127.0.0.1:%d/label.html" % self.port

    def stop(self):
        self.dev.adb_run("reverse", "--remove", "tcp:%d" % self.port)
        self.server.shutdown()


# --- the checks -------------------------------------------------------------

def check_apps(apps):
    listed = {a.get("pkg"): a for a in apps}
    every = all("multi" in a for a in apps)
    chrome = listed.get(CHROME, {}).get("multi")
    settings = listed.get(SETTINGS, {}).get("multi")
    check(every, "WIN-24", "every app answers multi (%d apps)" % len(apps))
    check(chrome is True and settings is False, "WIN-24",
          "Chrome multi=%s, Settings multi=%s" % (chrome, settings))
    return listed


def check_two_windows(phone, dev):
    first = open_window(phone, dev, 1, CHROME)
    second = open_window(phone, dev, 2, CHROME, new_instance=True)
    t1, t2 = first.get("taskId"), second.get("taskId")
    check(t1 and t2 and t1 != t2, "WIN-25",
          "two Chrome windows: taskId %s and %s, displays %s and %s"
          % (t1, t2, first.get("displayId"), second.get("displayId")))

    recent = recents(dev)
    chrome_tasks = sorted(k for k, v in recent.items() if v == CHROME)
    check(len(chrome_tasks) == 2 and set(chrome_tasks) == {t1, t2}, "WIN-25",
          "dumpsys activity recents lists exactly Chrome tasks %s" % chrome_tasks)

    shots = {}
    for stream, msg in ((1, first), (2, second)):
        display = msg.get("displayId")
        shots[stream] = dev.screencap(display, "b-s%d" % stream)
    lumas = {s: dev.luma(p) for s, p in shots.items()}
    check(all(v is not None and v > 8 for v in lumas.values()), "WIN-25",
          "both displays render (%s)" % ", ".join("s%d luma=%s" % kv for kv in sorted(lumas.items())))

    taps = {}
    for stream, msg in ((1, first), (2, second)):
        taps[stream] = tap(phone, dev, stream, msg.get("displayId"), "b-s%d" % stream)
    check(all(t["diff"] for t in taps.values()), "WIN-25",
          "both displays take a tap (%s)"
          % ", ".join("s%d at %s diff=%s" % (s, t["at"], t["diff"]) for s, t in sorted(taps.items())))
    return first, second


def check_label(phone, dev, page):
    third = open_window(phone, dev, 3, CHROME, new_instance=True)
    display = third.get("displayId")
    # The window starts on Chrome's own page; the navigation below gives it a
    # title of ours, and the label has to follow within the protocol's second.
    phone.client.send_json({"t": "window.keyframe", "stream": 3})
    time.sleep(1.0)
    if not page.reversed:
        phone.client.send_json({"t": "window.close", "stream": 3})
        return check(False, "WIN-28", "adb reverse failed; no local page to navigate to")
    started = time.time()
    dev.am_start(display, "-a", "android.intent.action.VIEW", "-d", page.url(), "-n", CHROME_MAIN)
    title, _ = phone.wait_title(3, LABEL_PAGE_TITLE, timeout=4.0)
    elapsed = time.time() - started
    check(title is not None and elapsed <= 2.0, "WIN-28",
          "a label change reached window.title in %.2fs (%s)"
          % (elapsed, ("title len=%d" % len(title)) if title else "no title"))
    dev.screencap(display, "c-label")
    close_window(phone, 3)
    return ok


def check_close(phone, dev, first, second):
    task_a = first.get("taskId")
    before = recents(dev)
    frames_before = phone.frames(2)
    chrome_pid_before = dev.pid(CHROME)
    reason = close_window(phone, 1)
    time.sleep(2.5)
    frames_after = phone.frames(2)
    after = recents(dev)
    chrome_pid_after = dev.pid(CHROME)
    lost = sorted(set(before) - set(after))
    gained = sorted(set(after) - set(before))
    check(reason == "requested" and frames_after > frames_before, "WIN-31",
          "B kept streaming after A closed (%d -> %d frames, closed reason %s)"
          % (frames_before, frames_after, reason))
    check(lost == [task_a] and not gained, "WIN-31",
          "recents lost exactly A's task %s (lost %s, gained %s)" % (task_a, lost, gained))
    check(bool(chrome_pid_after) and chrome_pid_before == chrome_pid_after, "WIN-31",
          "Chrome still running (pid %s)" % chrome_pid_after)
    return task_a


def check_cap(phone, dev, others):
    opened = []
    for stream, pkg in ((4, SETTINGS), (5, others.get("clock") or SETTINGS), (6, CHROME)):
        opened.append(open_window(phone, dev, stream, pkg, new_instance=(pkg == CHROME)))
    before_displays = displays(dev)
    phone.clear_errors()
    phone.client.send_json({"t": "window.open", "stream": 7, "w": 1280, "h": 800,
                            "dpi": 160, "pkg": CHROME, "newInstance": True})
    error = phone.wait_error(5.0)
    after_displays = displays(dev)
    check(error is not None and error.get("code") == "too_many_windows", "WIN-32",
          "the fifth app window answered %s" % (error.get("code") if error else "nothing"))
    check(before_displays == after_displays and len(after_displays) == 4, "WIN-32",
          "no fifth display was created (%d live: %s)" % (len(after_displays), ", ".join(after_displays)))
    return [2, 4, 5, 6]


def cost_phase(phone, dev, streams, name, out):
    t0 = time.time()
    cpu0 = dev.cpu()
    pss0 = dev.pss_kb(PACKAGE)
    # A phase file starts at a keyframe; without one it records nothing.
    for s in streams:
        phone.client.send_json({"t": "window.keyframe", "stream": s})
    time.sleep(0.4)
    for s in streams:
        phone.rec.begin_phase(s, os.path.join(out, "cost-%s-s%d.h264" % (name, s)))
    down = True
    while time.time() - t0 < MEASURE_S:
        for s in streams:
            phone.client.send_raw(proto.pack_scroll(s, 0.5, 0.5, 0.0, 0.6 if down else -0.6))
        down = not down
        time.sleep(0.15)
    elapsed = time.time() - t0
    frames = {s: phone.rec.end_phase(s) for s in streams}
    time.sleep(1.0)
    cpu1 = dev.cpu()
    pss1 = dev.pss_kb(PACKAGE)
    fps = {s: (frames[s] / elapsed) for s in streams}
    row = {
        "windows": len(streams), "seconds": round(elapsed, 1), "streams": streams,
        "frames": frames, "fps": {s: round(v, 2) for s, v in fps.items()},
        "interval_ms": {s: (round(1000.0 / fps[s], 1) if fps[s] else None) for s in streams},
        "cpu_swcodec": round(cpu1["procs"].get("media.swcodec", 0.0), 1),
        "cpu_pocketdeck": round(cpu1["procs"].get(PACKAGE, 0.0), 1),
        "pss_kb": pss1, "pss_delta_kb": (pss1 - pss0) if (pss1 and pss0) else None,
        "encoders": len(streams),
    }
    print("[cost] windows=%d encoders=%d fps=%s interval_ms=%s swcodec=%s%% pd=%s%% pss=%sKB"
          % (row["windows"], row["encoders"],
             " ".join("s%d %.2f" % (s, fps[s]) for s in streams),
             " ".join("s%d %s" % (s, row["interval_ms"][s]) for s in streams),
             row["cpu_swcodec"], row["cpu_pocketdeck"], row["pss_kb"]), flush=True)
    return row


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--adb", required=True)
    ap.add_argument("--serial", default="emulator-5554")
    ap.add_argument("--wt", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)

    global deckctl, proto
    sys.path.insert(0, os.path.join(args.wt, "tools", "fakephone"))
    import deckctl
    import proto  # noqa: F401  (deckctl's framing needs it imported beside)

    dev = Dev(args.adb, args.serial, args.out)
    summary = {"checks": [], "cost": []}

    def save():
        with open(os.path.join(args.out, "summary.json"), "w") as fp:
            json.dump(summary, fp, indent=2)

    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(args.host, args.port, state, None)
    log("session up on %s:%d" % (args.host, args.port))

    # apps.list before the recorder starts: only one reader at a time.
    client.send_json({"t": "apps.list"})
    apps = deckctl.expect_json(client, "apps").get("apps", [])
    listed = check_apps(apps)
    summary["apps"] = {pkg: {"multi": app.get("multi")} for pkg, app in listed.items()}
    save()

    phone = Phone(client, deckctl.StreamRecorder(client).start())
    try:
        first, second = check_two_windows(phone, dev)
        page = LocalPage(dev, args.out)
        try:
            check_label(phone, dev, page)
        finally:
            page.stop()
        check_close(phone, dev, first, second)
        others = {"clock": "com.google.android.deskclock" if "com.google.android.deskclock" in listed
                  else "com.android.deskclock" if "com.android.deskclock" in listed else None}
        streams = check_cap(phone, dev, others)
        for name in (4, 3, 2, 1):
            row = cost_phase(phone, dev, list(streams[:name]), "%dw" % name, args.out)
            summary["cost"].append(row)
            if len(streams) > name:
                close_window(phone, streams[name])
                time.sleep(1.0)
        close_window(phone, 2)
    finally:
        summary["checks"] = [{"ok": ok, "tag": tag, "line": line} for ok, tag, line in RESULTS]
        save()
        phone.rec.stop()
        dev.dump("recents-end", "dumpsys", "activity", "recents")
        dev.dump("activities-end", "dumpsys", "activity", "activities")
        dev.dump("display-end", "dumpsys", "display")

    failed = [r for r in RESULTS if not r[0]]
    print("# %d checks, %d failed" % (len(RESULTS), len(failed)), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
