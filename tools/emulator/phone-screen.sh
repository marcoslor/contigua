#!/usr/bin/env bash
# `state.screen` and `phone.wake` on the emulator rig — ONE boot
# (docs/design/phone-mirror.md "Screen off and wake").
#
#   tools/emulator/phone-screen.sh            the run (heavy.sh owns the lock
#                                             and the boot budget)
#   tools/emulator/phone-screen.sh --no-boot  the same checks on a rig that is
#                                             already up and paired (verify-batch.sh)
#   tools/emulator/phone-screen.sh --check    a dry run: preflight (syntax,
#                                             files, the APK's manifest,
#                                             versionCode), the serial, the
#                                             parser — no device
#
# Run it as `bash tools/emulator/phone-screen.sh` (the exec bit is not relied on).
#
# What it proves: after the rig boots and pairs, `input keyevent KEYCODE_SLEEP`
# makes the phone send `state.screen off`; `phone.wake` at shell UID brings
# display 0 back (`mWakefulness=Awake`, display 0 ON in `dumpsys display`) and
# `state.screen on` arrives; the keyguard is still locked afterwards. It never
# unlocks or dismisses the keyguard and never changes lock settings. Results are
# states only, in .agent/emu/phone-screen.log.
set -u

MODE=run
BOOT=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "phone-screen.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export CONTIGUA_PORT="${CONTIGUA_PORT:-47811}"
export CONTIGUA_SERIAL=emulator-5554
export CONTIGUA_AGENT_DIR="$PWD/.agent/emu"
mkdir -p "$CONTIGUA_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$CONTIGUA_AGENT_DIR"
RESULT="$OUT/phone-screen.log"
WAKE="$OUT/phone-screen-wake.log"
POWER="$OUT/phone-screen-power.log"
DISPLAY_ON="$OUT/phone-screen-display-on.log"
DISPLAY_OFF="$OUT/phone-screen-display-off.log"
WINDOW="$OUT/phone-screen-window.log"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$CACHE_DIR/deckctl-state.json")

FAILED=0
pass() { echo "PASS phone-screen: $*"; }
fail() { echo "FAIL phone-screen: $*"; FAILED=1; }

# Display 0's power state from a platform dump: "ON<TAB>mState=ON" (see
# display-state.py; API 36's dumpsys power names a binder, not the state).
display_state() { # display_state <display-dump>
  "$PYTHON" tools/emulator/display-state.py "$1" --power "$POWER" 2>/dev/null || true
}

# ---- --check: everything that can be wrong before a boot -------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  bash tools/emulator/preflight.sh || { echo "CHECK FAIL: preflight"; exit 1; }
  "$PYTHON" tools/emulator/display-state.py --self-test \
    || { echo "CHECK FAIL: display-state parser"; exit 1; }
  # The captures from the boot that proved the parser (fixtures, never
  # committed): the real dumps say mScreenState in "Display Power State:".
  for cap in "$OUT/phone-screen-display-on.log:ON" "$OUT/phone-screen-display-off.log:OFF"; do
    file="${cap%:*}"
    want="${cap##*:}"
    [ -f "$file" ] || continue
    got="$("$PYTHON" tools/emulator/display-state.py "$file" | cut -f1)"
    [ "$got" = "$want" ] \
      || { echo "CHECK FAIL: display-state read '$got' from $(basename "$file") (want $want)"; exit 1; }
    echo "CHECK OK: display-state reads $got from $(basename "$file")"
  done
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
    echo "CHECK FAIL: $SERIAL is already running (not ours to touch)"
    exit 1
  fi
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
  echo "CHECK OK: preflight, deckctl screen, fakephone flags; $SERIAL free"
  exit 0
fi

