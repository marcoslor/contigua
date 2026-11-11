#!/usr/bin/env bash
# SHARE-16's A2 proof and SHARE-17's targeted drop: ONE emulator boot.
#
#   bash tools/emulator/paste-drop.sh --check    rehearsal: preflight, syntax,
#                                                deckctl verbs, the debug activity
#                                                in the APK; no device
#   ~/dev/contigua/.agent/heavy.sh bash tools/emulator/paste-drop.sh
#
# The APK must already be built with the Docker K1
# (`k1-docker.sh <android> :app:assembleDebug`); start.sh runs with --no-build so
# no JVM ever runs on the host. The emulator, the checks and the kill are this
# one call. Pairing is poc.py's prompt-and-Allow path, once.
#
# A2: the app process writes the Mac's clipboard image (boot 5 showed the
# shell's own URI clip refused), with the launcher on top. KEYCODE_PASTE in a
# plain EditText pastes nothing, while an EditText whose OnReceiveContentListener
# takes image/* reads the fixture's exact bytes; the debug activity sets no clip
# in that step and is only a labelled control afterwards.
#
# SHARE-17: a drop with a target opens that installed SEND app with no chooser
# (CONTIGUA_DROP_TARGET overrides the first installed one); the same drop
# without a target opens the system chooser; a 3-file batch shares once.
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "paste-drop.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export CONTIGUA_PORT="${CONTIGUA_PORT:-47983}"
export CONTIGUA_SERIAL=emulator-5554
export CONTIGUA_AGENT_DIR="$PWD/.agent/emu"
mkdir -p "$CONTIGUA_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$CONTIGUA_AGENT_DIR"
LOG="$OUT/paste-drop.log"
APK="android/app/build/outputs/apk/debug/app-debug.apk"
STATE="$CACHE_DIR/deckctl-state.json"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" --state "$STATE")
FAILED=0

section() { # section <name> PASS|FAIL <detail...>
  printf 'SECTION %s\n' "$*" | tee -a "$LOG"
  [ "$2" = "PASS" ] || FAILED=1
}

check_mode() {
  : > "$LOG"
  bash -n tools/emulator/paste-drop.sh || { section syntax FAIL "bash -n"; return 1; }
  section syntax PASS "bash -n tools/emulator/paste-drop.sh"
  bash tools/emulator/preflight.sh || { section preflight FAIL "preflight"; return 1; }
  section preflight PASS "preflight (no device)"
  "$PYTHON" tools/fakephone/deckctl.py clipimage --help >/dev/null \
    || { section deckctl FAIL "clipimage"; return 1; }
  "$PYTHON" tools/fakephone/deckctl.py drop --help >/dev/null \
    || { section deckctl FAIL "drop"; return 1; }
  "$PYTHON" tools/fakephone/deckctl.py dropbatch --help >/dev/null \
    || { section deckctl FAIL "dropbatch"; return 1; }
  section deckctl PASS "clipimage, drop and dropbatch verbs"
  [ -f "$APK" ] || { section apk FAIL "no $APK (build it with k1-docker)"; return 1; }
  "$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" 2>/dev/null |
    grep -q "PasteDebugActivity" \
    && section apk PASS "debug activity in the merged manifest" \
    || { section apk FAIL "PasteDebugActivity not in $APK"; return 1; }
  section dry-run PASS "no device touched; run without --check boots once"
}

if [ "$MODE" = "check" ]; then
  check_mode
  exit $?
fi

"$ADB" devices 2>/dev/null | grep -q "^$SERIAL" && die "$SERIAL already running: refusing to touch it"
kill_emulator() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
trap 'kill_emulator' EXIT

{
  echo "=== paste-drop started $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
} > "$LOG"

[ -f "$APK" ] || die "no $APK (build it with k1-docker :app:assembleDebug)"
step "booting $SERIAL (one boot budget)"
if ! bash tools/emulator/start.sh --no-build > "$OUT/paste-drop-start.log" 2>&1; then
  tail -5 "$OUT/paste-drop-start.log" | tee -a "$LOG"
  section boot FAIL "start.sh --no-build (see $OUT/paste-drop-start.log)"
  exit 1
fi
section boot PASS "$(tail -1 "$OUT/paste-drop-start.log")"

pair_once() {
  "$PYTHON" tools/emulator/poc.py --state "$STATE" --addr "127.0.0.1:$PORT" \
    --serial "$SERIAL" --adb "$ADB" pair > "$OUT/paste-drop-pair.log" 2>&1
}
if pair_once; then
  section pair PASS "poc.py pair"
