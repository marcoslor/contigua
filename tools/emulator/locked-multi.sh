#!/usr/bin/env bash
# Two app windows on a locked, screen-off phone: covering one and closing the
# other must not end the episode or turn the remaining display off (CTRL-14),
# no keep-alive step may light the panel (CTRL-15), and the take-over's lit
# window stays short (CTRL-16). ONE boot (docs/specs/controls.md,
# docs/PROTOCOL.md "Phone screen").
#
#   bash tools/emulator/locked-multi.sh            the run (heavy.sh owns the
#                                                 lock and the boot budget)
#   bash tools/emulator/locked-multi.sh --no-boot  the same checks on a rig that
#                                                 is already up and paired
#   bash tools/emulator/locked-multi.sh --before <apk> --after <apk>
#                                                 one boot, two phases: BEFORE
#                                                 (the unfixed build) must fail
#                                                 the episode rules, AFTER must
#                                                 pass; both results are logged
#   bash tools/emulator/locked-multi.sh --judge <label> <dir> <session> <logcat>
#                                                 re-read one captured phase
#   bash tools/emulator/locked-multi.sh --check    a dry run: syntax, the driver,
#                                                 the parser's fixtures, the
#                                                 APKs, the serial and the
#                                                 budget, and the boot sequence
#   bash tools/emulator/locked-multi.sh --dry-run  the same as --check
#
# Run it as `bash tools/emulator/locked-multi.sh` (the exec bit is not relied on).
#
# The run is the 11-01 field shape (debug.contigua.force_panel_off=1 and
# debug.contigua.vd_panel_group=1 give AOSP One UI's shared panel group):
#   (a) open stream 1 on the locked phone, cover it (window.pause), open stream 2,
#       close stream 2 and resume stream 1: stream 1's display is still ON, its
#       display wake lock was never released, the phone never went back to sleep;
#   (b) no `power: panel ON` after the take-over, and SurfaceFlinger's physical
#       display never goes ON again after its first off;
#   (c) the physical ON window of the take-over (wake -> the off that stuck) is
#       at most 350 ms (the field log: 639 ms);
#   (d) the phone is still locked afterwards (WIN-20).
# The evidence is the dumps and the app's own lines, never pixels. Results go to
# .agent/locked-multi/locked-multi*.log. It never touches a phone but $SERIAL.
set -u

