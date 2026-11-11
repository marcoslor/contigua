#!/usr/bin/env bash
# After Shizuku's server comes back, the app must rebind its shell service by
# itself (docs/specs/phone-app.md PHONE-20).
#
#   bash tools/emulator/shizuku-restart.sh [--runs N] [--check]
#
# Runs against an already booted rig (tools/emulator/start.sh) and boots
# nothing: the caller owns the emulator's whole life inside ONE heavy.sh call.
#
# Each round is the person's 10-28 sequence: Shizuku's server dies (wireless
# debugging dropped), which takes the Contigua shell service with it, then the
# server is started again the way the rig starts it. Nothing touches the app:
# no tap, no relaunch. Within WAIT_S the shell service must be listening again
# and the app must not ask for the Shizuku permission again.
#
# The pre-fix build never rebinds: the server dies, the app is never told it is
# back, and no ContiguaSvc process ever appears. Exits non-zero when any
# round failed.
set -euo pipefail

RUNS=3
WAIT_S=10
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --runs) RUNS="${2:?--runs needs a count}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "[shizuku-restart] error: unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

PKG=app.contigua
SVC_PROCESS="app.contigua:contigua"
DUMP=/data/local/tmp/pd-shizuku.xml
# The app's card while it thinks the permission is missing, and the manager's
# own dialog package: either one means the app asked again (PHONE-20).
PERMISSION_CARD='Allow Contigua to use Shizuku'
SHIZUKU_PKG=moe.shizuku.privileged.api

app_pid() { emu shell "pidof $PKG" 2>/dev/null | tr -d '\r'; }

shizuku_server_pid() {
  emu shell "ps -A -o PID,NAME 2>/dev/null | grep -w shizuku_server" 2>/dev/null |
    awk '{print $1}' | tr -d '\r' | tr '\n' ' '
}

ui_text() {
  emu shell uiautomator dump --compressed "$DUMP" >/dev/null 2>&1 || true
  emu shell cat "$DUMP" 2>/dev/null | tr -d '\r'
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

if [ "$CHECK" = 1 ]; then
  [ -x "$EMULATOR" ] || die "emulator not installed"
  [ -f "$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk" ] ||
    die "no debug APK; run K1 first"
  case "$SERIAL" in emulator-*) ;; *) die "refusing serial $SERIAL (emulators only)" ;; esac
  [ -z "$(emu devices 2>/dev/null | awk -v s="$SERIAL" '$1 == s && $2 == "device"')" ] ||
    step "check: an emulator is already up on $SERIAL; start.sh would reuse it"
  step "check: rig and APK are present"
  exit 0
fi

device_present || die "no emulator on $SERIAL"
[ -n "$(app_pid)" ] || die "$PKG is not running; the round needs the app open as the person had it"

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

# The evidence a failed round leaves behind: the app's own lines, bounded.
dump_app_lines() {
  emu logcat -d -s ContiguaApp:I 2>/dev/null | tail -15 | sed 's/^/    /' >&2 || true
}

# --- round 0: the rig is where start.sh left it ------------------------------
STARTER="$(shizuku_starter)"
emu shell "test -x $STARTER" 2>/dev/null || die "Shizuku starter $STARTER is missing"
[ -n "$(shizuku_server_pid)" ] || die "Shizuku's server is not running; start.sh should have started it"
BASE_PIDS="$(server_pids | tr -d ' ')"
[ -n "$BASE_PIDS" ] || die "the shell service is not running before the first round"
BASE_PORT="$(device_port || true)"
[ -n "$BASE_PORT" ] || die "the shell service is not listening before the first round"
P0="$(app_pid)"
step "baseline: app pid $P0, shell service pid(s) $BASE_PIDS, listening on $BASE_PORT"

for round in $(seq 1 "$RUNS"); do
  # --- Shizuku's server dies, and the shell service goes with it ------------
  # On a real phone the user service is forked by the server and cannot outlive
  # it (the person's 13:38 capture: no ContiguaSvc line ever again). On the
  # emulator the daemon can be left orphaned, so it is reaped explicitly: the
  # round must start from the state the person's phone was in.
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
  # The port must be gone too: an orphan still listening would make a later
  # "listening again" a stale reading.
  [ -z "$(device_port || true)" ] || die "round $round: something still listens after the kills"

  # The app has to see the death before it can be expected to recover from it.
  sleep 3
  emu logcat -c >/dev/null 2>&1 || true

  # --- Shizuku's server comes back, started the way start.sh starts it ------
  step "round $round: starting the Shizuku server again"
  emu shell "$STARTER" >/dev/null 2>&1 || true
  STARTED=0
  for _ in $(seq 1 30); do
    if [ -n "$(shizuku_server_pid)" ]; then STARTED=1; break; fi
    sleep 1
  done
  [ "$STARTED" = 1 ] || die "round $round: Shizuku's server did not start"

  T0="$(date +%s)"
  DEADLINE=$((T0 + WAIT_S))
  SVC_PID=""
  PORT=""
  SVC_LINE=0
  while [ "$(date +%s)" -le "$DEADLINE" ]; do
    SVC_PID="$(server_pids | tr -d ' ')"
    PORT="$(device_port || true)"
    [ -n "$SVC_PID" ] && [ -n "$PORT" ] && { SVC_LINE=1; break; }
    sleep 0.5
  done
  ELAPSED=$(( $(date +%s) - T0 ))

  # The shell service's own first line ("listening on …") has to be this
  # round's: logcat was cleared just before the server restarted.
  LINE="$(emu logcat -d -s ContiguaSvc:I 2>/dev/null | grep -c 'listening on' || true)"
  if [ "$SVC_LINE" = 1 ] && [ "${LINE:-0}" -ge 1 ]; then
    pass "round $round: the shell service serves again in ${ELAPSED}s with no tap (pid $SVC_PID, port $PORT, $LINE ContiguaSvc line(s))"
  else
    fail "round $round: the shell service did not come back within ${WAIT_S}s (pid '${SVC_PID}', port '${PORT}', ContiguaSvc lines ${LINE:-0})"
    dump_app_lines
  fi

  # --- nobody touched the app ----------------------------------------------
  if [ "$(app_pid)" = "$P0" ]; then
    pass "round $round: the app process was never restarted (pid $P0)"
  else
    fail "round $round: the app process changed (was $P0, now '$(app_pid)')"
  fi

  # --- the app did not ask for Shizuku again -------------------------------
  DUMP_TEXT="$(ui_text)"
  if printf '%s' "$DUMP_TEXT" | grep -q "$PERMISSION_CARD"; then
    fail "round $round: the app shows '$PERMISSION_CARD' after the restart (a stale permission check)"
  elif printf '%s' "$DUMP_TEXT" | grep -q "package=\"$SHIZUKU_PKG\""; then
    fail "round $round: a Shizuku permission dialog is on screen"
  elif [ -z "$DUMP_TEXT" ]; then
    fail "round $round: the uiautomator dump was empty (cannot tell whether a prompt appeared)"
  else
    pass "round $round: no Shizuku permission prompt and no permission card"
  fi
done

echo
if [ "$FAILS" -eq 0 ]; then
  echo "shizuku-restart: PASS ($RUNS round(s))"
  exit 0
fi
echo "shizuku-restart: FAIL ($FAILS check(s) over $RUNS round(s))"
exit 1
