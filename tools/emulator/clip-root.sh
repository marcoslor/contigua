#!/usr/bin/env bash
# ISS-27 / SHARE-19: reading the phone's clipboard must never wipe it, and the
# helper must start under both `su` syntaxes.
#
#   bash tools/emulator/clip-root.sh --check    rehearsal: no device, no boot
#   ~/dev/pocketdeck/.agent/heavy.sh bash tools/emulator/clip-root.sh
#
# ONE emulator boot. The APKs must already be built with the Docker K1
# (`k1-docker.sh <android> :app:assembleDebug`):
#   .agent/clip-su/app-debug-main.apk    built from the branch point
#   .agent/clip-su/app-debug-fixed.apk   built from this branch
#   .agent/clip-life/app-debug-life.apk  built from fix/clip-life
# start.sh runs with --no-build so no JVM ever runs on the host.
#
# Phases, all on emulator-5554:
#   1. main APK, with root privileges (uid 0): copy from a focused app, 30 s of
#      image-poll ticks + the text listener. The helper never answers ready
#      (main only knows `su 2000 -c`), so expect 0 wipe lines and no clip.set.
#   2. fixed APK, still uid 0: form 1 dies before ready, form 2 answers ready.
#      Expect 0 wipe lines, one clip.set of the right length, the clip still
#      present 5 s later, and `ready(..., form 2)` in the helper's state lines.
#   3. life APK (this branch), still uid 0, with a 2 s healthy window from a
#      debug property set for this boot: the helper is ready (form 2), the
#      server's and helper's /proc/<pid>/oom_score_adj are printed, `kill -9`
#      the helper and it is ready again within the backoff, and a copy after
#      that reaches clip.set once with its length. The state lines are printed.
#   4. fixed APK, no root (the normal start, uid 2000): one clip.set, no wipe
#      lines, the clip still present; the helper is not started at all.
# Then adb unroot and emu kill. Never prints clipboard text, only lengths.
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "clip-root.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47992}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/clip-life/emu"
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
LOG="$OUT/clip-root.log"
APK_BUILD="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
APK_MAIN="$PWD/.agent/clip-su/app-debug-main.apk"
APK_FIXED="$PWD/.agent/clip-su/app-debug-fixed.apk"
APK_LIFE="$PWD/.agent/clip-life/app-debug-life.apk"
STATE="$CACHE_DIR/deckctl-state.json"
PKG=dev.pocketdeck
ACT="$PKG/.app.PasteDebugActivity"
# A made-up, contentless copy: only its length is ever reported.
TEST_TEXT="$(printf '%*s' 24 '' | tr ' ' 'q')"
TEST_LEN=${#TEST_TEXT}
# A second, different made-up copy for the phase after the kill, so the Mac
# never drops it as an echo of the first.
TEST_LIFE_TEXT="$(printf '%*s' 31 '' | tr ' ' 'z')"
TEST_LIFE_LEN=${#TEST_LIFE_TEXT}
# Debug-only: this boot's helper refills its restarts after 2 s ready, so the
# guest's own kills cannot spend the budget mid-phase. Shipped builds ignore it.
HEALTHY_PROP=debug.pocketdeck.clip_healthy_ms
HEALTHY_MS=2000
FAILED=0

fail() { printf 'SECTION %s FAIL\n' "$*" | tee -a "$LOG"; FAILED=1; }
ok() { printf 'SECTION %s PASS\n' "$*" | tee -a "$LOG"; }

[ "$SERIAL" = "emulator-5554" ] || die "serial '$SERIAL' is not emulator-5554"

starter_path() {
  local code_path abi
  code_path="$(emu shell dumpsys package moe.shizuku.privileged.api 2>/dev/null |
    sed -n 's/.*codePath=\(.*\)$/\1/p' | head -1 | tr -d '\r')"
  abi="$(emu shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    arm64-v8a) abi=arm64 ;;
    armeabi-v7a) abi=arm ;;
  esac
  echo "$code_path/lib/$abi/libshizuku.so"
}

