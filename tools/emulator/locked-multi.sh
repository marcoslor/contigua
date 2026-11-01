#!/usr/bin/env bash
# Two app windows on a locked, screen-off phone: covering one and closing the
# other must not end the episode or turn the remaining display off (CTRL-14),
# no keep-alive step may light the panel (CTRL-15), and the take-over's lit
# window stays short. ONE boot (docs/specs/controls.md, docs/PROTOCOL.md
# "Phone screen").
#
#   bash tools/emulator/locked-multi.sh            the run (heavy.sh owns the
#                                                 lock and the boot budget)
#   bash tools/emulator/locked-multi.sh --no-boot  the same checks on a rig that
#                                                 is already up and paired
#   bash tools/emulator/locked-multi.sh --check    a dry run: syntax, the driver,
#                                                 the parser's fixtures, the
#                                                 serial and the budget — no device
#
# Run it as `bash tools/emulator/locked-multi.sh` (the exec bit is not relied on).
#
# The run is the 11-01 field shape (debug.pocketdeck.force_panel_off=1 and
# debug.pocketdeck.vd_panel_group=1 give AOSP One UI's shared panel group):
#   (a) open stream 1 on the locked phone, cover it (window.pause), open stream 2,
#       close stream 2 and resume stream 1: stream 1's display is still ON, its
#       display wake lock was never released, the phone never went back to sleep;
#   (b) no `power: panel ON` after the take-over, and SurfaceFlinger's physical
#       display never goes ON again after its first off;
#   (c) the physical ON window of the take-over (wake -> the off that stuck) is
#       at most 350 ms (the field log: 639 ms);
#   (d) the phone is still locked afterwards (WIN-20).
# The evidence is the dumps and the app's own lines, never pixels. Results go to
# .agent/locked-multi/locked-multi.log. It never touches a phone but $SERIAL.
set -u

MODE=run
BOOT=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "locked-multi.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47995}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/locked-multi"
# start.sh sets this before it launches the server, so the policy is built forced.
export POCKETDECK_FORCE_PANEL_OFF=1
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
RESULT="$OUT/locked-multi.log"
PD_INSTALL_LOG="$OUT/install-failure.log"
export PD_INSTALL_LOG
SESSION="$OUT/locked-multi-session.log"
LOGCAT="$OUT/locked-multi-logcat.txt"
DRIVER="$REPO_ROOT/tools/emulator/locked-multi.py"
READER="$REPO_ROOT/tools/emulator/locked-multi-read.py"
APK="${POCKETDECK_APK:-$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
STATE="$CACHE_DIR/deckctl-state-locked-multi.json"
LIMIT_MS=350
FAILED=0
pass() { echo "PASS locked-multi: $*"; }
fail() { echo "FAIL locked-multi: $*"; FAILED=1; }

# --- rehearsal --------------------------------------------------------------
if [ "$MODE" = check ]; then
  rc=0
  bash -n "$0" || { echo "CHECK FAIL: bash -n $0"; rc=1; }
  "$PYTHON" -m py_compile "$DRIVER" "$READER" || { echo "CHECK FAIL: py_compile"; rc=1; }
  "$PYTHON" "$READER" --self-test || { echo "CHECK FAIL: reader self-test"; rc=1; }
  "$PYTHON" - <<PY || { echo "CHECK FAIL: deckctl import"; rc=1; }
