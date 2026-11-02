#!/usr/bin/env bash
# static-stall — one boot proves the still-screen heartbeat (PHONE-21).
#
# The field bug: a healthy but still app window showed "Not responding", because
# the phone's vendor encoder drops KEY_REPEAT_PREVIOUS_FRAME_AFTER on a static
# picture. A sync-frame request cannot wake it (the request waits for an input
# frame a still surface never submits), so this build sends
# `{"t":"window.still","stream":N}` once a second instead.
#
# With `debug.pocketdeck.ignore_repeat_frame=1` the server never sets the
# repeat heartbeat, so a static Settings screen produces no frames at all:
#
#   after   this branch's APK: no stall for 30 s, a `still` count of ~29 on the
#           phone and the Mac
#   stall   `debug.pocketdeck.freeze_drain=1`: the drain stops taking output,
#           so no still goes out, and the Mac says stall=1 within 1.5-2.5 s of
#           the last still
#
# The BEFORE phase is round 1's run (5.6 s stall, .agent/static-stall/); it is
# not repeated. One boot. The APK and Mac bundle are built before the boot; this
# script only installs, drives, judges and kills. Run it as
#
#   bash tools/emulator/static-stall.sh --check     # no device, no boot
#   ~/dev/pocketdeck/.agent/heavy.sh timeout 2400 bash tools/emulator/static-stall.sh
set -uo pipefail

WT="$(cd "$(dirname "$0")/../.." && pwd)"
E="$WT/.agent/static-stall"
PORT="${POCKETDECK_PORT:-47994}"
SERIAL="${POCKETDECK_SERIAL:-emulator-5554}"
export POCKETDECK_PORT="$PORT" POCKETDECK_SERIAL="$SERIAL"
export POCKETDECK_AGENT_DIR="$E"
. "$WT/tools/emulator/lib.sh"

PKG=dev.pocketdeck
PROFILE=staticstall
APP="$WT/macos/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck"
STATE="$E/chrome-state.txt"
AFTER_APK="${PD_STATIC_STALL_AFTER_APK:-$E/after-app-debug.apk}"
BUILT_APK="$WT/android/app/build/outputs/apk/debug/app-debug.apk"
APP_PID=0
FAILS=0
E2E_LOCK=/tmp/pocketdeck-e2e.lock
HOLDS_E2E=0
DOCK_DEFAULT_SET=0

say() { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
fail() { say "FAIL: $*"; FAILS=$((FAILS + 1)); }
now() { "$PYTHON" -c 'import time; print("%.3f" % time.time())'; }

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

check() {
  say "check: no device, no boot"
  [ -s "$AFTER_APK" ] || { say "missing after APK: $AFTER_APK (PD_STATIC_STALL_AFTER_APK)"; exit 1; }
  bash -n "$0" || exit 1
  [ -x "$APP" ] || say "note: the Mac bundle is built at run time ($APP)"
  say "check: OK — after=$(basename "$AFTER_APK")"
  exit 0
}

app_alive() { [ "$APP_PID" != "0" ] && kill -0 "$APP_PID" 2>/dev/null; }

stop_app() {
  if [ "$APP_PID" != "0" ]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=0
  fi
}

# The Mac app's window is real: another agent's visible e2e run could reach it
# with a real key or click (a stray ⌘W closes the window and ends the stream).
# Hold the e2e lock while a window is up, as any manual Mac run does.
acquire_e2e_lock() {
  local waited=0 holder
  until mkdir "$E2E_LOCK" 2>/dev/null; do
    holder="$(cat "$E2E_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$E2E_LOCK"
      continue
    fi
    if [ "$waited" -ge 600 ]; then
      say "the e2e lock is still held by pid ${holder:-unknown} after 10 minutes"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo $$ > "$E2E_LOCK/pid"
  HOLDS_E2E=1
}

release_e2e_lock() {
  if [ "$HOLDS_E2E" = "1" ] && [ "$(cat "$E2E_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$E2E_LOCK"
  fi
  HOLDS_E2E=0
}

cleanup() {
  stop_app
  if [ "$DOCK_DEFAULT_SET" = "1" ]; then
    defaults delete "dev.pocketdeck.mac.$PROFILE" showAppsInDock >/dev/null 2>&1 || true
    DOCK_DEFAULT_SET=0
  fi
  release_e2e_lock
  # The e2e bundle registers its Share extension when it runs (RULES 5).
  pluginkit -r "$WT/macos/build/e2e/PocketDeck.app/Contents/PlugIns/Share.appex" >/dev/null 2>&1 || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$WT/macos/build/e2e/PocketDeck.app" >/dev/null 2>&1 || true
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}

# --- the Mac app ------------------------------------------------------------

# launch_mac <tag> <args…>: the quiet e2e run (its own virtual display), pointed
# at the rig's forwarded port.
launch_mac() {
  local tag="$1"
  shift
  rm -f "$STATE"
  "$APP" --profile "$PROFILE" --background --connect "127.0.0.1:$PORT" \
    --debug-chrome-state "$STATE" "$@" \
    > "$E/app-$tag.log" 2>&1 &
  APP_PID=$!
  say "$tag: Mac app pid $APP_PID"
}

# wait_state <regex> <seconds>: the chrome-state file is rewritten on every
# change, so it is the window's own report of its picture.
wait_state() {
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ -s "$STATE" ] && grep -qE "$1" "$STATE" && return 0
    sleep 0.1
  done
  return 1
}

# watch_state <regex> <seconds> <since>: prints the seconds from <since> to the
# moment the state first appeared.
watch_state() {
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$STATE" ] && grep -qE "$1" "$STATE"; then
      "$PYTHON" -c "import time; print('%.1f' % (time.time() - $3))"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# mac_log <pid> <regex>: the app's own os_log lines (subsystem dev.pocketdeck.mac).
mac_log() {
  log show --last 6m --info --style syslog \
    --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $1" 2>/dev/null |
    grep -E "$2" || true
}

pair_mac() {
  say "pairing the Mac profile '$PROFILE' (the phone's prompt: tap Allow)"
  "$PYTHON" "$WT/tools/emulator/poc.py" --serial "$SERIAL" --adb "$ADB" \
    --addr "127.0.0.1:$PORT" wait-prompt --timeout 90 --tap-timeout 90
}

# The automatic Dock identity is a separate known bug (fix/dock-ack): a shim it
# launches misses the host's single `opened` answer, quits itself 30 s later, and
# the Quit ↔ close rule closes the window under the watch. The rig has no reason
# to show phone apps in the Dock, so it turns the setting off for its profile
# and restores it in cleanup. Turn it back on once fix/dock-ack is merged.
disable_dock_auto() {
  defaults write "dev.pocketdeck.mac.$PROFILE" showAppsInDock -bool NO || return 1
  DOCK_DEFAULT_SET=1
  [ "$(defaults read "dev.pocketdeck.mac.$PROFILE" showAppsInDock 2>/dev/null)" = "0" ]
}

# assert_no_dock_bound <tag>: no shim may be bound to this app's pid during the
# run (that is the other bug, and it would end the window mid-watch).
assert_no_dock_bound() {
  local lines
  lines="$(mac_log "$APP_PID" 'dock auto: bound')"
  if [ -n "$lines" ]; then
    fail "$1: the automatic Dock identity bound a shim during this run"
    printf '%s\n' "$lines" | tail -5
  fi
}

phone_stills() { # the stream's own count of sent window.still messages
  emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
    grep -c 'heartbeat: still [0-9]'
}

mac_stills() { # the Mac's count of received stills, from the debug state line
  [ -s "$STATE" ] || { echo ''; return; }
  grep -o 'stills=[0-9]*' "$STATE" | tail -1 | grep -o '[0-9]*$'
}

last_still_line() { # "<phone epoch> <n>" of the newest still-log line
  emu logcat -d -v epoch -s PocketDeckSvc:I 2>/dev/null |
    grep 'heartbeat: still ' | tail -1
}

# phone_offset <host epoch>: the phone's clock minus the host's, from a marker
# line the phone stamps itself (no cross-clock truncation).
phone_offset() {
  local host_at="$1"
  emu shell log -t PocketDeckSvc -p i "static-stall clock $host_at" >/dev/null 2>&1 || true
  "$PYTHON" - "$host_at" <<PY
import subprocess, sys
host = float(sys.argv[1])
out = subprocess.run(["$ADB", "-s", "$SERIAL", "logcat", "-d", "-v", "epoch",
                      "-s", "PocketDeckSvc:I"], capture_output=True, text=True).stdout
for line in reversed(out.splitlines()):
    if "static-stall clock" in line:
        print("%.3f" % (float(line.split()[0]) - host))
        break
else:
    print("0.000")
PY
}

# --- the phases -------------------------------------------------------------

phase_after() {
  say "=== AFTER: this branch's APK, the vendor's dropped heartbeat"
  if ! emu_long install -r -d -g "$AFTER_APK" > "$E/install-after.log" 2>&1; then
    fail "could not install the after APK (see $E/install-after.log)"; return
  fi
  # The Shizuku shell service survives a reinstall (10-28): kill it so the new
  # build's server answers.
  emu shell pkill -f "$PKG:pocketdeck" >/dev/null 2>&1 || true
  restart_server || { fail "the after build's server did not come up"; return; }
  ensure_forward >/dev/null || { fail "no port forward after the restart"; return; }
  emu shell setprop debug.pocketdeck.ignore_repeat_frame 1 >/dev/null 2>&1 || true
  [ "$(emu shell getprop debug.pocketdeck.ignore_repeat_frame | tr -d '\r')" = "1" ] ||
    { fail "the ignore-repeat property did not stick"; return; }
  emu logcat -c >/dev/null 2>&1 || true

  acquire_e2e_lock || { fail "no e2e lock"; return; }
  launch_mac after --open com.android.settings
  pair_mac || { fail "pairing the Mac app failed"; stop_app; return; }
  wait_state 'loading=0' 90 || { fail "the after window never showed a frame"; stop_app; return; }
  # Prove the new build is the server (10-28: the shell service can survive an
  # install): the new machine logs a heartbeat transition even when the
  # encoder stays silent. Without this line the old build may still be serving.
  local proved=""
  for _ in $(seq 1 150); do
    emu logcat -d -s PocketDeckSvc:I 2>/dev/null | grep -q 'heartbeat: ' && { proved=yes; break; }
    sleep 0.1
  done
  [ -n "$proved" ] || { fail "no 'heartbeat:' line: the old server may still be serving"; stop_app; return; }
  sleep 6   # let the launch's own animation settle; then the screen is still
  app_alive || { fail "the Mac app exited before the 30 s watch"; stop_app; return; }
  local start elapsed phone mac
  start="$(now)"
  say "AFTER: watching 30 s for a stall on a still screen"
  while :; do
    elapsed="$("$PYTHON" -c "import time; print('%.1f' % (time.time() - $start))")"
    "$PYTHON" -c "import sys; sys.exit(0 if $elapsed >= 30 else 1)" && break
    if [ -s "$STATE" ] && grep -q 'stall=1' "$STATE"; then
      fail "the fixed build stalled at ${elapsed}s on a still screen"
      emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-after.txt" 2>/dev/null || true
      grep -E 'heartbeat|no repeat' "$E/logcat-after.txt" | tail -20 || true
      stop_app
      return
    fi
    sleep 0.25
  done
  app_alive || fail "the Mac app exited during the 30 s watch"
  assert_no_dock_bound "AFTER"
  phone="$(phone_stills)"
  mac="$(mac_stills)"
  say "AFTER: no stall for 30 s; stills phone=$phone mac=$mac"
  grep -q 'stall=0' "$STATE" || fail "the state file lost stall=0"
  case "$phone" in
    ''|*[!0-9]*) fail "no still count on the phone" ;;
    *) [ "$phone" -ge 25 ] && [ "$phone" -le 35 ] || fail "phone stills $phone is not about 29" ;;
  esac
  case "$mac" in
    ''|*[!0-9]*) fail "no still count on the Mac" ;;
    *) [ "$mac" -ge 25 ] && [ "$mac" -le 35 ] || fail "Mac stills $mac is not about 29" ;;
  esac
  emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-after.txt" 2>/dev/null || true
  say "AFTER RESULT: done (the window stays open for the stall phase)"
}

