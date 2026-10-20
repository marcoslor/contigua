#!/usr/bin/env bash
# C0: one emulator boot that answers the phone camera questions P1-P5.
#
#   tools/emulator/cam-probe.sh [--check]
#
# Boots the rig (start.sh, --no-build: run K1 first), then runs the probe's
# stages as separate app_process runs at uid 2000, one result line each:
#
#   list    cameras, facing, sizes, 720p, fps ranges
#   open    open + a configured capture session (P1)
#   locked  lock the phone (lock.sh), then open + capture (P2)
#   feed    camera -> H.264 1280x720@30 encoder, 5 s of counts (P3)
#   evict   capture, then start the camera app; which callback arrives (P5)
#
# P4's indicators are read while the evict stage captures. Every result line
# goes to .agent/emu/cam-probe.log; the dumpsys/screenshot evidence to
# .agent/camera-c01/ (never committed). The emulator is killed on every exit
# path, including failure.
#
# --check validates the rig without touching a device (dry run).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown flag $arg" ;;
  esac
done

PKG="dev.pocketdeck"
PROBE="dev.pocketdeck.server.CameraProbe"
READY="/data/local/tmp/pd-cam-ready"
APK="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
LOG="$AGENT_DIR/cam-probe.log"
EVIDENCE="$REPO_ROOT/.agent/camera-c01"

check_only() {
  step "checking the rig (no device calls)"
  [ -x "$EMULATOR" ] || die "emulator missing: $EMULATOR"
  [ -d "$HOME/.android/avd/$AVD_NAME.avd" ] || die "AVD $AVD_NAME missing"
  [ -f "$APK" ] || die "no debug APK at $APK (run K1 first)"
  command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg missing"
  bash -n "$0" || die "syntax error in $0"
  step "python: $PYTHON"
  step "stages: list open locked feed evict"
  step "ok"
}

if [ "$CHECK" -eq 1 ]; then
  check_only
  exit 0
fi

mkdir -p "$AGENT_DIR" "$EVIDENCE"
: > "$LOG"
step "log: $LOG"

# Runs one stage device-side at the shell UID. Its classpath is the installed
# debug APK, which is why start.sh installs before this script runs.
probe() {
  emu_long shell "CP=\$(pm path $PKG | cut -d: -f2); CLASSPATH=\$CP app_process /system/bin $PROBE $*"
}

FAILED=0

record() { # record <name> <exit-code> <output>
  local name="$1" rc="$2" out="$3" lines
  printf '%s\n' "$out" | tee -a "$LOG"
  lines="$(printf '%s\n' "$out" | grep -c '^cam: result ' || true)"
  if [ "$lines" != "1" ]; then
    step "warn: stage $name printed $lines result lines"
  fi
  if [ "$rc" -ne 0 ]; then
    step "stage $name FAILED (exit $rc)"
    FAILED=1
  else
    step "stage $name ok"
  fi
}

run_stage() { # run_stage <stage> [args...]
  local name="$1"
  shift
  local out rc=0
  step "stage $name $*"
  out="$(probe "$name" "$@" 2>&1)" || rc=$?
  record "$name" "$rc" "$out"
}

start_camera_app() {
  local activity
  activity="$(emu_long shell cmd package resolve-activity --brief -a android.media.action.STILL_IMAGE_CAMERA 2>/dev/null |
    grep '/' | tail -1 | tr -d '\r')"
  step "camera app: ${activity:-none resolved}"
  if [ -n "$activity" ]; then
    emu shell am start -n "$activity" >/dev/null 2>&1 || step "warn: am start $activity failed"
  else
    emu shell am start -a android.media.action.STILL_IMAGE_CAMERA >/dev/null 2>&1 ||
      step "warn: no STILL_IMAGE_CAMERA handler"
  fi
}

dump_p4() {
  step "P4: dumpsys sensor_privacy, media.camera, status bar"
  emu_long shell dumpsys sensor_privacy > "$EVIDENCE/p4-sensor-privacy.txt" 2>&1 || true
  emu_long shell dumpsys media.camera > "$EVIDENCE/p4-media-camera.txt" 2>&1 || true
  emu shell screencap -p /data/local/tmp/pd-cam-status.png >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" pull /data/local/tmp/pd-cam-status.png "$EVIDENCE/p4-status-bar.png" >/dev/null 2>&1 || true
  emu shell rm -f /data/local/tmp/pd-cam-status.png >/dev/null 2>&1 || true
}

cleanup() {
  step "killing $SERIAL"
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

step "camera id list"
run_stage list

run_stage open

step "P2: locking the phone (rig PIN, screen off)"
"$EMU_DIR/lock.sh"
run_stage locked --seconds 5

step "P2: waking and unlocking for P3/P4"
"$EMU_DIR/unlock.sh"
run_stage feed --seconds 5

# P5 and P4 share one capture: start the stage in the background, wait for its
# ready marker, read the indicators while it holds the camera, then start the
# camera app and wait for the eviction callback.
EVICT_OUT="$AGENT_DIR/cam-evict.out"
EVICT_RC="$AGENT_DIR/cam-evict.rc"
rm -f "$EVICT_OUT" "$EVICT_RC" "$READY"
emu shell "rm -f $READY" >/dev/null 2>&1 || true
step "stage evict (background, waiting for $READY)"
(
  rc=0
  probe evict --seconds 25 --ready "$READY" > "$EVICT_OUT" 2>&1 || rc=$?
  echo "$rc" > "$EVICT_RC"
) &
EVICT_PID=$!

ready=0
for _ in $(seq 1 30); do
  if emu shell "test -f $READY" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
step "ready marker: $ready"

if [ "$ready" -eq 1 ]; then
  dump_p4
  start_camera_app
else
  step "warn: the evict stage never started capturing; starting the camera app anyway"
  start_camera_app
fi

wait "$EVICT_PID" || true
rc=99
[ -f "$EVICT_RC" ] && rc="$(cat "$EVICT_RC")"
out=""
[ -f "$EVICT_OUT" ] && out="$(cat "$EVICT_OUT")"
record evict "$rc" "$out"

step "results: $(grep -c '^cam: result ' "$LOG" || true) stage lines"
if [ "$FAILED" -eq 0 ]; then
  step "PASS"
else
  step "FAIL (see $LOG)"
fi
exit "$FAILED"
