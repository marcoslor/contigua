#!/usr/bin/env bash
# After an app update the deck must serve again with no tap (ISS-42,
# docs/specs/phone-app.md PHONE-7).
#
#   bash tools/emulator/update-race.sh [--apk PATH] [--runs N] [--check]
#
# Runs against an already booted rig (tools/emulator/start.sh) and boots
# nothing: the caller owns the emulator's whole life inside ONE heavy.sh call.
#
# Each round reproduces the person's 2026-11-04 order. Shizuku's server is
# stopped first, so the process has no binder; the APK is installed over itself
# with `adb install -r`, which kills the app (`killDueToPackageUpdate`) and
# sends `MY_PACKAGE_REPLACED`; the round waits for the app process the update
# starts and only then starts Shizuku's server again, 1 s later. The receiver
# therefore runs with no binder and the binder arrives just after it — the order
# that left the person's deck unlinked for six minutes. The pre-fix build
# returns at once and never starts the deck; the fix waits for the binder.
#
# The bound: 15 s from the server start until the shell service is listening
# and has the app's vouches (`app link: … --> linked`). That covers the 5 s
# receiver wait, a 5 s bind timeout and the server start. Nothing taps or
# launches the app: the install's own broadcast is the only trigger.
#
# Exits non-zero when any round failed. `--apk` names another build (the
# pre-fix baseline); the default is this checkout's debug APK.
set -euo pipefail

RUNS=3
BOUND_S=15
CHECK=0
APK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --runs) RUNS="${2:?--runs needs a count}"; shift ;;
    --apk) APK="${2:?--apk needs a path}"; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "[update-race] error: unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

PKG=dev.pocketdeck
SHIZUKU_PKG=moe.shizuku.privileged.api
APK="${APK:-$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"

# `pidof` exits 1 when the app is not running, and under `set -o pipefail`
# that made an assignment fail the whole script silently once. These helpers
# always answer, empty for "no".
app_pid() { emu shell "pidof $PKG" 2>/dev/null | tr -d '\r' | awk '{print $1}' || true; }

shizuku_server_pid() {
  emu shell "ps -A -o PID,NAME 2>/dev/null | grep -w shizuku_server" 2>/dev/null |
    awk '{print $1}' | tr -d '\r' | tr '\n' ' ' || true
}

# The starter is the rig's entry point (start.sh §4): it finds the manager APK
# and forks app_process as the adb shell user.
shizuku_starter() {
  local code_path abi
  code_path="$(emu shell dumpsys package "$SHIZUKU_PKG" 2>/dev/null |
    sed -n 's/.*codePath=\(.*\)$/\1/p' | head -1 | tr -d '\r')"
  abi="$(emu shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    arm64-v8a) abi=arm64 ;;
    armeabi-v7a) abi=arm ;;
  esac
  echo "$code_path/lib/$abi/libshizuku.so"
}

pref_enabled() {
  emu shell "run-as $PKG cat shared_prefs/pocketdeck.xml" 2>/dev/null |
    tr -d '\r' | grep -o 'name="enabled" value="[a-z]*"' | sed 's/.*value="//;s/"//' | head -1
}

linked_line() { emu logcat -d -s PocketDeckSvc:I 2>/dev/null | grep 'app link: .*--> linked' | tail -1 || true; }

if [ "$CHECK" = 1 ]; then
  PD_PREFLIGHT_DRY_RUN=1 bash "$EMU_DIR/preflight.sh" || die "preflight failed"
  [ -x "$EMULATOR" ] || die "emulator not installed"
  [ -f "$APK" ] || die "no APK at $APK; run K1 first"
  [ -n "$(apk_version_code "$APK")" ] || die "cannot read the APK's versionCode"
  case "$SERIAL" in emulator-*) ;; *) die "refusing serial $SERIAL (emulators only)" ;; esac
  [ -z "$(emu devices 2>/dev/null | awk -v s="$SERIAL" '$1 == s && $2 == "device"')" ] ||
    step "check: an emulator is already up on $SERIAL; start.sh would reuse it"
  step "check: rig and APK are present ($APK, versionCode $(apk_version_code "$APK"))"
  exit 0
fi

device_present || die "no emulator on $SERIAL"
[ "$(pref_enabled)" = true ] || die "keep running is off; the update would never start the deck"
STARTER="$(shizuku_starter)"
emu shell "test -x $STARTER" 2>/dev/null || die "Shizuku starter $STARTER is missing"

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

# The evidence a failed round leaves behind: bounded, the app's and the
# service's own lines (closed tokens only).
dump_lines() {
  emu logcat -d -s PocketDeckApp:I PocketDeckSvc:I 2>/dev/null | tail -20 | sed 's/^/    /' >&2 || true
}

