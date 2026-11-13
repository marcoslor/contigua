#!/usr/bin/env bash
# adopt: the app's own "New window" becomes another Mac window on API 36
# (WIN-44…WIN-49). One boot.
#
#   bash tools/emulator/adopt.sh --check    # rehearse: no device, no boot
#   bash tools/emulator/adopt.sh            # against an already booted rig
#
# Build the APK first (K1):
#   cd android && ./gradlew :app:assembleDebug
#
# The caller owns the emulator's whole life in ONE call:
#   bash tools/emulator/start.sh --no-build && bash tools/emulator/adopt.sh; r=$?
#   adb -s emulator-5554 emu kill; exit $r
#
# The check streams Chrome, taps its ⋮ and "New window" (the spike's path),
# expects window.task once, adopts the task, proves both streams draw, runs
# Back/close on the adopted window with the first untouched, then opens the
# streamed app from the phone's launcher and expects moved_to_phone and no
# second window.task. Artefacts land in $CONTIGUA_ADOPT_OUT
# (default $MAIN_REPO/.work/adopt/emu).
set -uo pipefail

MODE=boot
case "${1:-}" in
  --check) MODE=check ;;
  "") ;;
  *) echo "[adopt] error: unknown flag $1" >&2; exit 2 ;;
esac

. "$(dirname "$0")/lib.sh"
cd "$REPO_ROOT"

WT="$REPO_ROOT"
OUT="${CONTIGUA_ADOPT_OUT:-$MAIN_REPO/.work/adopt/emu}"
# A fresh pairing state per run: a reused one can be on the phone's revoked
# side and every attempt then dies on the handshake.
STATE="$CACHE_DIR/deckctl-state-adopt-$(date +%s).json"
find "$CACHE_DIR" -maxdepth 1 -name 'deckctl-state-adopt-*.json' -mtime +1 -delete 2>/dev/null || true
CLIENT="$WT/tools/fakephone/deckctl.py"
mkdir -p "$OUT"
export CONTIGUA_AGENT_DIR="${CONTIGUA_AGENT_DIR:-$OUT/emu}"

# --- rehearsal --------------------------------------------------------------
if [ "$MODE" = check ]; then
  rc=0
  bash -n "$0" || { echo "CHECK FAIL: bash -n $0"; rc=1; }
  "$PYTHON" -m py_compile "$CLIENT" "$WT/tools/fakephone/fakephone.py" \
    || { echo "CHECK FAIL: py_compile"; rc=1; }
  "$PYTHON" - <<PY || { echo "CHECK FAIL: adopt symbols"; rc=1; }
import importlib.util, sys
sys.path.insert(0, "$WT/tools/fakephone")
import deckctl, proto
assert hasattr(deckctl, "cmd_adopt"), "deckctl has no adopt command"
assert hasattr(deckctl, "_adopt_toolbar"), "deckctl has no toolbar fail-fast"
assert hasattr(deckctl, "StreamRecorder") and hasattr(proto, "pack_touch")
spec = importlib.util.spec_from_file_location("mw", "$WT/tools/emulator/multiwin.py")
mw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mw)
assert hasattr(mw, "warm_chrome") and hasattr(mw, "Dev"), "multiwin has no warm_chrome"
# The toolbar probe must follow the promo Back: the promo's modal is the only
# window uiautomator dumps while it is up, and boot 4 lost its boot to that.
adopt_src = open(deckctl.__file__).read()
i_adopt = adopt_src.find("def cmd_adopt")
i_back = adopt_src.find('"action": "back"', i_adopt)
i_probe = adopt_src.find("_adopt_toolbar(args, source", i_adopt)
assert 0 < i_back < i_probe, "the toolbar probe must come after the promo Back"
print("CHECK OK: deckctl adopt + proto + multiwin warm symbols")
PY
  # The exact global-flags then subcommand shape the boot uses: a global flag
  # after `adopt` made argparse read it as the command on boot 2 (11-16).
  "$PYTHON" "$CLIENT" --host 127.0.0.1 --port 1 --state /dev/null \
    adopt --adb "$ADB" --serial emulator-5554 --help >/dev/null 2>&1 \
    || { echo "CHECK FAIL: deckctl adopt argument order"; rc=1; }
  # The spike's reset order, copied exactly: clear, 1.5 s, warm, then the
  # stream. Boot 3 skipped the warm; the sleep is the spike's own gap.
  "$PYTHON" - "$0" <<'PY' || { echo "CHECK FAIL: clear/sleep/warm order"; rc=1; }
import sys
text = open(sys.argv[1]).read()
order = ["pm clear com.android.chrome", "sleep 1.5",
         "warm Chrome past its first run"]
pos = [text.find(needle) for needle in order]
if not all(p >= 0 for p in pos) or pos != sorted(pos):
    raise SystemExit(1)
