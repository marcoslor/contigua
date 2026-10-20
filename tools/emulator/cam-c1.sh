#!/usr/bin/env bash
# C1: the phone capture service on the emulator rig — ONE boot.
#
#   tools/emulator/cam-c1.sh [--check]
#
# Boots the rig (start.sh --no-build: run K1 first), turns on "Let Macs use the
# camera" the way the toggle does (the pref write plus `pm grant`; production
# code never grants the permission), sends the app HOME so the Mac asks a
# backgrounded app, then drives the real phone server through deckctl:
#
#   1. cam.list, cam.start -> 5 s of frames (fps, keyframe interval, the first
#      keyframe's SPS/PPS), and ONE decoded frame as evidence (never committed)
#   2. a capture that spans locking the phone: frames keep coming (C0b's P2)
#   3. the camera app opens mid-capture: evicted, no frames after, never retried
#   4. after closing the camera app: a new capture streams, cam.stop answers
#      stopped and the service is gone from dumpsys
#   5. the setting off: cam.start answers off
#
# Everything goes to .agent/emu/cam-c1.log; the one PNG to .agent/camera-c1/
# (ids, sizes, fps, counts and error codes otherwise). The emulator is killed on
# every exit path, including failure. --check validates the rig without
# touching a device (dry run).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown flag $arg" ;;
  esac
done

PKG="dev.pocketdeck"
SERVICE="$PKG/.app.CameraCaptureService"
DECKCTL="$REPO_ROOT/tools/fakephone/deckctl.py"
POC="$EMU_DIR/poc.py"
STATE="$CACHE_DIR/deckctl-state.json"
APK="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
MANIFEST="$REPO_ROOT/android/app/src/main/AndroidManifest.xml"
LOG="$AGENT_DIR/cam-c1.log"
EVIDENCE="$REPO_ROOT/.agent/camera-c1"
H264="$CACHE_DIR/cam-c1-live.h264"
LOCKED_H264="$CACHE_DIR/cam-c1-locked.h264"
CAMERA_APP="com.android.camera2"

check_only() {
  step "checking the rig (no device calls)"
  [ -x "$EMULATOR" ] || die "emulator missing: $EMULATOR"
  [ -d "$HOME/.android/avd/$AVD_NAME.avd" ] || die "AVD $AVD_NAME missing"
  [ -f "$APK" ] || die "no debug APK at $APK (run K1 first)"
  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"
  grep -q 'android.permission.CAMERA' "$MANIFEST" || die "manifest has no CAMERA"
  grep -q 'android.permission.FOREGROUND_SERVICE_CAMERA' "$MANIFEST" ||
    die "manifest has no FOREGROUND_SERVICE_CAMERA"
  grep -q 'android:name=".app.CameraCaptureService"' "$MANIFEST" || die "manifest has no camera service"
  grep -A5 'android:name=".app.CameraCaptureService"' "$MANIFEST" | grep -q 'foregroundServiceType="camera"' ||
    die "the camera service is not a camera FGS"
  grep -A5 'android:name=".app.CameraCaptureService"' "$MANIFEST" | grep -q 'android.permission.DUMP' ||
    die "the camera service is not protected for the shell UID"
  grep -q 'KEY_CAMERA_ALLOWED = "camera_allowed"' \
    "$REPO_ROOT/android/app/src/main/java/dev/pocketdeck/app/Prefs.kt" ||
    die "the pref write below does not match Prefs"
  bash -n "$0" || die "syntax error in $0"
  [ -x "$DECKCTL" ] || [ -f "$DECKCTL" ] || die "deckctl missing: $DECKCTL"
  [ -f "$POC" ] || die "poc.py missing: $POC"
  "$PYTHON" -c 'import ssl; c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.minimum_version = ssl.TLSVersion.TLSv1_3' ||
    die "python has no TLS 1.3: $PYTHON"
  python3 -c 'import sys' || die "python3 missing (the pref write)"
  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg missing (one decoded frame)"
  command -v ffprobe >/dev/null 2>&1 || die "ffprobe missing"
  [ -x "$EMU_DIR/lock.sh" ] || die "lock.sh missing"
  [ -x "$EMU_DIR/unlock.sh" ] || die "unlock.sh missing"
  [ -x "$EMU_DIR/start.sh" ] || die "start.sh missing"
  "$PYTHON" "$DECKCTL" cam --help >/dev/null 2>&1 || die "deckctl has no cam command"
  step "python: $PYTHON"
  step "ok"
}

