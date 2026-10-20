#!/usr/bin/env bash
# Boot the PocketDeck emulator rig and leave it ready for deckctl/poc:
#
#   tools/emulator/start.sh [--window] [--no-build]
#
# Does, in order (all idempotent):
#   1. boot the AVD headless and wait for sys.boot_completed (unlocks the rig PIN
#      if a previous run set one)
#   2. install the apps: Shizuku, dev.pocketdeck (built here) and the two F-Droid
#      test apps, all cached under tools/emulator/.cache/
#   3. grant dev.pocketdeck its runtime permissions - notably the Shizuku
#      permission, which is a plain dangerous permission, so `pm grant` works
#   4. start the Shizuku server through its own native starter, as the adb shell
#      user, so the PocketDeck user service runs with UID 2000. This must happen
#      *after* the grant: the server snapshots each app's permission state when
#      it starts (BinderSender/ShizukuConfig), and a later grant is not picked up
#      until the server restarts.
#   5. seed the app prefs that the UI would otherwise set by hand (enabled +
#      onboarding done + a stable device id), launch the app and read the server
#      port from logcat
#   6. adb forward tcp:<POCKETDECK_PORT> -> the server port, print 127.0.0.1:<port>
set -euo pipefail

WINDOW=0
NO_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --window) WINDOW=1 ;;
    --no-build) NO_BUILD=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "start.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

. "$(dirname "$0")/lib.sh"

PKG="dev.pocketdeck"
SHIZUKU_PKG="moe.shizuku.privileged.api"
BROWSER_PKG="${POCKETDECK_BROWSER:-acr.browser.lightning}"
MESSENGER_PKG="${POCKETDECK_MESSENGER:-org.fossify.messages}"
DEVICE_ID="${POCKETDECK_DEVICE_ID:-e0e0e0e0e0e0e0e0}"

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
  if pgrep -f "emulator.*-avd $AVD_NAME" >/dev/null 2>&1; then
    step "emulator already starting, waiting for $SERIAL"
  else
    GPU_ARGS="-gpu swiftshader_indirect"
    [ "$WINDOW" -eq 1 ] && GPU_ARGS=""
    # The back camera is the emulator's synthetic test pattern ("emulated"),
    # never a host webcam: the C0/C1 probe needs a camera that cannot open the
    # Mac's own. The front camera stays off (the AVD has none).
    ARGS="-avd $AVD_NAME -port 5554 -memory 2048 -cores 2 -no-audio -no-boot-anim -no-snapshot -no-metrics -netdelay none -netspeed full -camera-back emulated -camera-front none"
    [ "$WINDOW" -eq 0 ] && ARGS="$ARGS -no-window"
    step "starting $AVD_NAME on 5554 (headless=$((1 - WINDOW)))"
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
  "$EMU_DIR/unlock.sh"
fi

# --- 2. install the apps ----------------------------------------------------
package_installed() { [ -n "$(emu shell pm path "$1" 2>/dev/null | tr -d '\r')" ]; }

FRESH_APPS=""
install_apk() { # install_apk <path> <pkg>
  local path="$1" pkg="$2"
  if package_installed "$pkg"; then
    return 0
  fi
  step "installing $pkg"
  emu_long install -r -g "$path" >/dev/null || die "could not install $pkg"
  FRESH_APPS="$FRESH_APPS $pkg"
}

SHIZUKU_APK="$CACHE_DIR/shizuku.apk"
if [ ! -s "$SHIZUKU_APK" ]; then
  url="$(github_release_asset "RikkaApps/Shizuku" 'release\.apk$')" || die "cannot reach the Shizuku release feed"
  [ -n "$url" ] || die "no Shizuku release APK found"
  fetch "$url" "$SHIZUKU_APK" || die "cannot download Shizuku"
fi
install_apk "$SHIZUKU_APK" "$SHIZUKU_PKG"

install_fdroid() { # install_fdroid <pkg>
  local fpkg="$1"
  local fdst="$CACHE_DIR/apks/${fpkg}.apk"
  mkdir -p "$CACHE_DIR/apks"
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
emu_long install -r -g "$APK" >/dev/null || die "could not install $PKG"

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

step "starting the Shizuku server (as the adb shell user)"
emu shell "$STARTER" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  emu shell "ps -A | grep -q shizuku_server" 2>/dev/null && break
  sleep 1
done
emu shell "ps -A | grep -q shizuku_server" 2>/dev/null || die "shizuku_server is not running"
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
PREFS="$CACHE_DIR/pocketdeck_prefs.xml"
OLD_PREFS="$CACHE_DIR/pocketdeck_prefs.old.xml"
emu shell "run-as $PKG cat shared_prefs/pocketdeck.xml" >"$OLD_PREFS" 2>/dev/null || true
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
    fp.write('    <string name="device_name">PocketDeck Emulator</string>\n')
    if paired:
        fp.write("    %s\n" % paired)
    fp.write("</map>\n")
PY
emu shell "run-as $PKG mkdir -p shared_prefs" >/dev/null 2>&1 || true
emu shell "run-as $PKG sh -c 'cat > shared_prefs/pocketdeck.xml'" <"$PREFS" ||
  die "cannot seed $PKG prefs (is the build debuggable?)"

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
# device_port returns 1 until the server is up, so it needs `|| true` under set -e.
DEVPORT=""
for _ in $(seq 1 60); do
  DEVPORT="$(device_port || true)"
  [ -n "$DEVPORT" ] && break
  sleep 1
done
if [ -z "$DEVPORT" ]; then
  step "last app/server logs:"
  emu logcat -d -s PocketDeckApp:I PocketDeckSvc:I | tail -20 >&2 || true
  die "no listening socket for the PocketDeck shell service (see $AGENT_DIR/emulator.log)"
fi

# The emulator is behind NAT and mDNS does not cross it, so reach the server
# through an adb forward on the Mac's loopback.
ensure_forward >/dev/null || die "adb forward failed"
step "server: $(emu shell "ps -A -o USER,PID,NAME | grep 'dev.pocketdeck:pocketdeck'" | tr -s ' ' | tr -d '\r' | tr '\n' ' ')listening on $(emu shell "ss -ltnp 2>/dev/null | grep \":$DEVPORT \"" | tr -s ' ' | tr -d '\r' | head -1)"

echo
echo "POCKETDECK_SERIAL=$SERIAL"
echo "POCKETDECK_ADDR=127.0.0.1:$PORT"
echo "POCKETDECK_DEVICE_PORT=$DEVPORT"
echo
echo "next: python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port $PORT --state $CACHE_DIR/deckctl-state.json apps"
