#!/usr/bin/env python3
"""MCP read-less e2e suite (docs/specs/mcp.md MCP-34, MCP-74, MCP-75, MCP-82,
MCP-104, MCP-106; plan T9, #170).

`list_apps` with a query, `ui_tree`'s text view and `find` over the fake
phone's fixed tree: a Continue button, a password field, a search field
showing its hint, and a list with three rows on screen and five below it.
Run it through driver.py (`--suite read`).
"""

import time

from common import MCP, events, report
from suite_act import mode, open_window


def by_text(tree, text):
    return next((n for n in tree.get("nodes") or [] if n.get("text") == text), None)


def tree_reads(path, stream):
    """How many nodes each of the fake phone's ui.tree answers held, in order."""
    return [e.get("nodes") for e in events(path)
            if e.get("ev") == "ui.tree" and e.get("stream") == stream]


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-read", "version": "1"}})
        client.notify("notifications/initialized")
        mode(args)
        window = open_window(client)
        time.sleep(1.0)

        # [MCP-34] A query keeps the matches; without one, every app.
        every = client.text("list_apps")
        sett = client.text("list_apps", {"query": "sett"})
        labels = [a.get("label") for a in sett.get("apps") or []]
        report(labels == ["Settings"] and sett.get("total") == 1,
               "[MCP-34] MCP list_apps {query: sett} answers Settings alone, total 1 (%s, %s)"
               % (labels, sett.get("total")))
        folded = client.text("list_apps", {"query": "SÉTT"})
        report([a.get("label") for a in folded.get("apps") or []] == ["Settings"],
               "[MCP-34] MCP list_apps ignores case and accents in query")
        one = client.text("list_apps", {"limit": 1})
        report(len(every.get("apps") or []) > 1 and every.get("total") == len(every["apps"])
               and len(one.get("apps") or []) == 1 and one.get("total") == every.get("total"),
               "[MCP-34] MCP list_apps without query answers every app and total; limit caps the rows only")

        # [MCP-74] [MCP-104] [MCP-106] The text view names what the tree holds.
        plain = client.text("ui_tree", {"window": window})
        button = by_text(plain, "Continue") or {}
        lists = [n for n in plain.get("nodes") or [] if n.get("scroll")]
        listing = lists[0] if lists else {}
        view = client.text("ui_tree", {"window": window, "format": "text"})
        text = view.get("text") or ""
        report(view.get("format") == "text" and "nodes" not in view
               and ("Continue [%s Button]" % button.get("ref")) in text.split("\n"),
               "[MCP-74] MCP ui_tree {format: text} has the line Continue [%s Button]" % button.get("ref"))
        report("Search (hint) [e9 EditText edit focus]" in text.split("\n")
               and "[e3 EditText edit pwd]" in text.split("\n"),
               "[MCP-104] MCP the text view reads a shown hint as a hint, and a password field with no text")
        hidden = listing.get("hidden") or [0, 0]
        line = "[%s RecyclerView scroll, %d before, %d after]" % (listing.get("ref"), hidden[0], hidden[1])
        report(hidden[1] > 0 and line in text.split("\n"),
               "[MCP-106] MCP the text view ends the list's line with its counts (%s)" % line)

        # [MCP-75] [MCP-106] find reaches a row below the display and names
        # the list to swipe; a plain read never asks for off-screen rows.
        reads_before = len(tree_reads(args.events, window))
        found = client.text("ui_tree", {"window": window, "find": "row 7"})
        time.sleep(0.3)
        reads = tree_reads(args.events, window)[reads_before:]
        nodes = found.get("nodes") or []
        match = nodes[0] if len(nodes) == 1 else {}
        report(match.get("text") == "Row 7" and match.get("off") is True and "at" not in match
               and match.get("where") == "below"
               and match.get("in") == listing.get("ref") and found.get("matched") == 1
               and found.get("total") == len(plain.get("nodes") or []) + (plain.get("omitted") or 0),
               "[MCP-106] MCP ui_tree {find} answers an off-screen row off, with no at, where and in the list's ref (%s)"
               % {k: match.get(k) for k in ("ref", "off", "where", "in")})
        report(len(reads) == 1 and reads[0] == found.get("total")
               and reads[0] > len(plain.get("nodes") or []),
               "[MCP-106] MCP find reads the off-screen rows too (%s nodes, a plain read %d)"
               % (reads, len(plain.get("nodes") or [])))
        none = client.tool("ui_tree", {"window": window, "find": "nowhere at all"})
        answer = none.get("structuredContent") or {}
        report(not none.get("isError") and answer.get("nodes") == [] and answer.get("matched") == 0,
               "[MCP-75] MCP ui_tree {find} with no match answers nodes [] and matched 0, not an error")

        # [MCP-82] observe: "text" answers the text view in place of the tree.
        waited = client.text("wait", {"window": window, "ms": 50, "observe": "text"})
        report("tree" not in waited
               and ("Continue [%s Button]" % button.get("ref")) in (waited.get("text") or "").split("\n"),
               "[MCP-82] MCP wait {observe: text} carries the text view, not the tree")

        # [MCP-34] An unknown app points at list_apps' query.
        missing = client.tool("open_app", {"app": "zz no such app"})
        report(missing.get("isError")
               and "Call list_apps with a query to find it." in (missing.get("content") or [{}])[0].get("text", ""),
               "[MCP-34] MCP open_app on an unknown app says to call list_apps with a query")
    finally:
        mode(args)
        client.close()
