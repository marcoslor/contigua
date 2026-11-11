#!/usr/bin/env bash
# ISS-100 / PHONE-23: the person's 11-11 log had three Shizuku servers; the app's
# binder came from one that then died while another served other apps. The app
# sat in NoBinder until it was force-stopped, and a new app pid was what made the
# surviving server push a binder. This round reproduces that state and checks the
# recovery: the app's own process restarts once, the surviving server serves
# PocketDeck again, and nobody touches Shizuku.
#
#   bash tools/emulator/bootbind.sh [--runs N] [--wait S] [--check]
#
# Runs against an already booted rig (tools/emulator/start.sh) and boots
# nothing. Each round: a second server starts (the app keeps its own binder
# because a push while it pings is ignored), our server is killed, the orphan
# shell service is reaped, and the app must serve again with no tap.
set -euo pipefail

RUNS=1
WAIT_S=90
CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --runs) RUNS="${2:?--runs needs a count}"; shift ;;
    --wait) WAIT_S="${2:?--wait needs seconds}"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "[bootbind] error: unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

PKG=dev.pocketdeck
DUMP=/data/local/tmp/pd-bootbind.xml
PERMISSION_CARD='Allow PocketDeck to use Shizuku'
SHIZUKU_PKG=moe.shizuku.privileged.api

app_pid() { emu shell "pidof $PKG" 2>/dev/null | tr -d '\r' || true; }

shizuku_server_pids() {
  { emu shell "ps -A -o PID,NAME 2>/dev/null | grep -w shizuku_server" 2>/dev/null || true; } |
    awk '{print $1}' | tr -d '\r' | sort -n | tr '\n' ' '
}

ui_text() {
  emu shell uiautomator dump --compressed "$DUMP" >/dev/null 2>&1 || true
  emu shell cat "$DUMP" 2>/dev/null | tr -d '\r'
}

# The starter is the rig's entry point (start.sh §4): it finds the manager APK
# and forks app_process as the adb shell user. The starter also kills every
# running server first, so a second server is forked with its command line
# directly (that is all the starter does after the kill).
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