else
  tail -5 "$OUT/paste-drop-pair.log" | tee -a "$LOG"
  section pair FAIL "poc.py pair (see $OUT/paste-drop-pair.log)"
  exit 1
fi

# --- one 48x48 PNG for both proofs -----------------------------------------
PNG="$OUT/paste-drop.png"
"$PYTHON" - "$PNG" <<'PY'
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
rows = b"".join(b"\x00" + bytes((x * 5 + y * 11) % 256 for x in range(48 * 3)) for y in range(48))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 48, 48, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
# The debug activity draws on the main display, so the rig is awake and past
# its PIN for these fields (the product's own lock tests are elsewhere).
step "waking the rig for the two fields"
bash tools/emulator/unlock.sh > "$OUT/paste-drop-unlock.log" 2>&1 \
  || { section unlock FAIL "unlock.sh (see $OUT/paste-drop-unlock.log)"; }

debug_log() { emu logcat -d -s PasteDebug:I 2>/dev/null | tr -d '\r'; }
clear_debug_log() { emu logcat -c >/dev/null 2>&1 || true; }
start_debug() {
  emu shell am start -W -n app.contigua/.app.PasteDebugActivity "$@" \
    >> "$OUT/paste-drop-debug-start.log" 2>&1 || true
  sleep 1
}
debug_top() {
  emu shell dumpsys activity activities 2>/dev/null | tr -d '\r' |
    grep -E 'mResumedActivity|topResumedActivity' | head -1
}
back() { emu shell input keyevent 4 >/dev/null 2>&1 || true; sleep 0.5; }
paste_key() { emu shell input keyevent 279 >/dev/null 2>&1 || true; sleep 1.5; }

# --- A2 --------------------------------------------------------------------
# The real path: the app process owns the clipboard image (boot 5, H1). The app
# must be in the background when the Mac's clip arrives, so the launcher goes on
# top first; the debug activity is opened only after clip.image.done ok=True and
# sets no clip of its own in this step.
step "A2: the app writes a Mac clipboard image from the background"
back
emu shell input keyevent 3 >/dev/null 2>&1 || true
sleep 1
A2_TOP="$(debug_top)"
printf '  top before clipimage: %s\n' "$A2_TOP" | tee -a "$LOG"
if printf '%s' "$A2_TOP" | grep -q 'app.contigua'; then
  section a2-background FAIL "the app is on top before the clip: $A2_TOP"
else
  section a2-background PASS "the app is in the background: $A2_TOP"
fi
PNG_BYTES="$(wc -c < "$PNG" | tr -d ' ')"
if "${DC[@]}" clipimage "$PNG" --id 9001 > "$OUT/paste-drop-a2-clip.log" 2>&1 \
    && grep -q 'ok=True' "$OUT/paste-drop-a2-clip.log"; then
  section a2-clip PASS "$(tail -1 "$OUT/paste-drop-a2-clip.log")"
else
  tail -3 "$OUT/paste-drop-a2-clip.log" | tee -a "$LOG"
  section a2-clip FAIL "clipimage (see $OUT/paste-drop-a2-clip.log)"
fi
sleep 1
A2_TRACE="$(emu logcat -d -s ContiguaSvc:I ClipImageWriter:I 2>/dev/null | tr -d '\r' \
  | grep -E 'clip image:|ClipImageWriter' | tail -6)"
printf '%s\n' "$A2_TRACE" > "$OUT/paste-drop-a2-write.log"
printf '%s\n' "$A2_TRACE" | sed 's/^/  /' | tee -a "$LOG"
if printf '%s' "$A2_TRACE" | grep -q 'app answered ok=true'; then
  section a2-write PASS "$(printf '%s\n' "$A2_TRACE" | grep 'app answered ok=true' | tail -1)"
else
  section a2-write FAIL "no app-owned clipboard write in logcat"
fi

# The real clip, no debug clip: a plain field pastes nothing and the image
# field reads the fixture's exact byte count.
clear_debug_log
start_debug --es field plain
PLAIN_TOP="$(debug_top)"
paste_key
PLAIN="$(debug_log)"
printf '%s\n' "$PLAIN" > "$OUT/paste-drop-a2-plain.log"
if ! printf '%s' "$PLAIN_TOP" | grep -q 'PasteDebugActivity'; then
  section a2-plain FAIL "the debug activity is not on top: $PLAIN_TOP"
