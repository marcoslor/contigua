#!/usr/bin/env bash
# ISS-27 / SHARE-19: reading the phone's clipboard must never wipe it, and the
# helper must start under both `su` syntaxes.
#
#   bash tools/emulator/clip-root.sh --check    rehearsal: no device, no boot
#   ~/dev/contigua/.agent/heavy.sh bash tools/emulator/clip-root.sh
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
#   3. observe (review answer 2026-11-04): the life APK, ready, then 30 s of
#      quiet with one /proc scan a second and nothing else; the helper's pids
#      and lifetimes, the logcat +/- 2 s around every death (and dmesg), and one
#      snapshot of the helper's, its parent's and the server's cgroup, SELinux
#      context, uid/gid/groups and oom_score_adj. Finds the outside killer.
#   4. life APK (this branch), still uid 0, with a 2 s healthy window from a
#      debug property set for this boot: the helper is ready (form 2), the
#      server's and helper's /proc/<pid>/oom_score_adj are printed, `kill -9`
#      the helper and it is ready again within the backoff, and a copy after
#      that reaches clip.set once with its length. The state lines are printed.
#   5. fixed APK, no root (the normal start, uid 2000): one clip.set, no wipe
#      lines, the clip still present; the helper is not started at all.
# Then adb unroot and emu kill. Never prints clipboard text, only lengths.
# Every adb call is logged with a timestamp to $OUT/adb.log; the copy text and
# the APK paths are redacted there (lengths only, per the task's privacy rule).
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) echo "clip-root.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export CONTIGUA_PORT="${CONTIGUA_PORT:-47992}"
export CONTIGUA_SERIAL=emulator-5554
export CONTIGUA_AGENT_DIR="$PWD/.agent/clip-life/emu"
mkdir -p "$CONTIGUA_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$CONTIGUA_AGENT_DIR"
LOG="$OUT/clip-root.log"
APK_BUILD="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
APK_MAIN="$PWD/.agent/clip-su/app-debug-main.apk"
APK_FIXED="$PWD/.agent/clip-su/app-debug-fixed.apk"
APK_LIFE="$PWD/.agent/clip-life/app-debug-life.apk"
STATE="$CACHE_DIR/deckctl-state.json"
PKG=app.contigua
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
HEALTHY_PROP=debug.contigua.clip_healthy_ms
HEALTHY_MS=2000
FAILED=0

# The audit trail the reviewer asked for: every adb call, timestamped. Test
# copy text and APK paths are redacted (the task says lengths only and never
# the APK path or the command line); the shape and timing stay.
ADB_LOG="$OUT/adb.log"
redact_adb() {
  printf '%s' "$*" |
    sed -E -e 's#--es text [^ ]*#--es text <text>#g' -e 's#/Users/[^ ]*\.apk#<apk>#g'
}
log_adb() {
  printf '[%s] adb -s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$SERIAL" "$(redact_adb "$@")" >> "$ADB_LOG"
}
adb_direct() { log_adb "$@"; "$ADB" -s "$SERIAL" "$@"; }
emu() { log_adb "$@"; timeout "${ADB_TIMEOUT:-20}" "$ADB" -s "$SERIAL" "$@"; }
emu_long() { log_adb "$@"; timeout "${ADB_LONG_TIMEOUT:-600}" "$ADB" -s "$SERIAL" "$@"; }

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
  line="$(emu shell "ps -A -o USER,PID,NAME 2>/dev/null | grep 'app.contigua:contigua' | head -1" 2>/dev/null |
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
  emu shell "pkill -f app.contigua:contigua" >/dev/null 2>&1 || true
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
  emu shell "pkill -f app.contigua:contigua" >/dev/null 2>&1 || true
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
  emu logcat -d -s ContiguaSvc:I 2>/dev/null | grep 'cliphelper:' | tr -d '\r' || true
}

ready_form() { # ready_form <helper lines>
  printf '%s\n' "$1" |
    grep -o 'ready([0-9][0-9]*, form [0-9][0-9]*)' |
    tail -1 | sed 's/.*form \([0-9][0-9]*\))/\1/' || true
}

