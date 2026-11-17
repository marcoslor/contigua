#!/usr/bin/env python3
"""MCP core e2e suite (docs/design/mcp.md, docs/specs/mcp.md).

Speaks MCP to Contigua through the built stdio shim, then reads the fakephone
event log to prove what reached the phone: INPUT frames, the link and a dropped
file, plus a screenshot decoded from the image content it got back. Run it
through driver.py (`--suite core`).
"""

import base64
import hashlib
import json
import os
import re
import time

from common import MCP, TOOLS, events, png_stats, report, wait_event, within_px


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        initialize = client.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "contigua-e2e", "version": "1"},
        }, timeout=30)
        result = initialize.get("result") or {}
        report(result.get("protocolVersion") == "2025-06-18",
               "MCP initialize answers revision 2025-06-18")
        client.notify("notifications/initialized")

        listing = client.request("tools/list", {}, timeout=30).get("result") or {}
        names = [tool.get("name") for tool in listing.get("tools") or []]
        report(sorted(names) == sorted(TOOLS),
               "MCP tools/list has all %d tools" % len(TOOLS))
        report(all(isinstance(t.get("inputSchema"), dict) and
                   t["inputSchema"].get("type") == "object" for t in listing.get("tools") or []),
               "MCP every tool carries an object input schema")

        # The phone connects shortly after launch.
        status = None
        deadline = time.time() + 60
        while time.time() < deadline:
            status = client.text("phone_status")
            if status.get("connected"):
                break
            time.sleep(0.5)
        report(bool(status and status.get("connected")), "MCP phone_status reports a connected phone")
        report((status or {}).get("name") == "FakePhone",
               "MCP phone_status names the fakephone")
        report((status or {}).get("battery") == 87 and (status or {}).get("charging") is False,
               "MCP phone_status carries the fakephone battery (87 %, not charging)")

        apps = []
        settings = []
        deadline = time.time() + 30
        while time.time() < deadline:
            apps = client.text("list_apps").get("apps") or []
            settings = [a for a in apps if a.get("package") == "com.android.settings"]
            if settings:
                break
            time.sleep(0.5)
        report(bool(settings) and settings[0].get("label") == "Settings",
               "MCP list_apps lists Settings (com.android.settings)")

        # Only this suite's opens count: an earlier suite (act) opened its own.
        opens_since = time.time()
        opened = client.text("open_app", {"app": "com.android.settings"})
        window = opened.get("window")
        report(isinstance(window, int) and opened.get("package") == "com.android.settings",
               "MCP open_app opens a window for com.android.settings")
        windows = client.text("list_windows").get("windows") or []
        match = [w for w in windows if w.get("id") == window]
        report(bool(match) and match[0].get("package") == "com.android.settings",
               "MCP list_windows shows that window and its package")

        # [WIN-2] The same app asked for again is raised, not reopened: one
        # window, one window.open on the wire.
        again = client.text("open_app", {"app": "com.android.settings"})
        report(again.get("window") == window,
               "MCP open_app again raises the same window")
        time.sleep(1)
        opens = 0
        try:
            for raw in open(args.events, errors="replace"):
                try:
                    event = json.loads(raw)
                except ValueError:
                    continue
                msg = event.get("msg") or {}
                if (event.get("ev") == "rx" and msg.get("t") == "window.open"
                        and msg.get("pkg") == "com.android.settings"
                        and event.get("ts", 0) >= opens_since):
                    opens += 1
        except OSError:
            opens = -1
        report(opens == 1, "MCP the second open_app sent no window.open (one on the wire)")
        settings_windows = [w for w in (client.text("list_windows").get("windows") or [])
                            if w.get("package") == "com.android.settings"]
        report(len(settings_windows) == 1, "MCP the app still has one window")

        # Wait for the stream's VIDEO_CONFIG: it gives the pixel size that makes
        # the coordinate and screenshot assertions meaningful.
        config = wait_event(args.events,
                            lambda e: e.get("ev") == "video" and e.get("config") and e.get("stream") == window,
                            45, "the window's video config")
        width, height = config.get("w"), config.get("h")
        report(isinstance(width, int) and width > 0 and isinstance(height, int) and height > 0,
               "MCP the fakephone configured the window's stream (%sx%s)" % (width, height))

        # [WIN-79] The accessibility tree: a label, the button with its tap
        # point, and a password field that carries no text.
        tree = client.text("ui_tree", {"window": window})
        nodes = tree.get("nodes") or []
        button = next((n for n in nodes if n.get("text") == "Continue"), None)
        report(bool(button and button.get("click")),
               "MCP ui_tree lists the window's button with its text and click")
        report(bool(button and isinstance(button.get("at"), list) and len(button["at"]) == 2
                    and all(isinstance(v, (int, float)) and 0 <= v <= 1 for v in button["at"])),
               "MCP ui_tree gives the button a tap point in 0..1")
        report(bool(button and button.get("id") == "continue"),
               "MCP ui_tree keeps the view id")
        report(isinstance(tree.get("displayId"), int) and tree["displayId"] > 0,
               "MCP ui_tree names the window's display id")
        report(isinstance(tree.get("size"), list) and len(tree["size"]) == 2,
               "MCP ui_tree names the pixel space box is in")
        report(tree.get("snapshot") is not None,
               "MCP ui_tree names the read a tap can refer back to")
        report("l" not in (button or {}),
               "MCP ui_tree leaves out the layer index when the display has one layer")
        password = next((n for n in nodes if n.get("pwd")), None)
        report(password is not None and "text" not in password,
               "MCP ui_tree marks the password field and sends no text for it")
        read = wait_event(args.events,
                          lambda e: e.get("ev") == "ui.tree" and e.get("stream") == window,
                          5, "the fakephone's ui.tree read")
        report(read is not None, "MCP ui_tree reached the phone once")
        # A ref names an element: tapping it lands on that element's point, the
        # late-bound way an agent should press instead of guessing coordinates.
        ref_point = (button or {}).get("at") or [0, 0]
        # No wait and no observe: a tree read after the tap would replace the
        # refs the off-screen and stale checks below use (S1).
        by_ref = client.text("tap", {"window": window, "ref": (button or {}).get("ref"),
                                     "wait": "none", "observe": "none"})
        did = by_ref.get("did") or {}
        pressed = did.get("at") or [-1, -1]
        report(abs(pressed[0] - ref_point[0]) < 1e-6 and abs(pressed[1] - ref_point[1]) < 1e-6,
               "MCP tap by ref resolves to the element's own point")
        report((by_ref.get("on") or {}).get("snapshot") == tree.get("snapshot")
               and did.get("box") == (button or {}).get("box"),
               "[MCP-80] MCP tap by ref echoes the read it came from and the node's box")
        report(isinstance(pressed[0], (int, float))
               and len(str(pressed[0]).split(".")[-1]) <= 3,
               "MCP tap by ref prints its point to three decimals")
        # [WIN-79 S1] The Mac names refs s<snapshot>e<row> from its own count.
        report(bool(nodes) and all(re.match(r"^s%se\d+$" % tree.get("snapshot"), n.get("ref") or "")
                                   for n in nodes),
               "MCP ui_tree's refs carry the answer's snapshot")
        # [WIN-79 F9] An off-screen node keeps its text, has no tap point, and
        # a tap by its ref is refused.
        below = next((n for n in nodes if n.get("text") == "Below the fold"), None)
        report(bool(below and below.get("off") is True and "at" not in below),
               "MCP ui_tree marks an off-screen node off with no tap point")
        try:
            client.text("tap", {"window": window, "ref": (below or {}).get("ref") or "s0e0"})
            report(False, "MCP tap by an off-screen ref must fail")
        except RuntimeError as error:
            report("off screen" in str(error), "MCP tap by an off-screen ref is refused")
        # [WIN-79 F1] A newer read makes the older refs stale: refused, naming both reads.
        newer = client.text("ui_tree", {"window": window})
        try:
            client.text("tap", {"window": window, "ref": (button or {}).get("ref")})
            report(False, "MCP tap by an older tree's ref must fail")
        except RuntimeError as error:
            report(("s%s" % tree.get("snapshot")) in str(error)
                   and ("s%s" % newer.get("snapshot")) in str(error),
                   "MCP tap by an older tree's ref is refused, naming both reads")
        # [MCP-6] A failure is a closed code a program switches on, with the
        # sentence for a model beside it.
        missing = client.tool("ui_tree", {"window": 999})
        try:
            failure = json.loads(missing["content"][0]["text"]).get("error") or {}
        except (KeyError, IndexError, ValueError):
            failure = {}
        report(missing.get("isError") is True
               and "No window 999" in (failure.get("message") or ""),
               "MCP ui_tree on an unknown window says which window is missing")
        report(failure.get("code") == "no_window" and failure.get("window") == 999
               and "structuredContent" not in missing,
               "[MCP-6] MCP ui_tree on an unknown window fails with code no_window")

        # The screenshot: correct size, top side <= 1280, not a flat frame.
        shot = None
        last_error = None
        for _ in range(20):
            reply = client.tool("screenshot", {"window": window}, timeout=30)
            content = (reply.get("content") or [{}])[0]
            if not reply.get("isError") and content.get("type") == "image":
                shot = content
                break
            last_error = content.get("text")
            time.sleep(0.25)
        if shot is None:
            raise RuntimeError("screenshot never returned an image (%s)" % (last_error or "no error text"))
        png = base64.b64decode(shot.get("data") or "")
        shot_width, shot_height, mean, low, high = png_stats(png)
        scale = min(1.0, 1280.0 / max(width, height))
        expected = (max(1, int(width * scale)), max(1, int(height * scale)))
        report(max(shot_width, shot_height) <= 1280,
               "MCP screenshot's longest side is at most 1280 px (%dx%d)" % (shot_width, shot_height))
        report(abs(shot_width - expected[0]) <= 1 and abs(shot_height - expected[1]) <= 1,
               "MCP screenshot has the expected size (expected %dx%d)" % expected)
        report(high - low >= 8 and 5 < mean < 250,
               "MCP screenshot is a real frame (mean luma %.1f, range %.0f..%.0f)" % (mean, low, high))

        # Input. Coordinates are the stream's normalized video coordinates; the
        # event log is checked below against the pixel size.
        client.text("tap", {"window": window, "x": 0.25, "y": 0.4})
        client.text("long_press", {"window": window, "x": 0.55, "y": 0.55, "ms": 250})
        swipe_ms = 400
        client.text("swipe", {"window": window, "x1": 0.2, "y1": 0.7,
                              "x2": 0.8, "y2": 0.3, "ms": swipe_ms})
        client.text("type_text", {"window": window, "text": "mcp test 123"})
        client.text("press_key", {"window": window, "key": "enter"})

        link = client.tool("send_link", {"url": args.link})
        report(not link.get("isError"), "MCP send_link is accepted")

        digest = hashlib.sha256(open(args.file, "rb").read()).hexdigest()
        name = os.path.basename(args.file)
        client.tool("send_file", {"path": args.file}, timeout=90)
        drop = wait_event(args.events,
                          lambda e: e.get("ev") == "drop" and e.get("ok")
                          and any(f.get("name") == name for f in e.get("files") or []),
                          120, "the dropped file")
        dropped = [f for f in drop.get("files") or [] if f.get("name") == name][0]
        report(dropped.get("size") == os.path.getsize(args.file) and dropped.get("sha256") == digest,
               "MCP send_file delivers %s with a matching sha256 (%s…)" % (name, digest[:12]))

        # The phone's log is the source of truth for what input frames arrived.
        wait_event(args.events, lambda e: e.get("ev") == "link" and e.get("url") == args.link,
                   30, "the link")
        report(True, "MCP send_link reaches the phone through link.open")

        time.sleep(0.8)  # let the last frames land in the log
        log = events(args.events)
        touches = [e for e in log if e.get("ev") == "input" and e.get("kind") == "touch"
                   and e.get("stream") == window]
        downs = [e for e in touches if e.get("action") == 0]
        ups = [e for e in touches if e.get("action") == 1]
        moves = [e for e in touches if e.get("action") == 2]

        # Tap: down+up at the same point.
        tap_down = [e for e in downs if within_px(e.get("nx", -1), 0.25, width)
                    and within_px(e.get("ny", -1), 0.4, height)]
        report(bool(tap_down), "MCP tap arrives as a TOUCH down within 1 px of (0.25, 0.4)")
        ref_down = [e for e in downs if within_px(e.get("nx", -1), ref_point[0], width)
                    and within_px(e.get("ny", -1), ref_point[1], height)]
        report(bool(ref_down), "MCP tap by ref arrives as a TOUCH down on that element's point")
        report(any(within_px(e.get("nx", -1), 0.25, width) and within_px(e.get("ny", -1), 0.4, height)
                   for e in ups), "MCP tap lifts at the same point")

        # Long press: down then up 250 ms later (some scheduling slack).
        long_down = [e for e in downs if within_px(e.get("nx", -1), 0.55, width)
                     and within_px(e.get("ny", -1), 0.55, height)]
        long_up = [e for e in ups if within_px(e.get("nx", -1), 0.55, width)
                   and within_px(e.get("ny", -1), 0.55, height)]
        held = (long_up[0]["ts"] - long_down[0]["ts"]) if long_down and long_up else 0
        report(bool(long_down and long_up and 0.15 <= held <= 1.5),
               "MCP long_press holds for %.0f ms" % (held * 1000))

        # Swipe: exactly one down at the start, interpolated moves, one up at the end.
        swipe_down = [e for e in downs if within_px(e.get("nx", -1), 0.2, width)
                      and within_px(e.get("ny", -1), 0.7, height)]
        swipe_up = [e for e in ups if within_px(e.get("nx", -1), 0.8, width)
                    and within_px(e.get("ny", -1), 0.3, height)]
        report(len(swipe_down) == 1 and len(swipe_up) == 1,
               "MCP swipe starts at (0.2, 0.7) and ends at (0.8, 0.3)")
        ordered = sorted(touches, key=lambda e: e.get("ts", 0))
        start_index = next((i for i, e in enumerate(ordered)
                            if e.get("action") == 0 and e in swipe_down), None)
        end_index = next((i for i, e in enumerate(ordered)
                          if e.get("action") == 1 and e in swipe_up), None)
        between = ordered[start_index:end_index] if start_index is not None and end_index is not None else []
        swipe_moves = [e for e in between if e.get("action") == 2]
        report(len(swipe_moves) >= 5,
               "MCP swipe interpolates at ~60 Hz (%d moves)" % len(swipe_moves))
        monotonic = all(0 <= e.get("nx", -1) <= 1 and 0 <= e.get("ny", -1) <= 1 for e in swipe_moves)
        report(monotonic and (not swipe_moves or
               (swipe_moves[0]["nx"] < swipe_moves[-1]["nx"] and swipe_moves[0]["ny"] > swipe_moves[-1]["ny"])),
               "MCP swipe moves run from the start towards the end")

        texts = [e for e in log if e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                 and e["msg"].get("t") == "text" and e["msg"].get("text") == "mcp test 123"
                 and e["msg"].get("stream") == window]
        report(bool(texts), "MCP type_text reaches the phone as the text frame")

        enter_down = [e for e in log if e.get("ev") == "input" and e.get("kind") == "key"
                      and e.get("stream") == window and e.get("action") == 0 and e.get("keycode") == 66]
        enter_up = [e for e in log if e.get("ev") == "input" and e.get("kind") == "key"
                    and e.get("stream") == window and e.get("action") == 1 and e.get("keycode") == 66]
        report(bool(enter_down and enter_up), "MCP press_key sends KEYCODE_ENTER down and up")

        # Four: the tap, the tap by ref, the long press and the swipe.
        report(len(downs) == 4 and len(ups) == 4,
               "MCP delivered four gestures (%d downs, %d ups, %d moves)" % (len(downs), len(ups), len(moves)))

        closed = client.text("close_window", {"window": window})
        wait_event(args.events, lambda e: e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                   and e["msg"].get("t") == "window.close" and e["msg"].get("stream") == window,
                   30, "window.close")
        report(closed.get("closed") == {"reason": "closed", "closedBy": "you"} and
               not [w for w in client.text("list_windows").get("windows") or [] if w.get("id") == window],
               "MCP close_window closes the window and tells the phone")
    finally:
        client.close()
