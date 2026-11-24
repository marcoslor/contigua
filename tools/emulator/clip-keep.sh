#!/usr/bin/env bash
# clip-keep: the person's typing never loses their clip (WIN-80; docs/design/mcp-plan.md T14).
#
#   bash tools/emulator/clip-keep.sh --check   # rehearse: no device, no boot
#   bash tools/emulator/clip-keep.sh           # boot, pair, prove, kill (one boot)
#
# In an app window (its own virtual display, as ime-focus does: display 0 sits
# behind the keyguard), over the wire as the Mac sends it, with the Mac's
# clipboard switch on (clip.enable) so SHARE-1's watcher is live:
#   1. The debug activity's plain EditText, a text clip copied by the app:
#      `text` "ação" lands by set text; the clip still pastes the same after it;
#      no clip.set carried the run. Then, in a fresh field, a KEY frame "a" and
#      a `text` "é" sent back to back read "aé": the key landed before the set.
#   2. Its field with no ACTION_SET_TEXT, the same text clip: `text` "é" lands
#      by paste; a paste key afterwards pastes the person's clip again; no
#      clip.set carried the run.
#   3. The same field, an image the Mac put on the clipboard (clip.image.*,
#      the app's own provider URI): `text` "é" is not pasted (a clip carrying a
#      URI is never written: boot 1 measured that the shell cannot put it
#      back once replaced), the drop is logged as clip_carries_uri, and the
#      image field then receives the same image.
#   4. The phone's "typing:" log lines carry no typed text.
# The rig is awake and past its PIN for the debug activity (a locked phone hides
# its clip from every reader, so the fallback would never paste there).
# Output is codes, counts, lengths and match booleans only; no clip text is printed.
set -uo pipefail

MODE=boot
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "[clip-keep] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
OUT="${CONTIGUA_CLIP_KEEP_OUT:-$CACHE_DIR/clip-keep}"
mkdir -p "$OUT"
CLIENT="$OUT/clip_keep_proof.py"
APK="android/app/build/outputs/apk/debug/app-debug.apk"

cat > "$CLIENT" <<'PY'
import argparse, hashlib, os, struct, subprocess, sys, time, zlib

FAILS = []
ADB = []
PROTO = [None]
CLIPS = []  # the length of every clip.set the phone sent


def line(kind, tag, msg):
    print("%s [%s] %s" % (kind, tag, msg), flush=True)
    if kind == "FAIL":
        FAILS.append(tag)


def check(ok, tag, msg):
    line("PASS" if ok else "FAIL", tag, msg)


def adb(*args):
    """adb on this emulator only (`-s`), never another serial."""
    return subprocess.run(ADB + list(args), capture_output=True, text=True, timeout=30).stdout


def expect(client, deckctl, want, timeout):
    proto = PROTO[0]
    deadline = time.time() + timeout
    while time.time() < deadline:
        frame = client.recv(max(0.05, deadline - time.time()))
        if frame is deckctl.TIMEOUT:
            break
        if frame is None:
            raise RuntimeError("the phone closed the session")
        if frame.type != proto.TYPE_JSON:
            continue
        msg = proto.unpack_json(frame)
        if msg.get("t") == "clip.set":
            CLIPS.append(len(msg.get("text") or ""))
        if msg.get("t") == want:
            return msg
    return {}


def drain(client, deckctl, seconds):
    end = time.time() + seconds
    while time.time() < end:
        expect(client, deckctl, "__none__", max(0.05, end - time.time()))


def key(client, deckctl, keycode, meta=0):
    proto = PROTO[0]
    client.send_raw(proto.pack_key(1, proto.KEY_DOWN, keycode, meta))
    client.send_raw(proto.pack_key(1, proto.KEY_UP, keycode, meta))
    drain(client, deckctl, 0.1)


def text(client, deckctl, s, settle=1.5):
    client.send_json({"t": "text", "stream": 1, "text": s})
    drain(client, deckctl, settle)


DISPLAY = [0]


def debug(client, deckctl, field, *extras):
    """The debug activity on the window's display, ready on [field]; its log cleared first."""
    for _ in (0, 1):
        adb("logcat", "-c")
        # CLEAR_TOP: an earlier instance would take the intent as onNewIntent and keep its field.
        adb("shell", "am", "start", "-W", "--display", str(DISPLAY[0]), "--activity-clear-top",
            "-n", "app.contigua/.app.PasteDebugActivity", "--es", "field", field, *extras)
        deadline = time.time() + 8
        while time.time() < deadline:
            if any("ready field=%s" % field in l for l in debug_lines()):
                drain(client, deckctl, 1.0)
                return True
            drain(client, deckctl, 0.3)
        adb("shell", "input", "-d", str(DISPLAY[0]), "keyevent", "4")
        drain(client, deckctl, 1.0)
    line("FAIL", "rig", "the debug activity did not come up on display %d (field %s)" % (DISPLAY[0], field))
    return False


