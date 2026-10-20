#!/usr/bin/env bash
# C0b: can the APP process start a camera-type foreground service and capture
# while PocketDeck is in the background, unlocked and with the phone locked?
#
#   tools/emulator/cam-fgs.sh [--check]
#
# Boots the rig (start.sh --no-build: run K1 first), grants CAMERA, sends the
# app HOME, then drives the probe (CamFgsProbe, debug builds only) once per
# stage:
#
#   *-a   adb shell am start-foreground-service (uid 2000: the same UID as the
#         shell user service, i.e. "a system component starts the service")
#   *-b   am broadcast -> CamFgsTrigger -> the app starts itself from the
#         background
#   *-b2  the same broadcast with --allow-background-activity-starts, which
#         only a caller holding START_ACTIVITIES_FROM_BACKGROUND (shell) can set
#   *-c   skipped: the shell -> app binding (IDeckCallback) has no camera method
#         and adding one is an AIDL change outside this probe
#
# Then the phone is locked (lock.sh, rig PIN, screen off) and the stages run
# again. If a stage captured, it is repeated for 25 s while dumpsys media.camera
# / sensor_privacy, one status-bar screenshot and the camera app answer P4/P5.
#
# Result lines plus the ActivityManager/ActiveServices lines that mention
# dev.pocketdeck go to .agent/emu/cam-fgs.log; the one decoded frame and the
# one status-bar screenshot go to .agent/camera-c0b/ (never committed). The
# emulator is killed on every exit path, including failure.
#
# --check validates the rig without touching a device (dry run).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "unknown flag $arg" ;;
  esac
done

PKG="dev.pocketdeck"
COMPONENT="$PKG/dev.pocketdeck.app.CamFgsProbe"
ACTION="dev.pocketdeck.DEBUG_CAM_FGS"
TAG="PdCamFgs"
APK="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
LOG="$AGENT_DIR/cam-fgs.log"
EVIDENCE="$REPO_ROOT/.agent/camera-c0b"
FRAME_CACHE="cache/cam-fgs-frame.jpg"
WAIT_S="${POCKETDECK_STAGE_WAIT:-40}"

check_only() {
  step "checking the rig (no device calls)"
  [ -x "$EMULATOR" ] || die "emulator missing: $EMULATOR"
  [ -d "$HOME/.android/avd/$AVD_NAME.avd" ] || die "AVD $AVD_NAME missing"
  [ -f "$APK" ] || die "no debug APK at $APK (run K1 first)"
  MANIFEST="$REPO_ROOT/android/app/src/debug/AndroidManifest.xml"
  [ -f "$MANIFEST" ] || die "no debug manifest at $MANIFEST"
  grep -q 'dev.pocketdeck.app.CamFgsProbe' "$MANIFEST" || die "debug manifest has no CamFgsProbe"
  grep -q 'dev.pocketdeck.app.CamFgsTrigger' "$MANIFEST" || die "debug manifest has no CamFgsTrigger"
  grep -q 'foregroundServiceType="camera"' "$MANIFEST" || die "the probe is not a camera FGS"
  grep -q 'android.permission.FOREGROUND_SERVICE_CAMERA' "$MANIFEST" || die "missing FOREGROUND_SERVICE_CAMERA"
  grep -q 'android.permission.CAMERA' "$MANIFEST" || die "missing CAMERA"
  bash -n "$0" || die "syntax error in $0"
  command -v "$PYTHON" >/dev/null 2>&1 || die "python missing: $PYTHON"
  step "python: $PYTHON"
  step "stages: bg-unlocked-a bg-unlocked-b bg-unlocked-b2 locked-a locked-b locked-b2 (+evict; c skipped)"
  step "ok"
}

if [ "$CHECK" -eq 1 ]; then
  check_only
  exit 0
fi

mkdir -p "$AGENT_DIR" "$EVIDENCE"
: > "$LOG"
step "log: $LOG"
step "evidence: $EVIDENCE (never committed)"

FAILED=0
FRAME_PULLED=0
FIRST_OK=""
RESULTS=()

# The probe's one result line for a stage, without the logcat prefix.
result_line() { # result_line <stage>
  emu logcat -d -s "$TAG":I 2>/dev/null |
    grep -F "$TAG: stage=$1 " | tail -1 | sed "s/.*$TAG: //" || true
}

