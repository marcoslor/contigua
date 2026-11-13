#!/usr/bin/env bash
# The phone mirror's picture on the emulator rig: ONE boot (mirror-frames.py).
#
#   tools/emulator/mirror-frames.sh            the run (it runs under the boot budget)
#   tools/emulator/mirror-frames.sh --check    a dry run: preflight, the analyser's self-test, the
#                                              deckctl parser, the serial — no device, no boot
#
# Run it as `bash tools/emulator/mirror-frames.sh`. It boots the rig (start.sh builds the app from
# this worktree), pairs once, opens a phone mirror, resizes it through six sizes (odd ones
# included), and at each size checks the decoded frame against the picture rect the phone
# named (window.content): the picture is where the rect says, to 1 px, and no band lies inside it.
# The emulator is killed at the end whatever happened. Results: .work/emu/mirror-frames.log.
set -u

MODE=run
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "mirror-frames.sh: unknown flag $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/../.." || exit 1
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export CONTIGUA_PORT="${CONTIGUA_PORT:-47811}"
export CONTIGUA_SERIAL=emulator-5554
export CONTIGUA_AGENT_DIR="$PWD/.work/emu"
mkdir -p "$CONTIGUA_AGENT_DIR"
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

OUT="$CONTIGUA_AGENT_DIR/mirror-frames"
LOG="$CONTIGUA_AGENT_DIR/mirror-frames.log"
STATE="$CACHE_DIR/deckctl-state.json"

# ---- --check: everything that can be wrong before a boot -------------------
if [ "$MODE" = "check" ]; then
  bash -n "$0" || { echo "CHECK FAIL: syntax"; exit 1; }
  bash tools/emulator/preflight.sh || { echo "CHECK FAIL: preflight"; exit 1; }
  "$PYTHON" -c "import ast; ast.parse(open('tools/emulator/mirror-frames.py').read())" \
    || { echo "CHECK FAIL: mirror-frames.py does not parse"; exit 1; }
  mkdir -p "$OUT"
  "$PYTHON" tools/emulator/mirror-frames.py --self-test --out "$OUT" \
    || { echo "CHECK FAIL: the frame analyser self-test"; exit 1; }
  "$PYTHON" - <<'PY' || { echo "CHECK FAIL: deckctl parser"; exit 1; }
import sys
sys.path.insert(0, "tools/fakephone")
import deckctl
args = deckctl.build_parser().parse_args(["open", "--phone", "--w", "608", "--h", "1344"])
assert args.command == "open" and args.phone
PY
  command -v ffmpeg >/dev/null && command -v sips >/dev/null \
    || { echo "CHECK FAIL: ffmpeg or sips missing"; exit 1; }
  if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
    echo "CHECK FAIL: $SERIAL is already running (not ours to touch)"
    exit 1
  fi
  echo "CHECK OK: preflight, frame analyser, deckctl parser, ffmpeg and sips; $SERIAL free"
  exit 0
fi

# ---- the run (ONE boot) -----------------------------------------------------
if "$ADB" devices 2>/dev/null | grep -q "^$SERIAL"; then
  echo "mirror-frames: $SERIAL already running: refusing to touch it"
  exit 1
fi

kill_emulator() {
  "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}
trap 'kill_emulator' EXIT

echo "mirror-frames: booting $SERIAL (one boot budget)"
if ! bash tools/emulator/start.sh; then
  # The rig's known flake (see phone-screen.sh): restart the shell service once.
  echo "mirror-frames: start.sh failed; restarting the shell service"
  if ! restart_server; then
    echo "mirror-frames: the shell service never came up (unverified)"
    echo "failed: 1 (start)" > "$LOG"
    exit 1
  fi
fi
ensure_forward >/dev/null || { echo "mirror-frames: no server port"; echo "failed: 1 (port)" > "$LOG"; exit 1; }

if ! "$PYTHON" tools/emulator/poc.py --state "$STATE" --addr "127.0.0.1:$PORT" \
      --serial "$SERIAL" --adb "$ADB" pair; then
  echo "mirror-frames: pairing failed (unverified)"
  echo "failed: 1 (pair)" > "$LOG"
  exit 1
fi

mkdir -p "$OUT"
"$PYTHON" tools/emulator/mirror-frames.py --state "$STATE" --addr "127.0.0.1:$PORT" --out "$OUT"
rc=$?
echo "mirror-frames: exit $rc (log $LOG)"
exit "$rc"
