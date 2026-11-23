#!/usr/bin/env bash
# ui-type: `ui.type` on a real shell server (MCP-109/MCP-110; docs/design/mcp-plan.md B5).
#
#   bash tools/emulator/ui-type.sh --check   # rehearse: no device, no boot
#   bash tools/emulator/ui-type.sh           # boot, pair, prove, kill (one boot)
#
# On the phone mirror (display 0), over the wire as the Mac would send it:
#   1. Contacts' new-contact editor (an EditText; nothing is saved): key-map
#      text goes as keys; the field's text is copied by the app's own ctrl+A,
#      ctrl+C (KEY frames with their ctrl meta), so the person's clip is known
#      and the field is unchanged by the copy; the cursor is moved inside it
#      with DPAD_LEFT and "térmica " is set at the cursor: the field reads
#      before + typed + after, and a key typed next lands right after it (the
#      cursor moved past the typed text); clear replaces.
#   2. A WebView <input> on a local page (the rig's WebView browser): the same,
#      the page putting its cursor at 8 on focus.
#   3. A local canvas page that takes keys but offers no ACTION_SET_TEXT:
#      "térmica" is refused not_supported and no key reaches the page.
#   4. The clip copied in 1 is pasted into the cleared field: still the same,
#      and the phone sent no clip.set during the run; then the person's `text`
#      path with "é" (the control) does change it (#173, plan T14).
# A Compose TextField is not covered: neither the image nor the app has one.
# A step that finds nothing prints the tree's row shapes and goes on.
# Output is codes, counts and match booleans only; no screen text is printed.
set -uo pipefail

MODE=boot
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "[ui-type] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"
OUT="${CONTIGUA_UI_TYPE_OUT:-$CACHE_DIR/ui-type}"
mkdir -p "$OUT/pages"
CLIENT="$OUT/ui_type_proof.py"
PAGE_PORT="${CONTIGUA_PAGE_PORT:-47976}"
BROWSER="${CONTIGUA_BROWSER:-acr.browser.lightning}"

cat > "$OUT/pages/input.html" <<'HTML'
<!doctype html><meta name="viewport" content="width=device-width">
<title>input</title>
<input id="f" value="garrafa 500ml" aria-label="item" style="font-size:24px;width:90%;margin-top:40px">
<script>
const f = document.getElementById("f");
f.addEventListener("focus", () => setTimeout(() => f.setSelectionRange(8, 8), 50));
</script>
HTML
cat > "$OUT/pages/canvas.html" <<'HTML'
<!doctype html><meta name="viewport" content="width=device-width">
<title>canvas</title>
<canvas id="c" tabindex="0" style="width:100%;height:60vh;border:1px solid #888"></canvas>
<p id="n">keys 0</p>
<script>
let n = 0;
const c = document.getElementById("c");
c.addEventListener("click", () => c.focus());
c.addEventListener("keydown", () => { n++; document.getElementById("n").textContent = "keys " + n; });
</script>
HTML

cat > "$CLIENT" <<'PY'
import argparse, os, subprocess, sys, time

FAILS = []
ADB = []


def line(kind, tag, msg):
    print("%s [%s] %s" % (kind, tag, msg), flush=True)
    if kind == "FAIL":
        FAILS.append(tag)


def check(ok, tag, msg):
    line("PASS" if ok else "FAIL", tag, msg)


def shell(*args):
    """adb on this emulator only (`-s`), never another serial."""
    return subprocess.run(ADB + ["shell"] + list(args), capture_output=True, text=True, timeout=30).stdout


SEQ = [100]
PROTO = [None]
CLIPS = []  # every clip.set the phone sent during the run (lengths only)


def expect(client, deckctl, want, timeout):
    """The next JSON message of type [want]; a clip.set on the way is counted."""
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
        if msg.get("t") == want or (msg.get("t") == "error" and want != "ui.tree"):
            return msg
    return {}


def request(client, deckctl, obj, timeout=10):
    SEQ[0] += 1
    obj = dict(obj, seq=SEQ[0])
    client.send_json(obj)
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = expect(client, deckctl, obj["t"], max(0.1, deadline - time.time()))
        if not msg or msg.get("seq") == obj["seq"]:
            return msg
    return {}


def drain(client, deckctl, seconds):
    end = time.time() + seconds
    while time.time() < end:
        expect(client, deckctl, "__none__", max(0.05, end - time.time()))


def rows(client, deckctl):
    return request(client, deckctl, {"t": "ui.tree", "stream": 1}).get("nodes") or []


def settle(client, deckctl):
    request(client, deckctl, {"t": "ui.settle", "stream": 1, "quietMs": 300, "timeoutMs": 2000})


