#!/usr/bin/env python3
"""MCP type e2e suite (docs/specs/mcp.md MCP-92, MCP-109; plan T13).

`type_text` goes to the phone as one `ui.type`, never as the `text` message:
the fake phone logs one `type` event with the character count (never the
text), and `did` says how it typed. The fake's `type-refuse=<code>` mode word
(its `--mode-file`) makes it refuse; the tool then fails with that closed code
and its sentence. The mode is switched back off at the end so later suites see
the default. Run it through driver.py (`--suite type`).
"""

import json
import time

from common import MCP, events, report
from suite_act import live, mode, open_window


def error_of(reply):
    """The failure object of an isError tool result, or {}."""
    if not reply.get("isError"):
        return {}
    try:
        return json.loads(reply["content"][0]["text"]).get("error") or {}
    except (KeyError, IndexError, ValueError):
        return {}


def since(path, ts, stream):
    """The fake's events for `stream` from `ts` on; an `rx` row's stream is its message's."""
    def stream_of(e):
        msg = e.get("msg")
        return msg.get("stream") if e.get("ev") == "rx" and isinstance(msg, dict) else e.get("stream")
    return [e for e in events(path) if (e.get("ts") or 0) >= ts and stream_of(e) == stream]


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-type", "version": "1"}})
        client.notify("notifications/initialized")
        mode(args)
        window = open_window(client)
        report(live(client, window), "MCP [MCP-109] setup: the type window is live")

        # [MCP-92] [MCP-109] One ui.type, its character count, no text message.
        start = time.time()
        reply = client.tool("type_text", {"window": window, "text": "café", "clear": True,
                                          "submit": True, "observe": "none"}, timeout=30)
        time.sleep(0.5)
        answer = reply.get("structuredContent") or {}
        did = answer.get("did") or {}
        report(not reply.get("isError"),
               "[MCP-109] MCP type_text answers (%s)" % (error_of(reply).get("code") or "ok"))
        report(did.get("action") == "type" and did.get("characters") == 4
               and did.get("clear") is True and did.get("submit") is True
               and did.get("entry") == "replaced" and did.get("via") == "set_text",
               "[MCP-92] MCP type_text's did says how it typed and never the text (%s)"
               % sorted(did.items()))
        rows = since(args.events, start, window)
        typed = [e for e in rows if e.get("ev") == "type"]
        report(len(typed) == 1 and typed[0].get("characters") == 4 and "code" not in typed[0],
               "[MCP-109] MCP type_text reaches the phone as one ui.type of 4 characters (%s)"
               % [(e.get("characters"), e.get("via"), e.get("code")) for e in typed])
        texts = [e for e in rows if e.get("ev") == "rx" and isinstance(e.get("msg"), dict)
                 and e["msg"].get("t") == "text"]
        report(not texts, "[MCP-92] MCP type_text sends no text message (%d)" % len(texts))

        # [MCP-109] The phone's refusal is the tool's closed code and sentence.
        mode(args, "type-refuse=not_supported")
        start = time.time()
        reply = client.tool("type_text", {"window": window, "text": "térmica",
                                          "observe": "none"}, timeout=30)
        error = error_of(reply)
        report(reply.get("isError") is True and error.get("code") == "not_supported",
               "[MCP-109] MCP a field that can't take the text fails not_supported (%s)"
               % error.get("code"))
        report("clear: true" in (error.get("message") or ""),
               "[MCP-109] MCP the not_supported sentence names clear: true")
        time.sleep(0.3)
        refused = [e for e in since(args.events, start, window) if e.get("ev") == "type"]
        report(len(refused) == 1 and refused[0].get("code") == "not_supported",
               "[MCP-109] MCP the refused ui.type reached the phone once and typed nothing")
    finally:
        mode(args)
        client.close()