import sys
sys.path.insert(0, "$REPO_ROOT/tools/fakephone")
import deckctl, proto
assert hasattr(deckctl, "open_session") and hasattr(deckctl, "StreamRecorder")
assert hasattr(proto, "pack_touch")
print("CHECK OK: deckctl + proto symbols")
PY
  [ -s "$APK" ] || { echo "CHECK FAIL: no debug APK at $APK (run K1 assembleDebug)"; rc=1; }
  [ -x "$ADB" ] || { echo "CHECK FAIL: no adb at $ADB"; rc=1; }
  [ -x "$EMULATOR" ] || { echo "CHECK FAIL: no emulator at $EMULATOR"; rc=1; }
  PD_PREFLIGHT_DRY_RUN=1 bash "$EMU_DIR/preflight.sh" || { echo "CHECK FAIL: preflight"; rc=1; }
  echo "--- budget: $(cat "$HOME/dev/pocketdeck/.agent/budgets/locked-multi" 2>/dev/null | tr '\n' ' ') ---"
  echo "--- boots already in the ledger for locked-multi: $(ledger_boots /tmp/pocketdeck-boots.ledger locked-multi) ---"
  if device_present; then
    echo "CHECK FAIL: $SERIAL is already up (a boot would be wasted)"
    rc=1
  fi
  [ "$rc" -eq 0 ] && echo "CHECK OK: locked-multi rehearsal" || echo "CHECK FAIL: locked-multi rehearsal"
  exit "$rc"
fi

# --- the run (ONE boot) -----------------------------------------------------
if [ "$BOOT" -eq 1 ] && device_present; then
  echo "locked-multi: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() {
  if [ "$BOOT" -eq 1 ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  fi
}
trap 'kill_emulator' EXIT

if [ "$BOOT" -eq 1 ]; then
  echo "locked-multi: booting $SERIAL (one boot budget)"
  if ! bash tools/emulator/start.sh --no-build; then
    echo "locked-multi: start.sh failed; restarting the shell service"
    if ! restart_server; then
      echo "locked-multi: the shell service never came up (unverified)"
      { echo "failed: 1 (start)"; cat "$PD_INSTALL_LOG" 2>/dev/null; } > "$RESULT"
      exit 1
    fi
  fi
  emu shell setprop debug.pocketdeck.force_panel_off 1 >/dev/null 2>&1 || true
  emu shell setprop debug.pocketdeck.vd_panel_group 1 >/dev/null 2>&1 || true
  if [ "$(emu shell getprop debug.pocketdeck.force_panel_off | tr -d '\r')" != "1" ] \
    || [ "$(emu shell getprop debug.pocketdeck.vd_panel_group | tr -d '\r')" != "1" ]; then
    fail "the debug properties did not stick"
  fi
else
  device_present || { echo "locked-multi: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
fi

# The APK must be this tree's build: a previous boot's install survives in the
# AVD's userdata, and start.sh skips an installed package (a stale server would
# answer with the old code and prove nothing).
if [ ! -s "$APK" ]; then
  echo "locked-multi: no debug APK at $APK (run K1 assembleDebug)"; exit 1
fi
step "installing this tree's APK"
if ! emu_long install -r -d -g "$APK" >/dev/null 2>&1; then
  echo "locked-multi: the APK would not install (unverified)"
  { echo "failed: 1 (install)"; } > "$RESULT"
  exit 1
fi
# A reinstall leaves the Shizuku shell service alive on the old build; kill it
# and restart so the running server is the one just installed.
emu shell "pkill -f dev.pocketdeck:pocketdeck" >/dev/null 2>&1 || true
sleep 1
restart_server || { echo "locked-multi: the shell service did not come back (unverified)"; exit 1; }
INIT_LINE="$(emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
  grep 'power: panel power control' | tail -1 | tr -d '\r')"
case "$INIT_LINE" in
  *"forcing the panel-dark path"*) echo "locked-multi: init: $INIT_LINE" ;;
  *)
    echo "locked-multi: the server did not start forced (init: ${INIT_LINE:-none})"
    { echo "failed: 1 (not-forced)"; echo "init: ${INIT_LINE:-none}"; } > "$RESULT"
    exit 1
    ;;
esac
ensure_forward >/dev/null || { echo "locked-multi: no server port after restart"; exit 1; }