service_line() {
  local line
  line="$(emu shell "ps -A -o USER,PID,NAME 2>/dev/null | grep 'dev.pocketdeck:pocketdeck' | head -1" 2>/dev/null |
    tr -s ' ' | tr -d '\r' | sed 's/^ //; s/ $//')"
  echo "${line:-none}"
}

start_starter() { # start_starter <label>
  local label="$1" starter
  starter="$(starter_path)"
  [ -n "$starter" ] && emu shell "test -x $starter" >/dev/null 2>&1 ||
    { fail "starter missing for $label"; return 1; }
  emu shell "pkill -f shizuku_server" >/dev/null 2>&1 || true
  emu shell "$starter" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    emu shell "ps -A | grep -q shizuku_server" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "Shizuku did not start for $label"
  return 1
}

restart_service() { # restart_service <label>
  local label="$1"
  emu shell "pkill -f dev.pocketdeck:pocketdeck" >/dev/null 2>&1 || true
  restart_server >"$OUT/restart-$label.log" 2>&1 ||
    { fail "the shell service did not come back for $label"; return 1; }
  ensure_forward >/dev/null || { fail "cannot forward the phone port for $label"; return 1; }
  return 0
}

enter_root() {
  emu_long root >"$OUT/adb-root.txt" 2>&1 || { fail "adb root"; return 1; }
  wait_for_device 90 || { fail "no device after adb root"; return 1; }
  start_starter "root" || return 1
  step "shizuku: $(emu shell 'ps -A -o USER,PID,NAME | grep shizuku_server' | tr -s ' ' | tr -d '\r')"
  restart_service "root" || return 1
  step "service: $(service_line)"
}

enter_shell() {
  # A root Shizuku server cannot be killed by the shell user after unroot:
  # reap it (and its root user service) while adb is still root.
  emu shell "pkill -f dev.pocketdeck:pocketdeck" >/dev/null 2>&1 || true
  emu shell "pkill -f shizuku_server" >/dev/null 2>&1 || true
  emu unroot >/dev/null 2>&1 || true
  wait_for_device 90 || { fail "no device after adb unroot"; return 1; }
  start_starter "shell" || return 1
  step "shizuku: $(emu shell 'ps -A -o USER,PID,NAME | grep shizuku_server' | tr -s ' ' | tr -d '\r')"
  restart_service "shell" || return 1
  step "service: $(service_line)"
}

install_apk() { # install_apk <label> <apk>
  local label="$1" apk="$2" code
  step "installing the $label APK"
  emu_long install -r -d -g "$apk" >"$OUT/install-$label.txt" 2>&1 ||
    { fail "$label APK install"; return 1; }
  code="$(installed_version_code "$PKG")"
  [ "$code" = "$WANT_CODE" ] || { fail "$label installed versionCode $code != $WANT_CODE"; return 1; }
  restart_service "$label" || return 1
  step "service: $(service_line)"
}

helper_lines() {
  emu logcat -d -s PocketDeckSvc:I 2>/dev/null | grep 'cliphelper:' | tr -d '\r' || true
}

ready_form() { # ready_form <helper lines>
  printf '%s\n' "$1" |
    grep -o 'ready([0-9][0-9]*, form [0-9][0-9]*)' |
    tail -1 | sed 's/.*form \([0-9][0-9]*\))/\1/' || true
}

# The helper's pid, found by its command line: `app_process` carries no name of
# its own that ps would show unambiguously.
helper_pid() {
  emu shell 'for p in /proc/[0-9]*; do grep -qa ClipHelperMain "$p/cmdline" 2>/dev/null && basename "$p"; done' 2>/dev/null |
    tr -d '\r' | head -1
}

proc_value() { # proc_value <pid> <file under /proc/<pid>>
  emu shell "cat /proc/$1/$2 2>/dev/null" 2>/dev/null | tr -d '\r' | head -1
}

now_ms() {
  "$PYTHON" -c 'import time; print(int(time.monotonic() * 1000))'
}

