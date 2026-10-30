#!/usr/bin/env bash
# An app window opened on a locked, screen-off phone — ONE boot (WIN-23,
# docs/PROTOCOL.md "Phone screen" point 6, docs/NFR.md `first_frame_ms`).
#
#   bash tools/emulator/locked-open.sh            the run (heavy.sh owns the lock
#                                                 and the boot budget)
#   bash tools/emulator/locked-open.sh --no-boot  the same checks on a rig that is
#                                                 already up and paired
#   bash tools/emulator/locked-open.sh --check    a dry run: syntax, preflight,
#                                                 the driver's self-test, the
#                                                 parser and the rules on
#                                                 fixtures, the serial — no device
#
# Run it as `bash tools/emulator/locked-open.sh` (the exec bit is not relied on).
#
# What it proves (debug.pocketdeck.force_panel_off=1 and
# debug.pocketdeck.vd_panel_group=1 give AOSP the One UI shape, where the VD
# shares display 0's power group):
#   (1) an app window opened with the phone locked and its screen off reaches
#       its first frame within `first_frame_ms` (NFR.md), not the 23 s of the
#       10-30 report;
#   (2) the episode's take-over (the group wake) ran before the activity
#       launch, with the panel-off following it;
#   (3) a touch on the window's picture reaches the app: the app opens a screen,
#       and the platform logs no `ActivityRecordInputSink … NO_INPUT_CHANNEL`;
#   (4) the picture never goes silent for more than 1.5 s while it is open (the
#       "Not responding" rule, WIN-17);
#   (5) the phone is still locked and its panel was powered off under the
#       stream (WIN-20, the product promise).
#
# A control open with the phone awake runs first: it proves the tap target is a
# real control, so a locked run with no app reaction is the phone's fault and
# not the script's coordinates.
#
# The evidence is the phone's own state lines and the session's own timings,
# never pixels: .agent/locked-input/locked-open.log, -logcat.txt, -display-*.log.
set -u

MODE=run
BOOT=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "locked-open.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47996}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/locked-input"
# start.sh sets this property before it launches the server, so the policy is
# built forced. vd_panel_group is set below, before the server restarts.
export POCKETDECK_FORCE_PANEL_OFF=1
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
RESULT="$OUT/locked-open.log"
PD_INSTALL_LOG="$OUT/install-failure.log"
export PD_INSTALL_LOG
LOGCAT="$OUT/locked-open-logcat.txt"
CONTROL="$OUT/locked-open-control.log"
CONTROL_LOGCAT="$OUT/locked-open-control-logcat.txt"
OPENOUT="$OUT/locked-open-session.log"
DISPLAY_BEFORE="$OUT/locked-open-display-before.log"
DISPLAY_DURING="$OUT/locked-open-display-during.log"
SF_DURING="$OUT/locked-open-surfaceflinger-during.log"
WINDOW_AFTER="$OUT/locked-open-window-after.log"
APP="com.android.settings"
TAPS="3,5"
SECONDS_CONTROL=12
SECONDS_OPEN=25
LIMIT_MS="$("$PYTHON" -c 'import json; print(json.load(open("macos/scripts/nfr-limits.json"))["first_frame_ms"])')"

FAILED=0
pass() { echo "PASS locked-open: $*"; }
fail() { echo "FAIL locked-open: $*"; FAILED=1; }

DRIVER=("$PYTHON" tools/emulator/locked-open.py --state "$CACHE_DIR/deckctl-state.json" \
  --host 127.0.0.1 --port "$PORT" --pkg "$APP" --w 640 --h 480 --dpi 160 \
  --tap-after "$TAPS" --adb "$ADB" --serial "$SERIAL")

value() { sed -n "s/^$1=//p" "$2" | tail -1; }

# read_phone <logcat> <pkg> — the platform's own view of the run, as values:
# whether the VD started asleep, whether the take-over ran before the launch,
# how many touches fell into an input sink, and whether a tap opened a screen
# after its marker.
read_phone() {
  "$PYTHON" - "$1" "$2" <<'PHONE'
import sys
lines = [l.rstrip("\n") for l in open(sys.argv[1], errors="replace")]
pkg = sys.argv[2]

def index_of(pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]):
            return i
    return None

def show(v):
    return "none" if v is None else str(v)

