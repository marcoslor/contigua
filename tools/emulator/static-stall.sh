#!/usr/bin/env bash
# static-stall — one boot proves the still-screen heartbeat (PHONE-21).
#
# The field bug: a healthy but still app window showed "Not responding", because
# the phone's vendor encoder drops KEY_REPEAT_PREVIOUS_FRAME_AFTER on a static
# picture and the Mac's 1.5 s rule then fires. This rig simulates that vendor:
# with `debug.pocketdeck.ignore_repeat_frame=1` the server never sets the
# heartbeat, so a static Settings screen produces no output at all.
#
#   before  the unfixed APK + the property: the Mac says stall=1
#   after   this branch's APK: no stall for 30 s, ~30 idle keyframes
#   stall   `debug.pocketdeck.freeze_drain=1`: the drain stops taking output,
#           and the Mac still says stall=1 within 1.5-2.5 s of the last frame
#
# One boot. Both APKs and the Mac bundle are built before the boot; this script
# only installs, drives, judges and kills. Run it as
#
#   bash tools/emulator/static-stall.sh --check     # no device, no boot
#   ~/dev/pocketdeck/.agent/heavy.sh timeout 2400 bash tools/emulator/static-stall.sh
set -uo pipefail

WT="$(cd "$(dirname "$0")/../.." && pwd)"
E="$WT/.agent/static-stall"
PORT="${POCKETDECK_PORT:-47994}"
SERIAL="${POCKETDECK_SERIAL:-emulator-5554}"
export POCKETDECK_PORT="$PORT" POCKETDECK_SERIAL="$SERIAL"
export POCKETDECK_AGENT_DIR="$E"
. "$WT/tools/emulator/lib.sh"

PKG=dev.pocketdeck
PROFILE=staticstall
APP="$WT/macos/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck"
STATE="$E/chrome-state.txt"
BEFORE_APK="${PD_STATIC_STALL_BEFORE_APK:-$E/before-app-debug.apk}"
AFTER_APK="${PD_STATIC_STALL_AFTER_APK:-$E/after-app-debug.apk}"
BUILT_APK="$WT/android/app/build/outputs/apk/debug/app-debug.apk"
APP_PID=0
FAILS=0

say() { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
fail() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }
now() { "$PYTHON" -c 'import time; print("%.3f" % time.time())'; }

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

check() {
  say "check: no device, no boot"
  [ -s "$BEFORE_APK" ] || { say "missing before APK: $BEFORE_APK (PD_STATIC_STALL_BEFORE_APK)"; exit 1; }
  [ -s "$AFTER_APK" ] || { say "missing after APK: $AFTER_APK (PD_STATIC_STALL_AFTER_APK)"; exit 1; }
  bash -n "$0" || exit 1
  if [ "$(apk_version_code "$BEFORE_APK")" != "$(apk_version_code "$AFTER_APK")" ]; then
    say "note: the APKs carry different versionCodes"
  fi
  [ -x "$APP" ] || say "note: the Mac bundle is built at run time ($APP)"
  say "check: OK — before=$(basename "$BEFORE_APK") after=$(basename "$AFTER_APK")"
  exit 0
}

stop_app() {
  if [ "$APP_PID" != "0" ]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=0
  fi
}

cleanup() {
  stop_app
  # The e2e bundle registers its Share extension when it runs (RULES 5).
  pluginkit -r "$WT/macos/build/e2e/PocketDeck.app/Contents/PlugIns/Share.appex" >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$WT/macos/build/e2e/PocketDeck.app" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}

# --- the Mac app ------------------------------------------------------------

# launch_mac <tag> <args…>: the quiet e2e run (its own virtual display), pointed
# at the rig's forwarded port.
launch_mac() {
  local tag="$1"
  shift
  rm -f "$STATE"
  "$APP" --profile "$PROFILE" --background --connect "127.0.0.1:$PORT" \
    --debug-chrome-state "$STATE" --quit-after 300 "$@" \
    > "$E/app-$tag.log" 2>&1 &
  APP_PID=$!
  say "$tag: Mac app pid $APP_PID"
}

# wait_state <regex> <seconds>: the chrome-state file is rewritten on every
# change, so it is the window's own report of its picture.
wait_state() {
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -s "$STATE" ] && grep -qE "$1" "$STATE" && return 0
    sleep 0.1
  done
  return 1
}

