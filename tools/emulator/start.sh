#!/usr/bin/env bash
# Boot the Contigua emulator rig and leave it ready for deckctl/poc:
#
#   tools/emulator/start.sh [--window] [--no-build]
#
# Does, in order (all idempotent):
#   1. boot the AVD headless and wait for sys.boot_completed (unlocks the rig PIN
#      if a previous run set one)
#   2. install the apps: Shizuku, app.contigua (built here) and the two F-Droid
#      test apps, all cached under tools/emulator/.cache/
#   3. grant app.contigua its runtime permissions - notably the Shizuku
#      permission, which is a plain dangerous permission, so `pm grant` works
#   4. start the Shizuku server through its own native starter, as the adb shell
#      user, so the Contigua user service runs with UID 2000. This must happen
#      *after* the grant: the server snapshots each app's permission state when
#      it starts (BinderSender/ShizukuConfig), and a later grant is not picked up
#      until the server restarts.
#   5. seed the app prefs that the UI would otherwise set by hand (enabled +
#      onboarding done + a stable device id), launch the app and read the server
#      port from logcat
#   6. adb forward tcp:<CONTIGUA_PORT> -> the server port, print 127.0.0.1:<port>
#
# Run it as `bash tools/emulator/start.sh` (the exec bit is not relied on).
set -euo pipefail

WINDOW=0
NO_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --window) WINDOW=1 ;;
    --no-build) NO_BUILD=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "start.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

. "$(dirname "$0")/lib.sh"

# The emulator's console port comes from the serial, not a constant: a second
# rig (another worker's emulator-5584, or this tree's S3 boot while 5554 is
# busy) must land on its own port or adb would attach to the wrong guest.
EMU_PORT="${SERIAL#emulator-}"
case "$EMU_PORT" in
  ''|*[!0-9]*) die "serial '$SERIAL' is not an emulator-<port> serial" ;;
esac

PKG="app.contigua"
SHIZUKU_PKG="moe.shizuku.privileged.api"
BROWSER_PKG="${CONTIGUA_BROWSER:-acr.browser.lightning}"
MESSENGER_PKG="${CONTIGUA_MESSENGER:-org.fossify.messages}"
DEVICE_ID="${CONTIGUA_DEVICE_ID:-e0e0e0e0e0e0e0e0}"

[ -x "$EMULATOR" ] || die "emulator not installed - run tools/emulator/setup.sh first"