# One measured phase. Sets PHASE_PS, PHASE_UID, PHASE_WIPES, PHASE_CLIPS,
# PHASE_CHARS, PHASE_EXISTS, PHASE_COPY, PHASE_HELPER, PHASE_FORM,
# PHASE_READY_LINES and PHASE_FORM1_LINES for the caller.
phase() {
  local name="$1"
  local watch="$OUT/$name-watch.txt"
  local watch_pid line
  : > "$watch"
  PHASE_PS=""; PHASE_UID=""; PHASE_WIPES=""; PHASE_CLIPS=""; PHASE_CHARS=""
  PHASE_EXISTS=""; PHASE_COPY=""; PHASE_HELPER=""; PHASE_FORM=""
  PHASE_READY_LINES=""; PHASE_FORM1_LINES=""
  emu logcat -c >/dev/null 2>&1 || true
  "$PYTHON" -u tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$STATE" --wait-for-free 30 clip-watch --enable --seconds 60 >"$watch" 2>&1 &
  watch_pid=$!
  for _ in $(seq 1 80); do
    grep -q 'clip.enable on' "$watch" 2>/dev/null && break
    sleep 0.5
  done
  if ! grep -q 'clip.enable on' "$watch"; then
    kill "$watch_pid" 2>/dev/null || true
    fail "phase $name: clip-watch did not enable the gate"
    return 1
  fi
  # Give a helper at uid 0 time to start; form 1 dies at once, form 2 answers.
  sleep 5

  step "phase $name: copy (length $TEST_LEN)"
  emu shell am start -W -n "$ACT" --es action copy --es text "$TEST_TEXT" \
    >"$OUT/$name-copy.txt" 2>&1 || true
  sleep 5
  emu shell am start -W -n "$ACT" --es action exists \
    >"$OUT/$name-exists.txt" 2>&1 || true
  sleep 25

  PHASE_WIPES="$(emu logcat -d 2>/dev/null | grep -c 'Could not grant permission to primary clip' || true)"
  line="$(emu logcat -d -s PasteDebug:I 2>/dev/null | grep 'clip exists=' | tail -1 | tr -d '\r')"
  case "$line" in
    *exists=true*) PHASE_EXISTS=yes ;;
    *exists=false*) PHASE_EXISTS=no ;;
    *) PHASE_EXISTS=unknown ;;
  esac
  PHASE_COPY="$(emu logcat -d -s PasteDebug:I 2>/dev/null | grep 'copy length=' | tail -1 | tr -d '\r')"
  PHASE_PS="$(service_line)"
  PHASE_UID="$(printf '%s' "$PHASE_PS" | awk '{print $1}')"
  [ -n "$PHASE_UID" ] || PHASE_UID=none

  PHASE_HELPER="$(helper_lines)"
  PHASE_FORM="$(ready_form "$PHASE_HELPER")"
  PHASE_READY_LINES="$(printf '%s\n' "$PHASE_HELPER" | grep -c 'ready(' || true)"
  PHASE_FORM1_LINES="$(printf '%s\n' "$PHASE_HELPER" | grep -c 'starting(1, form 1)' || true)"

  for _ in $(seq 1 20); do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 1
  done
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  PHASE_CLIPS="$(grep -c 'clip.set chars=' "$watch" || true)"
  PHASE_CHARS="$(sed -n 's/.*clip.set chars=\([0-9][0-9]*\).*/\1/p' "$watch" | sort -u | tr '\n' ',' | sed 's/,$//')"

  printf 'PHASE %s uid=%s ps="%s" wipes=%s clip_set=%s chars=%s exists=%s helper_form=%s ready_lines=%s form1_lines=%s %s\n' \
    "$name" "$PHASE_UID" "$PHASE_PS" "$PHASE_WIPES" "$PHASE_CLIPS" "$PHASE_CHARS" \
    "$PHASE_EXISTS" "${PHASE_FORM:-none}" "$PHASE_READY_LINES" "$PHASE_FORM1_LINES" "$PHASE_COPY" |
    tee -a "$LOG"
  if [ -n "$PHASE_HELPER" ]; then
    printf 'PHASE %s helper state lines:\n%s\n' "$name" "$PHASE_HELPER" | tee -a "$LOG"
  fi
}