created = index_of(lambda l: "Creating virtual display: pocketdeck-1" in l)
started_off = index_of(lambda l: "Changing state of virtual display pocketdeck-1 from UNKNOWN to OFF" in l)
takeover = index_of(lambda l: "power: episode take-over:" in l)
first = index_of(lambda l: "PocketDeckLockedOpen: first-frame" in l)
launch = index_of(lambda l: "START u0" in l and pkg in l)
sinks = [l for l in lines if "NO_INPUT_CHANNEL" in l]
taps = [i for i, l in enumerate(lines) if "PocketDeckLockedOpen: tap" in l]
starts = [i for i, l in enumerate(lines) if "START u0" in l and pkg in l]
tap_started = 1 if any(s > t for t in taps for s in starts) else 0
panel_off = sum(1 for l in lines if "panel power mode -> OFF" in l)
dark_plan = index_of(lambda l: "PanelPlan(" in l and "panelOff=true" in l)
wake_lock = index_of(lambda l: "display wake lock held" in l)
display_off = index_of(lambda l: 'Display device changed state: "pocketdeck-1", OFF' in l)
display_on = index_of(lambda l: 'Display device changed state: "pocketdeck-1", ON' in l)
# The first ON edge before the first-frame marker is the one that made the
# picture possible; an ON only after it would be the app drawing into an
# already-lit display.
awake_before_frame = 1 if (display_on is not None and first is not None and display_on < first) else 0
print("sink_lines=%d" % len(sinks))
print("created=%s" % show(created))
print("started_off=%s" % show(started_off))
print("display_off=%s" % show(display_off))
print("display_on=%s" % show(display_on))
print("awake_before_frame=%d" % awake_before_frame)
print("takeover=%s" % show(takeover))
print("launch=%s" % show(launch))
print("first=%s" % show(first))
print("dark_plan=%s" % show(dark_plan))
print("wake_lock=%s" % show(wake_lock))
print("panel_off=%d" % panel_off)
print("taps=%d" % len(taps))
print("tap_started=%d" % tap_started)
print("takeover_before_launch=%d" % (1 if takeover is not None and launch is not None and takeover < launch else 0))
if sinks:
    print("sink_sample=%s" % sinks[0][:220])
PHONE
}

# verdict <first_ms> <tap_started> <sink_lines> <keyguard> <panel_off>
#         <takeover_before_launch> <frames> <max_gap_ms>
# Prints one line per failed rule; nothing when the run passes.
verdict() {
  local first="$1" tap="$2" sink="$3" guard="$4" panel="$5" order="$6" frames="$7" gap="$8"
  case "$first" in
    none|"") echo "no first frame reached the Mac" ;;
    *)
      if [ "${first%.*}" -gt "$LIMIT_MS" ]; then
        echo "first frame took ${first} ms (budget ${LIMIT_MS})"
      fi
      ;;
  esac
  [ "$tap" = "1" ] || echo "no tap opened a screen on the phone (tap_started=$tap)"
  [ "$sink" = "0" ] || echo "${sink} touch(es) fell into an ActivityRecordInputSink"
  [ "$guard" = "true" ] || echo "the keyguard is not showing after the open (${guard:-none})"
  [ "${panel:-0}" -ge 1 ] || echo "the phone never powered the panel off under the stream"
  [ "$order" = "1" ] || echo "the take-over did not run before the activity launch"
  if [ "${frames:-0}" -lt 2 ] || [ "${gap:-99999}" -gt 1500 ]; then
    echo "the picture stalled: largest gap ${gap:-none} ms over ${frames:-0} frames (limit 1500)"
  fi
}

keyguard_showing() { # keyguard_showing <dumpsys window> <dumpsys window policy>
  grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true|keyguardShowing=true' "$1" && return 0
  grep -qE 'keyguardShowing=true|showing=true' "$2" 2>/dev/null
}

# ---- --check: everything that can be wrong before a boot -------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  PD_PREFLIGHT_DRY_RUN=1 bash tools/emulator/preflight.sh ||
    { echo "CHECK FAIL: preflight"; exit 1; }
  "$PYTHON" tools/emulator/locked-open.py --self-test ||
    { echo "CHECK FAIL: driver self-test"; exit 1; }
  # The parser and the rules must read the reported shape (10-30): the VD
  # started OFF, the wake came after the launch, the taps fell into a sink.
  FIX="$OUT/locked-open-fixture.log"
  cat > "$FIX" <<'FIXTURE'
