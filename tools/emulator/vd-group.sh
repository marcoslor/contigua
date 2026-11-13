#!/usr/bin/env bash
# App window displays in a group of their own (docs/specs/app-windows.md
# WIN-74, WIN-75; docs/specs/phone-app.md PHONE-22; docs/specs/controls.md
# CTRL-14), on a rig that is already up and paired (`bash tools/emulator/start.sh`).
#
#   bash tools/emulator/vd-group.sh           the run
#   bash tools/emulator/vd-group.sh --check   a dry run: syntax and the serial
#
# What it proves, from the app's own log lines and `dumpsys`, never pixels:
#   ok [WIN-74] the default route's window display is not in group 0;
#   ok [WIN-74] debug.contigua.vd_plain=1 gives the plain route its own group;
#   ok [WIN-74] debug.contigua.vd_panel_group=1 lands in group 0 and the open is
#               refused (`windows_unsupported`) with nothing launched;
#   ok [WIN-75] two windows share one virtual device, and none is left after
#               the last close (only where the rig can make a device; else a note);
#   ok [CTRL-14] on a locked, screen-off phone a window opens and draws: its
#               display is ON while display 0 stays off, no keep-alive names
#               display 0, the panel's power mode is never written, and the
#               keyguard still shows afterwards (WIN-20, PHONE-22).
# Results go to .work/emu/vd-group.log. It never touches a phone but $SERIAL.
# Run it as `bash tools/emulator/vd-group.sh` (the exec bit is not relied on).
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    *) echo "vd-group.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

. "$(dirname "$0")/lib.sh"

case "$SERIAL" in
  emulator-*) ;;
  *) echo "vd-group.sh: refusing to run: $SERIAL is not an emulator serial" >&2; exit 2 ;;
esac

if [ "$MODE" = check ]; then
  bash -n "$0" && echo "CHECK OK: vd-group syntax ($SERIAL)"
  exit $?
fi

OUT="$AGENT_DIR"
RESULT="$OUT/vd-group.log"
PKG="${CONTIGUA_BROWSER:-acr.browser.lightning}"
PKG2="${CONTIGUA_SECOND_APP:-com.android.settings}"
STATE="$CACHE_DIR/deckctl-state.json"
FAILED=0
: > "$RESULT"

say() { echo "$*" | tee -a "$RESULT"; }
pass() { say "ok $*"; }
fail() { say "FAIL $*"; FAILED=1; }
note() { say "note $*"; }

device_present || { echo "vd-group: $SERIAL is not up (run start.sh first)"; exit 1; }
ensure_forward >/dev/null || { echo "vd-group: no server port"; exit 1; }

# Pair once (poc.py reads the rig's prompt and taps Allow, as flow.sh does).
POC="$EMU_DIR/poc.py"
if ! "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1; then
  bash "$EMU_DIR/unlock.sh" >/dev/null 2>&1 || true
  emu shell am start -n "app.contigua/.app.MainActivity" >/dev/null 2>&1 || true
  sleep 5
  "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair \
    > "$OUT/vd-group-pair.txt" 2>&1 || { echo "vd-group: pairing failed (unverified)"; exit 1; }
fi

deck() { "$PYTHON" "$REPO_ROOT/tools/fakephone/deckctl.py" --host 127.0.0.1 --port "$PORT" --state "$STATE" "$@"; }
applog() { emu logcat -d -s ContiguaSvc:I 2>/dev/null | tr -d '\r'; }
knobs() { # knobs <vd_plain> <vd_panel_group>
  emu shell setprop debug.contigua.vd_plain "$1" >/dev/null 2>&1
  emu shell setprop debug.contigua.vd_panel_group "$2" >/dev/null 2>&1
}
# One logical display's state from a `dumpsys display` dump: `mState=`, or
# API 36's `mBaseDisplayInfo=DisplayInfo{... state ON ...}`.
display_state() { # display_state <dump> <displayId>
  "$PYTHON" - "$1" "$2" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
want = int(sys.argv[2])
parts = re.split(r"(?m)^\s*Display (\d+):\s*$", text)
state = "UNKNOWN"
for i in range(1, len(parts), 2):
    if int(parts[i]) != want:
        continue
    body = parts[i + 1]
    m = re.search(r"mState=([A-Z_]+)", body)
    if not m:
        info = re.search(r"mBaseDisplayInfo=DisplayInfo\{[^\n]*", body)
        m = info and re.search(r"(?<![A-Za-z])state (ON_SUSPEND|DOZE_SUSPEND|DOZE|ON|OFF)\b", info.group(0))
    if m:
        state = "ON" if m.group(1) == "ON_SUSPEND" else m.group(1)
    break
print(state)
PY
}
# The group of the last window display the log described.
last_group() { applog | sed -n 's/.*stream [0-9]* vd=[0-9]* display [0-9]*: group=\([0-9]*\).*/\1/p' | tail -1; }

# --- the default route ---------------------------------------------------------
knobs 0 0
emu logcat -c >/dev/null 2>&1
deck open "$PKG" --w 1280 --h 800 --seconds 4 > "$OUT/vd-group-default.txt" 2>&1 || true
group="$(last_group)"
route="$(applog | grep -c 'windowdevice: device .* made')"
if [ -n "$group" ] && [ "$group" != 0 ]; then
  pass "[WIN-74] default route: group=$group ($([ "$route" -gt 0 ] && echo device || echo plain))"
