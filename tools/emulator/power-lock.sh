#!/usr/bin/env bash
# The person's power press while an app window streams — ONE boot. L1/L2:
# docs/PROTOCOL.md "Phone screen", docs/NFR.md "No stale picture".
#
#   tools/emulator/power-lock.sh            the run (it runs under the lock and
#                                           the boot budget)
#   tools/emulator/power-lock.sh --no-boot  the same checks on a rig that is
#                                           already up and paired
#   tools/emulator/power-lock.sh --check    a dry run: syntax, preflight, the
#                                           deckctl verbs, the log parser's
#                                           fixtures, the serial — no device
#
# Run it as `bash tools/emulator/power-lock.sh` (the exec bit is not relied on).
#
# What it proves (debug.contigua.force_panel_off=1 and
# debug.contigua.vd_panel_group=1 give AOSP the One UI shape, where the VD
# shares display 0's power group):
#   (a) KEYCODE_POWER while a window streams: the phone sees the
#       not-interactive edge and takes the panel over at once;
#   (b) the VD's next frame follows the edge by under 500 ms (the goal);
#   (c) the phone sent `power.locked` to the Mac;
#   (d) the press still locked the phone (keyguard showing) — nothing here
#       dismisses it, unlocks it or changes a lock setting.
# The evidence is the app's own state lines and the gap it measures, never
# pixels. Results go to .work/emu/power-lock.log.
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
export CONTIGUA_PORT="${CONTIGUA_PORT:-47813}"
export CONTIGUA_SERIAL=emulator-5554
export CONTIGUA_AGENT_DIR="$PWD/.work/emu"
export CONTIGUA_FORCE_PANEL_OFF=1
mkdir -p "$CONTIGUA_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$CONTIGUA_AGENT_DIR"
RESULT="$OUT/power-lock.log"
PD_INSTALL_LOG="$OUT/install-failure.log"
export PD_INSTALL_LOG
LOGCAT="$OUT/power-lock-logcat.log"
# The run's whole ContiguaSvc log, saved before the emulator is killed (the
# next run's evidence, and the field log's shape for whoever reads it).
LOGCAT_FULL="$OUT/power-lock-logcat.txt"
DISPLAY="$OUT/power-lock-display.log"
OPENOUT="$OUT/power-lock-open.log"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$CACHE_DIR/deckctl-state.json")

FAILED=0
pass() { echo "PASS power-lock: $*"; }
fail() { echo "FAIL power-lock: $*"; FAILED=1; }

# read_press <logcat> — what the phone did at the edge, as values:
#   edge=1 when the relight line is there; issued_ms/returned_ms/off_ms = the
#   wake and the panel-off after the edge; gap_ms = the largest gap between
#   consecutive VD frames around it, frames = how many frames the window saw;
#   display = the stream the line names; locked=1 when it told the Mac;
#   dark=1 for a panel-dark plan.
read_press() {
  "$PYTHON" - "$1" <<'PRESS'
import re, sys
lines = [l.rstrip() for l in open(sys.argv[1], errors="replace")]
edge = issued = returned = off = gap = frames = display = locked = dark = None
for line in lines:
    m = re.search(r"power: relight edge\+(\d+)ms wake issued, \+(\d+)ms wake returned, \+(\d+)ms panel off returned", line)
    if m:
        edge = 1
        issued, returned, off = int(m.group(1)), int(m.group(2)), int(m.group(3))
    m = re.search(r"power: display (\d+) max frame gap (\d+)ms around the screen-off edge \(frames=(\d+)\)", line)
    if m:
        display, gap, frames = int(m.group(1)), int(m.group(2)), int(m.group(3))
    if "power.locked: telling the Mac the screen went off" in line:
        locked = 1
    if "PanelPlan(" in line and "panelOff=true" in line:
        dark = 1
print("edge=%s" % ("1" if edge else "0"))
print("issued_ms=%s" % ("none" if issued is None else issued))
print("returned_ms=%s" % ("none" if returned is None else returned))
print("off_ms=%s" % ("none" if off is None else off))
print("gap_ms=%s" % ("none" if gap is None else gap))
print("frames=%s" % ("none" if frames is None else frames))
print("display=%s" % ("none" if display is None else display))
print("locked=%s" % ("1" if locked else "0"))
print("dark=%s" % ("1" if dark else "0"))
PRESS
}