# --- 1. emulator ------------------------------------------------------------
booted() { [ "$(emu shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }

wait_boot() { # wait_boot <timeout_s>
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    booted && return 0
    sleep 3
  done
  return 1
}

if ! device_present; then
  if ps -axww -o command= | grep -E "emulator.*-avd $AVD_NAME .*-port $EMU_PORT" |
      grep -v grep >/dev/null 2>&1; then
    step "emulator already starting, waiting for $SERIAL"
  else
    GPU_ARGS="-gpu swiftshader_indirect"
    [ "$WINDOW" -eq 1 ] && GPU_ARGS=""
    ARGS="-avd $AVD_NAME -port $EMU_PORT -memory 2048 -cores 2 -no-audio -no-boot-anim -no-snapshot -no-metrics -netdelay none -netspeed full"
    [ "$WINDOW" -eq 0 ] && ARGS="$ARGS -no-window"
    step "starting $AVD_NAME on $EMU_PORT (headless=$((1 - WINDOW)))"
    # shellcheck disable=SC2086
    nohup "$EMULATOR" $ARGS $GPU_ARGS >"$AGENT_DIR/emulator.log" 2>&1 &
  fi
  wait_for_device 300 || die "emulator $SERIAL did not appear (see $AGENT_DIR/emulator.log)"
fi

step "waiting for boot"
wait_boot 420 || die "emulator did not finish booting (see $AGENT_DIR/emulator.log)"
step "booted: Android $(emu shell getprop ro.build.version.release | tr -d '\r') (api $(emu shell getprop ro.build.version.sdk | tr -d '\r'))"

# The rig is a test device: keep its screen on (lock.sh sleeps it explicitly
# when a check needs a locked phone). A sleeping screen freezes the app, and a
# frozen app never draws the pairing prompt.
emu shell "settings put system screen_off_timeout 86400000" >/dev/null 2>&1 || true

# A rig PIN set by lock.sh keeps the keyguard up across reboots, and userdata
# (including app data) is only readable after the first unlock.
if [ "$(emu shell locksettings get-disabled 2>/dev/null | tr -d '\r')" = "false" ] &&
  emu shell dumpsys window 2>/dev/null | grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true'; then
  step "device is locked, unlocking with the rig PIN"
  bash "$EMU_DIR/unlock.sh"
  # The AVD keeps userdata across boots, so a PIN lock.sh set for a check must
  # not leave every later boot at the bouncer (ISS-71). lock.sh sets it again
  # when a check needs a locked phone.
  RIG_PIN="${CONTIGUA_PIN:-1234}"
  if emu shell "locksettings clear --old $RIG_PIN" >/dev/null 2>&1; then
    step "cleared the rig PIN: the next boot starts unlocked"
  else
    step "warn: could not clear the rig PIN (the next boot may ask for it)"
  fi
fi

# --- 2. install the apps ----------------------------------------------------
package_installed() { [ -n "$(emu shell pm path "$1" 2>/dev/null | tr -d '\r')" ]; }

FRESH_APPS=""
# log_install_failure <pkg> <apk> <install output> — a failed install used to
# die with an empty reason. Log the failed command's output in full, a plain
# `adb install -r -t -g` retry, /data space and the package list, into the file
# the caller names (panel-power.sh points it at panel-power.log). Logging only:
# the boot still stops on the failure.
log_install_failure() {
  local pkg="$1" apk="$2" out="$3"
  local log="${PD_INSTALL_LOG:-$AGENT_DIR/install-failure.log}"
  {
    echo "=== start.sh: could not install $pkg"
    echo "=== adb install -r -d -g $apk"
    printf '%s\n' "$out"
    echo "=== adb install -r -t -g $apk"
    emu install -r -t -g "$apk" 2>&1
    echo "=== adb shell df /data"
    emu shell df /data 2>&1
    echo "=== adb shell pm list packages $pkg"
    emu shell pm list packages "$pkg" 2>&1
  } >> "$log" 2>&1
}

install_apk() { # install_apk <path> <pkg>
  local path="$1" pkg="$2" out
  if package_installed "$pkg"; then
    return 0
  fi
  step "installing $pkg"
  # -d: a newer build may already be on the rig (another worktree, an earlier
  # boot) and the boot budget never allows a clean second try. A downgrade is
  # accepted only when the signature matches, so an APK from this tree wins.
  if ! out="$(emu_long install -r -d -g "$path" 2>&1)"; then
    log_install_failure "$pkg" "$path" "$out"
    die "could not install $pkg (see ${PD_INSTALL_LOG:-$AGENT_DIR/install-failure.log})"
  fi
  FRESH_APPS="$FRESH_APPS $pkg"
}

SHIZUKU_APK="$FIXTURE_DIR/shizuku.apk"
if [ ! -s "$SHIZUKU_APK" ]; then
  url="$(github_release_asset "RikkaApps/Shizuku" 'release\.apk$')" || die "cannot reach the Shizuku release feed"
  [ -n "$url" ] || die "no Shizuku release APK found"
  fetch "$url" "$SHIZUKU_APK" || die "cannot download Shizuku"
fi
install_apk "$SHIZUKU_APK" "$SHIZUKU_PKG"

install_fdroid() { # install_fdroid <pkg>
  local fpkg="$1"
  local fdst="$FIXTURE_DIR/apks/${fpkg}.apk"
  mkdir -p "$FIXTURE_DIR/apks"
  if [ ! -s "$fdst" ]; then
    local furl
    furl="$(fdroid_latest_url "$fpkg")" || die "cannot resolve the latest $fpkg on f-droid.org"
    fetch "$furl" "$fdst" || die "cannot download $fpkg"
  fi
  install_apk "$fdst" "$fpkg"
}
install_fdroid "$BROWSER_PKG"
install_fdroid "$MESSENGER_PKG"

# A messaging app that is not the default SMS app opens with a "set as default"
# dialog whose buttons sit where the app's own widgets are, so give it the role
# once and the first-launch screen is deterministic.
if emu shell cmd role get-role-holders --user 0 android.app.role.SMS 2>/dev/null | grep -qx "$MESSENGER_PKG"; then
  step "SMS role already held by $MESSENGER_PKG"
else
  step "giving $MESSENGER_PKG the SMS role (removes its first-run dialog)"
  emu shell cmd role add-role-holder --user 0 android.app.role.SMS "$MESSENGER_PKG" >/dev/null 2>&1 || true
fi

warm_test_apps() {
  local pkg
  for pkg in $FRESH_APPS; do
    case "$pkg" in
      "$BROWSER_PKG"|"$MESSENGER_PKG") ;;
      *) continue ;;
    esac
    step "warming $pkg once (first launch builds its WebView/profile caches)"
    emu shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    sleep 8
    emu shell am force-stop "$pkg" >/dev/null 2>&1 || true
  done
}