PY
  command -v ffmpeg >/dev/null || { echo "CHECK FAIL: no ffmpeg"; rc=1; }
  [ -x "$ADB" ] || { echo "CHECK FAIL: no adb at $ADB"; rc=1; }
  [ -x "$EMULATOR" ] || { echo "CHECK FAIL: no emulator at $EMULATOR"; rc=1; }
  [ -f "$CLIENT" ] || { echo "CHECK FAIL: $CLIENT missing"; rc=1; }
  PD_PREFLIGHT_DRY_RUN=1 bash "$WT/tools/emulator/preflight.sh" || { echo "CHECK FAIL: preflight"; rc=1; }
  echo "--- the boot start.sh will run ---"
  echo "$EMULATOR -avd $AVD_NAME -port 5554 -memory 2048 -cores 2 -no-audio -no-boot-anim -no-snapshot -no-metrics -netdelay none -netspeed full -no-window -gpu swiftshader_indirect"
  echo "--- budget: $(cat "$MAIN_REPO/.work/budgets/adopt" 2>/dev/null || echo '?') boot(s) ---"
  echo "--- boots already in the ledger for adopt: $(ledger_boots /tmp/contigua-boots.ledger adopt) ---"
  if device_present; then
    echo "CHECK FAIL: $SERIAL is already up (a boot would be wasted)"
    rc=1
  fi
  [ "$rc" -eq 0 ] && echo "CHECK OK: adopt rehearsal" || echo "CHECK FAIL: adopt rehearsal"
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
device_present || { echo "[adopt] error: $SERIAL is not up; boot it with tools/emulator/start.sh" >&2; exit 1; }
[ "$SERIAL" = "emulator-5554" ] \
  || { echo "[adopt] error: pm clear is allowed on emulator-5554 only (got $SERIAL)" >&2; exit 1; }

# The Shizuku shell service survives an APK reinstall and would keep answering
# from the previous build: kill it and restart after the install, then prove
# which server answered (lessons, 10-28).
DEVPORT="$(ensure_forward || true)"
step "server: pid $(server_pid||true) port ${DEVPORT:-none} forward 127.0.0.1:$PORT"
emu shell pkill -f "app.contigua:contigua" >/dev/null 2>&1 || true
for _ in $(seq 1 10); do
  [ -z "$(server_pids)" ] && break
  sleep 1
done
restart_server || { echo "[adopt] error: the shell service did not come back" >&2; exit 1; }
DEVPORT="$(ensure_forward)" || { echo "[adopt] error: no server port after restart" >&2; exit 1; }
step "restarted: pid $(server_pid) port $DEVPORT"

step "pairing state: $(basename "$STATE") (new this run)"
pair_phone || { echo "[adopt] error: could not pair with the rig" >&2; exit 1; }

# Chrome's own five-window cap hides "New window"; a fresh clear brings it back
# to one window. The server restart above closed every open stream, so the
# spike's order holds from here: clear, 1.5 s, warm, then open the stream.
step "pm clear com.android.chrome"
emu shell pm clear com.android.chrome >"$OUT/pm-clear.txt" 2>&1 || true
sleep 1.5

# A cleared Chrome starts on its first-run screen: no toolbar, so the ⋮ tap
# finds no menu (boot 3, 11:29). The spike's warm launch accepts/dismisses the
# first run on the phone's own display and force-stops it; every streamed
# window after that has a real page (WIN-44). The client then proves the ⋮ is
# on the stream before it taps anything.
step "warm Chrome past its first run"
"$PYTHON" - <<PY || { echo "[adopt] error: Chrome's first run did not clear" >&2; exit 1; }
import importlib.util
spec = importlib.util.spec_from_file_location("mw", "$WT/tools/emulator/multiwin.py")
mw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mw)
raise SystemExit(0 if mw.warm_chrome(mw.Dev("$ADB", "$SERIAL", "$OUT")) else 1)
PY
emu logcat -c >/dev/null 2>&1 || true

step "adopt checks"
"$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" \
  adopt --adb "$ADB" --serial "$SERIAL" \
  --out-prefix "$OUT/adopt" 2>&1 | tee "$OUT/adopt.log"
CLIENT_RC=${PIPESTATUS[0]}
step "client exit $CLIENT_RC"

emu logcat -d -s ContiguaSvc:I >"$OUT/logcat-server.txt" 2>/dev/null || true
emu logcat -d >"$OUT/logcat-all.txt" 2>/dev/null || true
emu shell dumpsys activity activities >"$OUT/activities-final.txt" 2>/dev/null || true
emu shell dumpsys display >"$OUT/display-final.txt" 2>/dev/null || true

step "done in $(( $(date +%s) - START ))s; artefacts in $OUT"
[ "$CLIENT_RC" -eq 0 ]
