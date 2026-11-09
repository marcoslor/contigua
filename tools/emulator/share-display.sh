#!/usr/bin/env bash
# ISS-51: a paste or drop's share screen stays in the window, never on the
# phone's own screen. ONE emulator boot, two phone states.
#
#   bash tools/emulator/share-display.sh --check    rehearsal: syntax, driver
#                                                    self-test, the debug
#                                                    activities in the APK; no
#                                                    device
#   ~/dev/pocketdeck/.agent/heavy.sh bash tools/emulator/share-display.sh \
#       [--second-apk PATH]
#
# Run it from the worktree that holds the second APK: the first APK is
# android/app/build/outputs/apk/debug/app-debug.apk in this tree.
# --second-apk runs the whole check again with another APK installed over the
# first, in the same boot: the first APK is the before (main: the two share
# sections must FAIL), the second the after (the fix: every section must pass).
# The boot budget is one for the pair. The swap kills the Shizuku-hosted
# `:pocketdeck` service (install -r leaves that uid-2000 process running the old
# APK) and fails unless a new pid maps the new base.apk.
#
# The APK must already be built with the Docker K1
# (`k1-docker.sh <android> :app:assembleDebug`); no JVM runs on the host.
#
# The stand-in (debug builds only): ShareDebugActivity is a window's app with an
# image paste field; its listener starts ShareDebugPickerActivity from the
# APPLICATION context with NEW_TASK, as a share target's picker does. The same
# app's ShareDebugSendActivity is the drop's ACTION_SEND target (application/pdf
# only, so the main ShareActivity's filters are untouched) and starts one
# picker from the application context and one from its own activity context.
#
# The check opens ShareDebugActivity in a PocketDeck window, sends the Mac's
# image paste and a pdf drop, and reads the task list: a dev.pocketdeck task on
# display 0 after a trigger is the bug. State (a) is the phone unlocked;
# state (b) is locked and screen off. A PASS needs no such task in both states.
set -u

MODE=run
SECOND_APK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --second-apk) SECOND_APK="${2:?--second-apk needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "share-display.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47987}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/emu"
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
LOG="$OUT/share-display.log"
APK="android/app/build/outputs/apk/debug/app-debug.apk"
STATE="$CACHE_DIR/deckctl-state.json"
FAILED=0
PHASE_FAILURES=0
PHASE_BUG_FAILURES=0
BEFORE_FAILURES=0
AFTER_FAILURES=0
BEFORE_BUG_FAILURES=0
AFTER_BUG_FAILURES=0

section() { # section <name> PASS|FAIL|INFO <detail...>
  printf 'SECTION %s\n' "$*" | tee -a "$LOG"
  if [ "$2" = "FAIL" ]; then
    FAILED=1
    PHASE_FAILURES=$((PHASE_FAILURES + 1))
  fi
}

# The proof's own sections: a `dev.pocketdeck` task on the phone's screen after
# the paste or the drop. On main these are the before's failures; after the fix
# they must all pass.
bug_section() {
  section "$@"
  if [ "$2" = "FAIL" ]; then
    PHASE_BUG_FAILURES=$((PHASE_BUG_FAILURES + 1))
  fi
}

check_mode() {
  : > "$LOG"
  bash -n tools/emulator/share-display.sh || { section syntax FAIL "bash -n"; return 1; }
  section syntax PASS "bash -n tools/emulator/share-display.sh"
  "$PYTHON" tools/emulator/share-arrival.py --self-test >/dev/null \
    && section driver PASS "share-arrival.py --self-test" \
    || { section driver FAIL "share-arrival.py --self-test"; return 1; }
  "$PYTHON" tools/emulator/service-maps.py --help >/dev/null 2>&1 \
    && section service-maps PASS "service-maps.py imports phone_install_check.py" \
    || { section service-maps FAIL "service-maps.py --help"; return 1; }
  bash tools/emulator/preflight.sh || { section preflight FAIL "preflight"; return 1; }
  section preflight PASS "preflight (no device)"
  [ -f "$APK" ] || { section apk FAIL "no $APK (build it with k1-docker)"; return 1; }
  local manifest
  manifest="$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" 2>/dev/null)"
  for activity in ShareDebugActivity ShareDebugSendActivity ShareDebugPickerActivity; do
    printf '%s' "$manifest" | grep -q "$activity" \
      || { section apk FAIL "$activity not in $APK"; return 1; }
  done
  section apk PASS "the three debug activities are in the merged manifest"
  section dry-run PASS "no device touched; run without --check boots once"
}

