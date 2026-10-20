#!/usr/bin/env bash
# `state.screen` and `phone.wake` on the emulator rig — ONE boot
# (docs/design/phone-mirror.md "Screen off and wake").
#
#   tools/emulator/phone-screen.sh            the run (heavy.sh owns the lock
#                                             and the boot budget)
#   tools/emulator/phone-screen.sh --check    a dry run: syntax, files, adb, the
#                                             serial, the parser — no device
#
# What it proves: after the rig boots and pairs, `input keyevent KEYCODE_SLEEP`
# makes the phone send `state.screen off`; `phone.wake` at shell UID brings
# display 0 back (`mWakefulness=Awake`, Display Power ON) and `state.screen on`
# arrives; the keyguard is still locked afterwards. It never unlocks or
# dismisses the keyguard and never changes lock settings. Results are states
# only, in .agent/emu/phone-screen.log.
set -u

MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  *) echo "phone-screen.sh: unknown flag $1" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47811}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/emu"
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
RESULT="$OUT/phone-screen.log"
WAKE="$OUT/phone-screen-wake.log"
POWER="$OUT/phone-screen-power.log"
WINDOW="$OUT/phone-screen-window.log"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$CACHE_DIR/deckctl-state.json")

FAILED=0
pass() { echo "PASS phone-screen: $*"; }
fail() { echo "FAIL phone-screen: $*"; FAILED=1; }

# ---- --check: everything that can be wrong before a boot -------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  [ -x "$ADB" ] || { echo "CHECK FAIL: no adb at $ADB"; exit 1; }
  [ -x "$EMULATOR" ] || { echo "CHECK FAIL: no emulator at $EMULATOR"; exit 1; }
  [ -f tools/emulator/start.sh ] && [ -x tools/emulator/start.sh ] || { echo "CHECK FAIL: start.sh"; exit 1; }
  [ -f tools/emulator/poc.py ] || { echo "CHECK FAIL: poc.py"; exit 1; }
  [ -f tools/fakephone/deckctl.py ] || { echo "CHECK FAIL: deckctl.py"; exit 1; }
  "$PYTHON" -c 'import ssl,sys; c=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.minimum_version = ssl.TLSVersion.TLSv1_3' \
    || { echo "CHECK FAIL: $PYTHON has no TLS 1.3"; exit 1; }
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
    echo "CHECK FAIL: $SERIAL is already running (not ours to touch)"
    exit 1
  fi
  APK="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
  [ -s "$APK" ] || { echo "CHECK FAIL: no debug APK at $APK (run K1 first)"; exit 1; }
  "$PYTHON" - <<'PY' || { echo "CHECK FAIL: deckctl screen parser"; exit 1; }
import sys
sys.path.insert(0, "tools/fakephone")
import deckctl
parser = deckctl.build_parser()
args = parser.parse_args(["wake-test", "--off-timeout", "10"])
assert args.command == "wake-test" and args.off_timeout == 10
args = parser.parse_args(["wake", "--wait", "5"])
assert args.command == "wake" and args.wait == 5
PY
  "$PYTHON" tools/fakephone/fakephone.py --help 2>&1 | grep -q -- "--screen-off-after" \
    || { echo "CHECK FAIL: fakephone has no --screen-off-after"; exit 1; }
  echo "CHECK OK: syntax, adb, emulator, rig scripts, TLS python, deckctl screen, fakephone flags; $SERIAL free"
  exit 0
fi

# ---- the run (ONE boot) ----------------------------------------------------
if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "phone-screen: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() {
  [ -n "${WAKE_PID:-}" ] && kill "$WAKE_PID" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}
trap 'kill_emulator' EXIT

