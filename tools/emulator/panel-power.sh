#!/usr/bin/env bash
# The phone's panel with the Mac's windows opening, covering and closing — ONE
# boot. docs/design/phone-mirror.md, docs/PROTOCOL.md "Phone screen".
#
#   tools/emulator/panel-power.sh            the run (heavy.sh owns the lock
#                                            and the boot budget)
#   tools/emulator/panel-power.sh --no-boot  the same checks on a rig that is
#                                            already up, paired and built with
#                                            debug.pocketdeck.force_panel_off=1
#   tools/emulator/panel-power.sh --check    a dry run: syntax, preflight, the
#                                            deckctl verbs, the log parser's
#                                            fixtures, the serial — no device
#
# Run it as `bash tools/emulator/panel-power.sh` (the exec bit is not relied on).
#
# What it proves (debug.pocketdeck.force_panel_off=1 forces the shared-group path,
# where AOSP would give the VD its own group):
#   (a) an app window open on a sleeping phone, covered for 4 s and resumed: one
#       panel take-over only — no second take-over after the resume, no hand-back
#       and no sleep inside the pause;
#   (b) a phone window beside an app window: the panel is never powered off
#       behind the mirror;
#   (c) phone.panel off: the panel plan goes dark while the mirror keeps sending
#       frames; phone.panel on: it comes back.
# The evidence is the app's own state lines (plans, mode transitions, counts),
# never pixels. Results go to .agent/emu/panel-power.log. It never unlocks or
# dismisses the keyguard, never changes lock settings and never touches a phone
# but $SERIAL.
set -u

MODE=run
BOOT=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --no-boot) BOOT=0 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "panel-power.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export POCKETDECK_PORT="${POCKETDECK_PORT:-47812}"
export POCKETDECK_SERIAL=emulator-5554
export POCKETDECK_AGENT_DIR="$PWD/.agent/emu"
# start.sh sets this property before it launches the server, so the policy is
# built forced. Setting it after the boot (the old order) left the Shizuku
# user-service process alive and unforced; the init-line check below catches it.
export POCKETDECK_FORCE_PANEL_OFF=1
mkdir -p "$POCKETDECK_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$POCKETDECK_AGENT_DIR"
RESULT="$OUT/panel-power.log"
# start.sh's failed-install diagnostic lands here; the start-failure path below
# copies it into panel-power.log before the trap kills the emulator.
PD_INSTALL_LOG="$OUT/install-failure.log"
export PD_INSTALL_LOG
SESSION="$OUT/panel-power-session.log"
LOGCAT="$OUT/panel-power-logcat.log"
DISPLAY="$OUT/panel-power-display.log"
DC=("$PYTHON" tools/fakephone/deckctl.py --host 127.0.0.1 --port "$PORT" \
    --state "$CACHE_DIR/deckctl-state.json")

FAILED=0
pass() { echo "PASS panel-power: $*"; }
fail() { echo "FAIL panel-power: $*"; FAILED=1; }

# read_plans <logcat> — the panel decisions the phone made, as counts and the
# one ordering fact that separates a pause from a close. States only.
read_plans() {
  "$PYTHON" - "$1" <<'PLANS'
import re, sys
lines = [l.rstrip() for l in open(sys.argv[1], errors="replace")]
dark = transitional = grace = 0
first_sleep = first_close = None
for i, line in enumerate(lines):
    if "power: panel" in line and "-> PanelPlan(" in line:
        if "panelOff=true" in line:
            dark += 1
        if "transitional=true" in line:
            transitional += 1
    if "all windows paused for" in line:
        grace += 1
    if first_sleep is None and "phone back to sleep after the last stream" in line:
        first_sleep = i
    if first_close is None and "closed stream 1 (display" in line:
        first_close = i
print("dark_plans=%d" % dark)
print("transitional_plans=%d" % transitional)
print("grace_handbacks=%d" % grace)
# -1 when a line never happened: the shell check reads these as "no evidence".
print("first_sleep=%s" % ("none" if first_sleep is None else first_sleep))
print("first_close=%s" % ("none" if first_close is None else first_close))
PLANS
}

# The forced shape boot #3 showed: 4 dark plans (the app-window take-over and
# its re-apply in (a), phone.panel off and its re-apply in (c)); 2 transitional
# plans (the two take-overs). A resume re-take would make 3, which item 1
# forbids. The sleep line is present; a pause hand-back would make grace > 0.
plans_shape_ok() { # <read_plans output>
  local p="$1" d t g s
  d="$(printf '%s\n' "$p" | sed -n 's/^dark_plans=//p')"
  t="$(printf '%s\n' "$p" | sed -n 's/^transitional_plans=//p')"
  g="$(printf '%s\n' "$p" | sed -n 's/^grace_handbacks=//p')"
  s="$(printf '%s\n' "$p" | sed -n 's/^first_sleep=//p')"
  [ "${d:-0}" -eq 4 ] && [ "${t:-0}" -eq 2 ] && [ "${g:-1}" -eq 0 ] && [ "${s:-none}" != "none" ]
}

