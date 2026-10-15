#!/usr/bin/env python3
"""handoff-probe — drive `task.continue` against the emulator rig (ROADMAP #9).

Reads the phone's answer to the Mac's "Continue on Mac" request and, with
--watch, waits so a person can look at the emulator. Pairing is automatic: the
app is a debug build, so the phone accepts pair.request without a prompt.

    python3 tools/device-checks/handoff-probe.py --host 127.0.0.1 --port 47812 \
        --state tools/emulator/.cache/deckctl-state.json
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fakephone"))
import deckctl  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--w", type=int, default=768)
    p.add_argument("--h", type=int, default=1024)
    p.add_argument("--dpi", type=int, default=160)
    p.add_argument("--stream", type=int, default=1)
    p.add_argument("--watch", type=float, default=0.0, help="keep the window open this long")
    args = p.parse_args()

    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(args.host, args.port, state, lambda code: None)
    try:
        client.send_json({"t": "task.continue", "stream": args.stream,
                          "w": args.w, "h": args.h, "dpi": args.dpi})
        deadline = time.time() + 15
        answer = None
        while time.time() < deadline:
            frame = client.recv(2.0)
            if frame is deckctl.TIMEOUT:
                continue
            if frame is None:
                print("phone closed the connection")
                return 1
            msg = proto_msg(frame)
            if msg is None:
                print("(bin frame, stream %d)" % frame.stream)
                continue
            kind = msg.get("t")
            print("phone:", json.dumps(msg, sort_keys=True))
            if kind in ("window.opened", "error"):
                answer = msg
                break
        if answer is None:
            print("no window.opened/error within 15 s")
            return 1
        if args.watch > 0:
            print("holding the window for %.0f s ..." % args.watch)
            time.sleep(args.watch)
            client.send_json({"t": "window.close", "stream": args.stream})
            time.sleep(0.5)
        return 0 if answer.get("t") == "window.opened" else 2
    finally:
        client.close()


def proto_msg(frame):
    if frame.type != 0x01:
        return None
    return __import__("proto").unpack_json(frame)


if __name__ == "__main__":
    sys.exit(main())