elif printf '%s\n' "$PLAIN" | grep -q 'plain text length=[1-9]'; then
  section a2-plain FAIL "the app's image item pasted text: $(printf '%s\n' "$PLAIN" | grep 'plain text length=' | tail -1)"
else
  section a2-plain PASS "the app's image item pasted nothing in a plain field (text length stayed 0)"
fi
back

clear_debug_log
start_debug --es field rich
RICH_TOP="$(debug_top)"
paste_key
RICH="$(debug_log | grep 'rich image bytes=' | tail -1)"
printf '%s\n' "$RICH" > "$OUT/paste-drop-a2-rich.log"
if ! printf '%s' "$RICH_TOP" | grep -q 'PasteDebugActivity'; then
  section a2-rich FAIL "the debug activity is not on top: $RICH_TOP"
elif printf '%s\n' "$RICH" | grep -q "rich image bytes=$PNG_BYTES"; then
  section a2-rich PASS "$RICH"
else
  section a2-rich FAIL "the image field got '${RICH:-nothing}', wanted $PNG_BYTES bytes"
fi
back

# Control: the debug activity sets the same URI-only item itself. A plain field
# must still paste nothing; the image field reads the debug fixture, not the
# real one. Labelled so it cannot be mistaken for the real path.
clear_debug_log
start_debug --es item uri --es field plain
URI_TOP="$(debug_top)"
paste_key
URI_LOG="$(debug_log)"
printf '%s\n' "$URI_LOG" > "$OUT/paste-drop-a2-uri.log"
URI_LINE="$(printf '%s\n' "$URI_LOG" | grep 'plain text length=' | tail -1)"
if ! printf '%s' "$URI_TOP" | grep -q 'PasteDebugActivity'; then
  section a2-uri-control-plain FAIL "the debug activity is not on top: $URI_TOP"
else
  section a2-uri-control-plain PASS "debug-set URI-only item in a plain field: ${URI_LINE:-no text line (pasted nothing)}"
fi
back

clear_debug_log
start_debug --es item uri --es field rich
URI_RICH_TOP="$(debug_top)"
paste_key
URI_RICH="$(debug_log | grep 'rich image bytes=' | tail -1)"
printf '%s\n' "$URI_RICH" > "$OUT/paste-drop-a2-uri-rich.log"
if ! printf '%s' "$URI_RICH_TOP" | grep -q 'PasteDebugActivity'; then
  section a2-uri-control-rich FAIL "the debug activity is not on top: $URI_RICH_TOP"
elif printf '%s\n' "$URI_RICH" | grep -q 'rich image bytes=[1-9]'; then
  section a2-uri-control-rich PASS "$URI_RICH"
else
  section a2-uri-control-rich FAIL "the debug-set image got nothing: ${URI_RICH:-no listener line}"
fi
back

# --- SHARE-17 --------------------------------------------------------------
# The target must be an app that really takes ACTION_SEND for an image on this
# AVD: hard-coding one that is not installed proves nothing. Query the device,
# skip the system UI and ourselves, and keep CONTIGUA_DROP_TARGET as an
# override.
emu shell cmd package query-activities -a android.intent.action.SEND \
  -c android.intent.category.DEFAULT -t image/png 2>/dev/null | tr -d '\r' \
  > "$OUT/paste-drop-send-apps.log" || true
SEND_PKGS="$(sed -n 's/.*packageName=\(.*\)/\1/p' "$OUT/paste-drop-send-apps.log" \
  | grep -Ev '^(dev\.contigua|android|com\.android\.systemui)$' | awk '!seen[$0]++')"
INSTALLED="$(printf '%s\n' "$SEND_PKGS" | head -1)"
# The built-in print service hands its SEND to the print spooler, so its top is
# not its own package; prefer Messages when it is installed: its share activity
# stays in its package.
if printf '%s\n' "$SEND_PKGS" | grep -qx 'com.google.android.apps.messaging'; then
  INSTALLED=com.google.android.apps.messaging
fi
TARGET="${CONTIGUA_DROP_TARGET:-${INSTALLED:-org.fossify.messages}}"
step "SHARE-17: a drop targeted at $TARGET (SEND apps: $(tr '\n' ' ' < "$OUT/paste-drop-send-apps.log" | cut -c1-160))"
emu logcat -c >/dev/null 2>&1 || true
if "${DC[@]}" drop "$PNG" --target "$TARGET" --id 9002 \
      > "$OUT/paste-drop-target.log" 2>&1; then
  section drop-target PASS "$(tail -1 "$OUT/paste-drop-target.log")"
