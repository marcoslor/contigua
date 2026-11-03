#!/usr/bin/env bash
# `fs.thumb` against the real phone server on the emulator rig (FILES-24/28):
# push a generated JPEG, HEIC and MP4 into DCIM/Camera, ask deckctl for each
# thumbnail, and print the mime, the long side, the byte count and the
# duration. Every answer must be at most 256 KiB with a long side at most 512,
# and the screen, the app's wake locks and the stream log must be unchanged:
# the screen is asleep before the asks and still asleep after them.
#
#   tools/emulator/start.sh
#   ~/dev/pocketdeck/.agent/heavy.sh bash tools/emulator/thumb.sh
#
# The files are generated (ffmpeg + sips for HEIC), never a real photo, and are
# removed at the end. No File Provider and no Mac app are involved.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

DECKCTL="$REPO_ROOT/tools/fakephone/deckctl.py"
STATE="$CACHE_DIR/deckctl-state.json"
WORK="$AGENT_DIR/thumbs"
FOLDER="DCIM/Camera"
NAME="pd-thumb"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

device_present || die "$SERIAL is not running - run tools/emulator/start.sh first"
DEVPORT="$(ensure_forward)" || die "cannot find the PocketDeck server port on $SERIAL (is the app running?)"
step "forward: 127.0.0.1:$PORT -> device tcp:$DEVPORT"
mkdir -p "$WORK"

deckctl() {
    ensure_forward >/dev/null 2>&1 || true
    "$PYTHON" "$DECKCTL" --host 127.0.0.1 --port "$PORT" --state "$STATE" "$@"
}

pair_if_needed() {
    "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1 && return 0
    "$EMU_DIR/unlock.sh" || true
    "$PYTHON" "$EMU_DIR/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair
}
pair_if_needed || die "could not pair with the rig"

command -v ffmpeg >/dev/null || die "ffmpeg is needed to make the fixtures"
command -v sips >/dev/null || die "sips is needed to make the HEIC fixture"

step "fixtures: a 1200x900 JPEG, its HEIC, and a 1 s 640x480 MP4"
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=1200x900:rate=1" \
    -frames:v 1 -q:v 4 "$WORK/$NAME.jpg" >/dev/null 2>&1 \
    || die "could not make the JPEG fixture"
sips -s format heic "$WORK/$NAME.jpg" --out "$WORK/$NAME.heic" >/dev/null 2>&1 \
    || die "could not make the HEIC fixture"
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=640x480:rate=30:duration=1" \
    -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$WORK/$NAME.mp4" >/dev/null 2>&1 \
    || die "could not make the MP4 fixture"
for ext in jpg heic mp4; do
    emu push "$WORK/$NAME.$ext" "/sdcard/$FOLDER/$NAME.$ext" >/dev/null 2>&1 \
        || die "could not push the $ext fixture"
done
# The shell's own storage is readable at shell uid; the MediaStore row is not
# needed because ThumbnailUtils decodes the path.
emu shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d "file:///sdcard/$FOLDER/$NAME.jpg" >/dev/null 2>&1 || true

power_dump() { emu shell dumpsys power 2>/dev/null | tr -d '\r'; }
wake_state() { power_dump | grep -m1 'mWakefulness=' | sed 's/.*mWakefulness=//'; }
# The held locks only: `dumpsys power` also keeps an ACQ/REL history, and a
# notification post there is not a lock the app holds.
app_wake_locks() {
    power_dump | sed -n '/Wake Locks: size=/,/^$/p' | grep -ci 'pocketdeck' || true
}
display_state() {
    local tag="$1"
    power_dump > "$WORK/power-$tag.txt"
    emu shell dumpsys display > "$WORK/display-$tag.txt" 2>/dev/null || true
    "$PYTHON" "$EMU_DIR/display-state.py" "$WORK/display-$tag.txt" \
        --power "$WORK/power-$tag.txt" 2>/dev/null | cut -f1
}

# Screen asleep before the asks, so a thumbnail that woke it or took a wake
# lock would show up as a change (FILES-28).
emu shell input keyevent 223 >/dev/null 2>&1 || true
sleep 2
WAKE_BEFORE="$(wake_state)"
DISPLAY_BEFORE="$(display_state before)"
LOCKS_BEFORE="$(app_wake_locks)"
step "screen before: wakefulness=${WAKE_BEFORE:-none} display=${DISPLAY_BEFORE:-unknown} app wake locks=$LOCKS_BEFORE"
if [ "$WAKE_BEFORE" = "Asleep" ] || [ "$DISPLAY_BEFORE" = "OFF" ] || [ "$DISPLAY_BEFORE" = "DOZE" ]; then
    ok "THUMB the screen is off before the asks"