# start_second_server <apk> <lib dir> — the same app_process invocation the
# starter execs after its "kill old server" step. The adb shell is held open by
# this Mac for the round: a device-side `cmd &` dies with the shell that forked
# it (tried: setsid and nohup, both produced no process and no log).
SECOND_CLIENT=""
trap 'if [ -n "$SECOND_CLIENT" ]; then kill "$SECOND_CLIENT" 2>/dev/null || true; fi' EXIT
start_second_server() {
  local apk="$1" lib="$2"
  local cmd="CLASSPATH='$apk' /system/bin/app_process -Djava.class.path='$apk' -Dshizuku.library.path='$lib' /system/bin --nice-name=shizuku_server rikka.shizuku.server.ShizukuService"
  "$ADB" -s "$SERIAL" shell "$cmd" >>"$AGENT_DIR/bootbind-second.log" 2>&1 &
  SECOND_CLIENT=$!
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

dump_app_lines() {
  emu logcat -d -s PocketDeckApp:I 2>/dev/null | tail -15 | sed 's/^/    /' >&2 || true
}

STARTER="$(shizuku_starter)"
emu shell "test -x $STARTER" 2>/dev/null || die "Shizuku starter $STARTER is missing"
SHIZUKU_APK="$(emu shell pm path "$SHIZUKU_PKG" 2>/dev/null | sed -n 's/^package://p' | head -1 | tr -d '\r')"
[ -n "$SHIZUKU_APK" ] || die "cannot read the Shizuku manager's APK path"
# `dumpsys package`'s codePath is the install DIRECTORY (that is where the
# starter's lib lives); app_process needs the APK from `pm path`, as the
# starter itself gets it (popen("pm path moe.shizuku.privileged.api")).
SHIZUKU_LIB="$(dirname "$STARTER")"

for round in $(seq 1 "$RUNS"); do
  P0="$(app_pid)"
  OURS="$(shizuku_server_pids | awk '{print $1}')"
  [ -n "$P0" ] || die "round $round: the app is not running"
  [ -n "$OURS" ] || die "round $round: no Shizuku server is running"
  [ "$(printf '%s\n' $OURS | wc -l | tr -d ' ')" = 1 ] ||
    die "round $round: expected one Shizuku server, found '$OURS'"
  BEFORE_PORT="$(device_port || true)"
  [ -n "$BEFORE_PORT" ] || die "round $round: the shell service is not listening before the round"
  step "round $round: app pid $P0, our server $OURS, listening on $BEFORE_PORT"

  # --- a second server appears; the app keeps its own binder -----------------
  step "round $round: starting a second Shizuku server"
  SECOND=""
  start_second_server "$SHIZUKU_APK" "$SHIZUKU_LIB"
  for _ in $(seq 1 30); do
    NOW="$(shizuku_server_pids)"
    SECOND="$(printf '%s\n' $NOW | awk -v a="$OURS" '$1 != a {print $1}' | head -1)"
    if [ -n "$SECOND" ]; then break; fi
    sleep 1
  done
  if [ -z "$SECOND" ]; then
    echo "--- second server did not appear; ps:" >&2
    emu shell "ps -A -o PID,NAME 2>/dev/null | grep -i -E 'shizuku|app_process'" 2>&1 | tail -10 >&2 || true
    echo "--- its adb client log:" >&2
    tail -10 "$AGENT_DIR/bootbind-second.log" >&2 2>/dev/null || true
    echo "--- logcat:" >&2
    emu logcat -d 2>/dev/null | grep -iE 'shizuku|app_process|AndroidRuntime' | tail -15 >&2 || true
    die "round $round: the second server did not start"
  fi
  sleep 3
  pass "round $round: a second server runs ($SECOND) beside ours ($OURS)"

  # --- our server dies; the app's binder goes with it ------------------------
  emu logcat -c >/dev/null 2>&1 || true
  emu shell "kill -9 $OURS" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if [ -z "$(shizuku_server_pids | grep -w "$OURS" || true)" ]; then break; fi
    sleep 0.5
  done
  # On a real phone the user service cannot outlive its server; on the emulator
  # it can be orphaned, so reap it to start the round from the person's state.
  for pid in $(server_pids); do
    emu shell "kill -9 $pid" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 20); do
    if [ -z "$(server_pids | tr -d ' ')" ]; then break; fi
    sleep 0.5
  done
  ALIVE="$(shizuku_server_pids | tr -d ' ')"
  [ "$ALIVE" = "$SECOND" ] || fail "round $round: the surviving server changed ('$ALIVE' != '$SECOND')"
  sleep 2

  # --- the app must come back by itself -------------------------------------
  T0="$(date +%s)"
  DEADLINE=$((T0 + WAIT_S))
  NEW_PID=""
  PORT=""
  while [ "$(date +%s)" -le "$DEADLINE" ]; do
    NEW_PID="$(app_pid)"
    PORT="$(device_port || true)"
    if [ -n "$PORT" ] && [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$P0" ]; then break; fi
    sleep 1
  done
  ELAPSED=$(( $(date +%s) - T0 ))
  LINE="$(emu logcat -d -s PocketDeckSvc:I 2>/dev/null | grep -c 'listening on' || true)"
  RECORD="$(emu logcat -d 2>/dev/null | grep -c 'New service record dev.pocketdeck:pocketdeck' || true)"
  if [ -n "$PORT" ] && [ "$LINE" -ge 1 ] && [ "$NEW_PID" != "$P0" ]; then
    pass "round $round: the shell service serves again in ${ELAPSED}s with no tap (pid $NEW_PID, port $PORT)"
  else
    fail "round $round: no recovery within ${WAIT_S}s (app pid '${NEW_PID:-none}', was $P0, port '${PORT:-none}', PocketDeckSvc lines ${LINE:-0})"
    dump_app_lines
  fi
  if [ "${RECORD:-0}" -ge 1 ]; then
    pass "round $round: the surviving server spawned the shell service ($RECORD record line(s))"
  else
    fail "round $round: no 'New service record' line from the surviving server"
  fi
  if [ "$NEW_PID" != "$P0" ]; then
    pass "round $round: PocketDeck restarted its own process for a binder ($P0 -> $NEW_PID)"
  else
    fail "round $round: the app process never restarted, so a live server could not push (pid $P0)"
  fi

  # --- once, and not again: no loop and no new server -----------------------
  sleep 8
  if [ "$(app_pid)" = "$NEW_PID" ]; then
    pass "round $round: the restarted process is stable (pid $NEW_PID)"
  else
    fail "round $round: the app restarted again ('$(app_pid)' != '$NEW_PID')"
  fi
  if [ "$(shizuku_server_pids | tr -d ' ')" = "$SECOND" ]; then
    pass "round $round: Shizuku's surviving server was never signalled (pid $SECOND)"
  else
    fail "round $round: Shizuku's servers changed ('$(shizuku_server_pids)')"
  fi

  # --- nobody asked for the permission again -------------------------------
  DUMP_TEXT="$(ui_text)"
  if printf '%s' "$DUMP_TEXT" | grep -q "$PERMISSION_CARD"; then
    fail "round $round: the app shows '$PERMISSION_CARD' after the restart"
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
  echo "bootbind: PASS ($RUNS round(s))"
  exit 0
fi
echo "bootbind: FAIL ($FAILS check(s) over $RUNS round(s))"
exit 1