if [ "$CHECK" -eq 1 ]; then
  check_only
  exit 0
fi

mkdir -p "$AGENT_DIR" "$EVIDENCE" "$CACHE_DIR"
: > "$LOG"
step "log: $LOG"
step "evidence: $EVIDENCE (the one PNG, never committed)"

FAILED=0
RESULTS=()
fail() { FAILED=1; step "FAIL: $*"; }

# deckctl against the rig: the forward is 127.0.0.1:$PORT -> the phone's server.
deckctl() { "$PYTHON" "$DECKCTL" --host 127.0.0.1 --port "$PORT" --state "$STATE" "$@"; }
DECK_PID=""

# --- the toggle's pref write -------------------------------------------------
# The app is debuggable, so run-as reaches its prefs. The app is stopped first:
# a live SharedPreferences instance would rewrite the file from its in-memory
# map and drop the key.
set_camera_setting() { # set_camera_setting true|false
  local want="$1" old="$CACHE_DIR/camera_prefs.old.xml" new="$CACHE_DIR/camera_prefs.xml"
  emu shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 1
  emu shell "run-as $PKG cat shared_prefs/pocketdeck.xml" >"$old" 2>/dev/null || true
  python3 - "$new" "$old" "$want" <<'PY'
import sys

out_path, old_path, want = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(old_path) as fp:
        lines = fp.read().splitlines()
except OSError:
    lines = []
if not any("<map" in line for line in lines):
    lines = ["<?xml version='1.0' encoding='utf-8' standalone='yes' ?>", "<map>", "</map>"]
lines = [line for line in lines if "camera_allowed" not in line]
out = []
done = False
for line in reversed(lines):
    out.append(line)
    if not done and "</map>" in line:
        out.append('    <boolean name="camera_allowed" value="%s" />' % want)
        done = True
out.reverse()
text = "\n".join(out) + "\n"
# The key must be INSIDE <map>; a straggler line after </map> is silently
# invisible to SharedPreferences, which is how C1's first boot was lost.
start, end = text.find("<map"), text.rfind("</map>")
key = text.find('name="camera_allowed"')
if not done or start < 0 or end < 0 or not (start < key < end):
    raise SystemExit("camera_allowed did not land inside <map>")
with open(out_path, "w") as fp:
    fp.write(text)
PY
  emu shell "run-as $PKG mkdir -p shared_prefs" >/dev/null 2>&1 || true
  emu shell "run-as $PKG sh -c 'cat > shared_prefs/pocketdeck.xml'" <"$new" ||
    die "cannot write the camera pref (is the build debuggable?)"
  local seen
  seen="$(emu shell "run-as $PKG cat shared_prefs/pocketdeck.xml" 2>/dev/null | grep -o "camera_allowed\" value=\"$want\"" || true)"
  step "pref camera_allowed=$want: ${seen:-MISSING}"
  [ -n "$seen" ] || fail "the camera pref did not stick"
  # The deck service re-reads the prefs and pushes the gate on bind.
  for _ in $(seq 1 10); do
    emu shell am start -n "$PKG/.app.MainActivity" >/dev/null 2>&1 || true
    sleep 3
    [ -n "$(emu shell "pidof $PKG" 2>/dev/null | tr -d '\r')" ] && break
  done
  [ -n "$(emu shell "pidof $PKG" 2>/dev/null | tr -d '\r')" ] || die "could not launch $PKG"
  local _dev="" _
  for _ in $(seq 1 60); do
    _dev="$(ensure_forward || true)"
    [ -n "$_dev" ] && break
    sleep 1
  done
  [ -n "$_dev" ] || die "the server did not come back after the pref write"
  step "forward: 127.0.0.1:$PORT -> device tcp:$_dev"
  sleep 2
}