else
    bad "THUMB the screen is not off before the asks (${WAKE_BEFORE:-none}/${DISPLAY_BEFORE:-unknown})"
fi
emu logcat -c >/dev/null 2>&1 || true

for ext in jpg heic mp4; do
    out="$WORK/answer-$ext.img"
    if ! deckctl fs thumb "$FOLDER/$NAME.$ext" "$out" --size 512 \
            > "$WORK/thumb-$ext.json" 2> "$WORK/thumb-$ext.err"; then
        bad "THUMB $ext: fs.thumb failed: $(tail -1 "$WORK/thumb-$ext.err")"
        continue
    fi
    mime="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["mime"])' "$WORK/thumb-$ext.json" 2>/dev/null)"
    bytes="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["bytes"])' "$WORK/thumb-$ext.json" 2>/dev/null)"
    ms="$("$PYTHON" -c 'import json,sys;print(json.load(open(sys.argv[1]))["ms"])' "$WORK/thumb-$ext.json" 2>/dev/null)"
    dims="$(sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null \
        | awk '/pixelWidth:/{w=$2}/pixelHeight:/{h=$2}END{if (w && h) print w, h}')"
    width="${dims% *}"; height="${dims#* }"
    long=0
    [ -n "$width" ] && [ -n "$height" ] && long=$(( width > height ? width : height ))
    step "THUMB $ext: mime=${mime:-none} long=${long:-?} bytes=${bytes:-?} ms=${ms:-?}"
    if [ "${mime:-none}" = "image/jpeg" ] || [ "${mime:-none}" = "image/png" ]; then
        ok "THUMB [$ext] mime=$mime"
    else
        bad "THUMB [$ext] unexpected mime ${mime:-none}"
    fi
    if [ "${bytes:-9999999}" -le 262144 ]; then
        ok "THUMB [$ext] $bytes bytes is within 256 KiB"
    else
        bad "THUMB [$ext] ${bytes:-?} bytes is over 256 KiB"
    fi
    if [ "$long" -ge 1 ] && [ "$long" -le 512 ]; then
        ok "THUMB [$ext] long side $long is within 512"
    else
        bad "THUMB [$ext] long side ${long:-?} is outside 1..512"
    fi
done

WAKE_AFTER="$(wake_state)"
DISPLAY_AFTER="$(display_state after)"
LOCKS_AFTER="$(app_wake_locks)"
step "screen after: wakefulness=${WAKE_AFTER:-none} display=${DISPLAY_AFTER:-unknown} app wake locks=$LOCKS_AFTER"
if [ "$WAKE_AFTER" = "$WAKE_BEFORE" ] && [ "$DISPLAY_AFTER" = "$DISPLAY_BEFORE" ]; then
    ok "THUMB the screen state is the same before and after (${WAKE_BEFORE:-none}/${DISPLAY_BEFORE:-unknown})"
else
    bad "THUMB the screen changed (${WAKE_BEFORE:-none}/${DISPLAY_BEFORE:-unknown} -> ${WAKE_AFTER:-none}/${DISPLAY_AFTER:-unknown})"
fi
if [ "$LOCKS_AFTER" -le "$LOCKS_BEFORE" ] && [ "$LOCKS_AFTER" -eq 0 ]; then
    ok "THUMB the app holds no wake lock after the asks ($LOCKS_BEFORE -> $LOCKS_AFTER)"
else
    bad "THUMB the app's wake locks changed ($LOCKS_BEFORE -> $LOCKS_AFTER)"
fi
STREAMS="$(emu logcat -d 2>/dev/null | grep -c 'PocketDeckSvc.*\(opened stream=\|display wake lock held\)' || true)"
if [ "$STREAMS" -eq 0 ]; then
    ok "THUMB no stream opened and no display wake lock taken during the asks"
else
    bad "THUMB $STREAMS stream/wake-lock lines appeared during the asks"
fi

emu shell rm -f "/sdcard/$FOLDER/$NAME.jpg" "/sdcard/$FOLDER/$NAME.heic" \
    "/sdcard/$FOLDER/$NAME.mp4" >/dev/null 2>&1 || true
# Leave the rig awake for whatever runs next.
"$EMU_DIR/unlock.sh" >/dev/null 2>&1 || true
printf 'THUMB %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