def debug_lines():
    return [l for l in adb("logcat", "-d", "-s", "PasteDebug:I").splitlines() if "PasteDebug" in l]


def last_length(field):
    marker = "%s text length=" % field
    values = [l.split(marker)[-1].split()[0] for l in debug_lines() if marker in l]
    return int(values[-1]) if values else None


def last_match(field):
    marker = "%s text length=" % field
    values = [l.split(" match=")[-1].strip() for l in debug_lines() if marker in l and " match=" in l]
    return values[-1] == "true" if values else None


def cps(s):
    return ".".join("%x" % ord(c) for c in s)


def typing_lines():
    return [l.split("typing: ")[-1] for l in adb("logcat", "-d").splitlines() if "typing: " in l]


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    rows = b"".join(b"\x00" + bytes((x * 7 + y * 13) % 256 for x in range(32 * 3)) for y in range(32))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


CLIP = "pdclip7731"  # the person's text clip: 10 characters
KEYCODE_A, KEYCODE_DEL, KEYCODE_PASTE = 29, 67, 279


def main():
    ap = argparse.ArgumentParser()
    for name in ("--host", "--state", "--wt", "--adb", "--serial"):
        ap.add_argument(name, required=True)
    ap.add_argument("--port", type=int, required=True)
    args = ap.parse_args()
    ADB.extend([args.adb, "-s", args.serial])
    sys.path.insert(0, os.path.join(args.wt, "tools", "fakephone"))
    import deckctl
    import proto
    PROTO[0] = proto

    state = deckctl.ClientState(args.state)
    client = deckctl.open_session(args.host, args.port, state, None, busy_retries=40)
    client.send_json({"t": "window.open", "stream": 1, "w": 720, "h": 1280, "dpi": 320,
                      "pkg": "com.android.settings"})
    opened = expect(client, deckctl, "window.opened", 40)
    DISPLAY[0] = int(opened.get("displayId") or 0)
    check(DISPLAY[0] > 0, "rig", "an app window opened on its own display (%d)" % DISPLAY[0])
    client.send_json({"t": "clip.enable", "on": True})
    drain(client, deckctl, 1.0)

    # 1. An EditText takes "ação" by set text; the person's text clip stays.
    debug(client, deckctl, "plain", "--es", "action", "copy", "--es", "text", CLIP, "--es", "expect", cps("ação"))
    CLIPS.clear()
    adb("logcat", "-c")
    text(client, deckctl, "ação")
    typed = last_length("plain")
    matched = last_match("plain")
    dropped = typing_lines()
    check(typed == 4 and matched and not dropped, "WIN-80 set text",
          "\"ação\" landed in the EditText (length 4=%s, in order=%s), no run dropped (%d lines)"
          % (typed == 4, matched, len(dropped)))
    run_clips = [n for n in CLIPS if n in (1, 2, 4)]
    key(client, deckctl, KEYCODE_PASTE)
    drain(client, deckctl, 1.0)
    after = last_length("plain")
    check(after == 4 + len(CLIP) and not run_clips, "WIN-80 set text",
          "the person's clip pastes the same after it (length %s, match=%s); clip.set carrying the run: %d"
          % (after, after == 4 + len(CLIP), len(run_clips)))

    # 1b. A KEY frame then a `text` run, back to back: the key lands first.
    if debug(client, deckctl, "plain", "--es", "expect", cps("aé")):
        adb("logcat", "-c")
        client.send_raw(proto.pack_key(1, proto.KEY_DOWN, KEYCODE_A, 0))
        client.send_raw(proto.pack_key(1, proto.KEY_UP, KEYCODE_A, 0))
        client.send_json({"t": "text", "stream": 1, "text": "é"})
        drain(client, deckctl, 1.5)
        typed = last_length("plain")
        matched = last_match("plain")
        check(typed == 2 and matched, "WIN-80 order",
              "a KEY \"a\" then `text` \"é\" read \"aé\" (length 2=%s, in order=%s)" % (typed == 2, matched))

    # 2. A field with no set text: "é" by paste; the text clip is put back.
    debug(client, deckctl, "noset", "--es", "action", "copy", "--es", "text", CLIP)
    CLIPS.clear()
    adb("logcat", "-c")
    text(client, deckctl, "é")
    typed = last_length("noset")
    dropped = typing_lines()
    check(typed == 1 and not dropped, "WIN-80 fallback",
          "\"é\" landed by paste in the field with no set text (length 1=%s), dropped lines: %d"
          % (typed == 1, len(dropped)))
    for l in dropped:
        line("INFO", "log", l)
    run_clips = [n for n in CLIPS if n == 1]
    line("INFO", "WIN-80 fallback", "clip.set sent during the run: lengths %s" % CLIPS)
    key(client, deckctl, KEYCODE_PASTE)
    drain(client, deckctl, 1.0)
    after = last_length("noset")
    check(after == 1 + len(CLIP), "WIN-80 fallback",
          "the person's text clip is back: a paste adds it again (length %s, match=%s)" % (after, after == 1 + len(CLIP)))
    check(not run_clips, "WIN-80 SHARE-1", "the temporary clip was not sent to the Mac (clip.set of the run: %d)"
          % len(run_clips))

    # 3. The same field, an image the Mac put on the clipboard.
    debug(client, deckctl, "noset")
    data = png()
    client.send_json({"t": "clip.image.start", "id": 7, "mime": "image/png", "size": len(data), "paste": True})
    client.send_raw(proto.pack_frame(proto.TYPE_CLIP_DATA, 7, data))
    client.send_json({"t": "clip.image.end", "id": 7, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    done = expect(client, deckctl, "clip.image.done", 10)
    check(done.get("ok") is True, "WIN-80 image", "the Mac's image is the phone's clip (done ok=%s)" % done.get("ok"))
    drain(client, deckctl, 1.0)
    adb("logcat", "-c")
    text(client, deckctl, "é")
    typed = last_length("noset")
    dropped = typing_lines()
    check(typed is None and any("clip_carries_uri" in l for l in dropped), "WIN-80 image",
          "\"é\" is not pasted over the image clip (field length %s) and the drop says clip_carries_uri (%s)"
          % (typed, dropped))
    debug(client, deckctl, "rich")
    key(client, deckctl, KEYCODE_PASTE)
    drain(client, deckctl, 1.5)
    rich = [l.split("rich image bytes=")[-1].strip() for l in debug_lines() if "rich image bytes=" in l]
    got = int(rich[-1]) if rich and rich[-1].lstrip("-").isdigit() else None
    check(got == len(data), "WIN-80 image", "the image is still the clip: the image field received %s bytes (want %d)"
          % (got, len(data)))

    # 4. The log carries lengths and reasons, never the typed text.
    log = adb("logcat", "-d")
    leaked = [l for l in log.splitlines() if "typing: " in l and ("é" in l or "ç" in l or CLIP in l)]
    check(not leaked, "WIN-80 log", "no typing line carries text (%d leaked)" % len(leaked))

    client.send_json({"t": "window.close", "stream": 1})
    print("RESULT %s (%d failed: %s)" % ("PASS" if not FAILS else "FAIL", len(FAILS), ",".join(FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
PY

if [ "$MODE" = check ]; then
  rc=0
  bash -n "$0" || { echo "CHECK FAIL: bash -n"; rc=1; }
  "$PYTHON" -m py_compile "$CLIENT" || { echo "CHECK FAIL: py_compile"; rc=1; }
  [ -x "$ADB" ] || { echo "CHECK FAIL: no adb at $ADB"; rc=1; }
  [ "$SERIAL" = "${SERIAL#emulator-}" ] && { echo "CHECK FAIL: serial $SERIAL is not an emulator"; rc=1; }
  [ -f "$APK" ] || { echo "CHECK FAIL: no $APK (build it with K1)"; rc=1; }
  [ "$rc" = 0 ] && echo "CHECK OK"
  exit $rc
fi

if device_present; then echo "[clip-keep] abort: $SERIAL already up (not this run's)"; exit 2; fi
cleanup() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
trap cleanup EXIT
T0=$(date +%s)
bash "$REPO_ROOT/tools/emulator/start.sh" --no-build > "$OUT/start.log" 2>&1 \
  || { tail -30 "$OUT/start.log"; echo "[clip-keep] start.sh failed"; exit 1; }
echo "[clip-keep] booted in $(( $(date +%s) - T0 ))s"
STATE="$CACHE_DIR/deckctl-state-$(date +%s).json"
paired=0
for attempt in 1 2 3 4; do
  bash "$REPO_ROOT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
  if "$PYTHON" "$REPO_ROOT/tools/emulator/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" \
       --serial "$SERIAL" --adb "$ADB" pair > "$OUT/pair-$attempt.log" 2>&1; then paired=1; break; fi
  sleep 4
done
[ "$paired" = 1 ] || { echo "[clip-keep] pairing failed"; tail -5 "$OUT"/pair-*.log; exit 1; }
echo "[clip-keep] paired"
bash "$REPO_ROOT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
"$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" --wt "$REPO_ROOT" \
  --adb "$ADB" --serial "$SERIAL"
rc=$?
echo "[clip-keep] total $(( $(date +%s) - T0 ))s"
exit $rc
