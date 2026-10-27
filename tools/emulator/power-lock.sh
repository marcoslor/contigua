#!/usr/bin/env bash
# The person's power press while an app window streams — ONE boot. L1/L2:
# docs/PROTOCOL.md "Phone screen", docs/NFR.md "No stale picture".
#
#   tools/emulator/power-lock.sh            the run (heavy.sh owns the lock and
#                                           the boot budget)
#   tools/emulator/power-lock.sh --no-boot  the same checks on a rig that is
#                                           already up and paired
#   tools/emulator/power-lock.sh --check    a dry run: syntax, preflight, the
#                                           deckctl verbs, the log parser's
#                                           fixtures, the serial — no device
#
# Run it as `bash tools/emulator/power-lock.sh` (the exec bit is not relied on).
#
# What it proves (debug.pocketdeck.force_panel_off=1 and
# debug.pocketdeck.vd_panel_group=1 give AOSP the One UI shape, where the VD
# shares display 0's power group):
#   (a) KEYCODE_POWER while a window streams: the phone sees the
#       not-interactive edge and takes the panel over at once;
#   (b) the VD's next frame follows the edge by under 500 ms (the goal);
#   (c) the phone sent `power.locked` to the Mac;
#   (d) the press still locked the phone (keyguard showing) — nothing here
#       dismisses it, unlocks it or changes a lock setting.
# The evidence is the app's own state lines and the gap it measures, never
# pixels. Results go to .agent/emu/power-lock.log.
set -u

MODE=run
BOOT=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "power-lock.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47813}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/emu"
export POCKETDECK_FORCE_PANEL_OFF=1
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
RESULT="$OUT/power-lock.log"
PD_INSTALL_LOG="$OUT/install-failure.log"
export PD_INSTALL_LOG
LOGCAT="$OUT/power-lock-logcat.log"
DISPLAY="$OUT/power-lock-display.log"
OPENOUT="$OUT/power-lock-open.log"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$CACHE_DIR/deckctl-state.json")

FAILED=0
pass() { echo "PASS power-lock: $*"; }
fail() { echo "FAIL power-lock: $*"; FAILED=1; }

# read_press <logcat> — what the phone did at the edge, as values:
#   edge=1 when the relight line is there, streams=<n>,
#   taken_ms=<the VD group wake after the edge>, frame_ms=<the first frame's
#   gap>, locked=1 when it told the Mac, dark=1 for a panel-dark plan.
read_press() {
  "$PYTHON" - "$1" <<'PRESS'
import re, sys
lines = [l.rstrip() for l in open(sys.argv[1], errors="replace")]
edge = streams = taken = frame = locked = dark = None
for line in lines:
    m = re.search(r"power: screen off with (\d+) stream\(s\) up; VD group woken (\d+)ms after the edge", line)
    if m:
        edge = 1
        streams = int(m.group(1))
        taken = int(m.group(2))
    m = re.search(r"power: display (\d+) frame (\d+)ms after the screen-off edge", line)
    if m:
        frame = int(m.group(2))
    if "power.locked: telling the Mac the screen went off" in line:
        locked = 1
    if "PanelPlan(" in line and "panelOff=true" in line:
        dark = 1
print("edge=%s" % ("1" if edge else "0"))
print("streams=%s" % ("none" if streams is None else streams))
print("taken_ms=%s" % ("none" if taken is None else taken))
print("frame_ms=%s" % ("none" if frame is None else frame))
print("locked=%s" % ("1" if locked else "0"))
print("dark=%s" % ("1" if dark else "0"))
PRESS
}

press_value() { printf '%s\n' "$PRESS" | sed -n "s/^$1=//p"; }

# ---- --check: everything that can be wrong before a boot -------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  PD_PREFLIGHT_DRY_RUN=1 bash tools/emulator/preflight.sh ||
    { echo "CHECK FAIL: preflight"; exit 1; }
  "$PYTHON" - <<'PY' || { echo "CHECK FAIL: deckctl open verbs"; exit 1; }
import sys
sys.path.insert(0, "tools/fakephone")
import deckctl
parser = deckctl.build_parser()
args = parser.parse_args(["open", "com.android.settings", "--w", "640", "--h", "480",
                          "--dpi", "160", "--seconds", "25"])
assert args.command == "open" and args.w == 640 and args.seconds == 25
PY
  # The parser must read the shape a good press leaves...
  FIX="$OUT/power-lock-fixture.log"
  cat > "$FIX" <<'FIXTURE'
