#!/usr/bin/env bash
# ISS-27 / SHARE-19: reading the phone's clipboard must never wipe it.
#
#   bash tools/emulator/clip-root.sh --check    rehearsal: no device, no boot
#   ~/dev/pocketdeck/.agent/heavy.sh bash tools/emulator/clip-root.sh
#
# ONE emulator boot. The APKs must already be built with the Docker K1
# (`k1-docker.sh <android> :app:assembleDebug`):
#   .agent/clip-root/app-debug-main.apk    built from the branch point
#   .agent/clip-root/app-debug-fixed.apk   built from this branch
# start.sh runs with --no-build so no JVM ever runs on the host.
#
# Phases, all on emulator-5554:
#   1. main APK, with root privileges (uid 0): copy from a focused app, 30 s of
#      image-poll ticks + the text listener. Expect wipe lines and no clip.set.
#   2. fixed APK, still uid 0. Expect 0 wipe lines, one clip.set of the right
#      length, the clip still present 5 s later.
#   3. fixed APK, no root (the normal start, uid 2000): the same expectations.
# Then adb unroot and emu kill. Never prints clipboard text, only lengths.
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "clip-root.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47993}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/clip-root/emu"
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
LOG="$OUT/clip-root.log"
APK_BUILD="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
APK_MAIN="$PWD/.agent/clip-root/app-debug-main.apk"
APK_FIXED="$PWD/.agent/clip-root/app-debug-fixed.apk"
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
    tr -s ' ' | tr -d '\r')"
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

install_fixed() {
  step "installing the fixed APK"
  emu_long install -r -d -g "$APK_FIXED" >"$OUT/install-fixed.txt" 2>&1 ||
    { fail "fixed APK install"; return 1; }
  local code
  code="$(installed_version_code "$PKG")"
  [ "$code" = "$WANT_CODE" ] || { fail "installed versionCode $code != $WANT_CODE"; return 1; }
  restart_service "fixed" || return 1
  step "service: $(service_line)"
}

# One measured phase. Sets PHASE_WIPES, PHASE_CLIPS, PHASE_CHARS, PHASE_EXISTS,
# PHASE_UID and PHASE_COPY for the caller.
phase() {
  local name="$1"
  local watch="$OUT/$name-watch.txt"
  local i line
  : > "$watch"
  PHASE_WIPES=""; PHASE_CLIPS=""; PHASE_CHARS=""; PHASE_EXISTS=""; PHASE_UID=""; PHASE_COPY=""
  emu logcat -c >/dev/null 2>&1 || true
  "$PYTHON" -u tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$STATE" --wait-for-free 30 clip-watch --enable --seconds 40 >"$watch" 2>&1 &
  local watch_pid=$!
  for _ in $(seq 1 80); do
    grep -q 'clip.enable on' "$watch" 2>/dev/null && break
    sleep 0.5
  done
  if ! grep -q 'clip.enable on' "$watch"; then
    kill "$watch_pid" 2>/dev/null || true
    fail "phase $name: clip-watch did not enable the gate"
    return 1
  fi
  # Give a helper at uid 0 time to spawn and register its listener.
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
  PHASE_UID="$(service_line)"

  for _ in $(seq 1 20); do
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 1
  done
  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  PHASE_CLIPS="$(grep -c 'clip.set chars=' "$watch" || true)"
  PHASE_CHARS="$(sed -n 's/.*clip.set chars=\([0-9][0-9]*\).*/\1/p' "$watch" | sort -u | tr '\n' ',' | sed 's/,$//')"

  printf 'PHASE %s uid=%s wipes=%s clip_set=%s chars=%s exists=%s %s\n' \
    "$name" "$PHASE_UID" "$PHASE_WIPES" "$PHASE_CLIPS" "$PHASE_CHARS" "$PHASE_EXISTS" "$PHASE_COPY" |
    tee -a "$LOG"
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
phase root-before
ROOT_BEFORE_WIPES=$PHASE_WIPES
ROOT_BEFORE_CLIPS=$PHASE_CLIPS
ROOT_BEFORE_EXISTS=$PHASE_EXISTS
ROOT_BEFORE_UID=$PHASE_UID

install_fixed || exit 1
phase root-after
ROOT_AFTER_WIPES=$PHASE_WIPES
ROOT_AFTER_CLIPS=$PHASE_CLIPS
ROOT_AFTER_CHARS=$PHASE_CHARS
ROOT_AFTER_EXISTS=$PHASE_EXISTS
ROOT_AFTER_UID=$PHASE_UID

enter_shell || exit 1
phase uid2000
SHELL_WIPES=$PHASE_WIPES
SHELL_CLIPS=$PHASE_CLIPS
SHELL_CHARS=$PHASE_CHARS
SHELL_EXISTS=$PHASE_EXISTS
SHELL_UID=$PHASE_UID

case "$ROOT_BEFORE_UID" in root*) ;; *) fail "root-before ran as '$ROOT_BEFORE_UID'";; esac
case "$ROOT_AFTER_UID" in root*) ;; *) fail "root-after ran as '$ROOT_AFTER_UID'";; esac
case "$SHELL_UID" in shell*|u0_a*) ;; *) fail "uid2000 ran as '$SHELL_UID'";; esac

