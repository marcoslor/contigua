#!/usr/bin/env python3
"""One PocketDeck window and the two share triggers, ISS-51's emulator driver.

Opens `window.open` for the debug stand-in (`ShareDebugActivity`) on a virtual
display, then on a schedule sends the Mac's image paste (clip.image with
paste:true, then KEYCODE_PASTE) and a drop of a pdf targeted at the stand-in.
The stand-in starts its "share screen" from an application context; the shell
reads where that task landed from the picker's logcat line.

    share-arrival.py --state <deckctl state> --host 127.0.0.1 --port <port> \
        --board <dir> --png <png> --pdf <pdf> --seconds 50 \
        --paste-after 6 --drop-after 22 [--self-test]

The driver only speaks the protocol. It writes `window display=<id> task=<id>`
to `<board>/window` the moment the window opens, and `paste-sent`/`drop-sent`
after each trigger, so the shell dumps the tasks at the right moment. A
`<board>/close` file ends the run early.
"""
import hashlib
import os
import sys
import time

sys.path.insert(0, "tools/fakephone")

import deckctl  # noqa: E402
import proto  # noqa: E402

KEYCODE_PASTE = 279
PACKAGE = "dev.pocketdeck"
ACTIVITY = ".app.ShareDebugActivity"


def due(at, opened_at, offset):
    """When a trigger is due: `offset` seconds after the window opened."""
    return None if opened_at is None else opened_at + offset


def self_test():
    assert due(0.0, None, 6) is None
    assert due(0.0, 10.0, 6) == 16.0
    assert KEYCODE_PASTE == 279 and ACTIVITY.endswith("ShareDebugActivity")
    print("SELF-TEST OK: trigger schedule and key code")
    return 0


def write(path, line):
    try:
        with open(path + ".tmp", "w") as handle:
            handle.write(line + "\n")
        os.replace(path + ".tmp", path)
    except OSError:
        pass


def wait_for_json(client, kind, ident, timeout):
    """Read frames until the phone's `kind` answer for this transfer arrives."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is deckctl.TIMEOUT:
            continue
        if frame is None:
            return None
        if frame.type == proto.TYPE_JSON:
            msg = proto.unpack_json(frame)
            if msg.get("t") == kind and (ident is None or msg.get("id") == ident):
                return msg
    return None


def send_clip_image(client, ident, path):
    with open(path, "rb") as handle:
        data = handle.read()
    client.send_json({"t": "clip.image.start", "id": ident, "mime": "image/png",
                      "size": len(data), "paste": True})
    offset = 0
    while offset < len(data):
        end = min(offset + (256 << 10), len(data))
        client.send_raw(proto.pack_frame(proto.TYPE_CLIP_DATA, ident, data[offset:end]))
        offset = end
    client.send_json({"t": "clip.image.end", "id": ident, "size": len(data),
                      "sha256": hashlib.sha256(data).hexdigest()})
    # The app owns the clipboard only once it has the whole image; the paste
    # key before that would paste the old clip.
    return wait_for_json(client, "clip.image.done", ident, 20.0)


def send_paste_key(client, stream):
    client.send_raw(proto.pack_key(stream, proto.KEY_DOWN, KEYCODE_PASTE, 0))
    client.send_raw(proto.pack_key(stream, proto.KEY_UP, KEYCODE_PASTE, 0))


def send_drop(client, ident, path):
    with open(path, "rb") as handle:
        data = handle.read()
    client.send_json({"t": "drop.start", "id": ident, "name": os.path.basename(path),
                      "mime": "application/pdf", "size": len(data),
                      "sha256": hashlib.sha256(data).hexdigest(),
                      "index": 1, "count": 1, "target": PACKAGE})
    # The default lane may overtake the bulk lane; wait for the start's answer
    # before the data, as deckctl drop does.
    wait_for_json(client, "drop.progress", ident, 15.0)
    offset = 0
    while offset < len(data):
        end = min(offset + (256 << 10), len(data))
        client.send_raw(proto.pack_frame(proto.TYPE_DROP_DATA, ident, data[offset:end]))
        offset = end


def main(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int)
    parser.add_argument("--board", required=False)
    parser.add_argument("--png")
    parser.add_argument("--pdf")
    parser.add_argument("--w", type=int, default=640)
    parser.add_argument("--h", type=int, default=1000)
    parser.add_argument("--dpi", type=int, default=240)
    parser.add_argument("--stream", type=int, default=1)
    parser.add_argument("--seconds", type=float, default=50.0)
    parser.add_argument("--paste-after", type=float, default=6.0)
    parser.add_argument("--drop-after", type=float, default=22.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()
    if not args.state or not args.port or not args.board:
        parser.error("--state, --port and --board are needed for a run")
    if not args.png or not args.pdf:
        parser.error("--png and --pdf are needed for a run")

    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(args.host, args.port, state, on_code=None)
    stream = args.stream
    started = time.time()
    client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                      "dpi": args.dpi, "pkg": PACKAGE, "activity": ACTIVITY})
    opened_at = None
    paste_at = None
    drop_at = None
    paste_sent = False
    drop_sent = False
    closed = False
    deadline = started + args.seconds
    try:
        while time.time() < deadline and not closed:
            if os.path.exists(os.path.join(args.board, "close")):
                closed = True
                break
            frame = client.recv(max(0.05, min(0.2, deadline - time.time())))
            if frame is deckctl.TIMEOUT:
                frame = None
            if frame is None:
                if time.time() >= deadline:
                    break
                continue
            if frame.type == proto.TYPE_JSON:
                msg = proto.unpack_json(frame)
                if msg.get("t") == "window.opened" and opened_at is None:
                    opened_at = time.time()
                    paste_at = due(opened_at, opened_at, args.paste_after)
                    drop_at = due(opened_at, opened_at, args.drop_after)
                    write(os.path.join(args.board, "window"),
                          "display=%s task=%s" % (msg.get("displayId"), msg.get("taskId")))
            now = time.time()
            if paste_at is not None and now >= paste_at and not paste_sent:
                send_clip_image(client, 9101, args.png)
                send_paste_key(client, stream)
                paste_sent = True
                write(os.path.join(args.board, "paste-sent"), "paste")
            if drop_at is not None and now >= drop_at and not drop_sent:
                send_drop(client, 9201, args.pdf)
                drop_sent = True
                write(os.path.join(args.board, "drop-sent"), "drop")
    finally:
        try:
            client.send_json({"t": "window.close", "stream": stream})
        except Exception:  # noqa: BLE001 - closing is best effort
            pass
        client.close()
    print("window display=%s" % ("opened" if opened_at else "none"))
    print("paste_sent=%s drop_sent=%s" % (paste_sent, drop_sent))
    return 0


if __name__ == "__main__":
    sys.exit(main())