# Phase 3: the life APK while root. Measures the low-memory-killer priorities
# and proves that a `kill -9` of the ready helper recovers and a later copy
# still reaches the Mac. Sets the PHASE_* values plus the two priorities.
life_phase() {
  local name=life
  local watch="$OUT/$name-watch.txt"
  local watch_pid helper server before_ready after_ready kill_at ready_at line
  local killed copy_text copy_len attempt
  : > "$watch"
  PHASE_FORM=""; PHASE_WIPES=""; PHASE_EXISTS=""; PHASE_CHARS=""; PHASE_COPY=""
  PHASE_HELPER_PID=""; PHASE_SERVER_OOM=""; PHASE_HELPER_OOM=""
  PHASE_KILLED_PID=""; PHASE_CLIPS=""; PHASE_KILL_MS=""; PHASE_LINES=""; PHASE_EXPECT_LEN=""
  PHASE_PS=""; PHASE_UID=""
  emu logcat -c >/dev/null 2>&1 || true
  "$PYTHON" -u tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$STATE" --wait-for-free 30 clip-watch --enable --seconds 120 >"$watch" 2>&1 &
  watch_pid=$!
  for _ in $(seq 1 80); do
    grep -q 'clip.enable on' "$watch" 2>/dev/null && break
    sleep 0.5
  done
  if ! grep -q 'clip.enable on' "$watch"; then
    kill "$watch_pid" 2>/dev/null || true
    fail "phase $name: clip-watch did not enable the gate"
    return 1
  fi
  for _ in $(seq 1 30); do
    [ -n "$(ready_form "$(helper_lines)")" ] && [ -n "$(helper_pid)" ] && break
    sleep 1
  done
  PHASE_FORM="$(ready_form "$(helper_lines)")"
  for _ in $(seq 1 10); do
    PHASE_PS="$(service_line)"
    helper="$(helper_pid)"
    server="$(printf '%s' "$PHASE_PS" | awk '{print $2}')"
    [ -n "$server" ] && PHASE_SERVER_OOM="$(proc_value "$server" oom_score_adj)"
    [ -n "$helper" ] && PHASE_HELPER_OOM="$(proc_value "$helper" oom_score_adj)"
    { [ -n "$PHASE_SERVER_OOM" ] && [ -n "$PHASE_HELPER_OOM" ]; } && break
    sleep 1
  done
  PHASE_UID="$(printf '%s' "$PHASE_PS" | awk '{print $1}')"
  [ -n "$PHASE_UID" ] || PHASE_UID=none
  PHASE_HELPER_PID="${helper:-none}"

  # One command finds and kills the live helper: a separate lookup and kill
  # lets the guest's own kills take the pid first.
  before_ready="$(helper_lines | grep -c 'ready(' || true)"
  kill_at="$(now_ms)"
  killed=""
  for _ in $(seq 1 20); do
    killed="$(emu shell 'for p in /proc/[0-9]*; do if grep -qa ClipHelperMain "$p/cmdline" 2>/dev/null; then pid=$(basename "$p"); kill -9 "$pid" && echo "$pid"; break; fi; done' 2>/dev/null |
      tr -d '\r' | head -1)"
    [ -n "$killed" ] && break
    sleep 0.5
  done
  PHASE_KILLED_PID="${killed:-none}"
  if [ -z "$killed" ]; then
    fail "phase $name: could not kill -9 the helper"
  fi
  ready_at=""
  for _ in $(seq 1 40); do
    after_ready="$(helper_lines | grep -c 'ready(' || true)"
    if [ "$after_ready" -gt "$before_ready" ]; then
      ready_at="$(now_ms)"
      break
    fi
    sleep 0.5
  done
  if [ -n "$ready_at" ]; then
    PHASE_KILL_MS=$((ready_at - kill_at))
  else
    fail "phase $name: the helper did not come back ready after kill -9"
  fi

  # The copy after the kill: a copy only reaches the Mac while a helper is
  # ready, so wait for one and retry with different made-up content if the
  # guest killed it mid-read (the Mac drops an identical copy as an echo).
  PHASE_CLIPS="0"
  copy_text="$TEST_LIFE_TEXT"
  copy_len=$TEST_LIFE_LEN
  for attempt in 1 2 3; do
    for _ in $(seq 1 10); do
      [ -n "$(helper_pid)" ] && break
      sleep 0.5
    done
    copy_text="$TEST_LIFE_TEXT$(printf '%*s' "$((attempt - 1))" '' | tr ' ' x)"
    copy_len=${#copy_text}
    step "phase $name: copy after the kill (length $copy_len)"
    emu shell am start -W -n "$ACT" --es action copy --es text "$copy_text" \
      >"$OUT/$name-copy.txt" 2>&1 || true
    for _ in $(seq 1 15); do
      PHASE_CLIPS="$(grep -c 'clip.set chars=' "$watch" || true)"
      [ "$PHASE_CLIPS" -ge 1 ] && break
      sleep 1
    done
    if [ "$PHASE_CLIPS" -ge 1 ]; then
      PHASE_EXPECT_LEN=$copy_len
      break
    fi
  done

  emu shell am start -W -n "$ACT" --es action exists \
    >"$OUT/$name-exists.txt" 2>&1 || true
  sleep 3

  PHASE_WIPES="$(emu logcat -d 2>/dev/null | grep -c 'Could not grant permission to primary clip' || true)"
  line="$(emu logcat -d -s PasteDebug:I 2>/dev/null | grep 'clip exists=' | tail -1 | tr -d '\r')"
  case "$line" in
    *exists=true*) PHASE_EXISTS=yes ;;
    *exists=false*) PHASE_EXISTS=no ;;
    *) PHASE_EXISTS=unknown ;;
  esac
  PHASE_COPY="$(emu logcat -d -s PasteDebug:I 2>/dev/null | grep 'copy length=' | tail -1 | tr -d '\r')"
  PHASE_LINES="$(helper_lines)"

  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  PHASE_CLIPS="$(grep -c 'clip.set chars=' "$watch" || true)"
  PHASE_CHARS="$(sed -n 's/.*clip.set chars=\([0-9][0-9]*\).*/\1/p' "$watch" | sort -u | tr '\n' ',' | sed 's/,$//')"

  printf 'PHASE %s helper_pid=%s killed_pid=%s server_oom=%s helper_oom=%s kill_ms=%s wipes=%s clip_set=%s chars=%s expected_len=%s exists=%s helper_form=%s %s\n' \
    "$name" "$PHASE_HELPER_PID" "$PHASE_KILLED_PID" "${PHASE_SERVER_OOM:-none}" "${PHASE_HELPER_OOM:-none}" \
    "${PHASE_KILL_MS:-none}" "$PHASE_WIPES" "$PHASE_CLIPS" "$PHASE_CHARS" "${PHASE_EXPECT_LEN:-none}" \
    "$PHASE_EXISTS" "${PHASE_FORM:-none}" "$PHASE_COPY" |
    tee -a "$LOG"
  printf 'PHASE %s helper lines with a SIGKILL death:\n%s\n' "$name" \
    "$(printf '%s\n' "$PHASE_LINES" | grep 'exit 137' || true)" | tee -a "$LOG"
}