phase_stall() {
  say "=== STALL: a frozen drain must still reach the Mac's rule"
  local offset
  offset="$(phone_offset "$(now)")"
  say "phone clock offset ${offset}s"
  emu shell setprop debug.pocketdeck.freeze_drain 1 >/dev/null 2>&1 || true
  [ "$(emu shell getprop debug.pocketdeck.freeze_drain | tr -d '\r')" = "1" ] ||
    { fail "the freeze property did not stick"; stop_app; return; }
  app_alive || { fail "the Mac app is gone before the stall phase"; stop_app; return; }
  local frozen at last_phone last_count delta
  frozen="$(now)"
  if ! at="$(watch_state 'stall=1' 20 "$frozen")"; then
    fail "a frozen drain never stalled"
    app_alive || say "the Mac app had exited"
    emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-stall.txt" 2>/dev/null || true
    mac_log "$APP_PID" 'stall|still|closed' | tail -5
    stop_app
    return
  fi
  read -r last_phone last_count <<< "$(last_still_line)"
  [ -n "${last_phone:-}" ] || { fail "no still to measure from"; stop_app; return; }
  delta="$("$PYTHON" -c "print('%.1f' % (($frozen + $at) - ($last_phone - $offset)))")"
  say "STALL: stall=1 ${at}s after the freeze, ${delta}s after the last still (count=$last_count)"
  grep -q 'stall=1' "$STATE" || fail "the state file does not say stall=1"
  "$PYTHON" -c "import sys; sys.exit(0 if 1.5 <= $delta <= 2.5 else 1)" ||
    fail "the stall came ${delta}s after the last still, outside 1.5-2.5 s"
  mac_log "$APP_PID" 'stall=1' | tail -1
  assert_no_dock_bound "STALL"
  emu logcat -d -v time -s PocketDeckSvc:I > "$E/logcat-stall.txt" 2>/dev/null || true
  stop_app
  say "STALL RESULT: done"
}

