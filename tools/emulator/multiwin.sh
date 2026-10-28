#!/usr/bin/env bash
# multiwin: several windows of one app on an API 36 rig (WIN-24, 25, 28, 31, 32)
# plus the cost table that informs the phone's four-window default.
#
#   bash tools/emulator/multiwin.sh --check    # rehearse: no device, no boot
#   bash tools/emulator/multiwin.sh            # against an already booted rig
#
# The caller owns the emulator's whole life in ONE heavy.sh call:
#   bash tools/emulator/start.sh && bash tools/emulator/multiwin.sh; r=$?
#   adb -s emulator-5554 emu kill; exit $r
#
# Exit status is non-zero when any PASS/FAIL line failed. Screenshots, the cost
# phase files, the logcat and summary.json land in $POCKETDECK_MW_OUT (default
# ~/dev/pocketdeck/.agent/mw-phone).
set -uo pipefail

MODE=boot
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "[multiwin] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

WT="$REPO_ROOT"
OUT="${POCKETDECK_MW_OUT:-$HOME/dev/pocketdeck/.agent/mw-phone}"
# A fresh pairing state per run: boot 4 was lost because a reused state file made
# every attempt die on the phone's "handshake timeout" (a key it had revoked).
# A new file pairs like a new Mac, so no earlier pairing can poison the run.
STATE="$CACHE_DIR/deckctl-state-$(date +%s).json"
find "$CACHE_DIR" -maxdepth 1 -name 'deckctl-state-*.json' -mtime +1 -delete 2>/dev/null || true
CLIENT="$WT/tools/emulator/multiwin.py"
mkdir -p "$OUT"
export POCKETDECK_AGENT_DIR="${POCKETDECK_AGENT_DIR:-$OUT/emu}"

# --- rehearsal --------------------------------------------------------------
if [ "$MODE" = check ]; then
  rc=0
  bash -n "$0" || { echo "CHECK FAIL: bash -n $0"; rc=1; }
  "$PYTHON" -m py_compile "$CLIENT" || { echo "CHECK FAIL: py_compile multiwin.py"; rc=1; }
  "$PYTHON" - <<PY || { echo "CHECK FAIL: deckctl import"; rc=1; }
import sys
sys.path.insert(0, "$WT/tools/fakephone")
import deckctl, proto
assert hasattr(deckctl, "open_session") and hasattr(deckctl, "StreamRecorder")
assert hasattr(deckctl, "expect_json") and hasattr(deckctl, "ClientState")
assert hasattr(proto, "pack_scroll") and hasattr(proto, "pack_touch")
print("CHECK OK: deckctl + proto symbols")
PY
  command -v ffmpeg >/dev/null || { echo "CHECK FAIL: no ffmpeg"; rc=1; }
  [ -x "$ADB" ] || { echo "CHECK FAIL: no adb at $ADB"; rc=1; }
  [ -x "$EMULATOR" ] || { echo "CHECK FAIL: no emulator at $EMULATOR"; rc=1; }
  [ -f "$CLIENT" ] || { echo "CHECK FAIL: $CLIENT missing"; rc=1; }
  PD_PREFLIGHT_DRY_RUN=1 bash "$WT/tools/emulator/preflight.sh" || { echo "CHECK FAIL: preflight"; rc=1; }
  echo "--- the boot start.sh will run ---"
  echo "$EMULATOR -avd $AVD_NAME -port 5554 -memory 2048 -cores 2 -no-audio -no-boot-anim -no-snapshot -no-metrics -netdelay none -netspeed full -no-window -gpu swiftshader_indirect"
  echo "--- budget: $(cat "$HOME/dev/pocketdeck/.agent/budgets/mw-phone" 2>/dev/null || echo '?') boot(s) ---"
  echo "--- boots already in the ledger for mw-phone: $(ledger_boots /tmp/pocketdeck-boots.ledger mw-phone) ---"
  if device_present; then
    echo "CHECK FAIL: $SERIAL is already up (a boot would be wasted)"
    rc=1
  fi
  [ "$rc" -eq 0 ] && echo "CHECK OK: multiwin rehearsal" || echo "CHECK FAIL: multiwin rehearsal"
  exit "$rc"
