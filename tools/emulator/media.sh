#!/usr/bin/env bash
# Deeper media control (ROADMAP v0.2 #9) on the emulator rig — ONE boot.
#
#   tools/emulator/media.sh            the run (heavy.sh owns the lock and the
#                                      boot budget; boot + checks + kill belong
#                                      to one heavy.sh call, see the README)
#   tools/emulator/media.sh --no-boot  the same checks on a rig that is already
#                                      up and paired (verify-batch.sh)
#   tools/emulator/media.sh --check    a dry run: preflight (syntax, files, the
#                                      APK's manifest, versionCode), the serial
#                                      and the assertions, no device touched
#   tools/emulator/media.sh --self-test  the assertions against synthetic logs
#                                      (the host dry run of the check logic)
#
# Run it as `bash tools/emulator/media.sh` (the exec bit is not relied on).
#
# What it proves on a real listener (docs/design/notify.md "Media part 2"):
# two debug fake media sessions are listed by media.sessions; the chosen one's
# artwork arrives scaled (w/h <= 512); a seek reaches the fake session and the
# next media.state is near it; a volume command is recorded by the fake and
# reflected in media.state; media.choose switches the chosen key; stopping one
# session shrinks the list. Logs carry counts, keys, states, rates and positions
# only — no package name, no track text, no artwork bytes.
set -u

MODE=run
BOOT=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --self-test) MODE=self-test ;;
    --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "media.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47982}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/emu"
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
RESULT="$OUT/media.log"
WATCH="$OUT/watch.log"
FAKEV="$OUT/fake-volume.log"
FAKEP="$OUT/fake-position.log"
EVIDENCE="$OUT/media-debug.log"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$CACHE_DIR/deckctl-state.json")

FAILED=0
pass() { echo "PASS media: $*"; }
fail() { echo "FAIL media: $*"; FAILED=1; }

# media_evidence LABEL — the phone's own account of the session stack, the
# listener binding and the fake sessions. Counts, packages and states only:
# neither dumpsys metadata nor logcat lines with track text are kept.
media_evidence() {
  {
    echo "== $1 $(date '+%H:%M:%S') =="
    emu shell dumpsys media_session 2>/dev/null | tr -d '\r' |
      grep -E 'Sessions Stack|MediaSessionRecord|package=|state=PlaybackState' | head -40
    emu shell dumpsys notification 2>/dev/null | tr -d '\r' |
      grep -A4 'PdNotificationListener' | head -20
    emu logcat -d -s PdMediaDebug:I 2>/dev/null | tr -d '\r' | tail -20
  } >> "$EVIDENCE"
}

# ---- the assertions (pure: they only read the files they are given) ---------

# watch_sessions FILE — "n playing chosen keys" of the last media.sessions line.
watch_sessions() {
  sed -n 's/^media.sessions n=\([0-9]*\) playing=\([0-9]*\) chosen=\([^ ]*\) keys=\(.*\)$/\1 \2 \3 \4/p' "$1" | tail -1
}

# watch_states FILE — the media.state lines, oldest first.
watch_states() { grep '^media.state ' "$1" 2>/dev/null || true; }

# last_state_field FILE FIELD — the last value of one media.state field.
last_state_field() {
  watch_states "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p" | tail -1
}

# watch_art FILE — the last media.art line.
watch_art() { grep '^media.art ' "$1" 2>/dev/null | tail -1; }