# ---- --check: everything that can be wrong before a boot -------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  PD_PREFLIGHT_DRY_RUN=1 bash tools/emulator/preflight.sh ||
    { echo "CHECK FAIL: preflight"; exit 1; }
  "$PYTHON" - <<'PY' || { echo "CHECK FAIL: deckctl panel verbs"; exit 1; }
import sys
sys.path.insert(0, "tools/fakephone")
import deckctl
parser = deckctl.build_parser()
args = parser.parse_args(["panel-test", "--pause-seconds", "4", "--off-seconds", "6"])
assert args.command == "panel-test" and args.pause_seconds == 4 and args.off_seconds == 6
args = parser.parse_args(["panel", "off"])
assert args.command == "panel" and args.mode == "off"
PY
  # The log parser must read the forced boot-3 shape: 4 dark plans (the
  # app-window take-over + re-apply, phone.panel off + re-apply) and 2
  # transitional (the two take-overs), with no grace hand-back and the close
  # sleep present.
  FIX="$OUT/panel-power-fixture.log"
  cat > "$FIX" <<'FIXTURE'
14:25:08.400 I/PocketDeckSvc: power: panel OFF -> PanelPlan(wake=true, panelOff=true, transitional=true)
14:25:10.455 I/PocketDeckSvc: power: panel OFF -> PanelPlan(wake=true, panelOff=true, transitional=false)
14:25:16.694 I/PocketDeckSvc: phone back to sleep after the last stream
14:25:17.602 I/PocketDeckSvc: closed stream 1 (display 2)
14:25:20.536 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=false, transitional=false)
14:25:23.500 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=true)
14:25:25.511 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=false)
14:25:29.514 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=false, transitional=false)
14:25:29.630 I/PocketDeckSvc: closed stream 1 (display 4)
FIXTURE
  GOOD="$(read_plans "$FIX")"
  plans_shape_ok "$GOOD" ||
    { echo "CHECK FAIL: the boot-3 logcat does not meet the forced shape ($GOOD)"; exit 1; }
  case "$GOOD" in
    *first_sleep=2*first_close=3*) ;;
    *) echo "CHECK FAIL: the parser orders the boot-3 sleep/close lines ($GOOD)"; exit 1 ;;
  esac
  # One extra transitional plan after the pause is a resume re-take (item 1's
  # bug); the pinned shape must reject it.
  cat > "$FIX" <<'FIXTURE'
14:25:08.400 I/PocketDeckSvc: power: panel OFF -> PanelPlan(wake=true, panelOff=true, transitional=true)
14:25:10.455 I/PocketDeckSvc: power: panel OFF -> PanelPlan(wake=true, panelOff=true, transitional=false)
14:25:16.694 I/PocketDeckSvc: phone back to sleep after the last stream
14:25:17.602 I/PocketDeckSvc: closed stream 1 (display 2)
14:25:20.536 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=false, transitional=false)
14:25:21.000 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=true)
14:25:23.500 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=true)
14:25:25.511 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=false)
14:25:29.514 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=false, transitional=false)
14:25:29.630 I/PocketDeckSvc: closed stream 1 (display 4)
FIXTURE
  BAD="$(read_plans "$FIX")"
  if plans_shape_ok "$BAD"; then
    echo "CHECK FAIL: the extra-transitional log passed the forced shape ($BAD)"
    exit 1
  fi
  case "$BAD" in
    *transitional_plans=3*) ;;
    *) echo "CHECK FAIL: the parser missed the extra transitional plan ($BAD)"; exit 1 ;;
  esac
  # And a log where the pause slept the phone (the bug) must read the other way.
  cat > "$FIX" <<'FIXTURE'
10-21 10:00:00.000 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=true)
10-21 10:00:02.000 I/PocketDeckSvc: all windows paused for 30s; handing the phone back
10-21 10:00:02.100 I/PocketDeckSvc: phone back to sleep after the last stream
10-21 10:00:05.000 I/PocketDeckSvc: power: panel ON -> PanelPlan(wake=true, panelOff=true, transitional=true)
10-21 10:00:06.000 I/PocketDeckSvc: closed stream 1 (display 57)
FIXTURE
  BAD="$(read_plans "$FIX")"
  case "$BAD" in
    *grace_handbacks=1*) ;;
    *) echo "CHECK FAIL: the parser missed a grace hand-back ($BAD)"; exit 1 ;;
  esac
  case "$BAD" in
    *first_sleep=2*first_close=4*) ;;
    *) echo "CHECK FAIL: the parser did not place the sleep before the close ($BAD)"; exit 1 ;;
  esac
  echo "CHECK OK: boot-3 fixture passes; the extra-transitional fixture is rejected"
  rm -f "$FIX"
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
    echo "CHECK FAIL: $SERIAL is already running (not ours to touch)"
    exit 1
  fi
  echo "CHECK OK: preflight, deckctl panel verbs, log parser fixtures; $SERIAL free"
  exit 0