if [ "$MODE" = "check" ]; then
  check_mode
  exit $?
fi

"$ADB" devices 2>/dev/null | grep -q "^$SERIAL" && die "$SERIAL already running: refusing to touch it"
kill_emulator() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
trap 'kill_emulator' EXIT

{
  echo "=== share-display started $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
} > "$LOG"

[ -f "$APK" ] || die "no $APK (build it with k1-docker :app:assembleDebug)"
step "booting $SERIAL (one boot budget)"
if ! bash tools/emulator/start.sh --no-build > "$OUT/share-display-start.log" 2>&1; then
  tail -5 "$OUT/share-display-start.log" | tee -a "$LOG"
  section boot FAIL "start.sh --no-build (see $OUT/share-display-start.log)"
  exit 1
fi
section boot PASS "$(tail -1 "$OUT/share-display-start.log")"

DECKCTL=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" --state "$STATE")
connect_ok() { "${DECKCTL[@]}" apps >/dev/null 2>&1; }
pair_once() {
  "$PYTHON" tools/emulator/poc.py --state "$STATE" --addr "127.0.0.1:$PORT" \
    --serial "$SERIAL" --adb "$ADB" pair > "$OUT/share-display-pair.log" 2>&1
}
connect_until() { # a pinned connection, pairing only when it is needed
  local try
  for try in 1 2 3; do
    connect_ok && return 0
    pair_once || true
    connect_ok && return 0
    sleep 3
  done
  return 1
}
if connect_until; then
  section pair PASS "a session with the phone (pairing only when it was needed)"
else
  {
    echo "--- adb forward --list"
    "$ADB" -s "$SERIAL" forward --list 2>&1
    echo "--- listening sockets"
    emu shell "ss -ltn 2>/dev/null | grep LISTEN" 2>&1
    echo "--- app and service log"
    emu logcat -d -s PocketDeckApp:I PocketDeckSvc:I 2>/dev/null | tail -40
  } >> "$OUT/share-display-pair.log" 2>&1
  tail -5 "$OUT/share-display-pair.log" | tee -a "$LOG"
  section pair FAIL "no session (see $OUT/share-display-pair.log)"
  exit 1
fi

# One PNG for the paste and one pdf for the drop.
PNG="$OUT/share-display.png"
PDF="$OUT/share-display.pdf"
"$PYTHON" - "$PNG" "$PDF" <<'PY'
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
rows = b"".join(b"\x00" + bytes((x * 5 + y * 11) % 256 for x in range(48 * 3)) for y in range(48))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 48, 48, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
pdf = (b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
       b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
       b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 64 64]>>endobj\n"
       b"trailer<</Root 1 0 R>>\n%%EOF\n")
open(sys.argv[2], "wb").write(pdf)
PY

tasks() { emu shell dumpsys activity activities 2>/dev/null | tr -d '\r'; }