# gap_ok — the press gap's rule: a real gap (two frames at least) under 500 ms.
gap_ok() {
  [ "${GAP:-none}" != "none" ] && [ "${GAP:-99999}" -lt 500 ] && [ "${FRAMES:-0}" -ge 2 ]
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
  # The parser must read the shape a good press leaves: one relight line with
  # the three step times, and one max-gap line under the goal...
  FIX="$OUT/power-lock-fixture.log"
  cat > "$FIX" <<'FIXTURE'
10-27 02:10:00.000 I/ContiguaSvc: keepalive step 1 interval=2000ms displayLocks=0
10-27 02:10:03.000 I/ContiguaSvc: power: relight edge+2ms wake issued, +14ms wake returned, +2044ms panel off returned
10-27 02:10:03.030 I/ContiguaSvc: power.locked: telling the Mac the screen went off
10-27 02:10:03.120 I/ContiguaSvc: power: panel OFF -> PanelPlan(wake=true, panelOff=true, transitional=true)
10-27 02:10:06.500 I/ContiguaSvc: power: display 57 max frame gap 234ms around the screen-off edge (frames=9)
FIXTURE
  PRESS="$(read_press "$FIX")"
  GAP="$(press_value gap_ms)"; FRAMES="$(press_value frames)"
  [ "$(press_value edge)" = "1" ] && [ "$(press_value issued_ms)" = "2" ] \
    && [ "$(press_value returned_ms)" = "14" ] && [ "$(press_value off_ms)" = "2044" ] \
    && [ "$(press_value display)" = "57" ] && [ "$GAP" = "234" ] && [ "$FRAMES" = "9" ] \
    && [ "$(press_value locked)" = "1" ] && [ "$(press_value dark)" = "1" ] \
    && gap_ok \
    || { echo "CHECK FAIL: the parser missed the good press ($PRESS)"; exit 1; }
  # A gap of 600 ms (or a window with a single frame) must be rejected: the
  # goal is under 500 ms and a gap needs two frames to mean anything.
  cat > "$FIX" <<'FIXTURE'
10-27 02:10:03.000 I/ContiguaSvc: power: relight edge+2ms wake issued, +14ms wake returned, +2100ms panel off returned
10-27 02:10:06.500 I/ContiguaSvc: power: display 57 max frame gap 600ms around the screen-off edge (frames=9)
FIXTURE
  PRESS="$(read_press "$FIX")"
  GAP="$(press_value gap_ms)"; FRAMES="$(press_value frames)"
  if gap_ok; then echo "CHECK FAIL: a 600 ms gap passed the rule ($PRESS)"; exit 1; fi
  cat > "$FIX" <<'FIXTURE'
10-27 02:10:03.000 I/ContiguaSvc: power: relight edge+2ms wake issued, +14ms wake returned, +2100ms panel off returned
10-27 02:10:06.500 I/ContiguaSvc: power: display 57 max frame gap 0ms around the screen-off edge (frames=1)
FIXTURE
  PRESS="$(read_press "$FIX")"
  GAP="$(press_value gap_ms)"; FRAMES="$(press_value frames)"
  if gap_ok; then echo "CHECK FAIL: a single-frame window passed the rule ($PRESS)"; exit 1; fi
  # ...and a press that was only handled at the next keep-alive step (no
  # relight line, no gap line) must read as no evidence, not as zero.
  cat > "$FIX" <<'FIXTURE'
10-27 02:10:00.000 I/ContiguaSvc: keepalive step 1 interval=2000ms displayLocks=0
10-27 02:10:03.000 I/ContiguaSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=true)
FIXTURE
  PRESS="$(read_press "$FIX")"
  [ "$(press_value edge)" = "0" ] && [ "$(press_value gap_ms)" = "none" ] \
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
  emu shell setprop debug.contigua.force_panel_off 1 >/dev/null 2>&1 || true
  emu shell setprop debug.contigua.vd_panel_group 1 >/dev/null 2>&1 || true
  if [ "$(emu shell getprop debug.contigua.force_panel_off | tr -d '\r')" != "1" ] \
    || [ "$(emu shell getprop debug.contigua.vd_panel_group | tr -d '\r')" != "1" ]; then
    fail "the debug properties did not stick"
  fi
  if ! restart_server; then
    echo "power-lock: the app did not come back with the forced path (unverified)"
    echo "failed: 1 (restart)" > "$RESULT"
    exit 1
  fi
  INIT_LINE="$(emu logcat -d -s ContiguaSvc:I 2>/dev/null |
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
  if emu logcat -d -s ContiguaSvc:I 2>/dev/null | tr -d '\r' |
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

emu logcat -d -s ContiguaSvc:I ContiguaApp:I 2>/dev/null | tr -d '\r' > "$LOGCAT" || true
# The full service log, kept even when the run fails: the next boot's evidence.
emu logcat -d -s ContiguaSvc:I 2>/dev/null | tr -d '\r' > "$LOGCAT_FULL" || true
PRESS="$(read_press "$LOGCAT")"
EDGE="$(press_value edge)"
ISSUED="$(press_value issued_ms)"
RETURNED="$(press_value returned_ms)"
OFF="$(press_value off_ms)"
GAP="$(press_value gap_ms)"
FRAMES="$(press_value frames)"
DISP="$(press_value display)"
LOCKED="$(press_value locked)"
DARK="$(press_value dark)"

if [ "$OPEN_RC" -ne 0 ]; then
  fail "the window did not stream through the press (rc=$OPEN_RC): $(tail -2 "$OPENOUT" | tr '\n' ' ')"
fi
if [ "${EDGE:-0}" -eq 1 ]; then
  pass "the press was taken at the edge (wake issued +${ISSUED}ms, returned +${RETURNED}ms, panel off returned +${OFF}ms)"
else
  fail "the phone never took the panel over at the edge (edge=$EDGE)"
fi
# The goal: no silence between consecutive VD frames around the edge above
# 500 ms. A gap needs two frames in the window to mean anything.
if gap_ok; then
  pass "the largest frame gap around the press was ${GAP} ms on display ${DISP} (goal < 500; frames=${FRAMES})"
else
  fail "the largest frame gap around the press was ${GAP:-none} ms (goal < 500; frames=${FRAMES:-none})"
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
  echo "edge: $EDGE issued_ms=$ISSUED returned_ms=$RETURNED off_ms=$OFF gap_ms=$GAP frames=$FRAMES display=$DISP locked=$LOCKED dark=$DARK"
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