MODE=run
BOOT=1
JUDGE=0
JUDGE_LABEL=""
JUDGE_DIR=""
JUDGE_SESSION=""
JUDGE_LOGCAT=""
BEFORE_APK=""
AFTER_APK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--dry-run) MODE=check ;;
    --no-boot) BOOT=0 ;;
    --before)
      [ $# -ge 2 ] || { echo "locked-multi.sh: --before needs an APK" >&2; exit 2; }
      BEFORE_APK="$2"; shift ;;
    --after)
      [ $# -ge 2 ] || { echo "locked-multi.sh: --after needs an APK" >&2; exit 2; }
      AFTER_APK="$2"; shift ;;
    --judge)
      [ $# -ge 5 ] || { echo "locked-multi.sh: --judge needs <label> <dir> <session> <logcat>" >&2; exit 2; }
      JUDGE=1; JUDGE_LABEL="$2"; JUDGE_DIR="$3"; JUDGE_SESSION="$4"; JUDGE_LOGCAT="$5"; shift 4 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "locked-multi.sh: unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done
AB=0
if [ -n "$BEFORE_APK" ] || [ -n "$AFTER_APK" ]; then
  [ -n "$BEFORE_APK" ] && [ -n "$AFTER_APK" ] ||
    { echo "locked-multi.sh: --before and --after go together" >&2; exit 2; }
  [ "$BOOT" -eq 1 ] || { echo "locked-multi.sh: --before/--after own the boot (no --no-boot)" >&2; exit 2; }
  AB=1
fi

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export CONTIGUA_PORT="${CONTIGUA_PORT:-47995}"
export CONTIGUA_SERIAL=emulator-5554
export CONTIGUA_AGENT_DIR="$PWD/.agent/locked-multi"
# start.sh sets this before it launches the server, so the policy is built forced.
export CONTIGUA_FORCE_PANEL_OFF=1
mkdir -p "$CONTIGUA_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$CONTIGUA_AGENT_DIR"
APK="${CONTIGUA_APK:-$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
STATE="$CACHE_DIR/deckctl-state-locked-multi.json"
LIMIT_MS=350

# --- the boot and service helpers -------------------------------------------
SHIZUKU_PKG=moe.shizuku.privileged.api
shizuku_pid() {
  emu shell "ps -A -o PID,NAME 2>/dev/null | grep -w shizuku_server" 2>/dev/null |
    awk '{print $1}' | tr -d '\r' | tr '\n' ' '
}

# The starter is the rig's documented adb entry point; it kills any old server
# and forks app_process as the adb shell user. A cold boot's first fork can die
# (boot 1: start.sh's own start found no server), so try it again.
start_shizuku() {
  local code_path abi starter i
  [ -n "$(shizuku_pid)" ] && return 0
  code_path="$(emu shell dumpsys package "$SHIZUKU_PKG" 2>/dev/null |
    sed -n 's/.*codePath=//p' | head -1 | tr -d '\r')"
  if [ -z "$code_path" ] && [ -s "$FIXTURE_DIR/shizuku.apk" ]; then
    step "installing the cached Shizuku manager"
    emu install -r -g "$FIXTURE_DIR/shizuku.apk" >/dev/null 2>&1 || true
    code_path="$(emu shell dumpsys package "$SHIZUKU_PKG" 2>/dev/null |
      sed -n 's/.*codePath=//p' | head -1 | tr -d '\r')"
  fi
  abi="$(emu shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    arm64-v8a) abi=arm64 ;;
    armeabi-v7a) abi=arm ;;
  esac
  starter="$code_path/lib/$abi/libshizuku.so"
  emu shell "test -x $starter" 2>/dev/null || { echo "locked-multi: no Shizuku starter at $starter" >&2; return 1; }
  for i in 1 2 3; do
    step "starting the Shizuku server (try $i)"
    emu shell "$starter" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [ -n "$(shizuku_pid)" ] && return 0
      sleep 1
    done
    sleep 2
  done
  return 1
}

# The shell service binds only while Shizuku's server runs: start it, then let
# restart_server relaunch the app and wait for the port.
ensure_service() {
  local i
  start_shizuku || true
  for i in 1 2 3; do
    if restart_server; then return 0; fi
    start_shizuku || true
    sleep 3
  done
  return 1
}

set_props() {
  emu shell setprop debug.contigua.force_panel_off 1 >/dev/null 2>&1 || true
  emu shell setprop debug.contigua.vd_panel_group 1 >/dev/null 2>&1 || true
  if [ "$(emu shell getprop debug.contigua.force_panel_off | tr -d '\r')" != "1" ] \
    || [ "$(emu shell getprop debug.contigua.vd_panel_group | tr -d '\r')" != "1" ]; then
    echo "locked-multi: the debug properties did not stick" >&2
    return 1
  fi
}

# Installs one APK and restarts the shell service *after* the properties are
# set, then proves the running server built the forced policy.
prepare_apk() { # prepare_apk <apk>
  local apk="$1" init
  step "installing $(basename "$apk")"
  emu_long install -r -d -g "$apk" >/dev/null 2>&1 ||
    { echo "locked-multi: $apk would not install (unverified)" >&2; return 1; }
  # Clear the log before the restart so the forced init line below is this
  # server's, never a previous one's.
  emu logcat -c >/dev/null 2>&1 || true
  emu shell "pkill -f app.contigua:contigua" >/dev/null 2>&1 || true
  sleep 1
  set_props || return 1
  ensure_service || { echo "locked-multi: the shell service did not come back" >&2; return 1; }
  init="$(emu logcat -d -s ContiguaSvc:I 2>/dev/null |
    grep 'power: panel power control' | tail -1 | tr -d '\r')"
  case "$init" in
    *"forcing the panel-dark path"*) echo "locked-multi: init: $init" ;;
    *)
      echo "locked-multi: the server did not start forced (init: ${init:-none})" >&2
      return 1
      ;;
  esac
  ensure_forward >/dev/null
}

