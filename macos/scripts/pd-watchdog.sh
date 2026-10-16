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
#
#   WATCHDOG killed reason=colorsync cpu=93.1 pid=12345    (exit 1)
#
# Ten seconds in a row, not one sample: a display appearing legitimately raises
# colorsync for a moment, and that must not kill a healthy run. Silence and exit
# 0 mean only that the process ended on its own.
#
# Limits: colorsync 60% (its daemon and its per-display helper together),
# WindowServer 80%.
set -u

PID="${1:-}"
if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
    exit 0
fi
if [ -z "$PID" ]; then
    echo "usage: pd-watchdog.sh PID" >&2
    exit 2
fi

# cpu_sum "name name ..." — %CPU of every process with one of these executable
# names, summed. The name is the last path component, the way pd-load.swift
# reads it; one `ps` for all of them, once a second.
cpu_sum() {
    ps -axo %cpu=,comm= 2>/dev/null | awk -v want="$1" '
        BEGIN { count = split(want, names, " ") }
        {
            comm = $0
            sub(/^[[:space:]]*[0-9.]+[[:space:]]+/, "", comm)
            for (i = length(comm); i > 0; i--) {
                if (substr(comm, i, 1) == "/") { comm = substr(comm, i + 1); break }
            }
            for (i = 1; i <= count; i++) if (comm == names[i]) { total += $1; break }
        }
        END { printf "%.1f", total }'
}

# above VALUE LIMIT — true when the sample is over the limit.
above() { awk -v value="$1" -v limit="$2" 'BEGIN { exit !(value > limit) }'; }

COLORSYNC_LIMIT=60
WINDOWSERVER_LIMIT=80
STRIKES=10

colorsync_strikes=0
windowserver_strikes=0

while kill -0 "$PID" 2>/dev/null; do
    colorsync="$(cpu_sum "colorsyncd colorsync.displayservices")"
    windowserver="$(cpu_sum "WindowServer")"
    if above "$colorsync" "$COLORSYNC_LIMIT"; then
        colorsync_strikes=$((colorsync_strikes + 1))
    else
        colorsync_strikes=0
    fi
    if above "$windowserver" "$WINDOWSERVER_LIMIT"; then
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
    if [ -n "$reason" ]; then
        kill "$PID" 2>/dev/null
        for _ in 1 2 3; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 1
        done
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
        echo "WATCHDOG killed reason=$reason pid=$PID"
        exit 1
    fi
    sleep 1
done
exit 0