# watch_state <regex> <seconds> <since>: prints the seconds from <since> to the
# moment the state first appeared.
watch_state() {
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$STATE" ] && grep -qE "$1" "$STATE"; then
      "$PYTHON" -c "import time; print('%.1f' % (time.time() - $3))"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# mac_log <pid> <regex>: the app's own os_log lines (subsystem dev.pocketdeck.mac).
mac_log() {
  log show --last 6m --info --style syslog \
    --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $1" 2>/dev/null |
    grep -E "$2" || true
}

pair_mac() {
  say "pairing the Mac profile '$PROFILE' (the phone's prompt: tap Allow)"
  "$PYTHON" "$WT/tools/emulator/poc.py" --serial "$SERIAL" --adb "$ADB" \
    --addr "127.0.0.1:$PORT" wait-prompt --timeout 90 --tap-timeout 90
}

idle_keyframes() {
  emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
    grep -o 'heartbeat: idle keyframes=[0-9]*' | grep -o '[0-9]*$' | tail -1
}

last_idle_line() { # "<phone epoch> <count>" of the newest idle keyframe
  emu logcat -d -v epoch -s PocketDeckSvc:I 2>/dev/null |
    grep 'heartbeat: idle keyframes=' | tail -1
}

# phone_offset <host epoch>: the phone's clock minus the host's, from a marker
# line the phone stamps itself (no cross-clock truncation).
phone_offset() {
  local host_at="$1"
  emu shell log -t PocketDeckSvc -p i "static-stall clock $host_at" >/dev/null 2>&1 || true
  "$PYTHON" - "$host_at" <<PY
import subprocess, sys
host = float(sys.argv[1])
out = subprocess.run(["$ADB", "-s", "$SERIAL", "logcat", "-d", "-v", "epoch",
                      "-s", "PocketDeckSvc:I"], capture_output=True, text=True).stdout
for line in reversed(out.splitlines()):
    if "static-stall clock" in line:
        print("%.3f" % (float(line.split()[0]) - host))
        break
else:
    print("0.000")
PY
}

# --- the phases -------------------------------------------------------------

phase_before() {
  say "=== BEFORE: the unfixed APK, the vendor's dropped heartbeat"
  emu shell setprop debug.pocketdeck.ignore_repeat_frame 1 >/dev/null 2>&1 || true
  [ "$(emu shell getprop debug.pocketdeck.ignore_repeat_frame | tr -d '\r')" = "1" ] ||
    { fail "the ignore-repeat property did not stick"; return; }
  emu logcat -c >/dev/null 2>&1 || true

  launch_mac before --open com.android.settings
  pair_mac || { fail "pairing the Mac app failed"; stop_app; return; }
  wait_state 'loading=0' 90 || { fail "the window never showed a frame"; stop_app; return; }
  local live at
  live="$(now)"
  at="$(watch_state 'stall=1' 40 "$live")" || { fail "the unfixed build never stalled"; stop_app; return; }
  say "BEFORE: stall=1 ${at}s after the first frame on a still, healthy screen"
  grep -o 'loading=[0-9]* .*stall=[01]' "$STATE" | tail -1
  mac_log "$APP_PID" 'stall=1' | tail -1
  emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-before.txt" 2>/dev/null || true
  stop_app
  say "BEFORE RESULT: PASS (the bug reproduced)"
}

phase_after() {
  say "=== AFTER: this branch's APK, the same still screen"
  if ! emu_long install -r -d -g "$AFTER_APK" > "$E/install-after.log" 2>&1; then
    fail "could not install the after APK (see $E/install-after.log)"; return
  fi
  # The Shizuku shell service survives a reinstall (10-28): kill it so the new
  # build's server answers, then prove it from logcat.
  emu shell pkill -f "$PKG:pocketdeck" >/dev/null 2>&1 || true
  restart_server || { fail "the after build's server did not come up"; return; }
  ensure_forward >/dev/null || { fail "no port forward after the restart"; return; }
  emu logcat -c >/dev/null 2>&1 || true
  [ "$(emu shell getprop debug.pocketdeck.ignore_repeat_frame | tr -d '\r')" = "1" ] ||
    { fail "the ignore-repeat property did not survive"; return; }

  launch_mac after --open com.android.settings
  wait_state 'loading=0' 90 || { fail "the after window never showed a frame"; stop_app; return; }
  sleep 3   # let the launch's own animation settle; then the screen is still
  local start elapsed frames requests
  start="$(now)"
  say "AFTER: watching 30 s for a stall on a still screen"
  while :; do
    elapsed="$("$PYTHON" -c "import time; print('%.1f' % (time.time() - $start))")"
    "$PYTHON" -c "import sys; sys.exit(0 if $elapsed >= 30 else 1)" && break
    if [ -s "$STATE" ] && grep -q 'stall=1' "$STATE"; then
      fail "the fixed build stalled at ${elapsed}s on a still screen"
      emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-after.txt" 2>/dev/null || true
      grep -E 'heartbeat|no repeat' "$E/logcat-after.txt" | tail -20 || true
      stop_app
      return
    fi
    sleep 0.25
  done
  frames="$(idle_keyframes)"
  say "AFTER: no stall for 30 s; idle keyframes=$frames (the phone's own count)"
  grep -q 'stall=0' "$STATE" || fail "the state file lost stall=0"
  case "$frames" in
    ''|*[!0-9]*) fail "no idle-keyframe count on the phone" ;;
    *) [ "$frames" -ge 25 ] && [ "$frames" -le 35 ] || fail "idle keyframes $frames is not about 30" ;;
  esac
  requests="$(emu logcat -d -s PocketDeckSvc:I 2>/dev/null | grep -c 'heartbeat: armed --tick--> requested')"
  say "AFTER: idle periods that asked for a frame=$requests"
  [ "$requests" -ge 1 ] || fail "no heartbeat request was logged"
  emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-after.txt" 2>/dev/null || true
  say "AFTER RESULT: done (the window stays open for the stall phase)"
}