check_mode() {
  : > "$LOG"
  bash -n tools/emulator/clip-root.sh || { fail "bash -n"; return 1; }
  [ -f "$APK_MAIN" ] || { fail "no $APK_MAIN"; return 1; }
  [ -f "$APK_FIXED" ] || { fail "no $APK_FIXED"; return 1; }
  [ -f "$APK_LIFE" ] || { fail "no $APK_LIFE"; return 1; }
  local main_code fixed_code life_code gradle_code
  main_code="$(apk_version_code "$APK_MAIN")"
  fixed_code="$(apk_version_code "$APK_FIXED")"
  life_code="$(apk_version_code "$APK_LIFE")"
  gradle_code="$(sed -n 's/.*versionCode = \([0-9][0-9]*\).*/\1/p' android/app/build.gradle.kts | head -1)"
  [ -n "$main_code" ] && [ "$main_code" = "$fixed_code" ] && [ "$fixed_code" = "$life_code" ] &&
    [ "$life_code" = "$gradle_code" ] ||
    { fail "versionCodes main=$main_code fixed=$fixed_code life=$life_code gradle=$gradle_code"; return 1; }
  for apk in "$APK_MAIN" "$APK_FIXED" "$APK_LIFE"; do
    "$AAPT2" dump xmltree --file AndroidManifest.xml "$apk" 2>/dev/null |
      grep -q "PasteDebugActivity" || { fail "no PasteDebugActivity in $(basename "$apk")"; return 1; }
  done
  "$PYTHON" tools/fakephone/deckctl.py clip-watch --help 2>&1 | grep -q -- '--enable' ||
    { fail "deckctl clip-watch has no --enable"; return 1; }
  cp "$APK_FIXED" "$APK_BUILD" || { fail "cannot stage the APK for preflight"; return 1; }
  bash tools/emulator/preflight.sh || { fail "preflight"; return 1; }
  local free_kb
  free_kb="$(df -k /System/Volumes/Data | awk 'NR == 2 { print $4 }')"
  [ -n "$free_kb" ] && [ "$free_kb" -ge 15728640 ] ||
    { fail "less than 15 GB free ($free_kb KB)"; return 1; }
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL[[:space:]]"; then
    fail "$SERIAL is already running; refusing to touch it"
    return 1
  fi
  ok "check: syntax, APKs (versionCode $fixed_code), debug activity, deckctl --enable, preflight, 15 GB, $SERIAL free"
  echo "CHECK OK: run without --check boots once"
}