# The helper's pid, found by its command line: `app_process` carries no name of
# its own that ps would show unambiguously. The bracket keeps grep from matching
# its own (or the adb shell's) command line, which carries the same text.
helper_pid() {
  emu shell 'for p in $(grep -l "ClipHelperMai[n]" /proc/[0-9]*/cmdline 2>/dev/null); do p=${p#/proc/}; p=${p%/cmdline}; echo "$p"; break; done' 2>/dev/null |
    tr -d '\r' | head -1
}

proc_value() { # proc_value <pid> <file under /proc/<pid>>
  emu shell "cat /proc/$1/$2 2>/dev/null" 2>/dev/null | tr -d '\r' | head -1
}

now_ms() {
  "$PYTHON" -c 'import time; print(int(time.monotonic() * 1000))'
}

# One line per process: pid, PPid/Uid/Gid/Groups, oom_score_adj, cgroup and
# SELinux context. One adb call, so a link reads all of it or none.
proc_snapshot() { # proc_snapshot <pid>
  emu shell "p=$1; echo pid=\$p; awk '/^(PPid|Uid|Gid|Groups):/{printf \"%s \", \$0}' /proc/\$p/status 2>/dev/null; echo; echo oom=\$(cat /proc/\$p/oom_score_adj 2>/dev/null); echo cgroup=\$(cat /proc/\$p/cgroup 2>/dev/null | tr '\n' ','); echo selinux=\$(cat /proc/\$p/attr/current 2>/dev/null)" \
    2>/dev/null | tr -d '\r' | tr '\n' ' ' | tr -s ' '
}