else
  fail "[WIN-74] default route: group=${group:-unread}"
fi
applog | grep 'windowdevice: device .* made' | tail -1 | sed 's/^/  /' | tee -a "$RESULT"
applog | grep 'windowdevice: not made' | tail -1 | sed 's/^/  /' | tee -a "$RESULT"

# --- the plain route -----------------------------------------------------------
knobs 1 0
emu logcat -c >/dev/null 2>&1
deck open "$PKG" --w 1280 --h 800 --seconds 4 > "$OUT/vd-group-plain.txt" 2>&1 || true
group="$(last_group)"
if [ -n "$group" ] && [ "$group" != 0 ] && applog | grep -q 'requested flags=.*OWN_DISPLAY_GROUP'; then
  pass "[WIN-74] plain route: group=$group"
else
  fail "[WIN-74] plain route: group=${group:-unread}"
fi

# --- group 0 is refused --------------------------------------------------------
knobs 0 1
emu logcat -c >/dev/null 2>&1
deck open "$PKG" --w 1280 --h 800 --seconds 4 > "$OUT/vd-group-refused.txt" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && applog | grep -q 'refused: windows_unsupported' &&
  ! applog | grep -q 'launch.*display'; then
  pass "[WIN-74] group 0 refused: $(applog | grep 'refused: windows_unsupported' | tail -1 | sed 's/.*refused: //')"
else
  fail "[WIN-74] group 0 not refused (rc=$rc)"
fi
knobs 0 0

# --- one device for two windows ------------------------------------------------
emu logcat -c >/dev/null 2>&1
deck multi --apps "$PKG" "$PKG2" --w 1280 --h 800 --phase-seconds 1 \
  --out-prefix "$OUT/vd-group-multi" > "$OUT/vd-group-multi.txt" 2>&1 || true
# A session that ends with its connection closes its windows after the path
# grace (docs/design/paths.md), so the device's close can take ~30 s.
for _ in $(seq 1 45); do
  applog | grep -q 'windowdevice: Open --release--> Closed' && break
  applog | grep -q 'windowdevice: device .* made' || break
  sleep 1
done
made="$(applog | grep -c 'windowdevice: device .* made')"
if [ "$made" -eq 1 ]; then
  if applog | grep -q 'windowdevice: .*holders=2' && applog | grep -q 'windowdevice: Open --release--> Closed'; then
    pass "[WIN-75] two windows, one device; closed after the last release"
  else
    fail "[WIN-75] one device, but the holders or the close are missing"
  fi
elif [ "$made" -eq 0 ]; then
  note "[WIN-75] this rig made no virtual device ($(applog | grep 'windowdevice: not made' | tail -1 | sed 's/.*reason=//')): the plain route ran"
else
  fail "[WIN-75] $made devices for two windows"
fi

# --- a locked, screen-off phone ------------------------------------------------
bash "$EMU_DIR/lock.sh" >/dev/null 2>&1 || { fail "[CTRL-14] the rig would not lock"; }
sleep 2
emu logcat -c >/dev/null 2>&1
deck open "$PKG" --w 1280 --h 800 --seconds 14 > "$OUT/vd-group-locked.txt" 2>&1 &
opener=$!
sleep 9
emu shell dumpsys display 2>/dev/null | tr -d '\r' > "$OUT/vd-group-display.txt"
wait "$opener"
vd="$(sed -n 's/^stream=1 .*displayId=\([0-9]*\).*/\1/p' "$OUT/vd-group-locked.txt")"
panel_state="$(emu shell dumpsys power 2>/dev/null | tr -d '\r' | sed -n 's/.*mWakefulness=\([A-Za-z]*\).*/\1/p' | head -1)"
d0="$(display_state "$OUT/vd-group-display.txt" 0)"
dv="$(display_state "$OUT/vd-group-display.txt" "${vd:--1}")"
frames="$(sed -n 's/.* frames=\([0-9]*\).*/\1/p' "$OUT/vd-group-locked.txt" | tail -1)"
keyguard="$(emu shell dumpsys window 2>/dev/null | grep -ciE 'isKeyguardShowing=true|mKeyguardShowing=true')"
touched_panel="$(applog | grep -cE 'phone.panel|panel off|power: panel ')"
poked_zero="$(applog | grep -cE 'window display (0|0,.*|.*,0) woken')"
say "  locked: display0=${d0:-?} window=${vd:-?}:${dv:-?} frames=${frames:-0} global=${panel_state:-?}"
if [ -n "$vd" ] && [ "${frames:-0}" -gt 0 ] && [ "$dv" = ON ] && [ "$d0" != ON ] &&
  [ "$touched_panel" -eq 0 ] && [ "$poked_zero" -eq 0 ] && [ "$keyguard" -gt 0 ]; then
  pass "[CTRL-14] locked open: the window draws, display 0 stays off, the keyguard stays"
else
  fail "[CTRL-14] locked open (display0=${d0:-?} window=${dv:-?} frames=${frames:-0} panel-lines=$touched_panel keyguard=$keyguard)"
fi

say "failed: $FAILED"
exit "$FAILED"