10-30 15:25:30.148 D/SurfaceFlinger( 1872): Creating virtual display: pocketdeck-1
10-30 15:25:30.158 D/VirtualDisplayAdapter( 2328): Changing state of virtual display pocketdeck-1 from UNKNOWN to OFF
10-30 15:25:30.194 I/DisplayDeviceRepository( 2328): Display device changed state: "pocketdeck-1", OFF
10-30 15:25:41.379 I/ActivityTaskManager( 2328): START u0 {act=android.intent.action.MAIN flg=0x10000000 cmp=com.samsung.android.app.contacts/com.samsung.android.contacts.contactslist.PeopleActivity} from uid 2000
10-30 15:25:41.385 I/PocketDeckSvc(12981): display wake lock held (display 45, SCREEN_BRIGHT, display-scoped)
10-30 15:25:41.391 I/PocketDeckSvc(12981): power: panel OFF -> PanelPlan(wake=true, panelOff=true, transitional=true)
10-30 15:25:41.392 I/PocketDeckSvc(12981): panel power mode -> OFF (1 physical display)
10-30 15:25:41.393 I/DisplayDeviceRepository( 2328): Display device changed state: "pocketdeck-1", ON
10-30 15:25:42.159 I/PocketDeckLockedOpen: first-frame
10-30 15:26:13.000 W/InputDispatcher( 2328): Not sending touch gesture to ActivityRecordInputSink com.samsung.android.app.contacts/com.samsung.android.contacts.contactslist.PeopleActivity because it has config NO_INPUT_CHANNEL
10-30 15:26:13.100 I/PocketDeckLockedOpen: tap1
10-30 15:26:13.200 I/PocketDeckLockedOpen: tap2
FIXTURE
  BAD="$(read_phone "$FIX" com.samsung.android.app.contacts)"
  bad_value() { printf '%s\n' "$BAD" | sed -n "s/^$1=//p"; }
  [ "$(bad_value started_off)" != "none" ] || { echo "CHECK FAIL: the parser missed a VD created OFF"; exit 1; }
  [ "$(bad_value sink_lines)" -ge 1 ] || { echo "CHECK FAIL: the parser missed the input sink"; exit 1; }
  [ "$(bad_value tap_started)" = "0" ] || { echo "CHECK FAIL: the parser invented a tap that opened a screen"; exit 1; }
  [ "$(bad_value takeover_before_launch)" = "0" ] || { echo "CHECK FAIL: the parser read a late wake as a take-over"; exit 1; }
  BADVERDICT="$(verdict none 0 "$(bad_value sink_lines)" true "$(bad_value panel_off)" 0 3 900)"
  for want in "no first frame" "ActivityRecordInputSink" "take-over did not run before"; do
    printf '%s\n' "$BADVERDICT" | grep -q "$want" ||
      { echo "CHECK FAIL: the rules did not reject the reported shape ($want; got: $BADVERDICT)"; exit 1; }
  done
  # And a good run: the take-over before the launch, the wake light already on,
  # a tap that opened a screen, no sink line.
  cat > "$FIX" <<'FIXTURE'