if [ "$BOOT" -eq 1 ]; then
  bash "$EMU_DIR/unlock.sh" >/dev/null 2>&1 || true
  sleep 1
  if ! "$PYTHON" tools/emulator/poc.py --state "$STATE" --addr "127.0.0.1:$PORT" \
        --serial "$SERIAL" --adb "$ADB" pair --timeout 90 --tap-timeout 90; then
    echo "locked-multi: pairing failed (unverified)"
    exit 1
  fi
  echo "locked-multi: up and paired"
fi

# --- locked, screen off -----------------------------------------------------
echo "locked-multi: locking the emulator (PIN + screen off)"
bash "$EMU_DIR/lock.sh" || { fail "could not lock the emulator"; }
emu shell dumpsys window > "$OUT/window-before.txt" 2>/dev/null || true
if ! grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true' "$OUT/window-before.txt"; then
  fail "the keyguard is not showing before the run"
fi
WAKE_STATE="$(emu shell dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | tr -d '\r' | sed 's/.*mWakefulness=//')"
case "$WAKE_STATE" in
  Asleep|Dozing) ;;
  *) fail "the screen is not off before the run (mWakefulness=${WAKE_STATE:-none})" ;;
esac

emu logcat -c >/dev/null 2>&1 || true
"$PYTHON" "$DRIVER" --host 127.0.0.1 --port "$PORT" --state "$STATE" \
  --adb "$ADB" --serial "$SERIAL" --out "$OUT" > "$SESSION" 2>&1
DRIVER_RC=$?
emu logcat -d > "$LOGCAT" 2>/dev/null || true
emu shell dumpsys window > "$OUT/window-after.txt" 2>/dev/null || true

DISPLAY1="$(sed -n 's/^display1=//p' "$SESSION" | tail -1)"
DISPLAY2="$(sed -n 's/^display2=//p' "$SESSION" | tail -1)"
if [ "$DRIVER_RC" -ne 0 ]; then
  fail "the driver did not finish (rc=$DRIVER_RC): $(tail -2 "$SESSION" | tr '\n' ' ')"
fi
if [ -z "$DISPLAY1" ] || [ -z "$DISPLAY2" ]; then
  fail "the driver did not report both displays: $(tail -3 "$SESSION" | tr '\n' ' ')"
  { echo "failed: 1 (driver)"; cat "$SESSION"; } > "$RESULT"
  cat "$RESULT"
  exit 1
fi

STATE_ONE="$(  "$PYTHON" "$READER" --state "$OUT/display-one.txt"   "$DISPLAY1")"
STATE_TWO="$(  "$PYTHON" "$READER" --state "$OUT/display-two.txt"   "$DISPLAY1")"
STATE_TWO2="$( "$PYTHON" "$READER" --state "$OUT/display-two.txt"   "$DISPLAY2")"
STATE_AFTER="$( "$PYTHON" "$READER" --state "$OUT/display-after.txt" "$DISPLAY1")"
FACTS="$("$PYTHON" "$READER" --facts "$LOGCAT" "$DISPLAY1" "$DISPLAY2")"
fact() { printf '%s\n' "$FACTS" | sed -n "s/^$1=//p" | tail -1; }
RELEASED="$(fact released_while_open)"
SLEEPS="$(fact sleeps_while_open)"
PANEL_ON="$(fact panel_on_after_takeover)"
PANEL_OFF="$(fact panel_off_writes)"
LIT_MS="$(fact lit_ms)"
ON_AGAIN="$(fact on_again_after_off)"
LOCKS="$(fact keepalive_locks1_after_resume)"
SINK="$(fact sink_lines)"
TAP_STARTED="$(fact tap_started)"
GUARD_AFTER=false
grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true' "$OUT/window-after.txt" && GUARD_AFTER=true

if [ "$STATE_ONE" = "ON" ] && [ "$STATE_TWO" = "ON" ] && [ "$STATE_TWO2" = "ON" ] && [ "$STATE_AFTER" = "ON" ]; then
  pass "both displays were ON, and the remaining one stayed ON after its sibling closed and resumed (display $DISPLAY1: $STATE_ONE -> $STATE_TWO -> $STATE_AFTER)"
