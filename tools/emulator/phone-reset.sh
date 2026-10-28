#!/usr/bin/env bash
# Clear data / uninstall must revoke the pairing at once (PAIR-19/PAIR-20).
#
#   bash tools/emulator/phone-reset.sh [--check]
#
# Runs against an already booted rig (tools/emulator/start.sh) and boots
# nothing itself: the caller owns the emulator's whole life inside ONE
# heavy.sh call. Every check prints PASS/FAIL with its measured value; the
# script exits non-zero when any check failed (the pre-fix run fails A and B).
#
# A  pair the fake Mac, then hold a live session
# B  pm clear -> the live session closes within 5 s (PAIR-20)
# C  with the app dead, a reconnect is refused (no stale identity served)
# D  the relaunched app lists no Macs
# E  pair again, then Paired Macs > Forget All Macs... with its confirmation:
#    the session closes, and the Mac must pair again (PAIR-18/PAIR-20)
set -euo pipefail

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) echo "[phone-reset] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

PKG=dev.pocketdeck
PORT="${POCKETDECK_PORT:-47997}"
# A fresh fake-Mac identity per run (the store lives in a directory, and a
# stale pin from an earlier run would change what this check proves).
RUN="$(date +%s)"
STATE="$CACHE_DIR/phone-reset-$RUN-a.json"
CODE="$CACHE_DIR/phone-reset-code.txt"
WATCH="$CACHE_DIR/phone-reset-watch.log"
SHOTS="${POCKETDECK_SHOTS:-$HOME/dev/pocketdeck/.agent/phone-reset/shots}"
MAX_CLOSE_S=5

dc() {
  "$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$STATE" "$@"
}

now() { "$PYTHON" -c 'import time; print("%.3f" % time.time())'; }
elapsed() { "$PYTHON" -c "import sys; print('%.2f' % (float(sys.argv[2]) - float(sys.argv[1])))" "$1" "$2"; }

ui_text() { # ui_text <dump-file> -> the dump's text nodes
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

shot() { # shot <name> -> the PNG path
  mkdir -p "$SHOTS"
  emu exec-out screencap -p > "$SHOTS/$1.png"
  echo "$SHOTS/$1.png"
}

seed_prefs() { # seed_prefs <enabled> <onboarding_done> [paired-json]
  local enabled="$1" done_flag="$2" paired="${3:-}"
  local file="$CACHE_DIR/phone-reset-prefs.xml"
  {
    echo "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>"
    echo "<map>"
    echo "    <boolean name=\"enabled\" value=\"$enabled\" />"
    echo "    <boolean name=\"onboarding_done\" value=\"$done_flag\" />"
    echo "    <string name=\"device_id\">e0e0e0e0e0e0e0e0</string>"
    echo "    <string name=\"device_name\">PocketDeck Emulator</string>"
    [ -n "$paired" ] && echo "    <string name=\"paired\">$paired</string>"
    echo "</map>"
  } > "$file"
  emu shell "run-as $PKG mkdir -p shared_prefs" >/dev/null 2>&1 || true
  emu shell "run-as $PKG sh -c 'cat > shared_prefs/pocketdeck.xml'" < "$file"
}

restart_app() {
  emu shell am force-stop "$PKG" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    emu shell am start -n "$PKG/.app.MainActivity" >/dev/null 2>&1 || true
    sleep 2
    [ -n "$(emu shell "pidof $PKG" 2>/dev/null | tr -d '\r')" ] && break
  done
}

# --- --check: the exact preconditions, without a boot -----------------------
if [ "$CHECK" = 1 ]; then
  [ -x "$EMULATOR" ] || die "emulator not installed"
  [ -f "$REPO_ROOT/android/app/build/outputs/apk/debug/app-debug.apk" ] ||
    die "no debug APK; run K1 first"
  [ -f "$REPO_ROOT/tools/fakephone/deckctl.py" ] || die "no deckctl"
  "$PYTHON" -c 'import ssl; c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.minimum_version = ssl.TLSVersion.TLSv1_3' ||
    die "$PYTHON cannot do TLS 1.3"
  case "$SERIAL" in emulator-*) ;; *) die "refusing serial $SERIAL (emulators only)" ;; esac
  [ -z "$(emu devices 2>/dev/null | awk -v s="$SERIAL" '$1 == s && $2 == "device"')" ] ||
    step "check: an emulator is already up on $SERIAL; start.sh would reuse it"
  step "check: rig, deckctl, TLS 1.3 and APK are present ($PYTHON)"
  exit 0
