#!/usr/bin/env bash
# "Keep running in the background" must do something (PHONE-19): the onboarding
# button and the home switch share one action, the row says what the pref plus
# the battery exemption mean, and a swipe from Recents follows the switch.
#
#   bash tools/emulator/background-switch.sh [--check]
#
# Runs against an already booted rig and boots nothing: the caller owns the
# emulator's whole life inside ONE heavy.sh call. Exits non-zero when any check
# failed (the pre-fix run fails the tap checks).
set -euo pipefail

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) echo "[background-switch] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

PKG=dev.pocketdeck
SHOTS="${POCKETDECK_SHOTS:-$HOME/dev/pocketdeck/.agent/phone-reset/shots}"

ui_text() {
  emu shell uiautomator dump --compressed "$1" >/dev/null 2>&1 || true
  emu shell cat "$1" 2>/dev/null | tr -d '\r'
}

wait_for_text() { # wait_for_text <dump-file> <grep-pattern> <timeout_s>
  local dump="$1" pattern="$2" deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ui_text "$dump" | grep -q "$pattern" && return 0
    sleep 1
  done
  return 1
}

tap_text() { # tap_text <dump-file> <text it contains>
  local dump="$1" want="$2" xy host="$CACHE_DIR/background-switch-ui.txt"
  ui_text "$dump" > "$host" 2>/dev/null || true
  xy="$("$PYTHON" - "$host" "$want" <<'PY'
import re, sys
want = sys.argv[2]
for tag in re.findall(r"<node\b[^>]*>", open(sys.argv[1], "r", errors="replace").read()):
    t = re.search(r"\btext=\"([^\"]*)\"", tag)
    if not t or want not in t.group(1):
        continue
    m = re.search(r"\bbounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
    if m:
        a, b, c, d = map(int, m.groups())
        print((a + c) // 2, (b + d) // 2)
        break
PY
)"
  [ -n "$xy" ] || return 1
  emu shell input tap $xy >/dev/null
}

shot() { # shot <name>
  mkdir -p "$SHOTS"
  emu exec-out screencap -p > "$SHOTS/$1.png"
}

pref_enabled() {
  emu shell "run-as $PKG cat shared_prefs/pocketdeck.xml" 2>/dev/null |
    tr -d '\r' | grep -o 'name="enabled" value="[a-z]*"' | sed 's/.*value="//;s/"//' | head -1
}

seed_prefs() { # seed_prefs <enabled> <onboarding_done>
  local file="$CACHE_DIR/background-switch-prefs.xml"
  cat > "$file" <<XML
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <boolean name="enabled" value="$1" />
    <boolean name="onboarding_done" value="$2" />
    <string name="device_id">e0e0e0e0e0e0e0e0</string>
    <string name="device_name">PocketDeck Emulator</string>
</map>
XML
  emu shell "run-as $PKG mkdir -p shared_prefs" >/dev/null 2>&1 || true
  emu shell "run-as $PKG sh -c 'cat > shared_prefs/pocketdeck.xml'" < "$file"
}

stop_app() {
  emu shell am force-stop "$PKG" >/dev/null 2>&1 || true
}

restart_app() {
  stop_app
  for _ in $(seq 1 10); do
    emu shell am start -n "$PKG/.app.MainActivity" >/dev/null 2>&1 || true
    sleep 2
    [ -n "$(emu shell "pidof $PKG" 2>/dev/null | tr -d '\r')" ] && break
  done
}

service_running() {
  emu shell dumpsys activity services "$PKG" 2>/dev/null |
    grep -q "ServiceRecord.*DeckForegroundService"
}

task_present() {
  emu shell dumpsys activity recents 2>/dev/null | grep -q "realActivity=.*$PKG/"
}

swipe_from_recents() {
  # The person's gesture: open Recents, swipe the card up and away. A second
  # attempt with a longer, slower swipe covers a card that sat higher.
  emu shell input keyevent KEYCODE_APP_SWITCH >/dev/null 2>&1 || true
  sleep 2
  emu shell input swipe 540 1500 540 250 250 >/dev/null 2>&1 || true
  sleep 2
  if task_present; then
    emu shell input swipe 540 1800 540 200 500 >/dev/null 2>&1 || true
    sleep 2
  fi
  if task_present; then
    emu shell input swipe 300 1400 300 150 400 >/dev/null 2>&1 || true
    sleep 2
  fi
}

if [ "$CHECK" = 1 ]; then
  [ -x "$EMULATOR" ] || die "emulator not installed"
  [ -f "$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk" ] ||
    die "no debug APK; run K1 first"
  case "$SERIAL" in emulator-*) ;; *) die "refusing serial $SERIAL (emulators only)" ;; esac
  step "check: rig and APK are present"
  exit 0
fi

device_present || die "no emulator on $SERIAL"

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

