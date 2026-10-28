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
LABEL_PAGE_TITLE_2 = "PocketDeck second page"
UI_DUMP = "/data/local/tmp/pd-mw-ui.xml"
MEASURE_S = 8.0
# An 8 s phase with a keyframe and a scroll every 150 ms: a live window draws far
# more than this, a dead one (or one whose phase missed its keyframe) draws fewer.
MIN_PHASE_FRAMES = 3
RESULTS = []


def check(ok, tag, message):
    RESULTS.append((bool(ok), tag, message))
    print("%s [%s] %s" % ("PASS" if ok else "FAIL", tag, message), flush=True)
    return bool(ok)


def log(message):
    print("[multiwin] %s" % message, flush=True)


class Dev(object):
    """The emulator side: dumps, uiautomator, process ids, shell."""

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

    def avc_encoders(self):
        """Live H.264 encoder instances the device lists (one per window is the
        phone's design); an empty list when the dump names none."""
        text = self.out_of("dumpsys", "media.codec")
        return [line.strip() for line in text.splitlines()
                if re.search(r"\b(c2|OMX)\.[\w.]*avc[\w.]*enc", line)]

    def pid(self, pkg):
        return self.out_of("pidof", pkg).strip()

    def dump(self, name, *args):
        path = os.path.join(self.out, "%s.txt" % name)
        with open(path, "w") as fp:
            fp.write(self.out_of(*args))
        return path


    def ui_xml(self):
        """The focused display's UI hierarchy (first-run dialogs live there)."""
        self.sh("uiautomator", "dump", "--compressed", UI_DUMP, timeout=60)
        return self.out_of("cat", UI_DUMP)

    def tap_text(self, want):
        """Tap the view whose text contains [want]; false when it is not there."""
        xml = self.ui_xml()
        for tag in re.findall(r"<node\b[^>]*>", xml):
            text = re.search(r'\btext="([^"]*)"', tag)
            if not text or want not in text.group(1):
                continue
            bounds = re.search(r'\bbounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', tag)
            if not bounds:
                continue
            a, b, c, d = map(int, bounds.groups())
            self.sh("input", "tap", (a + c) // 2, (b + d) // 2)
            return True
        return False


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


def logical_displays(text):
    """How many displays the phone tells `dumpsys display` it has (0 is the panel)."""
    m = re.search(r"Logical Displays: size=(\d+)", text)
    return int(m.group(1)) if m else -1


def tasks_on_display(display):
    return sorted(task for d, task, _pkg in activity_tasks(display) if d == display)


def recents(dev):
    return recents_tasks(dev.out_of("dumpsys", "activity", "recents"))


def displays(dev):
    return logical_displays(dev.out_of("dumpsys", "display"))


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

    def wait_title(self, stream, want, timeout=6.0, since=0):
        """(title, elapsed_s) once this stream's title carries [want], else (None, elapsed).

        [since] skips the messages already read, so a retry cannot match a title
        from an earlier attempt.
        """
        started = time.time()
        deadline = started + timeout
        while time.time() < deadline:
            with self.rec.lock:
                for msg in reversed(self.rec.messages[since:]):
                    if msg.get("t") != "window.title" or msg.get("stream") != stream:
                        continue
                    title = msg.get("title")
                    if title and want in title:
                        return title, time.time() - started
            time.sleep(0.02)
        return None, time.time() - started

    def mark(self):
        """How many messages have arrived: wait_title(since=…) counts from here."""
        with self.rec.lock:
            return len(self.rec.messages)

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


def await_key(rec, stream, timeout=5.0):
    """True once [stream] has delivered the keyframe its phase file waits for.

    A phase file starts at a keyframe: `begin_phase` drops deltas until one
    arrives, so the keyframe must be asked for *after* the phase begins (one
    that arrives before it is missed and the phase records nothing).
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        with rec.lock:
            if not rec.wait_key.get(stream, True):
                return True
        time.sleep(0.02)
    return False


def grab(phone, dev, stream, tag, out, seconds=1.5):
    """One PNG of what the window shows, decoded from its own stream.

    `screencap -d <id>` refuses a virtual display's id on API 36 ("Display Id
    '2' is not valid"), and the product's picture is the better evidence
    anyway: a window that renders has frames.
    """
    path = os.path.join(out, "cap-%s.h264" % tag)
    # The phase file is seeded with the stream's SPS/PPS, and an encoder sends
    # them in VIDEO_CONFIG: without it the file does not decode on its own.
    try:
        phone.rec.wait_for_size(stream, 10.0)
    except deckctl.DeckError:
        return None
    phone.rec.begin_phase(stream, path)
    phone.client.send_json({"t": "window.keyframe", "stream": stream})
    if not await_key(phone.rec, stream):
        phone.rec.end_phase(stream)
        return None
    time.sleep(seconds)
    frames = phone.rec.end_phase(stream)
    if frames == 0:
        return None
    png = os.path.join(out, "shot-%s.png" % tag)
    deckctl.dump_last_frame(path, png)
    return png


def send_tap(client, stream, nx, ny):
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, nx, ny))
    time.sleep(0.05)
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, nx, ny))


def send_key(client, stream, keycode):
    client.send_raw(proto.pack_key(stream, proto.KEY_DOWN, keycode, 0))
    time.sleep(0.03)
    client.send_raw(proto.pack_key(stream, proto.KEY_UP, keycode, 0))


def tap(phone, dev, out, stream, tag):
    """A tap through the product's own input path, proved by the picture."""
    before = grab(phone, dev, stream, "%s-before" % tag, out)
    luma = dev.luma(before)
    for nx, ny in ((0.5, 0.06), (0.5, 0.5)):
        send_tap(phone.client, stream, nx, ny)
        time.sleep(1.2)
        after = grab(phone, dev, stream, "%s-after" % tag, out)
        changed = dev.diff(before, after)
        if changed:
            return {"luma": luma, "diff": changed, "at": "%.2f,%.2f" % (nx, ny),
                    "before": before, "after": after}
    return {"luma": luma, "diff": None, "at": None, "before": before, "after": after}


class LocalPage(object):
    """Two pages with known titles, served to the emulator through `adb reverse`.

    The first page is one whole-viewport link to the second: a tap on it is the
    label change the check times, so no typing and no cold render sit inside the
    two seconds.
    """

    def __init__(self, dev, out):
        self.dev = dev
        self.dir = os.path.join(out, "page")
        os.makedirs(self.dir, exist_ok=True)
        with open(os.path.join(self.dir, "label.html"), "w") as fp:
            fp.write("<!doctype html><html><head><title>%s</title></head>"
                     "<body style='margin:0'><a href='label2.html' style='display:block;"
                     "width:100vw;height:100vh;font-size:48px;padding:40px;"
                     "box-sizing:border-box'>multiwin, tap for the second page</a></body></html>\n"
                     % LABEL_PAGE_TITLE)
        with open(os.path.join(self.dir, "label2.html"), "w") as fp:
            fp.write("<!doctype html><html><head><title>%s</title></head>"
                     "<body style='font-size:48px;padding:40px'>multiwin, second</body></html>\n"
                     % LABEL_PAGE_TITLE_2)
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

FIRST_RUN_BUTTONS = ("Accept & continue", "Use without an account", "No thanks", "Got it", "Next")


def warm_chrome(dev):
    """Launch Chrome once on the phone's own screen and get past its first run.

    Chrome's first-run screen is not a window's page: its tabs, its task
    description and its second instance all behave differently while it is up
    (the label stayed the app's, and the second task came up empty). One warm
    launch on display 0 settles it for every window after.
    """
    if not dev.pid(CHROME):
        dev.sh("am", "start", "-n", CHROME_MAIN, timeout=45)
        time.sleep(8)
    for _ in range(6):
        tapped = False
        for label in FIRST_RUN_BUTTONS:
            if dev.tap_text(label):
                log("dismissed Chrome's first run: %s" % label)
                tapped = True
                time.sleep(3)
                break
        if not tapped:
            break
    dev.sh("am", "force-stop", CHROME)
    time.sleep(2)
    return not dev.pid(CHROME)


def check_apps(apps):
    listed = {a.get("pkg"): a for a in apps}
    every = all("multi" in a for a in apps)
    chrome = listed.get(CHROME, {}).get("multi")
    settings = listed.get(SETTINGS, {}).get("multi")
    check(every, "WIN-24", "every app answers multi (%d apps)" % len(apps))
    check(chrome is True and settings is False, "WIN-24",
          "Chrome multi=%s, Settings multi=%s" % (chrome, settings))
    return listed


def check_two_windows(phone, dev, base, out):
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

    displays_now = displays(dev)
    # The positive control: if this metric did not move, the refusal check below
    # would pass for the wrong reason.
    check(base > 0 and displays_now == base + 2, "WIN-25",
          "two windows are two displays (dumpsys display: %s -> %s)" % (base, displays_now))

    shots = {s: grab(phone, dev, s, "b-s%d" % s, out) for s in (1, 2)}
    lumas = {s: dev.luma(p) for s, p in shots.items()}
    check(all(v is not None and v > 8 for v in lumas.values()), "WIN-25",
          "both displays render (%s)" % ", ".join("s%d luma=%s" % kv for kv in sorted(lumas.items())))

    taps = {s: tap(phone, dev, out, s, "b-s%d" % s) for s in (1, 2)}
    check(all(t["diff"] for t in taps.values()), "WIN-25",
          "both displays take a tap (%s)"
          % ", ".join("s%d at %s diff=%s" % (s, t["at"], t["diff"]) for s, t in sorted(taps.items())))
    return first, second


def check_label(phone, dev, page, out):
    third = open_window(phone, dev, 3, CHROME, new_instance=True)
    if not page.reversed:
        close_window(phone, 3)
        return check(False, "WIN-28", "adb reverse failed; no local page to navigate to")
    log("window 3 on display %s; the page is %s" % (third.get("displayId"), page.url()))
    # The window's own input, the way a person navigates one tab: focus the
    # address bar, type the local page, Return. No intent, so no task moves.
    # Chrome's bar height depends on the tab strip it drew, so a couple of
    # heights are tried; each waits only for a message that arrives after it.
    first = None
    for ny in (0.06, 0.11, 0.16):
        mark = phone.mark()
        send_tap(phone.client, 3, 0.5, ny)
        time.sleep(0.8)
        phone.client.send_json({"t": "text", "stream": 3, "text": page.url()})
        time.sleep(0.3)
        send_key(phone.client, 3, 66)
        first, _ = phone.wait_title(3, LABEL_PAGE_TITLE, timeout=6.0, since=mark)
        if first:
            log("the local page loaded after a tap at y=%.2f" % ny)
            break
    if first is None:
        log("window 3's picture: %s" % (grab(phone, dev, 3, "c-label", out) or "no frame"))
        close_window(phone, 3)
        return check(False, "WIN-28",
                     "the local page never became window.title (could not load %s)" % page.url())
    # The timed label change is the next one, and its clock starts at the tap
    # that asks for it: typing a URL and a cold first render are the harness's
    # work, not the phone's.
    mark = phone.mark()
    started = time.time()
    send_tap(phone.client, 3, 0.5, 0.5)
    title, _ = phone.wait_title(3, LABEL_PAGE_TITLE_2, timeout=4.0, since=mark)
    elapsed = time.time() - started
    ok = check(title is not None and elapsed <= 2.0, "WIN-28",
               "a label change reached window.title in %.2fs (%s)"
               % (elapsed, ("title len=%d" % len(title)) if title else "no title"))
    shot = grab(phone, dev, 3, "c-label", out)
    log("window 3's picture: %s" % (shot or "no frame"))
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


def check_cap(phone, dev, others, base):
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
    check(before_displays == after_displays and after_displays == base + 4, "WIN-32",
          "no fifth display was created (%s displays before, %s after; %s windows' worth)"
          % (before_displays, after_displays, after_displays - base))
    return [2, 4, 5, 6]


def cost_phase(phone, dev, streams, name, out):
    # A phase file starts at a keyframe; without one it records nothing. The
    # keyframe is asked for after `begin_phase`, which is what waits for it.
    for s in streams:
        try:
            phone.rec.wait_for_size(s, 10.0)
        except deckctl.DeckError:
            log("stream %d sent no VIDEO_CONFIG; its phase cannot decode" % s)
        phone.rec.begin_phase(s, os.path.join(out, "cost-%s-s%d.h264" % (name, s)))
    for s in streams:
        phone.client.send_json({"t": "window.keyframe", "stream": s})
    keys = {s: await_key(phone.rec, s) for s in streams}
    t0 = time.time()
    cpu0 = dev.cpu()
    pss0 = dev.pss_kb(PACKAGE)
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
    codecs = dev.avc_encoders()
    fps = {s: (frames[s] / elapsed) for s in streams}
    row = {
        "windows": len(streams), "seconds": round(elapsed, 1), "streams": streams,
        "frames": frames, "fps": {s: round(v, 2) for s, v in fps.items()},
        "keyframes": keys,
        "interval_ms": {s: (round(1000.0 / fps[s], 1) if fps[s] else None) for s in streams},
        "cpu_swcodec": round(cpu1["procs"].get("media.swcodec", 0.0), 1),
        "cpu_pocketdeck": round(cpu1["procs"].get(PACKAGE, 0.0), 1),
        "pss_kb": pss1, "pss_delta_kb": (pss1 - pss0) if (pss1 and pss0) else None,
        "encoders": len(streams), "codec_instances": len(codecs),
    }
    print("[cost] windows=%d encoders=%d codec_instances=%d fps=%s interval_ms=%s swcodec=%s%% pd=%s%% pss=%sKB"
          % (row["windows"], row["encoders"], row["codec_instances"],
             " ".join("s%d %.2f" % (s, fps[s]) for s in streams),
             " ".join("s%d %s" % (s, row["interval_ms"][s]) for s in streams),
             row["cpu_swcodec"], row["cpu_pocketdeck"], row["pss_kb"]), flush=True)
    # The cost table is only worth reading if every window it counts was drawing
    # (round 1's zero rows came from a phase that never saw its keyframe, and
    # from a window whose app had already exited). A live window under 8 s of
    # scrolls produces far more than MIN_PHASE_FRAMES.
    check(all(keys[s] and frames[s] >= MIN_PHASE_FRAMES for s in streams), "WIN-25",
          "%d window(s) all drawing (%s)" % (len(streams), " ".join(
              "s%d %d frames %.2f/s" % (s, frames[s], fps[s]) for s in streams)))
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

    if not warm_chrome(dev):
        log("warning: Chrome is still running after the warm-up")
    base_displays = displays(dev)
    log("displays before any window: %s" % base_displays)
    phone = Phone(client, deckctl.StreamRecorder(client).start())
    try:
        first, second = check_two_windows(phone, dev, base_displays, args.out)
        page = LocalPage(dev, args.out)
        try:
            check_label(phone, dev, page, args.out)
        finally:
            page.stop()
        check_close(phone, dev, first, second)
        others = {"clock": "com.google.android.deskclock" if "com.google.android.deskclock" in listed
                  else "com.android.deskclock" if "com.android.deskclock" in listed else None}
        streams = check_cap(phone, dev, others, base_displays)
        # At N live windows: the phase is measured with exactly N open, so the
        # table is the cost of that many encoders (the one below was still up
        # while round 1 measured "3").
        for name in (4, 3, 2, 1):
            row = cost_phase(phone, dev, list(streams[:name]), "%dw" % name, args.out)
            summary["cost"].append(row)
            if name > 1:
                close_window(phone, streams[name - 1])
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