# --- rehearsal --------------------------------------------------------------
if [ "$MODE" = check ]; then
  rc=0
  bash -n "$0" || { echo "CHECK FAIL: bash -n $0"; rc=1; }
  "$PYTHON" -m py_compile "$REPO_ROOT/tools/emulator/locked-multi.py" \
    "$REPO_ROOT/tools/emulator/locked-multi-read.py" || { echo "CHECK FAIL: py_compile"; rc=1; }
  "$PYTHON" "$REPO_ROOT/tools/emulator/locked-multi-read.py" --self-test ||
    { echo "CHECK FAIL: reader self-test"; rc=1; }
  "$PYTHON" - <<PY || { echo "CHECK FAIL: deckctl import"; rc=1; }
import sys
sys.path.insert(0, "$REPO_ROOT/tools/fakephone")
import deckctl, proto
assert hasattr(deckctl, "open_session") and hasattr(deckctl, "StreamRecorder")
assert hasattr(proto, "pack_touch")
print("CHECK OK: deckctl + proto symbols")
PY
  if [ "$AB" -eq 1 ]; then
    for apk in "$BEFORE_APK" "$AFTER_APK"; do
      [ -s "$apk" ] || { echo "CHECK FAIL: no APK at $apk"; rc=1; }
    done
  else
    [ -s "$APK" ] || { echo "CHECK FAIL: no debug APK at $APK (run K1 assembleDebug)"; rc=1; }
  fi
  [ -x "$ADB" ] || { echo "CHECK FAIL: no adb at $ADB"; rc=1; }
  [ -x "$EMULATOR" ] || { echo "CHECK FAIL: no emulator at $EMULATOR"; rc=1; }
  PD_PREFLIGHT_DRY_RUN=1 bash "$EMU_DIR/preflight.sh" || { echo "CHECK FAIL: preflight"; rc=1; }
  echo "--- the boot sequence ---"
  echo "start.sh --no-build; set force_panel_off + vd_panel_group; install the APK;"
  echo "pkill the shell service; ensure Shizuku; restart_server; prove the forced init;"
  echo "(pair with the rig PIN on a boot); lock.sh; run the driver; read the dumps + logcat."
  echo "--- budget: $(tr '\n' ' ' < "$HOME/dev/contigua/.agent/budgets/locked-multi" 2>/dev/null) ---"
  echo "--- boots already in the ledger for locked-multi: $(ledger_boots /tmp/contigua-boots.ledger locked-multi) ---"
  if device_present; then
    echo "CHECK FAIL: $SERIAL is already up (a boot would be wasted)"
    rc=1
  fi
  [ "$rc" -eq 0 ] && echo "CHECK OK: locked-multi rehearsal" || echo "CHECK FAIL: locked-multi rehearsal"
  exit "$rc"
fi

