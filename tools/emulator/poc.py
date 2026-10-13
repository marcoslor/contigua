#!/usr/bin/env python3
"""Emulator-rig helper for the parts deckctl has no subcommand for.

deckctl.py speaks the protocol, records streams and dumps frames; it cannot read
or touch the phone's screen, so this tool covers the rig's local bits:

  check          connect + authenticate + print the welcome (exit 0 paired,
                 2 not paired, 3 the phone is busy with another session).
  pair           real code pairing: reads the 6-digit code from the pairing
                 prompt, taps Allow over adb, stores the key in deckctl's own
                 state file (under the same clientId, so deckctl authenticates
                 with `--state` afterwards).
  wait-prompt    the same code reading/tapping for `deckctl --code-file F`.
  seed           deterministic pairing for a machine that cannot drive the real
                 flow: writes the same `paired` entry a pairing stores into the
                 app prefs with `run-as`, restarts the app, stores the key.
  verify-phases  check the PNGs `deckctl multi` wrote: every phase must show real
                 UI (mean luma), and every input-step phase must differ from the
                 previous phase of the same stream.

Only reads tools/fakephone/proto.py (never edits it). Python 3.9 stdlib + ffmpeg.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "..", "fakephone"))
import proto  # noqa: E402

APP_PKG = "dev.pocketdeck"
MAIN_ACTIVITY = APP_PKG + "/.app.MainActivity"
DEFAULT_ADB = os.path.join(os.path.expanduser("~"), "Library/Android/sdk/platform-tools/adb")
TIMEOUT = object()


class PocError(Exception):
    pass


# --- adb plumbing ----------------------------------------------------------
class Adb:
    def __init__(self, adb, serial):
        self.adb = adb
        self.serial = serial

    def sh(self, *args, **kw):
        cmd = [self.adb, "-s", self.serial, "shell"] + list(args)
        try:
            return subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=kw.get("timeout", 30))
        except subprocess.TimeoutExpired:
            # `uiautomator dump` hangs while the screen is off; callers poll.
            return subprocess.CompletedProcess(cmd, 124, "", "timeout")

    def out(self, *args):
        return self.sh(*args).stdout.strip()

    def tap(self, x, y):
        self.sh("input", "tap", str(int(x)), str(int(y)))


# --- pairing prompt --------------------------------------------------------
CODE_RE = re.compile(r"\b(\d{3})\s(\d{3})\b")
UI_DUMP = "/sdcard/pocketdeck-ui.xml"


def ui_dump(adb):
    """Return the uiautomator XML of the current window ('' when unavailable)."""
    res = adb.sh("uiautomator", "dump", "--compressed", UI_DUMP)
    if "dumped" not in (res.stdout + res.stderr):
        return ""
    return adb.sh("cat", UI_DUMP).stdout


def find_node(xml, text):
    """Return (x, y) centre of the first node whose text starts with *text*."""
    if not xml:
        return None
    pattern = r'<node[^>]*text="([^"]*)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"'
    for m in re.finditer(pattern, xml):
        if m.group(1).strip().startswith(text):
            x1, y1, x2, y2 = (int(m.group(i)) for i in range(2, 6))
            return (x1 + x2) / 2.0, (y1 + y2) / 2.0
    return None


def dialog_code(xml):
    m = CODE_RE.search(xml or "")
    return m.group(1) + m.group(2) if m else None


def notification_code(adb):
    """The pairing notification's code (the shell user has DUMP, which is what
    `dumpsys notification --noredact` needs)."""
    dump = adb.out("dumpsys", "notification", "--noredact")
    m = CODE_RE.search(dump)
    return m.group(1) + m.group(2) if m else None


def read_new_code(adb, timeout, interval=0.4, stale=None):
    """Wait for a *new* pairing code: notification first (fast), dialog second.

    A prompt left over from an earlier aborted request can still be on screen, so
    a code equal to *stale* is ignored.
    """
    if stale is None:
        stale = notification_code(adb) or dialog_code(ui_dump(adb))
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = notification_code(adb)
        if found and found != stale:
            return found
        dialog = dialog_code(ui_dump(adb))
        if dialog and dialog != stale:
            return dialog
        time.sleep(interval)
    return None


def tap_allow(adb, timeout):
    """Tap the prompt's Allow: app dialog first, then the notification shade.

    Not time-critical: the phone waits ~30 s for the decision after pair.confirm.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        allow = find_node(ui_dump(adb), "Allow")
        if allow:
            adb.tap(*allow)
            print("tap-allow: tapped at %.0f,%.0f (dialog)" % allow)
            return True
        adb.sh("cmd", "statusbar", "expand-notifications")
        time.sleep(0.8)
        allow = find_node(ui_dump(adb), "Allow")
        if allow:
            adb.tap(*allow)
            print("tap-allow: tapped at %.0f,%.0f (notification)" % allow)
            return True
        adb.sh("cmd", "statusbar", "collapse-notifications")
        time.sleep(0.4)
    print("tap-allow: no Allow button reachable within %.0fs" % timeout)
    return False