10-27 02:10:00.000 I/PocketDeckSvc: keepalive step 1 interval=2000ms displayLocks=0
10-27 02:10:03.000 I/PocketDeckSvc: power: screen off with 1 stream(s) up; VD group woken 12ms after the edge, panel taken over
10-27 02:10:03.030 I/PocketDeckSvc: power.locked: telling the Mac the screen went off
10-27 02:10:03.120 I/PocketDeckSvc: power: panel OFF -> PanelPlan(wake=true, panelOff=true, transitional=true)
10-27 02:10:03.160 I/PocketDeckSvc: power: display 57 frame 160ms after the screen-off edge
FIXTURE
  PRESS="$(read_press "$FIX")"
  [ "$(press_value edge)" = "1" ] && [ "$(press_value streams)" = "1" ] \
    && [ "$(press_value taken_ms)" = "12" ] && [ "$(press_value frame_ms)" = "160" ] \
    && [ "$(press_value locked)" = "1" ] && [ "$(press_value dark)" = "1" ] \
    || { echo "CHECK FAIL: the parser missed the good press ($PRESS)"; exit 1; }
  # ...and a press that was only handled at the next keep-alive step (no edge
  # line, no frame line) must read as no evidence, not as zero.
  cat > "$FIX" <<'FIXTURE'
10-27 02:10:00.000 I/PocketDeckSvc: keepalive step 1 interval=2000ms displayLocks=0
10-27 02:10:03.000 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=true)
FIXTURE
  PRESS="$(read_press "$FIX")"
  [ "$(press_value edge)" = "0" ] && [ "$(press_value frame_ms)" = "none" ] \
    || { echo "CHECK FAIL: the parser invented an edge ($PRESS)"; exit 1; }
  rm -f "$FIX"
  echo "CHECK OK: preflight, deckctl open, parser fixtures; $( [ "$("$ADB" devices 2>/dev/null | grep -c "^$SERIAL")" = "0" ] && echo "$SERIAL free" || echo "$SERIAL RUNNING")"
  exit 0
fi

# ---- the run (ONE boot, or a rig verify-batch.sh already booted) ------------
if [ "$BOOT" -eq 1 ] && "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "power-lock: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() {
  if [ "$BOOT" -eq 1 ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  fi
}
trap 'kill_emulator' EXIT

if [ "$BOOT" -eq 1 ]; then
  echo "power-lock: booting $SERIAL (one boot budget)"
  if ! bash tools/emulator/start.sh --no-build; then
    echo "power-lock: start.sh failed; restarting the shell service"
    if ! restart_server; then
      echo "power-lock: the shell service never came up (unverified)"
      { echo "failed: 1 (start)"; cat "$PD_INSTALL_LOG" 2>/dev/null; } > "$RESULT"
      exit 1
    fi
  fi
  # The two shapes One UI has and AOSP does not: the panel-dark policy and a
  # VD in display 0's power group. Both are read when the policy/VD is built.
  emu shell setprop debug.pocketdeck.force_panel_off 1 >/dev/null 2>&1 || true
  emu shell setprop debug.pocketdeck.vd_panel_group 1 >/dev/null 2>&1 || true
  if [ "$(emu shell getprop debug.pocketdeck.force_panel_off | tr -d '\r')" != "1" ] \
    || [ "$(emu shell getprop debug.pocketdeck.vd_panel_group | tr -d '\r')" != "1" ]; then
    fail "the debug properties did not stick"
  fi
  if ! restart_server; then
    echo "power-lock: the app did not come back with the forced path (unverified)"
    echo "failed: 1 (restart)" > "$RESULT"
    exit 1
  fi
  INIT_LINE="$(emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
    grep 'power: panel power control' | tail -1 | tr -d '\r')"
  case "$INIT_LINE" in
    *"forcing the panel-dark path"*) echo "power-lock: init: $INIT_LINE" ;;
    *)
      echo "power-lock: the server did not start forced (init: ${INIT_LINE:-none})"
      { echo "failed: 1 (not-forced)"; echo "init: ${INIT_LINE:-none}"; } > "$RESULT"
      exit 1
      ;;
  esac
  # A prompt is an app dialog, and a sleeping screen hides it from the rig's
  # reads (the notification dump and uiautomator both return nothing).
  emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  sleep 1
  if ! "$PYTHON" tools/emulator/poc.py --state "$CACHE_DIR/deckctl-state.json" \
        --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair \
        --timeout 90 --tap-timeout 90; then
    echo "power-lock: pairing failed (unverified)"
    exit 1
  fi
  echo "power-lock: up and paired"
