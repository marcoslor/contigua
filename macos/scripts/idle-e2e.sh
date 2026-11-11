#!/usr/bin/env bash
# Runs the full e2e suite once, when the Mac is idle.
#
#   ./scripts/idle-e2e.sh [--idle-minutes N] [--max-load L] [--summary FILE] [--log FILE] [--shard N/M]
#
# Waits until nobody has touched the keyboard, mouse or trackpad for N minutes
# (HIDIdleTime, default 10) and the 1-minute load average is under L (default 2),
# then runs `check-e2e.sh all` once in the foreground and exits with its status.
# It never schedules itself: whoever wants a run starts it (and may leave it
# waiting for the idle period).
#
# The run's output is kept in the log (default /tmp/contigua-idle-e2e-<time>.log);
# the log ends with the run's cost (scripts/e2e-cost.py: DAEMONS, BYCHECK per
# check, COST), and one summary line is appended to the summary file (default
# /tmp/contigua-idle-e2e.txt):
#
#   2026-10-18T23:10:04 all passed=222 failed=3 | QUIET … | LOAD … | COST … | log=…
#
# PD_E2E_PORT / PD_E2E_PROFILE / PD_FAKE_TLS_PYTHON pass through to check-e2e.sh.
# PD_HEAVY names a wrapper that serializes heavy work on this Mac (it gets the
# command to run as its arguments), e.g. an agent's machine-wide lock script.
set -uo pipefail

MACOS="$(cd "$(dirname "$0")/.." && pwd)"
IDLE_MINUTES=10
MAX_LOAD=2
SUMMARY="/tmp/contigua-idle-e2e.txt"
LOG="/tmp/contigua-idle-e2e-$(date +%Y%m%d-%H%M%S).log"
SHARD=()

while [ $# -gt 0 ]; do
    case "$1" in
        --idle-minutes) IDLE_MINUTES="${2:?}"; shift 2 ;;
        --max-load) MAX_LOAD="${2:?}"; shift 2 ;;
        --summary) SUMMARY="${2:?}"; shift 2 ;;
        --log) LOG="${2:?}"; shift 2 ;;
        --shard) SHARD=(--shard "${2:?}"); shift 2 ;;
        *) echo "usage: idle-e2e.sh [--idle-minutes N] [--max-load L] [--summary FILE] [--log FILE] [--shard N/M]" >&2; exit 2 ;;
    esac
done

# Seconds since the last keyboard/pointer event.
idle_seconds() {
    ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }'
}

load_1m() { sysctl -n vm.loadavg | awk '{ print $2 }'; }

ready() {
    [ "$(idle_seconds)" -ge $((IDLE_MINUTES * 60)) ] \
        && awk -v load="$(load_1m)" -v max="$MAX_LOAD" 'BEGIN { exit !(load < max) }'
}

said=""
until ready; do
    if [ -z "$said" ]; then
        echo "waiting for ${IDLE_MINUTES} idle minutes and a load under ${MAX_LOAD} (idle $(idle_seconds)s, load $(load_1m))"
        said=1
    fi
    sleep 30
done
echo "idle $(idle_seconds)s, load $(load_1m): running check-e2e.sh all ${SHARD[*]:-}; log: $LOG"

started="$(date +%Y-%m-%dT%H:%M:%S)"
cost="$(mktemp -t contigua-idle-cost)"
${PD_HEAVY:+"$PD_HEAVY"} python3 -I "$MACOS/scripts/e2e-cost.py" --profile "${PD_E2E_PROFILE:-e2e}" --summary "$cost" --by-check -- \
    "$MACOS/scripts/check-e2e.sh" all ${SHARD[@]+"${SHARD[@]}"} > "$LOG" 2>&1
status=$?

line="$started all${SHARD[*]:+ ${SHARD[*]}}"
line="$line $(grep -E '^passed=' "$LOG" | tail -1 || echo "no result (exit $status)")"
line="$line | $(grep '^QUIET ' "$LOG" | tail -1)"
line="$line | $(grep '^LOAD ' "$LOG" | tail -1)"
line="$line | $(tail -1 "$cost" 2>/dev/null)"
line="$line | log=$LOG"
rm -f "$cost"
echo "$line" >> "$SUMMARY"
echo "$line"
exit "$status"