if [ "$MODE" = "check" ]; then
  check_mode
  exit $FAILED
fi

"$ADB" devices 2>/dev/null | grep -q "^$SERIAL[[:space:]]" &&
  die "$SERIAL already running: refusing to touch it"
[ -f "$APK_MAIN" ] || die "no $APK_MAIN"
[ -f "$APK_FIXED" ] || die "no $APK_FIXED"
[ -f "$APK_LIFE" ] || die "no $APK_LIFE"
WANT_CODE="$(apk_version_code "$APK_FIXED")"
[ -n "$WANT_CODE" ] || die "cannot read the fixed APK's versionCode"

cleanup() {
  "$ADB" -s "$SERIAL" unroot >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}
trap cleanup EXIT

{
  echo "=== clip-root started $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
} > "$LOG"

# start.sh --no-build installs the APK at the canonical path.
cp "$APK_MAIN" "$APK_BUILD" || die "cannot stage the main APK"
step "booting $SERIAL with the main APK (one boot budget)"
if ! bash tools/emulator/start.sh --no-build >"$OUT/start.log" 2>&1; then
  tail -8 "$OUT/start.log" | tee -a "$LOG"
  exit 1
fi
ok "boot: $(tail -1 "$OUT/start.log")"
ensure_forward >/dev/null || die "cannot forward the phone port"

