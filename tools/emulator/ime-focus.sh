#!/usr/bin/env bash
# ISS-35 / WIN-51: the phone's own screen keeps the top focus, so its own apps
# show their keyboard while an app window is open. ONE emulator boot.
#
#   bash tools/emulator/ime-focus.sh --check    rehearsal: preflight, syntax,
#                                               the driver, the APK; no device
#   bash tools/emulator/ime-focus.sh            boot, pair, the check, kill
#   bash tools/emulator/ime-focus.sh --no-boot  the check on a rig already up
#                                               and paired (a retry, or the
#                                               second APK of one boot)
#
# The APK must already be built with K1
# (`cd android && ./gradlew :app:assembleDebug`); start.sh runs with --no-build so
# no JVM runs on the host. The driver opens one session, focuses Settings' search
# field on display 0, opens app windows and taps the field again, then proves the
# windows' own typing, TextRuns text, image paste, drop and title still work. It
# never logs a task label, a title, typed text or a path: lengths, ids and
# states only.
set -u

MODE=run
BOOT=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "ime-focus.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export CONTIGUA_PORT="${CONTIGUA_PORT:-47996}"
export CONTIGUA_SERIAL=emulator-5554
export CONTIGUA_AGENT_DIR="$PWD/.agent/emu"
mkdir -p "$CONTIGUA_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$CONTIGUA_AGENT_DIR/ime-focus"
LOG="$OUT/ime-focus.log"
APK="android/app/build/outputs/apk/debug/app-debug.apk"
STATE="$CACHE_DIR/deckctl-state.json"
FAILED=0

check_mode() {
  : > "$LOG"
  bash -n tools/emulator/ime-focus.sh || { echo "CHECK FAIL: bash -n ime-focus.sh"; return 1; }
  bash -n tools/emulator/start.sh || { echo "CHECK FAIL: bash -n start.sh"; return 1; }
  "$PYTHON" -m py_compile tools/emulator/ime-focus.py \
    || { echo "CHECK FAIL: py_compile ime-focus.py"; return 1; }
  bash tools/emulator/preflight.sh || { echo "CHECK FAIL: preflight"; return 1; }
  [ -f "$APK" ] || { echo "CHECK FAIL: no $APK (gradlew :app:assembleDebug)"; return 1; }
  echo "--- budget: $(cat "$MAIN_REPO/.agent/budgets/ime-focus" 2>/dev/null || echo '?')"
  echo "--- boots in the ledger for ime-focus: $(ledger_boots /tmp/contigua-boots.ledger ime-focus)"
  if device_present; then
    echo "CHECK FAIL: $SERIAL is already up (a boot would be wasted)"
    return 1
  fi
  echo "CHECK OK: ime-focus emulator rehearsal"
}

if [ "$MODE" = check ]; then
  check_mode
  exit $?
fi

if [ "$BOOT" -eq 1 ] && "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "ime-focus: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
if [ "$BOOT" -eq 1 ]; then
  trap 'kill_emulator' EXIT
fi
mkdir -p "$OUT"
: > "$LOG"

if [ "$BOOT" -eq 1 ]; then
  echo "ime-focus: booting $SERIAL (one boot budget)" | tee -a "$LOG"
  if ! bash tools/emulator/start.sh --no-build > "$OUT/start.log" 2>&1; then
    tail -8 "$OUT/start.log" | tee -a "$LOG"
    echo "FAIL ime-focus: start.sh --no-build (see start.log)" | tee -a "$LOG"
    exit 1
  fi
  tail -1 "$OUT/start.log" | tee -a "$LOG"

  PAIRED=0
  for _ in 1 2 3; do
    if "$PYTHON" tools/emulator/poc.py --state "$STATE" --addr "127.0.0.1:$PORT" \
         --serial "$SERIAL" --adb "$ADB" pair > "$OUT/pair.log" 2>&1; then
      PAIRED=1
      break
    fi
    sleep 3
  done
  if [ "$PAIRED" -ne 1 ]; then
    tail -6 "$OUT/pair.log" | tee -a "$LOG"
    echo "FAIL ime-focus: pair (see pair.log)" | tee -a "$LOG"
    exit 1
  fi
  echo "ime-focus: paired" | tee -a "$LOG"
else
  device_present || { echo "ime-focus: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
fi

export CONTIGUA_WT="$PWD"
export ADB_BIN="$ADB"
export DECKCTL_STATE="$STATE"
export IME_FOCUS_OUT="$OUT"
export CONTIGUA_HOST="127.0.0.1"
export CONTIGUA_PORT="$PORT"
export CONTIGUA_BROWSER="${CONTIGUA_BROWSER:-acr.browser.lightning}"
export CONTIGUA_MESSENGER="${CONTIGUA_MESSENGER:-org.fossify.messages}"

"$PYTHON" tools/emulator/ime-focus.py 2>&1 | tee -a "$LOG"
FAILED=${PIPESTATUS[0]}

echo "ime-focus: driver rc=$FAILED" | tee -a "$LOG"
if [ "$BOOT" -eq 1 ]; then
  kill_emulator
fi
exit "$FAILED"
