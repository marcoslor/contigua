#!/usr/bin/env bash
# netshape — the Android emulator console's own network shaper.
#
#   bash tools/emulator/netshape.sh show            # current speed and delay
#   bash tools/emulator/netshape.sh speed 3         # 3 Mbit/s each way
#   bash tools/emulator/netshape.sh delay 100       # 100 ms each way
#   bash tools/emulator/netshape.sh throttle 3 100  # both
#   bash tools/emulator/netshape.sh reset           # full speed, no delay
#   bash tools/emulator/netshape.sh --check throttle 3 100   # print, don't run
#
# One serial, always named: CONTIGUA_SERIAL (default emulator-5554). A
# serial that is not an emulator is refused, so the person's phone can never be
# shaped by a test. No root, no host network change: the console shapes the
# emulator's own virtual NIC. Measured 2026-11-09: the Mac's e2e reaches the
# phone through an `adb forward`, which is an adb pipe rather than the guest's
# NIC, so this shaper does not touch that leg (S3 shapes it with pdpathfault
# and uses `show` to prove the console is unshaped); it remains useful for
# traffic the guest originates on its own NIC.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

CHECK=0
if [ "${1:-}" = "--check" ]; then
    CHECK=1
    shift
fi

case "$SERIAL" in
    emulator-*) ;;
    *)
        echo "netshape: refusing to shape '$SERIAL' (only an emulator-* serial)" >&2
        exit 2
        ;;
esac

run() {
    if [ "$CHECK" -eq 1 ]; then
        printf 'netshape: would run: adb -s %s emu network %s\n' "$SERIAL" "$*"
        return 0
    fi
    # `emu` is lib.sh's adb -s SERIAL wrapper; the console verb is its own
    # `emu network`.
    emu emu network "$@"
}

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

speed_bits() { # speed_bits MBIT — the console wants bits per second
    python3 - "$1" <<'PY'
import sys
value = float(sys.argv[1])
if value <= 0:
    sys.exit(2)
print(int(round(value * 1000 * 1000)))
PY
}

action="${1:-show}"
shift || true
case "$action" in
    show|status)
        run status
        ;;
    reset)
        run speed full || exit $?
        run delay none || exit $?
        ;;
    speed)
        [ $# -eq 1 ] || { usage; exit 2; }
        bits="$(speed_bits "$1")" || { echo "netshape: speed needs Mbit/s > 0" >&2; exit 2; }
        run speed "$bits"
        ;;
    delay)
        [ $# -eq 1 ] || { usage; exit 2; }
        case "$1" in
            none|gprs|edge|umts) run delay "$1" ;;
            *)
                if ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 0 else 1)" "$1" 2>/dev/null; then
                    echo "netshape: delay needs milliseconds >= 0 (or none|gprs|edge|umts)" >&2
                    exit 2
                fi
                run delay "$1"
                ;;
        esac
        ;;
    throttle)
        [ $# -eq 2 ] || { usage; exit 2; }
        bits="$(speed_bits "$1")" || { echo "netshape: speed needs Mbit/s > 0" >&2; exit 2; }
        run speed "$bits" || exit $?
        run delay "$2" || exit $?
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "netshape: unknown action '$action'" >&2
        usage
        exit 2
        ;;
esac
