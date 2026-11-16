#!/usr/bin/env python3
"""MCP act e2e suite (docs/specs/mcp.md MCP-8, MCP-64, MCP-80…83).

Every input tool answers the act envelope: what it did, the settle, the
window's state and frame after it and, by default, the tree read after the
settle; never `ok`. The fake phone's settle modes are switched through its
`--mode-file` (the `fake-mode` file beside the events log), so one run sees a
settle, a screen that never stops, a spinner, a phone that never answers the
settle and an app that exits on back. Run it through driver.py (`--suite act`).
"""

import json
import os
import time

from common import MCP, report


def mode(args, *words):
    """Set the fake phone's modes for the requests that follow."""
    path = os.path.join(os.path.dirname(os.path.abspath(args.events)), "fake-mode")
    with open(path + ".tmp", "w") as handle:
        handle.write(" ".join(words) + "\n")
    os.rename(path + ".tmp", path)


def open_window(client):
    """Wait for the phone's app list (this suite may run first), then open
    Settings; the last error is in the failure."""
    deadline = time.time() + 30
    while time.time() < deadline:
        reply = client.tool("list_apps")
        apps = (reply.get("structuredContent") or {}).get("apps") or []
        if any(a.get("package") == "com.android.settings" for a in apps):
            break
        time.sleep(0.5)
    last = None
    for _ in range(40):
        reply = client.tool("open_app", {"app": "com.android.settings"})
        if not reply.get("isError"):
            window = (reply.get("structuredContent") or {}).get("window")
            if window:
                return window
        last = (reply.get("content") or [{}])[0].get("text")
        time.sleep(0.25)
    raise RuntimeError("open_app gave no window (%s)" % last)


def act(client, name, arguments):
    """The answer object and the call's wall time."""
    started = time.monotonic()
    reply = client.tool(name, arguments, timeout=30)
    elapsed = time.monotonic() - started
    if reply.get("isError"):
        raise RuntimeError("%s failed: %s" % (name, (reply.get("content") or [{}])[0].get("text")))
    return reply.get("structuredContent") or {}, elapsed


def live(client, window):
    """Wait for the window's first frame: input before it is not_ready (MCP-85)."""
    for _ in range(40):
        rows = client.text("list_windows").get("windows") or []
        if any(row.get("id") == window and row.get("state") == "live" for row in rows):
            return True
        time.sleep(0.25)
    return False


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-act", "version": "1"}})
        client.notify("notifications/initialized")
        mode(args)
        window = open_window(client)
        report(live(client, window), "MCP [MCP-81] setup: the act window is live")

        # [MCP-80] [MCP-81] A point tap settles and observes by default.
        answer, _ = act(client, "tap", {"window": window, "x": 0.5, "y": 0.65})
        settle = answer.get("settle") or {}
        report("ok" not in answer, "[MCP-80] MCP tap answers the envelope with no ok key")
        report((answer.get("did") or {}).get("action") == "tap"
               and (answer.get("did") or {}).get("at") == [0.5, 0.65],
               "[MCP-80] MCP tap's did names the point it pressed (%s)" % answer.get("did"))
        report(isinstance((answer.get("on") or {}).get("frame"), int),
               "[MCP-80] MCP tap's on names the frame current at the input (%s)" % answer.get("on"))
        report(settle.get("state") == "settled" and 120 <= (settle.get("waitedMs") or -1) <= 1000,
               "[MCP-81] MCP tap settles: %s" % json.dumps(settle))
        nodes = ((answer.get("tree") or {}).get("nodes")) or []
        report(len(nodes) > 0, "[MCP-82] MCP tap observes the tree after the settle (%d nodes)" % len(nodes))

        # [MCP-80] [MCP-87] With a tree read, a point tap names the node under it.
        on = answer.get("on") or {}
        report(on.get("snapshot") is None or isinstance(on.get("snapshot"), int),
               "[MCP-87] MCP tap's on.snapshot is the tree the hit came from (%s)" % on)

        # [MCP-81] A screen that never stops answers still_changing at 2 s.
        mode(args, "never-settle")
        answer, elapsed = act(client, "tap", {"window": window, "x": 0.5, "y": 0.65})
        settle = answer.get("settle") or {}
        report(settle.get("state") == "still_changing" and settle.get("reason") == "changes"
               and 1900 <= (settle.get("waitedMs") or -1) <= 2100 and elapsed < 3.5,
               "[MCP-81] MCP a screen that never stops: %s in %.2f s" % (json.dumps(settle), elapsed))

        # [MCP-103] [MCP-107] A spinner: still_changing for loading, and the tree says loading.
        mode(args, "settle-loading")
        answer, _ = act(client, "tap", {"window": window, "x": 0.5, "y": 0.65})
        settle = answer.get("settle") or {}
        tree = answer.get("tree") or {}
        report(settle.get("state") == "still_changing" and settle.get("reason") == "loading",
               "[MCP-107] MCP a spinner answers still_changing for loading: %s" % json.dumps(settle))
        report(tree.get("loading") is True,
               "[MCP-103] MCP the observed tree carries loading: true (%s)" % tree.get("loading"))

        # [MCP-8] A phone that never answers the settle: the call's bound answers.
        mode(args, "ignore-ui-settle")
        answer, elapsed = act(client, "tap", {"window": window, "x": 0.5, "y": 0.65})
        settle = answer.get("settle") or {}
        report(settle.get("state") == "still_changing" and elapsed < 5.5,
               "[MCP-8] MCP a settle the phone never answers ends at the bound: %s in %.2f s"
               % (json.dumps(settle), elapsed))
        mode(args)

        # [MCP-81] wait none, observe none: nothing waited, nothing read.
        answer, elapsed = act(client, "swipe", {"window": window, "x1": 0.5, "y1": 0.7,
                                                "x2": 0.5, "y2": 0.3, "ms": 100,
                                                "wait": "none", "observe": "none"})
        report((answer.get("settle") or {}).get("state") == "not_waited" and "tree" not in answer,
               "[MCP-81] MCP wait none answers not_waited and no tree (%s)" % answer.get("settle"))

        # [MCP-64] A screenshot that waits says how the settle went.
        reply = client.tool("screenshot", {"window": window, "wait": "settle"}, timeout=30)
        shot = reply.get("structuredContent") or {}
        report(not reply.get("isError") and (shot.get("settle") or {}).get("state") == "settled",
               "[MCP-64] MCP screenshot with wait settle carries settle (%s)" % shot.get("settle"))

        # [MCP-83] Back on the app's last screen closes the window: an answer, not an error.
        mode(args, "close-on-back")
        reply = client.tool("press_key", {"window": window, "key": "back"}, timeout=30)
        answer = reply.get("structuredContent") or {}
        report(not reply.get("isError") and answer.get("state") == "closed"
               and (answer.get("closed") or {}).get("reason") == "app_exited"
               and (answer.get("settle") or {}).get("state") == "window_closed"
               and "tree" not in answer,
               "[MCP-83] MCP press_key back that ends the app answers closed: %s"
               % json.dumps({k: answer.get(k) for k in ("state", "closed", "settle")}))
        mode(args)
    finally:
        mode(args)
        client.close()