# ---- the run (ONE boot, or a rig verify-batch.sh already booted) ------------
if [ "$BOOT" -eq 1 ] && "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "phone-screen: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() {
  [ -n "${WAKE_PID:-}" ] && kill "$WAKE_PID" >/dev/null 2>&1 || true
  if [ "$BOOT" -eq 1 ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  fi
}
trap 'kill_emulator' EXIT

if [ "$BOOT" -eq 1 ]; then
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
else
  device_present || { echo "phone-screen: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
fi
ensure_forward >/dev/null || { echo "phone-screen: no server port"; echo "failed: 1 (port)" > "$RESULT"; exit 1; }

# --- pair (the real v2 flow) ----------------------------------------------
if [ "$BOOT" -eq 1 ]; then
  if ! "$PYTHON" tools/emulator/poc.py --state "$CACHE_DIR/deckctl-state.json" \
        --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair; then
    echo "phone-screen: pairing failed (unverified)"
    exit 1
  fi
  echo "phone-screen: paired"
fi

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

# API 36 prints `Display Power: com.android.server.power.PowerManagerService$1@…`
# in dumpsys power, so display 0's own dump is the evidence; the parser keeps
# the old `Display Power: state=` line as the alternative.
emu shell dumpsys display > "$DISPLAY_ON" 2>/dev/null || true
DISPLAY_STATE="$(display_state "$DISPLAY_ON")"
case "$DISPLAY_STATE" in
  ON*) pass "display 0 is ON ($(printf '%s' "$DISPLAY_STATE" | cut -f2))" ;;
  OFF*) fail "display 0 is OFF after the wake ($(printf '%s' "$DISPLAY_STATE" | cut -f2))" ;;
  *) fail "display 0 state unknown ($(printf '%s' "$DISPLAY_STATE" | cut -f2))" ;;
esac

emu shell dumpsys window > "$WINDOW" 2>/dev/null || true
if grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true' "$WINDOW"; then
  pass "dumpsys window: the keyguard is still showing"
else
  fail "the keyguard is not showing ($(grep -iE 'keyguard' "$WINDOW" | head -2 | tr '\n' ' '))"
fi
grep -qiE 'isKeyguardLocked=true|mKeyguardLocked=true' "$WINDOW" \
  && pass "dumpsys window: isKeyguardLocked=true" \
  || echo "note phone-screen: no isKeyguardLocked line on this build; the showing line is the evidence"

# The parser must read OFF too, or an always-ON parser would pass this section
# blind. Sleep the panel once more, capture, wake it again: KEYCODE_WAKEUP only
# lights the display, it never dismisses the keyguard.
emu shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1 || true
sleep 3
emu shell dumpsys display > "$DISPLAY_OFF" 2>/dev/null || true
emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
DISPLAY_OFF_STATE="$(display_state "$DISPLAY_OFF")"
case "$DISPLAY_OFF_STATE" in
  OFF*) pass "with the panel asleep display 0 reads OFF ($(printf '%s' "$DISPLAY_OFF_STATE" | cut -f2))" ;;
  *) fail "with the panel asleep display 0 is not OFF ($(printf '%s' "$DISPLAY_OFF_STATE" | cut -f2))" ;;
esac

{
  echo "screen-off: $(grep '^state screen=off' "$WAKE" | tail -1)"
  echo "wake: $(grep '^sent phone.wake' "$WAKE" | tail -1)"
  echo "screen-on: $(grep '^state screen=on' "$WAKE" | tail -1)"
  echo "power: $(grep -m1 'mWakefulness' "$POWER" | tr -s ' ')"
  echo "display-on: $(printf '%s' "$DISPLAY_STATE" | tr '\t' ' ')"
  echo "display-off: $(printf '%s' "$DISPLAY_OFF_STATE" | tr '\t' ' ')"
  echo "keyguard: $(grep -iE 'isKeyguardShowing=true|mKeyguardShowing=true' "$WINDOW" | head -1 | tr -s ' ')"
  echo "failed: $FAILED"
} > "$RESULT"
cat "$RESULT"

if [ "$FAILED" -ne 0 ]; then
  # Evidence for the next boot: the phone's own phone.wake lines and the
  # session's last output (states only, never any content).
  EMULOG="$OUT/phone-screen-logcat.log"
  emu logcat -d -s ContiguaSvc:I ContiguaApp:I 2>/dev/null |
    tr -d '\r' | tail -40 > "$EMULOG" || true
  echo "phone-screen: logcat evidence ($EMULOG):"
  tail -10 "$EMULOG"
  echo "phone-screen: session tail: $(tail -3 "$WAKE" 2>/dev/null | tr '\n' ' ')"
fi

if [ "$BOOT" -eq 1 ]; then
  kill_emulator
fi
exit "$FAILED"