# A cam.state line out of a deckctl run, last one only.
last_state() { grep -o 'cam.state stream=[0-9]* state=[a-z]*' "$1" 2>/dev/null | tail -1 || true; }
stats_field() { # stats_field <deckctl output> <field>
  awk -v key="$2=" '/^cam.stats /{ for (i = 1; i <= NF; i++) if (index($i, key) == 1) v = substr($i, length(key) + 1) } END { if (v != "") print v }' "$1" 2>/dev/null
}

cleanup() {
  [ -n "$DECK_PID" ] && kill "$DECK_PID" >/dev/null 2>&1 || true
  step "killing $SERIAL"
  emu shell am stop-service -n "$SERVICE" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if ! device_present; then break; fi
    sleep 1
  done
  step "emulator stopped"
}
trap cleanup EXIT

step "booting (the APK must already be built and current)"
"$EMU_DIR/start.sh" --no-build

step "granting CAMERA (the app process needs it; the rig grants runtime perms)"
emu shell pm grant "$PKG" android.permission.CAMERA >/dev/null 2>&1 || true
emu shell dumpsys package "$PKG" 2>/dev/null |
  sed -n '/runtime permissions:/,/^$/p' | grep -E 'CAMERA|POST_NOTIFICATIONS' >> "$LOG" || true

step "turning on 'Let Macs use the camera' (the toggle's pref write + the grant)"
set_camera_setting true

step "pairing (poc.py reads the prompt; deckctl keeps the pin)"
"$EMU_DIR/unlock.sh" >>"$LOG" 2>&1 || true
PAIRED=0
for _ in $(seq 1 6); do
  rc=0
  "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    PAIRED=1
    break
  fi
  if [ "$rc" -eq 3 ]; then
    step "phone busy with another session, waiting"
    sleep 5
    continue
  fi
  emu shell am start -n "$PKG/.app.MainActivity" >/dev/null 2>&1 || true
  sleep 3
  "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" \
    --adb "$ADB" pair >>"$LOG" 2>&1 || sleep 3
done
if [ "$PAIRED" -eq 0 ]; then
  rc=0
  "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && PAIRED=1
fi
[ "$PAIRED" -eq 1 ] || fail "could not pair deckctl with the rig"

step "checking the app sees the setting (cam.list must not be empty)"
GATE_OK=0
for _ in $(seq 1 10); do
  deckctl cam list >"$CACHE_DIR/cam-c1-gate.txt" 2>&1 || true
  if grep -q 'cam.cams count=[1-9]' "$CACHE_DIR/cam-c1-gate.txt"; then
    GATE_OK=1
    break
  fi
  sleep 2
done
cat "$CACHE_DIR/cam-c1-gate.txt" >>"$LOG"
if [ "$GATE_OK" -eq 0 ]; then
  # Evidence for the next fix, ids/states only: a cam.start says whether the
  # shell holds the gate closed ("off") or open with no cameras; the camera
  # lines of logcat say whether the app pushed the gate and what it found.
  {
    echo "--- gate diagnosis"
    deckctl cam start --stream 7 --seconds 2 2>&1 | grep -E '^cam\.(state|terminal)' | head -3
    emu shell "dumpsys package $PKG" 2>/dev/null | grep -E 'android.permission.CAMERA:' | head -2
    emu shell "ps -A -o USER,PID,NAME" 2>/dev/null | grep -E 'pocketdeck' | awk '{print $1, $3}'
    emu shell "logcat -d -v brief" 2>/dev/null | grep -iE 'camera gate|gate push|cam\.start|camera service|consent|PocketDeckApp.*cam' | tail -20
  } >>"$LOG" 2>&1
  die "the app does not see 'Let Macs use the camera' (cam.list empty); not burning the boot on the rest"