fi

device_present || die "no emulator on $SERIAL"
emu shell am force-stop "$PKG" >/dev/null 2>&1 || true
emu shell setprop debug.pocketdeck.auto_approve 1 >/dev/null
[ "$(emu shell getprop debug.pocketdeck.auto_approve | tr -d '\r')" = "1" ] ||
  die "could not turn on the rig's pairing auto-approve"
step "auto-approve pairing on (rig only)"

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }

# --- A: pair, then hold one live session ------------------------------------
restart_app
wait_server_port 60 >/dev/null || die "no listening port after relaunch"
ensure_forward >/dev/null || die "adb forward failed"

step "pairing the fake Mac"
dc --pair --code-file "$CODE" --name "Studio Mac" apps > "$CACHE_DIR/phone-reset-pair.log" 2>&1 ||
  { cat "$CACHE_DIR/phone-reset-pair.log" >&2; die "deckctl could not pair"; }
step "paired"

wait_for_text /data/local/tmp/pd-reset.xml 'Paired Macs' 20 ||
  die "the home screen is not on top after pairing"
wait_for_text /data/local/tmp/pd-reset.xml 'Studio Mac' 20 ||
  die "the paired list does not show the Mac after pairing"
shot phone-reset-1-paired >/dev/null
pass "pair: the home lists the Mac"

PYTHONUNBUFFERED=1 "$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
  --state "$STATE" watch-state --seconds 40 > "$WATCH" 2>&1 &
WPID=$!
LIVE=0
for _ in $(seq 1 20); do
  grep -q ' state #' "$WATCH" 2>/dev/null && { LIVE=1; break; }
  kill -0 "$WPID" 2>/dev/null || break
  sleep 1
done
[ "$LIVE" = 1 ] || { cat "$WATCH" >&2; die "the live session never reported a state"; }
pass "session: authenticated and live"

# --- B: Clear data ends the live session within MAX_CLOSE_S -----------------
emu shell pm clear "$PKG" >/dev/null 2>&1 || die "pm clear failed"
T_CLEARED="$(now)"
CLOSED=0
for _ in $(seq 1 80); do
  if ! kill -0 "$WPID" 2>/dev/null; then CLOSED=1; break; fi
  sleep 0.1
done
T_END="$(now)"
wait "$WPID" 2>/dev/null || true
N="$(elapsed "$T_CLEARED" "$T_END")"
if [ "$CLOSED" = 1 ] && grep -q 'closed during watch-state' "$WATCH" &&
  [ "$("$PYTHON" -c "print(1 if float('$N') <= $MAX_CLOSE_S else 0)")" = 1 ]; then
  pass "clear data: the live session closed in ${N}s (<= ${MAX_CLOSE_S}s)"
else
  fail "clear data: the live session did not close in time (closed=$CLOSED N=${N}s; see $WATCH)"
fi

# --- C: with the app dead, nothing serves the old identity ------------------
if timeout 20 "$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$STATE" apps > "$CACHE_DIR/phone-reset-reconnect-dead.log" 2>&1; then
  fail "clear data: a reconnect with the app dead was SERVED (stale identity)"
else
  pass "clear data: a reconnect with the app dead was refused: $(tail -1 "$CACHE_DIR/phone-reset-reconnect-dead.log")"
fi

# --- D: the relaunched app lists no Macs ------------------------------------
restart_app
wait_server_port 60 >/dev/null || die "no listening port after the relaunch"
ensure_forward >/dev/null || die "adb forward failed after the relaunch"
seed_prefs true true
restart_app
wait_server_port 60 >/dev/null || die "no listening port after seeding the prefs"
ensure_forward >/dev/null || die "adb forward failed"
if wait_for_text /data/local/tmp/pd-reset.xml 'No Macs paired yet.' 20; then
  if ui_text /data/local/tmp/pd-reset.xml | grep -q 'Studio Mac'; then
    fail "relaunch: the home still lists the Mac after Clear data"
  else
    shot phone-reset-2-empty >/dev/null
    pass "relaunch: the home lists no Macs"
  fi
else
  fail "relaunch: the home never showed the empty paired list"
fi

