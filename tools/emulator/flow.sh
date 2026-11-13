#!/usr/bin/env bash
# The core Contigua POC check against the running emulator rig:
#
#   tools/emulator/flow.sh
#
# pair -> lock the emulator -> apps -> two apps in their own streams at
# 1280x800 -> resize to 768x1280 and 1600x496 -> save the last decoded frame of
# every phase as a PNG -> tap/text/scroll and prove the frames changed.
# The phone-side work is deckctl's (`apps`, `multi`); the two local bits deckctl
# cannot do (reading the pairing prompt, judging the PNGs) are in poc.py.
# Exits non-zero on the first failed step; frames land in .work/emu/frames/.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

DECKCTL="$REPO_ROOT/tools/fakephone/deckctl.py"
POC="$EMU_DIR/poc.py"
STATE="$CACHE_DIR/deckctl-state.json"
FRAMES="$AGENT_DIR/frames"
BROWSER="${CONTIGUA_BROWSER:-acr.browser.lightning}"
MESSENGER="${CONTIGUA_MESSENGER:-org.fossify.messages}"
# Widget targets of a first launch at the rig's window sizes (see README).
STEPS1="${CONTIGUA_STEPS1:-tap:0.92,0.06;back;tap:0.50,0.056;text:example.com}"
# `wait:` steps let a screen finish appearing before the next input is judged.
STEPS2="${CONTIGUA_STEPS2:-tap:0.93,0.78;wait:5;text:5551234;scroll:-6}"
# Seconds each phase waits before its snapshot; a WebView app on a software GPU
# needs a while to finish its first layout before it can answer a resize.
SETTLE="${CONTIGUA_SETTLE:-12}"
PHASE_SECONDS="${CONTIGUA_PHASE_SECONDS:-6}"

device_present || die "$SERIAL is not running - run tools/emulator/start.sh first"

# adb forward rules vanish when the adb server restarts (a wireless device
# reconnecting is enough), so re-assert the rig's forward before every run.
DEVPORT="$(ensure_forward)" || die "cannot find the Contigua server port on $SERIAL (is the app running?)"
step "forward: 127.0.0.1:$PORT -> device tcp:$DEVPORT"

deckctl() { "$PYTHON" "$DECKCTL" --host 127.0.0.1 --port "$PORT" --state "$STATE" "$@"; }

# --- pair -------------------------------------------------------------------
# deckctl cannot read the phone's screen, so the pairing prompt is handled by
# poc.py: it reads the 6-digit code (app dialog or notification), taps Allow and
# stores the key in deckctl's own state file - so every deckctl call below just
# authenticates. (To pair by hand instead: `deckctl --pair` with
# `poc.py wait-prompt` in the background; see README.)
bring_app_forward() {
  emu shell am start -n "app.contigua/.app.MainActivity" >/dev/null 2>&1 || true
  local deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if emu shell dumpsys activity activities 2>/dev/null |
      grep -q "ResumedActivity.*app.contigua/app.contigua.app.MainActivity"; then
      break
    fi
    sleep 2
  done
  sleep 3
}

check_paired() { # 0 paired, 2 not paired, 3 phone busy
  local rc=0
  "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" check >/dev/null 2>&1 || rc=$?
  return "$rc"
}

for _ in $(seq 1 6); do
  if check_paired; then
    break
  elif [ "$?" -eq 3 ]; then
    step "phone busy with another session, waiting"
    sleep 5
  else
    step "not paired yet: waking the rig and bringing the app forward"
    bash "$EMU_DIR/unlock.sh"
    bring_app_forward
    break
  fi
done

if ! check_paired; then
  PAIRED=0
  # The real flow first (a loaded host can be too slow for it).
  for attempt in 1 2; do
    step "pairing (code from the app prompt), attempt $attempt"
    if "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" pair; then
      PAIRED=1
      break
    fi
    bash "$EMU_DIR/unlock.sh" || true
    bring_app_forward
  done
  [ "$PAIRED" -eq 1 ] || die "could not pair with the rig"
else
  step "already paired (pin in $STATE)"
fi

step "deckctl apps"
# --wait-for-free: another client (or a previous run) holding the session is
# retried instead of failing the run.
deckctl --wait-for-free 60 apps >"$AGENT_DIR/apps.txt" 2>"$AGENT_DIR/apps.err" ||
  die "could not list apps ($(tail -1 "$AGENT_DIR/apps.err"))"
for pkg in "$BROWSER" "$MESSENGER"; do
  grep -q "^$pkg	" "$AGENT_DIR/apps.txt" || die "apps.list is missing $pkg"
  step "listed: $(grep "^$pkg	" "$AGENT_DIR/apps.txt")"
done

# --- lock ------------------------------------------------------------------
step "locking the emulator"
bash "$EMU_DIR/lock.sh"
# E4's command, as given: the rig must show up as locked to the platform.
emu shell dumpsys window | grep -i -E 'mDreamingLockscreen|isKeyguardShowing|showing=' | head -4 |
  tr -s ' ' | tr -d '\r' | sed 's/^/[flow.sh] dumpsys window |/'
LOCKED="$(emu shell dumpsys window | grep -i -E 'mDreamingLockscreen|isKeyguardShowing|mKeyguardShowing' | tr -s ' ' | tr -d '\r' | tr '\n' ' ')"
step "keyguard: $LOCKED"
echo "$LOCKED" | grep -qiE 'isKeyguardShowing=true|mKeyguardShowing=true' ||
  die "the emulator does not report a locked screen"

# A cold app state makes the first-launch widgets the ones the steps target.
# The protocol has no "restart this app", so the rig does it over adb.
for pkg in "$BROWSER" "$MESSENGER"; do
  emu shell am force-stop "$pkg" >/dev/null 2>&1 || true
done

# --- the two-window flow ---------------------------------------------------
# A cold browser on a software GPU can take longer than the flow's first
# CONFIG wait, so the whole step is retried with a warm-up in between.
warm_test_apps_once() {
  local pkg="$1"
  emu shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 10
  emu shell am force-stop "$pkg" >/dev/null 2>&1 || true
}

MULTI_OK=0
for attempt in 1 2 3; do
  step "deckctl multi (two windows, resizes, frames, input), attempt $attempt"
  rm -rf "$FRAMES"
  mkdir -p "$FRAMES"
  if deckctl --wait-for-free 30 multi \
    --apps "$BROWSER" "$MESSENGER" --w 1280 --h 800 --dpi 420 \
    --resize1 768x1280 --resize2 1600x496 \
    --steps "$STEPS1" --steps2 "$STEPS2" \
    --settle "$SETTLE" --phase-seconds "$PHASE_SECONDS" --out-prefix "$FRAMES/emu"; then
    MULTI_OK=1
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    step "attempt $attempt failed; warming the test apps and retrying"
    warm_test_apps_once "$BROWSER"
    warm_test_apps_once "$MESSENGER"
  fi
done
[ "$MULTI_OK" -eq 1 ] || die "deckctl multi did not complete"

step "checking the frames"
"$PYTHON" "$POC" verify-phases --dir "$FRAMES" --prefix emu

step "frames:"
ls -1 "$FRAMES"/*.png
step "flow.sh: OK"