10-30 15:25:30.148 D/SurfaceFlinger( 1872): Creating virtual display: pocketdeck-1
10-30 15:25:30.158 D/VirtualDisplayAdapter( 2328): Changing state of virtual display pocketdeck-1 from UNKNOWN to OFF
10-30 15:25:30.194 I/DisplayDeviceRepository( 2328): Display device changed state: "pocketdeck-1", OFF
10-30 15:25:30.420 I/PocketDeckSvc(12981): power: episode take-over: display 45 woken before the launch; panel off owed
10-30 15:25:30.430 I/PocketDeckSvc(12981): display wake lock held (display 45, SCREEN_BRIGHT, display-scoped)
10-30 15:25:30.450 I/ActivityTaskManager( 2328): START u0 {act=android.intent.action.MAIN cmp=com.android.settings/.Settings} from uid 2000
10-30 15:25:30.700 I/PocketDeckSvc(12981): power: panel OFF -> PanelPlan(wake=false, panelOff=true, transitional=true)
10-30 15:25:30.701 I/PocketDeckSvc(12981): panel power mode -> OFF (1 physical display)
10-30 15:25:30.702 I/DisplayDeviceRepository( 2328): Display device changed state: "pocketdeck-1", ON
10-30 15:25:31.010 I/PocketDeckLockedOpen: first-frame
10-30 15:25:34.100 I/PocketDeckLockedOpen: tap1
10-30 15:25:34.500 I/ActivityTaskManager( 2328): START u0 {act=android.intent.action.MAIN cmp=com.android.settings/.SubSettings} from uid 2000
10-30 15:25:36.100 I/PocketDeckLockedOpen: tap2
FIXTURE
  GOOD="$(read_phone "$FIX" com.android.settings)"
  good_value() { printf '%s\n' "$GOOD" | sed -n "s/^$1=//p"; }
  [ "$(good_value sink_lines)" = "0" ] || { echo "CHECK FAIL: the parser saw a sink in a clean run"; exit 1; }
  [ "$(good_value tap_started)" = "1" ] || { echo "CHECK FAIL: the parser missed the tap that opened a screen"; exit 1; }
  [ "$(good_value takeover_before_launch)" = "1" ] || { echo "CHECK FAIL: the parser missed the take-over before the launch"; exit 1; }
  [ "$(good_value awake_before_frame)" = "1" ] || { echo "CHECK FAIL: the parser missed the display-on before the first frame"; exit 1; }
  [ -z "$(verdict 700 1 0 true 1 1 9 300)" ] ||
    { echo "CHECK FAIL: a good run was rejected ($(verdict 700 1 0 true 1 1 9 300))"; exit 1; }
  [ -n "$(verdict 23000 1 0 true 1 1 9 300)" ] ||
    { echo "CHECK FAIL: a 23 s first frame passed the budget"; exit 1; }
  [ -n "$(verdict 700 1 0 true 1 0 9 300)" ] ||
    { echo "CHECK FAIL: a late take-over passed the order rule"; exit 1; }
  rm -f "$FIX"
  echo "CHECK OK: driver self-test, parser + rules on the reported and the fixed shapes; $( [ "$("$ADB" devices 2>/dev/null | grep -c "^$SERIAL")" = "0" ] && echo "$SERIAL free" || echo "$SERIAL RUNNING")"
  exit 0
fi

# ---- the run (ONE boot, or a rig verify-batch-style boot already has) ------
if [ "$BOOT" -eq 1 ] && "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "locked-open: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() {
  if [ "$BOOT" -eq 1 ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  fi
}
trap 'kill_emulator' EXIT

if [ "$BOOT" -eq 1 ]; then
  echo "locked-open: booting $SERIAL (one boot budget)"
  if ! bash tools/emulator/start.sh --no-build; then
    echo "locked-open: start.sh failed; restarting the shell service"
    if ! restart_server; then
      echo "locked-open: the shell service never came up (unverified)"
      { echo "failed: 1 (start)"; cat "$PD_INSTALL_LOG" 2>/dev/null; } > "$RESULT"
      exit 1
    fi
  fi
  # The two shapes One UI has and AOSP does not: the panel-dark policy and a VD
  # in display 0's power group. Both are read when the policy/VD is built.
  emu shell setprop debug.pocketdeck.force_panel_off 1 >/dev/null 2>&1 || true
  emu shell setprop debug.pocketdeck.vd_panel_group 1 >/dev/null 2>&1 || true
  if [ "$(emu shell getprop debug.pocketdeck.force_panel_off | tr -d '\r')" != "1" ] \
    || [ "$(emu shell getprop debug.pocketdeck.vd_panel_group | tr -d '\r')" != "1" ]; then
    fail "the debug properties did not stick"
  fi
  # start.sh installed a new APK: the Shizuku shell service can survive it, and
  # an old daemon would answer with the old policy (10-28 lesson). Kill it so
  # the restart proves which server runs.
  emu shell "pkill -f dev.pocketdeck:pocketdeck" >/dev/null 2>&1 || true
  sleep 1
  if ! restart_server; then
    echo "locked-open: the app did not come back with the forced path (unverified)"
    echo "failed: 1 (restart)" > "$RESULT"
    exit 1
  fi
  INIT_LINE="$(emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
    grep 'power: panel power control' | tail -1 | tr -d '\r')"
  case "$INIT_LINE" in
    *"forcing the panel-dark path"*) echo "locked-open: init: $INIT_LINE" ;;
    *)
      echo "locked-open: the server did not start forced (init: ${INIT_LINE:-none})"
      { echo "failed: 1 (not-forced)"; echo "init: ${INIT_LINE:-none}"; } > "$RESULT"
      exit 1
      ;;
  esac
  # The restart may have bound a new server port: pairing (and the driver) reach
  # the phone only through the forward, so re-assert it before both.
  ensure_forward >/dev/null || { echo "locked-open: no server port after restart"; exit 1; }
  # A prompt is an app dialog, and a sleeping screen hides it from the rig's
  # reads (the notification dump and uiautomator both return nothing).
  emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  sleep 1
  if ! "$PYTHON" tools/emulator/poc.py --state "$CACHE_DIR/deckctl-state.json" \
        --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair \
        --timeout 90 --tap-timeout 90; then
    echo "locked-open: pairing failed (unverified)"
    exit 1
  fi
  echo "locked-open: up and paired"