def xml_unescape(value):
    return (value.replace("&quot;", '"').replace("&lt;", "<")
                 .replace("&gt;", ">").replace("&amp;", "&"))


def xml_escape(value):
    return (value.replace("&", "&amp;").replace("<", "&lt;")
                 .replace(">", "&gt;").replace('"', "&quot;"))


# --- protocol client -------------------------------------------------------
class Session:
    def __init__(self, sock):
        self.sock = sock
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.nonce = None
        self.challenge_id = None
        self.welcome = {}
        self.device = {}

    def send_json(self, obj):
        self.sock.sendall(proto.pack_json(obj, obj.get("stream", 0) or 0))

    def send_raw(self, data):
        self.sock.sendall(data)

    def recv(self, timeout):
        self.sock.settimeout(timeout)
        try:
            return proto.recv_frame(self.sock)
        except socket.timeout:
            return TIMEOUT

    def expect_json(self, want, timeout=10.0):
        deadline = time.time() + timeout
        while True:
            frame = self.recv(max(0.05, deadline - time.time()))
            if frame is TIMEOUT:
                raise PocError("timed out waiting for %r" % want)
            if frame is None:
                raise PocError("phone closed the connection while waiting for %r" % want)
            if frame.type != proto.TYPE_JSON:
                continue
            msg = proto.unpack_json(frame)
            if msg.get("t") == "error":
                raise PocError("phone error %s: %s" % (msg.get("code"), msg.get("message", "")))
            if want is None or msg.get("t") == want:
                return msg

    def hello(self, client_id="rig", name="rig"):
        self.send_json({"t": "hello", "v": 1, "clientId": client_id, "name": name})
        msg = self.expect_json("challenge")
        self.nonce = msg.get("nonce")
        self.challenge_id = msg.get("id")
        return msg

    def auth(self, key_hex, nonce):
        self.send_json({"t": "auth", "mac": proto.hmac_hex(bytes.fromhex(key_hex), nonce)})
        self.welcome = self.expect_json("welcome")
        self.device = self.welcome.get("device", {})
        return self.welcome


def connect(addr, timeout=10.0):
    host, _, port = addr.rpartition(":")
    return Session(socket.create_connection((host, int(port)), timeout=timeout))


# --- frames ----------------------------------------------------------------
def ffmpeg_bin():
    for name in ("ffmpeg", "/opt/homebrew/bin/ffmpeg"):
        path = shutil.which(name) if os.sep not in name else name
        if path and os.path.exists(path):
            return path
    raise PocError("ffmpeg not found (needed to judge the frames)")