def key(client, keycode, meta=0):
    proto = PROTO[0]
    client.send_raw(proto.pack_key(1, proto.KEY_DOWN, keycode, meta))
    client.send_raw(proto.pack_key(1, proto.KEY_UP, keycode, meta))
    time.sleep(0.05)


def type_(client, deckctl, text, **flags):
    return request(client, deckctl, dict({"t": "ui.type", "stream": 1, "text": text}, **flags))


def answer(r):
    return "ok=%s entry=%s via=%s chars=%s code=%s" % (r.get("ok"), r.get("entry"), r.get("via"),
                                                       r.get("characters"), r.get("code"))


def field_of(client, deckctl, k):
    """The row with key [k] now (its text compared, never printed)."""
    return next((n for n in rows(client, deckctl) if n.get("k") == k), {})


def until(test, seconds=10):
    deadline = time.time() + seconds
    value = test()
    while not value and time.time() < deadline:
        time.sleep(0.5)
        value = test()
    return value


CTRL = 0x1000 | 0x2000
KEYCODE_A, KEYCODE_C, KEYCODE_DEL, KEYCODE_DPAD_LEFT, KEYCODE_PASTE = 29, 31, 67, 21, 279
CLIP = "pdclip7731"


def round_trip(client, deckctl, tag, k, keys_first):
    """Before + typed + after at the cursor, then a key right after it, then clear."""
    settle(client, deckctl)
    if keys_first:
        r = type_(client, deckctl, "garrafa 500ml", clear=True)
        check(r.get("ok") is True and r.get("characters") == 13, tag, "key-map text with clear: %s" % answer(r))
        for _ in range(5):
            key(client, KEYCODE_DPAD_LEFT)  # the cursor to 8: "garrafa |500ml"
    else:
        request(client, deckctl, {"t": "ui.press", "stream": 1, "k": k})  # focus: the page puts its cursor at 8
        time.sleep(0.5)
    settle(client, deckctl)
    r = type_(client, deckctl, "térmica ")
    check(r.get("ok") is True and r.get("entry") == "inserted" and r.get("via") == "set_text"
          and r.get("characters") == 8, tag, "\"térmica \" at the cursor: %s" % answer(r))
    settle(client, deckctl)
    now = field_of(client, deckctl, k).get("text")
    check(now == "garrafa térmica 500ml", tag, "the field reads before + typed + after (match=%s)"
          % (now == "garrafa térmica 500ml"))
    r = type_(client, deckctl, "X")
    settle(client, deckctl)
    now = field_of(client, deckctl, k).get("text")
    check(r.get("via") == "keys" and now == "garrafa térmica X500ml", tag,
          "the next key lands right after the typed text, the cursor at 16 (%s, match=%s)"
          % (answer(r), now == "garrafa térmica X500ml"))
    if now != "garrafa térmica X500ml":
        line("INFO", tag, "where the key went: right place but lowercase=%s, at the end=%s, not typed=%s" % (
            now == "garrafa térmica x500ml", now == "garrafa térmica 500mlX", now == "garrafa térmica 500ml"))
    r = type_(client, deckctl, "café", clear=True)
    settle(client, deckctl)
    now = field_of(client, deckctl, k).get("text")
    check(r.get("entry") == "replaced" and r.get("via") == "set_text" and now == "café", tag,
          "clear replaces: %s, match=%s" % (answer(r), now == "café"))