step "APK: $APK (versionCode $(apk_version_code "$APK"))"
for round in $(seq 1 "$RUNS"); do
  # --- setup: the app serves before the round, as it did on the person's phone
  if [ -z "$(app_pid)" ] || [ -z "$(device_port || true)" ]; then
    step "round $round: setup: the app is not serving; starting it before the round"
    restart_server || die "round $round: could not restore the app before the round"
    sleep 2
  fi
  P0="$(app_pid)"
  [ -n "$P0" ] || die "round $round: the app is not running before the round"
  [ -n "$(shizuku_server_pid)" ] || die "round $round: Shizuku's server is not running before the round"
  [ -n "$(linked_line)" ] || die "round $round: the deck was not linked before the round"

  # --- no binder: the server dies, taking the shell service with it ---------
  emu shell "pkill -f shizuku_server" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    [ -z "$(shizuku_server_pid)" ] && break
    sleep 0.5
  done
  [ -z "$(shizuku_server_pid)" ] || die "round $round: shizuku_server survived pkill"
  for pid in $(server_pids); do
    emu shell "kill -9 $pid" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 20); do
    [ -z "$(server_pids | tr -d ' ')" ] && break
    sleep 0.5
  done
  [ -z "$(server_pids | tr -d ' ')" ] || die "round $round: the shell service survived kill -9"
  [ -z "$(device_port || true)" ] || die "round $round: something still listens after the kills"
  sleep 1
  emu logcat -c >/dev/null 2>&1 || true

  # --- the update: install over itself, with no binder in the process -------
  step "round $round: installing the APK over itself (no binder yet)"
  if ! INSTALL_OUT="$(emu_long install -r -d -g "$APK" 2>&1)"; then
    fail "round $round: adb install -r failed: $(printf '%s' "$INSTALL_OUT" | tail -1)"
    continue
  fi
  WANT_CODE="$(apk_version_code "$APK" || true)"
  GOT_CODE="$(installed_version_code "$PKG" || true)"
  [ -n "$WANT_CODE" ] && [ "$GOT_CODE" = "$WANT_CODE" ] ||
    die "round $round: installed versionCode '$GOT_CODE' but the APK is '$WANT_CODE'"

  # The update starts the app process for the broadcast. Waiting for it, then
  # the 1 s below, puts the binder after the receiver on every build: that is
  # the person's order (receiver 23:49:08, binder 23:49:09.74).
  NEW_PID=""
  for _ in $(seq 1 150); do
    pid="$(app_pid)"
    if [ -n "$pid" ] && [ "$pid" != "$P0" ]; then NEW_PID="$pid"; break; fi
    sleep 0.1
  done
  if [ -n "$NEW_PID" ]; then
    step "round $round: the update started the app again (pid $NEW_PID); starting the binder 1 s later"
    sleep 1
  else
    step "round $round: warn: no new app process after the install; starting the binder after 2 s"
    sleep 2
  fi

  # --- the binder arrives late ---------------------------------------------
  emu shell "$STARTER" >/dev/null 2>&1 || true
  SERVER_UP=0
  for _ in $(seq 1 30); do
    if [ -n "$(shizuku_server_pid)" ]; then SERVER_UP=1; break; fi
    sleep 1
  done
  [ "$SERVER_UP" = 1 ] || die "round $round: Shizuku's server did not start"
  S0="$(date +%s)"

  # --- the deck serves again, with no tap and no launch ---------------------
  PORT=""
  LINKED=""
  DEADLINE=$((S0 + BOUND_S))
  while [ "$(date +%s)" -le "$DEADLINE" ]; do
    PORT="$(device_port || true)"
    LINKED="$(linked_line)"
    [ -n "$PORT" ] && [ -n "$LINKED" ] && break
    sleep 0.5
  done
  ELAPSED=$(( $(date +%s) - S0 ))
  APP_START="$(emu logcat -d -s PocketDeckApp:I 2>/dev/null | grep 'app start:' | tail -2 | tr '\n' '|' || true)"

  if [ -n "$PORT" ] && [ -n "$LINKED" ]; then
    pass "round $round: linked and listening ${ELAPSED}s after the binder (port $PORT)"
    pass "round $round: $LINKED"
    [ -n "$APP_START" ] && step "round $round: receiver: $APP_START"
  else
    fail "round $round: not linked+listening within ${BOUND_S}s (port '${PORT}', linked '${LINKED:-none}')"
    dump_lines
    continue
  fi

  # --- nobody relaunched it: the process is the one the update started ------
  NOW_PID="$(app_pid)"
  if [ -n "$NEW_PID" ] && [ "$NOW_PID" = "$NEW_PID" ]; then
    pass "round $round: the app process is the update's own (pid $NEW_PID), not a relaunch"
  else
    fail "round $round: the app process is '${NOW_PID}' (the update started '${NEW_PID:-none}')"
  fi
done

echo
if [ "$FAILS" -eq 0 ]; then
  echo "update-race: PASS ($RUNS round(s))"
  exit 0
fi
echo "update-race: FAIL ($FAILS check(s) over $RUNS round(s))"
exit 1