fi

# ---- the run (ONE boot, or a rig verify-batch.sh already booted) ------------
if [ "$BOOT" -eq 1 ] && "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "panel-power: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() {
  if [ "$BOOT" -eq 1 ]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
  fi
}
trap 'kill_emulator' EXIT

if [ "$BOOT" -eq 1 ]; then
  echo "panel-power: booting $SERIAL (one boot budget)"
  if ! bash tools/emulator/start.sh --no-build; then
    # The rig's known flake: the shell service does not always come up on the
    # first launch after a boot (the app is installed and seeded by now). Its
    # own restart path re-runs the app and waits for the listening port.
    echo "panel-power: start.sh failed; restarting the shell service"
    if ! restart_server; then
      echo "panel-power: the shell service never came up (unverified)"
      { echo "failed: 1 (start)"; cat "$PD_INSTALL_LOG" 2>/dev/null; } > "$RESULT"
      exit 1
    fi
  fi
  # The shared-group path, as on the person's One UI build. It is read when the
  # power policy is built, so the app restarts once (the session is not up yet).
  emu shell setprop debug.pocketdeck.force_panel_off 1 >/dev/null 2>&1 || true
  if [ "$(emu shell getprop debug.pocketdeck.force_panel_off | tr -d '\r')" != "1" ]; then
    fail "debug.pocketdeck.force_panel_off did not stick"
  fi
  if ! restart_server; then
    echo "panel-power: the app did not come back with the forced path (unverified)"
    echo "failed: 1 (restart)" > "$RESULT"
    exit 1
  fi
  # The init line is the only proof the running policy was built forced. The
  # old order set the property after the server had started, and the Shizuku
  # user service survived the app restart, so every plan came out unforced.
  INIT_LINE="$(emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
    grep 'power: panel power control' | tail -1 | tr -d '\r')"
  case "$INIT_LINE" in
    *"forcing the panel-dark path"*)
      echo "panel-power: init: $INIT_LINE"
      ;;
    *)
      echo "panel-power: the server did not start forced (init: ${INIT_LINE:-none})"
      { echo "failed: 1 (not-forced)"; echo "init: ${INIT_LINE:-none}"; } > "$RESULT"
      exit 1
      ;;
  esac
  if ! "$PYTHON" tools/emulator/poc.py --state "$CACHE_DIR/deckctl-state.json" \
        --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair; then
    echo "panel-power: pairing failed (unverified)"
    exit 1
  fi
  echo "panel-power: up and paired"
else
  device_present || { echo "panel-power: $SERIAL is not up (--no-boot needs a booted, paired rig)"; exit 1; }
  if [ "$(emu shell getprop debug.pocketdeck.force_panel_off | tr -d '\r')" != "1" ]; then
    echo "panel-power: the rig is not running with force_panel_off=1"
    exit 1
  fi
fi
ensure_forward >/dev/null || { echo "panel-power: no server port"; echo "failed: 1 (port)" > "$RESULT"; exit 1; }

# A clean log: everything below reads this run's own lines.
emu logcat -c >/dev/null 2>&1 || true

# (a) needs the panel asleep (the person's phone in their pocket); (b)/(c) need
# it awake so the mirror has a group to render from. KEYCODE_SLEEP and
# KEYCODE_WAKEUP only: no unlock, no keyguard change.
emu shell input keyevent KEYCODE_SLEEP >/dev/null 2>&1 || true
sleep 2
"${DC[@]}" panel-test --phase pause --pause-seconds 4 > "$SESSION" 2>&1
PAUSE_RC=$?

# The person wakes the phone (the keyguard stays up): the mirror needs a panel.
emu shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
sleep 2
emu shell dumpsys display > "$DISPLAY" 2>/dev/null || true
"${DC[@]}" panel-test --phase panel --off-seconds 6 >> "$SESSION" 2>&1
SESSION_RC=$?
emu logcat -d -s PocketDeckSvc:I PocketDeckApp:I PocketDeckPower:I 2>/dev/null | tr -d '\r' > "$LOGCAT" || true

