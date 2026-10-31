#!/usr/bin/env python3
"""Emulator-rig helper for the parts deckctl has no subcommand for.

deckctl.py speaks the protocol, records streams and dumps frames; it cannot read
or touch the phone's screen, so this tool covers the rig's local bits:

  check          connect + authenticate + print the welcome (exit 0 paired,
                 2 not paired, 3 the phone is busy with another session).
  pair           pair through deckctl's v2 client: watch the phone's prompt,
                 tap Allow over adb, and store the pin in deckctl's own state
                 file (under the same clientId, so deckctl authenticates with
                 `--state` afterwards).
  wait-prompt    wait for a new prompt and tap Allow (pair with `deckctl --pair`).
  verify-phases  check the PNGs `deckctl multi` wrote: every phase must show real
                 UI (mean luma), and every input-step phase must differ from the
                 previous phase of the same stream.

The v2 handshake is TLS 1.3 with client certificates and pins taken from the
handshake, so this file does not speak the protocol itself: it imports deckctl
(`open_session`, `ClientState`, `DeckError`) and adds only the adb side.
Python 3.9 stdlib + ffmpeg.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, "..", "fakephone"))
import deckctl  # noqa: E402
import proto  # noqa: E402

APP_PKG = "dev.pocketdeck"
MAIN_ACTIVITY = APP_PKG + "/.app.MainActivity"
DEFAULT_ADB = os.path.join(os.path.expanduser("~"), "Library/Android/sdk/platform-tools/adb")


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


def ui_dump(adb, timeout=30):
    """Return the uiautomator XML of the current window ('' when unavailable)."""
    res = adb.sh("uiautomator", "dump", "--compressed", UI_DUMP, timeout=timeout)
    if "dumped" not in (res.stdout + res.stderr):
        return ""
    return adb.sh("cat", UI_DUMP, timeout=timeout).stdout


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


# The phone-side facts a failed pair needs: who is alive, why, and what the
# app/shell logged. Without these a `session failed: tls` on the Mac cannot be
# told from a dropped session, a dead server or a crash.
EVIDENCE_RE = re.compile(
    r"PocketDeckSvc|PocketDeckApp|AndroidRuntime|FATAL| DEBUG |Shizuku|shizuku|"
    r"tombstone|am_crash|am_anr|lowmemorykiller|Force finishing|"
    r"Process dev\.pocketdeck|Killing [0-9]+:dev\.pocketdeck")


def write_evidence(directory, name, text):
    if not directory:
        return None
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, name)
    with open(path, "w") as fh:
        fh.write(text if text.endswith("\n") else text + "\n")
    print("evidence: %s (%d bytes)" % (path, len(text)))
    return path


def phone_evidence(adb, directory, label):
    """Dump logcat/process/activity state before the emulator is killed."""
    if not directory:
        return None
    lines = ["== phone evidence: %s at %s ==" %
             (label, time.strftime("%Y-%m-%d %H:%M:%S"))]
    for name in (APP_PKG, APP_PKG + ":pocketdeck"):
        lines.append("pidof %s: %s" % (name, adb.out("pidof", name)))
    ps = adb.sh("ps", "-A", "-o", "PID,PPID,USER,NAME")
    lines.append("-- ps (pocketdeck/shizuku) --")
    lines.extend(line for line in ps.stdout.splitlines()
                 if "pocketdeck" in line or "shizuku" in line.lower())
    acts = adb.sh("dumpsys", "activity", "activities")
    lines.append("-- activity --")
    lines.extend(line for line in acts.stdout.splitlines()
                 if "ResumedActivity" in line or "mFocusedApp" in line)
    lines.append("-- logcat --")
    logcat = adb.sh("logcat", "-d", "-v", "time", "-b", "all", timeout=60)
    lines.extend(line for line in logcat.stdout.splitlines()
                 if EVIDENCE_RE.search(line))
    return write_evidence(directory, "phone-%s.log" % label, "\n".join(lines))


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


def tap_allow(adb, timeout, evidence_dir=None):
    """Tap the prompt's Allow: app dialog first, then the notification shade.

    Not time-critical: the phone waits 120 s for the decision. With
    *evidence_dir*, the phone's state around the tap is written there, so a
    failure after the tap has the logcat/pid lines of the exact moment.
    """
    deadline = time.time() + timeout
    first = True
    while time.time() < deadline:
        if first:
            first = False
            phone_evidence(adb, evidence_dir, "before-tap")
            write_evidence(evidence_dir, "ui-before-tap.xml", ui_dump(adb, 10))
            # The dumps can be slow on a fresh boot; they must not eat the
            # window that finds the Allow button.
            deadline = time.time() + timeout
        allow = find_node(ui_dump(adb), "Allow")
        if allow:
            adb.tap(*allow)
            print("tap-allow: tapped at %.0f,%.0f (dialog)" % allow)
            if evidence_dir:
                time.sleep(0.5)
                phone_evidence(adb, evidence_dir, "after-tap")
                write_evidence(evidence_dir, "ui-after-tap.xml", ui_dump(adb, 10))
            return True
        adb.sh("cmd", "statusbar", "expand-notifications")
        time.sleep(0.8)
        allow = find_node(ui_dump(adb), "Allow")
        if allow:
            adb.tap(*allow)
            print("tap-allow: tapped at %.0f,%.0f (notification)" % allow)
            if evidence_dir:
                time.sleep(0.5)
                phone_evidence(adb, evidence_dir, "after-tap")
                write_evidence(evidence_dir, "ui-after-tap.xml", ui_dump(adb, 10))
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
def split_addr(addr):
    """'host:port' -> (host, port)."""
    host, _, port = addr.rpartition(":")
    if not host or not port:
        raise PocError("address must be host:port, got %r" % addr)
    try:
        return host, int(port)
    except ValueError:
        raise PocError("bad port in address %r" % addr)


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


# --- commands --------------------------------------------------------------
def cmd_check(args):
    """Connect + authenticate + print the welcome.

    Exit codes so a caller can tell the two failures apart: 0 paired, 2 not
    paired (needs the prompt), 3 the phone is busy with another session.
    """
    host, port = split_addr(args.addr)
    state = deckctl.ClientState(args.state)
    try:
        client = deckctl.open_session(host, port, state, on_code=None)
    except deckctl.DeckError as exc:
        # open_session folds Busy/AuthFailed into DeckError; the message is the
        # only distinction left (the busy one is raised verbatim).
        message = str(exc)
        sys.stderr.write("poc: %s\n" % message)
        return 3 if "busy" in message else 2
    try:
        dev = client.device or {}
        print("welcome: id=%s name=%s model=%s locked=%s" %
              (dev.get("id"), dev.get("name"), dev.get("model"), dev.get("locked")))
    finally:
        client.close()
    return 0


def cmd_pair(args):
    """Real pairing through deckctl's v2 client: watch the phone's prompt, tap
    Allow, store the pin in deckctl's state file under the clientId deckctl will
    use.

    deckctl derives its own advisory code from the wire facts (it cannot reach
    the TLS exporter), so it is not compared with the phone's prompt: the
    prompt's code is what the person compares, and this helper only taps Allow
    after confirming a *new* prompt appeared.
    """
    adb = Adb(args.adb, args.serial)
    state = deckctl.ClientState(args.state)
    if args.name:
        state.name = args.name
    host, port = split_addr(args.addr)
    # A prompt left over from an earlier aborted request must not be mistaken
    # for the one this request raises. "" means "none": read_new_code would
    # otherwise snapshot the *new* prompt as its baseline and ignore it.
    stale = notification_code(adb) or dialog_code(ui_dump(adb)) or ""

    def on_code(_code):
        print("pair: pair.request accepted, watching the phone's prompt")
        shown = read_new_code(adb, args.timeout, stale=stale)
        if shown is None:
            raise deckctl.DeckError("no new pairing code within %.0fs" % args.timeout)
        print("pair: prompt shows code %s" % shown)
        if not tap_allow(adb, args.tap_timeout):
            raise deckctl.DeckError(
                "pairing prompt found (code %s) but Allow was not reachable" % shown)

    client = deckctl.open_session(host, port, state, on_code=on_code)
    try:
        print("pair: ok device=%s pin stored in %s" % (client.device_id, args.state))
    finally:
        client.close()
    return 0


def cmd_wait_prompt(args):
    """Wait for a new pairing prompt and tap Allow.

    The manual path: `deckctl --pair apps` in one terminal (it prints the code the
    phone announces) and this helper in another. flow.sh pairs through `pair`.
    """
    adb = Adb(args.adb, args.serial)
    code = read_new_code(adb, args.timeout, args.interval)
    if code is None:
        raise PocError("no new pairing code within %.0fs" % args.timeout)
    print("wait-prompt: prompt shows code %s" % code)
    return 0 if tap_allow(adb, args.tap_timeout, args.evidence) else 1


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
    sp.add_argument("--name", help="client name to store (must match deckctl --name)")
    sp.add_argument("--timeout", type=float, default=60.0, help="how long to watch for the prompt")
    sp.add_argument("--tap-timeout", type=float, default=25.0,
                    help="how long to keep looking for the Allow button")
    sp.set_defaults(func=cmd_pair)

    sp = sub.add_parser("wait-prompt", help="wait for a new pairing prompt, tap Allow")
    sp.add_argument("--timeout", type=float, default=90.0)
    sp.add_argument("--interval", type=float, default=0.4)
    sp.add_argument("--tap-timeout", type=float, default=25.0)
    sp.add_argument("--evidence", metavar="DIR",
                    help="write the phone's logcat/pid/UI state before and after the tap")
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
    except (PocError, deckctl.DeckError, proto.ProtocolError, OSError) as exc:
        sys.stderr.write("poc: error: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