fi

# --- against the booted rig -------------------------------------------------
PAIRS=0
pair_phone() {
  bash "$WT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
  local attempt rc
  for attempt in $(seq 1 6); do
    rc=0
    "$PYTHON" "$WT/tools/emulator/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" check \
      >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && { step "already paired"; PAIRS=1; return 0; }
    [ "$rc" -eq 3 ] && { step "phone busy, waiting"; sleep 5; continue; }
    step "pairing (attempt $attempt)"
    "$PYTHON" "$WT/tools/emulator/poc.py" --state "$STATE" --addr "127.0.0.1:$PORT" \
      --serial "$SERIAL" --adb "$ADB" pair && { PAIRS=1; return 0; }
    bash "$WT/tools/emulator/unlock.sh" >/dev/null 2>&1 || true
    sleep 3
  done
  return 1
}

START=$(date +%s)
device_present || { echo "[multiwin] error: $SERIAL is not up; boot it with tools/emulator/start.sh" >&2; exit 1; }

# The Shizuku shell service survives an APK reinstall and would keep answering
# from the previous build (lessons, 10-28): kill it and restart after the install,
# then prove which server answered.
DEVPORT="$(ensure_forward || true)"
step "server: pid $(server_pid||true) port ${DEVPORT:-none} forward 127.0.0.1:$PORT"
emu shell pkill -f "dev.pocketdeck:pocketdeck" >/dev/null 2>&1 || true
for _ in $(seq 1 10); do
  [ -z "$(server_pids)" ] && break
  sleep 1
done
restart_server || { echo "[multiwin] error: the shell service did not come back" >&2; exit 1; }
DEVPORT="$(ensure_forward)" || { echo "[multiwin] error: no server port after restart" >&2; exit 1; }
step "restarted: pid $(server_pid) port $DEVPORT"

step "pairing state: $(basename "$STATE") (new this run)"
pair_phone || { echo "[multiwin] error: could not pair with the rig" >&2; exit 1; }

# The pairing above belongs to the restarted build; the reply proves which server
# answered (a build without `multi` would answer every app `single`... or nothing).
emu logcat -c >/dev/null 2>&1 || true
step "proving the new server answers apps with multi"
SERVER_RC=1
if "$PYTHON" "$WT/tools/fakephone/deckctl.py" --host 127.0.0.1 --port "$PORT" --state "$STATE" \
    --wait-for-free 20 apps >"$OUT/apps.txt" 2>"$OUT/apps.err"; then
  MULTI_N=$(awk -F'\t' '$3=="multi"' "$OUT/apps.txt" | wc -l | tr -d ' ')
  SINGLE_N=$(awk -F'\t' '$3=="single"' "$OUT/apps.txt" | wc -l | tr -d ' ')
  if [ "$MULTI_N" -ge 1 ] && [ "$SINGLE_N" -ge 1 ]; then
    echo "PASS [WIN-24] the server after the install answers apps with multi ($MULTI_N multi, $SINGLE_N single, $(tail -1 "$OUT/apps.txt"))"
    SERVER_RC=0
  else
    echo "FAIL [WIN-24] the apps reply carries no multi field ($MULTI_N multi, $SINGLE_N single)"
  fi
else
  echo "FAIL [WIN-24] apps.list failed: $(tail -3 "$OUT/apps.err")"
fi

step "multiwin checks"
"$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" \
  --adb "$ADB" --serial "$SERIAL" --wt "$WT" --out "$OUT" 2>&1 | tee "$OUT/multiwin.log"
CLIENT_RC=${PIPESTATUS[0]}
step "client exit $CLIENT_RC"

emu logcat -d -s PocketDeckSvc:I >"$OUT/logcat-server.txt" 2>/dev/null || true
emu logcat -d >"$OUT/logcat-all.txt" 2>/dev/null || true
emu shell dumpsys display >"$OUT/display-final.txt" 2>/dev/null || true

step "done in $(( $(date +%s) - START ))s; artefacts in $OUT"
[ "$SERVER_RC" -eq 0 ] && [ "$CLIENT_RC" -eq 0 ]