[ "$ROOT_BEFORE_CLIPS" = "0" ] || fail "root-before sent $ROOT_BEFORE_CLIPS clip.set (expected 0)"
[ "$ROOT_BEFORE_EXISTS" = "no" ] || fail "root-before clip exists=$ROOT_BEFORE_EXISTS (expected no)"
{ [ -n "$ROOT_BEFORE_WIPES" ] && [ "$ROOT_BEFORE_WIPES" -gt 0 ]; } || fail "root-before saw 0 wipe lines (expected some)"

[ "$ROOT_AFTER_WIPES" = "0" ] || fail "root-after saw $ROOT_AFTER_WIPES wipe lines (expected 0)"
[ "$ROOT_AFTER_CLIPS" = "1" ] || fail "root-after sent $ROOT_AFTER_CLIPS clip.set (expected 1)"
[ "$ROOT_AFTER_CHARS" = "$TEST_LEN" ] || fail "root-after chars=$ROOT_AFTER_CHARS (expected $TEST_LEN)"
[ "$ROOT_AFTER_EXISTS" = "yes" ] || fail "root-after clip exists=$ROOT_AFTER_EXISTS (expected yes)"

[ "$SHELL_WIPES" = "0" ] || fail "uid2000 saw $SHELL_WIPES wipe lines (expected 0)"
[ "$SHELL_CLIPS" = "1" ] || fail "uid2000 sent $SHELL_CLIPS clip.set (expected 1)"
[ "$SHELL_CHARS" = "$TEST_LEN" ] || fail "uid2000 chars=$SHELL_CHARS (expected $TEST_LEN)"
[ "$SHELL_EXISTS" = "yes" ] || fail "uid2000 clip exists=$SHELL_EXISTS (expected yes)"

{
  echo "SUMMARY root-before uid=$ROOT_BEFORE_UID wipes=$ROOT_BEFORE_WIPES clip_set=$ROOT_BEFORE_CLIPS exists=$ROOT_BEFORE_EXISTS"
  echo "SUMMARY root-after  uid=$ROOT_AFTER_UID wipes=$ROOT_AFTER_WIPES clip_set=$ROOT_AFTER_CLIPS chars=$ROOT_AFTER_CHARS exists=$ROOT_AFTER_EXISTS"
  echo "SUMMARY uid2000     uid=$SHELL_UID wipes=$SHELL_WIPES clip_set=$SHELL_CLIPS chars=$SHELL_CHARS exists=$SHELL_EXISTS"
} | tee -a "$LOG"

[ "$FAILED" = "0" ] && echo "CLIP-ROOT PASS" || { echo "CLIP-ROOT FAIL"; exit 1; }
