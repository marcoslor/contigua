#!/usr/bin/env python3
"""MCP input e2e suite (docs/specs/mcp.md MCP-88, MCP-90; plan T2).

`tap` with `holdMs` is the long press, and `swipe` takes a direction through
the window's centre. The fake phone's event log is the proof of what TOUCH
frames reached it. Run it through driver.py (`--suite input`).
"""

import time

from common import MCP, events, mode, report, within_px
from suite_act import live, open_window


def touches(path, window, since):
    return sorted((e for e in events(path)
                   if e.get("ev") == "input" and e.get("kind") == "touch"
                   and e.get("stream") == window and e.get("ts", 0) >= since),
                  key=lambda e: e.get("ts", 0))


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-input", "version": "1"}})
        client.notify("notifications/initialized")
        mode(args)
        window = open_window(client)
        report(live(client, window), "MCP [MCP-88] setup: the input window is live")
        rows = client.text("list_windows").get("windows") or []
        row = next((r for r in rows if r.get("id") == window), {})
        width, height = (row.get("size") or [1080, 2340])[:2]
        quick = {"wait": "none", "observe": "none"}

        # [MCP-88] A held tap: down, then up 600 ms later.
        since = time.time()
        reply = client.tool("tap", dict(quick, window=window, x=0.35, y=0.6, holdMs=600), timeout=30)
        did = (reply.get("structuredContent") or {}).get("did") or {}
        report(not reply.get("isError") and did.get("holdMs") == 600,
               "[MCP-88] MCP tap holdMs 600 is accepted and its did says holdMs (%s)" % did)
        time.sleep(0.8)  # let the frames land in the log
        log = touches(args.events, window, since)
        down = next((e for e in log if e.get("action") == 0 and within_px(e.get("nx", -1), 0.35, width)
                     and within_px(e.get("ny", -1), 0.6, height)), None)
        up = next((e for e in log if e.get("action") == 1 and down and e["ts"] >= down["ts"]), None)
        held = (up["ts"] - down["ts"]) if down and up else -1
        report(0.5 <= held <= 1.5, "[MCP-88] MCP tap holdMs 600 holds the press %.0f ms" % (held * 1000))

        # [MCP-90] A direction swipe: up through the window's centre, 60 % of its height.
        since = time.time()
        reply = client.tool("swipe", dict(quick, window=window, direction="up"), timeout=30)
        report(not reply.get("isError"), "[MCP-90] MCP swipe direction up is accepted")
        time.sleep(0.8)
        log = touches(args.events, window, since)
        down = next((e for e in log if e.get("action") == 0), {})
        up = next((e for e in log if e.get("action") == 1), {})
        moves = [e for e in log if e.get("action") == 2]
        report(within_px(down.get("nx", -1), 0.5, width) and within_px(down.get("ny", -1), 0.8, height)
               and within_px(up.get("nx", -1), 0.5, width) and within_px(up.get("ny", -1), 0.2, height),
               "[MCP-90] MCP swipe up goes down at (0.5, 0.8) and up at (0.5, 0.2) (%s, %s → %s, %s)"
               % (down.get("nx"), down.get("ny"), up.get("nx"), up.get("ny")))
        report(len(moves) >= 5 and all(a.get("ny", 0) >= b.get("ny", 0) for a, b in zip(moves, moves[1:])),
               "[MCP-90] MCP swipe up moves the finger up (%d moves)" % len(moves))
    finally:
        client.close()
