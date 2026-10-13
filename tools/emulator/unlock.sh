#!/usr/bin/env bash
# Wake the emulator and get past its test PIN, so adb/run-as can reach app data
# and the app can draw on screen again. Pairs with lock.sh.
#
#   tools/emulator/unlock.sh [PIN]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PIN="${1:-${POCKETDECK_PIN:-1234}}"
case "$SERIAL" in
  emulator-*) ;;
  *) die "refusing to run: $SERIAL is not an emulator serial" ;;
esac

device_present || die "$SERIAL is not running (run start.sh first)"

keyguard_showing() {
  emu shell dumpsys window 2>/dev/null | grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true'
}

screen_awake() {
  emu shell dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'
}

ui_xml() {
  emu shell uiautomator dump --compressed /sdcard/pocketdeck-lock.xml >/dev/null 2>&1 || true
  emu shell cat /sdcard/pocketdeck-lock.xml 2>/dev/null
}

# The screen can be off while the keyguard reports "not showing" (the panel was
# turned off after an unlock), and nothing draws until it is awake again.
if ! screen_awake; then
  emu shell input keyevent KEYCODE_WAKEUP >/dev/null
  for _ in $(seq 1 10); do
    screen_awake && break
    sleep 1
  done
  screen_awake || die "the screen never came back on"
fi

if ! keyguard_showing; then
  step "awake and unlocked"
  exit 0
fi

# Swipe the keyguard up until the PIN bouncer is actually on screen: typing into
# a bouncer that has not drawn yet silently loses the digits.
pad_up() { ui_xml | grep -q 'com.android.systemui:id/pinEntry'; }
for _ in $(seq 1 6); do
  pad_up && break
  emu shell input swipe 540 2000 540 700 250 >/dev/null
  sleep 1
done
pad_up || die "the PIN bouncer never appeared"

emu shell input text "$PIN" >/dev/null
sleep 1
emu shell input keyevent KEYCODE_ENTER >/dev/null

for _ in $(seq 1 8); do
  if ! keyguard_showing; then
    step "unlocked"
    exit 0
  fi
  sleep 1
done
die "keyguard still up after entering the PIN"