# Phase 3: the killer hunt (review answer 2026-11-04). From the moment the
# helper is ready, 30 s with no rig activity but one /proc scan a second: the
# pids and their lifetimes, logcat (+/- 2 s around every death) and dmesg, and
# one snapshot of the helper, its parent and the server. Names the outside
# killer (or says there was none in the window) before the life phase runs.
observe_phase() {
  local watch="$OUT/observe-watch.txt" watch_pid form helper server parent snap
  local samples="$OUT/observe-samples.txt" lifetimes="$OUT/observe-lifetimes.txt"
  local dmesg="$OUT/observe-dmesg.txt" line t0 t1 i pid last gone lo hi w deaths matches pids n t named
  : > "$samples"
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
    fail "observe: clip-watch did not enable the gate"
    return 1
  fi
  form=""; helper=""
  for _ in $(seq 1 40); do
    form="$(ready_form "$(helper_lines)")"
    helper="$(helper_pid)"
    [ -n "$form" ] && [ -n "$helper" ] && break
    sleep 1
  done
  if [ -z "$form" ] || [ -z "$helper" ]; then
    kill "$watch_pid" 2>/dev/null || true
    fail "observe: the helper never reached ready"
    return 1
  fi
  step "observe: helper ready (form $form, pid $helper); 30 s quiet, one /proc scan a second"
  snap=""
  for _ in $(seq 1 8); do
    helper="$(helper_pid)"
    if [ -n "$helper" ]; then
      snap="$(proc_snapshot "$helper")"
      case "$snap" in *Uid:*) break;; esac
    fi
    sleep 1
  done
  printf 'OBSERVE ready form=%s epoch=%s\n' "$form" \
    "$(emu shell 'date +%s' | tr -d '\r')" | tee -a "$LOG"
  printf 'OBSERVE proc helper %s\n' "$snap" | tee -a "$LOG"
  parent="$(printf '%s' "$snap" | sed -n 's/.*PPid: \([0-9][0-9]*\).*/\1/p' | head -1)"
  if [ -n "$parent" ]; then
    printf 'OBSERVE proc parent %s\n' "$(proc_snapshot "$parent")" | tee -a "$LOG"
  fi
  server="$(service_line | awk '{print $2}')"
  if [ -n "$server" ]; then
    printf 'OBSERVE proc server %s\n' "$(proc_snapshot "$server")" | tee -a "$LOG"
  fi

  # The quiet window: no copies, no am start, no kill: one scan a second.
  t0="$(now_ms)"
  for i in $(seq 1 32); do
    line="$(emu shell 'date +%s; for f in $(grep -l "ClipHelperMai[n]" /proc/[0-9]*/cmdline 2>/dev/null); do f=${f#/proc/}; echo "${f%/cmdline}"; done' \
      2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    printf '%s\n' "$line" >> "$samples"
    sleep 1
  done
  t1="$(now_ms)"

  awk '
    {
      t = $1
      split("", cur)
      for (i = 2; i <= NF; i++) {
        p = $i
        cur[p] = 1
        if (!(p in first)) { first[p] = t; order[++n] = p }
        last[p] = t
      }
      for (p in seen) if (!(p in cur) && !(p in gone)) gone[p] = t
      for (p in cur) seen[p] = 1
    }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        printf "OBSERVE helper pid=%s first_seen=%s last_seen=%s gone=%s\n",
          p, first[p], last[p], (p in gone ? gone[p] : "alive")
      }
    }
  ' "$samples" > "$lifetimes"
  tee -a "$LOG" < "$lifetimes"

  emu logcat -b all -v epoch -d > "$OUT/observe-logcat.txt" 2>/dev/null || true
  [ -s "$OUT/observe-logcat.txt" ] || emu logcat -v epoch -d > "$OUT/observe-logcat.txt" 2>/dev/null || true
  emu shell dmesg > "$dmesg" 2>/dev/null || true
  [ -s "$dmesg" ] || emu shell 'su 0 dmesg' > "$dmesg" 2>/dev/null || true

  deaths=0
  while IFS= read -r line; do
    case "$line" in *gone=alive*) continue;; esac
    pid="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p')"
    last="$(printf '%s' "$line" | sed -n 's/.*last_seen=\([0-9][0-9]*\).*/\1/p')"
    gone="$(printf '%s' "$line" | sed -n 's/.*gone=\([0-9][0-9]*\).*/\1/p')"
    [ -n "$pid" ] && [ -n "$last" ] && [ -n "$gone" ] || continue
    deaths=$((deaths + 1))
    lo=$((last - 2)); hi=$((gone + 2))
    w="$OUT/observe-pid-$pid.logcat.txt"
    awk -v lo="$lo" -v hi="$hi" '($1 + 0) >= lo && ($1 + 0) <= hi' \
      "$OUT/observe-logcat.txt" > "$w"
    printf 'OBSERVE death pid=%s between=%s..%s logcat_lines=%s\n' "$pid" "$last" "$gone" \
      "$(wc -l < "$w" | tr -d ' ')" | tee -a "$LOG"
  done < "$lifetimes"

  # Every death the logcat saw in the window gets its own +/- 2 s window, so a
  # death between two samples is not lost.
  n=0
  grep -E 'cliphelper: .*--died\(' "$OUT/observe-logcat.txt" | while IFS= read -r line; do
    t="$(printf '%s' "$line" | awk '{print $1}')"
    case "$t" in ''|*[!0-9.]*) continue;; esac
    n=$((n + 1))
    lo=$(( ${t%%.*} - 2 )); hi=$(( ${t%%.*} + 2 ))
    w="$OUT/observe-logcat-death-$n.txt"
    awk -v lo="$lo" -v hi="$hi" '($1 + 0) >= lo && ($1 + 0) <= hi' \
      "$OUT/observe-logcat.txt" > "$w"
    printf 'OBSERVE logcat death at=%s window=%s..%s lines=%s\n' "$t" "$lo" "$hi" \
      "$(wc -l < "$w" | tr -d ' ')" | tee -a "$LOG"
    matches="$(grep -E "am_kill|lowmemorykiller|lmkd|PhantomProcess|Killing|init:|avc:|SIGKILL|--died\(" "$w" | head -20)"
    if [ -n "$matches" ]; then
      printf '%s\n' "$matches" | tee -a "$LOG"
    else
      printf 'OBSERVE logcat death at=%s: no matching line\n' "$t" | tee -a "$LOG"
    fi
  done

  # Anything naming a helper pid anywhere in the window: its own log lines, or
  # a killer's line.
  for pid in $(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$lifetimes" | sort -u); do
    named="$(awk -v p="$pid" '$2 == p' "$OUT/observe-logcat.txt" | head -8)"
    if [ -n "$named" ]; then
      printf 'OBSERVE pid=%s named in logcat:\n%s\n' "$pid" "$named" | tee -a "$LOG"
    fi
  done

  if [ -s "$dmesg" ]; then
    printf 'OBSERVE dmesg lines=%s\n' "$(wc -l < "$dmesg" | tr -d ' ')" | tee -a "$LOG"
    pids="$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' "$lifetimes" | paste -sd'|' -)"
    if [ -n "$pids" ]; then
      grep -E "am_kill|lowmemorykiller|lmkd|PhantomProcess|Killing|init:|avc:|SIGKILL|($pids)([^0-9]|$)" "$dmesg" |
        head -20 | tee -a "$LOG"
    fi
  else
    printf 'OBSERVE dmesg unreadable even as root\n' | tee -a "$LOG"
  fi

  printf 'OBSERVE quiet span=%sms sampled_deaths=%s sigkill_deaths=%s helper_pids=%s\n' \
    "$((t1 - t0))" "$deaths" "$(grep -c 'cliphelper: .*died(exit 137' "$OUT/observe-logcat.txt" || true)" \
    "$(grep -c 'pid=' "$lifetimes" || true)" | tee -a "$LOG"
  printf 'OBSERVE helper lines with a SIGKILL death:\n%s\n' \
    "$(helper_lines | grep 'exit 137' | head -12 || true)" | tee -a "$LOG"

  kill "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
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
  kill_at="$(now_ms)"
  killed=""
  for _ in $(seq 1 20); do
    killed="$(emu shell 'for p in $(grep -l "ClipHelperMai[n]" /proc/[0-9]*/cmdline 2>/dev/null); do p=${p#/proc/}; p=${p%/cmdline}; kill -9 "$p" && echo "$p"; break; done' 2>/dev/null |
      tr -d '\r' | head -1)"
    [ -n "$killed" ] && break
    sleep 0.5
  done
  PHASE_KILLED_PID="${killed:-none}"
  if [ -z "$killed" ]; then
    fail "phase $name: could not kill -9 the helper"
  fi
  # `--> ready(` counts transitions into ready; a Died line also carries the
  # word `ready(...)` and made the old count look like an instant recovery.
  before_ready="$(helper_lines | grep -c -- '--> ready(' || true)"
  ready_at=""
  for _ in $(seq 1 40); do
    after_ready="$(helper_lines | grep -c -- '--> ready(' || true)"
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
  : > "$ADB_LOG"
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
  if adb_direct devices 2>/dev/null | grep -q "^$SERIAL[[:space:]]"; then
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

adb_direct devices 2>/dev/null | grep -q "^$SERIAL[[:space:]]" &&
  die "$SERIAL already running: refusing to touch it"
[ -f "$APK_MAIN" ] || die "no $APK_MAIN"
[ -f "$APK_FIXED" ] || die "no $APK_FIXED"
[ -f "$APK_LIFE" ] || die "no $APK_LIFE"
WANT_CODE="$(apk_version_code "$APK_FIXED")"
[ -n "$WANT_CODE" ] || die "cannot read the fixed APK's versionCode"

cleanup() {
  adb_direct unroot >/dev/null 2>&1 || true
  adb_direct emu kill >/dev/null 2>&1 || true
}
trap cleanup EXIT

: > "$ADB_LOG"
{
  echo "=== clip-root started $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "commit $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
  echo "adb audit: $ADB_LOG"
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
observe_phase
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