fi
step "gate open: $(sed -n 's/cam.cams count=//p' "$CACHE_DIR/cam-c1-gate.txt" | tail -1) cameras"

step "sending the app HOME: the Mac asks a backgrounded app"
emu shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
sleep 2
emu logcat -c >/dev/null 2>&1 || true

step "cam.start stream=7, 5 s"
deckctl cam start --stream 7 --seconds 5 --busy-stream 8 --save-h264 "$H264" \
  >"$CACHE_DIR/cam-c1-start.txt" 2>"$CACHE_DIR/cam-c1-start.err"
START_RC=$?
{
  printf -- '--- cam start (stream 7, 5 s)\n'
  cat "$CACHE_DIR/cam-c1-start.txt" 2>/dev/null || true
  cat "$CACHE_DIR/cam-c1-start.err" 2>/dev/null || true
} >>"$LOG"
if [ "$START_RC" -ne 0 ]; then
  fail "cam.start: $(tail -2 "$CACHE_DIR/cam-c1-start.err" 2>/dev/null | tr '\n' ' ')"
else
  FRAMES="$(stats_field "$CACHE_DIR/cam-c1-start.txt" frames)"
  KEYS="$(stats_field "$CACHE_DIR/cam-c1-start.txt" keys)"
  FPS="$(stats_field "$CACHE_DIR/cam-c1-start.txt" fps)"
  GAP="$(stats_field "$CACHE_DIR/cam-c1-start.txt" key_gap_ms)"
  FIRST="$(stats_field "$CACHE_DIR/cam-c1-start.txt" first_key)"
  SPS="$(stats_field "$CACHE_DIR/cam-c1-start.txt" sps_pps)"
  step "frames=$FRAMES keys=$KEYS fps=$FPS key_gap_ms=$GAP first_key=$FIRST sps_pps=$SPS"
  RESULTS+=("stream=7 frames=$FRAMES keys=$KEYS fps=$FPS key_gap_ms=$GAP first_key=$FIRST sps_pps=$SPS")
  # The emulator's synthetic camera delivers ~6-8 fps (C0b), so 5 s is ~30 frames.
  [ "${FRAMES:-0}" -ge 20 ] || fail "only $FRAMES frames in 5 s"
  [ "$FIRST" = "True" ] || fail "the first frame is not a keyframe"
  [ "$SPS" = "True" ] || fail "the first keyframe carries no SPS/PPS"
  [ "${KEYS:-0}" -ge 2 ] || fail "only $KEYS keyframes in 5 s (interval must be <= 2 s)"
  grep -q 'cam.busy stream=8 state=busy' "$CACHE_DIR/cam-c1-start.txt" ||
    fail "a second cam.start was not busy"
  grep -q 'state=stopped' "$CACHE_DIR/cam-c1-start.txt" || fail "cam.stop did not answer stopped"
  # ONE decoded frame as evidence: the first keyframe of the capture.
  if ffmpeg -hide_banner -loglevel error -y -i "$H264" -frames:v 1 -f image2 "$EVIDENCE/c1-frame.png" 2>>"$LOG"; then
    SIZE="$(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$EVIDENCE/c1-frame.png" 2>/dev/null | head -1)"
    step "frame: $EVIDENCE/c1-frame.png ${SIZE}"
    RESULTS+=("frame ${SIZE:-unknown}")
  else
    fail "could not decode the one evidence frame"
  fi
  ffprobe -v error -show_entries stream=codec_name,width,height -of csv=p=0 "$H264" >>"$LOG" 2>&1 || true
fi