else
  fail "the remaining display left ON (display $DISPLAY1: $STATE_ONE -> $STATE_TWO -> $STATE_AFTER; display $DISPLAY2: $STATE_TWO2)"
fi
if [ "${RELEASED:-1}" = "0" ]; then
  pass "the covered window's display wake was never released while it was open"
else
  fail "the covered window's display wake was released ${RELEASED:-?} time(s) while it was open"
fi
if [ "${SLEEPS:-1}" = "0" ]; then
  pass "the phone never went back to sleep while a window was open"
else
  fail "the phone went back to sleep ${SLEEPS:-?} time(s) while a window was open"
fi
if [ "${PANEL_ON:-1}" = "0" ]; then
  pass "no keep-alive step reported the panel on after the take-over (the override holds it)"
else
  fail "${PANEL_ON:-?} panel-on plan line(s) after the take-over while the panel was owed off"
fi
if [ "${LIT_MS:--1}" -ge 0 ] && [ "${LIT_MS:--1}" -le "$LIMIT_MS" ]; then
  pass "the take-over's physical ON window was ${LIT_MS} ms (limit ${LIMIT_MS} ms; the field log was 639 ms)"
else
  fail "the take-over's physical ON window was ${LIT_MS:-none} ms (limit ${LIMIT_MS} ms)"
fi
if [ "${ON_AGAIN:-1}" = "0" ]; then
  pass "SurfaceFlinger's physical display never went ON again after its first off"
else
  fail "SurfaceFlinger's physical display went ON again ${ON_AGAIN:-?} time(s) after its first off"
fi
if [ "${LOCKS:-0}" -ge 1 ]; then
  pass "the keep-alive ran with one display lock after the resume (the episode is alive)"
else
  fail "no keep-alive step with a display lock after the resume"
fi
if [ "${PANEL_OFF:-0}" -ge 1 ]; then
  pass "the panel was powered off under the streams (${PANEL_OFF} write(s))"
else
  fail "the panel was never powered off"
fi
if [ "$GUARD_AFTER" = "true" ]; then
  pass "the phone is still locked after the run (keyguard showing)"
else
  fail "the keyguard is not showing after the run"
fi
if [ "${SINK:-0}" -gt 0 ]; then
  if [ "${TAP_STARTED:-0}" = "1" ]; then
    pass "a gesture with a NO_INPUT_CHANNEL sink line still opened an app screen (${SINK} sink line(s))"
  else
    fail "${SINK} sink line(s) and the tap never reached the app"
  fi
else
  echo "note locked-multi: no NO_INPUT_CHANNEL line in this run (the sink is a transition artifact; see notes.md)"
fi

{
  echo "display1: $DISPLAY1 states one=$STATE_ONE two=$STATE_TWO after=$STATE_AFTER"
  echo "display2: $DISPLAY2 state two=$STATE_TWO2"
  echo "wake: released_while_open=$RELEASED sleeps_while_open=$SLEEPS keepalive_locks1=$LOCKS"
  echo "panel: on_after_takeover=$PANEL_ON off_writes=$PANEL_OFF lit_ms=$LIT_MS limit_ms=$LIMIT_MS on_again=$ON_AGAIN"
  echo "input: sink_lines=$SINK tap_started=$TAP_STARTED"
  echo "before: keyguard=true wakefulness=$WAKE_STATE"
  echo "after: keyguard=$GUARD_AFTER"
  echo "session: $(tr '\n' ' ' < "$SESSION")"
  echo "failed: $FAILED"
} > "$RESULT"
cat "$RESULT"

if [ "$FAILED" -ne 0 ]; then
  echo "locked-multi: logcat evidence ($LOGCAT):"
  grep -E 'power:|keepalive|stream [12]|episode|display wake lock|pocketdeck-|InputDispatcher|START u0|LockedMulti' "$LOGCAT" |
    tail -50 | sed 's/^/  /'
fi
exit "$FAILED"