# A fresh install with no pairing: onboarding from page 1, switch off.
emu shell am force-stop "$PKG" >/dev/null 2>&1 || true
seed_prefs false false
# Make sure the test starts without the exemption, and remember whether the rig
# already had it so the state can be put back.
HAD_EXEMPT=0
if emu shell dumpsys deviceidle whitelist 2>/dev/null | grep -q "$PKG"; then
  HAD_EXEMPT=1
fi
if [ "$HAD_EXEMPT" = 1 ]; then
  emu shell "dumpsys deviceidle whitelist -$PKG" >/dev/null 2>&1 || true
fi

restart_app
if emu shell dumpsys deviceidle whitelist 2>/dev/null | grep -q "$PKG"; then
  fail "precondition: the rig could not un-exempt $PKG; the restricted row is unreachable"
fi
wait_for_text /data/local/tmp/pd-bg.xml 'Get started' 30 || die "the onboarding never appeared"
tap_text /data/local/tmp/pd-bg.xml 'Get started' || die "could not tap Get started"
wait_for_text /data/local/tmp/pd-bg.xml 'Keep running in the background' 30 ||
  die "the notifications step never appeared"

[ "$(pref_enabled)" != "true" ] && pass "before: keep running is off" ||
  fail "before: the pref was already on"
shot phone-reset-5-onboarding-before

tap_text /data/local/tmp/pd-bg.xml 'Keep running in the background' ||
  die "could not tap the keep-running button"
sleep 3
# The exemption dialog may be in front of the app; back out of it (the person
# declining) so the row can be read. The page title is the anchor: the
# keep-running button is replaced by the row in the other two states.
for _ in 1 2 3; do
  if ui_text /data/local/tmp/pd-bg.xml | grep -q 'Allow notifications'; then break; fi
  emu shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  sleep 2
done

if [ "$(pref_enabled)" = "true" ]; then
  pass "tap: the keep-running pref is on"
else
  fail "tap: the keep-running pref is still off (the reported bug)"
fi
if service_running; then
  pass "tap: the foreground service is running"
else
  fail "tap: no foreground service after the tap"
fi
if wait_for_text /data/local/tmp/pd-bg.xml 'Battery restriction still on' 8; then
  pass "tap: the row says the battery restriction is still on"
  shot phone-reset-6-onboarding-after
  if tap_text /data/local/tmp/pd-bg.xml 'Open battery settings'; then
    sleep 3
    if emu shell dumpsys window 2>/dev/null | grep -qiE 'mCurrentFocus.*(settings|battery)'; then
      pass "row: Open battery settings opened a settings screen"
    else
      fail "row: Open battery settings did not open a settings screen"
    fi
    emu shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
  else
    fail "row: no Open battery settings button"
  fi
else
  fail "tap: the row did not say the battery restriction is still on"
fi

# Grant the exemption (the person's Allow) and come back: the row settles and
# the home carries the same line.
emu shell "dumpsys deviceidle whitelist +$PKG" >/dev/null 2>&1 || true
stop_app
seed_prefs true true
restart_app
wait_for_text /data/local/tmp/pd-bg.xml 'Keep running in the background' 30 ||
  die "the home never appeared"
if ui_text /data/local/tmp/pd-bg.xml | grep -q 'Keeps running after you swipe it away and starts when the phone restarts.'; then
  pass "on: the home says what the switch survives"
else
  fail "on: the home does not say what the switch survives"
fi
shot phone-reset-7-home-on

# --- on: a swipe from Recents keeps the service -----------------------------
if [ "$(pref_enabled)" = "true" ] && service_running; then
  swipe_from_recents
  if task_present; then
    fail "swipe on: the task is still in Recents (the gesture missed)"
  elif service_running; then
    pass "swipe on: the task is gone and the service still runs"
  else
    fail "swipe on: the service stopped although the switch is on"
  fi
else
  fail "swipe on: the switch is off or the service was not running"
fi

# --- off: the same swipe stops the service ----------------------------------
restart_app
wait_for_text /data/local/tmp/pd-bg.xml 'Keep running in the background' 30 ||
  die "the home never came back"
tap_text /data/local/tmp/pd-bg.xml 'Keep running in the background' ||
  die "could not tap the home switch"
sleep 2
if [ "$(pref_enabled)" = "false" ]; then
  pass "off: the home switch stored the pref"
else
  fail "off: the home switch did not store the pref"
fi
swipe_from_recents
if task_present; then
  fail "swipe off: the task is still in Recents (the gesture missed)"
elif service_running; then
  fail "swipe off: the service still runs with the switch off"
else
  pass "swipe off: the task is gone and the service stopped"
fi

# Put the rig's exemption back the way it was found.
if [ "$HAD_EXEMPT" = 1 ]; then
  emu shell "dumpsys deviceidle whitelist +$PKG" >/dev/null 2>&1 || true
else
  emu shell "dumpsys deviceidle whitelist -$PKG" >/dev/null 2>&1 || true
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "background-switch: PASS"
  exit 0
fi
echo "background-switch: FAIL ($FAILS check(s))"
exit 1