# --- E: the Mac must pair again; Forget All Macs ends a live session --------
STATE="$CACHE_DIR/phone-reset-$RUN-b.json"
step "pairing the fake Mac again (fresh Mac identity)"
dc --pair --code-file "$CODE" --name "Studio Mac" apps > "$CACHE_DIR/phone-reset-pair2.log" 2>&1 ||
  { cat "$CACHE_DIR/phone-reset-pair2.log" >&2; die "deckctl could not pair the second time"; }
pass "repair: a fresh pairing works and the old pin is not reused"

PYTHONUNBUFFERED=1 "$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
  --state "$STATE" watch-state --seconds 40 > "$WATCH" 2>&1 &
WPID=$!
LIVE=0
for _ in $(seq 1 20); do
  grep -q ' state #' "$WATCH" 2>/dev/null && { LIVE=1; break; }
  kill -0 "$WPID" 2>/dev/null || break
  sleep 1
done
[ "$LIVE" = 1 ] || { cat "$WATCH" >&2; die "the second live session never reported a state"; }

# The real control: Paired Macs > Forget All Macs... then its confirmation.
wait_for_text /data/local/tmp/pd-reset.xml 'Forget All Macs' 20 ||
  die "the home has no Forget All Macs action"
TAP="$(ui_text /data/local/tmp/pd-reset.xml | "$PYTHON" -c '
import re, sys
want = sys.argv[1]
for tag in re.findall(r"<node\b[^>]*>", sys.stdin.read()):
    t = re.search(r"\btext=\"([^\"]*)\"", tag)
    if not t or t.group(1) != want:
        continue
    m = re.search(r"\bbounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
    if m:
        a, b, c, d = map(int, m.groups())
        print((a + c) // 2, (b + d) // 2)
        break
' "Forget All Macs…")"
[ -n "$TAP" ] || die "could not find the Forget All Macs button's bounds"
emu shell input tap $TAP >/dev/null
wait_for_text /data/local/tmp/pd-reset.xml 'Forget all Macs?' 10 ||
  die "the confirmation did not appear"
shot phone-reset-3-confirm >/dev/null
TAP="$(ui_text /data/local/tmp/pd-reset.xml | "$PYTHON" -c '
import re, sys
want = sys.argv[1]
for tag in re.findall(r"<node\b[^>]*>", sys.stdin.read()):
    t = re.search(r"\btext=\"([^\"]*)\"", tag)
    if not t or t.group(1) != want:
        continue
    m = re.search(r"\bbounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
    if m:
        a, b, c, d = map(int, m.groups())
        print((a + c) // 2, (b + d) // 2)
        break
' "Forget All")"
[ -n "$TAP" ] || die "could not find the confirm button's bounds"
T_FORGET="$(now)"
emu shell input tap $TAP >/dev/null
CLOSED=0
for _ in $(seq 1 80); do
  if ! kill -0 "$WPID" 2>/dev/null; then CLOSED=1; break; fi
  sleep 0.1
done
T_END="$(now)"
wait "$WPID" 2>/dev/null || true
N="$(elapsed "$T_FORGET" "$T_END")"
if [ "$CLOSED" = 1 ] && grep -q 'closed during watch-state' "$WATCH" &&
  [ "$("$PYTHON" -c "print(1 if float('$N') <= $MAX_CLOSE_S else 0)")" = 1 ]; then
  pass "forget all: the live session closed in ${N}s (<= ${MAX_CLOSE_S}s)"
else
  fail "forget all: the live session did not close in time (closed=$CLOSED N=${N}s)"
fi
if wait_for_text /data/local/tmp/pd-reset.xml 'No Macs paired yet.' 10; then
  pass "forget all: the list is empty"
else
  fail "forget all: the list still shows a Mac"
fi
if timeout 20 "$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$STATE" apps > "$CACHE_DIR/phone-reset-reconnect-forgot.log" 2>&1; then
  fail "forget all: the Mac still gets a session (the pin survived the rotation)"
else
  pass "forget all: the Mac must pair again: $(tail -1 "$CACHE_DIR/phone-reset-reconnect-forgot.log")"
fi
shot phone-reset-4-forgotten >/dev/null

echo
if [ "$FAILS" -eq 0 ]; then
  echo "phone-reset: PASS"
  exit 0
fi
echo "phone-reset: FAIL ($FAILS check(s))"
exit 1
