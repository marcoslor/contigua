#!/usr/bin/env bash
# Wake the emulator and get past its test PIN, so adb/run-as can reach app data
# and the app can draw on screen again. Pairs with lock.sh.
#
#   tools/emulator/unlock.sh [PIN]
#
# Two things about API 36's rig needed fixing (round 1 died here):
#   * while the phone is locked, /sdcard is not mounted yet (FBE), so a
#     uiautomator dump written there is empty. The dump goes to
#     /data/local/tmp, which the shell user always has.
#   * the bouncer is not reliably behind one swipe: `wm dismiss-keyguard`
#     raises it, and a MENU key event plus a swipe is the fallback. The PIN
#     is typed as key events, and if none of the known PIN views can be seen
#     in the dump the script still enters it once before giving up.
#   * one boot in three arrives with the screen dozing, where the dump shows no
#     PIN view at all: the whole sequence is retried once after a wake and a
#     `wm dismiss-keyguard` before the script dies.
# The last dump and the window state are kept in $AGENT_DIR on failure.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PIN="${1:-${CONTIGUA_PIN:-1234}}"
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

DUMP=/data/local/tmp/contigua-lock.xml
ui_xml() {
  emu shell uiautomator dump --compressed "$DUMP" >/dev/null 2>&1 || true
  emu shell cat "$DUMP" 2>/dev/null
}

save_evidence() {
  ui_xml > "$AGENT_DIR/unlock-dump.xml" 2>/dev/null || true
  emu shell dumpsys window 2>/dev/null > "$AGENT_DIR/unlock-window.txt" || true
  emu shell screencap -p "$DUMP.png" >/dev/null 2>&1 || true
  emu shell cat "$DUMP.png" > "$AGENT_DIR/unlock-screen.png" 2>/dev/null || true
  step "saved the bouncer dump and window state to $AGENT_DIR"
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

# API 36's bouncer: a KeyguardPINView with its own id; older images used
# pinEntry. Any of these means digits can be typed.
pin_pad_up() {
  local dump
  dump="$(ui_xml)"
  printf '%s' "$dump" | grep -qiE \
    'id/(pinEntry|bouncer_pin_entry|keyguard_pin_view|pin_keypad|lock_pin_entry)|KeyguardPINView|password="true"'
}

# Digits as key events: on a bouncer, `input text` can land in the wrong field.
enter_pin() {
  local i digit code
  for ((i = 0; i < ${#PIN}; i++)); do
    digit="${PIN:i:1}"
    case "$digit" in
      0) code=7 ;;
      1) code=8 ;; 2) code=9 ;; 3) code=10 ;; 4) code=11 ;; 5) code=12 ;;
      6) code=13 ;; 7) code=14 ;; 8) code=15 ;; 9) code=16 ;;
      *) die "the PIN must be digits only" ;;
    esac
    emu shell input keyevent "$code" >/dev/null 2>&1 || true
    sleep 0.15
  done
  emu shell input keyevent KEYCODE_ENTER >/dev/null 2>&1 || true
}

unlocked() {
  for _ in $(seq 1 10); do
    if ! keyguard_showing; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 1. Ask the system for the bouncer: with a secure keyguard this shows the PIN.
# 2. Swipe it up until the pad is on screen, then type the PIN.
# 3. No pad in the dump (the keyguard is not always visible to uiautomator):
#    one more swipe and a blind PIN, which is what the pad expects anyway.
# Returns 0 as soon as the keyguard is gone.
try_unlock() {
  # 1. Dismiss: with a secure keyguard this shows the bouncer.
  emu shell wm dismiss-keyguard >/dev/null 2>&1 || true
  sleep 2

  # 2. Swipe it up (and MENU, which wakes the bouncer on some builds) until the
  #    pad is on screen; typing into a pad that has not drawn yet loses digits.
  local tried_menu=0
  for _ in $(seq 1 8); do
    pin_pad_up && break
    if [ "$tried_menu" = 0 ]; then
      tried_menu=1
      emu shell input keyevent KEYCODE_MENU >/dev/null 2>&1 || true
      sleep 1
    fi
    emu shell input swipe 540 2000 540 700 250 >/dev/null
    sleep 1
  done

  if pin_pad_up; then
    enter_pin
    unlocked && return 0
  fi

  # 3. A bag of last resorts, then one more swipe and a blind PIN.
  emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  emu shell input swipe 540 2000 540 700 250 >/dev/null
  sleep 2
  enter_pin
  unlocked && return 0
  return 1
}

if try_unlock; then
  step "unlocked"
  exit 0
fi

# One boot in three arrives with a dozing screen: the dump shows only
# keyguard_carrier_text and no PIN view, and every swipe lands on a panel that
# is not drawing yet. Wake it, let it settle, dismiss again, and run the whole
# sequence once more before giving up (the boot is too expensive to lose here).
step "no PIN pad: waking the screen and running the sequence again"
emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
sleep 2
emu shell wm dismiss-keyguard >/dev/null 2>&1 || true

if try_unlock; then
  step "unlocked after the retry"
  exit 0
fi

save_evidence
die "the PIN bouncer did not accept the PIN (evidence in $AGENT_DIR)"