main() {
  case "${1:-}" in
    --check) check ;;
    -h|--help) usage ;;
    "") ;;
    *) say "unknown argument: $1"; usage ;;
  esac

  mkdir -p "$E"
  trap cleanup EXIT

  if [ ! -x "$APP" ]; then
    say "building the e2e Mac bundle"
    bash "$WT/macos/scripts/bundle.sh" "$WT/macos/build/e2e/PocketDeck.app" --variant e2e ||
      { say "the Mac bundle did not build"; exit 1; }
  fi

  # A clean profile: the first launch pairs (and must), the rest reuse the pins.
  defaults delete "dev.pocketdeck.mac.$PROFILE" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Application Support/PocketDeck-$PROFILE"
  disable_dock_auto || { say "could not turn the Dock identity off for this profile"; exit 1; }

  say "staging the after APK as the boot's own APK"
  cp "$AFTER_APK" "$BUILT_APK" || { say "cannot stage the after APK"; exit 1; }

  say "booting the rig (the one boot)"
  bash "$WT/tools/emulator/start.sh" --no-build || { say "the rig did not boot"; exit 1; }
  ensure_forward >/dev/null || { say "no port forward"; exit 1; }
  say "rig: Android $(emu shell getprop ro.build.version.release | tr -d '\r') api $(emu shell getprop ro.build.version.sdk | tr -d '\r'), forward $PORT"

  phase_after
  if [ "$FAILS" -eq 0 ]; then
    phase_stall
  else
    say "skipping the stall phase: the after phase failed"
  fi

  say "-------------------------------------------"
  if [ "$FAILS" -eq 0 ]; then
    say "RESULT: PASS (30 s still with no stall, a frozen drain stalled)"
  else
    say "RESULT: FAIL ($FAILS)"
  fi
  exit $([ "$FAILS" -eq 0 ] && echo 0 || echo 1)
}

main "$@"
