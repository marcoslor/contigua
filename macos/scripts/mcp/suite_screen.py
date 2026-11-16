#!/usr/bin/env python3
"""MCP screenshot freshness e2e suite (docs/specs/mcp.md MCP-20/21/22/50/60).

A screenshot is a frame from after the call: each one asks the fakephone for a
keyframe and its `frame.seq` grows; `size` is the window's pixels, the same as
`list_windows` says. A minimised (paused) window is resumed by the agent hold
for the call and pauses again by WIN's rule 15 s after it. Run it through
driver.py (`--suite screen`); the pause setup needs `--control`.
"""

import os
import time

from common import MCP, events, report, wait_event


def rx(log, kind, stream, since=0.0):
    return [e for e in log if e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
            and e["msg"].get("t") == kind and e["msg"].get("stream") == stream
            and e.get("ts", 0) >= since]


def control(directory, line, seq=[0]):
    """One debug-control command (DebugControl.swift); its one-line answer."""
    seq[0] += 1
    name = os.path.join(directory, "screen%d" % seq[0])
    with open(name + ".tmp", "w") as handle:
        handle.write(line + "\n")
    os.rename(name + ".tmp", name + ".cmd")
    deadline = time.time() + 10
    while time.time() < deadline:
        if os.path.exists(name + ".done") and os.path.getsize(name + ".done") > 0:
            with open(name + ".done") as handle:
                answer = handle.read().strip()
            os.remove(name + ".done")
            return answer
        time.sleep(0.1)
    return "no answer in 10 s"


def screenshot(client, window):
    """The screenshot's answer object, retried while the window opens."""
    last = None
    for _ in range(20):
        reply = client.tool("screenshot", {"window": window}, timeout=30)
        if not reply.get("isError"):
            return reply.get("structuredContent") or {}
        last = (reply.get("content") or [{}])[0].get("text")
        time.sleep(0.25)
    raise RuntimeError("screenshot never returned an image (%s)" % (last or "no error text"))


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "contigua-e2e-screen", "version": "1"},
        }, timeout=30)
        client.notify("notifications/initialized")
        deadline = time.time() + 60
        while time.time() < deadline and not client.text("phone_status").get("connected"):
            time.sleep(0.5)
        window = None
        deadline = time.time() + 30
        while time.time() < deadline and window is None:
            reply = client.tool("open_app", {"app": "com.android.settings"})
            if not reply.get("isError"):
                window = (reply.get("structuredContent") or {}).get("window")
            else:
                time.sleep(0.5)
        if not isinstance(window, int):
            raise RuntimeError("open_app gave no window")
        wait_event(args.events, lambda e: e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                   and e["msg"].get("t") == "window.open", 30, "window.open")

        # [MCP-60] Two screenshots: each asks for a keyframe, the seq grows.
        first = screenshot(client, window)
        before = len(rx(events(args.events), "window.keyframe", window))
        second = screenshot(client, window)
        after = len(rx(events(args.events), "window.keyframe", window))
        seq1 = (first.get("frame") or {}).get("seq")
        seq2 = (second.get("frame") or {}).get("seq")
        report(isinstance(seq1, int) and isinstance(seq2, int) and seq2 > seq1,
               "MCP [MCP-60] a second screenshot is a later frame (seq %s then %s)" % (seq1, seq2))
        report(first.get("state") == "live" and second.get("state") == "live",
               "MCP [MCP-21] both screenshots say state live")
        report(after - before == 1,
               "MCP [MCP-60] one window.keyframe per screenshot (%d)" % (after - before))
        image = second.get("image") or [0, 0]
        report(max(image) <= 1280 and min(image) > 0,
               "MCP [MCP-60] the image's longest side is at most 1280 px (%sx%s)" % tuple(image))
        rows = [w for w in client.text("list_windows").get("windows") or [] if w.get("id") == window]
        row = rows[0] if rows else {}
        report(row.get("size") == second.get("size") and "width" not in row,
               "MCP [MCP-50] list_windows' size is the screenshot's size (%s)" % row.get("size"))
        report(row.get("state") == "live" and isinstance((row.get("frame") or {}).get("seq"), int),
               "MCP [MCP-20] list_windows' row carries state and frame")

        # [MCP-22] A minimised window: the call resumes it, and it pauses again
        # by WIN's rule 15 s after the call.
        if not args.control:
            report(False, "MCP [MCP-22] the suite needs --control for the pause setup")
            return
        answer = control(args.control, "open --minimize-stream %d:0" % window)
        report(answer == "ok", "MCP [MCP-22] setup: minimise the window (%s)" % answer)
        paused = wait_event(args.events, lambda e: e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                            and e["msg"].get("t") == "window.pause"
                            and e["msg"].get("stream") == window, 15, "window.pause")
        time.sleep(1)
        called = time.time()
        shot = screenshot(client, window)
        done = time.time()
        log = events(args.events)
        resumes = rx(log, "window.resume", window, since=paused.get("ts", 0))
        keyframes = rx(log, "window.keyframe", window, since=called - 0.5)
        report(bool(resumes) and bool(keyframes) and resumes[0]["ts"] <= keyframes[0]["ts"],
               "MCP [MCP-22] the call resumes the paused window before its keyframe")
        report(shot.get("state") == "live",
               "MCP [MCP-22] the held window's screenshot says state live (%s)" % shot.get("state"))
        early = rx(events(args.events), "window.pause", window, since=done)
        repaused = None
        deadline = done + 20
        while time.time() < deadline and repaused is None:
            later = rx(events(args.events), "window.pause", window, since=done)
            repaused = later[0] if later else None
            time.sleep(0.2)
        held = (repaused["ts"] - done) if repaused else None
        report(not early and repaused is not None and 14 <= held <= 20,
               "MCP [MCP-22] the window pauses again 15 s after the call (%s s)"
               % (None if held is None else round(held, 1)))
        client.text("close_window", {"window": window})
    finally:
        client.close()