PAIR_ARGS=(--state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB")
if ! "$PYTHON" tools/emulator/poc.py "${PAIR_ARGS[@]}" pair >"$OUT/pair.log" 2>&1; then
  tail -8 "$OUT/pair.log" | tee -a "$LOG"
  fail "pairing"
  exit 1
fi
ok "pair: poc.py"

enter_root || exit 1
install_apk main "$APK_MAIN" || exit 1
phase main
MAIN_WIPES=$PHASE_WIPES
MAIN_CLIPS=$PHASE_CLIPS
MAIN_CHARS=$PHASE_CHARS
MAIN_EXISTS=$PHASE_EXISTS
MAIN_UID=$PHASE_UID
MAIN_PS=$PHASE_PS
MAIN_READY=$PHASE_READY_LINES

install_apk fixed "$APK_FIXED" || exit 1
phase fixed
FIXED_WIPES=$PHASE_WIPES
FIXED_CLIPS=$PHASE_CLIPS
FIXED_CHARS=$PHASE_CHARS
FIXED_EXISTS=$PHASE_EXISTS
FIXED_UID=$PHASE_UID
FIXED_PS=$PHASE_PS
FIXED_FORM=$PHASE_FORM
FIXED_READY=$PHASE_READY_LINES
FIXED_FORM1=$PHASE_FORM1_LINES

step "shortening the healthy window for this boot only: $HEALTHY_PROP=$HEALTHY_MS"
emu shell "setprop $HEALTHY_PROP $HEALTHY_MS" >/dev/null 2>&1 || fail "cannot set $HEALTHY_PROP"
install_apk life "$APK_LIFE" || exit 1
life_phase
LIFE_WIPES=$PHASE_WIPES
LIFE_CHARS=$PHASE_CHARS
LIFE_EXPECT_LEN=$PHASE_EXPECT_LEN
LIFE_EXISTS=$PHASE_EXISTS
LIFE_FORM=$PHASE_FORM
LIFE_UID=$PHASE_UID
LIFE_PS=$PHASE_PS
LIFE_HELPER_PID=$PHASE_HELPER_PID
LIFE_KILLED_PID=$PHASE_KILLED_PID
LIFE_SERVER_OOM=$PHASE_SERVER_OOM
LIFE_HELPER_OOM=$PHASE_HELPER_OOM
LIFE_CLIPS=$PHASE_CLIPS
LIFE_KILL_MS=$PHASE_KILL_MS
LIFE_LINES=$PHASE_LINES
emu shell "setprop $HEALTHY_PROP ''" >/dev/null 2>&1 || true

enter_shell || exit 1
phase uid2000
SHELL_WIPES=$PHASE_WIPES
SHELL_CLIPS=$PHASE_CLIPS
SHELL_CHARS=$PHASE_CHARS
SHELL_EXISTS=$PHASE_EXISTS
SHELL_UID=$PHASE_UID
SHELL_PS=$PHASE_PS
SHELL_READY=$PHASE_READY_LINES

case "$MAIN_UID" in root*) ;; *) fail "main ran as '$MAIN_UID'";; esac
case "$FIXED_UID" in root*) ;; *) fail "fixed ran as '$FIXED_UID'";; esac
case "$SHELL_UID" in shell*|u0_a*) ;; *) fail "uid2000 ran as '$SHELL_UID'";; esac

# main: the helper never answers ready, so nothing is read and nothing is sent.
[ "$MAIN_WIPES" = "0" ] || fail "main saw $MAIN_WIPES wipe lines (expected 0)"
[ "$MAIN_CLIPS" = "0" ] || fail "main sent $MAIN_CLIPS clip.set (expected 0)"
[ "$MAIN_EXISTS" = "yes" ] || fail "main clip exists=$MAIN_EXISTS (expected yes: no read may wipe it)"
[ "$MAIN_READY" = "0" ] || fail "main reached ready $MAIN_READY time(s) (expected 0)"

# fixed: form 1 dies, form 2 answers ready, one copy reaches the Mac.
[ "$FIXED_WIPES" = "0" ] || fail "fixed saw $FIXED_WIPES wipe lines (expected 0)"
[ "$FIXED_CLIPS" = "1" ] || fail "fixed sent $FIXED_CLIPS clip.set (expected 1)"
[ "$FIXED_CHARS" = "$TEST_LEN" ] || fail "fixed chars=$FIXED_CHARS (expected $TEST_LEN)"
[ "$FIXED_EXISTS" = "yes" ] || fail "fixed clip exists=$FIXED_EXISTS (expected yes)"
[ "$FIXED_FORM" = "2" ] || fail "fixed helper ready form='$FIXED_FORM' (expected 2)"
{ [ -n "$FIXED_FORM1" ] && [ "$FIXED_FORM1" -gt 0 ]; } || fail "fixed never tried form 1"
{ [ -n "$FIXED_READY" ] && [ "$FIXED_READY" -gt 0 ]; } || fail "fixed helper never reached ready"