else
  device_present || { echo "locked-open: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
fi
ensure_forward >/dev/null || { echo "locked-open: no server port"; echo "failed: 1 (port)" > "$RESULT"; exit 1; }

# --- control: the same window and taps with the phone awake -----------------
# The tap target must open a screen when the phone is healthy; otherwise a
# locked run with no reaction would prove nothing about the phone.
emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
sleep 2
emu logcat -c >/dev/null 2>&1 || true
: > "$CONTROL"
"${DRIVER[@]}" --seconds "$SECONDS_CONTROL" > "$CONTROL" 2>&1
CONTROL_RC=$?
emu logcat -d > "$CONTROL_LOGCAT" 2>/dev/null || true
CONTROL_PHONE="$(read_phone "$CONTROL_LOGCAT" "$APP")"
control_value() { printf '%s\n' "$CONTROL_PHONE" | sed -n "s/^$1=//p"; }
if [ "$CONTROL_RC" -ne 0 ]; then
  fail "the control open did not stream (rc=$CONTROL_RC): $(tail -2 "$CONTROL" | tr '\n' ' ')"
elif [ "$(control_value tap_started)" != "1" ]; then
  fail "the control tap never opened a screen while the phone was awake: the tap target is wrong, not the phone ($(control_value sink_lines) sink lines)"
else
  pass "control: the same taps opened a screen with the phone awake (first frame $(value first_frame_ms "$CONTROL") ms)"
fi
# The locked open must be a cold one, like the Contacts launch of the report:
# a warm process would hide the launch the take-over has to beat.
emu shell am force-stop "$APP" >/dev/null 2>&1 || true

# --- the run: locked, screen off, the group asleep --------------------------
echo "locked-open: locking the emulator (PIN + screen off)"
bash "$EMU_DIR/lock.sh" || { fail "could not lock the emulator"; }
emu shell dumpsys window > "$WINDOW_AFTER" 2>/dev/null || true
emu shell dumpsys window policy > "$OUT/locked-open-window-policy-before.log" 2>/dev/null || true
LOCK_GUARD="$(keyguard_showing "$WINDOW_AFTER" "$OUT/locked-open-window-policy-before.log" && echo true || echo false)"
WAKE_STATE="$(emu shell dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | tr -d '\r' | sed 's/.*mWakefulness=//')"
emu shell dumpsys display 2>/dev/null | tr -d '\r' > "$DISPLAY_BEFORE" || true
[ "$LOCK_GUARD" = "true" ] || fail "the keyguard is not showing before the open (got ${LOCK_GUARD:-none})"
case "$WAKE_STATE" in
  Asleep|Dozing) ;;
  *) fail "the screen is not off before the open (mWakefulness=${WAKE_STATE:-none})" ;;
esac

