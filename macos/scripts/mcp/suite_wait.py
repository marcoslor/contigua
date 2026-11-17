#!/usr/bin/env python3
"""MCP wait e2e suite (docs/specs/mcp.md MCP-96, MCP-97, MCP-111; plan T11).

`wait` is a clock (`ms`), a condition (`text`) or the settle (`settle: true`).
The fake phone's settle is slowed to 1200 ms through its mode file
(`slow-settle`). Run it through driver.py (`--suite wait`).
"""

import json
import time

from common import MCP, report
from suite_act import live, mode, open_window


def call(client, arguments):
    started = time.monotonic()
    reply = client.tool("wait", arguments, timeout=40)
    return reply, time.monotonic() - started


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-wait", "version": "1"}})
        client.notify("notifications/initialized")
        mode(args)
        window = open_window(client)
        report(live(client, window), "MCP [MCP-96] setup: the wait window is live")

        # [MCP-96] A plain clock.
        reply, elapsed = call(client, {"window": window, "ms": 1000})
        answer = reply.get("structuredContent") or {}
        report(not reply.get("isError") and 1.0 <= elapsed <= 1.5 and "until" not in answer
               and (answer.get("waitedMs") or 0) >= 1000,
               "[MCP-96] MCP wait ms 1000 returns in %.2f s (%s)" % (elapsed, answer.get("waitedMs")))

        # [MCP-97] Text already on screen: met, with the Continue button's ref.
        tree = (client.tool("ui_tree", {"window": window}).get("structuredContent") or {})
        button = next((n for n in tree.get("nodes") or [] if n.get("text") == "Continue"), {})
        reply, elapsed = call(client, {"window": window, "text": "Continue", "timeoutMs": 3000})
        answer = reply.get("structuredContent") or {}
        match = answer.get("match") or {}
        report(not reply.get("isError") and answer.get("until") == "met"
               and button.get("ref") is not None and match.get("ref") == button.get("ref"),
               "[MCP-97] MCP wait text Continue is met at its ref (%s vs %s)"
               % (match.get("ref"), button.get("ref")))

        # [MCP-97] Text that never shows: timeout, not an error, inside the bound.
        reply, elapsed = call(client, {"window": window, "text": "No such words", "timeoutMs": 1500})
        answer = reply.get("structuredContent") or {}
        report(not reply.get("isError") and answer.get("until") == "timeout" and elapsed < 4.5,
               "[MCP-97] MCP wait text that never shows times out in %.2f s (%s)"
               % (elapsed, answer.get("until")))

        # [MCP-111] The settle, slowed to 1200 ms.
        mode(args, "slow-settle")
        reply, elapsed = call(client, {"window": window, "settle": True})
        mode(args)
        answer = reply.get("structuredContent") or {}
        report(not reply.get("isError") and answer.get("until") == "met"
               and (answer.get("waitedMs") or 0) >= 1200,
               "[MCP-111] MCP wait settle is met after the phone settles (%s)" % json.dumps(
                   {k: answer.get(k) for k in ("until", "waitedMs", "reason")}))
    finally:
        client.close()