step "cam.list on the real server"
DECK_LIST="$CACHE_DIR/cam-c1-list.txt"
deckctl cam list >"$DECK_LIST" 2>&1 || true
cat "$DECK_LIST" >>"$LOG"
grep -q 'cam.cams count=' "$DECK_LIST" || fail "cam.list answered nothing"
RESULTS+=("cams=$(sed -n 's/cam.cams count=//p' "$DECK_LIST" | tail -1)")

# --- 2. a capture that spans the lock --------------------------------------
step "capture spanning the lock: start, lock 5 s in, read what happened"
deckctl cam start --stream 8 --seconds 9 --wait 20 --save-h264 "$LOCKED_H264" \
  >"$CACHE_DIR/cam-c1-locked.txt" 2>"$CACHE_DIR/cam-c1-locked.err" &
DECK_PID=$!
sleep 5
LOCK_RC=0
"$EMU_DIR/lock.sh" >>"$LOG" 2>&1 || LOCK_RC=$?
step "lock.sh exit=$LOCK_RC"
[ "$LOCK_RC" -eq 0 ] || fail "could not lock the emulator"
emu shell dumpsys window 2>/dev/null | grep -iE 'isKeyguardShowing|mKeyguardShowing' | head -2 >>"$LOG" || true
wait "$DECK_PID" || true
DECK_PID=""
cat "$CACHE_DIR/cam-c1-locked.txt" >>"$LOG" 2>/dev/null || true
L_FRAMES="$(stats_field "$CACHE_DIR/cam-c1-locked.txt" frames)"
L_KEYS="$(stats_field "$CACHE_DIR/cam-c1-locked.txt" keys)"
L_FPS="$(stats_field "$CACHE_DIR/cam-c1-locked.txt" fps)"
step "locked: frames=$L_FRAMES keys=$L_KEYS fps=$L_FPS"
RESULTS+=("locked frames=$L_FRAMES keys=$L_KEYS fps=$L_FPS")
[ "${L_FRAMES:-0}" -ge 60 ] || fail "only $L_FRAMES frames across the lock (C0b expected ~30/s)"
[ "${L_KEYS:-0}" -ge 2 ] || fail "only $L_KEYS keyframes across the lock"
case "$(last_state "$CACHE_DIR/cam-c1-locked.txt")" in
  *stopped*) : ;;
  *) fail "the locked capture ended as $(last_state "$CACHE_DIR/cam-c1-locked.txt")" ;;
esac

# --- 3. the person's camera app wins --------------------------------------
step "eviction: starting a capture, then opening the camera app"
deckctl cam start --stream 9 --seconds 15 --wait 25 --await-terminal \
  >"$CACHE_DIR/cam-c1-evict.txt" 2>"$CACHE_DIR/cam-c1-evict.err" &
DECK_PID=$!
sleep 5
"$EMU_DIR/unlock.sh" >>"$LOG" 2>&1 || step "warn: unlock.sh failed"
CAM_ACTIVITY="$(emu_long shell cmd package resolve-activity --brief   -a android.media.action.STILL_IMAGE_CAMERA 2>/dev/null | grep '/' | tail -1 | tr -d '\r' || true)"
step "camera app: ${CAM_ACTIVITY:-none resolved}"
if [ -n "$CAM_ACTIVITY" ]; then
  emu shell am start -n "$CAM_ACTIVITY" >>"$LOG" 2>&1 || step "warn: could not start the camera app"
else
  emu shell am start -a android.media.action.STILL_IMAGE_CAMERA >>"$LOG" 2>&1 ||
    step "warn: no STILL_IMAGE_CAMERA handler"
fi
wait "$DECK_PID" || true
DECK_PID=""
cat "$CACHE_DIR/cam-c1-evict.txt" >>"$LOG" 2>/dev/null || true
if grep -q 'cam.state stream=9 state=evicted' "$CACHE_DIR/cam-c1-evict.txt"; then
  step "evicted (no retry)"
  RESULTS+=("evicted after $(stats_field "$CACHE_DIR/cam-c1-evict.txt" frames) frames")
  grep -q 'cam.after_terminal frames=0' "$CACHE_DIR/cam-c1-evict.txt" ||
    fail "frames kept coming after the eviction"
