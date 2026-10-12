#!/usr/bin/env bash
# Dark-panel device check (the K4 flow): with the phone locked, a Mac window
# streams and the physical panel must stay dark, while frames arrive and input
# works. On close the phone must be asleep again with no leftovers.
#
#   tools/device-checks/dark-panel.sh <serial> [package]
#
# Env: ADB, POCKETDECK_PORT (host forward port), POCKETDECK_STATE (deckctl state
# file), POCKETDECK_SECONDS.
#
# Read-only with respect to the phone: it never unlocks, never changes lock
# settings, never installs anything. It only opens a window through the normal
# protocol. Neighbours: tools/emulator/lock.sh for the emulator rig.
set -uo pipefail

SERIAL="${1:?usage: dark-panel.sh <serial> [package]}"
APP="${2:-com.whatsapp}"
ADB="${ADB:-adb}"
HOST_PORT="${POCKETDECK_PORT:-47819}"
STATE="${POCKETDECK_STATE:-$HOME/.pocketdeck-deckctl.json}"
SECONDS_OPEN="${POCKETDECK_SECONDS:-20}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/pocketdeck-dark-panel.$$"
mkdir -p "$TMP"

FAILS=0
adb_() { timeout 20 "$ADB" -s "$SERIAL" "$@"; }
note() { printf '%s\n' "$*"; }
pass() { note "PASS: $1${2:+ -> $2}"; }
fail() { note "FAIL: $1${2:+ -> $2}"; FAILS=$((FAILS + 1)); }
check() { if printf '%s' "$3" | grep -qE "$2"; then pass "$1" "$3"; else fail "$1" "got [$3], want /$2/"; fi; }

deckctl() {
  python3 "$ROOT/tools/fakephone/deckctl.py" --host 127.0.0.1 --port "$HOST_PORT" --state "$STATE" "$@"
}

# --- helpers ---------------------------------------------------------------

wakefulness() { adb_ shell dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | tr -d '\r' | sed 's/ *mWakefulness=//'; }
screen_state() {
  local v
  v="$(adb_ shell dumpsys display 2>/dev/null | grep -m1 'mScreenState=' | tr -d '\r' | sed 's/ *mScreenState=//')"
  [ -n "$v" ] || { sleep 1; v="$(adb_ shell dumpsys display 2>/dev/null | grep -m1 'mScreenState=' | tr -d '\r' | sed 's/ *mScreenState=//')"; }
  printf '%s' "$v"
}
# Every physical display's SurfaceFlinger power mode; the definitive "the panel
# is not emitting light" reading (the platform's logical state stays ON while the
# fallback holds the panel off).
physical_power_modes() {
  adb_ shell dumpsys SurfaceFlinger 2>/dev/null | tr -d '\r' |
    awk '/^Virtual Display/{virt=1} /^Display [0-9]/{virt=0} /powerMode=/{if(!virt) print $0}' |
    sed 's/.*powerMode=//' | tr '\n' ' ' | sed 's/ *$//'
}
panel_group_interactive() {
  adb_ shell dumpsys power 2>/dev/null | tr -d '\r' |
    awk '/powerGroupId: 0/,/powerGroupId: 1/' | grep -m1 'mIsInteractive:' | sed 's/.*mIsInteractive: *//'
}
our_wake_lock() { adb_ shell dumpsys power 2>/dev/null | grep -c "'pocketdeck:streams'" | tr -d '\r'; }
server_log() { adb_ logcat -d 2>/dev/null | grep 'PocketDeckSvc'; }

# --- preflight -------------------------------------------------------------

if ! adb_ get-state >/dev/null 2>&1; then
  note "FAIL: $SERIAL is not connected (adb devices)"; exit 2
fi
note "== $SERIAL :: $(adb_ shell getprop ro.product.model | tr -d '\r') API $(adb_ shell getprop ro.build.version.sdk | tr -d '\r')"

PORT="$(server_log | sed -n 's/.*listening on 0.0.0.0:\([0-9]*\).*/\1/p' | tail -1)"
INSTANCE="PocketDeck $(adb_ shell getprop ro.product.model | tr -d '\r')"
DISCOVER=0
if [ -n "$PORT" ]; then
  adb_ forward --remove tcp:"$HOST_PORT" >/dev/null 2>&1 || true
  adb_ forward tcp:"$HOST_PORT" tcp:"$PORT" >/dev/null 2>&1 || PORT=""
fi
if [ -n "$PORT" ]; then
  note "forward tcp:$HOST_PORT -> phone:$PORT"
  deckctl() { python3 "$ROOT/tools/fakephone/deckctl.py" --host 127.0.0.1 --port "$HOST_PORT" --state "$STATE" "$@"; }
  deckctl latency >/dev/null 2>&1 || PORT=""
fi
if [ -z "$PORT" ]; then
  # No port in logcat (the log may have rotated): find the phone over mDNS instead.
  note "no server port in logcat; trying mDNS discovery of \"$INSTANCE\""
  DISCOVER=1
  deckctl() { python3 "$ROOT/tools/fakephone/deckctl.py" --discover --instance "$INSTANCE" --state "$STATE" "$@"; }
  deckctl latency >/dev/null 2>&1 || {
    note "FAIL: cannot reach the phone server (is PocketDeck running and paired? state: $STATE)"
    exit 2
  }