judge_phase() { # judge_phase <label> <dir> <result> <session> <logcat> [wake_state]
  local label="$1" dir="$2" result="$3" session="$4" logcat="$5" wake_state="${6:-n/a}"
  local display1 display2 state_one state_two state_two2 state_after facts
  local released sleeps panel_on panel_off lit on_again locks sink tap_started vd_at_close live_after
  local guard_after=false phase_failed=0
  display1="$(sed -n 's/^display1=//p' "$session" | tail -1)"
  display2="$(sed -n 's/^display2=//p' "$session" | tail -1)"
  if [ -z "$display2" ]; then
    # A run from before the driver printed one value per line.
    display2="$(sed -n 's/.*[[:space:]]display2=//p' "$session" | tail -1)"
    display1="${display1%% *}"
  fi
  if [ -z "$display1" ] || [ -z "$display2" ]; then
    echo "locked-multi: $label: no display ids in $session" >&2
    { echo "failed: 1 (no displays)"; cat "$session"; } > "$result"
    return 1
  fi

  state_one="$(  "$PYTHON" "$REPO_ROOT/tools/emulator/locked-multi-read.py" --state "$dir/display-one.txt"   "$display1")"
  state_two="$(  "$PYTHON" "$REPO_ROOT/tools/emulator/locked-multi-read.py" --state "$dir/display-two.txt"   "$display1")"
  state_two2="$( "$PYTHON" "$REPO_ROOT/tools/emulator/locked-multi-read.py" --state "$dir/display-two.txt"   "$display2")"
  state_after="$( "$PYTHON" "$REPO_ROOT/tools/emulator/locked-multi-read.py" --state "$dir/display-after.txt" "$display1")"
  facts="$("$PYTHON" "$REPO_ROOT/tools/emulator/locked-multi-read.py" --facts "$logcat" "$display1" "$display2")"
  fact() { printf '%s\n' "$facts" | sed -n "s/^$1=//p" | tail -1; }
  released="$(fact released_while_open)"
  sleeps="$(fact sleeps_while_open)"
  panel_on="$(fact panel_on_after_takeover)"
  panel_off="$(fact panel_off_writes)"
  lit="$(fact lit_ms)"
  on_again="$(fact on_again_after_off)"
  locks="$(fact keepalive_locks1_after_resume)"
  vd_at_close="$(fact vd1_at_close)"
  live_after="$(fact episode_live_after_close)"
  sink="$(fact sink_lines)"
  tap_started="$(fact tap_started)"
  [ -f "$dir/window-after.txt" ] &&
    grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true' "$dir/window-after.txt" && guard_after=true

  echo "--- $label ---"
  # The state the reviewer asks for is the one right at the sibling's close:
  # the VD log's last change before it (the dump is taken 3 s later, when an app
  # that shared its task with the closed window may already have exited).
  if [ "$vd_at_close" = "ON" ] && { [ "$state_after" = "ON" ] || [ "${live_after:-0}" = "1" ]; }; then
    echo "PASS [$label] the other display was ON when its sibling closed and stayed in the episode (display $display1: at close $vd_at_close, dump after $state_after, episode live after close ${live_after:-?}; display $display2 while both open: $state_two2)"
  else
    echo "FAIL [$label] the other display left the episode (display $display1: at close $vd_at_close, dumped $state_one/$state_two/$state_after, episode live after close ${live_after:-?}; display $display2: $state_two2)"; phase_failed=1
  fi
  if [ "${released:-1}" = "0" ]; then
    echo "PASS [$label] the covered window's display wake was never released while it was open"
  else
    echo "FAIL [$label] the covered window's display wake was released ${released:-?} time(s) while it was open"; phase_failed=1
  fi
  if [ "${sleeps:-1}" = "0" ]; then
    echo "PASS [$label] the phone never went back to sleep while a window was open"
  else
    echo "FAIL [$label] the phone went back to sleep ${sleeps:-?} time(s) while a window was open"; phase_failed=1
  fi
  if [ "${panel_on:-1}" = "0" ]; then
    echo "PASS [$label] no keep-alive step reported the panel on after the take-over (the override holds it)"
  else
    echo "FAIL [$label] ${panel_on:-?} panel-on plan line(s) after the take-over while the panel was owed off"; phase_failed=1
  fi
  if [ "${lit:--1}" -ge 0 ] && [ "${lit:--1}" -le "$LIMIT_MS" ]; then
    echo "PASS [$label] the take-over's physical ON window was ${lit} ms (limit ${LIMIT_MS} ms; the field log was 639 ms)"
  else
    echo "FAIL [$label] the take-over's physical ON window was ${lit:-none} ms (limit ${LIMIT_MS} ms)"; phase_failed=1
  fi
  if [ "${on_again:-1}" = "0" ]; then
    echo "PASS [$label] SurfaceFlinger's physical display never went ON again after its first off"
  else
    echo "FAIL [$label] SurfaceFlinger's physical display went ON again ${on_again:-?} time(s) after its first off"; phase_failed=1
  fi
  if [ "${live_after:-0}" = "1" ]; then
    echo "PASS [$label] the episode was still live after the sibling close (the resume did not start a new one)"
  else
    echo "FAIL [$label] the episode ended at the sibling close"; phase_failed=1
  fi
  if [ "${panel_off:-0}" -ge 1 ]; then
    echo "PASS [$label] the panel was powered off under the streams (${panel_off} write(s))"
  else
    echo "FAIL [$label] the panel was never powered off"; phase_failed=1
  fi
  if [ "$guard_after" = "true" ]; then
    echo "PASS [$label] the phone is still locked after the run (keyguard showing)"
  else
    echo "FAIL [$label] the keyguard is not showing after the run"; phase_failed=1
  fi
  if [ "${sink:-0}" -gt 0 ]; then
    if [ "${tap_started:-0}" = "1" ]; then
      echo "PASS [$label] a gesture with a NO_INPUT_CHANNEL sink line still opened an app screen (${sink} sink line(s))"
    else
      echo "FAIL [$label] ${sink} sink line(s) and the tap never reached the app"; phase_failed=1
    fi
  else
    echo "note [$label]: no NO_INPUT_CHANNEL line in this run (the sink is a transition artifact; see notes.md)"
  fi

  {
    echo "display1: $display1 states one=$state_one two=$state_two after=$state_after"
    echo "display2: $display2 state two=$state_two2"
    echo "wake: released_while_open=$released sleeps_while_open=$sleeps keepalive_locks1=$locks"
    echo "display: vd_at_close=$vd_at_close episode_live_after_close=$live_after"
    echo "panel: on_after_takeover=$panel_on off_writes=$panel_off lit_ms=$lit limit_ms=$LIMIT_MS on_again=$on_again"
    echo "input: sink_lines=$sink tap_started=$tap_started"
    echo "before: wakefulness=$wake_state"
    echo "after: keyguard=$guard_after"
    echo "session: $(tr '\n' ' ' < "$session")"
    echo "failed: $phase_failed"
  } > "$result"
  return "$phase_failed"
}