# uid 2000: the normal start, reads directly and starts no helper.
[ "$SHELL_WIPES" = "0" ] || fail "uid2000 saw $SHELL_WIPES wipe lines (expected 0)"
[ "$SHELL_CLIPS" = "1" ] || fail "uid2000 sent $SHELL_CLIPS clip.set (expected 1)"
[ "$SHELL_CHARS" = "$TEST_LEN" ] || fail "uid2000 chars=$SHELL_CHARS (expected $TEST_LEN)"
[ "$SHELL_EXISTS" = "yes" ] || fail "uid2000 clip exists=$SHELL_EXISTS (expected yes)"
[ "$SHELL_READY" = "0" ] || fail "uid2000 started a helper (expected none)"

# life: our branch as root, form 2, a SIGKILL recovers and the next copy arrives.
case "$LIFE_UID" in root*) ;; *) fail "life ran as '$LIFE_UID'";; esac
[ "$LIFE_FORM" = "2" ] || fail "life helper ready form='$LIFE_FORM' (expected 2)"
[ "$LIFE_WIPES" = "0" ] || fail "life saw $LIFE_WIPES wipe lines (expected 0)"
[ "$LIFE_CLIPS" = "1" ] || fail "life sent $LIFE_CLIPS clip.set after the kill (expected 1)"
[ "$LIFE_CHARS" = "$LIFE_EXPECT_LEN" ] || fail "life chars=$LIFE_CHARS (expected $LIFE_EXPECT_LEN)"
[ "$LIFE_EXISTS" = "yes" ] || fail "life clip exists=$LIFE_EXISTS (expected yes)"
{ [ -n "$LIFE_HELPER_PID" ] && [ "$LIFE_HELPER_PID" != "none" ]; } || fail "life found no helper pid"
{ [ -n "$LIFE_KILLED_PID" ] && [ "$LIFE_KILLED_PID" != "none" ]; } || fail "life never killed the helper"
{ [ -n "$LIFE_KILL_MS" ] && [ "$LIFE_KILL_MS" -le 10000 ]; } ||
  fail "life came back ready in '${LIFE_KILL_MS:-never}' ms (expected at most 10000)"
[ -n "$LIFE_SERVER_OOM" ] || fail "life read no server oom_score_adj"
[ -n "$LIFE_HELPER_OOM" ] || fail "life read no helper oom_score_adj"
printf '%s\n' "$LIFE_LINES" | grep -q 'died(exit 137, form 2)' ||
  fail "life has no died(exit 137, form 2) line"
printf '%s\n' "$LIFE_LINES" | grep -q 'restarting([0-9][0-9]*, form 2)' ||
  fail "life helper did not restart after the kill"

{
  echo "SUMMARY main   uid=$MAIN_UID ps=\"$MAIN_PS\" wipes=$MAIN_WIPES clip_set=$MAIN_CLIPS exists=$MAIN_EXISTS helper=never-ready"
  echo "SUMMARY fixed  uid=$FIXED_UID ps=\"$FIXED_PS\" wipes=$FIXED_WIPES clip_set=$FIXED_CLIPS chars=$FIXED_CHARS exists=$FIXED_EXISTS helper=form-$FIXED_FORM"
  echo "SUMMARY life   uid=$LIFE_UID ps=\"$LIFE_PS\" wipes=$LIFE_WIPES clip_set=$LIFE_CLIPS chars=$LIFE_CHARS exists=$LIFE_EXISTS helper=form-$LIFE_FORM kill_ms=$LIFE_KILL_MS oom_server=$LIFE_SERVER_OOM oom_helper=$LIFE_HELPER_OOM"
  echo "SUMMARY uid2000 uid=$SHELL_UID ps=\"$SHELL_PS\" wipes=$SHELL_WIPES clip_set=$SHELL_CLIPS chars=$SHELL_CHARS exists=$SHELL_EXISTS helper=none"
} | tee -a "$LOG"

[ "$FAILED" = "0" ] && echo "CLIP-ROOT PASS" || { echo "CLIP-ROOT FAIL"; exit 1; }