# check_boot WATCH POSITION_LOG VOLUME_LOG — the on-device assertions.
check_boot() {
  local watch="$1" position="$2" volume="$3" sessions art w h key chosen position_ms state_position level
  sessions="$(grep '^media.sessions n=2 ' "$watch" 2>/dev/null | head -1)"
  if [ -n "$sessions" ]; then
    pass "media.sessions listed two sessions"
  else
    fail "no two-session media.sessions line"
  fi
  chosen="$(printf '%s' "$sessions" | sed -n 's/.* chosen=\([^ ]*\) .*/\1/p')"
  if [ -n "$chosen" ] && grep '^media.sessions n=2 ' "$watch" |
      sed -n 's/.* chosen=\([^ ]*\) .*/\1/p' | grep -qvx "$chosen"; then
    pass "media.choose switched the chosen key"
  else
    fail "the chosen key never switched"
  fi
  if [ -n "$chosen" ] && [ "$chosen" != "-" ]; then
    pass "the chosen session key arrived (len ${#chosen})"
  else
    fail "no chosen session key"
  fi

  art="$(watch_art "$watch")"
  w="$(printf '%s' "$art" | sed -n 's/.* w=\([0-9]*\) .*/\1/p')"
  h="$(printf '%s' "$art" | sed -n 's/.* h=\([0-9]*\) .*/\1/p')"
  if [ -n "$art" ] && [ -n "$w" ] && [ -n "$h" ] && [ "$w" -le 512 ] && [ "$h" -le 512 ] && [ "$w" -gt 0 ] && [ "$h" -gt 0 ]; then
    pass "media.art arrived at ${w}x${h} (<= 512), $(printf '%s' "$art" | sed -n 's/.* size=\([0-9]*\).*/\1/p') bytes"
  else
    fail "no sane media.art line (${art:-nothing})"
  fi

  position_ms="$(sed -n 's/.*seek positionMs=\([0-9]*\).*/\1/p' "$position" | tail -1)"
  if [ -n "$position_ms" ]; then
    pass "the fake session logged a seek (positionMs=$position_ms)"
  else
    fail "the fake session logged no seek"
  fi
  if [ -n "$position_ms" ] && watch_states "$watch" |
      sed -n 's/.* positionMs=\([0-9]*\).*/\1/p' |
      awk -v p="$position_ms" '($1 - p < 2500) && (p - $1 < 2500) { found = 1 } END { exit !found }'; then
    pass "a media.state is near the seek"
  else
    fail "no media.state near the seek"
  fi

  level="$(sed -n 's/.*volume level=\([0-9]*\) max=\([0-9]*\).*/\1 \2/p' "$volume" | tail -1)"
  if [ -n "$level" ]; then
    pass "the fake session logged a volume (level/max $level)"
  else
    fail "the fake session logged no volume"
  fi
  if [ -n "$level" ] && watch_states "$watch" |
      sed -n 's/.* volume=\([0-9]*\)\/.*/\1/p' |
      grep -qx "$(printf '%s' "$level" | awk '{print $1}')"; then
    pass "media.state reflects the volume"
  else
    fail "media.state does not reflect the volume"
  fi

  local chosen_key
  chosen_key="$(last_state_field "$watch" key)"
  if [ -n "$chosen_key" ] && [ "$chosen_key" != "-" ]; then
    pass "media.state carries the chosen key (${#chosen_key} chars)"
  else
    fail "media.state carries no key"
  fi
}

if [ "$MODE" = "self-test" ]; then
  T="$(mktemp -d "${TMPDIR:-/tmp}/media-selftest.XXXXXX")"
  cat > "$T/watch.log" <<'EOF'
notify.state on=true
media.sessions n=2 playing=1 chosen=s1 keys=s1,s2
media.state playing=true key=s1 titleLen=9 durationMs=180000 positionMs=10000 rate=1.00 canSeek=true volume=8/15
media.art key=s1 mime=image/jpeg w=512 h=512 size=21000
media.sessions n=2 playing=2 chosen=s2 keys=s1,s2
media.state playing=true key=s2 titleLen=9 durationMs=180000 positionMs=45000 rate=1.00 canSeek=true volume=3/15
media.sessions n=1 playing=1 chosen=s2 keys=s2
EOF
  cat > "$T/position.log" <<'EOF'
seek positionMs=45000
EOF
  cat > "$T/volume.log" <<'EOF'
volume level=3 max=15
EOF
  check_boot "$T/watch.log" "$T/position.log" "$T/volume.log"
  [ "$FAILED" = "0" ] && echo "SELF-TEST PASS" || echo "SELF-TEST FAIL"
  rm -rf "$T"
  exit "$FAILED"
fi

# ---- --check: everything that can be wrong before a boot -------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  bash tools/emulator/preflight.sh || { echo "CHECK FAIL: preflight"; exit 1; }
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
    echo "CHECK FAIL: $SERIAL is already running (not ours to touch)"
    exit 1
  fi
  "$PYTHON" - <<'PY' || { echo "CHECK FAIL: deckctl media parser"; exit 1; }