def main():
    ap = argparse.ArgumentParser()
    for name in ("--host", "--state", "--wt", "--adb", "--serial", "--page", "--browser"):
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
    client.send_json({"t": "window.open", "stream": 1, "w": 720, "h": 1560, "dpi": 320, "mode": "phone"})
    expect(client, deckctl, "window.opened", 40)
    subprocess.run(ADB + ["logcat", "-c"], timeout=30)

    # 1. Contacts' editor: its first field.
    shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.INSERT",
          "-t", "vnd.android.cursor.dir/contact")
    edit = until(lambda: next((n for n in rows(client, deckctl) if n.get("edit") and n.get("at")
                               and not n.get("pwd")), None), 20)
    check(edit is not None, "MCP-109", "the contact editor shows a field (%s)" % (edit or {}).get("role"))
    copied = False
    if edit is None:
        shapes(client, deckctl, "editor")
    else:
        k = edit["k"]
        request(client, deckctl, {"t": "ui.press", "stream": 1, "k": k})
        settle(client, deckctl)
        # The person's clip, copied by the app itself: the field's text, all of it.
        r = type_(client, deckctl, CLIP, clear=True)
        check(r.get("ok") is True, "MCP-110", "the clip's text typed: %s" % answer(r))
        key(client, KEYCODE_A, CTRL)
        key(client, KEYCODE_C, CTRL)
        drain(client, deckctl, 1.0)
        # ctrl+A, ctrl+C are shortcuts: they copy and type nothing. A field that
        # grew means the KEY frames' ctrl was lost and nothing was copied.
        held = field_of(client, deckctl, k).get("text")
        check(held == CLIP, "MCP-110", "ctrl+A, ctrl+C copied and typed nothing (match=%s, typed a and c=%s)"
              % (held == CLIP, held == CLIP + "ac"))
        CLIPS.clear()  # from here on, the phone's clipboard must not change
        copied = True
        round_trip(client, deckctl, "MCP-109 EditText", k, keys_first=True)

    # 2. A WebView <input> on a local page.
    shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.VIEW",
          "-d", "http://127.0.0.1:%s/input.html" % args.page, "-p", args.browser)
    web = until(lambda: next((n for n in rows(client, deckctl) if n.get("edit") and n.get("at")
                              and n.get("text") == "garrafa 500ml"), None), 25)
    check(web is not None, "MCP-109", "the page's input is a row (%s)" % (web or {}).get("role"))
    if web is not None:
        round_trip(client, deckctl, "MCP-109 WebView", web["k"], keys_first=False)
    else:
        shapes(client, deckctl, "input page")

    # 3. A canvas that takes keys and no set text.
    shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.VIEW",
          "-d", "http://127.0.0.1:%s/canvas.html" % args.page, "-p", args.browser)
    counter = lambda: next((n for n in rows(client, deckctl) if (n.get("text") or "").startswith("keys ")), None)
    shown = until(counter, 25)
    check(shown is not None, "MCP-109", "the canvas page shows its key count")
    if shown is None:
        shapes(client, deckctl, "canvas page")
    else:
        box = shown["box"]
        size = request(client, deckctl, {"t": "ui.tree", "stream": 1}).get("size") or [1, 1]
        at = ((box[0] + box[2]) / 2.0 / size[0], max(0.0, box[1] - 150) / size[1])
        client.send_raw(proto.pack_touch(1, proto.TOUCH_DOWN, 0, at[0], at[1]))
        time.sleep(0.05)
        client.send_raw(proto.pack_touch(1, proto.TOUCH_UP, 0, at[0], at[1]))
        settle(client, deckctl)
        r = type_(client, deckctl, "térmica")
        settle(client, deckctl)
        after = (counter() or {}).get("text")
        check(r.get("ok") is False and r.get("code") == "not_supported" and after == "keys 0", "MCP-109",
              "a canvas with no set text: %s, nothing typed (count unchanged=%s)" % (answer(r), after == "keys 0"))
        # Its keys still go: key-map text is keys (MCP-109).
        r = type_(client, deckctl, "ab")
        settle(client, deckctl)
        after = (counter() or {}).get("text")
        line("INFO", "MCP-109", "key-map text on the canvas: %s, count now 2=%s" % (answer(r), after == "keys 2"))

    # 4. The clip is the same: paste it into the cleared editor field.
    shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.INSERT",
          "-t", "vnd.android.cursor.dir/contact")
    edit = until(lambda: next((n for n in rows(client, deckctl) if n.get("edit") and n.get("at")
                               and not n.get("pwd")), None), 20) if copied else None
    if not copied:
        line("FAIL", "MCP-110", "no clip was copied in step 1, so the clip check could not run")
    elif edit is None:
        line("FAIL", "MCP-110", "the editor showed no field for the paste check")
    else:
        k = edit["k"]
        request(client, deckctl, {"t": "ui.press", "stream": 1, "k": k})
        settle(client, deckctl)
        type_(client, deckctl, "q", clear=True)
        key(client, KEYCODE_DEL)
        sent = len(CLIPS)
        key(client, KEYCODE_PASTE)
        settle(client, deckctl)
        pasted = field_of(client, deckctl, k).get("text")
        check(pasted == CLIP and sent == 0, "MCP-110",
              "the clip copied before the run pastes the same after it (match=%s), clip.set sent during it: %d"
              % (pasted == CLIP, sent))
        # The control: the person's text path pastes through the clipboard (#173).
        type_(client, deckctl, "q", clear=True)
        key(client, KEYCODE_DEL)
        client.send_json({"t": "text", "stream": 1, "text": "é"})
        time.sleep(1.5)
        type_(client, deckctl, "q", clear=True)
        key(client, KEYCODE_DEL)
        key(client, KEYCODE_PASTE)
        settle(client, deckctl)
        pasted = field_of(client, deckctl, k).get("text")
        line("INFO", "control", "after the text path typed a non-ASCII run the clip is still ours=%s "
             "(expected False until T14)" % (pasted == CLIP))
    log = subprocess.run(ADB + ["logcat", "-d"], capture_output=True, text=True, timeout=30).stdout
    types = [l.split("ui.type ")[-1] for l in log.splitlines() if "ui.type stream=" in l]
    leaked = [l for l in types if "café" in l or "rmica" in l or CLIP in l]
    check(bool(types) and not leaked, "MCP-109", "the phone logged %d ui.type lines, none with text" % len(types))
    for l in types:
        line("INFO", "log", l)
    return finish(client)