fi

note "== ensure the phone is locked with the screen off"
adb_ shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1
sleep 3
check "phone locked (keyguard showing)" "true" "$(adb_ shell dumpsys window 2>/dev/null | grep -m1 -oE 'isKeyguardShowing=(true|false)' | cut -d= -f2)"
check "screen off before streaming" "^(Asleep|Dozing)$" "$(wakefulness)"
BEFORE_MODES="$(physical_power_modes)"
note "panel before: wakefulness=$(wakefulness) screen=$(screen_state) sfModes=[$BEFORE_MODES]"
check "panel dark before streaming" "^Off( Off)*$" "$BEFORE_MODES"

# --- stream with the phone locked ------------------------------------------

note "== streaming $APP for ${SECONDS_OPEN}s while locked"
: > "$TMP/open.log"
(timeout $((SECONDS_OPEN + 40)) python3 "$ROOT/tools/fakephone/deckctl.py" \
    --host 127.0.0.1 --port "$HOST_PORT" --state "$STATE" \
    open "$APP" --w 1280 --h 800 --seconds "$SECONDS_OPEN" --out "$TMP/open.h264" \
    >> "$TMP/open.log" 2>&1) &
OPEN=$!
sleep 8
D_MODES="$(physical_power_modes)"
D_SCREEN="$(screen_state)"
D_WAKE="$(wakefulness)"
D_GROUP="$(panel_group_interactive)"
D_LOCK="$(our_wake_lock)"
note "during: wakefulness=$D_WAKE screen=$D_SCREEN panelGroupInteractive=$D_GROUP sfModes=[$D_MODES] pocketdeck-wakelocks=$D_LOCK"
wait $OPEN; OPEN_RC=$?
cat "$TMP/open.log"
LOG="$(server_log | tail -40)"
note "server log (VD creation):"
printf '%s\n' "$(printf '%s' "$LOG" | grep -E 'requested flags=|display [0-9]+: group=' | tail -2)" | sed 's/^/  /'
check "deckctl open exit" "^0$" "$OPEN_RC"
check "frames received" "frames=[1-9][0-9]*" "$(grep -m1 'frames=' "$TMP/open.log")"
check "VD reported flags + path + group" "display [0-9]+: group=" "$(printf '%s' "$LOG" | grep 'display [0-9]*: group=' | tail -1)"

# The physical panel must not be emitting light while the VD renders.
check "panel physically dark while streaming" "^Off( Off)*$" "$D_MODES"
check "our wake lock held while streaming" "^1$" "$D_LOCK"
if [ "$D_GROUP" = "true" ]; then
  note "note: the VD shares the panel's power group (fallback path); logical panel state is $D_SCREEN"
fi

# --- input on the locked phone --------------------------------------------

note "== input check ($APP, tap in the middle)"
: > "$TMP/probe.log"
timeout 120 python3 "$ROOT/tools/fakephone/deckctl.py" --host 127.0.0.1 --port "$HOST_PORT" \
    --state "$STATE" --wait-for-free 20 probe "$APP" --w 1280 --h 800 --dpi 240 \
    --steps "wait:4;tap:0.5,0.46;wait:4" --phase-seconds 3 \
    --out-prefix "$TMP/probe" > "$TMP/probe.log" 2>&1
PROBE_RC=$?
cat "$TMP/probe.log"
check "input probe exit" "^0$" "$PROBE_RC"
I_MODES="$(physical_power_modes)"
check "panel physically dark during input" "^Off( Off)*$" "$I_MODES"
if [ -s "$TMP/probe-base.png" ] && [ -s "$TMP/probe-01-tap.png" ]; then
  if cmp -s "$TMP/probe-base.png" "$TMP/probe-01-tap.png"; then
    note "note: the frame after the tap is byte-identical to the frame before it (the tap may have been a no-op)"
  else
    pass "the tap visibly changed the frame" "$TMP/probe-base.png vs $TMP/probe-01-tap.png"
  fi
fi

# --- close: back to locked-off, no leftovers -------------------------------

sleep 4
AFTER_MODES="$(physical_power_modes)"
AFTER_WAKE="$(wakefulness)"
AFTER_LOCK="$(our_wake_lock)"
LOG="$(server_log | tail -40)"
note "after: wakefulness=$AFTER_WAKE screen=$(screen_state) sfModes=[$AFTER_MODES] pocketdeck-wakelocks=$AFTER_LOCK"
check "phone asleep after close" "^(Asleep|Dozing)$" "$AFTER_WAKE"
check "panel dark after close" "^Off( Off)*$" "$AFTER_MODES"
check "no leftover pocketdeck wake lock" "^0$" "$AFTER_LOCK"
if printf '%s' "$LOG" | grep -q "panel power mode -> OFF"; then
  check "fallback restored and slept the phone" "phone back to sleep after the last stream" "$(printf '%s' "$LOG" | grep 'phone back to sleep' | tail -1)"
else
  note "note: the panel power mode was never touched (own-group build)"
fi

note
if [ "$FAILS" -eq 0 ]; then
  note "dark-panel $SERIAL: PASS"
else
  note "dark-panel $SERIAL: FAIL ($FAILS)"
fi
exit "$FAILS"