# A `dev.pocketdeck` task on display 0 is the share screen on the phone's own
# screen; every trigger must leave none there. The display count is printed so
# the log says where the tasks went.
phone_tasks() {
  tasks | awk -v pkg="dev.pocketdeck" '
    /^[[:space:]]*Display #0 \(activities/ { phone = 1; next }
    /^[[:space:]]*Display #[0-9]+ \(activities/ { phone = 0; next }
    phone && /^[[:space:]]*\* Task\{/ && index($0, ":" pkg "") { n++ }
    END { print n + 0 }'
}

window_tasks() {
  local display="$1"
  tasks | awk -v d="$display" -v pkg="dev.pocketdeck" '
    $0 ~ "^[[:space:]]*Display #" d " \\(activities" { here = 1; next }
    /^[[:space:]]*Display #[0-9]+ \(activities/ { here = 0; next }
    here && /^[[:space:]]*\* Task\{/ && index($0, ":" pkg "") { n++ }
    END { print n + 0 }'
}

picker_lines() { emu logcat -d -s ShareDebug:I 2>/dev/null | tr -d '\r' | grep 'picker origin='; }

# `adb install -r` does not restart the Shizuku-hosted shell service: it is a
# uid-2000 app_process, not the app's own process, so it survives the install
# and keeps serving the old APK. Kill every `:pocketdeck` pid (adb shell is the
# same uid), then let the app ask Shizuku for a fresh service from the APK now
# on disk — the plain-kill path `tools/phone_install.sh` falls back to.
kill_shell_service() {
  local pid
  for pid in $(server_pids); do
    emu shell "kill -9 $pid" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 10); do
    [ -z "$(server_pids)" ] && return 0
    sleep 1
  done
  return 1
}

# The service pid must map the live base.apk, the fact
# tools/phone_install_check.py decides (its evaluate/read_maps, with the pid
# list read from ps: pidof compares the 15-char comm and can miss this name).
service_maps_check() {
  "$PYTHON" tools/emulator/service-maps.py --adb "$ADB" --serial "$SERIAL"
}

picker_settled() {
  emu logcat -d -s ShareDebug:I 2>/dev/null | tr -d '\r' | grep 'phase=settled' || true
}

task_display() { # task_display <taskId>: the Display # section the task sits in
  tasks | awk -v id="$1" '
    /^[[:space:]]*Display #[0-9]+ \(activities/ { d = $2; sub("#", "", d); next }
    /^[[:space:]]*\* Task\{/ && match($0, /#[0-9]+/) {
      tid = substr($0, RSTART + 1, RLENGTH - 1)
      if (tid == id) { print d; exit }
    }'
}

judge_picker() { # judge_picker <section> <origin> <window display> [missing FAIL|INFO]
  local name="$1" origin="$2" window_display="$3" missing="${4:-FAIL}" line logged task settled
  line="$(picker_settled | grep "origin=$origin " | tail -1)"
  if [ -z "$line" ]; then
    if [ "$missing" = INFO ]; then
      section "$name" INFO "no settled picker line for origin=$origin (the share screen did not start)"
    else
      bug_section "$name" FAIL "no settled picker line for origin=$origin (the share screen never started)"
    fi
    return
  fi
  logged="$(printf '%s' "$line" | sed -n 's/.*display=\([0-9-]*\).*/\1/p')"
  task="$(printf '%s' "$line" | sed -n 's/.*task=\([0-9]*\).*/\1/p')"
  settled=""
  if [ -n "$task" ]; then
    settled="$(task_display "$task")"
    printf '  %s: task %s sits on display %s\n' "$name" "$task" "${settled:-unknown}" | tee -a "$LOG"
  fi
  # The task list's display is the fact (the brief's dumpsys read); the
  # activity's own display= is the fallback when the list has no entry.
  if [ -n "$settled" ] && [ "$settled" = "$window_display" ]; then
    bug_section "$name" PASS "share screen settled in the window (display $window_display): $line"
  elif [ -z "$settled" ] && [ "$logged" = "$window_display" ]; then
    bug_section "$name" PASS "share screen settled in the window (display $window_display, no task entry): $line"
  else
    bug_section "$name" FAIL "share screen is on display ${settled:-$logged}, not the window's $window_display: $line"
  fi
}

run_state() { # run_state <label> <paste-after> <drop-after> <seconds> [control 0|1]
  local label="$1" paste_after="$2" drop_after="$3" seconds="$4" control="${5:-1}"
  local board="$OUT/share-display-$label" display driver_pid tries
  rm -rf "$board"; mkdir -p "$board"
  step "$label: opening the stand-in in a window"
  "$PYTHON" tools/emulator/share-arrival.py --state "$STATE" --host 127.0.0.1 --port "$PORT" \
    --board "$board" --png "$PNG" --pdf "$PDF" --seconds "$seconds" \
    --paste-after "$paste_after" --drop-after "$drop_after" \
    > "$OUT/share-display-$label-driver.log" 2>&1 &
  driver_pid=$!

  tries=80
  while [ "$tries" -gt 0 ] && [ ! -s "$board/window" ]; do sleep 0.25; tries=$((tries - 1)); done
  if [ ! -s "$board/window" ]; then
    section "$label-window" FAIL "the window never opened (see $OUT/share-display-$label-driver.log)"
    kill "$driver_pid" 2>/dev/null
    return 1
  fi
  display="$(sed -n 's/.*display=\([0-9-]*\).*/\1/p' "$board/window" | head -1)"
  section "$label-window" PASS "window on display ${display:-none}: $(cat "$board/window")"
  [ -n "$display" ] && [ "$display" -gt 0 ] \
    || { section "$label-display" FAIL "the window has no virtual display: $display"; kill "$driver_pid" 2>/dev/null; return 1; }

  # --- the paste -----------------------------------------------------------
  emu logcat -c >/dev/null 2>&1 || true
  tries=120
  while [ "$tries" -gt 0 ] && [ ! -s "$board/paste-sent" ]; do sleep 0.25; tries=$((tries - 1)); done
  if [ ! -s "$board/paste-sent" ]; then
    bug_section "$label-paste" FAIL "the driver never sent the paste"
  else
    # The pickers log their settled display 2 s after they start: the
    # application-context one is the bug, the activity-context one the control.
    tries=40
    while [ "$tries" -gt 0 ]; do
      picker_settled | grep -q 'origin=app ' \
        && picker_settled | grep -q 'origin=activity ' && break
      sleep 0.5; tries=$((tries - 1))
    done
    judge_picker "$label-paste" app "$display"
    if [ "$control" = 1 ]; then
      judge_picker "$label-paste-control" activity "$display"
    else
      section "$label-paste-control" INFO "$(picker_settled | grep 'origin=activity ' | tail -1)"
    fi
  fi
  emu logcat -d -s PocketDeckSvc:I 2>/dev/null | tr -d '\r' | grep 'share arrival:' \
    > "$OUT/share-display-$label-paste-arrival.log" || true

  # --- the drop ------------------------------------------------------------
  # The paste picker lines are cleared so only the drop's pickers are judged.
  emu logcat -c >/dev/null 2>&1 || true
  tries=200
  while [ "$tries" -gt 0 ] && [ ! -s "$board/drop-sent" ]; do sleep 0.25; tries=$((tries - 1)); done
  if [ ! -s "$board/drop-sent" ]; then
    bug_section "$label-drop" FAIL "the driver never sent the drop"
  else
    # The drop's SEND target starts its picker a few seconds after the file.
    tries=60
    while [ "$tries" -gt 0 ] && ! picker_settled | grep -q 'origin=app '; do
      sleep 0.5; tries=$((tries - 1))
    done
    # A locked phone does not start the drop's SEND flow at all (it does not on
    # the pre-fix build either), so there is nothing to judge there; when a
    # picker does start, its display is judged like any other.
    if [ "$control" = 1 ]; then
      judge_picker "$label-drop" app "$display"
    else
      judge_picker "$label-drop" app "$display" INFO
    fi
  fi
  emu logcat -d -s PocketDeckSvc:I 2>/dev/null | tr -d '\r' | grep 'share arrival:' \
    > "$OUT/share-display-$label-drop-arrival.log" || true

  touch "$board/close"
  wait "$driver_pid" 2>/dev/null
  printf '  %s: driver says %s\n' "$label" "$(tail -2 "$OUT/share-display-$label-driver.log" | tr '\n' ' ')" | tee -a "$LOG"
}

# The stand-ins ship disabled (the person's phone runs debug builds; an enabled
# SEND filter would show a test target in every share sheet). Enable them on the
# emulator only, after every install.
enable_stand_ins() {
  local activity
  for activity in ShareDebugActivity ShareDebugSendActivity ShareDebugPickerActivity; do
    emu shell pm enable "dev.pocketdeck/dev.pocketdeck.app.$activity" >/dev/null 2>&1 \
      || { section stand-ins FAIL "pm enable $activity"; return 1; }
  done
  section stand-ins PASS "the three debug activities are enabled on the emulator"
}

run_phase() { # run_phase <tag>: both phone states with the APK now installed
  local tag="$1"
  PHASE_FAILURES=0
  PHASE_BUG_FAILURES=0
  enable_stand_ins || return 1

  step "[$tag] state (a): the phone unlocked, screen on"
  bash tools/emulator/unlock.sh > "$OUT/share-display-$tag-unlock-a.log" 2>&1 \
    || section "$tag-unlock-a" FAIL "unlock.sh (see $OUT/share-display-$tag-unlock-a.log)"
  run_state "$tag-unlocked" 6 22 55 1

  step "[$tag] state (b): the phone locked, screen off"
  bash tools/emulator/lock.sh > "$OUT/share-display-$tag-lock.log" 2>&1 \
    || { section "$tag-lock" FAIL "lock.sh (see $OUT/share-display-$tag-lock.log)"; return 1; }
  section "$tag-lock" PASS "$(grep -E 'locked:' "$OUT/share-display-$tag-lock.log" | tail -1)"
  run_state "$tag-locked" 6 22 55 0

  # Leave the rig usable for the next check on the next boot; the kill is next.
  bash tools/emulator/unlock.sh > "$OUT/share-display-$tag-unlock-b.log" 2>&1 || true
  if [ "$tag" = "before" ]; then
    BEFORE_FAILURES=$PHASE_FAILURES
    BEFORE_BUG_FAILURES=$PHASE_BUG_FAILURES
  else
    AFTER_FAILURES=$PHASE_FAILURES
    AFTER_BUG_FAILURES=$PHASE_BUG_FAILURES
  fi
}

run_phase before

if [ -n "$SECOND_APK" ]; then
  [ -f "$SECOND_APK" ] || die "no second APK at $SECOND_APK"
  OLD_SVC="$(server_pid)"
  section second-service-before INFO "shell service pid before the swap: ${OLD_SVC:-none}"
  step "installing the second APK over the first (same boot)"
  if emu install -r "$SECOND_APK" > "$OUT/share-display-second-install.log" 2>&1; then
    section second-install PASS "emu install -r $SECOND_APK"
  else
    tail -5 "$OUT/share-display-second-install.log" | tee -a "$LOG"
    section second-install FAIL "emu install -r (see $OUT/share-display-second-install.log)"
    kill_emulator
    exit 1
  fi
  step "killing the old shell service so the app binds one from the new APK"
  if kill_shell_service; then
    section second-kill PASS "every :pocketdeck pid is gone (was ${OLD_SVC:-none})"
  else
    section second-kill FAIL "the old shell service survived kill -9: $(server_pids)"
    kill_emulator
    exit 1
  fi
  step "restarting the app on the second APK"
  if restart_server > "$OUT/share-display-second-restart.log" 2>&1; then
    section second-restart PASS "$(tail -1 "$OUT/share-display-second-restart.log")"
  else
    tail -5 "$OUT/share-display-second-restart.log" | tee -a "$LOG"
    section second-restart FAIL "restart_server (see $OUT/share-display-second-restart.log)"
    kill_emulator
    exit 1
  fi
  NEW_SVC="$(server_pid)"
  if [ -n "$NEW_SVC" ] && [ "$NEW_SVC" != "$OLD_SVC" ]; then
    section second-service PASS "shell service pid changed: ${OLD_SVC:-none} -> $NEW_SVC"
  else
    section second-service FAIL "the shell service pid did not change: ${NEW_SVC:-none} (was ${OLD_SVC:-none})"
    kill_emulator
    exit 1
  fi
  if service_maps_check > "$OUT/share-display-second-maps.log" 2>&1; then
    section second-maps PASS "$(tail -1 "$OUT/share-display-second-maps.log")"
  else
    cat "$OUT/share-display-second-maps.log" | tee -a "$LOG"
    section second-maps FAIL "the shell service does not map the new base.apk (see share-display-second-maps.log)"
    kill_emulator
    exit 1
  fi
  ensure_forward >/dev/null || { section second-forward FAIL "ensure_forward"; kill_emulator; exit 1; }
  section second-forward PASS "adb forward tcp:$PORT"
  if connect_until; then
    section second-pair PASS "a session with the phone on the second APK"
  else
    tail -5 "$OUT/share-display-pair.log" | tee -a "$LOG"
    section second-pair FAIL "no session on the second APK (see $OUT/share-display-pair.log)"
    kill_emulator
    exit 1
  fi

  run_phase after

  # The proof: the bug shows on the first APK (the first APK is main or a
  # build of it) and is gone on the second (the fix), in the same boot.
  if [ "$BEFORE_BUG_FAILURES" -ge 1 ] && [ "$AFTER_BUG_FAILURES" -eq 0 ] \
      && [ "$AFTER_FAILURES" -eq 0 ]; then
    section proof PASS "before: $BEFORE_BUG_FAILURES share section(s) failed; after: none" \
      "(before $BEFORE_FAILURES, after $AFTER_FAILURES section(s) overall)"
  else
    section proof FAIL "before: $BEFORE_BUG_FAILURES share section(s) failed, $BEFORE_FAILURES overall;" \
      "after: $AFTER_BUG_FAILURES share section(s), $AFTER_FAILURES overall (want before >= 1, after 0)"
  fi
else
  # A single-APK run is a check of that build alone.
  section proof PASS "single APK: $PHASE_FAILURES failing section(s) in the last phase (no before/after pair)"
fi

emu logcat -d -s ShareDebug:I PocketDeckSvc:I 2>/dev/null | tr -d '\r' > "$OUT/share-display-logcat.txt" || true
printf 'SECTION logcat INFO %s lines in %s\n' \
  "$(wc -l < "$OUT/share-display-logcat.txt" | tr -d ' ')" "share-display-logcat.txt" | tee -a "$LOG"

kill_emulator
if [ -n "$SECOND_APK" ]; then
  # In the pair mode only the proof decides: the before's failures are the
  # expected bug, not a failure of the check.
  grep -q '^SECTION proof PASS' "$LOG" && exit 0
  exit 1
fi
exit "$FAILED"
