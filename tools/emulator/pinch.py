#!/usr/bin/env python3
"""Two-finger pinch and one-finger drag over TOUCH frames, against the emulator rig.

    tools/emulator/pinch.py pinch --port 47811

Opens the browser stand-in, loads example.com, then records three phases on that
stream: before any gesture, after a two-finger pinch-out, and after a one-finger
drag on the zoomed page. Each phase writes its last decoded frame as a PNG under
--out-dir. Uses deckctl's client and recorder from tools/fakephone without
changing them.
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tools", "fakephone"))

import deckctl  # noqa: E402
import proto  # noqa: E402

DEFAULT_STATE = os.path.join(HERE, ".cache", "deckctl-state.json")
DEFAULT_OUT = os.path.join(REPO, ".work", "multitouch")
KEYCODE_ENTER = 66


def tap(client, stream, nx, ny):
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, nx, ny))
    time.sleep(0.05)
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, nx, ny))


def key(client, stream, keycode):
    client.send_raw(proto.pack_key(stream, proto.KEY_DOWN, keycode, 0))
    time.sleep(0.03)
    client.send_raw(proto.pack_key(stream, proto.KEY_UP, keycode, 0))


def pinch_out(client, stream, cx, cy, gap_from, gap_to, steps, interval):
    """Pointer 0 left, pointer 1 right of the centre; both spread apart."""
    half_from = gap_from / 2.0
    half_to = gap_to / 2.0
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, cx - half_from, cy))
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 1, cx + half_from, cy))
    for i in range(1, steps + 1):
        half = half_from + (half_to - half_from) * i / steps
        time.sleep(interval)
        client.send_raw(proto.pack_touch(stream, proto.TOUCH_MOVE, 0, cx - half, cy))
        client.send_raw(proto.pack_touch(stream, proto.TOUCH_MOVE, 1, cx + half, cy))
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 1, cx + half_to, cy))
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, cx - half_to, cy))


def drag(client, stream, x, y_from, y_to, steps, interval):
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_DOWN, 0, x, y_from))
    for i in range(1, steps + 1):
        time.sleep(interval)
        y = y_from + (y_to - y_from) * i / steps
        client.send_raw(proto.pack_touch(stream, proto.TOUCH_MOVE, 0, x, y))
    client.send_raw(proto.pack_touch(stream, proto.TOUCH_UP, 0, x, y_to))


def phase(rec, client, args, name, action):
    """Records the frames that the action produces. The protocol sends nothing
    while the screen is static, so a phase's last frame is the newest state."""
    h264 = os.path.join(args.out_dir, "pinch-%s.h264" % name)
    png = os.path.join(args.out_dir, "pinch-%s.png" % name)
    rec.begin_phase(1, h264)
    client.send_json({"t": "window.keyframe", "stream": 1})
    action()
    try:
        rec.wait_for_key(1, args.key_wait)
    except deckctl.DeckError:
        pass
    time.sleep(args.phase_seconds)
    frames = rec.end_phase(1)
    if frames == 0:
        raise deckctl.DeckError("no frames in phase %s" % name)
    deckctl.dump_last_frame(h264, png)
    print("phase %-8s frames=%3d png=%s" % (name, frames, png))


def load_page(client, stream, url, load_seconds):
    tap(client, stream, 0.50, 0.056)
    time.sleep(0.5)
    client.send_json({"t": "text", "stream": stream, "text": url})
    time.sleep(0.5)
    key(client, stream, KEYCODE_ENTER)
    time.sleep(load_seconds)


def cmd_pinch(client, args):
    stream = 1
    rec = deckctl.StreamRecorder(client).start()
    try:
        client.send_json({"t": "window.open", "stream": stream, "w": args.w, "h": args.h,
                          "dpi": args.dpi, "pkg": args.pkg})
        size = rec.wait_for_size(stream, 25.0)
        want = (deckctl.round16(args.w), deckctl.round16(args.h))
        if size != want:
            raise proto.ProtocolError("CONFIG is %dx%d, expected %dx%d" % (size[0], size[1], want[0], want[1]))
        print("stream1 pkg=%s displayId=%s size=%dx%d" %
              (args.pkg, rec.opened.get(stream, {}).get("displayId"), size[0], size[1]))
        time.sleep(args.settle)
        phase(rec, client, args, "loaded", lambda: load_page(client, stream, "example.com", args.load_seconds))
        phase(rec, client, args, "pinched", lambda: pinch_out(
            client, stream, 0.5, 0.5, 0.10, 0.50, args.steps, args.interval))
        phase(rec, client, args, "dragged", lambda: drag(
            client, stream, 0.5, 0.70, 0.30, args.steps, args.interval))
    finally:
        client.send_json({"t": "window.close", "stream": stream})
        time.sleep(0.5)
        rec.stop()
    return 0


def build_parser():
    p = argparse.ArgumentParser(description="Pinch and drag over TOUCH frames on the emulator rig.")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=47811)
    p.add_argument("--state", default=DEFAULT_STATE)
    p.add_argument("--out-dir", default=DEFAULT_OUT)
    sub = p.add_subparsers(dest="command", required=True)
    sp = sub.add_parser("pinch", help="browser: before / pinch-out / drag phases")
    sp.add_argument("--pkg", default="acr.browser.lightning")
    sp.add_argument("--w", type=int, default=1280)
    sp.add_argument("--h", type=int, default=800)
    sp.add_argument("--dpi", type=int, default=420)
    sp.add_argument("--steps", type=int, default=10)
    sp.add_argument("--interval", type=float, default=0.016)
    sp.add_argument("--settle", type=float, default=2.0)
    sp.add_argument("--load-seconds", type=float, default=6.0)
    sp.add_argument("--phase-seconds", type=float, default=3.0)
    sp.add_argument("--key-wait", type=float, default=4.0)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    os.makedirs(args.out_dir, exist_ok=True)
    state = deckctl.ClientState(args.state)
    try:
        client = deckctl.open_session(args.host, args.port, state, code_provider=None)
    except (deckctl.DeckError, proto.ProtocolError) as exc:
        sys.stderr.write("pinch: error: %s\n" % exc)
        return 2
    try:
        return cmd_pinch(client, args)
    except (deckctl.DeckError, proto.ProtocolError) as exc:
        sys.stderr.write("pinch: error: %s\n" % exc)
        return 3
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
