#!/bin/bash
# Reinstall the debug APK and restart PocketDeck's root/Shizuku shell service.
#
#   ANDROID_ADB_SERVER_PORT=5038 tools/phone_install.sh <apk> [serial]
#
# `adb install -r` does not restart `:pocketdeck`: the old process keeps the
# deleted base.apk and the LAN listener, and the Mac times out on SYN while the
# phone looks healthy. This script installs, kills that exact process with su
# (KernelSU; falls back to stopping the app), launches MainActivity once, and
# asserts the new pid maps the current base.apk.
set -euo pipefail

APK=${1:?usage: phone_install.sh <apk> [serial]}
SERIAL=${2:-${ANDROID_SERIAL:-}}
ADB=${ADB:-adb}
DIR=$(cd "$(dirname "$0")" && pwd)

adb_cmd=("$ADB")
if [ -n "$SERIAL" ]; then adb_cmd+=(-s "$SERIAL"); fi

"${adb_cmd[@]}" install -r "$APK"

pid_of_service() {
  "${adb_cmd[@]}" shell pidof dev.pocketdeck:pocketdeck 2>/dev/null \
    | tr -d '\r' | awk '{print $1}'
}

PID="$(pid_of_service || true)"
if [ -n "$PID" ]; then
  echo "restarting the shell service (pid $PID)"
  if ! "${adb_cmd[@]}" shell "su -c 'kill $PID'" >/dev/null 2>&1; then
    echo "su kill failed; stopping the app instead"
    "${adb_cmd[@]}" shell am force-stop dev.pocketdeck >/dev/null 2>&1 || true
  fi
  sleep 1
fi

"${adb_cmd[@]}" shell am start -n dev.pocketdeck/.app.MainActivity >/dev/null

for _ in $(seq 1 20); do
  if [ -n "$(pid_of_service || true)" ]; then break; fi
  sleep 1
done

python3 "$DIR/phone_install_check.py" --adb "$ADB" ${SERIAL:+--serial "$SERIAL"}