else
  fail "no evicted state: $(last_state "$CACHE_DIR/cam-c1-evict.txt")"
fi

# --- 4. capture again, stop, the service goes away ------------------------
step "closing the camera app, capturing again, cam.stop"
emu shell am force-stop "$CAMERA_APP" >/dev/null 2>&1 || true
sleep 2
emu shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
if deckctl cam start --stream 10 --seconds 4 --wait 15 \
    >"$CACHE_DIR/cam-c1-again.txt" 2>"$CACHE_DIR/cam-c1-again.err"; then
  cat "$CACHE_DIR/cam-c1-again.txt" >>"$LOG"
  A_FRAMES="$(stats_field "$CACHE_DIR/cam-c1-again.txt" frames)"
  step "after the camera app: frames=$A_FRAMES"
  RESULTS+=("restart frames=$A_FRAMES")
  [ "${A_FRAMES:-0}" -ge 12 ] || fail "the capture after the camera app got $A_FRAMES frames"
  grep -q 'state=streaming' "$CACHE_DIR/cam-c1-again.txt" || fail "no streaming after the camera app"
  grep -q 'state=stopped' "$CACHE_DIR/cam-c1-again.txt" || fail "cam.stop did not answer stopped"
else
  fail "the capture after the camera app failed: $(tail -1 "$CACHE_DIR/cam-c1-again.err" 2>/dev/null)"
fi
SERVICES=1
for _ in $(seq 1 10); do
  SERVICES="$(emu shell dumpsys activity services "$PKG" 2>/dev/null | grep -c 'CameraCaptureService' || true)"
  [ "${SERVICES:-0}" -eq 0 ] && break
  sleep 1
done
step "camera service records after stop: ${SERVICES:-0}"
RESULTS+=("service records after stop=${SERVICES:-0}")
[ "${SERVICES:-0}" -eq 0 ] || fail "the camera service is still in dumpsys after cam.stop"

# --- 5. the setting off ----------------------------------------------------
step "turning the setting off (the toggle's pref write)"
set_camera_setting false
emu shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
sleep 2
deckctl cam start --stream 11 --wait 8 >"$CACHE_DIR/cam-c1-off.txt" 2>"$CACHE_DIR/cam-c1-off.err" || true
cat "$CACHE_DIR/cam-c1-off.txt" >>"$LOG" 2>/dev/null || true
if grep -q 'state=off' "$CACHE_DIR/cam-c1-off.txt"; then
  step "the setting off: cam.start answered off"
  RESULTS+=("off refused")
else
  fail "the setting off did not answer off: $(last_state "$CACHE_DIR/cam-c1-off.txt")"
fi
deckctl cam list >"$CACHE_DIR/cam-c1-off-list.txt" 2>&1 || true
cat "$CACHE_DIR/cam-c1-off-list.txt" >>"$LOG"
RESULTS+=("off cams=$(sed -n 's/cam.cams count=//p' "$CACHE_DIR/cam-c1-off-list.txt" | tail -1)")

# --- logs ------------------------------------------------------------------
{
  printf -- '--- PdCamera logcat\n'
  emu logcat -d -s PdCamera:I 2>/dev/null | tail -200 || true
  printf -- '--- camera/activity framework lines\n'
  emu logcat -d 2>/dev/null | grep -E 'CameraService|ActivityManager.*dev\.pocketdeck|cam\.' | tail -200 || true
} >>"$LOG"

step "results:"
for line in ${RESULTS[@]+"${RESULTS[@]}"}; do
  printf '  %s\n' "$line"
done
if [ "$FAILED" -eq 0 ]; then
  step "PASS"
else
  step "FAIL (see $LOG)"
fi
exit "$FAILED"