if [ "$NO_BUILD" -eq 0 ]; then
  step "building :app:assembleDebug"
  (cd "$REPO_ROOT/android" && ./gradlew --console=plain -q :app:assembleDebug) || die "gradle build failed"
fi
APK="$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || die "no debug APK at $APK"
step "installing $PKG"
# -d: another epic's worktree may have left a higher versionCode on the rig and
# the boot budget never allows a second boot. A downgrade is only accepted when
# the debug signature matches, so this tree's APK always ends up installed.
if ! install_out="$(emu_long install -r -d -g "$APK" 2>&1)"; then
  log_install_failure "$PKG" "$APK" "$install_out"
  die "could not install $PKG (see ${PD_INSTALL_LOG:-$AGENT_DIR/install-failure.log})"
fi

# Fail fast and loudly: a silent downgrade failure leaves the previous build
# answering on the port, and every later check would report the wrong code.
WANT_CODE="$(apk_version_code "$APK")"
GOT_CODE="$(installed_version_code "$PKG")"
[ -n "$WANT_CODE" ] || die "cannot read the APK's versionCode (aapt2 at $AAPT2)"
[ "$GOT_CODE" = "$WANT_CODE" ] ||
  die "installed $PKG versionCode '${GOT_CODE:-none}' but the APK is '$WANT_CODE' (install -r -d did not land; check the signature and the log above)"
step "installed $PKG versionCode $GOT_CODE"

warm_test_apps

# --- 3. permissions (before the server starts, see the header) --------------
for perm in "moe.shizuku.manager.permission.API_V23" "android.permission.POST_NOTIFICATIONS"; do
  if ! emu shell pm grant "$PKG" "$perm" 2>&1 | grep -qi "error\|exception"; then
    continue
  fi
  step "warn: pm grant $perm said: $(emu shell pm grant "$PKG" "$perm" 2>&1 | tr -d '\r' | tail -1)"
done
step "runtime perms: $(emu shell dumpsys package "$PKG" | sed -n '/runtime permissions:/,/^$/p' |
  grep -E 'API_V23|POST_NOTIFICATIONS' | tr -s ' ' | tr -d '\r' | tr '\n' ' ')"

# --- 4. Shizuku server ------------------------------------------------------
# The starter (libshizuku.so) is the documented adb entry point: it kills any
# old server, finds the manager APK itself and forks app_process as UID 2000.
# Always run it, so a daemon left over from a previous install cannot survive.

# Boot 7: the starter reached ShizukuService and the server died with a
# tombstone one second later, while lmkd was killing a dozen processes. On a
# cold, memory-tight guest the server must not race a kill storm: it snapshots
# permission state when it starts. Boot completed is not enough - wait until
# lmkd has logged no kill for 15 s (cap 90 s), and say what the wait saw.
lmkd_quiet() { # lmkd_quiet <quiet_s> <cap_s> — 0 when no kill for quiet_s
  local quiet="$1" cap=$(( $(date +%s) + $2 )) now last="" quiet_until=0
  quiet_until=$(( $(date +%s) + quiet ))
  while [ "$(date +%s)" -lt "$cap" ]; do
    now="$(emu logcat -d -b main,system 2>/dev/null |
      grep -Ei 'lowmemorykiller|lmkd' | tail -1 | tr -d '\r')"
    if [ "$now" != "$last" ]; then
      last="$now"
      quiet_until=$(( $(date +%s) + quiet ))
      [ -n "$now" ] && step "lmkd: new kill line, quiet window restarts: $(printf '%s' "$now" | cut -c1-140)"
    fi
    [ "$(date +%s)" -ge "$quiet_until" ] && return 0
    sleep 2
  done
  return 1
}