echo "phone-screen: booting $SERIAL (one boot budget)"
if ! bash tools/emulator/start.sh --no-build; then
  # The rig's known flake: the Shizuku user service does not always come up on
  # the first launch after a boot (the app is installed and seeded by now). Its
  # own restart path re-runs the app and waits for the listening port; nothing
  # about the lock settings changes.
  echo "phone-screen: start.sh failed; restarting the shell service"
  if ! restart_server; then
    echo "phone-screen: the shell service never came up (unverified)"
    echo "failed: 1 (start)" > "$RESULT"
    exit 1
  fi
fi
echo "phone-screen: up"
ensure_forward >/dev/null || { echo "phone-screen: no server port"; echo "failed: 1 (port)" > "$RESULT"; exit 1; }

# --- pair (the real v2 flow) ----------------------------------------------
if ! "$PYTHON" tools/emulator/poc.py --state "$CACHE_DIR/deckctl-state.json" \
      --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair; then
  echo "phone-screen: pairing failed (unverified)"
  exit 1
fi
echo "phone-screen: paired"

# --- screen off, wake, screen on, on one session ---------------------------
"${DC[@]}" wake-test --off-timeout 60 --on-timeout 25 > "$WAKE" 2>&1 &
WAKE_PID=$!
sleep 4
# The panel times out the way a person's does (power key). Nothing else is
# changed on the device: no lock setting, no timeout, no unlock.
emu shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1 || true
wait "$WAKE_PID"
WAKE_RC=$?

grep -q '^state screen=off' "$WAKE" \
  && pass "the phone sent state.screen off after KEYCODE_SLEEP" \
  || fail "no state.screen off ($(tail -2 "$WAKE" 2>/dev/null | tr '\n' ' '))"
grep -q '^sent phone.wake' "$WAKE" \
  && pass "phone.wake went to the phone" \
  || fail "phone.wake was not sent"
grep -q '^state screen=on' "$WAKE" \
  && pass "the phone sent state.screen on after the wake" \
  || fail "no state.screen on (rc=$WAKE_RC)"
grep -q 'screen=on locked=True' "$WAKE" \
  && pass "the keyguard is still locked after the wake" \
  || fail "state after the wake is not locked ($(grep '^state screen=on' "$WAKE" | tail -1))"

# --- the platform's own view ------------------------------------------------
emu shell dumpsys power > "$POWER" 2>/dev/null || true
grep -q 'mWakefulness=Awake' "$POWER" \
  && pass "dumpsys power: mWakefulness=Awake" \
  || fail "dumpsys power is not Awake ($(grep -m1 'mWakefulness' "$POWER"))"
grep -qE 'Display Power: state=ON' "$POWER" \
  && pass "dumpsys power: Display Power state=ON" \
  || fail "display 0 is not ON ($(grep -m1 'Display Power' "$POWER"))"

emu shell dumpsys window > "$WINDOW" 2>/dev/null || true
if grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true' "$WINDOW"; then
  pass "dumpsys window: the keyguard is still showing"
else
  fail "the keyguard is not showing ($(grep -iE 'keyguard' "$WINDOW" | head -2 | tr '\n' ' '))"
fi
grep -qiE 'isKeyguardLocked=true|mKeyguardLocked=true' "$WINDOW" \
  && pass "dumpsys window: isKeyguardLocked=true" \
  || echo "note phone-screen: no isKeyguardLocked line on this build; the showing line is the evidence"

{
  echo "screen-off: $(grep '^state screen=off' "$WAKE" | tail -1)"
  echo "wake: $(grep '^sent phone.wake' "$WAKE" | tail -1)"
  echo "screen-on: $(grep '^state screen=on' "$WAKE" | tail -1)"
  echo "power: $(grep -m1 'mWakefulness' "$POWER" | tr -s ' ') / $(grep -m1 'Display Power' "$POWER" | tr -s ' ')"
  echo "keyguard: $(grep -iE 'isKeyguardShowing=true|mKeyguardShowing=true' "$WINDOW" | head -1 | tr -s ' ')"
  echo "failed: $FAILED"
} > "$RESULT"
cat "$RESULT"

kill_emulator
exit "$FAILED"