else
  device_present || { echo "power-lock: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
fi
ensure_forward >/dev/null || { echo "power-lock: no server port"; echo "failed: 1 (port)" > "$RESULT"; exit 1; }

# A clean log: everything below reads this run's own lines.
emu logcat -c >/dev/null 2>&1 || true

# The person's own screen, awake, with one app window streaming on it. The wake
# is display 0 only (KEYCODE_WAKEUP): nothing here unlocks the phone. It also
# comes before pairing (the rig pairs above, before this): the prompt is an app
# dialog, and a sleeping screen hides it from both the notification dump and
# uiautomator.
emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
sleep 2

: > "$OPENOUT"
"${DC[@]}" open com.android.settings --w 640 --h 480 --dpi 160 --seconds 25 \
  >> "$OPENOUT" 2>&1 &
OPEN_PID=$!
STREAMING=0
for _ in $(seq 1 80); do
  # The VD line, not "first frame": that line only prints when the redraw
  # guard nudged an app, so a healthy stream can run without it (boot 3 of this
  # rig waited 30 s on it and pressed after the window had closed).
  if emu logcat -d -s PocketDeckSvc:I 2>/dev/null | tr -d '\r' |
      grep -q 'stream 1 vd='; then
    STREAMING=1
    break
  fi
  kill -0 "$OPEN_PID" 2>/dev/null || break
  sleep 0.5
done
if [ "$STREAMING" -ne 1 ]; then
  fail "no streaming window before the press ($(tail -2 "$OPENOUT" | tr '\n' ' '))"
fi
# A moment of frames, so the stream is in its steady state before the press.
sleep 3
if ! kill -0 "$OPEN_PID" 2>/dev/null; then
  fail "the window closed before the press"
else
  emu shell input keyevent KEYCODE_POWER >/dev/null 2>&1 || true
fi
sleep 6
emu shell dumpsys window policy 2>/dev/null | tr -d '\r' > "$DISPLAY" || true
wait "$OPEN_PID"
OPEN_RC=$?

emu logcat -d -s PocketDeckSvc:I PocketDeckApp:I 2>/dev/null | tr -d '\r' > "$LOGCAT" || true
PRESS="$(read_press "$LOGCAT")"
EDGE="$(press_value edge)"
STREAMS="$(press_value streams)"
TAKEN="$(press_value taken_ms)"
FRAME="$(press_value frame_ms)"
LOCKED="$(press_value locked)"
DARK="$(press_value dark)"

if [ "$OPEN_RC" -ne 0 ]; then
  fail "the window did not stream through the press (rc=$OPEN_RC): $(tail -2 "$OPENOUT" | tr '\n' ' ')"
fi
if [ "${EDGE:-0}" -eq 1 ] && [ "${STREAMS:-0}" -ge 1 ]; then
  pass "the press was taken at the edge with $STREAMS stream(s) up (VD group woken ${TAKEN}ms after it)"
else
  fail "the phone never took the panel over at the edge (edge=$EDGE streams=$STREAMS)"
fi
# The goal: the VD's next frame within 500 ms of the not-interactive edge.
if [ "${FRAME:-none}" != "none" ] && [ "${FRAME:-9999}" -lt 500 ]; then
  pass "the VD's next frame came ${FRAME} ms after the screen-off edge (goal < 500)"
else
  fail "the VD's next frame came ${FRAME} ms after the screen-off edge (goal < 500)"
fi
if [ "${DARK:-0}" -eq 1 ]; then
  pass "the take-over used the PANEL_DARK plan (wake, then panel off)"
else
  fail "no panel-dark plan followed the press"
fi
if [ "${LOCKED:-0}" -eq 1 ]; then
  pass "the phone told the Mac it locked (power.locked)"
else
  fail "the phone never sent power.locked"
fi
# The keyguard is the person's: the press locked the phone and nothing here
# dismisses or unlocks it.
if grep -qE 'keyguardShowing=true|showing=true' "$DISPLAY"; then
  pass "the press locked the phone (keyguard showing; never dismissed)"
else
  fail "the keyguard was not showing after the press (nothing here may dismiss it)"
fi

{
  echo "edge: $EDGE streams=$STREAMS taken_ms=$TAKEN frame_ms=$FRAME locked=$LOCKED dark=$DARK"
  echo "open: rc=$OPEN_RC $(head -2 "$OPENOUT" | tr '\n' ' ')"
  echo "keyguard: $(grep -m1 -E 'keyguardShowing|showing=' "$DISPLAY" | tr -s ' ')"
  echo "failed: $FAILED"
} > "$RESULT"
cat "$RESULT"

if [ "$FAILED" -ne 0 ]; then
  EMULOG="$OUT/power-lock-logcat-tail.log"
  grep -E 'power:|power.locked|keepalive|stream 1' "$LOGCAT" | tail -40 > "$EMULOG" || true
  echo "power-lock: logcat evidence ($EMULOG):"
  tail -12 "$EMULOG"
fi

if [ "$BOOT" -eq 1 ]; then
  kill_emulator
fi
exit "$FAILED"
