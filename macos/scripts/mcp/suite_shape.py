#!/usr/bin/env python3
"""An agent's new window takes the phone's shape (docs/specs/mcp.md MCP-100,
MCP-101, plan T12).

`open_app` with no `shape` asks the phone for a portrait stream at the phone's
own dp width, its long side at most 1280 px; `shape: "window"` asks for a
person's window. A person's resize hands the window back (one `window.resize`
at WIN-5's size) and a later `open_app` raises it unchanged. A new window's
`size` is the display the phone made, so an open whose first frame the fake
holds back (`hold-first-frame`) still answers it, with `state: "opening"`. The
phone's side is read from the fake phone's received messages (`events.jsonl`).
Run it through driver.py (`--suite shape`).
"""

import json
import os
import time

from common import MCP, mode, report

# The fake phone's own screen (tools/fakephone/fakephone.py SCREEN_W/H/DPI).
FAKE_SHORT, FAKE_DPI = 1080, 450
FAKE_DP_WIDTH = FAKE_SHORT * 160.0 / FAKE_DPI


def control(directory, line, seq=[0]):
    """One debug-control command (DebugControl.swift); its one-line answer."""
    seq[0] += 1
    name = os.path.join(directory, "shape%d" % seq[0])
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


def received(events, kind, stream=None, after=0.0):
    """The phone's received messages of type `kind` (for `stream`) after `after`."""
    found = []
    try:
        lines = open(events, errors="replace").readlines()
    except OSError:
        return found
    for raw in lines:
        try:
            event = json.loads(raw)
        except ValueError:
            continue
        msg = event.get("msg") or {}
        if event.get("ev") != "rx" or msg.get("t") != kind or event.get("ts", 0) < after:
            continue
        if stream is not None and msg.get("stream") != stream:
            continue
        found.append(msg)
    return found


def close_all(client):
    for row in client.text("list_windows").get("windows") or []:
        client.tool("close_window", {"window": row.get("id")})
    time.sleep(0.5)