run_phase() { # run_phase <label> <apk> <dir> <result> <session> <logcat>
  local label="$1" apk="$2" dir="$3" result="$4" session="$5" logcat="$6"
  local wake_state driver_rc
  mkdir -p "$dir"
  step "$label: preparing $(basename "$apk")"
  prepare_apk "$apk" || { echo "failed: 1 (service)" > "$result"; return 1; }

  echo "locked-multi: $label: locking the emulator (PIN + screen off)"
  bash "$EMU_DIR/lock.sh" || { echo "failed: 1 (lock)" > "$result"; return 1; }
  emu shell dumpsys window > "$dir/window-before.txt" 2>/dev/null || true
  grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true' "$dir/window-before.txt" ||
    echo "locked-multi: $label: the keyguard is not showing before the run" >&2
  wake_state="$(emu shell dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | tr -d '\r' | sed 's/.*mWakefulness=//')"
  case "$wake_state" in
    Asleep|Dozing) ;;
    *) echo "locked-multi: $label: the screen is not off (mWakefulness=${wake_state:-none})" >&2 ;;
  esac

  emu logcat -c >/dev/null 2>&1 || true
  "$PYTHON" "$REPO_ROOT/tools/emulator/locked-multi.py" --host 127.0.0.1 --port "$PORT" \
    --state "$STATE" --adb "$ADB" --serial "$SERIAL" --out "$dir" > "$session" 2>&1
  driver_rc=$?
  emu logcat -d > "$logcat" 2>/dev/null || true
  emu shell dumpsys window > "$dir/window-after.txt" 2>/dev/null || true
  if [ "$driver_rc" -ne 0 ]; then
    echo "locked-multi: $label: the driver did not finish (rc=$driver_rc): $(tail -2 "$session" | tr '\n' ' ')" >&2
    { echo "failed: 1 (driver)"; cat "$session"; } > "$result"
    return 1
  fi
  judge_phase "$label" "$dir" "$result" "$session" "$logcat" "${wake_state:-n/a}"
}