wait_result() { # wait_result <stage> <timeout_s>
  local stage="$1" timeout="$2" waited=0 line=""
  while [ "$waited" -lt "$timeout" ]; do
    line="$(result_line "$stage" || true)"
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

start_stage() { # start_stage <stage> <mode> <seconds>
  local stage="$1" mode="$2" seconds="$3" out="" rc=0 cmd
  emu shell "run-as $PKG rm -f $FRAME_CACHE" >/dev/null 2>&1 || true
  emu shell am stop-service -n "$COMPONENT" >/dev/null 2>&1 || true
  sleep 1
  case "$mode" in
    a)
      cmd="am start-foreground-service -n $COMPONENT --es stage $stage --ei seconds $seconds --ez frame true"
      ;;
    b)
      cmd="am broadcast -a $ACTION -p $PKG --es stage $stage --ei seconds $seconds --ez frame true"
      ;;
    b2)
      cmd="am broadcast --allow-background-activity-starts -a $ACTION -p $PKG --es stage $stage --ei seconds $seconds --ez frame true"
      ;;
    *)
      die "unknown stage mode $mode"
      ;;
  esac
  step "start $stage ($mode): $cmd"
  out="$(emu_long shell "$cmd" 2>&1)" || rc=$?
  {
    printf -- '--- start %s mode=%s rc=%s\n' "$stage" "$mode" "$rc"
    printf '%s\n' "$out"
  } > "$AGENT_DIR/cam-fgs-am-$stage.txt"
  cat "$AGENT_DIR/cam-fgs-am-$stage.txt" >> "$LOG"
  if [ "$rc" -ne 0 ]; then
    step "warn: am exited $rc"
  fi
}

record_stage() { # record_stage <stage> <mode> <seconds>
  local stage="$1" mode="$2" seconds="$3" line="" frames="" reason=""
  step "stage $stage"
  start_stage "$stage" "$mode" "$seconds"
  if ! line="$(wait_result "$stage" "$WAIT_S")"; then
    # No probe line: the start itself may have been refused. The shell's
    # exception is the answer then; only a silent start counts as a failure.
    reason="$(grep -m1 -E '(java\.lang\.|android\.|java\.)[A-Za-z]+(Exception|Error):' \
      "$AGENT_DIR/cam-fgs-am-$stage.txt" 2>/dev/null | sed 's/^[[:space:]]*//' | cut -c1-240 || true)"
    if [ -n "$reason" ]; then
      line="stage=$stage ok=false started_fg=false opened=false frames=0 error=$(printf '%s' "$reason" | tr ' ' '_')"
      step "start refused: $reason"
    else
      line="stage=$stage ok=false started_fg=false opened=false frames=0 error=no_result_line"
      step "warn: $stage printed no result line (see the start output)"
      FAILED=1
    fi
  fi
  printf '[%s] %s\n' "$(basename "$0")" "$line" | tee -a "$LOG"
  RESULTS+=("$line")
  frames="$(printf '%s' "$line" | sed -n 's/.* frames=\([0-9][0-9]*\) .*/\1/p')"
  if [ -n "$frames" ] && [ "$frames" -gt 0 ] && [ -z "$FIRST_OK" ]; then
    FIRST_OK="$stage"
  fi
  if [ "$FRAME_PULLED" -eq 0 ] && [ -n "$frames" ] && [ "$frames" -gt 0 ]; then
    if "$ADB" -s "$SERIAL" exec-out run-as "$PKG" cat "$FRAME_CACHE" > "$EVIDENCE/c0b-frame.jpg" 2>/dev/null; then
      bytes="$(wc -c < "$EVIDENCE/c0b-frame.jpg" | tr -d ' ')"
      step "frame: $EVIDENCE/c0b-frame.jpg ($bytes bytes)"
      if [ "$bytes" -gt 0 ]; then
        FRAME_PULLED=1
      else
        rm -f "$EVIDENCE/c0b-frame.jpg"
        step "warn: the frame file is empty"
      fi
    else
      rm -f "$EVIDENCE/c0b-frame.jpg"
      step "warn: could not pull the frame"
    fi
  fi
}

dump_p4() { # dumpsys + one status-bar screenshot while the probe holds the camera
  local tmp=/data/local/tmp/pd-c0b-status.png
  step "P4: dumpsys media.camera, sensor_privacy, status bar"
  emu_long shell dumpsys media.camera > "$EVIDENCE/c0b-media-camera.txt" 2>&1 || true
  emu_long shell dumpsys sensor_privacy > "$EVIDENCE/c0b-sensor-privacy.txt" 2>&1 || true
  {
    printf -- '--- media.camera clients\n'
    grep -iE 'Client|package|uid|Device [0-9]' "$EVIDENCE/c0b-media-camera.txt" | head -40 || true
    printf -- '--- sensor_privacy\n'
    grep -iE 'camera|active|package|uid' "$EVIDENCE/c0b-sensor-privacy.txt" | head -40 || true
  } >> "$LOG"
  emu shell screencap -p "$tmp" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" pull "$tmp" "$EVIDENCE/c0b-status-bar.png" >/dev/null 2>&1 || true
  emu shell rm -f "$tmp" >/dev/null 2>&1 || true
  [ -s "$EVIDENCE/c0b-status-bar.png" ] && step "screenshot: $EVIDENCE/c0b-status-bar.png"
}

start_camera_app() {
  local activity
  activity="$(emu_long shell cmd package resolve-activity --brief -a android.media.action.STILL_IMAGE_CAMERA 2>/dev/null |
    grep '/' | tail -1 | tr -d '\r' || true)"
  step "camera app: ${activity:-none resolved}"
  if [ -n "$activity" ]; then
    emu shell am start -n "$activity" >/dev/null 2>&1 || step "warn: am start $activity failed"
  else
    emu shell am start -a android.media.action.STILL_IMAGE_CAMERA >/dev/null 2>&1 ||
      step "warn: no STILL_IMAGE_CAMERA handler"
  fi
}

