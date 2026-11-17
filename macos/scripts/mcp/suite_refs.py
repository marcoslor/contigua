#!/usr/bin/env python3
"""MCP refs e2e suite (docs/specs/mcp.md MCP-71, MCP-86, MCP-89, MCP-108; plan T10).

A ref is the phone's key `e<k>`: it names one element across reads, `tap` by
ref goes to the phone as `ui.press`, and the phone presses the element where it
is now, or refuses and presses nothing. The fake phone's `tree-variant` (a
covered button; from the second read on, k 2 is gone) and `relabel` (the
Continue button reads "Continue later" at the press) are switched through its
mode file. Run it through driver.py (`--suite refs`).
"""

import json
import time

from common import MCP, events, report
from suite_act import mode, open_window


def error_of(reply):
    """The failure object of an isError tool result, or {}."""
    if not reply.get("isError"):
        return {}
    try:
        return json.loads(reply["content"][0]["text"]).get("error") or {}
    except (KeyError, IndexError, ValueError):
        return {}


def downs_since(path, stream, since):
    return [e for e in events(path)
            if e.get("ev") == "input" and e.get("kind") == "touch" and e.get("action") == 0
            and e.get("stream") == stream and (e.get("ts") or 0) >= since]


def row(tree, k):
    return next((n for n in tree.get("nodes") or [] if n.get("ref") == "e%d" % k), None)


def suite(args):
    client = MCP(args.shim, args.profile)
    other = None
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-refs", "version": "1"}})
        client.notify("notifications/initialized")
        mode(args)
        window = open_window(client)
        time.sleep(1.0)
        tap = lambda ref: client.tool("tap", {"window": window, "ref": ref, "observe": "none"}, timeout=30)

        # [MCP-86] A ref from read 1 still presses after read 2.
        first = client.text("ui_tree", {"window": window})
        client.text("ui_tree", {"window": window})
        label = row(first, 1) or {}
        since = time.time()
        reply = tap("e1")
        answer = reply.get("structuredContent") or {}
        time.sleep(0.5)
        downs = downs_since(args.events, window, since)
        at = label.get("at") or [-1, -1]
        report(not reply.get("isError") and len(downs) == 1
               and abs(downs[0].get("nx", -9) - at[0]) < 1e-3 and abs(downs[0].get("ny", -9) - at[1]) < 1e-3,
               "[MCP-86] MCP a ref from read 1 still presses after read 2, once, at its at")
        box = (answer.get("did") or {}).get("box")
        report(isinstance(box, list) and len(box) == 4
               and all(isinstance(v, (int, float)) for v in box) and box == label.get("box"),
               "[MCP-86] MCP the press's did.box is the box the phone pressed")

        # [MCP-86] A ref whose node is gone presses nothing.
        mode(args, "tree-variant")
        client.text("ui_tree", {"window": window})
        second = client.text("ui_tree", {"window": window})
        since = time.time()
        gone = tap("e2")
        time.sleep(0.5)
        report(row(second, 2) is None and error_of(gone).get("code") == "stale_ref"
               and not downs_since(args.events, window, since),
               "[MCP-86] MCP a ref whose node is gone fails stale_ref and presses nothing")

        # [MCP-89] The covered button is not pressed; the answer names its cover.
        since = time.time()
        covered = tap("e6")
        time.sleep(0.5)
        failure = error_of(covered)
        report(failure.get("code") == "covered" and failure.get("coveredBy") == "e7"
               and not downs_since(args.events, window, since),
               "[MCP-89] MCP a covered ref fails covered, names coveredBy, presses nothing")

        # [MCP-86] #188: the label this client was answered no longer matches.
        mode(args, "relabel")
        client.text("ui_tree", {"window": window})
        since = time.time()
        changed = tap("e2")
        time.sleep(0.5)
        failure = error_of(changed)
        report(failure.get("code") == "stale_ref"
               and failure.get("message") == 'e2 now reads "Continue later", not "Continue". Call ui_tree and use the ref it gives.'
               and not downs_since(args.events, window, since),
               "[MCP-86] MCP a relabelled ref fails stale_ref naming the new label, presses nothing")

        # [MCP-108] A client never answered a tree for the ref sends no expect:
        # the press names the label at the press, not a tree's.
        other = MCP(args.shim, args.profile)
        other.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                     "clientInfo": {"name": "suite-refs-2", "version": "1"}})
        other.notify("notifications/initialized")
        pressed = other.tool("tap", {"window": window, "ref": "e2", "observe": "none"}, timeout=30)
        node = ((pressed.get("structuredContent") or {}).get("did") or {}).get("node") or {}
        report(not pressed.get("isError") and node.get("text") == "Continue later"
               and node.get("role") == "Button",
               "[MCP-108] MCP did.node.text is the label at the press, not the tree's")
    finally:
        mode(args)
        if other is not None:
            other.close()
        client.close()