import sys
sys.path.insert(0, "tools/fakephone")
import deckctl
parser = deckctl.build_parser()
args = parser.parse_args(["media", "watch", "--seconds", "1"])
assert args.command == "media" and args.what == "watch"
args = parser.parse_args(["media", "seek", "--position", "1000"])
assert args.position == 1000
args = parser.parse_args(["media", "volume", "--level", "3"])
assert args.level == 3
args = parser.parse_args(["media", "choose", "--key", "s2"])
assert args.key == "s2"
PY
  "$PYTHON" tools/fakephone/fakephone.py --help >/dev/null 2>&1 \
    || { echo "CHECK FAIL: fakephone --help"; exit 1; }
  "$PYTHON" tools/fakephone/fakephone.py --help 2>&1 | grep -q -- "--older-phone" \
    || { echo "CHECK FAIL: fakephone has no --older-phone"; exit 1; }
  # The receiver checks the intent's action first: a helper that sends only the
  # component delivers a broadcast the debug code ignores (this is how the
  # fake sessions stayed at zero on two boots).
  ( emu() { echo "$@"; }; debug_broadcast dev.pocketdeck.DEBUG_MEDIA --es op start ) |
    grep -q -- "-a dev.pocketdeck.DEBUG_MEDIA" \
    || { echo "CHECK FAIL: debug_broadcast drops the action"; exit 1; }
  echo "CHECK OK: preflight, deckctl media, fakephone flags; $SERIAL free"
  exit 0
fi

