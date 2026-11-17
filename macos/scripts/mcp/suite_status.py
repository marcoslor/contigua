#!/usr/bin/env python3
"""MCP phone_status e2e suite (docs/specs/mcp.md MCP-31, MCP-32, plan T8).

The fake phone answers `task.front` with its `--foreground-pkg`
(com.android.settings by default); `ignore-task-front` in its mode file
models a phone that never answers. Run it through driver.py (`--suite status`).
"""

import os
import time

from common import MCP, report

FRONT = "com.android.settings"


def mode(args, *words):
    """Set the fake phone's modes for the requests that follow."""
    path = os.path.join(os.path.dirname(os.path.abspath(args.events)), "fake-mode")
    with open(path + ".tmp", "w") as handle:
        handle.write(" ".join(words) + "\n")
    os.rename(path + ".tmp", path)


def suite(args):
    client = MCP(args.shim, args.profile)
    try:
        client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "suite-status", "version": "1"}})
        client.notify("notifications/initialized")
        mode(args)
        status = {}
        deadline = time.time() + 30
        while time.time() < deadline:
            status = client.text("phone_status")
            if status.get("connected"):
                break
            time.sleep(0.5)
        report(bool(status.get("connected")), "MCP [MCP-32] setup: phone_status reports a connected phone")

        # [MCP-31] What locked means.
        report(isinstance(status.get("locked"), bool) and status.get("screen") in ("on", "off")
               and isinstance(status.get("lockChangedAgoMs"), int)
               and status.get("input", "").startswith("App windows take input"),
               "[MCP-31] MCP phone_status carries locked, screen, lockChangedAgoMs and input (%s)"
               % {k: status.get(k) for k in ("locked", "screen", "lockSource", "lockChangedAgoMs")})

        # [MCP-32] The app in front.
        foreground = status.get("foreground") or {}
        report(foreground.get("package") == FRONT and "foregroundError" not in status,
               "[MCP-32] MCP phone_status names the fake phone's task.front package (%s)" % foreground)

        # [MCP-32] A phone that never answers: timeout at 1 s.
        time.sleep(2.1)
        mode(args, "ignore-task-front")
        started = time.monotonic()
        silent = client.text("phone_status")
        elapsed = time.monotonic() - started
        report(silent.get("foreground", "missing") is None and silent.get("foregroundError") == "timeout"
               and 0.9 <= elapsed <= 2.0,
               "[MCP-32] MCP phone_status answers foregroundError timeout at 1 s (%s, %.2f s)"
               % (silent.get("foregroundError"), elapsed))
        mode(args)
    finally:
        client.close()