phase_stall() {
  say "=== STALL: a frozen drain must still reach the Mac's rule"
  local offset
  offset="$(phone_offset "$(now)")"
  say "phone clock offset ${offset}s"
  emu shell setprop debug.pocketdeck.freeze_drain 1 >/dev/null 2>&1 || true
  [ "$(emu shell getprop debug.pocketdeck.freeze_drain | tr -d '\r')" = "1" ] ||
    { fail "the freeze property did not stick"; stop_app; return; }
  local frozen at last_phone last_count delta
  frozen="$(now)"
  at="$(watch_state 'stall=1' 20 "$frozen")" || { fail "a frozen drain never stalled"; stop_app; return; }
  read -r last_phone last_count <<< "$(last_idle_line)"
  [ -n "${last_phone:-}" ] || { fail "no idle keyframe to measure from"; stop_app; return; }
  delta="$("$PYTHON" -c "print('%.1f' % (($frozen + $at) - ($last_phone - $offset)))")"
  say "STALL: stall=1 ${at}s after the freeze, ${delta}s after the last keyframe (count=$last_count)"
  grep -q 'stall=1' "$STATE" || fail "the state file does not say stall=1"
  "$PYTHON" -c "import sys; sys.exit(0 if 1.5 <= $delta <= 2.5 else 1)" ||
    fail "the stall came ${delta}s after the last frame, outside 1.5-2.5 s"
  mac_log "$APP_PID" 'stall=1' | tail -1
  emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-stall.txt" 2>/dev/null || true
  stop_app
  say "STALL RESULT: done"
}

main() {
  case "${1:-}" in
    --check) check ;;
    -h|--help) usage ;;
    "") ;;
    *) say "unknown argument: $1"; usage ;;
  esac

  mkdir -p "$E"
  trap cleanup EXIT

  if [ ! -x "$APP" ]; then
    say "building the e2e Mac bundle"
    bash "$WT/macos/scripts/bundle.sh" "$WT/macos/build/e2e/PocketDeck.app" --variant e2e ||
      { say "the Mac bundle did not build"; exit 1; }
  fi

  # A clean profile: the first launch pairs (and must), the rest reuse the pins.
  defaults delete "dev.pocketdeck.mac.$PROFILE" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Application Support/PocketDeck-$PROFILE"

  say "staging the before APK as the boot's own APK"
  cp "$BEFORE_APK" "$BUILT_APK" || { say "cannot stage the before APK"; exit 1; }

  say "booting the rig (the one boot)"
  bash "$WT/tools/emulator/start.sh" --no-build || { say "the rig did not boot"; exit 1; }
  ensure_forward >/dev/null || { say "no port forward"; exit 1; }
  say "rig: Android $(emu shell getprop ro.build.version.release | tr -d '\r') api $(emu shell getprop ro.build.version.sdk | tr -d '\r'), forward $PORT"

  phase_before
  phase_after
  if [ "$FAILS" -eq 0 ]; then
    phase_stall
  else
    say "skipping the stall phase: the after phase failed"
  fi

  say "-------------------------------------------"
  if [ "$FAILS" -eq 0 ]; then
    say "RESULT: PASS (before stalled, after ran 30 s still with no stall, a frozen drain stalled)"
  else
    say "RESULT: FAIL ($FAILS)"
  fi
  exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
}

main "$@"