# A clean log: everything below reads this run's own lines.
emu logcat -c >/dev/null 2>&1 || true
: > "$OPENOUT"
"${DRIVER[@]}" --seconds "$SECONDS_OPEN" > "$OPENOUT" 2>&1 &
OPEN_PID=$!
# While the window opens, read the phone's own view of the display: the state it
# reports and the physical panel's power mode.
sleep 3
emu shell dumpsys display 2>/dev/null | tr -d '\r' > "$DISPLAY_DURING" || true
emu shell dumpsys SurfaceFlinger 2>/dev/null | tr -d '\r' > "$SF_DURING" || true
wait "$OPEN_PID"
OPEN_RC=$?
emu logcat -d > "$LOGCAT" 2>/dev/null || true
emu shell dumpsys display 2>/dev/null | tr -d '\r' > "$OUT/locked-open-display-after.log" || true
emu shell dumpsys window > "$WINDOW_AFTER" 2>/dev/null || true
emu shell dumpsys window policy > "$OUT/locked-open-window-policy-after.log" 2>/dev/null || true
GUARD_AFTER="$(keyguard_showing "$WINDOW_AFTER" "$OUT/locked-open-window-policy-after.log" && echo true || echo false)"
PHONE="$(read_phone "$LOGCAT" "$APP")"
phone_value() { printf '%s\n' "$PHONE" | sed -n "s/^$1=//p"; }

FIRST_MS="$(value first_frame_ms "$OPENOUT")"
MAX_GAP="$(value max_gap_ms "$OPENOUT")"
FRAMES="$(value frames "$OPENOUT")"
TAP_STARTED="$(phone_value tap_started)"
SINK="$(phone_value sink_lines)"
PANEL_OFF="$(phone_value panel_off)"
ORDER="$(phone_value takeover_before_launch)"
STARTED_OFF="$(phone_value started_off)"
AWAKENED="$(phone_value awake_before_frame)"
VD_ON="$(phone_value display_on)"
PANEL_DURING="$(grep -E 'powerMode=' "$SF_DURING" 2>/dev/null | sed 's/^[ \t]*//' | tr '\n' ' ' | sed 's/ *$//')"

if [ "$OPEN_RC" -ne 0 ]; then
  fail "the window did not stream on the locked phone (rc=$OPEN_RC): $(tail -2 "$OPENOUT" | tr '\n' ' ')"
fi
REASONS="$(verdict "$FIRST_MS" "$TAP_STARTED" "$SINK" "$GUARD_AFTER" "$PANEL_OFF" "$ORDER" "$FRAMES" "$MAX_GAP")"
if [ -n "$REASONS" ]; then
  while IFS= read -r reason; do
    [ -n "$reason" ] && fail "$reason"
  done <<< "$REASONS"
else
  pass "first frame in ${FIRST_MS} ms on the locked phone (budget ${LIMIT_MS}), the taps arrived, no input sink, no stall"
fi
if [ "$ORDER" = "1" ]; then
  pass "the take-over ran before the activity launch (wake lock held before the launch, panel-off after it)"
fi
if [ "$STARTED_OFF" != "none" ]; then
  pass "the VD was created OFF (the group was asleep) and the take-over woke it (display ON before the first frame: $AWAKENED)"
fi
if [ "$GUARD_AFTER" = "true" ]; then
  pass "the phone is still locked after the open (keyguard showing; nothing here dismisses it)"
fi
if [ "${PANEL_OFF:-0}" -ge 1 ]; then
  pass "the phone powered the panel off under the stream (${PANEL_OFF} write(s); SurfaceFlinger powerMode=[$PANEL_DURING])"
fi

{
  echo "first_frame_ms: $FIRST_MS (budget $LIMIT_MS)"
  echo "frames: $FRAMES max_gap_ms: $MAX_GAP"
  echo "tap_started: $TAP_STARTED taps: $(phone_value taps) sink_lines: $SINK"
  echo "take-over: before_launch=$ORDER vd_on=$VD_ON awake_before_frame=$AWAKENED started_off=$STARTED_OFF"
  echo "panel: off_writes=$PANEL_OFF surfaceflinger=[$PANEL_DURING]"
  echo "before: keyguard=$LOCK_GUARD wakefulness=$WAKE_STATE"
  echo "after: keyguard=$GUARD_AFTER"
  echo "control: $(tr '\n' ' ' < "$CONTROL")"
  echo "session: $(tr '\n' ' ' < "$OPENOUT")"
  echo "failed: $FAILED"
} > "$RESULT"
cat "$RESULT"

if [ "$FAILED" -ne 0 ]; then
  echo "locked-open: logcat evidence ($LOGCAT):"
  grep -E 'power:|keepalive|stream 1|pocketdeck-1|InputDispatcher|START u0|PROCESS_STATE|LockedOpen' "$LOGCAT" |
    tail -40 | sed 's/^/  /'
fi

if [ "$BOOT" -eq 1 ]; then
  kill_emulator
fi
exit "$FAILED"
