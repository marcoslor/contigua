#!/usr/bin/env bash
# Lock the emulator the way a phone sits in someone's pocket: a test PIN and the
# screen off. The PIN is only ever set on the emulator (the serial guard below
# refuses to touch anything else).
#
#   tools/emulator/lock.sh [PIN]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

PIN="${1:-${POCKETDECK_PIN:-1234}}"
case "$SERIAL" in
  emulator-*) ;;
  *) die "refusing to run: $SERIAL is not an emulator serial" ;;
esac

device_present || die "$SERIAL is not running (run start.sh first)"

# `locksettings get-disabled` is "true" while no credential is set, and the
# emulator refuses a second set-pin without --old, so only set it once.
if [ "$(emu shell locksettings get-disabled | tr -d '\r')" = "true" ]; then
  step "setting the rig PIN on $SERIAL"
  emu shell "locksettings set-pin $PIN" >/dev/null || die "could not set the rig PIN"
else
  step "rig PIN already set"
fi

emu shell input keyevent KEYCODE_SLEEP >/dev/null

for _ in $(seq 1 15); do
  if emu shell dumpsys window 2>/dev/null | grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true'; then
    step "locked: $(emu shell dumpsys window | grep -iE 'mDreamingLockscreen|isKeyguardShowing|mKeyguardShowing' | head -2 | tr -s ' ' | tr -d '\r' | tr '\n' ' ')"
    exit 0
  fi
  sleep 1
done
die "keyguard never reported as showing"
