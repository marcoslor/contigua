#!/usr/bin/env python3
"""MCP opens answer like actions (docs/specs/mcp.md MCP-41, MCP-43, MCP-44,
plan T6).

`open_app` answers the opened-window shape after the first frame and a settle,
a second `open_app` raises the same window, `send_link` answers the window it
opened (a `link` row in `list_windows`) and `send_file` waits for the phone's
`drop.result`. Run it through driver.py (`--suite open`).
"""

import os
import time

from common import MCP, report


def wait_for_apps(client, package):
    deadline = time.time() + 30
    while time.time() < deadline:
        apps = (client.tool("list_apps").get("structuredContent") or {}).get("apps") or []
        if any(a.get("package") == package for a in apps):
            return True
        time.sleep(0.5)
    return False


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-open", "version": "1"}})
        client.notify("notifications/initialized")
        wait_for_apps(client, "com.android.settings")
        # An earlier suite may have left Settings open: a new window needs none.
        for row in client.text("list_windows").get("windows") or []:
            if row.get("package") == "com.android.settings":
                client.tool("close_window", {"window": row.get("id")})
        time.sleep(0.5)

        # [MCP-41] a new window: first frame, settle, tree.
        start = time.time()
        first = client.tool("open_app", {"app": "com.android.settings"}, timeout=30)
        took = time.time() - start
        body = first.get("structuredContent") or {}
        settle = body.get("settle") or {}
        nodes = (body.get("tree") or {}).get("nodes") or []
        size = body.get("size") or []
        report(not first.get("isError") and body.get("opened") == "new"
               and body.get("openedBy") == "you" and body.get("kind") == "app"
               and settle.get("state") == "settled" and len(nodes) > 0
               and len(size) == 2 and all(isinstance(v, int) and v > 0 for v in size)
               and "ok" not in body and took < 20,
               "[MCP-41] MCP open_app answers opened new, a settled settle and a tree (%r, %.1f s)"
               % ({k: body.get(k) for k in ("window", "opened", "openedBy", "kind", "size",
                                             "settle", "state")}, took))
        window = body.get("window")

        # [MCP-41] again: the same window, raised.
        again = client.tool("open_app", {"app": "com.android.settings"}, timeout=30)
        body2 = again.get("structuredContent") or {}
        report(not again.get("isError") and body2.get("opened") == "raised"
               and body2.get("window") == window and body2.get("openedBy") == "you",
               "[MCP-41] MCP a second open_app answers opened raised on the same window (%r)"
               % ({k: body2.get(k) for k in ("window", "opened", "openedBy")},))

        # [MCP-43] send_link answers its window, listed as a link window.
        link = client.tool("send_link", {"url": args.link}, timeout=30)
        body3 = link.get("structuredContent") or {}
        link_window = body3.get("window")
        rows = (client.text("list_windows").get("windows") or [])
        row = [r for r in rows if r.get("id") == link_window]
        report(not link.get("isError") and isinstance(link_window, int)
               and body3.get("kind") == "link" and bool(row) and row[0].get("kind") == "link",
               "[MCP-43] MCP send_link answers its window and list_windows has it as a link (%r)"
               % ({k: body3.get(k) for k in ("window", "kind", "opened", "settle", "state")},))

        # [MCP-44] the 1 MiB file waits for the phone's drop.result.
        drop = client.tool("send_file", {"path": args.file}, timeout=40)
        body4 = drop.get("structuredContent") or {}
        report(not drop.get("isError") and body4.get("state") == "delivered"
               and body4.get("bytes") == os.path.getsize(args.file)
               and set(body4.keys()) == {"bytes", "state"},
               "[MCP-44] MCP send_file answers delivered with its bytes and no name (%r)" % (body4,))
    finally:
        client.close()
