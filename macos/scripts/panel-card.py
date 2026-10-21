#!/usr/bin/env python3
"""Check that a panel dump (PanelProbe.dump, `paneldump HOST PATH`) is the phone
card, and optionally a state of it.

    panel-card.py PATH [sessions|ringing]

sessions: the two-session Now Playing picker is a row.
ringing:  the Ring row reads Stop Ringing.
Exit 0 when it is, else 1 with what is wrong on stdout.
"""
import json
import sys

path = sys.argv[1]
extra = sys.argv[2] if len(sys.argv) > 2 else ""
root = json.load(open(path))
items = root["items"]
kinds = [row["kind"] for row in items]

problems = []
if root["width"] != 300:
    problems.append("width %s" % root["width"])
if not root["mapped"]:
    problems.append("items %d, controls %d" % (len(items), len(root["controls"])))
for kind in ("volume", "dnd", "ring", "phoneScreen", "findApps", "continueOnMac",
             "installApk", "settings", "quit"):
    if kind not in kinds:
        problems.append("missing %s" % kind)
if extra == "sessions" and "sessions" not in kinds:
    problems.append("no sessions row")
if extra == "ringing":
    label = next((row["label"] for row in items if row["kind"] == "ring"), "")
    if label != "Stop Ringing":
        problems.append("ring label %r" % label)
if extra not in ("", "sessions", "ringing"):
    problems.append("unknown check %r" % extra)

if problems:
    print("; ".join(problems))
    sys.exit(1)
print("ok")