def shapes(client, deckctl, where):
    """What the display showed when a step found nothing: the tree's answer, the
    resumed package and each row's role and flags; never a label."""
    reply = request(client, deckctl, {"t": "ui.tree", "stream": 1})
    resumed = "?"
    for l in shell("dumpsys", "activity", "activities").splitlines():
        if "ResumedActivity" in l and "/" in l:
            resumed = l.split("/")[0].split()[-1]
            break
    # The window with focus, by its system name (an activity, NotificationShade,
    # an "Application Not Responding" dialog): a system layer over the app is
    # named here, never read.
    focused = "?"
    for l in shell("dumpsys", "window").splitlines():
        if "mCurrentFocus=" in l:
            focused = l.split("mCurrentFocus=", 1)[1].strip().rstrip("}").split(" ")[-1]
            break
    line("INFO", "evidence", "%s: tree ok=%s code=%s rows=%d layers=%s resumed=%s focus=%s" % (
        where, reply.get("ok"), reply.get("code"), len(reply.get("nodes") or []),
        [(l.get("type"), bool(l.get("active"))) for l in reply.get("layers") or []], resumed, focused))
    # The emulator's screen as it was (the rig's own test apps, nothing of a
    # person's), next to this script, so a layer the tree names is seen.
    try:
        png = subprocess.run(ADB + ["exec-out", "screencap", "-p"], capture_output=True, timeout=30).stdout
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "evidence-%s.png" % "".join(c if c.isalnum() else "-" for c in where))
        with open(path, "wb") as handle:
            handle.write(png)
        line("INFO", "evidence", "%s: screen %s (%d bytes)" % (where, path, len(png)))
    except (OSError, subprocess.SubprocessError) as error:
        line("INFO", "evidence", "%s: no screen (%s)" % (where, type(error).__name__))
    for n in (reply.get("nodes") or [])[:40]:
        line("INFO", "evidence", "  %s %s" % (n.get("role"), sorted(f for f in (
            "click", "edit", "focus", "hint", "pwd", "scroll") if n.get(f))))


def finish(client):
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
  [ "$rc" = 0 ] && echo "CHECK OK"
  exit $rc
fi

if device_present; then echo "[ui-type] abort: $SERIAL already up (not this run's)"; exit 2; fi
PAGE_PID=""
cleanup() {
  [ -n "$PAGE_PID" ] && kill "$PAGE_PID" 2>/dev/null
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}
trap cleanup EXIT
T0=$(date +%s)
bash "$REPO_ROOT/tools/emulator/start.sh" --no-build > "$OUT/start.log" 2>&1 \
  || { tail -30 "$OUT/start.log"; echo "[ui-type] start.sh failed"; exit 1; }
echo "[ui-type] booted in $(( $(date +%s) - T0 ))s"
"$PYTHON" -m http.server "$PAGE_PORT" --bind 127.0.0.1 --directory "$OUT/pages" > "$OUT/pages.log" 2>&1 &
PAGE_PID=$!
emu reverse "tcp:$PAGE_PORT" "tcp:$PAGE_PORT" >/dev/null || { echo "[ui-type] adb reverse failed"; exit 1; }
STATE="$CACHE_DIR/deckctl-state-$(date +%s).json"
paired=0
for attempt in 1 2 3 4; do
  bash "$REPO_ROOT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
  if "$PYTHON" "$REPO_ROOT/tools/emulator/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" \
       --serial "$SERIAL" --adb "$ADB" pair > "$OUT/pair-$attempt.log" 2>&1; then paired=1; break; fi
  sleep 4
done
[ "$paired" = 1 ] || { echo "[ui-type] pairing failed"; tail -5 "$OUT"/pair-*.log; exit 1; }
echo "[ui-type] paired"
"$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" --wt "$REPO_ROOT" \
  --adb "$ADB" --serial "$SERIAL" --page "$PAGE_PORT" --browser "$BROWSER"
rc=$?
echo "[ui-type] total $(( $(date +%s) - T0 ))s"
exit $rc
