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
# start.sh runs with --no-build so no JVM ever runs on the host.
#
# Phases, all on emulator-5554:
#   1. main APK, with root privileges (uid 0): copy from a focused app, 30 s of
#      image-poll ticks + the text listener. The helper never answers ready
#      (main only knows `su 2000 -c`), so expect 0 wipe lines and no clip.set.
#   2. fixed APK, still uid 0: form 1 dies before ready, form 2 answers ready.
#      Expect 0 wipe lines, one clip.set of the right length, the clip still
#      present 5 s later, and `ready(..., form 2)` in the helper's state lines.
#   3. fixed APK, no root (the normal start, uid 2000): one clip.set, no wipe
#      lines, the clip still present; the helper is not started at all.
# Then adb unroot and emu kill. Never prints clipboard text, only lengths.
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "clip-root.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47992}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/clip-su/emu"
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
LOG="$OUT/clip-root.log"
APK_BUILD="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
APK_MAIN="$PWD/.agent/clip-su/app-debug-main.apk"
APK_FIXED="$PWD/.agent/clip-su/app-debug-fixed.apk"
STATE="$CACHE_DIR/deckctl-state.json"
PKG=dev.pocketdeck
ACT="$PKG/.app.PasteDebugActivity"
# A made-up, contentless copy: only its length is ever reported.
TEST_TEXT="$(printf '%*s' 24 '' | tr ' ' 'q')"
TEST_LEN=${#TEST_TEXT}
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

check_mode() {
  : > "$LOG"
  bash -n tools/emulator/clip-root.sh || { fail "bash -n"; return 1; }
  [ -f "$APK_MAIN" ] || { fail "no $APK_MAIN"; return 1; }
  [ -f "$APK_FIXED" ] || { fail "no $APK_FIXED"; return 1; }
  local main_code fixed_code gradle_code
  main_code="$(apk_version_code "$APK_MAIN")"
  fixed_code="$(apk_version_code "$APK_FIXED")"
  gradle_code="$(sed -n 's/.*versionCode = \([0-9][0-9]*\).*/\1/p' android/app/build.gradle.kts | head -1)"
  [ -n "$main_code" ] && [ "$main_code" = "$fixed_code" ] && [ "$fixed_code" = "$gradle_code" ] ||
    { fail "versionCodes main=$main_code fixed=$fixed_code gradle=$gradle_code"; return 1; }
  for apk in "$APK_MAIN" "$APK_FIXED"; do
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

{
  echo "SUMMARY main   uid=$MAIN_UID ps=\"$MAIN_PS\" wipes=$MAIN_WIPES clip_set=$MAIN_CLIPS exists=$MAIN_EXISTS helper=never-ready"
  echo "SUMMARY fixed  uid=$FIXED_UID ps=\"$FIXED_PS\" wipes=$FIXED_WIPES clip_set=$FIXED_CLIPS chars=$FIXED_CHARS exists=$FIXED_EXISTS helper=form-$FIXED_FORM"
  echo "SUMMARY uid2000 uid=$SHELL_UID ps=\"$SHELL_PS\" wipes=$SHELL_WIPES clip_set=$SHELL_CLIPS chars=$SHELL_CHARS exists=$SHELL_EXISTS helper=none"
} | tee -a "$LOG"

[ "$FAILED" = "0" ] && echo "CLIP-ROOT PASS" || { echo "CLIP-ROOT FAIL"; exit 1; }