SETTLE_START="$(date +%s)"
if lmkd_quiet 15 90; then
  step "guest settled: lmkd quiet for 15 s (waited $(( $(date +%s) - SETTLE_START ))s)"
else
  step "warn: lmkd not quiet after 90 s (waited $(( $(date +%s) - SETTLE_START ))s); starting the server anyway"
fi
CODE_PATH="$(emu shell dumpsys package "$SHIZUKU_PKG" 2>/dev/null |
  sed -n 's/.*codePath=\(.*\)$/\1/p' | head -1 | tr -d '\r')"
ABI="$(emu shell getprop ro.product.cpu.abi | tr -d '\r')"
case "$ABI" in
  arm64-v8a) ABI_DIR=arm64 ;;
  armeabi-v7a) ABI_DIR=arm ;;
  *) ABI_DIR="$ABI" ;;
esac
STARTER="$CODE_PATH/lib/$ABI_DIR/libshizuku.so"
emu shell "test -x $STARTER" 2>/dev/null || die "Shizuku starter $STARTER not executable"

# Shizuku user services are daemons: killing the server can leave one orphaned,
# and an orphan from an older build would keep serving the app. They run as the
# adb shell user, so the shell can reap them.
ORPHANS="$(server_pids)"
if [ -n "$ORPHANS" ]; then
  step "killing stale user-service processes:$ORPHANS"
  for pid in $ORPHANS; do
    emu shell "kill -9 $pid" >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 10); do
    [ -z "$(server_pids)" ] && break
    sleep 1
  done
  [ -z "$(server_pids)" ] || step "warn: still there:$(server_pids)"
fi