else
  tail -3 "$OUT/paste-drop-target.log" | tee -a "$LOG"
  section drop-target FAIL "deckctl drop --target (see $OUT/paste-drop-target.log)"
fi
sleep 2
SHARE_LOG="$(emu logcat -d -s ContiguaDrop:I ContiguaSvc:I 2>/dev/null | tr -d '\r' \
  | grep -E 'share offered|share: target|share: chooser|trampoline: started|drop: (SEND|am start|staging)' \
  | tail -5 | tr '\n' ' | ')"
if printf '%s' "$SHARE_LOG" | grep -q "to $TARGET"; then
  section target-share PASS "$SHARE_LOG"
else
  section target-share FAIL "no targeted share line: ${SHARE_LOG:-none}"
fi
TOP="$(emu shell dumpsys activity activities 2>/dev/null | tr -d '\r' |
       grep -E 'mResumedActivity|topResumedActivity' | head -1)"
if printf '%s' "$TOP" | grep -q "$TARGET"; then
  section target-top PASS "top activity: $TOP"
else
  section target-top FAIL "top activity is not the target: $TOP"
fi
back

step "SHARE-17: the same drop without a target keeps the chooser"
emu logcat -c >/dev/null 2>&1 || true
if "${DC[@]}" drop "$PNG" --id 9003 \
      > "$OUT/paste-drop-notarget.log" 2>&1; then
  section drop-notarget PASS "$(tail -1 "$OUT/paste-drop-notarget.log")"
else
  tail -3 "$OUT/paste-drop-notarget.log" | tee -a "$LOG"
  section drop-notarget FAIL "deckctl drop (see $OUT/paste-drop-notarget.log)"
fi
sleep 2
CHOOSER="$(emu shell dumpsys activity activities 2>/dev/null | tr -d '\r' |
           grep -E 'mResumedActivity|topResumedActivity' | head -1)"
if printf '%s' "$CHOOSER" | grep -Eq 'intentresolver|ChooserActivity'; then
  section notarget-chooser PASS "top activity: $CHOOSER"
else
  section notarget-chooser FAIL "no chooser for an untargeted drop: $CHOOSER"
fi

step "SHARE-17: a 3-file batch shares once"
back
emu logcat -c >/dev/null 2>&1 || true
if "${DC[@]}" dropbatch "$PNG" --target "$TARGET" --count 3 --id 9100 \
    > "$OUT/paste-drop-batch.log" 2>&1; then
  section batch-drop PASS "$(tail -1 "$OUT/paste-drop-batch.log")"
else
  tail -3 "$OUT/paste-drop-batch.log" | tee -a "$LOG"
  section batch-drop FAIL "dropbatch (see $OUT/paste-drop-batch.log)"
fi
sleep 2
BATCH_SHARE="$(emu logcat -d -s ContiguaDrop:I ContiguaSvc:I 2>/dev/null | tr -d '\r' \
  | grep -E 'share offered for 3 file|share: chooser for 3 file|share refused' | tail -3 | tr '\n' ' | ')"
printf '%s\n' "$BATCH_SHARE" > "$OUT/paste-drop-batch-share.log"
if printf '%s' "$BATCH_SHARE" | grep -Eq 'share offered for 3 file|share: chooser for 3 file'; then
  section batch-share PASS "$BATCH_SHARE"
else
  section batch-share FAIL "no 3-file share: '${BATCH_SHARE:-none}'"
fi
printf '  batch top: %s\n' "$(emu shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -E 'mResumedActivity|topResumedActivity' | head -1)" | tee -a "$LOG"
back

# The logcat is always kept: a diagnosis run needs the trace even when every
# section passed, and a proof run needs it when one did not.
emu logcat -d -s ContiguaSvc:I ContiguaDrop:I PasteDebug:I ClipImageWriter:I 2>/dev/null \
  | tr -d '\r' > "$OUT/paste-drop-logcat.txt" || true
printf 'SECTION logcat INFO %s lines in %s\n' \
  "$(wc -l < "$OUT/paste-drop-logcat.txt" | tr -d ' ')" "paste-drop-logcat.txt" | tee -a "$LOG"

kill_emulator
exit "$FAILED"
