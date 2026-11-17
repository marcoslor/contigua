#!/usr/bin/env python3
"""MCP windows-ledger e2e suite (docs/specs/mcp.md MCP-53, MCP-102, plan T7).

Two shim clients share the phone: a window one opens and the other closes is
answered to the first as closed by `another_agent`, and a client that exits
leaves its windows open with their opener kept. Run it through driver.py
(`--suite windows`).
"""

import json
import time

from common import MCP, events, report


def open_settings(client):
    deadline = time.time() + 30
    while time.time() < deadline:
        apps = (client.tool("list_apps").get("structuredContent") or {}).get("apps") or []
        if any(a.get("package") == "com.android.settings" for a in apps):
            break
        time.sleep(0.5)
    last = None
    for _ in range(40):
        reply = client.tool("open_app", {"app": "com.android.settings", "newWindow": True})
        if not reply.get("isError"):
            window = (reply.get("structuredContent") or {}).get("window")
            if window:
                return window
        last = (reply.get("content") or [{}])[0].get("text")
        time.sleep(0.25)
    raise RuntimeError("open_app gave no window (%s)" % last)


def error_of(reply):
    try:
        return json.loads(reply["content"][0]["text"]).get("error") or {}
    except (KeyError, IndexError, ValueError):
        return {}


def suite(args):
    a = MCP(args.shim, args.profile)
    b = MCP(args.shim, args.profile)
    try:
        for client in (a, b):
            client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                          "clientInfo": {"name": "suite-windows", "version": "1"}})
            client.notify("notifications/initialized")

        # [MCP-53] A opens, B closes: A sees why and by whom.
        window = open_settings(a)
        b.text("close_window", {"window": window})
        time.sleep(0.5)
        listing = a.text("list_windows")
        record = [r for r in listing.get("recentlyClosed") or [] if r.get("id") == window]
        report(bool(record) and record[0].get("closedBy") == "another_agent"
               and record[0].get("reason") == "closed",
               "[MCP-53] MCP a window another agent closed is in recentlyClosed with closedBy another_agent (%r)"
               % (record[:1],))
        reply = a.tool("tap", {"window": window, "x": 0.5, "y": 0.5})
        error = error_of(reply)
        closed = error.get("closed") or {}
        report(reply.get("isError") and error.get("code") == "no_window"
               and closed.get("reason") == "closed" and closed.get("closedBy") == "another_agent"
               and isinstance(closed.get("closedAgoMs"), int),
               "[MCP-53] MCP a tap on it fails no_window with that closed record (%r)" % (error,))
    finally:
        a.close()

    # [MCP-102] A opens Settings and exits; B still sees it, opened by another agent.
    a = MCP(args.shim, args.profile)
    try:
        a.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "suite-windows-a", "version": "1"}})
        a.notify("notifications/initialized")
        window = open_settings(a)
    finally:
        a.close()
    try:
        time.sleep(1.0)
        rows = [w for w in b.text("list_windows").get("windows") or [] if w.get("id") == window]
        report(bool(rows) and rows[0].get("openedBy") == "another_agent",
               "[MCP-102] MCP a window whose client exited stays open, openedBy another_agent (%r)" % (rows[:1],))
        closes = [e for e in events(args.events) if e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                  and e["msg"].get("t") == "window.close" and e["msg"].get("stream") == window]
        report(not closes, "[MCP-102] MCP the phone saw no window.close for it")
        b.text("close_window", {"window": window})
    finally:
        b.close()