def png_stats(path):
    """Mean luma of a PNG (1x1 downscale, area filter). A frame that is black, or
    the keyguard, sits near zero; real app UI does not."""
    res = subprocess.run(
        [ffmpeg_bin(), "-loglevel", "error", "-i", path, "-vf",
         "scale=1:1:flags=area", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        capture_output=True, timeout=60)
    return float(res.stdout[0]) if res.stdout else -1.0


# --- state -----------------------------------------------------------------
def load_state(path):
    try:
        with open(path) as fp:
            return json.load(fp)
    except (IOError, OSError, ValueError):
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as fp:
        json.dump(state, fp, indent=2)
    os.replace(tmp, path)


def remember_key(state, device_id, key, path):
    keys = state.setdefault("keys", {})
    keys[device_id] = key
    state["order"] = [device_id] + [i for i in state.get("order", []) if i != device_id]
    save_state(path, state)


# --- commands --------------------------------------------------------------
def cmd_check(args):
    """Connect + authenticate + print the welcome.

    Exit codes so a caller can tell the two failures apart: 0 paired, 2 not
    paired (needs the prompt), 3 the phone is busy with another session.
    """
    try:
        sess = connect(args.addr)
        state = load_state(args.state)
        sess.hello(state.get("clientId", "rig"), state.get("name", "rig"))
        keys = state.get("keys", {})
        key_id = sess.challenge_id
        if key_id not in keys:
            raise PocError("no stored key for device %s" % key_id)
        sess.auth(keys[key_id], sess.nonce)
        dev = sess.welcome.get("device", {})
        print("welcome: id=%s name=%s model=%s locked=%s" %
              (dev.get("id"), dev.get("name"), dev.get("model"), dev.get("locked")))
        sess.sock.close()
        return 0
    except PocError as exc:
        message = str(exc)
        sys.stderr.write("poc: %s\n" % message)
        busy = "busy" in message or "reset" in message.lower()
        return 3 if busy else 2


def cmd_pair(args):
    """Real code pairing: hello -> pair.request -> code -> pair.confirm -> Allow.

    The confirm goes out as soon as the code is known (the phone only waits ~15 s
    for it); the Allow tap follows (the phone waits ~30 s for that decision). The
    key lands in deckctl's state file under the clientId deckctl will use.
    """
    adb = Adb(args.adb, args.serial)
    state = load_state(args.state)
    client_id = state.get("clientId") or str(uuid.uuid4())
    name = args.name or state.get("name") or socket.gethostname()
    state["clientId"] = client_id
    state["name"] = name

    sess = connect(args.addr)
    sess.hello(client_id, name)
    stale = notification_code(adb) or dialog_code(ui_dump(adb))
    sess.send_json({"t": "pair.request"})
    sess.expect_json("pair.code_shown", timeout=20.0)
    print("pair: code requested, watching for the prompt")

    if args.code:
        code = args.code
    elif args.code_file:
        code = None
        deadline = time.time() + 30
        while time.time() < deadline and not code:
            try:
                with open(args.code_file) as fp:
                    code = fp.read().strip() or None
            except (IOError, OSError):
                code = None
            if not code:
                time.sleep(0.2)
        if not code:
            raise PocError("no code in %s" % args.code_file)
    else:
        code = read_new_code(adb, args.timeout, stale=stale)
        if code is None:
            raise PocError("no new pairing code within %.0fs" % args.timeout)
        print("pair: code %s read from the prompt" % code)
        sess.send_json({"t": "pair.confirm", "code": str(code)})
        if not tap_allow(adb, args.tap_timeout):
            raise PocError("pairing prompt found (code %s) but Allow was not reachable" % code)

    if args.code or args.code_file:
        sess.send_json({"t": "pair.confirm", "code": str(code)})
    msg = sess.expect_json("pair.ok", timeout=40.0)
    key = msg["key"]
    device_id = sess.expect_json("welcome").get("device", {}).get("id", "")
    remember_key(state, device_id, key, args.state)
    print("pair: ok device=%s key stored in %s" % (device_id, args.state))
    sess.sock.close()
    return 0


def cmd_seed(args):
    """Deterministic pairing, for when the real code flow cannot be driven.

    The rig writes the same `paired` entry a real pairing stores into the app's
    prefs (debug build -> `run-as`), restarts the app so it pushes the client to
    the shell service, and puts the matching key into deckctl's state file.
    `pair` remains the real flow; flow.sh tries it first.
    """
    adb = Adb(args.adb, args.serial)
    state = load_state(args.state)
    client_id = state.get("clientId") or str(uuid.uuid4())
    name = args.name or state.get("name") or socket.gethostname()
    key = os.urandom(32).hex()
    device_id = args.device_id

    adb.sh("am", "force-stop", APP_PKG)
    prefs = adb.out("run-as", APP_PKG, "cat", "shared_prefs/pocketdeck.xml")
    if "<map>" not in prefs:
        raise PocError("cannot read %s prefs (run start.sh first)" % APP_PKG)
    m = re.search(r'<string name="paired">(.*?)</string>', prefs, re.S)
    paired = []
    if m:
        try:
            paired = json.loads(xml_unescape(m.group(1)))
        except ValueError as exc:
            raise PocError("existing `paired` prefs entry is not JSON: %s" % exc)
    paired = [e for e in paired if e.get("clientId") != client_id]
    paired.append({"clientId": client_id, "name": name, "key": key,
                   "lastConnected": int(time.time() * 1000)})
    entry = '<string name="paired">%s</string>' % xml_escape(json.dumps(paired))
    if m:
        prefs = prefs[:m.start()] + entry + prefs[m.end():]
    else:
        prefs = prefs.replace("</map>", "    %s\n</map>" % entry)

    written = subprocess.run(
        [adb.adb, "-s", adb.serial, "shell",
         "run-as %s sh -c 'cat > shared_prefs/pocketdeck.xml'" % APP_PKG],
        input=prefs, capture_output=True, text=True, timeout=60)
    if written.returncode != 0:
        raise PocError("cannot write %s prefs: %s" % (APP_PKG, (written.stderr or "").strip()))

    state["clientId"] = client_id
    state["name"] = name
    remember_key(state, device_id, key, args.state)
    adb.sh("am", "start", "-n", MAIN_ACTIVITY)
    print("seed: client %s stored (device %s), app restarted, key in %s" %
          (client_id, device_id, args.state))
    return 0


def cmd_wait_prompt(args):
    """Read a new code, write it for `deckctl --code-file`, then tap Allow.

    The manual path: `deckctl --code-file F apps` in one terminal and this helper
    in another. flow.sh pairs through `pair` instead.
    """
    adb = Adb(args.adb, args.serial)
    code = read_new_code(adb, args.timeout, args.interval)
    if code is None:
        raise PocError("no new pairing code within %.0fs" % args.timeout)
    tmp = args.code_file + ".tmp"
    with open(tmp, "w") as fp:
        fp.write(code + "\n")
    os.replace(tmp, args.code_file)
    print("wait-prompt: code %s -> %s" % (code, args.code_file))
    return 0 if tap_allow(adb, args.tap_timeout) else 1


def phase_pngs(directory, prefix):
    """{stream: [(phase, path), ...]} for <prefix>-s<N>-<phase>.png, in order."""
    pattern = re.compile(r"^%s-s(\d+)-(.+)\.png$" % re.escape(prefix))
    out = {}
    for name in sorted(os.listdir(directory)):
        m = pattern.match(name)
        if m:
            out.setdefault(int(m.group(1)), []).append((m.group(2), os.path.join(directory, name)))
    return out


def cmd_verify(args):
    """Judge the PNGs deckctl wrote: real UI everywhere, and every input step
    must have changed the frames of the stream it was sent to."""
    streams = phase_pngs(args.dir, args.prefix)
    if not streams:
        raise PocError("no %s-s*-*.png in %s" % (args.prefix, args.dir))
    failed = []
    for stream in sorted(streams):
        previous = None
        for phase, path in streams[stream]:
            luma = png_stats(path)
            # A `wait:` step is not an input, so it need not change the frames.
            is_wait = "-wait-" in phase or phase.endswith("-wait")
            injected = (not is_wait) and ((phase.startswith("s1-") and stream == 1) or
                                          (phase.startswith("s2-") and stream == 2))
            changed = "-"
            changed_ok = True
            if injected:
                if previous is None:
                    changed = "no-baseline"
                    changed_ok = False
                else:
                    changed_ok = (hashlib.sha256(open(path, "rb").read()).digest() !=
                                  hashlib.sha256(open(previous, "rb").read()).digest())
                    changed = "yes" if changed_ok else "no"
            print("verify: stream%d %-14s mean luma %5.1f  changed=%s  %s" %
                  (stream, phase, luma, changed, os.path.basename(path)))
            if luma < args.min_luma:
                failed.append("stream%d %s: looks blank/black (mean luma %.1f)" % (stream, phase, luma))
            if injected and not changed_ok:
                failed.append("stream%d %s: frames did not change after the input" % (stream, phase))
            previous = path
    if failed:
        raise PocError("; ".join(failed))
    print("verify: OK (%d phases, all showing real UI, every input step changed frames)" %
          sum(len(v) for v in streams.values()))
    return 0


# --- CLI -------------------------------------------------------------------
def main(argv=None):
    p = argparse.ArgumentParser(
        description="Emulator-rig helper for PocketDeck (pairing + frame checks).")
    p.add_argument("--addr", default=os.environ.get("POCKETDECK_ADDR", "127.0.0.1:47811"),
                   help="phone address, host:port (default %(default)s)")
    p.add_argument("--serial", default=os.environ.get("POCKETDECK_SERIAL", "emulator-5554"))
    p.add_argument("--adb", default=os.environ.get("ADB", DEFAULT_ADB))
    p.add_argument("--state", default=os.path.join(ROOT, ".cache", "deckctl-state.json"),
                   help="deckctl state file to pair into (default: the rig cache)")

    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("check", help="connect and authenticate, print the welcome")
    sp.set_defaults(func=cmd_check)

    sp = sub.add_parser("pair", help="real code pairing (reads the prompt, taps Allow)")
    sp.add_argument("--code", help="use this code instead of reading the prompt")
    sp.add_argument("--code-file", help="read the code from this file (deckctl-style)")
    sp.add_argument("--name", help="client name to store (must match deckctl --name)")
    sp.add_argument("--timeout", type=float, default=60.0, help="how long to watch for the prompt")
    sp.add_argument("--tap-timeout", type=float, default=25.0,
                    help="how long to keep looking for the Allow button")
    sp.set_defaults(func=cmd_pair)

    sp = sub.add_parser("seed", help="deterministic pairing: write the client into the app prefs")
    sp.add_argument("--device-id", default=os.environ.get("POCKETDECK_DEVICE_ID", "e0e0e0e0e0e0e0e0"),
                    help="the rig's stable device id (default %(default)s)")
    sp.add_argument("--name", help="client name to store")
    sp.set_defaults(func=cmd_seed)

    sp = sub.add_parser("wait-prompt", help="read a new pairing code, write it, tap Allow")
    sp.add_argument("--code-file", required=True, help="write the code here (deckctl --code-file)")
    sp.add_argument("--timeout", type=float, default=90.0)
    sp.add_argument("--interval", type=float, default=0.4)
    sp.add_argument("--tap-timeout", type=float, default=25.0)
    sp.set_defaults(func=cmd_wait_prompt)

    sp = sub.add_parser("verify-phases", help="check the PNGs deckctl multi wrote")
    sp.add_argument("--dir", required=True, help="directory holding <prefix>-s<N>-<phase>.png")
    sp.add_argument("--prefix", required=True, help="deckctl --out-prefix basename used there")
    sp.add_argument("--min-luma", type=float, default=8.0,
                    help="fail a frame darker than this (black/keyguard guard)")
    sp.set_defaults(func=cmd_verify)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except (PocError, proto.ProtocolError, OSError) as exc:
        sys.stderr.write("poc: error: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