def phone_shaped(msg):
    w, h, dpi = msg.get("w") or 0, msg.get("h") or 0, msg.get("dpi") or 0
    return (h > w > 0 and max(w, h) <= 1280 and dpi > 0
            and abs(w * 160.0 / dpi - FAKE_DP_WIDTH) <= 1)


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-shape", "version": "1"}})
        client.notify("notifications/initialized")
        close_all(client)

        # [MCP-100] shape: "window" with no remembered frame: today's 900x600 pt
        # window (WIN-5). The opens before this suite were all phone-shaped,
        # and a phone-shape window remembers no frame (WIN-13's exception).
        start = time.time()
        plain = client.tool("open_app", {"app": "com.android.settings", "shape": "window"}, timeout=30)
        body0 = plain.get("structuredContent") or {}
        opens = received(args.events, "window.open", body0.get("window"), start)
        msg0 = opens[0] if opens else {}
        w0, h0, dpi0 = msg0.get("w") or 0, msg0.get("h") or 0, msg0.get("dpi") or 0
        report(not plain.get("isError") and body0.get("opened") == "new" and len(opens) == 1
               and w0 > h0 > 0 and dpi0 > 0 and abs(w0 * 160.0 / dpi0 - 900) <= 1
               and abs(h0 * 160.0 / dpi0 - 600) <= 1 and body0.get("size") == [w0, h0],
               "[MCP-100] MCP open_app with shape window opens today's 900x600 pt window (open %r)"
               % ({k: msg0.get(k) for k in ("w", "h", "dpi")},))
        close_all(client)

        # [MCP-100] no shape: the phone's portrait shape at its own dp width.
        start = time.time()
        first = client.tool("open_app", {"app": "com.android.settings"}, timeout=30)
        body = first.get("structuredContent") or {}
        window = body.get("window")
        opens = received(args.events, "window.open", window, start)
        msg = opens[0] if opens else {}
        report(not first.get("isError") and body.get("opened") == "new" and len(opens) == 1
               and phone_shaped(msg) and body.get("size") == [msg.get("w"), msg.get("h")],
               "[MCP-100] MCP open_app with no shape opens portrait at the phone's dp width (open %r, size %r)"
               % ({k: msg.get(k) for k in ("w", "h", "dpi")}, body.get("size")))

        # [MCP-101] a person's resize hands it back: one window.resize at WIN-5's size.
        before = time.time()
        answer = control(args.control, "resize-drag right 120 6 16 %d" % window)
        time.sleep(2.0)
        resizes = received(args.events, "window.resize", window, before)
        last = resizes[-1] if resizes else {}
        w, h = last.get("w") or 0, last.get("h") or 0
        shape_w, shape_h = msg.get("w") or 1, msg.get("h") or 1
        dpi = last.get("dpi") or 0
        report(answer == "ok" and len(resizes) == 1 and dpi > 0
               and w * 160.0 / dpi > FAKE_DP_WIDTH + 1
               and (w / float(h or 1)) > (shape_w / float(shape_h)) + 0.02,
               "[MCP-101] MCP a person's resize hands the phone shape back: one window.resize at WIN-5's size (%s; %r)"
               % (answer, [{k: r.get(k) for k in ("w", "h", "dpi")} for r in resizes]))

        # [MCP-101] a raise keeps what the window has and sends no window.open.
        # The window has the stream the person's resize gave it.
        had = [w, h]
        before = time.time()
        again = client.tool("open_app", {"app": "com.android.settings", "shape": "phone"}, timeout=30)
        body2 = again.get("structuredContent") or {}
        report(not again.get("isError") and body2.get("opened") == "raised"
               and body2.get("window") == window and body2.get("size") == had
               and not received(args.events, "window.open", None, before)
               and not received(args.events, "window.resize", window, before),
               "[MCP-101] MCP open_app on a handed-back window raises it unchanged (size %r, had %r)"
               % (body2.get("size"), had))

        # [MCP-100] shape: "window" opens a person's window: WIN-5 at WIN-13's
        # frame, which is the handed-back window's (MCP-101 makes it the app's
        # remembered frame), never the phone shape.
        close_all(client)
        start = time.time()
        third = client.tool("open_app", {"app": "com.android.settings", "shape": "window"}, timeout=30)
        body3 = third.get("structuredContent") or {}
        opens = received(args.events, "window.open", body3.get("window"), start)
        msg3 = opens[0] if opens else {}
        w3, h3, dpi3 = msg3.get("w") or 0, msg3.get("h") or 0, msg3.get("dpi") or 0
        report(not third.get("isError") and body3.get("opened") == "new" and len(opens) == 1
               and [w3, h3, dpi3] == [w, h, dpi] and not phone_shaped(msg3)
               and body3.get("size") == [w3, h3],
               "[MCP-100] MCP open_app with shape window opens a person's window at the app's remembered frame (open %r, resize was %r)"
               % ({k: msg3.get(k) for k in ("w", "h", "dpi")}, [w, h, dpi]))
        close_all(client)

        # [MCP-100] send_link's new window takes the phone's shape too.
        start = time.time()
        link = client.tool("send_link", {"url": args.link}, timeout=30)
        body4 = link.get("structuredContent") or {}
        opens = received(args.events, "link.open", body4.get("window"), start)
        msg4 = opens[0] if opens else {}
        report(not link.get("isError") and len(opens) == 1 and phone_shaped(msg4),
               "[MCP-100] MCP send_link opens its window at the phone's shape (open %r)"
               % ({k: msg4.get(k) for k in ("w", "h", "dpi")},))
        close_all(client)

        # [MCP-41] [MCP-100] an open whose first frame has not arrived answers
        # the display the phone made (`window.opened`), not [0, 0]: the fake
        # holds frame one past the 10 s open bound.
        mode(args, "hold-first-frame")
        start = time.time()
        held = client.tool("open_app", {"app": "com.android.settings"}, timeout=30)
        body5 = held.get("structuredContent") or {}
        opens = received(args.events, "window.open", body5.get("window"), start)
        msg5 = opens[0] if opens else {}
        settle5 = (body5.get("settle") or {}).get("state")
        report(not held.get("isError") and body5.get("opened") == "new" and len(opens) == 1
               and body5.get("state") == "opening" and settle5 == "not_ready"
               and phone_shaped(msg5) and body5.get("size") == [msg5.get("w"), msg5.get("h")],
               "[MCP-41] [MCP-100] MCP an open with no first frame answers state opening and the display's size (state %r, settle %r, size %r, open %r)"
               % (body5.get("state"), settle5, body5.get("size"),
                  {k: msg5.get(k) for k in ("w", "h", "dpi")}))
        mode(args)
        close_all(client)
    finally:
        mode(args)
        client.close()