# ---- the run (ONE boot, or a rig verify-batch.sh already booted) -----------
if [ "$BOOT" -eq 1 ] && "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "media: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() { "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true; }
if [ "$BOOT" -eq 1 ]; then
  trap 'kill_emulator' EXIT
fi

if [ "$BOOT" -eq 1 ]; then
  echo "media: booting $SERIAL (one boot budget)"
  bash tools/emulator/start.sh --no-build || { echo "media: start.sh failed"; exit 1; }
  echo "media: up"
else
  device_present || { echo "media: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
fi

# --- the phone's own notify opt-in (media travels under the same gate) ------
PREFS="$OUT/prefs.xml"
emu shell "run-as dev.pocketdeck cat shared_prefs/pocketdeck.xml" > "$PREFS" 2>/dev/null || {
  echo "media: cannot read prefs"; exit 1; }
"$PYTHON" - "$PREFS" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
if 'name="notify_shared"' not in text:
    text = text.replace("</map>", '    <boolean name="notify_shared" value="true" />\n</map>')
open(path, "w").write(text)
PY
emu shell "run-as dev.pocketdeck sh -c 'cat > shared_prefs/pocketdeck.xml'" < "$PREFS" || {
  echo "media: cannot write prefs"; exit 1; }
emu shell am force-stop dev.pocketdeck >/dev/null 2>&1 || true
sleep 1
emu shell am start -n dev.pocketdeck/.app.MainActivity >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  [ -n "$(emu shell "pidof dev.pocketdeck" 2>/dev/null | tr -d '\r')" ] && break
  sleep 1
done
for _ in $(seq 1 90); do
  ensure_forward >/dev/null 2>&1 && break
  sleep 1
done
emu shell cmd notification allow_listener dev.pocketdeck/dev.pocketdeck.app.PdNotificationListener >/dev/null 2>&1 || true
# Without the bound listener the phone has no media sessions to list, and the
# whole section would time out with nothing to show. Wait for the setting, and
# say so loudly when it never appears (component names only, no content).
listener_enabled() {
  emu shell settings get secure enabled_notification_listeners 2>/dev/null |
    tr -d '\r' | grep -q 'dev.pocketdeck'
}
LISTENER=0
for _ in $(seq 1 20); do
  if listener_enabled; then LISTENER=1; break; fi
  emu shell cmd notification allow_listener dev.pocketdeck/dev.pocketdeck.app.PdNotificationListener >/dev/null 2>&1 || true
  sleep 1
done
if [ "$LISTENER" -ne 1 ]; then
  echo "media: the notification listener is not enabled; media.sessions cannot list anything"
fi
echo "media: prefs + listener grant done (listener enabled=$LISTENER)"

# --- pair (the real v2 flow) ----------------------------------------------
if [ "$BOOT" -eq 1 ]; then
  if ! "$PYTHON" tools/emulator/poc.py --state "$CACHE_DIR/deckctl-state.json" \
        --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair; then
    echo "media: pairing failed (unverified)"
    exit 1
  fi
  echo "media: paired"
fi

# --- two fake media sessions, the debug build's own ------------------------
start_fake() {
  debug_broadcast dev.pocketdeck.DEBUG_MEDIA \
    --es op start --ei index "$1" >> "$OUT/broadcast.log" || true
}
start_fake 1
sleep 2
start_fake 2
sleep 3
: > "$EVIDENCE"
media_evidence "fake sessions started"
emu logcat -c >/dev/null 2>&1 || true

wait_watch() { # wait_watch PATTERN SECONDS
  local i
  for i in $(seq 1 "$2"); do
    grep -q "$1" "$WATCH" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# One deckctl session drives it: the phone allows one connection, so the seek,
# the volume and the choose travel on the same session as the watch. The
# sequence is 3 s seek, 6 s volume, 9 s choose (deckctl media drive).
"${DC[@]}" media drive --seconds 40 --position 45000 --level 3 > "$WATCH" 2>&1 &
WATCH_PID=$!
wait_watch '^media.sessions n=2 ' 25 || fail "no two-session list (see $WATCH)"
FIRST_CHOSEN="$(watch_sessions "$WATCH" | awk '{print $3}')"
sleep 5
emu logcat -d -s PdMediaDebug:I 2>/dev/null | tr -d '\r' > "$FAKEP" || true
sleep 4
emu logcat -d -s PdMediaDebug:I 2>/dev/null | tr -d '\r' > "$FAKEV" || true

# The drive chooses the other session at 9 s; wait for that before stopping one.
chosen_switched() {
  local last
  last="$(watch_sessions "$WATCH" | awk '{print $3}')"
  [ -n "$last" ] && [ -n "$FIRST_CHOSEN" ] && [ "$last" != "$FIRST_CHOSEN" ]
}
wait_chosen() {
  local i
  for i in $(seq 1 20); do
    chosen_switched && return 0
    sleep 1
  done
  return 1
}
wait_chosen || fail "media.choose did not switch the chosen session"

# Stop the second fake session: the list shrinks to one.
debug_broadcast dev.pocketdeck.DEBUG_MEDIA --es op stop --ei index 2 \
  >> "$OUT/broadcast.log" || true
wait_watch '^media.sessions n=1 ' 20 || fail "the list did not shrink after a session stopped"

kill $WATCH_PID >/dev/null 2>&1 || true
wait $WATCH_PID 2>/dev/null || true
media_evidence "after drive"
check_boot "$WATCH" "$FAKEP" "$FAKEV"

if [ "$FAILED" -ne 0 ]; then
  # The next boot is not allowed, so a failed section must carry the phone's own
  # account of it: the debug session's lines, the server's, and which listeners
  # are enabled (component names only).
  media_evidence "failed"
  EMULOG="$OUT/media-logcat.log"
  emu logcat -d -s PdMediaDebug:I PocketDeckSvc:I PocketDeckApp:I 2>/dev/null |
    tr -d '\r' | tail -60 > "$EMULOG" || true
  echo "media: logcat evidence ($EMULOG):"
  tail -12 "$EMULOG"
  echo "media: enabled notification listeners: $(emu shell settings get secure enabled_notification_listeners 2>/dev/null | tr -d '\r')"
fi
{
  echo "sessions: $(watch_sessions "$WATCH")"
  echo "art: $(watch_art "$WATCH")"
  echo "seek: $(tail -1 "$FAKEP" 2>/dev/null)"
  echo "volume: $(tail -1 "$FAKEV" 2>/dev/null)"
  echo "states: $(watch_states "$WATCH" | wc -l | tr -d ' ')"
  echo "failed: $FAILED"
} > "$RESULT"
cat "$RESULT"

if [ "$BOOT" -eq 1 ]; then
  kill_emulator
fi
exit "$FAILED"