# Boot 7 lost its only boot to a one-shot race: the starter forked the server
# and lmkd took it a second later. If the first attempt leaves no
# shizuku_server, wait 10 s and run the starter once more; a second miss still
# fails, as before.
start_shizuku() { # 0 when shizuku_server survives the 30 s wait
  emu shell "$STARTER" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    emu shell "ps -A | grep -q shizuku_server" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

ATTEMPT=1
while :; do
  step "starting the Shizuku server (as the adb shell user), attempt $ATTEMPT/2"
  if start_shizuku; then break; fi
  if [ "$ATTEMPT" -ge 2 ]; then
    die "shizuku_server is not running after 2 attempts"
  fi
  step "attempt $ATTEMPT did not leave a running shizuku_server; waiting 10 s, then one retry"
  ATTEMPT=$((ATTEMPT + 1))
  sleep 10
done
step "shizuku: $(emu shell 'ps -A -o USER,PID,NAME | grep shizuku_server' | tr -s ' ' | tr -d '\r')"

resolve_activity() {
  emu shell cmd package resolve-activity --brief "$1" 2>/dev/null | grep '/' | tail -1 | tr -d '\r'
}
SHIZUKU_ACT="$(resolve_activity "$SHIZUKU_PKG")"
if [ -n "$SHIZUKU_ACT" ]; then
  emu shell am start -n "$SHIZUKU_ACT" >/dev/null 2>&1 || true
fi

# --- 5. launch the app ------------------------------------------------------
# The UI's service switch lives in prefs; writing them directly is what makes
# the rig non-interactive (the app is debuggable, so run-as can reach them).
# An existing pairing is carried over so restarts do not force a new prompt.
step "seeding app prefs (enabled + onboarding done)"
emu shell am force-stop "$PKG" >/dev/null 2>&1 || true
PREFS="$CACHE_DIR/contigua_prefs.xml"
OLD_PREFS="$CACHE_DIR/contigua_prefs.old.xml"
emu shell "run-as $PKG cat shared_prefs/contigua.xml" >"$OLD_PREFS" 2>/dev/null || true
python3 - "$PREFS" "$OLD_PREFS" "$DEVICE_ID" <<'PY'
import re
import sys

out_path, old_path, device_id = sys.argv[1], sys.argv[2], sys.argv[3]
old = ""
try:
    with open(old_path) as fp:
        old = fp.read()
except OSError:
    pass
# <string> bodies escape &, <, >; the paired list is machine-generated JSON.
m = re.search(r'<string name="paired">.*?</string>', old, re.S)
paired = m.group(0) if m else ""

with open(out_path, "w") as fp:
    fp.write("<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n")
    fp.write('    <boolean name="enabled" value="true" />\n')
    fp.write('    <boolean name="onboarding_done" value="true" />\n')
    fp.write('    <string name="device_id">%s</string>\n' % device_id)
    fp.write('    <string name="device_name">Contigua Emulator</string>\n')
    if paired:
        fp.write("    %s\n" % paired)
    fp.write("</map>\n")
PY
emu shell "run-as $PKG mkdir -p shared_prefs" >/dev/null 2>&1 || true
emu shell "run-as $PKG sh -c 'cat > shared_prefs/contigua.xml'" <"$PREFS" ||
  die "cannot seed $PKG prefs (is the build debuggable?)"

if [ "${CONTIGUA_FORCE_PANEL_OFF:-0}" = "1" ]; then
  step "setting debug.contigua.force_panel_off=1 before the server starts"
  emu shell setprop debug.contigua.force_panel_off 1 >/dev/null 2>&1 || true
  [ "$(emu shell getprop debug.contigua.force_panel_off | tr -d '\r')" = "1" ] ||
    die "debug.contigua.force_panel_off did not stick"
fi

emu logcat -c >/dev/null 2>&1 || true
step "launching $PKG"
# A fresh boot sometimes swallows the first start; make sure the app really runs.
for _ in $(seq 1 10); do
  emu shell am start -n "$PKG/.app.MainActivity" >/dev/null 2>&1 || true
  sleep 3
  [ -n "$(emu shell "pidof $PKG" 2>/dev/null | tr -d '\r')" ] && break
done
[ -n "$(emu shell "pidof $PKG" 2>/dev/null | tr -d '\r')" ] || die "could not launch $PKG"

# --- 6. server port ---------------------------------------------------------
# The first launch after a boot sometimes leaves the shell service without a
# listening port (the user service does not bind). Retry the app, up to three
# times, and name the service's own log lines when it still does not come up.
DEVPORT="$(wait_server_port 60 || true)"
TRY=1
while [ -z "$DEVPORT" ] && [ "$TRY" -le 3 ]; do
  step "no listening port yet; restarting the shell service (try $TRY/3)"
  if restart_server; then
    DEVPORT="$(device_port || true)"
  fi
  TRY=$((TRY + 1))
done
if [ -z "$DEVPORT" ]; then
  step "last app/server logs:"
  emu logcat -d -s ContiguaApp:I ContiguaSvc:I | tail -20 >&2 || true
  die "no listening socket for the Contigua shell service after 3 restarts (see $AGENT_DIR/emulator.log)"
fi

# The emulator is behind NAT and mDNS does not cross it, so reach the server
# through an adb forward on the Mac's loopback.
ensure_forward >/dev/null || die "adb forward failed"
step "server: $(emu shell "ps -A -o USER,PID,NAME | grep 'app.contigua:contigua'" | tr -s ' ' | tr -d '\r' | tr '\n' ' ')listening on $(emu shell "ss -ltnp 2>/dev/null | grep \":$DEVPORT \"" | tr -s ' ' | tr -d '\r' | head -1)"

echo
echo "CONTIGUA_SERIAL=$SERIAL"
echo "CONTIGUA_ADDR=127.0.0.1:$PORT"
echo "CONTIGUA_DEVICE_PORT=$DEVPORT"
echo
echo "next: python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port $PORT --state $CACHE_DIR/deckctl-state.json apps"