# --- judge one captured phase, no device ------------------------------------
if [ "$JUDGE" -eq 1 ]; then
  for f in "$JUDGE_DIR/display-one.txt" "$JUDGE_DIR/display-two.txt" "$JUDGE_DIR/display-after.txt" \
           "$JUDGE_SESSION" "$JUDGE_LOGCAT"; do
    [ -s "$f" ] || { echo "locked-multi: judge: missing $f" >&2; exit 2; }
  done
  judge_phase "$JUDGE_LABEL" "$JUDGE_DIR" "$OUT/locked-multi-${JUDGE_LABEL}.log" \
    "$JUDGE_SESSION" "$JUDGE_LOGCAT" "n/a"
  RC=$?
  cat "$OUT/locked-multi-${JUDGE_LABEL}.log"
  exit "$RC"
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
  # start.sh can die before its own property step (boot 1: the Shizuku server's
  # first fork did not survive). Its failure is not fatal here: the properties,
  # the service restart and the pairing below are the ones this check needs.
  bash tools/emulator/start.sh --no-build || \
    echo "locked-multi: start.sh did not finish; recovering with its pieces"
  set_props || { echo "locked-multi: the forced-panel property is not set"; exit 1; }
  start_shizuku || true
else
  device_present || { echo "locked-multi: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
fi

if [ "$AB" -eq 1 ]; then
  prepare_apk "$BEFORE_APK" || { echo "locked-multi: the BEFORE APK never came up (unverified)"; exit 1; }
else
  prepare_apk "$APK" || { echo "locked-multi: the APK never came up (unverified)"; exit 1; }
fi

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

# --- one phase: lock, run, read ---------------------------------------------
if [ "$AB" -eq 1 ]; then
  BEFORE_RESULT="$OUT/locked-multi-before.log"
  AFTER_RESULT="$OUT/locked-multi-after.log"
  run_phase "BEFORE" "$BEFORE_APK" "$OUT/before" "$BEFORE_RESULT" \
    "$OUT/locked-multi-before-session.log" "$OUT/locked-multi-before-logcat.txt"
  BEFORE_FAILED=$?
  run_phase "AFTER" "$AFTER_APK" "$OUT/after" "$AFTER_RESULT" \
    "$OUT/locked-multi-after-session.log" "$OUT/locked-multi-after-logcat.txt"
  AFTER_FAILED=$?
  echo "===== BEFORE ====="; cat "$BEFORE_RESULT"
  echo "===== AFTER ====="; cat "$AFTER_RESULT"
  if [ "$BEFORE_FAILED" -eq 0 ]; then
    echo "locked-multi: BEFORE passed; the unfixed APK did not reproduce the field shape"
    exit 1
  fi
  if [ "$AFTER_FAILED" -ne 0 ]; then
    echo "locked-multi: AFTER failed; see $AFTER_RESULT"
    exit 1
  fi
  echo "locked-multi: BEFORE failed as the field did, AFTER passed"
  exit 0
fi

run_phase "run" "$APK" "$OUT" "$OUT/locked-multi.log" \
  "$OUT/locked-multi-session.log" "$OUT/locked-multi-logcat.txt"
RC=$?
cat "$OUT/locked-multi.log"
if [ "$RC" -ne 0 ]; then
  echo "locked-multi: logcat evidence ($OUT/locked-multi-logcat.txt):"
  grep -E 'power:|keepalive|stream [12]|episode|display wake lock|contigua-|InputDispatcher|START u0|LockedMulti' \
    "$OUT/locked-multi-logcat.txt" | tail -50 | sed 's/^/  /'
fi
exit "$RC"