evict_stage() { # evict_stage <capturing stage> <mode>
  local base="$1" mode="$2" stage="$1-evict" ready=0 i=0 line=""
  step "P4/P5: repeating $base as $stage (${mode}, 25 s)"
  start_stage "$stage" "$mode" 25
  while [ "$i" -lt 30 ]; do
    if emu logcat -d -s "$TAG":I 2>/dev/null | grep -qF "$TAG: capture=configured stage=$stage "; then
      ready=1
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  step "capture configured: $ready"
  if [ "$ready" -eq 1 ]; then
    dump_p4
  fi
  start_camera_app
  if line="$(wait_result "$stage" 45)"; then
    printf '[%s] %s\n' "$(basename "$0")" "$line" | tee -a "$LOG"
    RESULTS+=("$line")
  else
    step "warn: $stage printed no result line"
    FAILED=1
  fi
  {
    printf -- '--- P5 callback for %s\n' "$stage"
    emu logcat -d -s "$TAG":I 2>/dev/null | grep -F "$TAG: evict stage=$stage " | tail -2 || true
  } >> "$LOG"
}

background_state() {
  local uid=""
  uid="$(emu shell cmd package list packages -U "$PKG" 2>/dev/null |
    sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -1 | tr -d '\r' || true)"
  step "app uid: ${uid:-unknown}"
  {
    printf -- '--- uid state (the app must be in the background)\n'
    if [ -n "$uid" ]; then
      emu shell am get-uid-state "$uid" 2>&1 || true
    else
      printf 'uid: unknown\n'
    fi
    emu_long shell dumpsys activity processes 2>/dev/null |
      grep -A3 -E "ProcessRecord.*$PKG|uid $uid" | head -40 || true
    printf -- '--- deck service\n'
    emu shell dumpsys activity services "$PKG" 2>/dev/null |
      grep -E 'ServiceRecord|isForeground|foregroundServiceType' | head -20 || true
  } >> "$LOG"
}

collect_logs() {
  {
    printf -- '--- result lines and framework lines for %s\n' "$PKG"
    emu logcat -d 2>/dev/null |
      grep -E "$TAG|(ActivityManager|ActiveServices).*dev\.pocketdeck" | tail -800 || true
  } >> "$LOG"
}

cleanup() {
  step "killing $SERIAL"
  emu shell am stop-service -n "$COMPONENT" >/dev/null 2>&1 || true
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

step "sending the app home: the Mac asks while PocketDeck is in the background"
emu shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
sleep 2
background_state
emu logcat -c >/dev/null 2>&1 || true

step "background (unlocked) stages"
record_stage bg-unlocked-a a 5
record_stage bg-unlocked-b b 5
record_stage bg-unlocked-b2 b2 5
step "stage bg-unlocked-c skipped: the shell -> app binding has no camera method (docs/design/camera.md)"

if [ -n "$FIRST_OK" ]; then
  case "$FIRST_OK" in
    *-a) EVICT_MODE=a ;;
    *-b2) EVICT_MODE=b2 ;;
    *) EVICT_MODE=b ;;
  esac
  evict_stage "$FIRST_OK" "$EVICT_MODE"
else
  step "no unlocked stage captured; locking before the locked stages"
fi

step "P2: locking the phone (rig PIN, screen off)"
"$EMU_DIR/lock.sh"
emu shell dumpsys window 2>/dev/null | grep -iE 'isKeyguardShowing|mKeyguardShowing' | head -2 >> "$LOG" || true

step "locked stages"
record_stage locked-a a 5
record_stage locked-b b 5
record_stage locked-b2 b2 5
step "stage locked-c skipped: the shell -> app binding has no camera method (docs/design/camera.md)"

if [ -n "$FIRST_OK" ] && [ "$FIRST_OK" != "bg-unlocked-a" ] && [ "$FIRST_OK" != "bg-unlocked-b" ] && [ "$FIRST_OK" != "bg-unlocked-b2" ]; then
  case "$FIRST_OK" in
    *-a) EVICT_MODE=a ;;
    *-b2) EVICT_MODE=b2 ;;
    *) EVICT_MODE=b ;;
  esac
  evict_stage "$FIRST_OK" "$EVICT_MODE"
elif [ -z "$FIRST_OK" ]; then
  step "no stage captured: eviction and P4/P5 unverified"
fi

collect_logs

step "results:"
for line in ${RESULTS[@]+"${RESULTS[@]}"}; do
  printf '  %s\n' "$line"
done
if [ "$FAILED" -eq 0 ]; then
  step "PASS (every stage answered; a refusal is an answer)"
else
  step "FAIL (a stage printed no result line; see $LOG)"
fi
exit "$FAILED"