if [ "$PAUSE_RC" -ne 0 ]; then
  fail "the pause phase failed (rc=$PAUSE_RC): $(head -2 "$SESSION" | tr '\n' ' ')"
fi
if [ "$SESSION_RC" -ne 0 ]; then
  fail "the panel phase failed (rc=$SESSION_RC): $(grep -v '^paused\|^resumed' "$SESSION" | tail -2 | tr '\n' ' ')"
fi
grep -q '^state-panel=off' "$SESSION" \
  && pass "the phone echoed state.panel off for phone.panel off" \
  || fail "no state.panel off echo ($(grep '^state-panel' "$SESSION" | tr '\n' ' '))"
grep -q '^state-panel=on' "$SESSION" \
  && pass "the phone echoed state.panel on for phone.panel on" \
  || fail "no state.panel on echo"
FRAMES_OFF="$(grep -o 'frames-while-off=[0-9]*' "$SESSION" | tail -1 | cut -d= -f2)"
if [ -n "${FRAMES_OFF:-}" ] && [ "$FRAMES_OFF" -gt 0 ]; then
  pass "the mirror kept sending frames with the panel off ($FRAMES_OFF frames)"
else
  fail "the mirror sent no frames with the panel off (${FRAMES_OFF:-none})"
fi
grep -q '^resumed' "$SESSION" \
  && pass "the covered window resumed inside the grace period" \
  || fail "the window never resumed"

PLANS="$(read_plans "$LOGCAT")"
DARK="$(printf '%s\n' "$PLANS" | sed -n 's/^dark_plans=//p')"
TRANS="$(printf '%s\n' "$PLANS" | sed -n 's/^transitional_plans=//p')"
GRACE="$(printf '%s\n' "$PLANS" | sed -n 's/^grace_handbacks=//p')"
SLEEP_AT="$(printf '%s\n' "$PLANS" | sed -n 's/^first_sleep=//p')"
CLOSE_AT="$(printf '%s\n' "$PLANS" | sed -n 's/^first_close=//p')"

# The forced boot-3 shape: 4 dark plans (the app-window take-over + re-apply in
# (a), phone.panel off + re-apply in (c)); 2 transitional plans (the two
# take-overs). A resume re-take would make 3, which item 1 forbids.
if [ "${DARK:-0}" -eq 4 ]; then
  pass "the panel went dark 4 times: the app window and phone.panel off, each with its re-apply ($DARK)"
else
  fail "the panel went dark $DARK time(s), expected 4 (forced take-over + re-apply, twice)"
fi
if [ "${TRANS:-0}" -eq 2 ]; then
  pass "the two take-overs were transitional; a resume did not re-take ($TRANS)"
else
  fail "the panel was taken over $TRANS time(s), expected 2 (a resume re-take would make 3)"
fi
if [ "${GRACE:-1}" -eq 0 ]; then
  pass "no grace hand-back inside a 4 s pause"
else
  fail "the phone handed the panel back during the pause ($GRACE)"
fi
# A close hands the phone back and sleeps it; a pause must not. The sleep line
# is logged inside AndroidPower.restoreAfterStop (before the session's own
# "closed stream" line), so compare presence, not line order: the line only
# prints when goToSleep() returned true. grace_handbacks=0 above is the
# "not during the pause" evidence.
if [ "${SLEEP_AT:-none}" != "none" ]; then
  pass "the phone logged the sleep on the close (sleep@$SLEEP_AT close@$CLOSE_AT; the power line precedes the session close line)"
else
  fail "the phone never logged 'phone back to sleep after the last stream' (sleep@none close@${CLOSE_AT:-none})"
fi
if grep -q 'panel power mode -> OFF' "$LOGCAT"; then
  pass "the phone's panel power mode went OFF (the shared-group path)"
else
  echo "note panel-power: this rig has no panel power control (emulator); the plans are the evidence"
fi

{
  echo "state-panel: $(grep '^state-panel' "$SESSION" | tr '\n' ' ')"
  echo "frames-while-off: ${FRAMES_OFF:-none}"
  echo "plans: $(printf '%s' "$PLANS" | tr '\n' ' ')"
  echo "display0: $(grep -m1 -E 'mScreenState|Display Power' "$DISPLAY" | tr -s ' ')"
  echo "failed: $FAILED"
} > "$RESULT"
cat "$RESULT"

if [ "$FAILED" -ne 0 ]; then
  EMULOG="$OUT/panel-power-logcat-tail.log"
  grep -E 'power:|keepalive|closed stream|phone.panel' "$LOGCAT" | tail -30 > "$EMULOG" || true
  echo "panel-power: logcat evidence ($EMULOG):"
  tail -10 "$EMULOG"
fi

if [ "$BOOT" -eq 1 ]; then
  kill_emulator
fi
exit "$FAILED"
