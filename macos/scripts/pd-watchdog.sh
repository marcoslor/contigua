#!/bin/bash
# pd-watchdog — kills a process that is dragging the Mac's display plumbing down
# with it, and says why.
#
# A quiet e2e run makes macOS create (or adopt) a virtual display and put the
# app's windows on it. That path has frozen this Mac once (colorsync and the
# window server at ~100% CPU until it had to be hard-reset), so no run may be
# left able to repeat it: check-e2e.sh starts one of these for the run's virtual
# display and one for every app it launches, and a run reports any line below.
#
# Every second it reads the CPU of the two colorsync processes together and of
# WindowServer (the same reading `top` shows) and, when one of them stays above
# its limit for ten samples in a row, kills the process it was given:
#
#   pd-watchdog.sh PID
#   pd-watchdog.sh --targets FILE
#
#   WATCHDOG killed reason=colorsync cpu=93.1 pid=12345    (exit 1)
#
# With --targets, one watchdog guards a whole run: FILE lists the processes,
# one "<slot> <pid>" line each, and is read again every second (the run rewrites
# it as its apps come and go); the watchdog exits once FILE is gone. When a
# limit fires, every listed process still alive is killed, one line each.
#
# Ten seconds in a row, not one sample: a display appearing legitimately raises
# colorsync for a moment, and that must not kill a healthy run. Silence and exit
# 0 mean only that the process ended on its own (or FILE went away).
#
# Limits: colorsync 60% (its daemon and its per-display helper together),
# WindowServer 80%. One `ps` and one `awk` a second: the watchdog runs for as
# long as the run, so its own cost counts.
set -u

PID=""
TARGETS=""
case "${1:-}" in
    --targets) TARGETS="${2:-}" ;;
    *) PID="${1:-}" ;;
esac
if [ -z "$PID$TARGETS" ]; then
    echo "usage: pd-watchdog.sh PID | --targets FILE" >&2
    exit 2
fi

# guarded — the live processes to guard, in PIDS; false when there is nothing
# left to watch (the PID ended, or FILE is gone).
guarded() {
    PIDS=()
    if [ -n "$PID" ]; then
        kill -0 "$PID" 2>/dev/null || return 1
        PIDS=("$PID")
        return 0
    fi
    [ -f "$TARGETS" ] || return 1
    local slot pid
    while read -r slot pid; do
        [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null && PIDS+=("$pid")
    done < "$TARGETS"
    return 0
}

# sample — "<colorsync> <windowserver> <colorsync x10> <windowserver x10>":
# %CPU of the processes with these executable names (the last path component,
# the way pd-load.swift reads it), summed, from one `ps`.
sample() {
    ps -axo %cpu=,comm= 2>/dev/null | awk '
        {
            comm = $0
            sub(/^[[:space:]]*[0-9.]+[[:space:]]+/, "", comm)
            sub(/.*\//, "", comm)
            if (comm == "colorsyncd" || comm == "colorsync.displayservices") colorsync += $1
            else if (comm == "WindowServer") windowserver += $1
        }
        END { printf "%.1f %.1f %d %d\n", colorsync, windowserver, colorsync * 10, windowserver * 10 }'
}

COLORSYNC_LIMIT=600      # tenths of a percent
WINDOWSERVER_LIMIT=800
STRIKES=10

colorsync_strikes=0
windowserver_strikes=0

while guarded; do
    read -r colorsync windowserver colorsync10 windowserver10 < <(sample)
    if [ "${colorsync10:-0}" -gt "$COLORSYNC_LIMIT" ]; then
        colorsync_strikes=$((colorsync_strikes + 1))
    else
        colorsync_strikes=0
    fi
    if [ "${windowserver10:-0}" -gt "$WINDOWSERVER_LIMIT" ]; then
        windowserver_strikes=$((windowserver_strikes + 1))
    else
        windowserver_strikes=0
    fi
    reason=""
    if [ "$colorsync_strikes" -ge "$STRIKES" ]; then
        reason="colorsync cpu=$colorsync"
    fi
    if [ "$windowserver_strikes" -ge "$STRIKES" ]; then
        if [ -n "$reason" ]; then
            reason="colorsync cpu=$colorsync and windowserver cpu=$windowserver"
        else
            reason="windowserver cpu=$windowserver"
        fi
    fi
    if [ -n "$reason" ] && [ ${#PIDS[@]} -gt 0 ]; then
        for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
        for pid in "${PIDS[@]}"; do
            for _ in 1 2 3; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
            echo "WATCHDOG killed reason=$reason pid=$pid"
        done
        exit 1
    fi
    sleep 1
done
exit 0
