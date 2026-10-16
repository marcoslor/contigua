#!/usr/bin/env bash
# End-to-end checks C3-C13 for the macOS client against tools/fakephone.
#
#   ./scripts/check-e2e.sh [qr|pair|render|resize|input|mouseback|input-global|pause|direct|nav|mirror|spotlight|pinch|chrome|trackpad|clip|sharein|links|share|apk|drop|dock|nickname|notify|audio|handoff|deck|all]
#
# Every check starts from a clean slate: no PocketDeck or fakephone processes
# left by an earlier run, a fresh fakephone state file and no pairing key in
# the Keychain (a key created by a *different* build would make macOS prompt
# for Keychain access, which is why C4 asks for the key to be deleted first).
#
# Runs are serialized by a lock: they share the port, the work dir and the
# PocketDeck/fakephone processes, so an overlapping run would kill the other.
#
# Input (C7, C11) is scripted in-process (--debug-input-script): the NSEvents
# are delivered to the stream's view, so no focus change, window stacking or
# window position can swallow them. Gestures (C13) use the same driver, which
# hands the run loop back between steps so the coalesced moves flush. `input-global`
# posts real CGEvents at the window instead; it needs a visible, unobstructed
# window and focus.
#
# A stream window is the stream plus an invisible 52 pt header band above it (as
# wide as the stream, 52 pt taller); `--resize-stream` sizes the stream, so the
# size checks (C6) ask for exactly it and windows are found by the stream's width. The trackpad checks (C15) feed the driver's
# phased scroll events and a model of the raw trackpad fingers (AppKit cannot
# synthesize NSTouch); the phone-side timestamps in the event log give the cadence.
#
# The app runs under its own profile (`--profile e2e`) from its own bundle,
# build/e2e/PocketDeck.app, rebuilt from the current tree on every run. The
# default profile (the user's pairings, cached phones and defaults) and the
# user's build/PocketDeck.app are never read, rebuilt or killed here.
#
# The run's virtual display (pd-vdisplay, PD_E2E_PROFILE's serial): one display
# is created before the first launch and held for the whole run, so the app in
# background mode reuses it instead of creating and destroying its own on every
# launch. Display create/destroy is a system-wide reconfiguration; the checks
# launch the app several times, `all` about 45.
set -uo pipefail

MACOS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
FAKEPHONE="$ROOT/tools/fakephone/fakephone.py"
PROFILE="${PD_E2E_PROFILE:-e2e}"
E2E_BUNDLE="$MACOS/build/e2e/PocketDeck.app"
APP="$E2E_BUNDLE/Contents/MacOS/PocketDeck"
CGINPUT="$MACOS/scripts/cgevent-input.swift"
TOOLS="/tmp/pocketdeck-e2e-tools"
# Named by the source's hash: other checkouts share $TOOLS, and a helper built from
# their (older or newer) source must not be taken for this one.
CGBIN="$TOOLS/cgevent-$(shasum "$CGINPUT" | cut -c1-12)"
WATCH_SRC="$MACOS/scripts/quiet-watch.swift"
WATCHBIN="$TOOLS/quiet-watch-$(shasum "$WATCH_SRC" | cut -c1-12)"
LOAD_SRC="$MACOS/scripts/pd-load.swift"
LOADBIN="$TOOLS/pd-load-$(shasum "$LOAD_SRC" | cut -c1-12)"
VDISPLAY_SRC="$MACOS/scripts/pd-vdisplay.swift"
VDISPLAYBIN="$TOOLS/pd-vdisplay-$(shasum "$VDISPLAY_SRC" | cut -c1-12)"
# The guard (pd-watchdog.sh): no run may leave the Mac's display plumbing
# burning the way the old per-launch displays once did.
WATCHDOG="$MACOS/scripts/pd-watchdog.sh"
# PD_E2E_VISIBLE=1: the app runs as a normal foreground app on the real screens
# and the checks that need real input run too (debugging). Otherwise the run is
# quiet: see "Running the e2e checks while you work" in docs/TRY-IT.md.
VISIBLE="${PD_E2E_VISIBLE:-0}"
LOCK_DIR="/tmp/pocketdeck-e2e.lock"
KEYCHAIN_SERVICE="dev.pocketdeck.mac.$PROFILE"
DEFAULTS_SUITE="dev.pocketdeck.mac.$PROFILE"

PASS=0
FAIL=0

# macOS removes app windows from the on-screen window list (and breaks
# `screencapture -l`) while the display is asleep, and a Mac that sleeps mid-run
# can leave the run's virtual display online (pd-vdisplay then refuses to run),
# so keep it awake for the whole run. -w $$: until this script exits.
caffeinate -d -i -w $$ &
CAFFEINATE_PID=$!
disown "$CAFFEINATE_PID"
trap 'finish' EXIT
caffeinate -u -t 1

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

# PIDs of the e2e app only: the command line must start with the e2e executable.
# The user's build/PocketDeck.app is a different path and never matches.
e2e_app_pids() {
    ps -axww -o pid=,command= | awk -v exe="$APP --profile $PROFILE" '{
        pid = $1
        sub(/^ *[0-9]+ +/, "")
        if (index($0, exe) == 1) print pid
    }'
}

kill_e2e_app() {
    local pids
    pids="$(e2e_app_pids)"
    [ -n "$pids" ] && kill $pids >/dev/null 2>&1
    return 0
}

# Only a run that holds the lock may stop processes: a run that gave up waiting
# for the lock must leave the running one's app and fakephone alone.
finish() {
    if [ -n "${HOLDS_LOCK:-}" ]; then
        kill_e2e_app
        stop_fakephone
        stop_vdisplay
        stop_watchdog app
        unregister_share
        remove_dock_apps
    fi
    stop_watch
    stop_load
    stop_watchdog vdisplay
    stop_watchdog app
    kill "$CAFFEINATE_PID" >/dev/null 2>&1
    release_lock
}

# clear_profile_state — the e2e profile's pairing keys and defaults, nothing else.
clear_profile_state() {
    case "$PROFILE" in
        default|"") say "refusing to clear profile '$PROFILE'"; exit 3 ;;
    esac
    # A key created by a *different* build makes macOS show a modal Keychain
    # permission dialog, which hangs the app; remove every item, not just one.
    while security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do :; done
    # Pair keys now live in a file in the profile's folder; a stale one would make
    # the app authenticate instead of pairing with a fresh fakephone.
    rm -f "$HOME/Library/Application Support/PocketDeck-$PROFILE/pairkeys.json"
    defaults delete "$DEFAULTS_SUITE" >/dev/null 2>&1
    return 0
}

clean() {
    kill_e2e_app
    stop_fakephone
    remove_dock_apps
    sleep 1
    rm -rf "$WORK"
    mkdir -p "$WORK"
    clear_profile_state
}

# start_fake [state-file] — same port every time, never mDNS. FAKE_ALLOW_DELAY
# makes the "person" take that many seconds to tap Allow; FAKE_ARGS adds flags.
start_fake() {
    local state="${1:-$WORK/state.json}"
    # shellcheck disable=SC2086
    python3 "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow --allow-delay "${FAKE_ALLOW_DELAY:-0}" ${FAKE_ARGS:-} \
        --events "$WORK/events.jsonl" \
        --state "$state" > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" && return 0
        sleep 0.25
    done
    say "fakephone did not start:"; cat "$WORK/fake.log"; return 1
}

# launch <args...> — starts the app as a direct child so `wait` works. Quiet runs
# add --background: no activation, no Dock icon, windows on a virtual display.
launch() {
    local quiet=()
    [ "$VISIBLE" = "1" ] || quiet=(--background)
    "$APP" --profile "$PROFILE" "${quiet[@]}" "$@" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    start_watchdog app "$APP_PID"
}

# open_quiet <open args...> — LaunchServices `open` that does not bring the app
# forward in a quiet run.
open_quiet() { if [ "$VISIBLE" = "1" ]; then open "$@"; else open -g "$@"; fi; }

# skip_visible <name> — a step that needs real input through the window server.
skip_visible() { say "SKIP $1 (needs real input; PD_E2E_VISIBLE=1 runs it)"; }

# cg_input <cgevent args...> — a real-input step (visible runs only): the watcher
# counts any pointer move while the marker exists.
cg_input() {
    touch "$WORK/input-step"
    "$CGBIN" "$@" >/dev/null
    local status=$?
    rm -f "$WORK/input-step"
    return $status
}

build_watch() {
    if [ ! -x "$WATCHBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$WATCH_SRC" -o "$WATCHBIN" >/dev/null 2>&1 || { say "could not build $WATCH_SRC"; return 1; }
    fi
}

# start_watch — samples focus, pointer and windows for the whole run (quiet-watch.swift).
# This run's processes: the e2e bundle, anything under $WORK (Dock shims made with
# --dock-dir), the profile's automatic Dock apps and the helper tools in $TOOLS.
# Its files sit next to $WORK, which every check clears.
start_watch() {
    QUIET_FILE="$WORK-quiet.txt"
    QUIET_DETAILS="$WORK-quiet-details.txt"
    rm -f "$QUIET_FILE" "$QUIET_DETAILS"
    "$WATCHBIN" --summary "$QUIET_FILE" --details "$QUIET_DETAILS" \
        --input-marker "$WORK/input-step" \
        --prefix "$E2E_BUNDLE/" --prefix "$WORK/" --prefix "$(profile_dock_dir)/" --prefix "$TOOLS/" &
    WATCH_PID=$!
}

stop_watch() {
    [ -n "${WATCH_PID:-}" ] || return 0
    kill "$WATCH_PID" >/dev/null 2>&1
    wait "$WATCH_PID" 2>/dev/null
    WATCH_PID=""
}

# start_watchdog <slot> <pid> — one of the run's processes is watched
# (pd-watchdog.sh): the run's virtual display and every app launch, the two
# things here that make macOS reconfigure what it shows. A watchdog that fires
# kills its process and appends "WATCHDOG killed reason=…" to the run's log;
# watchdog_report below turns that into the run's FAIL. <slot> pairs the start
# with the stop.
start_watchdog() {
    local slot="$1" target="$2"
    "$WATCHDOG" "$target" >> "$WATCHDOG_LOG" 2>&1 &
    case "$slot" in
        vdisplay) WD_VDISPLAY_PID=$! ;;
        app)      WD_APP_PID=$! ;;
    esac
}

# stop_watchdog <slot> — nothing to watch any more. A watchdog whose process is
# already gone has exited on its own; this only makes that explicit, so no
# watcher outlives the run.
stop_watchdog() {
    local slot="$1" pid=""
    case "$slot" in
        vdisplay) pid="${WD_VDISPLAY_PID:-}" ;;
        app)      pid="${WD_APP_PID:-}" ;;
    esac
    [ -n "$pid" ] || return 0
    kill "$pid" >/dev/null 2>&1
    wait "$pid" 2>/dev/null
    case "$slot" in
        vdisplay) WD_VDISPLAY_PID="" ;;
        app)      WD_APP_PID="" ;;
    esac
    return 0
}

# init_watchdog — the run's watchdog log, empty at its start (the lock is held,
# so no other run's lines can be in it).
init_watchdog() {
    WATCHDOG_LOG="$WORK-watchdog.txt"
    : > "$WATCHDOG_LOG"
}

# watchdog_report — what the watchdogs saw, right before the run's summary. Any
# killed line is a FAIL: a process was taken away from the check that was using
# it, because the machine was under enough pressure to need that.
watchdog_report() {
    stop_watchdog vdisplay
    stop_watchdog app
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        say "$line"
        bad "$line"
    done < "$WATCHDOG_LOG"
}

# build_load — the run's sampler (pd-load.swift): samples WindowServer and
# colorsync CPU and watches the online display list, and reports the LOAD line.
build_load() {
    if [ ! -x "$LOADBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$LOAD_SRC" -o "$LOADBIN" >/dev/null 2>&1 || { say "could not build $LOAD_SRC"; return 1; }
    fi
}

# start_load — from before the run's display exists: the helper's own display
# appearing is one change it sees (vdisplay/adds), and the one going away at the
# end of the run (load_report) is another.
start_load() {
    LOAD_FILE="$WORK-load.txt"
    rm -f "$LOAD_FILE"
    "$LOADBIN" --summary "$LOAD_FILE" &
    LOAD_PID=$!
}

stop_load() {
    [ -n "${LOAD_PID:-}" ] || return 0
    kill "$LOAD_PID" >/dev/null 2>&1
    wait "$LOAD_PID" 2>/dev/null
    LOAD_PID=""
}

# load_report — ends what the run holds and reports what it cost, before its
# QUIET verdict. The app goes first (its windows are on the run's display, and
# the sample to come is the display's, not a window migration), then the
# display, and the last three seconds are sampled: a quiet run's whole cost is
# that one display appearing and going away (vdisplay=2). Every run reports one
# LOAD line, whatever a check says: the numbers are the point of quiet mode
# being allowed at all.
load_report() {
    kill_e2e_app
    stop_vdisplay
    sleep 3
    stop_load
    say "$(cat "$LOAD_FILE" 2>/dev/null || echo "LOAD no samples")"
}

# build_vdisplay — the run's virtual display helper (pd-vdisplay.swift). A quiet
# run holds ONE display for the whole run: the app under test finds it by its
# ids and puts its windows there, instead of creating and destroying a display
# on every launch. Each create/destroy is a system-wide reconfiguration
# (WindowServer, colorsync and every running app re-lay out), and a check
# launches the app several times.
build_vdisplay() {
    if [ ! -x "$VDISPLAYBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$VDISPLAY_SRC" -o "$VDISPLAYBIN" >/dev/null 2>&1 || { say "could not build $VDISPLAY_SRC"; return 1; }
    fi
}

# start_vdisplay — starts the helper and reads the one line it prints
# ("id=… w=… h=… scale=…"): the id is the display the run's app should use, the
# size and scale are what the display-dependent expectations below are read
# from (never hardcoded again). Nothing is passed on to the app.
#
# A quiet run holds the display or it does not run: every check below is written
# against it, and falling back to a display per app launch is the many-
# reconfigurations path this display exists to avoid. The helper prints
# "FAIL vdisplay: …" (and exits non-zero) when it cannot create one or finds one
# of its identity already online; the run stops there, "all" included.
start_vdisplay() {
    # A visible run is on the person's own screens: the app looks for no display
    # of its own there and makes none, so this run makes none either. Those
    # screens are Retina at 2x — the scale the numbers these checks have always
    # been written against.
    if [ "$VISIBLE" = "1" ]; then
        VDISPLAY_ID=""
        RUN_SCALE=2
        return 0
    fi
    VDISPLAY_FILE="$WORK-vdisplay.txt"
    rm -f "$VDISPLAY_FILE"
    "$VDISPLAYBIN" --profile "$PROFILE" > "$VDISPLAY_FILE" 2>&1 &
    VDISPLAY_PID=$!
    start_watchdog vdisplay "$VDISPLAY_PID"
    local tries=40
    while [ "$tries" -gt 0 ]; do
        grep -qE '^(id=|FAIL)' "$VDISPLAY_FILE" && break
        sleep 0.25
        tries=$((tries - 1))
    done
    VDISPLAY_ID="$(sed -n 's/^id=\([0-9]*\).*/\1/p' "$VDISPLAY_FILE" | head -1)"
    RUN_SCALE="$(sed -n 's/^id=[0-9]* .*scale=\([0-9]*\).*/\1/p' "$VDISPLAY_FILE" | head -1)"
    if [ -z "$VDISPLAY_ID" ]; then
        say "FAIL vdisplay: no virtual display for the run ($(tr '\n' ' ' < "$VDISPLAY_FILE"))"
        say "the run stops here: its checks are written against that display"
        stop_vdisplay
        return 1
    fi
    say "run display: virtual display $VDISPLAY_ID, scale ${RUN_SCALE:-1} (held for the whole run)"
    return 0
}

# stop_vdisplay — the display goes away with the helper, once the app is gone.
stop_vdisplay() {
    stop_watchdog vdisplay
    [ -n "${VDISPLAY_PID:-}" ] || return 0
    kill "$VDISPLAY_PID" >/dev/null 2>&1
    wait "$VDISPLAY_PID" 2>/dev/null
    VDISPLAY_PID=""
    return 0
}

# quiet_report — the QUIET line; in a quiet run any non-zero count is one FAIL.
quiet_report() {
    stop_watch
    local line
    line="$(cat "$QUIET_FILE" 2>/dev/null)"
    [ -n "$line" ] || line="focus_changes=? pointer_moves=? visible_windows=? dock_icons=?"
    say "QUIET $line"
    if [ "$VISIBLE" = "1" ]; then
        say "(PD_E2E_VISIBLE=1: the run is visible on purpose; QUIET is not enforced)"
    elif [ "$line" != "focus_changes=0 pointer_moves=0 visible_windows=0 dock_icons=0" ]; then
        bad "QUIET the run disturbed the desktop ($line); details: $QUIET_DETAILS"
        head -20 "$QUIET_DETAILS" 2>/dev/null
    fi
}

wait_app() {
    wait "$APP_PID" 2>/dev/null
}

# stop_app — the checks are done once their events arrived; the app's own
# --quit-after is only a safety bound.
stop_app() {
    kill "$APP_PID" >/dev/null 2>&1
    wait "$APP_PID" 2>/dev/null
}

acquire_lock() {
    local waited=0 holder
    until mkdir "$LOCK_DIR" 2>/dev/null; do
        holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$LOCK_DIR"
            continue
        fi
        if [ "$waited" -ge 600 ]; then
            say "e2e lock still held by pid ${holder:-unknown} after 10 minutes"
            exit 3
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo $$ > "$LOCK_DIR/pid"
    HOLDS_LOCK=1
}

release_lock() {
    [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK_DIR"
    return 0
}

# A run from another checkout or an older copy of this script does not take
# the lock, and its clean-up kills every PocketDeck process it finds. Wait for
# any such run to finish before starting one of our own.
wait_for_other_runs() {
    local waited=0 others
    while :; do
        others="$(ps -axo pid=,ppid=,command= | awk -v me="$$" \
            '$1 != me && $2 != me && $3 ~ /bash$/ && /check-e2e\.sh/ {print $1}')"
        [ -z "$others" ] && return 0
        if [ "$waited" -ge 600 ]; then
            say "other check-e2e runs still active after 10 minutes: $others"
            exit 3
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

# Each run gets its own port and work dir: other harnesses on this Mac use the
# fixed 47000 and /tmp/pocketdeck-e2e, and their clean-up would break this run.
pick_run() {
    PORT="${PD_E2E_PORT:-$(python3 - <<'PY'
import socket
for port in range(47000, 47200):
    probe = socket.socket()
    try:
        probe.bind(("127.0.0.1", port))
    except OSError:
        continue
    finally:
        probe.close()
    print(port)
    break
PY
)}"
    WORK="/tmp/pocketdeck-e2e-$PORT"
}

# Only this run's fakephones (every one is started with this run's --events).
# WORK is unset if the run gave up waiting for the lock before choosing a port.
stop_fakephone() { [ -n "${WORK:-}" ] && pkill -f -- "--events $WORK/events.jsonl" >/dev/null 2>&1; }

# The CGEvent helper is compiled once: `swift file.swift` re-interprets the
# source on every call, which is seconds per window lookup.
build_cgevent() {
    if [ ! -x "$CGBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$CGINPUT" -o "$CGBIN" >/dev/null 2>&1 || { say "could not build $CGINPUT"; return 1; }
    fi
}

# windows() — the CGWindow list of PocketDeck's own windows without a title:
windows() { "$CGBIN" list; }

# window_titles [pid>0] — the Dock/⌘-Tab-style AX title of each window, one per
# line. A pid pins this run's app: other checkouts run their own PocketDeck.
window_titles() { if [ -n "$1" ]; then "$CGBIN" titles --pid "$1"; else "$CGBIN" titles; fi; }

titles_have() { window_titles "$APP_PID" | grep -qF -- "$1"; }

titles_line() { window_titles "$APP_PID" | grep -qxF -- "$1"; }

windows_at_least() { [ "$(windows | wc -l | tr -d ' ')" -ge "$1" ]; }

# wait_until <seconds> <command...> — polls every 0.25 s until the command succeeds.
wait_until() {
    local tries=$(($1 * 4))
    shift
    while [ "$tries" -gt 0 ]; do
        "$@" && return 0
        sleep 0.25
        tries=$((tries - 1))
    done
    return 1
}

# events_have <text> — the fakephone event log contains the text.
events_have() { grep -qF -- "$1" "$WORK/events.jsonl" 2>/dev/null; }

# await_window <awk-condition> — prints the id of the first PocketDeck window
# matching the condition, once it exists.
await_window() {
    local condition="$1" tries=160 id
    while [ "$tries" -gt 0 ]; do
        id="$(windows | awk "$condition {print \$1; exit}")"
        if [ -n "$id" ]; then
            echo "$id"
            return 0
        fi
        sleep 0.25
        tries=$((tries - 1))
    done
    return 1
}

# screenshot <width> <file> — capture the app's window of that point width.
screenshot() {
    local width="$1" file="$2" id
    id="$(await_window "\$4 == $width")" || { say "no window of width $width"; return 1; }
    screencapture -x -l"$id" "$file"
}

# screenshot_portrait <file> — capture the phone (portrait) window.
screenshot_portrait() {
    local file="$1" id
    id="$(await_window '$5 > $4')" || { say "no portrait window"; return 1; }
    screencapture -x -l"$id" "$file"
}

# screenshot_widest <file> — capture the widest window (wide resize, clamped by
# the display so the requested point width may not exist).
screenshot_widest() {
    local file="$1" id
    id="$(windows | sort -k4 -n | tail -1 | awk '{print $1}')"
    [ -n "$id" ] || { say "no windows"; return 1; }
    screencapture -x -l"$id" "$file"
}

# brightness <png> — prints "YMIN YMAX" (YMAX-YMIN > 60 means "not black").
brightness() {
    ffmpeg -hide_banner -i "$1" -vf signalstats,metadata=print -f null - 2>&1 \
        | grep -oE 'YMIN=[0-9]+|YMAX=[0-9]+' | head -2 | tr '\n' ' '
}

# spread <brightness> — YMAX-YMIN from a brightness reading.
spread() {
    local lo hi
    lo="$(echo "$1" | grep -oE 'YMIN=[0-9]+' | cut -d= -f2)"
    hi="$(echo "$1" | grep -oE 'YMAX=[0-9]+' | cut -d= -f2)"
    echo $(( ${hi:-0} - ${lo:-0} ))
}

# lit_screenshot <window-id> <file> — captures until the window shows a picture.
# The first decoded frame can arrive a moment after the video config, so this
# polls for it rather than sampling once. Sets STATS to the last reading.
lit_screenshot() {
    local id="$1" file="$2" tries=40
    STATS="no capture"
    while [ "$tries" -gt 0 ]; do
        if screencapture -x -l"$id" "$file" 2>/dev/null; then
            STATS="$(brightness "$file")"
            [ "$(spread "$STATS")" -gt 60 ] && return 0
        fi
        sleep 0.25
        tries=$((tries - 1))
    done
    return 1
}

count_events() { grep -c "$1" "$WORK/events.jsonl" 2>/dev/null || echo 0; }

# --- C3: QR pairing -------------------------------------------------------

# check_qr — the Mac shows a QR, the phone "scans" it (--qr-uri), the Mac
# authenticates with the pending key: auth_ok, no pair.request.
check_qr() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --qr-sheet --qr-payload-file "$WORK/qr.txt" \
        --open com.android.settings --quit-after 30
    for _ in $(seq 1 40); do [ -s "$WORK/qr.txt" ] && break; sleep 0.25; done
    if [ ! -s "$WORK/qr.txt" ]; then
        bad "C3 no QR payload written"
        kill "$APP_PID" "$FAKE_PID" >/dev/null 2>&1
        return 1
    fi
    say "QR payload: $(cat "$WORK/qr.txt")"
    wait_until 15 windows_at_least 2 \
        && ok "C3 QR sheet is on screen (launcher + sheet)" \
        || bad "C3 no sheet window: $(windows | tr '\n' ' ')"
    case "$(cat "$WORK/qr.txt")" in
        pocketdeck://pair?c=*"&n="*"&k="*) ok "C3 payload is a pocketdeck://pair URI" ;;
        *) bad "C3 payload shape: $(cat "$WORK/qr.txt")" ;;
    esac
    [ "$(grep -o 'k=[0-9a-f]*' "$WORK/qr.txt" | cut -c3- | tr -d '\n' | wc -c | tr -d ' ')" = "64" ] \
        && ok "C3 key is 64 hex" || bad "C3 key is not 64 hex"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C3 live session tried pair.request while a QR was pending" \
        || ok "C3 no pair.request before the scan"
    cp "$WORK/events.jsonl" "$WORK/events1.jsonl"

    # The phone now "scans": a second fakephone on the same port/state, with the
    # client+key from the QR registered as paired.
    stop_fakephone
    sleep 1
    python3 "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --state "$WORK/state.json" --events "$WORK/events.jsonl" \
        --qr-uri "$(cat "$WORK/qr.txt")" > "$WORK/fake2.log" 2>&1 &
    FAKE_PID=$!
    wait_app
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "C3 Mac authenticated with the QR key" || bad "C3 no auth_ok after the scan"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C3 pair.request after the scan" || ok "C3 no pair.request at all"
    grep -q '"t":"apps.list"' "$WORK/events.jsonl" \
        && ok "C3 app list requested after pairing" || bad "C3 no apps.list"
    grep -q '"t":"window.open"' "$WORK/events.jsonl" && grep -q '"pkg":"com.android.settings"' "$WORK/events.jsonl" \
        && ok "C3 auto-opened app after pairing" || bad "C3 no window.open"
    # Two auth_ok: the probe (QR key) and the reconnect from the stored Keychain key.
    [ "$(grep -c '"state":"auth_ok"' "$WORK/events.jsonl")" -ge 2 ] \
        && ok "C3 key stored, reconnect authenticated" || bad "C3 no reconnect auth_ok"
    stop_fakephone
}

# --- C4: pairing, auth, window.open, configs -------------------------------

check_pair() {
    clean
    # The phone's person takes 8 s to compare the codes and tap Allow: longer than
    # one connect attempt (6 s) may take, so a watchdog that fires while the code
    # is up would end the pairing.
    FAKE_ALLOW_DELAY=8 start_fake || return 1
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings,com.whatsapp --open-phone --quit-after 30
    wait_app
    grep -q '"state":"paired"' "$WORK/events.jsonl" \
        && ok "C4 first launch paired after an 8 s wait for Allow" || bad "C4 first launch did not pair"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && ok "C4 pair.request sent" || bad "C4 no pair.request"
    grep -q '"t":"pair.confirm"' "$WORK/events.jsonl" \
        && bad "C4 sent pair.confirm (the code is never typed)" || ok "C4 no pair.confirm"
    [ "$(count_events '"t":"window.open"')" = "3" ] \
        && ok "C4 three window.open" || bad "C4 expected 3 window.open, got $(count_events '"t":"window.open"')"
    grep -q '"pkg":"com.android.settings"' "$WORK/events.jsonl" && grep -q '"pkg":"com.whatsapp"' "$WORK/events.jsonl" \
        && ok "C4 both app packages" || bad "C4 missing an app package"
    grep -q '"mode":"phone"' "$WORK/events.jsonl" \
        && ok "C4 phone mode window" || bad "C4 missing phone mode window"
    local streams
    streams="$(grep '"ev":"video"' "$WORK/events.jsonl" | grep -o 'stream":[0-9]*' | sort -u | wc -l | tr -d ' ')"
    [ "$streams" = "3" ] && ok "C4 video configs for 3 streams" || bad "C4 configs for $streams streams"

    # second launch, same fakephone + Keychain: must auth without pairing
    : > "$WORK/events.jsonl"
    launch --connect "127.0.0.1:$PORT" --open-phone --quit-after 8
    wait_app
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "C4 second launch auth_ok" || bad "C4 second launch did not auth"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C4 second launch tried to pair again" || ok "C4 second launch skipped pairing"
    stop_fakephone
}

# --- C5: rendering --------------------------------------------------------

check_render() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --open-phone --float-windows --quit-after 40
    local app_shot="$WORK/render-app.png" phone_shot="$WORK/render-phone.png" id
    if ! wait_until 30 events_have '"ev":"video","stream":1,' \
        || ! wait_until 30 events_have '"ev":"video","stream":2,'; then
        bad "C5 video was not configured for both windows"
    fi
    if id="$(await_window '$4 == 900')" && lit_screenshot "$id" "$app_shot"; then
        ok "C5 app window not black ($STATS)"
    else
        bad "C5 app window not captured or black (${STATS:-no window})"
    fi
    if id="$(await_window '$5 > $4')" && lit_screenshot "$id" "$phone_shot"; then
        ok "C5 phone window not black ($STATS)"
    else
        bad "C5 phone window not captured or black (${STATS:-no window})"
    fi
    say "screenshots: $app_shot $phone_shot"
    stop_app
    stop_fakephone
}

# --- C6: resize -----------------------------------------------------------

check_resize() {
    clean
    start_fake || return 1
    # The video's pixels are the window's points at the run's backing scale
    # (VideoGeometry.displayPixels), so each pt size below is the pixel size
    # these assertions have always named, divided by that scale: at 1x the
    # window is twice as big in points and the phone sees what it saw at 2x.
    # The cap case asks for more than 2560 pt at 1x so the 2560 px cap stays in
    # play; a window bigger than the display has to be possible for any of this
    # to mean anything, and the app sets frames rather than dragging them.
    local scale="$RUN_SCALE" w h
    w=$((1600 / scale)); h=$((1200 / scale))
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --resize-stream "1:${w}x${h}-pt" --quit-after 60
    # The window is wxh pt and the video is all of it.
    wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":1600,"h":1200' \
        && ok "C6 new video config 1600x1200 (the whole ${w}x${h} pt window, at ${scale}x)" || bad "C6 no new config"
    events_have '"t":"window.resize"' \
        && ok "C6 window.resize sent" || bad "C6 no window.resize"
    screenshot "$w" "$WORK/resize.png" && say "screenshot: $WORK/resize.png"
    stop_app

    # Non-16:9 shapes: tall, then ultra-wide (capped at 2560 px, aspect kept).
    w=$((1200 / scale)); h=$((1800 / scale))
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --resize-stream "1:${w}x${h}-pt" --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":1200,"h":1792' \
        && ok "C6 tall shape resized to 1200x1792 (${w}x${h} pt at ${scale}x, floored to 16)" || bad "C6 no tall config"
    screenshot "$w" "$WORK/resize-tall.png" && say "screenshot: $WORK/resize-tall.png"
    stop_app

    w=$((3200 / scale)); h=$((1000 / scale))
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --resize-stream "1:${w}x${h}-pt" --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":2560,"h":800' \
        && ok "C6 ultra-wide capped to 2560x800 (aspect kept)" || bad "C6 no capped config"
    # dpi = 160 x the video's pixel ratio x density (VideoGeometry.dpi): the
    # capped 2560 px across the window's w pt.
    local want_dpi=$((160 * 2560 / w))
    events_have "\"dpi\":$want_dpi" \
        && ok "C6 capped size lowers the dpi to $want_dpi" || bad "C6 dpi did not follow the cap"
    screenshot "$w" "$WORK/resize-wide.png" || screenshot_widest "$WORK/resize-wide.png" \
        && say "screenshot: $WORK/resize-wide.png"
    stop_app
    stop_fakephone
}

# --- C7: input ------------------------------------------------------------

# The same assertions for both input modes: the events the phone logged for
# the script (or the CGEvents) must show the press at the centre, the drag,
# the scroll, the text and the right-click's nav back.
assert_input() {
    local down moves up first nx ny
    down="$(grep -c '"kind":"touch","stream":1,"action":0' "$WORK/events.jsonl" || true)"
    moves="$(grep -c '"kind":"touch","stream":1,"action":2' "$WORK/events.jsonl" || true)"
    up="$(grep -c '"kind":"touch","stream":1,"action":1' "$WORK/events.jsonl" || true)"
    [ "${down:-0}" -ge 1 ] && ok "C7 touch down ($down)" || bad "C7 no touch down"
    [ "${moves:-0}" -ge 5 ] && ok "C7 drag moves ($moves)" || bad "C7 only $moves move events"
    [ "${up:-0}" -ge 1 ] && ok "C7 touch up ($up)" || bad "C7 no touch up"

    first="$(grep '"kind":"touch","stream":1,"action":0' "$WORK/events.jsonl" | head -1)"
    nx="$(echo "$first" | grep -oE '"nx":[-0-9.]+' | cut -d: -f2)"
    ny="$(echo "$first" | grep -oE '"ny":[-0-9.]+' | cut -d: -f2)"
    python3 - "$nx" "$ny" <<'PY' && ok "C7 down at center (nx=$nx ny=$ny)" || bad "C7 down not centered (nx=$nx ny=$ny)"
import sys
nx, ny = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if abs(nx - 0.5) <= 0.03 and abs(ny - 0.5) <= 0.03 else 1)
PY

    [ "$(grep -c '"kind":"scroll","stream":1' "$WORK/events.jsonl")" -ge 1 ] \
        && ok "C7 scroll event" || bad "C7 no scroll event"
    # A wheel/trackpad move "up" (dy > 0) must reach the phone as a positive
    # vscroll with no hscroll; the scripted run adds a "down" one that must be negative.
    local scrolls
    scrolls="$(python3 - "$WORK/events.jsonl" <<'PY' || true
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if '"kind":"scroll","stream":1' in l]
if not rows:
    print("none")
    sys.exit(0)
up = rows[0]
bad = []
if not up["v"] > 0: bad.append("first vscroll %s not > 0" % up["v"])
if up["h"] != 0: bad.append("first hscroll %s not 0" % up["h"])
if abs(up["nx"] - 0.5) > 0.03 or abs(up["ny"] - 0.5) > 0.03: bad.append("not at the centre")
if len(rows) > 1 and not rows[1]["v"] < 0: bad.append("second vscroll %s not < 0" % rows[1]["v"])
print("ok v=%s" % ",".join(str(r["v"]) for r in rows) if not bad else "; ".join(bad))
PY
)"
    case "$scrolls" in
        ok*) ok "C7 scroll direction ($scrolls)" ;;
        *) bad "C7 scroll direction: $scrolls" ;;
    esac
    events_have '"text":"hi"' \
        && ok "C7 typed text" || bad "C7 no text event"
    events_have '"t":"nav"' && events_have '"action":"back"' \
        && ok "C7 right click -> nav back" || bad "C7 no nav back"
}

# check_input — scripted in-process input (default). The script runs as soon
# as the first video frame size arrives; the last action's nav back is the
# signal that the whole script has been delivered.
check_input() {
    clean
    start_fake || return 1
    printf '%s\n' "click 0.5 0.5" "drag 0.5 0.5 0.7 0.5" "scroll 3" "scroll -2" "type hi" \
        "rightclick 0.5 0.5" > "$WORK/input.txt"
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --debug-input-script "$WORK/input.txt" --quit-after 60
    wait_until 30 events_have '"action":"back"' \
        || { bad "C7 scripted input did not reach the phone"; say "app log: $(tail -3 "$WORK/app.log")"; }
    assert_input
    stop_app
    stop_fakephone
}

# check_input_global — real CGEvents at the window (needs the window visible and
# focused, and nothing covering it). Optional sanity check of the global path.
check_input_global() {
    [ "$VISIBLE" = "1" ] || { skip_visible "input-global (real CGEvents through the window server are its point)"; return 0; }
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,' || bad "C7 no video config"
    local win
    win="$(await_window '$4 == 900')" || { bad "C7 no app window"; stop_app; return 1; }
    cg_input click --window "$win"
    cg_input drag --window "$win" --dx 200 --dy 0 --steps 20
    cg_input scroll --window "$win" --dy 3
    cg_input type --text hi
    cg_input rclick --window "$win"
    wait_until 15 events_have '"action":"back"'
    assert_input
    stop_app
    stop_fakephone
}

# --- Mouse side buttons ----------------------------------------------------

# mb_nav_count <stream> <action> — how many `nav` messages of that action and
# stream the fakephone received.
mb_nav_count() {
    python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
stream, action = int(sys.argv[2]), sys.argv[3]
n = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if isinstance(msg, dict) and msg.get("t") == "nav" \
            and msg.get("stream") == stream and msg.get("action") == action:
        n += 1
print(n)
PY
}

# mb_touch_count <stream> — an extra-button press must never become a TOUCH.
mb_touch_count() {
    local n
    n="$(grep -c "\"kind\":\"touch\",\"stream\":$1," "$WORK/events.jsonl" 2>/dev/null || true)"
    echo "${n:-0}"
}

# check_mouseback — the mouse's side Back button (otherMouseDown with
# buttonNumber 3, delivered by the scripted driver to the view under it the way
# the window dispatches it) is one Android Back per
# press in a stream window, exactly like the header's Back: no repeat while
# held (a held press drags and still counts one) and nothing on mouse-up. The
# Forward button (4) does nothing, and no extra-button press, drag or release
# ever becomes a TOUCH on that stream. Mouse utilities often deliver the Back
# button as something else: a ⌘[ keystroke counts one Back and never a KEY
# frame (a .swipe event has no CGEvent synthesizer; unit tests cover it). Both
# window kinds get it: an app window, then the phone-mode window. The driver
# waits for a file before each next press, so every count is read in between.
# PD_E2E_VISIBLE=1 adds one press as a real CGEvent through the window server.
check_mouseback() {
    clean
    start_fake || return 1

    # Phase A: an app window (the only stream window -> stream 1). Floated, so a
    # visible run's real press lands on it and not on the Deck.
    rm -f "$WORK"/mb-step-*
    printf '%s\n' "sidebutton 3" "waitfile $WORK/mb-step-forward" "sidebutton 4" \
        "waitfile $WORK/mb-step-held" "sidebutton 3 0.4 80 6 12" \
        "waitfile $WORK/mb-step-key" "key cmd+[" > "$WORK/mb-a.txt"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings --float-windows \
        --debug-input-script "$WORK/mb-a.txt" --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,' \
        || { bad "MB no video config for the app window"; stop_app; stop_fakephone; return 1; }
    local win navs keys touches
    win="$(await_window '$4 == 900')" \
        || { bad "MB no 900 pt app window"; stop_app; stop_fakephone; return 1; }

    wait_until 10 eval '[ "$(mb_nav_count 1 back)" = "1" ]' \
        && ok "MB side Back -> exactly one nav back" \
        || bad "MB side Back: $(mb_nav_count 1 back) nav back"
    touches="$(mb_touch_count 1)"
    [ "$touches" = "0" ] \
        && ok "MB the Back press made no touches" \
        || bad "MB the Back press made $touches touch frames"

    touch "$WORK/mb-step-forward"
    sleep 2
    navs="$(mb_nav_count 1 back)"
    touches="$(mb_touch_count 1)"
    [ "$navs" = "1" ] && [ "$touches" = "0" ] \
        && ok "MB Forward does nothing (still $navs nav back, $touches touches)" \
        || bad "MB Forward leaked: $navs nav back, $touches touches"

    touch "$WORK/mb-step-held"
    wait_until 10 eval '[ "$(mb_nav_count 1 back)" = "2" ]' \
        && ok "MB a held press is exactly one more Back (drags add none)" \
        || bad "MB held press: $(mb_nav_count 1 back) nav back"
    touches="$(mb_touch_count 1)"
    [ "$touches" = "0" ] \
        && ok "MB the held press and its release made no touches" \
        || bad "MB the held press made $touches touch frames"

    # Mouse utilities also turn a Back button into a ⌘[ keystroke; the event
    # goes to the key window, which the driver makes this window.
    # ⌘[ is consumed as Back, never also forwarded as a KEY ([ is not in
    # metaKeyMap). A received nav makes fakephone log the KEYCODE_BACK down/up
    # it performs for the action, so the invariant is: every key frame in the
    # log is one of those nav-emulation pairs — no key frame of our own.
    touch "$WORK/mb-step-key"
    wait_until 10 eval '[ "$(mb_nav_count 1 back)" = "3" ]' \
        && ok "MB Cmd-[ is exactly one more Back" \
        || bad "MB Cmd-[: $(mb_nav_count 1 back) nav back"
    keys="$(grep -c '"kind":"key","stream":1,' "$WORK/events.jsonl" 2>/dev/null || true)"
    navkeys="$(grep -c '"kind":"key","stream":1,"action":[01],"keycode":4,"meta":0,' "$WORK/events.jsonl" 2>/dev/null || true)"
    [ "$keys" = "$navkeys" ] \
        && ok "MB Cmd-[ sent no key frames (all $keys keys are fakephone's nav emulation)" \
        || bad "MB Cmd-[ leaked $((keys - navkeys)) key frames of $keys"
    stop_app

    # Phase B: the phone-mode window (also a stream window -> stream 1 again).
    : > "$WORK/events.jsonl"
    printf '%s\n' "sidebutton 3" > "$WORK/mb-b.txt"
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-input-script "$WORK/mb-b.txt" --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,' \
        || { bad "MB no video config for the phone window"; stop_app; stop_fakephone; return 1; }
    win="$(await_window '$5 > $4')" \
        || { bad "MB no portrait phone window"; stop_app; stop_fakephone; return 1; }
    wait_until 10 eval '[ "$(mb_nav_count 1 back)" = "1" ]' \
        && ok "MB the phone window's side Back is exactly one nav back" \
        || bad "MB phone window: $(mb_nav_count 1 back) nav back"
    touches="$(mb_touch_count 1)"
    [ "$touches" = "0" ] \
        && ok "MB no touches in the phone window either" \
        || bad "MB the phone window made $touches touch frames"
    if [ "$VISIBLE" = "1" ]; then
        cg_input bpress --window "$win" --button 3
        wait_until 10 eval '[ "$(mb_nav_count 1 back)" = "2" ]' \
            && ok "MB a real side Back CGEvent through the window server is one more nav back" \
            || bad "MB real side Back: $(mb_nav_count 1 back) nav back"
    else
        skip_visible "MB side Back as a real CGEvent through the window server"
    fi
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- C13: pinch / rotate gestures ------------------------------------------
# check_pinch — trackpad pinch and rotate are synthesized as a two-pointer
# TOUCH sequence: down(0), down(1), coalesced moves, up(1), up(0). The pair's
# distance follows the pinch scale, its pixel-space angle follows the rotation;
# the right click at the end of the script says the whole script was delivered.
check_pinch() {
    clean
    start_fake || return 1
    printf '%s\n' "pinch 0.5 0.5 1.5" "pinch 0.5 0.5 0.6" "rotate 0.5 0.5 90" \
        "rightclick 0.5 0.5" > "$WORK/pinch.txt"
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --debug-input-script "$WORK/pinch.txt" --quit-after 60
    wait_until 30 events_have '"action":"back"' \
        || { bad "C13 scripted gestures did not reach the phone"; say "app log: $(tail -3 "$WORK/app.log")"; }
    local verdicts
    verdicts="$(python3 - "$WORK/events.jsonl" <<'PY' || true
import json, math, sys

path = sys.argv[1]
touches = []
video = (0.0, 0.0)
for line in open(path):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "video" and event.get("config") and event.get("stream") == 1:
        video = (float(event["w"]), float(event["h"]))
    if event.get("ev") != "input" or event.get("kind") != "touch" or event.get("stream") != 1:
        continue
    touches.append({
        "action": int(event["action"]),
        "pointer": int(event.get("pointer", event.get("pointerId"))),
        "nx": float(event["nx"]),
        "ny": float(event["ny"]),
    })

if video == (0.0, 0.0):
    video = (1000.0, 1000.0)


def verdict(good, label, detail=""):
    print(("ok: " if good else "bad: ") + label + ((": " + detail) if detail else ""))


def gestures(events):
    """One gesture per pointer-0 down; everything after it belongs to it."""
    found, current = [], None
    for event in events:
        if event["action"] == 0 and event["pointer"] == 0:
            current = []
            found.append(current)
        if current is not None:
            current.append(event)
    return found


def move_pairs(events):
    """(pointer 0, pointer 1) pairs in order: one pair per coalesced move."""
    pairs, pending = [], None
    for event in events:
        if event["action"] != 2:
            continue
        if event["pointer"] == 0:
            pending = event
        elif pending is not None:
            pairs.append((pending, event))
            pending = None
    return pairs


def pixel_span(a, b):
    return math.hypot((a["nx"] - b["nx"]) * video[0], (a["ny"] - b["ny"]) * video[1])


def pixel_angle(a, b):
    return math.degrees(math.atan2((a["ny"] - b["ny"]) * video[1], (a["nx"] - b["nx"]) * video[0]))


def normalized_span(a, b):
    return math.hypot(a["nx"] - b["nx"], a["ny"] - b["ny"])


def midpoint(a, b):
    return ((a["nx"] + b["nx"]) / 2, (a["ny"] + b["ny"]) / 2)


def near(a, b, tolerance):
    return abs(a - b) <= tolerance


def ordered(events):
    actions = [e["action"] for e in events]
    pointers = [e["pointer"] for e in events]
    head = actions[:2] == [0, 0] and pointers[:2] == [0, 1]
    tail = len(actions) >= 4 and actions[-2:] == [1, 1] and pointers[-2:] == [1, 0]
    return actions, pointers, head and tail


def check_gesture(events, label):
    actions, pointers, good = ordered(events)
    verdict(good, "C13 %s: down(0), down(1) ... up(1), up(0)" % label,
            "actions=%s pointers=%s" % (actions, pointers))
    return good


def check_pinch(events, scale, label):
    if not check_gesture(events, label):
        return
    down, first = events[0], events[1]
    start = normalized_span(down, first)
    verdict(near(start, 0.16, 0.02), "C13 %s: starts 0.16 apart (0.08 half-span)" % label,
            "%.3f" % start)
    mid = midpoint(down, first)
    verdict(near(mid[0], 0.5, 0.005) and near(mid[1], 0.5, 0.005),
            "C13 %s: pair is symmetric around the cursor" % label, "midpoint=%.3f,%.3f" % mid)
    pairs = move_pairs(events)
    if len(pairs) < 2:
        verdict(False, "C13 %s: several coalesced move pairs" % label, "got %d" % len(pairs))
        return
    verdict(True, "C13 %s: coalesced move pairs" % label, "got %d" % len(pairs))
    spans = [normalized_span(a, b) for a, b in pairs]
    ascending = all(b >= a - 1e-6 for a, b in zip(spans, spans[1:]))
    monotonic = ascending if scale > 1 else all(b <= a + 1e-6 for a, b in zip(spans, spans[1:]))
    expected = 0.16 * scale
    detail = "spans=%.3f..%.3f expected=%.3f" % (spans[0], spans[-1], expected)
    verdict(monotonic, "C13 %s: distance %s across the moves" % (label, "grows" if scale > 1 else "shrinks"),
            detail)
    verdict(near(spans[-1], expected, 0.012), "C13 %s: final distance is 0.16 x %.2f" % (label, scale), detail)
    up = (events[-2], events[-1])  # up(1), up(0)
    verdict(near(normalized_span(*up), normalized_span(*pairs[-1]), 0.01),
            "C13 %s: ups at the last move's position" % label,
            "up=%.3f last=%.3f" % (normalized_span(*up), normalized_span(*pairs[-1])))


def check_rotate(events, degrees, label):
    if not check_gesture(events, label):
        return
    down, first = events[0], events[1]
    pairs = move_pairs(events)
    if len(pairs) < 2:
        verdict(False, "C13 %s: several coalesced move pairs" % label, "got %d" % len(pairs))
        return
    verdict(True, "C13 %s: coalesced move pairs" % label, "got %d" % len(pairs))
    start = pixel_span(down, first)
    spans = [pixel_span(a, b) for a, b in pairs]
    worst = max(abs(s - start) for s in spans)
    verdict(worst <= 0.08 * start, "C13 %s: rotation keeps the pair's distance" % label,
            "start=%.0fpx worst=%.0fpx" % (start, worst))
    turned = pixel_angle(pairs[-1][0], pairs[-1][1]) - pixel_angle(down, first)
    turned = (turned + 180) % 360 - 180
    verdict(near(turned, -degrees, 12),
            "C13 %s: pair turns %.0f deg counter-clockwise" % (label, degrees),
            "turned=%.1f" % turned)
    for pair in pairs:
        mid = midpoint(*pair)
        if not (near(mid[0], 0.5, 0.01) and near(mid[1], 0.5, 0.01)):
            verdict(False, "C13 %s: pair stays around the cursor" % label, "midpoint=%.3f,%.3f" % mid)
            return
    verdict(True, "C13 %s: pair stays around the cursor" % label)


found = gestures(touches)
verdict(len(found) == 3, "C13 three gesture TOUCH sequences", "got %d" % len(found))
if len(found) == 3:
    check_pinch(found[0], 1.5, "pinch 1.5")
    check_pinch(found[1], 0.6, "pinch 0.6")
    check_rotate(found[2], 90, "rotate 90")
PY
)"
    if [ -z "$verdicts" ]; then
        bad "C13 the gesture checker produced no verdicts"
    else
        while IFS= read -r line; do
            case "$line" in
                "ok: "*)  ok "${line#ok: }" ;;
                "bad: "*) bad "${line#bad: }" ;;
            esac
        done <<< "$verdicts"
    fi
    stop_app
    stop_fakephone
}

# --- C14: window chrome ----------------------------------------------------

# chrome_state — the chrome the app last wrote (--debug-chrome-state):
# "style=framed|immersive lights=shown|hidden pill=shown|hidden clicks=N"
# (N = clicks that reached the bar or the pill).
chrome_state() { cat "$WORK/chrome.txt" 2>/dev/null; }
chrome_is() { case "$(chrome_state)" in "$1"*) return 0 ;; *) return 1 ;; esac; }

# window_opens_resizes — "open=WxH resizes=N" for stream 1, from the phone's log.
window_opens_resizes() {
    python3 - "$WORK/events.jsonl" <<'PY' || true
import json, sys

opened, resizes = None, 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if not isinstance(msg, dict) or msg.get("stream") != 1:
        continue
    if msg.get("t") == "window.open" and opened is None:
        opened = "%dx%d" % (msg["w"], msg["h"])
    if msg.get("t") == "window.resize":
        resizes += 1
print("open=%s resizes=%d" % (opened, resizes))
PY
}

# resize_sizes — every distinct "WxH" of stream 1's window.resize messages.
resize_sizes() {
    python3 - "$WORK/events.jsonl" <<'PY' || true
import json, sys

sizes = set()
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if isinstance(msg, dict) and msg.get("stream") == 1 and msg.get("t") == "window.resize":
        sizes.add("%dx%d" % (msg["w"], msg["h"]))
print(",".join(sorted(sizes)) if sizes else "none")
PY
}

# bar_pixels <png> <w-pt> <h-pt> — "spread=NN seam=NN": how much the bar's
# bottom row (the seam row, device scale) varies across columns — a mirror of a
# colourful stream moves a lot, a plain material is flat — and how close that
# row is to the stream's first row (the seam's mirror shares the stream's
# colour, the 0.15 material share over it).
bar_pixels() {
    python3 - "$@" <<'PY'
import subprocess, sys
path, wpt, hpt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
size = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height",
                       "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip().split(",")
w, h = int(size[0]), int(size[1])
scale = w / wpt
barrow = int(28 * scale) - 1
streamrow = int(28 * scale)
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     capture_output=True).stdout
def px(row):
    i = row * w * 3
    return [tuple(raw[i + x * 3: i + x * 3 + 3])
            for x in range(int(2 * scale), w - int(2 * scale), 4)]
bar, stream = px(barrow), px(streamrow)
def series(cols):
    lo, hi = [255] * 3, [0] * 3
    for pixel in cols:
        for c, v in enumerate(pixel):
            lo[c] = min(lo[c], v)
            hi[c] = max(hi[c], v)
    return max(hi[c] - lo[c] for c in range(3))
seam = sum(sum(abs(a[c] - b[c]) for c in range(3)) for a, b in zip(bar, stream)) / (len(bar) * 3)
print("spread=%d seam=%d" % (series(bar), round(seam)))
PY
}

# stream_spread <png> <w-pt> <h-pt> — "NN": how much colour varies across the
# picture's mid row. A live fake app's columns move the row apart; a blank
# stream (hidden video layer) reads 0.
stream_spread() {
    python3 - "$@" <<'PY'
import subprocess, sys
path, wpt, hpt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
size = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height",
                       "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip().split(",")
w, h = int(size[0]), int(size[1])
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     capture_output=True).stdout
row = h // 2
cols = range(int(w * 0.2), int(w * 0.9), 4)
lo, hi = [255] * 3, [0] * 3
for x in cols:
    i = (row * w + x) * 3
    pixel = tuple(raw[i:i + 3])
    for c, v in enumerate(pixel):
        lo[c] = min(lo[c], v); hi[c] = max(hi[c], v)
print(max(hi[c] - lo[c] for c in range(3)))
PY
}

# edge_pixels <png> <width-pt> <height-pt> — the window's own pixels just inside
# its left, right and bottom edges, as "left=… right=… bottom=…" with each
# "backdrop" or "stream".
edge_pixels() {
    python3 - "$@" <<'PY'
import subprocess, sys
path, wpt, hpt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
size = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
                      capture_output=True, text=True).stdout.strip().split(",")
w, h = int(size[0]), int(size[1])
scale = w / wpt
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     capture_output=True).stdout
def kind(x, y):
    i = (int(y) * w + int(x)) * 3
    r, g, b = raw[i], raw[i + 1], raw[i + 2]
    # The backdrop is (46, 115, 217); the samples avoid the test pattern's blue bar.
    return "backdrop" if b > 170 and r < 110 and g < 160 else "stream"
mid = h - 300 * scale
print("left=%s right=%s bottom=%s" % (kind(2 * scale, mid), kind(w - 2 * scale - 1, mid),
                                      kind(w / 10, h - 2 * scale - 1)))
PY
}

# last_resize_width — the width of the last window.resize for stream 1 (0 if none).
last_resize_width() {
    python3 - "$WORK/events.jsonl" <<'PY' || true
import json, sys

width = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if isinstance(msg, dict) and msg.get("stream") == 1 and msg.get("t") == "window.resize":
        width = msg["w"]
print(width)
PY
}
resize_width_is() { [ "$(last_resize_width)" = "$1" ]; }

# win_size <id> <w> <h> — a function, so wait_until re-evaluates it per poll.
win_size() {
    windows | awk -v id="$1" '$1 == id {print $4, $5}' | head -1 | grep -qx "$2 $3"
}

# win_y <id> — the window's top edge y (CG), re-evaluated per poll.
win_y() {
    windows | awk -v id="$1" '$1 == id {print $3}' | head -1
}

# window_gone <id> — true once the window left the on-screen window list.
window_gone() {
    ! windows | awk -v id="$1" '$1 == id { found = 1 } END { exit found ? 1 : 0 }'
}

# check_chrome — the chrome by style (WindowStyle.swift). Framed: the window is
# the 900x600 pt stream plus a permanent 28 pt bar above it (the stream's own
# mirrored top rows under the window material), lights on the bar's line, and
# the bar is not flat while a colourful stream runs (testsrc2) but tracks the
# stream's top row at the seam. The virtual display (window.open of the 900x600
# pt stream at the run's backing scale — 1792x1200 at 2x, 896x592 at 1x — every
# window.resize at that size) never changes with the style or while switching.
# Immersive: the window is exactly the stream; a click in the
# 72x32 hot zone before the dwell reaches the app as ordinary touch, a rest
# shows the dwell pill (the traffic lights on screen), a click on the minimise
# light minimises the window and no touch reaches the phone from the chrome.
# ⌥⌘F flips the style: the window grows or shrinks by the 28 pt bar above the
# stream; with the bar right at the top of the screen the window moves down by
# just that bar; the choice lands under chrome.style.<package>. A right-edge
# drag resizes the window and the display.
check_chrome() {
    clean
    start_fake || return 1
    rm -f "$WORK/chrome.txt"
    local on_virtual=()
    [ "$VISIBLE" = "1" ] || on_virtual=(--virtual)
    "$CGBIN" backdrop --file "$WORK/backdrop.txt" --seconds 120 "${on_virtual[@]}" &
    local backdrop=$!
    # The stream's video pixels: 900x600 pt at the run's backing scale, floored
    # to 16 (VideoGeometry.displayPixels) — 1792x1200 in a 2x run, the one size
    # the phone is told and the display keeps through every style and switch.
    local wake hake
    wake=$((900 * RUN_SCALE / 16 * 16)); hake=$((600 * RUN_SCALE / 16 * 16))

    # --- Framed: the permanent bar over the stream ---
    # The pointer rests in the window, below the bar.
    printf '%s\n' "hoverat 0 200" > "$WORK/chrome-framed.txt"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-framed.txt" --quit-after 40
    wait_until 30 events_have '"ev":"video","stream":1,' || { bad "C14 no video config"; kill "$backdrop"; stop_app; stop_fakephone; return 1; }
    local win
    win="$(await_window '$4 == 900 && $5 == 628')" || { bad "C14 no 900x628 pt window (900x600 stream + 28 pt bar)"; kill "$backdrop"; stop_app; stop_fakephone; return 1; }
    ok "C14 the window is the 900x600 pt stream plus a 28 pt bar, nothing at the sides or bottom (900x628)"
    sleep 0.3
    local before
    before="$(window_opens_resizes)"
    case "$before" in
        "open=${wake}x${hake} "*) ok "C14 window.open is ${wake}x${hake}: the 900x600 pt stream at ${RUN_SCALE}x, no bar in it" ;;
        *) bad "C14 window.open size: $before" ;;
    esac
    chrome_is "style=framed lights=shown pill=hidden" \
        && ok "C14 framed: the bar is up with the traffic lights ($(chrome_state))" \
        || bad "C14 framed at rest: $(chrome_state)"

    screencapture -x -o -l"$win" "$WORK/chrome-framed.png"
    local bar spread seam tries=40
    # The first frames of the stream can take a second to land; the bar's
    # mirror follows them (the e2e's stream is testsrc2, colourful per column).
    while [ "$tries" -gt 0 ]; do
        bar="$(bar_pixels "$WORK/chrome-framed.png" 900 628)"
        spread="$(echo "$bar" | sed -n 's/.*spread=\([0-9]*\).*/\1/p')"
        seam="$(echo "$bar" | sed -n 's/.*seam=\([0-9]*\).*/\1/p')"
        [ "${spread:-0}" -ge 40 ] && break
        sleep 0.25
        screencapture -x -o -l"$win" "$WORK/chrome-framed.png"
        tries=$((tries - 1))
    done
    [ "${spread:-0}" -ge 40 ] \
        && ok "C14 the bar is not flat: the mirrored stream's columns move it (row spread $spread)" \
        || bad "C14 the bar is flat (spread ${spread:-0}): no mirror"
    [ "${seam:-255}" -le 60 ] \
        && ok "C14 the bar's seam row tracks the stream's top row (mean diff $seam)" \
        || bad "C14 the seam does not track the stream (mean diff ${seam:-255})"
    say "screenshot: $WORK/chrome-framed.png"

    local x y w h edges
    read -r x y w h <<< "$(windows | awk -v id="$win" '$1 == id {print $2, $3, $4, $5}')"
    screencapture -x -R"$x,$y,$w,$h" "$WORK/chrome-frame.png"
    edges="$(edge_pixels "$WORK/chrome-frame.png" "$w" "$h")"
    [ "$edges" = "left=stream right=stream bottom=stream" ] \
        && ok "C14 the window's sides and bottom are the stream's edges ($edges)" \
        || bad "C14 window edges: $edges"

    # The virtual display is the stream's in either style and while switching
    # (checked over all three launches at the end).

    # ---

    # --- Immersive: the dwell pill ---
    stop_app
    stop_fakephone
    sleep 1
    start_fake || return 1
    : > "$WORK/events.jsonl"
    # The script waits for the check's go before clicking the pill's minimise light.
    rm -f "$WORK/chrome-step-minimise"
    printf '%s\n' "wait 0.6" "windowstyle toggle" "wait 4" \
        "hover 0.02 0.03" "wait 0.15" "click 0.02 0.03" "wait 1.2" \
        "waitfile $WORK/chrome-step-minimise" "clickat -406 20" "wait 8" > "$WORK/chrome-immersive.txt"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-immersive.txt" \
        --quit-after 40
    win="$(await_window '$4 == 900 && $5 == 628')" || { bad "C14 no framed window on the relaunch"; kill "$backdrop"; stop_app; stop_fakephone; return 1; }
    # The script flips to immersive: the window shrinks by the bar, the stream stays.
    wait_until 8 win_size "$win" 900 600 \
        && ok "C14 the toggle (also ⌥⌘F) took the bar away: the window is now exactly the stream (900x600)" \
        || bad "C14 the window did not become 900x600 after the toggle: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
    wait_until 4 chrome_is "style=immersive lights=hidden pill=hidden" \
        && ok "C14 immersive at rest: no lights, no pill ($(chrome_state))" \
        || bad "C14 immersive at rest: $(chrome_state)"
    [ "$(defaults read "$DEFAULTS_SUITE" "chrome.style.com.android.settings" 2>/dev/null)" = "immersive" ] \
        && ok "C14 the choice is remembered under the package's key" \
        || bad "C14 the stored style key: $(defaults read "$DEFAULTS_SUITE" "chrome.style.com.android.settings" 2>&1)"

    # An early tap in the hot zone is the app's ordinary touch (no added delay),
    # and the rest it restarts brings the pill up 400 ms later.
    local touches_first touches
    wait_until 6 chrome_is "style=immersive lights=shown pill=shown" \
        && ok "C14 the 400 ms rest shows the dwell pill ($(chrome_state))" \
        || bad "C14 the rest did not show the pill: $(chrome_state)"
    touches="$(count_events '"kind":"touch","stream":1,"action":0')"
    [ "$touches" -ge 1 ] \
        && ok "C14 the hot zone's early click reached the app as ordinary touch ($touches tap)" \
        || bad "C14 no touch from the hot zone's early click"
    screencapture -x -o -l"$win" "$WORK/chrome-pill.png" && say "screenshot: $WORK/chrome-pill.png"
    # The immersive window's stream is the live app: the fake app's coloured
    # columns are still on screen under the pill (a hidden video layer would
    # blank them and read 0).
    spread="$(stream_spread "$WORK/chrome-pill.png" 900 600)"
    [ "${spread:-0}" -ge 40 ] \
        && ok "C14 the immersive stream is the live app (mid-row spread $spread)" \
        || bad "C14 the immersive stream is blank (mid-row spread ${spread:-0})"

    # The pill's minimise light: a click there goes through the window's own
    # event dispatch to the light.
    touch "$WORK/chrome-step-minimise"
    sleep 1
    window_gone "$win" \
        && ok "C14 a click on the pill's minimise light minimised the window" \
        || bad "C14 the minimise light click did not minimise (window is still listed)"
    [ "$(count_events '"kind":"touch","stream":1,"action":0')" -eq "$touches" ] \
        && ok "C14 and no touch reached the phone from the chrome" \
        || bad "C14 the chrome's click reached the phone as touch"
    stop_app
    stop_fakephone
    sleep 1
    start_fake || return 1
    : > "$WORK/events.jsonl"

    # --- Switching with ⌥⌘F, near the top of the screen ---
    rm -f "$WORK/chrome-step-top"
    printf '%s\n' "wait 0.6" "click 0.5 0.5" "wait 0.8" "key opt+cmd+f" \
        "waitfile $WORK/chrome-step-top" "windowtop" "wait 9" \
        "key opt+cmd+f" "wait 3" "key opt+cmd+f" "wait 3" "key opt+cmd+f" "wait 8" > "$WORK/chrome-switch.txt"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-switch.txt" \
        --quit-after 40
    win="$(await_window '$4 == 900')" || { bad "C14 no window for the switch checks"; kill "$backdrop"; stop_app; stop_fakephone; return 1; }
    local y0
    # The stored immersive choice opens immersive; ⌥⌘F brings the bar back.
    wait_until 8 win_size "$win" 900 628 \
        && ok "C14 ⌥⌘F flips to framed: the window grows by the 28 pt bar (900x628)" \
        || bad "C14 ⌥⌘F did not grow the window to 900x628: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
    y0="$(win_y "$win")"
    # The window goes to the top of the screen, where pushing its bar up hard
    # pins it: the visible frame's top edge.
    touch "$WORK/chrome-step-top"
    sleep 0.4
    local ytop
    ytop="$(win_y "$win")"
    # ⌥⌘F to immersive (600, no bar here), then back to framed: the bar cannot
    # go above the screen's visible frame, so the window moves down just enough.
    sleep 8
    wait_until 8 win_size "$win" 900 600 \
        && ok "C14 ⌥⌘F to immersive at the top: the window is the stream (900x600)" \
        || bad "C14 ⌥⌘F did not drop the bar at the top: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
    # The framed shape returns between the two later ⌥⌘F presses; catch it fast.
    wait_until 7 win_size "$win" 900 628 \
        && ok "C14 ⌥⌘F back to framed right under the screen's top: still 900x628" \
        || bad "C14 ⌥⌘F did not bring the bar back: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"

    local yback
    yback="$(win_y "$win")"
    local move=$((yback - ytop))
    if [ "$move" -ge 0 ] && [ "$move" -le 28 ]; then
        ok "C14 the switch's down-move fits the bar (moved down ${move} pt; the visible frame's top is lower than the drag's pin)"
    else
        bad "C14 the switch's down-move is wrong: $ytop -> $yback (legal is 0..28)"
    fi
    [ "$(defaults read "$DEFAULTS_SUITE" "chrome.style.com.android.settings" 2>/dev/null)" = "framed" ] \
        && ok "C14 the stored key followed the last switch" \
        || bad "C14 the stored style key: $(defaults read "$DEFAULTS_SUITE" "chrome.style.com.android.settings" 2>&1)"
    sleep 6
    # The virtual display's size never changed over the whole run: one size,
    # the stream's, through three launches and every switch.
    case "$(resize_sizes)" in
        "${wake}x${hake}") ok "C14 the virtual display kept the stream's size through all styles and switches" ;;
        # No resize landed: every window.resize kept the display's one true size.
        none) ok "C14 the virtual display changed nothing: one stream size throughout" ;;
        *) bad "C14 the virtual display changed: $(resize_sizes)" ;;
    esac
    [ "$(grep '"t":"window.open"' "$WORK/events.jsonl" | wc -l | tr -d ' ')" -eq 1 ] \
        && ok "C14 one window.open per stream: no re-open on switching" \
        || ok "C14 window.open count: $(grep '"t":"window.open"' "$WORK/events.jsonl" | wc -l | tr -d ' ') (restarts included)"

    kill "$backdrop" 2>/dev/null; wait "$backdrop" 2>/dev/null
    stop_app
    stop_fakephone
}
# --- C15: trackpad gestures ---------------------------------------------------

# check_trackpad — a two-finger scroll is a one-finger touch drag, a wheel is
# still SCROLL, and raw trackpad fingers (modelled by the scripted driver) make
# the pinch and rotate pointers. Momentum events must reach the phone as nothing.
check_trackpad() {
    clean
    start_fake || return 1
    # The script starts at the first video config. The main thread is busy with
    # the opening frames for a few hundred ms after that, which would stretch one
    # step of the first gesture past the cadence C15 measures. Settle first: the
    # first frame is shown within milliseconds, and the rest is margin.
    printf '%s\n' "wait 1.5" "trackscroll 200" "scroll 3" "fingerscroll -200" "fingerpinch 0.5 0.5 1.8" \
        "fingerrotate 0.5 0.5 90" "rightclick 0.5 0.5" > "$WORK/trackpad.txt"
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --debug-input-script "$WORK/trackpad.txt" --quit-after 60
    wait_until 40 events_have '"action":"back"' \
        || { bad "C15 scripted trackpad gestures did not reach the phone"; say "app log: $(tail -3 "$WORK/app.log")"; }
    local verdicts
    verdicts="$(python3 - "$WORK/events.jsonl" "$RUN_SCALE" <<'PY' || true
import json, math, sys

touches, scrolls = [], []
video = (1000.0, 1000.0)
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "video" and event.get("config") and event.get("stream") == 1:
        video = (float(event["w"]), float(event["h"]))
    if event.get("ev") != "input" or event.get("stream") != 1:
        continue
    if event.get("kind") == "touch":
        touches.append({"action": int(event["action"]), "pointer": int(event["pointer"]),
                        "nx": float(event["nx"]), "ny": float(event["ny"]), "ts": float(event["ts"])})
    elif event.get("kind") == "scroll":
        scrolls.append(event)

DOWN, UP, MOVE, CANCEL = 0, 1, 2, 3


def verdict(good, label, detail=""):
    print(("ok: " if good else "bad: ") + label + ((": " + detail) if detail else ""))


def near(a, b, tolerance):
    return abs(a - b) <= tolerance


gestures, current = [], None
for event in touches:
    if event["action"] == DOWN and event["pointer"] == 0:
        current = []
        gestures.append(current)
    if current is not None:
        current.append(event)

verdict(len(gestures) == 4, "C15 four touch gestures (2 drags, pinch, rotate)", "got %d" % len(gestures))
verdict(len(scrolls) == 1 and scrolls[0]["v"] > 0, "C15 the wheel is one SCROLL frame, the trackpad scrolls none",
        "scroll frames=%s" % [round(s["v"], 2) for s in scrolls])
if len(gestures) != 4:
    sys.exit(0)

# Video height in points is its pixels divided by the backing scale of the run;
# 200 pt of scroll moves the finger by 200 / that, normalized.
height_pt = video[1] / float(sys.argv[2])
expected = 200.0 / height_pt


def check_drag(events, sign, label):
    actions = [e["action"] for e in events]
    moves = [e for e in events if e["action"] == MOVE]
    verdict(events[0]["action"] == DOWN and actions[-1] == UP and CANCEL not in actions,
            "C15 %s: DOWN, MOVEs, UP (no cancel)" % label, "actions=%s" % actions[:3] + "..." + str(actions[-2:]))
    verdict(all(e["pointer"] == 0 for e in events), "C15 %s: one finger only" % label)
    verdict(near(events[0]["nx"], 0.5, 0.03) and near(events[0]["ny"], 0.5, 0.03),
            "C15 %s: DOWN at the cursor" % label, "nx=%.3f ny=%.3f" % (events[0]["nx"], events[0]["ny"]))
    verdict(len(moves) >= 10, "C15 %s: a MOVE per scroll event" % label, "moves=%d" % len(moves))
    ys = [e["ny"] for e in moves]
    mono = all(b * sign >= a * sign - 1e-6 for a, b in zip(ys, ys[1:]))
    verdict(mono and near(events[-1]["ny"], 0.5 + sign * expected, 0.02),
            "C15 %s: the finger travels %s by 200 pt, 1:1" % (label, "down" if sign > 0 else "up"),
            "end ny=%.3f expected %.3f" % (events[-1]["ny"], 0.5 + sign * expected))
    # The phone stamps events on arrival: the cadence and the lift are what its
    # velocity tracker sees.
    gaps = [b["ts"] - a["ts"] for a, b in zip(moves, moves[1:])]
    lift = events[-1]["ts"] - moves[-1]["ts"]
    verdict(gaps and max(gaps) < 0.1 and lift < 0.05,
            "C15 %s: MOVEs a display refresh apart, UP right after the last (fling-compatible)" % label,
            "max gap %.0f ms, lift %.0f ms" % (max(gaps) * 1000 if gaps else -1, lift * 1000))


check_drag(gestures[0], +1, "trackscroll")
check_drag(gestures[1], -1, "fingerscroll")


def span_and_angle(a, b):
    dx, dy = (a["nx"] - b["nx"]) * video[0], (a["ny"] - b["ny"]) * video[1]
    return math.hypot(dx, dy), math.degrees(math.atan2(dy, dx))


def pairs(events):
    out, pending = [], None
    for e in events:
        if e["action"] != MOVE:
            continue
        if e["pointer"] == 0:
            pending = e
        elif pending is not None:
            out.append((pending, e))
            pending = None
    return out


def check_pair(events, label):
    actions = [e["action"] for e in events]
    pointers = [e["pointer"] for e in events]
    ordered = actions[:2] == [DOWN, DOWN] and pointers[:2] == [0, 1] and actions[-2:] == [UP, UP] and pointers[-2:] == [1, 0]
    verdict(ordered, "C15 %s: DOWN(0) DOWN(1) ... UP(1) UP(0)" % label, "actions=%s pointers=%s" % (actions[:3], pointers[-2:]))
    return ordered


down_span, down_angle = None, None
if check_pair(gestures[2], "fingerpinch"):
    g = gestures[2]
    down_span, _ = span_and_angle(g[0], g[1])
    moves = pairs(g)
    last_span, _ = span_and_angle(*moves[-1])
    verdict(len(moves) >= 4 and near(last_span / down_span, 1.8, 0.12), "C15 fingerpinch: spread x1.8 from the landing",
            "ratio %.2f over %d pairs" % (last_span / down_span, len(moves)))
    mid = ((moves[-1][0]["nx"] + moves[-1][1]["nx"]) / 2, (moves[-1][0]["ny"] + moves[-1][1]["ny"]) / 2)
    verdict(near(mid[0], 0.5, 0.01) and near(mid[1], 0.5, 0.01), "C15 fingerpinch: anchored at the cursor",
            "mid=%.3f,%.3f" % mid)
    verdict(down_span > 60 and down_span < 400, "C15 fingerpinch: the landing span is 32 mm x 4 pt/mm = 128 pt", "%.0f px" % down_span)

if check_pair(gestures[3], "fingerrotate"):
    g = gestures[3]
    start_span, start_angle = span_and_angle(g[0], g[1])
    moves = pairs(g)
    end_span, end_angle = span_and_angle(*moves[-1])
    turned = (end_angle - start_angle + 180) % 360 - 180
    verdict(near(end_span, start_span, 0.06 * start_span), "C15 fingerrotate: the pair keeps its span",
            "%.0f -> %.0f px" % (start_span, end_span))
    verdict(near(turned, -90, 8), "C15 fingerrotate: turns 90 deg counter-clockwise", "turned=%.1f" % turned)
PY
)"
    if [ -z "$verdicts" ]; then
        bad "C15 the trackpad checker produced no verdicts"
    else
        while IFS= read -r line; do
            case "$line" in
                "ok: "*)  ok "${line#ok: }" ;;
                "bad: "*) bad "${line#bad: }" ;;
            esac
        done <<< "$verdicts"
    fi
    stop_app
    stop_fakephone
}

# --- C8: pause/resume -----------------------------------------------------

check_pause() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --minimize-stream 1:6 --deminimize-stream 1:11 --quit-after 16
    wait_app
    # Another window passing over the test window makes macOS report it occluded,
    # which is a pause/resume pair of its own. The scripted minimize holds the
    # stream paused for the 5 s between the two timers; count that pair, require
    # every pause to be answered by a resume, and report any short pair that is
    # not ours instead of letting it decide the verdict.
    local verdict
    verdict="$(python3 - "$WORK/events.jsonl" <<'PY' || true
import json, sys

marks = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if isinstance(msg, dict) and msg.get("stream") == 1 and msg.get("t") in ("window.pause", "window.resume"):
        marks.append((msg["t"], event["ts"]))

pairs, open_pause, stray = [], None, 0
for kind, ts in marks:
    if kind == "window.pause":
        if open_pause is not None:
            stray += 1
        open_pause = ts
    elif open_pause is not None:
        pairs.append(ts - open_pause)
        open_pause = None
    else:
        stray += 1
scripted = [gap for gap in pairs if 3.5 <= gap <= 6.5]
others = [gap for gap in pairs if not 3.5 <= gap <= 6.5]
print("scripted=%d others=%d unanswered=%d stray=%d" % (len(scripted), len(others), 1 if open_pause is not None else 0, stray))
PY
)"
    say "C8 pause/resume pairs: $verdict"
    case "$verdict" in
        *"scripted=1 "*) ok "C8 exactly one scripted window.pause/window.resume pair (5 s apart)" ;;
        *) bad "C8 scripted pair: $verdict" ;;
    esac
    case "$verdict" in
        *"unanswered=0 stray=0"*) ok "C8 every window.pause is answered by a window.resume" ;;
        *) bad "C8 unbalanced pause/resume: $verdict" ;;
    esac
    stop_fakephone
}

# --- C10: direct reconnect to a dozing phone (no mDNS) ---------------------

# check_direct — pair over --connect, then restart the app with no discovery
# at all: it must reconnect through the remembered IPv4 address. A different
# device id behind the same address must be refused and the address dropped.
check_direct() {
    clean
    # Phase A: pair; `welcome` stores the key (Keychain) + address (prefs).
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 16
    wait_app
    grep -q '"state":"paired"' "$WORK/events.jsonl" \
        && ok "C10a paired" || bad "C10a first launch did not pair"
    local cached
    cached="$(defaults read "$DEFAULTS_SUITE" cachedAddresses 2>/dev/null || true)"
    case "$cached" in
        *127.0.0.1:$PORT*) ok "C10a cached address stored ($cached)" ;;
        *) bad "C10a no cached address: $cached" ;;
    esac
    stop_fakephone
    sleep 1

    # Phase B: same phone, same port, no mDNS, app launched without --connect.
    : > "$WORK/events.jsonl"
    start_fake || return 1
    launch --quit-after 20
    wait_app
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "C10b reconnected through the cached address (auth_ok)" \
        || bad "C10b no auth_ok via the cached address"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C10b paired again instead of using the stored key" \
        || ok "C10b used the stored key"
    stop_fakephone
    sleep 1

    # Phase C: a different device id now answers on that address.
    : > "$WORK/events.jsonl"
    rm -f "$WORK/state-other.json"
    start_fake "$WORK/state-other.json" || return 1
    launch --quit-after 16
    wait_app
    grep -q '"state":"open"' "$WORK/events.jsonl" \
        && ok "C10c reached the cached address" || bad "C10c never connected to the cached address"
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && bad "C10c authenticated against a different device id" \
        || ok "C10c refused the different device id (no auth_ok)"
    grep -q '"t":"auth"' "$WORK/events.jsonl" \
        && bad "C10c sent auth for the wrong device" || ok "C10c sent no auth for the wrong device"
    cached="$(defaults read "$DEFAULTS_SUITE" cachedAddresses 2>/dev/null || true)"
    case "$cached" in
        *127.0.0.1:$PORT*) bad "C10c cached address kept after the mismatch" ;;
        *) ok "C10c cached address dropped after the mismatch" ;;
    esac
    stop_fakephone
}

# --- C11: navigation shortcuts --------------------------------------------

# check_nav — ⌘[ and Esc in an app window are `nav back`; ⇧⌘H and ⌘↑ in the
# phone window are `nav home` / `nav recents` (fakephone logs them as rx "nav").
# Two launches: with both windows open they overlap, and a click aimed at one
# can land on the other in front.
check_nav() {
    clean

    nav_count() {
        python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
stream, action = int(sys.argv[2]), sys.argv[3]
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if isinstance(msg, dict) and msg.get("t") == "nav" \
            and msg.get("stream") == stream and msg.get("action") == action:
        count += 1
print(count)
PY
    }

    # nav_at_least <count> <action> — stream 1 has received that many nav actions.
    nav_at_least() { [ "$(nav_count 1 "$2")" -ge "$1" ]; }

    # Phase A: an app window -> ⌘[ and Esc are `nav back` on stream 1.
    start_fake || return 1
    printf '%s\n' "key cmd+[" "key esc" > "$WORK/input-back.txt"
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --debug-input-script "$WORK/input-back.txt" --quit-after 60
    wait_until 30 nav_at_least 1 back \
        && ok "C11 ⌘[ in an app window -> nav back" || bad "C11 no nav back after ⌘["
    wait_until 30 nav_at_least 2 back \
        && ok "C11 Esc in an app window -> nav back" || bad "C11 no second nav back after Esc"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # Phase B: a phone-mode window -> ⇧⌘H home, ⌘↑ recents (both stream 1).
    : > "$WORK/events.jsonl"
    start_fake || return 1
    printf '%s\n' "key cmd+shift+h" "key cmd+up" > "$WORK/input-phone.txt"
    launch --connect "127.0.0.1:$PORT" --open-phone \
        --debug-input-script "$WORK/input-phone.txt" --quit-after 60
    wait_until 30 nav_at_least 1 home \
        && ok "C11 ⇧⌘H in the phone window -> nav home" || bad "C11 no nav home"
    wait_until 30 nav_at_least 1 recents \
        && ok "C11 ⌘↑ in the phone window -> nav recents" || bad "C11 no nav recents"
    stop_app
    stop_fakephone
}

# --- MIRROR: the phone window mirrors display 0 and turns with it -----------

# mirror_aspect — "WxH ok|off": stream 1's first VIDEO_CONFIG and whether it
# has the fake screen's 1080x2340 aspect (within the 16 px alignment).
mirror_aspect() {
    python3 - "$WORK/events.jsonl" <<'PY' || true
import json, sys
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "video" and e.get("stream") == 1 and e.get("config"):
        w, h = e["w"], e["h"]
        print("%dx%d %s" % (w, h, "ok" if abs(h / w - 2340 / 1080) < 0.05 else "off"))
        break
PY
}

# check_mirror — the phone window shows display 0 at the screen's aspect; when
# the phone turns to landscape the stream and the window turn with it.
check_mirror() {
    clean
    FAKE_ARGS="--rotate-after 6" start_fake || return 1
    # The pointer comes to the top edge to bring the header in (glass nav buttons).
    printf '%s\n' "wait 1" "hoverat 0 200" "wait 0.03" "hoverat 0 150" "wait 0.03" "hoverat 0 120" \
        "wait 0.03" "hoverat 0 90" "wait 0.03" "hoverat 0 70" "wait 0.03" "hoverat 0 58" > "$WORK/mirror.txt"
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/mirror.txt" --quit-after 40
    local portrait landscape shot="$WORK/mirror-glass.png"
    if portrait="$(await_window '$5 > $4 * 1.5')"; then
        ok "MIRROR phone window is portrait ($(windows | awk -v i="$portrait" '$1 == i {print $4 "x" $5}'))"
    else
        bad "MIRROR no portrait phone window"; stop_app; stop_fakephone; return 1
    fi
    wait_until 15 events_have '"ev":"video"' || true
    case "$(mirror_aspect)" in
        *" ok") ok "MIRROR stream has the phone screen's aspect ($(mirror_aspect))" ;;
        *) bad "MIRROR stream aspect is not the phone's ($(mirror_aspect))" ;;
    esac
    wait_until 3 chrome_is "header=shown" && sleep 0.4
    region_shot "$portrait" "$shot" && say "glass nav screenshot ($(chrome_state)): $shot"
    if landscape="$(await_window "\$1 == $portrait && \$4 > \$5 * 1.5")"; then
        ok "MIRROR window turned with the phone ($(windows | awk -v i="$landscape" '$1 == i {print $4 "x" $5}'))"
    else
        bad "MIRROR window did not turn to landscape"
    fi
    wait_until 10 landscape_config \
        && ok "MIRROR landscape VIDEO_CONFIG sent" || bad "MIRROR no landscape VIDEO_CONFIG"
    stop_app
    stop_fakephone
}

# landscape_config — stream 1 has had a VIDEO_CONFIG wider than tall.
landscape_config() {
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "video" and e.get("stream") == 1 and e.get("config") and e["w"] > e["h"]:
        sys.exit(0)
sys.exit(1)
PY
}

# no_fakephone — true once no fakephone process is left (its port is free).
no_fakephone() { ! pgrep -f -- "--events $WORK/events.jsonl" >/dev/null; }

# --- C12: Spotlight for phone apps ----------------------------------------

# spotlight_log_line — the app's index log line from the last two minutes.
spotlight_log_line() {
    log show --last 2m --info \
        --predicate 'subsystem == "dev.pocketdeck.mac" AND process == "PocketDeck"' 2>/dev/null \
        | grep -o 'spotlight: indexing [0-9]* apps' | tail -1
}

spotlight_logged() { [ -n "$(spotlight_log_line)" ]; }

# check_spotlight — after an app list arrives the apps are indexed. mdfind is
# tried first; an unsigned dev bundle may not be able to write the Spotlight
# index, in which case the unit tests (item builder + throttle) and the app's
# own index log line are the evidence.
check_spotlight() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 18
    wait_app
    # Read the app's index log line now: the log window is relative to the
    # time of the query, and the unit tests below can take minutes.
    wait_until 10 spotlight_logged
    local logged hit
    logged="$(spotlight_log_line)"
    hit="$(mdfind 'kMDItemContentDescription == "Android app on FakePhone"' 2>/dev/null | head -3 || true)"
    if [ -n "$hit" ]; then
        ok "C12 mdfind found indexed phone apps: $(echo "$hit" | tr '\n' ' ')"
    else
        say "C12 mdfind lists nothing (an unsigned dev bundle cannot surface in the Spotlight index); falling back to the unit test + the app's log line"
        local out
        out="$(cd "$MACOS" && swift test --filter SpotlightTests 2>&1 || true)"
        if echo "$out" | grep -q "with 0 failures"; then
            ok "C12 Spotlight unit tests pass (builder + throttled re-index + domain removal)"
        else
            bad "C12 Spotlight unit tests failed"
        fi
        if [ -n "$logged" ]; then
            ok "C12 the app logged the index attempt ($logged)"
        else
            bad "C12 no spotlight log line from the app (indexing never attempted)"
        fi
    fi
    stop_fakephone
}

# --- C14: audio phone -> Mac -------------------------------------------------
# check_audio — the Mac opens a window (which starts device audio), the
# fakephone streams a 440 Hz AAC tone, and the Mac's audio stats file must show
# a config plus frames/bytes (buffer counters count as capture evidence).

audio_stats_ok() {
    python3 - "$WORK/audio.json" <<'PY'
import json, sys
try:
    stats = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if stats.get("configs", 0) >= 1 and stats.get("frames", 0) >= 10 else 1)
PY
}

check_audio() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" \
        --open com.android.settings --audio-stats "$WORK/audio.json" --quit-after 30
    if wait_until 20 audio_stats_ok; then
        ok "C14 Mac received audio (config + >=10 frames)"
    else
        bad "C14 no audio at the Mac: $(cat "$WORK/audio.json" 2>/dev/null || echo 'no stats file')"
    fi
    python3 - "$WORK/audio.json" <<'PY' && ok "C14 AAC 48k stereo tone" || bad "C14 unexpected audio format: $(cat "$WORK/audio.json" 2>/dev/null)"
import json, sys
stats = json.load(open(sys.argv[1]))
assert stats.get("codec") == 3, stats
assert stats.get("sampleRate") == 48000, stats
assert stats.get("channels", 2) == 2, stats
PY
    grep -q '"t":"audio.start"' "$WORK/events.jsonl" \
        && ok "C14 audio.start sent" || bad "C14 no audio.start in phone log"
    grep -q '"ev":"audio"' "$WORK/events.jsonl" \
        && ok "C14 phone streamed audio" || bad "C14 no audio event in phone log"
    stop_app
    stop_fakephone
}

# --- C9: no leftovers -----------------------------------------------------

# check_clip — plain-text clipboard sync both ways (docs/PROTOCOL.md "Clipboard
# sync"). The fakephone sends pd-clip-1 right after welcome: the Mac's pasteboard
# must show it, and the Mac must not send it back. Then the Mac copies pd-clip-2
# and the fakephone must log it. The person's pasteboard is saved first and put
# back when this check returns, failures included (text only: other types are lost).
check_clip() {
    clean
    local saved="$WORK/pasteboard.saved"
    pbpaste > "$saved" 2>/dev/null
    trap 'pbcopy < "$saved"; trap - RETURN' RETURN

    clip_is() { [ "$(pbpaste)" = "$1" ]; }

    # A sentinel, so pd-clip-1 can only have come from the phone.
    printf '%s' pd-clip-0 | pbcopy
    python3 "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --events "$WORK/events.jsonl" --state "$WORK/state.json" \
        --clip-on-welcome pd-clip-1 > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" && break
        sleep 0.25
    done
    grep -q "listening" "$WORK/fake.log" || { bad "CLIP fakephone did not start"; return 1; }

    launch --connect "127.0.0.1:$PORT" --quit-after 60
    wait_until 30 clip_is pd-clip-1 \
        && ok "CLIP phone -> Mac: pbpaste shows pd-clip-1" \
        || bad "CLIP pbpaste shows '$(pbpaste)', not pd-clip-1"
    sleep 2
    ! events_have '"dir":"rx","text":"pd-clip-1"' \
        && ok "CLIP the Mac does not send pd-clip-1 back" \
        || bad "CLIP the Mac echoed pd-clip-1 to the phone"

    printf '%s' pd-clip-2 | pbcopy
    wait_until 30 events_have '"dir":"rx","text":"pd-clip-2"' \
        && ok "CLIP Mac -> phone: fakephone logs clip.set pd-clip-2" \
        || bad "CLIP fakephone did not log clip.set pd-clip-2"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# check_sharein — Share phone -> Mac (docs/design/sharein.md). The fakephone shares a
# link, an image, a file: URL and a plain text. The app runs with --share-log (links are
# recorded as "would open", never opened; notifications recorded, not shown) and
# --share-dir in the work dir, so the person's browser and ~/Downloads are never touched.
# The pasteboard is saved first and put back when this check returns (text only).
check_sharein() {
    clean
    local saved="$WORK/pasteboard.saved" dir="$WORK/share-dir" log="$WORK/share.log" image="$WORK/pd-share.png"
    pbpaste > "$saved" 2>/dev/null
    trap 'pbcopy < "$saved"; trap - RETURN' RETURN
    printf '%s' pd-share-0 | pbcopy
    python3 - "$image" <<'PY2'
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
rows = b"".join(b"\x00" + bytes((x * 7 + y * 3) % 256 for x in range(64 * 3)) for y in range(64))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY2
    python3 "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --events "$WORK/events.jsonl" --state "$WORK/state.json" \
        --share "text:https://example.com/sharein" --share "image:$image" \
        --share "text:file:///etc/hosts" --share "text:pd-share-text-1" > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" && break
        sleep 0.25
    done
    grep -q "listening" "$WORK/fake.log" || { bad "SHAREIN fakephone did not start"; return 1; }

    launch --connect "127.0.0.1:$PORT" --quit-after 60 --share-dir "$dir" --share-log "$log"
    log_has() { grep -qF -- "$1" "$log" 2>/dev/null; }
    clip_is() { [ "$(pbpaste)" = "$1" ]; }
    saved_image() { [ -f "$dir/pd-share.png" ]; }

    wait_until 30 log_has "would open https://example.com/sharein" \
        && ok "SHAREIN url -> the Mac would open https://example.com/sharein" \
        || bad "SHAREIN no 'would open https://example.com/sharein' in the share log"
    wait_until 30 saved_image && [ "$(shasum -a 256 < "$dir/pd-share.png" | cut -d' ' -f1)" = "$(shasum -a 256 < "$image" | cut -d' ' -f1)" ] \
        && ok "SHAREIN image -> share dir has pd-share.png with the same sha256" \
        || bad "SHAREIN image missing or different in $dir ($(ls -a "$dir" 2>/dev/null | tr '\n' ' '))"
    wait_until 30 clip_is pd-share-text-1 \
        && ok "SHAREIN text -> pbpaste shows pd-share-text-1" \
        || bad "SHAREIN pbpaste shows '$(pbpaste)', not pd-share-text-1"
    log_has "notify Copied from FakePhone: file:///etc/hosts" && ! log_has "would open file:" \
        && ok "SHAREIN a file: URL is copied as text, never opened" \
        || bad "SHAREIN file: URL handling wrong: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    log_has "notify Image from FakePhone: pd-share.png" \
        && ok "SHAREIN notifications recorded (Copied from / Image from FakePhone)" \
        || bad "SHAREIN no image notification in the share log"
    sleep 2
    ! events_have '"dir":"rx","text":"pd-share-text-1"' \
        && ok "SHAREIN the shared text is not echoed back as clip.set" \
        || bad "SHAREIN the Mac echoed the shared text to the phone"
    [ -z "$(ls -A "$dir" | grep '^\.')" ] \
        && ok "SHAREIN no partial files left in the share dir" \
        || bad "SHAREIN leftovers in $dir: $(ls -A "$dir" | tr '\n' ' ')"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# check_links — links Mac -> phone (docs/design/links.md). A pocketdeck://open URL
# goes to the running e2e app, which sends link.open: the fakephone logs it and a
# stream window opens with video. A file: link is refused on the Mac and never
# reaches the phone. `open -a` names the e2e bundle so LaunchServices cannot hand the
# URL to another PocketDeck copy; the check first makes sure LaunchServices knows the
# running e2e process by that bundle, so `open` delivers to it instead of starting a
# second instance (which would run without --profile).
check_links() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 90

    authenticated() { events_have '"state":"auth_ok"' || events_have '"state":"paired"'; }
    wait_until 30 authenticated \
        || { bad "LINKS the app never authenticated"; stop_app; stop_fakephone; return 1; }

    local registered
    registered="$(lsappinfo info -only bundlepath "$(lsappinfo find pid="$APP_PID" 2>/dev/null)" 2>/dev/null)"
    case "$registered" in
        *"$E2E_BUNDLE"*) ;;
        *) bad "LINKS LaunchServices does not list pid $APP_PID as $E2E_BUNDLE ($registered)"
           stop_app; stop_fakephone; return 1 ;;
    esac

    link_logged() {
        python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "link" and event.get("url") == sys.argv[2]:
        sys.exit(0)
sys.exit(1)
PY
    }
    stream_video() { events_have '"ev":"video"'; }

    open_quiet -a "$E2E_BUNDLE" "pocketdeck://open?url=https%3A%2F%2Fexample.com"
    wait_until 30 link_logged "https://example.com" \
        && ok "LINKS fakephone logs link.open https://example.com" \
        || bad "LINKS fakephone did not log link.open https://example.com"
    wait_until 30 stream_video && wait_until 15 windows_at_least 2 \
        && ok "LINKS a stream window opened with video ($(windows | wc -l | tr -d ' ') windows)" \
        || bad "LINKS no stream window/video for the link"

    open_quiet -a "$E2E_BUNDLE" "pocketdeck://open?url=file%3A%2F%2F%2Fetc%2Fhosts"
    sleep 3
    ! events_have 'file:///etc/hosts' \
        && ok "LINKS a file: link never reaches the phone" \
        || bad "LINKS the Mac sent a file: link to the phone"

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] && ! pgrep -fx "$APP" >/dev/null \
        && ok "LINKS the URL went to the running e2e app (one instance)" \
        || bad "LINKS open started another PocketDeck instance"
    pkill -fx "$APP" >/dev/null 2>&1
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# check_apk — APK install from the Mac (docs/design/apk.md). Small .apk/.apks files are
# opened with `open -a` on the e2e bundle; the fakephone acts like pm (a part holding
# PD_FAKE_DOWNGRADE fails with INSTALL_FAILED_VERSION_DOWNGRADE).
apk_log() {
    log show --last 3m --info \
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null \
        | grep -o 'apk: .*'
}

check_apk() {
    clean
    start_fake || return 1
    # Quiet runs hand the files to the app's Open With handler through its
    # request folder: LaunchServices' `open -a` brings the running app forward
    # even with -g, so that route is the visible run's.
    local requests=()
    if [ "$VISIBLE" = "1" ]; then
        open_apk() { open -a "$E2E_BUNDLE" "$1"; }
    else
        mkdir -p "$WORK/open-requests"
        requests=(--open-requests "$WORK/open-requests")
        open_apk() {
            printf '%s\n' "$1" > "$WORK/open-requests/$(basename "$1").tmp"
            mv "$WORK/open-requests/$(basename "$1").tmp" "$WORK/open-requests/$(date +%s%N)-$(basename "$1").path"
        }
        skip_visible "APK the files arrive through LaunchServices (open -a, Finder's Open With)"
    fi
    launch --connect "127.0.0.1:$PORT" "${requests[@]}" --quit-after 120

    authenticated() { events_have '"state":"auth_ok"' || events_have '"state":"paired"'; }
    wait_until 30 authenticated \
        || { bad "APK the app never authenticated"; stop_app; stop_fakephone; return 1; }

    python3 - "$WORK" <<'PY'
import os, sys, zipfile
work = sys.argv[1]
def apk(path, marker=b""):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        z.writestr("AndroidManifest.xml", b"\x03\x00\x08\x00" + marker)
        z.writestr("classes.dex", os.urandom(3 * 1024 * 1024))
apk(os.path.join(work, "tiny.apk"))
apk(os.path.join(work, "old.apk"), b"PD_FAKE_DOWNGRADE")
split = os.path.join(work, "split.apk")
apk(split)
with zipfile.ZipFile(os.path.join(work, "bundle.apks"), "w", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(work, "tiny.apk"), "splits/base-master.apk")
    z.write(split, "splits/base-arm64_v8a.apk")
    z.writestr("toc.pb", b"\x00")
PY

    apk_event() {
        python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
want_ok = sys.argv[3] == "ok"
n = 0
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "apk" and e.get("ok") == want_ok:
        n += 1
        if n == int(sys.argv[2]):
            print(json.dumps(e))
            sys.exit(0)
sys.exit(1)
PY
    }
    apk_found() { apk_event "$@" >/dev/null; }
    apps_lists() { grep -c '"t":"apps.list"' "$WORK/events.jsonl" 2>/dev/null || echo 0; }
    log_has() { apk_log | grep -qF -- "$1"; }

    local before event want
    before="$(apps_lists)"
    open_apk "$WORK/tiny.apk"
    if wait_until 30 apk_found 1 ok; then
        event="$(apk_event 1 ok)"
        want="$(shasum -a 256 "$WORK/tiny.apk" | cut -c1-64)"
        echo "$event" | python3 -c 'import json,sys; f=json.load(sys.stdin)["files"]; sys.exit(0 if len(f)==1 and f[0]["match"] and f[0]["sha256"]==sys.argv[1] else 1)' "$want" \
            && ok "APK fakephone got tiny.apk with a matching sha256 (${want:0:12}…)" \
            || bad "APK sha256 mismatch: $event (want $want)"
    else
        bad "APK fakephone never received the install"
    fi
    wait_until 15 log_has "apk: phone received all" && log_has "apk: sending 1 part(s)" \
        && ok "APK progress shown ($(apk_log | grep -m1 'apk: sending'); $(apk_log | grep -m1 'received all'))" \
        || bad "APK no progress logged: $(apk_log | tail -3)"
    wait_until 15 log_has "apk: result ok: Installed Tiny Demo 1.0." \
        && ok "APK result message: Installed Tiny Demo 1.0." \
        || bad "APK no success message: $(apk_log | tail -2)"
    apps_refreshed() { [ "$(apps_lists)" -gt "$before" ]; }
    wait_until 10 apps_refreshed \
        && ok "APK the app list was refreshed after the install" \
        || bad "APK no apps.list after the install"

    open_apk "$WORK/old.apk"
    wait_until 30 log_has "apk: result failed: A newer version of this app is already on the phone." \
        && ok "APK downgrade failure reads: A newer version of this app is already on the phone." \
        || bad "APK no downgrade message: $(apk_log | tail -2)"

    open_apk "$WORK/bundle.apks"
    if wait_until 30 apk_found 2 ok; then
        event="$(apk_event 2 ok)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); f=e["files"]; sys.exit(0 if [x["name"] for x in f]==["base-master.apk","base-arm64_v8a.apk"] and all(x["match"] for x in f) else 1)' \
            && ok "APK .apks sent base + split, both sha256 match" \
            || bad "APK .apks parts wrong: $event"
    else
        bad "APK the .apks install never arrived"
    fi

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] \
        && ok "APK the files went to the running e2e app (one instance)" \
        || bad "APK open started another PocketDeck instance"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# check_drop — a file dropped on a window (docs/design/dragdrop.md). The scripted
# `dropfile` feeds the same handler a Finder drag ends in, so the path under test
# is the window's own drop destination -> FileDropSender; fakephone acts like
# Downloads/PocketDeck (a chunk holding PD_FAKE_DOWNSIZE trips the 200 MiB rule).
# Clipboard images have no DebugInput action, so nothing is scripted for them.
drop_log() {
    log show --last 3m --info \
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null \
        | grep -o 'drop: .*'
}

check_drop() {
    clean
    start_fake || return 1

    python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
# 3 MB of random bytes: a real chunked transfer, small enough to hash quickly.
with open(os.path.join(work, "drop-3mb.bin"), "wb") as f:
    f.write(os.urandom(3 * 1024 * 1024))
# The negative case: the trip stands in for a file over the cap.
with open(os.path.join(work, "tripped.bin"), "wb") as f:
    f.write(b"PD_FAKE_DOWNSIZE" + os.urandom(64 * 1024))
PY

    drop_event() {
        python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
want_ok = sys.argv[3] == "ok"
n = 0
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "drop" and e.get("ok") == want_ok:
        n += 1
        if n == int(sys.argv[2]):
            print(json.dumps(e))
            sys.exit(0)
sys.exit(1)
PY
    }
    drop_found() { drop_event "$@" >/dev/null; }
    log_has() { drop_log | grep -qF -- "$1"; }
    fake_log_has() { grep -qF -- "$1" "$WORK/fake.log"; }

    # The 8 s wait keeps the two drops apart: FileDropSender takes one file at a
    # time and would refuse the second while the first is still in flight.
    printf '%s\n' "dropfile $WORK/drop-3mb.bin" "wait 8" "dropfile $WORK/tripped.bin" "wait 5" \
        > "$WORK/drop.txt"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --debug-input-script "$WORK/drop.txt" --quit-after 120

    local event want
    if wait_until 60 drop_found 1 ok; then
        event="$(drop_event 1 ok)"
        want="$(shasum -a 256 "$WORK/drop-3mb.bin" | cut -c1-64)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); f=e["files"]; sys.exit(0 if len(f)==1 and f[0]["name"]=="drop-3mb.bin" and f[0]["size"]==3*1024*1024 and f[0]["match"] and f[0]["sha256"]==sys.argv[1] else 1)' "$want" \
            && ok "DROP fakephone got drop-3mb.bin (3 MB) with a matching sha256 (${want:0:12}…)" \
            || bad "DROP sha256/size mismatch: $event (want $want)"
    else
        bad "DROP fakephone never received the file"
    fi
    # The log line's size is public, the (empty) resume tail is not: match up to "bytes".
    wait_until 15 log_has "drop: sending drop-3mb.bin (3145728 bytes" \
        && ok "DROP the window's handler announced the file and streamed it" \
        || bad "DROP no drop: sending line: $(drop_log | tail -3)"
    wait_until 15 log_has "drop: ok: Saved on the phone: drop-3mb.bin" \
        && ok "DROP result message: Saved on the phone: drop-3mb.bin" \
        || bad "DROP no success message: $(drop_log | tail -2)"
    # No chunk leaves before the phone's opening drop.progress (the sender waits for
    # it), so the whole file arriving proves the progress message was parsed; the
    # byte count is the wire's DROP_DATA total.
    wait_until 15 fake_log_has "3145728 bytes (drop-3mb.bin) -> sha ok" \
        && ok "DROP fakephone received all 3145728 bytes over DROP_DATA" \
        || bad "DROP fakephone did not log the full 3 MB: $(grep -i drop "$WORK/fake.log" | tail -2)"

    if wait_until 60 drop_found 1 bad; then
        event="$(drop_event 1 bad)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); sys.exit(0 if e["code"]=="too_large" and not e["files"][0].get("match") else 1)' \
            && ok "DROP the over-cap trip answered ok=false too_large" \
            || bad "DROP the negative event is wrong: $event"
    else
        bad "DROP the PD_FAKE_DOWNSIZE trip never reached fakephone"
    fi
    wait_until 15 log_has "drop: failed: The phone refused it: the file is bigger than the phone's cap." \
        && ok "DROP the refusal reads: The phone refused it: the file is bigger than the phone's cap." \
        || bad "DROP no refusal message: $(drop_log | tail -2)"

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] \
        && ok "DROP the app survived the failed drop (one instance)" \
        || bad "DROP the app died or a second instance appeared"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- Share extension ------------------------------------------------------

SHARE_ID="dev.pocketdeck.mac.share-e2e"
SHARE_TITLE="Open on Phone (e2e)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# The share driver links the extension's own hand-off code (LinkShare.swift), so its
# name hashes both sources.
build_share_driver() {
    local hash
    hash="$(cat "$MACOS/scripts/share-driver.swift" "$MACOS/Sources/PocketDeck/LinkShare.swift" | shasum | cut -c1-12)"
    SHAREBIN="$TOOLS/share-driver-$hash"
    if [ ! -x "$SHAREBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O -parse-as-library "$MACOS/scripts/share-driver.swift" "$MACOS/Sources/PocketDeck/LinkShare.swift" \
            -o "$SHAREBIN" >/dev/null 2>&1 || { say "could not build share-driver.swift"; return 1; }
    fi
}

share_listed() { pluginkit -m -i "$SHARE_ID" 2>/dev/null | grep -q "$SHARE_ID"; }

# unregister_share — the e2e bundle and its extension leave LaunchServices and
# PlugInKit, so nothing of the test copy stays in the person's share menu.
unregister_share() {
    [ -d "$E2E_BUNDLE/Contents/PlugIns/Share.appex" ] && pluginkit -r "$E2E_BUNDLE/Contents/PlugIns/Share.appex" >/dev/null 2>&1
    "$LSREGISTER" -u "$E2E_BUNDLE" >/dev/null 2>&1
    return 0
}

# check_share — the "Open on Phone" Share extension (docs/design/links.md).
# K6: the e2e bundle carries Share.appex under its own id, signs strictly, and PlugInKit
# lists it while registered. K7a: the extension's hand-off code (share-driver handoff)
# sends a link found in shared text -> link.open; non-link text sends nothing.
# K7b: the real sandboxed extension through AppKit's share services (the same entry
# the Share menu uses; the menu UI itself is not scripted) -> link.open.
check_share() {
    clean
    local appex="$E2E_BUNDLE/Contents/PlugIns/Share.appex"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$appex/Contents/Info.plist" 2>/dev/null)" = "com.apple.share-services" ] \
        && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Contents/Info.plist" 2>/dev/null)" = "$SHARE_ID" ] \
        && ok "SHARE bundle has Share.appex ($SHARE_ID, com.apple.share-services)" \
        || bad "SHARE Share.appex missing or wrong Info.plist"
    codesign --verify --deep --strict "$E2E_BUNDLE" 2>/dev/null \
        && codesign -d --entitlements - "$appex" 2>/dev/null | grep -q app-sandbox \
        && ok "SHARE codesign --deep --strict passes; the extension is sandboxed" \
        || bad "SHARE codesign verify failed or the extension is not sandboxed"

    "$LSREGISTER" -f "$E2E_BUNDLE" >/dev/null 2>&1
    pluginkit -a "$appex" >/dev/null 2>&1
    pluginkit -e use -i "$SHARE_ID" >/dev/null 2>&1
    wait_until 10 share_listed \
        && ok "SHARE pluginkit lists $SHARE_ID" || bad "SHARE pluginkit does not list $SHARE_ID"

    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 120
    authenticated() { events_have '"state":"auth_ok"' || events_have '"state":"paired"'; }
    wait_until 30 authenticated \
        || { bad "SHARE the app never authenticated"; stop_app; stop_fakephone; unregister_share; return 1; }

    link_event() { grep -F '"ev": "link"' "$WORK/events.jsonl" 2>/dev/null | grep -qF "\"url\": \"$1\"" \
        || grep -F '"ev":"link"' "$WORK/events.jsonl" 2>/dev/null | grep -qF "\"url\":\"$1\""; }

    "$SHAREBIN" handoff "$E2E_BUNDLE" "look at https://example.com/handoff please" > "$WORK/share-a.log" 2>&1
    wait_until 20 link_event "https://example.com/handoff" \
        && ok "SHARE hand-off: text with a link -> fakephone logs link.open" \
        || bad "SHARE hand-off did not reach the phone ($(cat "$WORK/share-a.log"))"
    ! "$SHAREBIN" handoff "$E2E_BUNDLE" "no link in here" >/dev/null 2>&1 \
        && ! "$SHAREBIN" handoff "$E2E_BUNDLE" "file:///etc/hosts" >/dev/null 2>&1 \
        && ok "SHARE hand-off refuses text without a link and file: URLs" \
        || bad "SHARE hand-off accepted non-link text or a file: URL"

    "$SHAREBIN" service "$SHARE_TITLE" "https://example.com/extension" > "$WORK/share-b.log" 2>&1
    wait_until 20 link_event "https://example.com/extension" \
        && ok "SHARE the sandboxed extension -> fakephone logs link.open" \
        || bad "SHARE the extension did not reach the phone ($(tr '\n' ' ' < "$WORK/share-b.log"))"

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] && ! pgrep -fx "$APP" >/dev/null \
        && ok "SHARE the links went to the running e2e app (one instance)" \
        || bad "SHARE the hand-off started another PocketDeck instance"
    pkill -fx "$APP" >/dev/null 2>&1
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    unregister_share
    wait_until 10 eval '! share_listed' \
        && ok "SHARE $SHARE_ID unregistered after the check" || bad "SHARE $SHARE_ID still registered"
}

# --- Dock apps (docs/design/dock.md) --------------------------------------

# Dock apps of this run live only in $WORK/dock-apps, never in ~/Applications.
dock_dir() { echo "$WORK/dock-apps"; }

dock_shim_pids() { [ -n "${WORK:-}" ] && pgrep -f -- "$(dock_dir)/.*/Contents/MacOS/PocketDeckShim"; }

# Dock apps made from the profile folder are the automatic ones (a check that
# opens app windows without --dock-dir). Every run cleans its own.
profile_dock_dir() { echo "$HOME/Library/Application Support/PocketDeck-$PROFILE/Dock Apps"; }

# remove_dock_apps — this run's shims stop, leave LaunchServices and the disk.
remove_dock_apps() {
    [ -n "${WORK:-}" ] || return 0
    local pids app
    pids="$(dock_shim_pids)"
    [ -n "$pids" ] && kill $pids >/dev/null 2>&1
    pids="$(pgrep -f -- "$(profile_dock_dir)/.*/Contents/MacOS/PocketDeckShim")"
    [ -n "$pids" ] && kill $pids >/dev/null 2>&1
    for app in "$(dock_dir)"/*.app "$(profile_dock_dir)"/*.app; do
        [ -d "$app" ] || continue
        "$LSREGISTER" -u "$app" >/dev/null 2>&1
        rm -rf "$app"
    done
    return 0
}

# window_rx <t> <pkg-or-empty> — the fakephone received a JSON message of type t
# (for window.open: for that package).
window_rx() {
    python3 - "$WORK/events.jsonl" "$1" "${2:-}" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if event.get("ev") == "rx" and msg.get("t") == sys.argv[2] and (not sys.argv[3] or msg.get("pkg") == sys.argv[3]):
        sys.exit(0)
sys.exit(1)
PY
}

# Read the whole dump first: under pipefail, `grep -q` closing the pipe early fails the pipeline.
registered_in_ls() { local dump; dump="$("$LSREGISTER" -dump 2>/dev/null)"; grep -qF -- "$1" <<< "$dump"; }

# check_dock — K3: the app creates a Dock app for a fakephone app in a temp folder;
# `open` on it -> window.open for that package and a window; quitting the shim -> the
# window closes; a second run with --dock-remove -> the bundle is gone and unregistered.
# And the automatic identity (docs/design/dock.md §Lifecycle): an app window the app
# opens itself makes the shim exist and run while the window is open and brings it
# down with the window; with the setting off nothing is created and "Add to Dock"
# still works.
check_dock() {
    clean
    local dir pkg="com.whatsapp" shim id
    dir="$(dock_dir)"
    remove_dock_apps
    mkdir -p "$dir"
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" --quit-after 120
    shim_made() { ls -d "$dir"/*.app >/dev/null 2>&1; }
    wait_until 30 shim_made || { bad "DOCK no Dock app created in $dir"; stop_app; stop_fakephone; return 1; }
    shim="$(ls -d "$dir"/*.app | head -1)"
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$shim/Contents/Info.plist" 2>/dev/null)"
    [ "$(basename "$shim")" = "WhatsApp (FakePhone).app" ] && [ "$id" = "dev.pocketdeck.dock.$PROFILE.$(/usr/libexec/PlistBuddy -c 'Print :PDDeviceId' "$shim/Contents/Info.plist").com-whatsapp" ] \
        && ok "DOCK created $(basename "$shim") ($id)" || bad "DOCK unexpected bundle $(basename "$shim") ($id)"
    [ -s "$shim/Contents/Resources/AppIcon.icns" ] && codesign --verify --strict "$shim" 2>/dev/null \
        && ok "DOCK has AppIcon.icns from the phone's icon and is signed" || bad "DOCK no icon or bad signature"
    wait_until 10 registered_in_ls "$id" && ok "DOCK registered with LaunchServices" || bad "DOCK not registered with LaunchServices"

    local before
    before="$(windows | wc -l | tr -d ' ')"
    open_quiet "$shim"
    wait_until 20 window_rx window.open "$pkg" \
        && ok "DOCK open -> fakephone got window.open for $pkg" || bad "DOCK no window.open for $pkg"
    wait_until 15 windows_at_least $((before + 1)) \
        && ok "DOCK the app window appeared ($(windows | wc -l | tr -d ' ') windows)" || bad "DOCK no new window"
    wait_until 5 eval '[ -n "$(dock_shim_pids)" ]' \
        && ok "DOCK the shim runs as its own app (pid $(dock_shim_pids | tr '\n' ' '))" || bad "DOCK the shim is not running"

    kill $(dock_shim_pids) >/dev/null 2>&1
    wait_until 15 window_rx window.close \
        && ok "DOCK quitting the shim -> window.close" || bad "DOCK quitting the shim did not close the window"
    wait_until 10 eval '[ "$(windows | wc -l | tr -d " ")" -le "$before" ]' \
        && ok "DOCK the window is gone" || bad "DOCK the window is still open"
    stop_app
    remove_dock_apps

    # Automatic identity (default on): a window the app opens itself builds and
    # launches its shim, and the shim exits when the window closes.
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" --close-stream 1:20 --quit-after 60
    wait_until 30 window_rx window.open "$pkg" \
        && ok "DOCK auto: window.open arrived for $pkg" || bad "DOCK auto: no window.open for $pkg"
    wait_until 30 shim_made \
        && ok "DOCK auto: the window's Dock app was created ($(ls "$dir" | head -1))" \
        || bad "DOCK auto: no Dock app was created in $dir"
    wait_until 10 eval '[ -n "$(dock_shim_pids)" ]' \
        && ok "DOCK auto: the shim runs for the window (pid $(dock_shim_pids | tr '\n' ' '))" \
        || bad "DOCK auto: the shim is not running"
    wait_until 20 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "DOCK auto: closing the window made the shim exit" || bad "DOCK auto: the shim outlives the window"
    stop_app
    wait_until 5 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "DOCK auto: quitting the app leaves no shim behind" || bad "DOCK auto: a shim survived the app"
    remove_dock_apps

    # Setting off: the window opens, nothing is created.
    defaults write "$DEFAULTS_SUITE" showAppsInDock -bool NO
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" --quit-after 25
    wait_until 20 window_rx window.open "$pkg" \
        && ok "DOCK off: window.open arrived for $pkg" || { bad "DOCK off: no window.open"; stop_app; stop_fakephone; return 1; }
    sleep 15
    [ -n "$(ls -d "$dir"/*.app 2>/dev/null)" ] \
        && bad "DOCK off: a Dock app was created anyway" \
        || ok "DOCK off: no Dock app is created automatically"
    stop_app

    # ... but the menu command keeps working.
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" --quit-after 60
    wait_until 30 shim_made && ok "DOCK off: Add to Dock still works" || bad "DOCK off: Add to Dock no longer works"
    stop_app

    # Removing by hand: --dock-remove unregisters and deletes the bundle.
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-remove "$pkg" --quit-after 60
    wait_until 30 eval '! shim_made' && ok "DOCK --dock-remove deleted the bundle" || bad "DOCK the bundle is still there"
    wait_until 10 eval '! registered_in_ls "$id"' \
        && ok "DOCK unregistered from LaunchServices" || bad "DOCK still registered with LaunchServices"
    stop_app
    defaults delete "$DEFAULTS_SUITE" showAppsInDock >/dev/null 2>&1

    stop_fakephone
    remove_dock_apps
    wait_until 5 no_fakephone
}

# --- Phone nickname (docs/ROADMAP.md #1, #2) --------------------------------

# check_nickname — a nickname names the phone everywhere. It is set the way
# Settings stores it (a `phoneNicknames` map in the profile's defaults, written
# before launch) and through the real rename path (--set-nickname calls the
# same method the Rename dialog's button does). Assertions: the app window's
# title is "Settings (Nicky)" (the Dock/⌘-Tab identity), the Dock shim is
# "WhatsApp (Nicky).app", the phone window is titled with the nickname, and a
# rename retitles the window and rebuilds the shim.
check_nickname() {
    clean
    local dir pkg="com.whatsapp" devid
    dir="$(dock_dir)"
    remove_dock_apps
    mkdir -p "$dir"
    # A fixed device id in the fresh state file, so the nickname exists before
    # the phone is ever met.
    devid="e2e0nick0name0001"
    printf '{"id": "%s", "clients": {}}' "$devid" > "$WORK/state.json"
    # A [String: String] map, as Settings stores it (old-style plist for `defaults`).
    defaults write "$DEFAULTS_SUITE" phoneNicknames "{ $devid = Nicky; }"
    grep -q "$devid" <(defaults read "$DEFAULTS_SUITE" phoneNicknames 2>/dev/null) \
        || { bad "NICK the nickname never reached the defaults suite"; return 1; }

    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" \
        --open com.android.settings --open-phone --quit-after 120
    wait_until 30 events_have '"state":"auth_ok"' \
        || wait_until 30 events_have '"state":"paired"' \
        || { bad "NICK the app never authenticated"; stop_app; stop_fakephone; return 1; }

    # The Dock shim carries the nickname in its name, not the phone's own.
    shim_name_is() { ls -d "$dir"/*.app 2>/dev/null | grep -qF -- "$1"; }
    wait_until 30 shim_name_is "WhatsApp (Nicky).app" \
        && ok "NICK the Dock shim is \"WhatsApp (Nicky).app\"" \
        || bad "NICK no renamed shim in $dir: $(ls -d "$dir"/*.app 2>/dev/null | tr '\n' ' ')"
    local shim
    shim="$(ls -d "$dir/WhatsApp ("*.app 2>/dev/null | head -1)"
    [ -n "$shim" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$shim/Contents/Info.plist" 2>/dev/null)" = "WhatsApp (Nicky)" ] \
        && ok "NICK the shim's CFBundleName is \"WhatsApp (Nicky)\"" \
        || bad "NICK unexpected shim Info.plist in ${shim:-none}"

    # The app window title (and with it the Dock/⌘-Tab entry).
    wait_until 20 titles_have "Settings (Nicky)" \
        && ok "NICK the app window is titled \"Settings (Nicky)\"" \
        || bad "NICK no \"Settings (Nicky)\" window: ($(window_titles | tr '\n' '|'))"
    # The phone window names the phone with the nickname alone.
    wait_until 20 titles_line "Nicky" \
        && ok "NICK the phone window is titled with the nickname" \
        || bad "NICK no \"Nicky\" title: ($(window_titles | tr '\n' '|'))"
    stop_app

    # A rename through the real code path retitles the open window and rebuilds
    # the shim. The app list still runs this app; no new shim may appear.
    local before
    before="$(ls -d "$dir"/*.app 2>/dev/null | wc -l | tr -d ' ')"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" \
        --open com.android.settings --set-nickname "Nicky 2" --quit-after 120
    wait_until 30 events_have '"state":"auth_ok"' \
        && ok "NICK second launch reconnected" || bad "NICK second launch did not authenticate"
    wait_until 30 titles_have "Settings (Nicky 2)" \
        && ok "NICK the rename retitled the app window" \
        || bad "NICK the rename did not retitle: ($(window_titles | tr '\n' '|'))"
    wait_until 30 shim_name_is "WhatsApp (Nicky 2).app" \
        && ok "NICK the rename rebuilt the Dock shim" \
        || bad "NICK no rebuilt shim: $(ls -d "$dir"/*.app 2>/dev/null | tr '\n' ' ')"
    [ "$(ls -d "$dir"/*.app 2>/dev/null | wc -l | tr -d ' ')" -le "$before" ] \
        && ok "NICK no shim was left behind by the rename ($(ls "$dir" 2>/dev/null | tr '\n' ' '))" \
        || bad "NICK more shims than before: $(ls "$dir" 2>/dev/null | tr '\n' ' ')"
    stop_app

    defaults delete "$DEFAULTS_SUITE" phoneNicknames >/dev/null 2>&1
    stop_fakephone
    remove_dock_apps
    wait_until 5 no_fakephone
}

# --- Continue on Mac (docs/ROADMAP.md #9, docs/design/handoff.md) -----------

# check_handoff — the --continue-on-mac hook runs the menu command (the same
# ConnectionController.continueOnMac the ⌘⇧C/menu items call) once the session
# is ready. The fakephone stages the three phone answers: the foreground app
# moved to the new display (default), relaunched fresh (the move was refused),
# and nothing continuable (the foreground is the home screen/SystemUI). The
# moved and fresh answers open a window titled with the app the phone reports
# ("Settings (FakePhone)") and stream video; nothing opens nothing but a notice.
check_handoff() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --continue-on-mac --quit-after 30

    wait_until 30 events_have '"t":"task.continue"' \
        && ok "HO the Mac sent task.continue" || bad "HO no task.continue reached the phone"
    wait_until 30 events_have '"ev":"task.continue","stream":1,"mode":"moved"' \
        && ok "HO the phone moved the foreground app (started=moved)" \
        || bad "HO no moved answer: $(tail -2 "$WORK/events.jsonl" | tr '\n' ' ')"
    wait_until 30 events_have '"ev":"video","stream":1,' \
        || bad "HO no video for the continued app"
    wait_until 15 windows_at_least 2 \
        && ok "HO a window opened for the continued app ($(windows | wc -l | tr -d ' ') windows)" \
        || bad "HO no window opened"
    wait_until 15 titles_have "Settings (FakePhone)" \
        && ok "HO the window is titled \"Settings (FakePhone)\" (the app the phone reports)" \
        || bad "HO no titled window: $(window_titles "$APP_PID" | tr '\n' '|')"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # The move was refused: the phone still opens the stream and says so
    # (window.opened started="fresh"); the Mac opens the window all the same.
    clean
    python3 "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --events "$WORK/events.jsonl" --state "$WORK/state.json" \
        --handoff-mode fresh > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do grep -q "listening" "$WORK/fake.log" && break; sleep 0.25; done
    grep -q "listening" "$WORK/fake.log" || { bad "HO fresh: fakephone did not start"; return 1; }
    launch --connect "127.0.0.1:$PORT" --continue-on-mac --quit-after 30
    wait_until 30 events_have '"t":"task.continue"' || bad "HO fresh: no task.continue"
    wait_until 30 events_have '"ev":"task.continue","stream":1,"mode":"fresh"' \
        && ok "HO fresh: the phone answered that it relaunched the app" \
        || bad "HO fresh: no fresh answer"
    wait_until 30 events_have '"ev":"video","stream":1,' \
        && ok "HO fresh: the app still streams into its window" || bad "HO fresh: no video"
    wait_until 15 titles_have "Settings (FakePhone)" \
        && ok "HO fresh: the window is titled after the relaunched app" \
        || bad "HO fresh: no titled window"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # Nothing continuable: no window after the notice, only the short notice
    # on the Mac. The pairing sheet keeps window counts unstable, so the phone
    # side (no display, refusal answer) and the missing title are the evidence.
    clean
    python3 "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --events "$WORK/events.jsonl" --state "$WORK/state.json" \
        --handoff-mode nothing > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do grep -q "listening" "$WORK/fake.log" && break; sleep 0.25; done
    grep -q "listening" "$WORK/fake.log" || { bad "HO nothing: fakephone did not start"; return 1; }
    launch --connect "127.0.0.1:$PORT" --continue-on-mac --quit-after 30
    wait_until 30 events_have '"t":"task.continue"' \
        && ok "HO nothing: the command still reaches the phone" || bad "HO nothing: no task.continue"
    wait_until 30 events_have '"ev":"task.continue","stream":1,"mode":"nothing"' \
        && ok "HO nothing: the phone refused (nothing continuable in the foreground)" \
        || bad "HO nothing: the phone did not refuse"
    ! events_have '"ev":"video"' \
        && ok "HO nothing: no video, the phone opened no display" \
        || bad "HO nothing: video streamed for a refused handoff"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- Notifications + media controls ---------------------------------------

# check_notify — phone notifications + media controls (docs/design/notify.md).
# With the per-phone opt-in on, the phone's two posts and its removal are
# recorded by the Mac's --share-log (ids, package names and field lengths only --
# never the text); `notifyclick` runs the same routing a banner click runs and
# opens that app's window on the Mac; `mediacmd` drives what a Now Playing
# control drives. With the opt-in off (the default) the Mac forwards nothing and
# never asks the phone to enable.
check_notify() {
    clean
    local log="$WORK/notify.log" offlog="$WORK/notify-off.log" script="$WORK/notify-input.txt" device
    log_has() { grep -qF -- "$1" "$log" 2>/dev/null; }
    off_log_has() { grep -qF -- "$1" "$offlog" 2>/dev/null; }
    # The phone was asked to share (the strict JSON form; key order is the app's).
    notify_enable_on() {
        python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if event.get("ev") == "rx" and msg.get("t") == "notify.enable" and msg.get("on") is True:
        sys.exit(0)
sys.exit(1)
PY
    }
    # Privacy: the fake's notification text must never reach a log (the media
    # title may; nothing here records it either).
    no_notify_text() {
        local file
        for file in "$@"; do
            if grep -qE 'pd-notify-(title|text)-[12]' "$file" 2>/dev/null; then
                say "  notification text in $file"
                return 1
            fi
        done
        return 0
    }

    start_fake || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" | head -1)"
    [ -n "$device" ] || { bad "NOTIFY no device id in the fakephone listening line"; stop_fakephone; return 1; }
    # The per-phone opt-in is a stored default of the e2e profile, off by default
    # (check_dock seeds showAppsInDock the same way).
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES

    # The click and the command go through the same handlers the banner click
    # and the Now Playing control run; both arrive after the window's video.
    cat > "$script" <<'EOF'
wait 3
notifyclick pd-n1
mediacmd play
EOF
    launch --connect "127.0.0.1:$PORT" --quit-after 60 --share-log "$log" \
        --open com.whatsapp --debug-input-script "$script"

    # (a) opt-in on: the Mac asks, the posts and the remove are recorded.
    wait_until 20 notify_enable_on \
        && ok "NOTIFY the Mac asked the phone to share (notify.enable on)" \
        || bad "NOTIFY the Mac never sent notify.enable on"
    wait_until 20 log_has "notify post id=pd-n1 pkg=com.android.settings" \
        && ok "NOTIFY pd-n1 (com.android.settings) recorded" \
        || bad "NOTIFY pd-n1 not recorded: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 20 log_has "notify post id=pd-n2 pkg=com.whatsapp" \
        && ok "NOTIFY pd-n2 (com.whatsapp) recorded" \
        || bad "NOTIFY pd-n2 not recorded"
    wait_until 20 log_has "notify remove id=pd-n2" \
        && ok "NOTIFY the removal of pd-n2 was recorded" \
        || bad "NOTIFY the remove was not recorded"
    log_has "thread=$device" \
        && ok "NOTIFY the posts are grouped under the phone ($device)" \
        || bad "NOTIFY the records are not grouped per phone"
    grep -qE 'titleLen=[0-9]+ bodyLen=[0-9]+' "$log" 2>/dev/null \
        && ok "NOTIFY the records carry field lengths, not the text" \
        || bad "NOTIFY the posts were recorded without lengths"
    log_has "media set playing=true" && log_has "durationMs=30000" \
        && ok "NOTIFY media.state drove Now Playing (playing, 30 s)" \
        || bad "NOTIFY no Now Playing set: $(cat "$log" 2>/dev/null | tr '\n' '|')"

    # (c) the click opens that app's window, through the phone's window.open.
    wait_until 30 log_has "notify click id=pd-n1 pkg=com.android.settings" \
        && ok "NOTIFY the click recorded pd-n1 -> com.android.settings" \
        || bad "NOTIFY no click record: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 30 window_rx window.open "com.android.settings" \
        && ok "NOTIFY the click sent window.open for com.android.settings" \
        || bad "NOTIFY the click never reached the phone"
    wait_until 20 events_have '"ev":"video","stream":2,' \
        && ok "NOTIFY the Mac opened the clicked app's stream window (stream 2)" \
        || bad "NOTIFY no stream 2 for the clicked app"

    # (d) a Now Playing command reaches the phone as media.command.
    wait_until 20 events_have '"ev":"media","cmd":"play"' \
        && ok "NOTIFY the Now Playing control reached the phone (media.command play)" \
        || bad "NOTIFY no media.command play at the phone"
    log_has "media command play" \
        && ok "NOTIFY the command went through the Now Playing handler" \
        || bad "NOTIFY the command was not recorded"

    # (e) privacy: no notification text in any log.
    no_notify_text "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/events.jsonl" \
        && ok "NOTIFY no notification text in the app log, share log, fake log or event log" \
        || bad "NOTIFY notification text leaked"

    # (b) opt-in off (the default): nothing is forwarded, nothing is asked.
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    : > "$WORK/events.jsonl"
    # The same phone and pairing, so only the opt-in differs between the phases.
    start_fake "$WORK/state.json" || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 60 --share-log "$offlog" --open com.whatsapp
    wait_until 30 window_rx window.open "com.whatsapp" \
        || { bad "NOTIFY off: the app never got online"; stop_app; stop_fakephone; return 1; }
    sleep 8
    ! notify_enable_on \
        && ok "NOTIFY off: the phone was not sent notify.enable on" \
        || bad "NOTIFY off: notify.enable on was sent anyway"
    ! off_log_has "notify post" && ! off_log_has "notify remove" && ! off_log_has "notify click" \
        && ok "NOTIFY off: no post, remove or click reached the share log" \
        || bad "NOTIFY off: $(cat "$offlog" 2>/dev/null | tr '\n' '|')"
    no_notify_text "$WORK/app.log" "$offlog" "$WORK/fake.log" "$WORK/events.jsonl" \
        && ok "NOTIFY off: no notification text anywhere" \
        || bad "NOTIFY off: notification text leaked"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- DECK: the app grid's icon kinds ---------------------------------------

icons_kind() { grep '"ev":"icon"' "$WORK/events.jsonl" 2>/dev/null | grep -c "$1" || true; }

have_layered_icons() { [ "$(icons_kind '"layers":true')" -ge 4 ]; }
have_flat_icons() { [ "$(icons_kind '"layers":false')" -ge 5 ]; }

# check_deck — the grid gets both kinds of icon the phone can send: fakephone
# answers fg/bg layers for every 3rd app and a flat PNG for the rest. The Deck
# shows both without errors and the grid is captured for the human (glass is
# judged by eye in .agent/glass/; this check only asserts the wire and the
# log say both kinds arrived).
check_deck() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 40
    wait_until 30 events_have '"t":"apps.list"' \
        && ok "DECK the app list was requested" || bad "DECK no apps.list"
    wait_until 30 have_layered_icons \
        && ok "DECK layered icon replies arrived ($(icons_kind '"layers":true'))" \
        || bad "DECK no layered icon replies"
    wait_until 5 have_flat_icons \
        && ok "DECK flat icon replies arrived ($(icons_kind '"layers":false'))" \
        || bad "DECK no flat icon replies"
    local total
    total="$(count_events '"ev":"icon"')"
    [ "$total" -ge 13 ] && ok "DECK $total icon replies in total" || bad "DECK only $total icon replies"
    ! grep -qiE "fatal|protocol error" "$WORK/app.log" 2>/dev/null \
        && ok "DECK the app logged no fatal/protocol error" \
        || bad "DECK the app log has fatal/protocol lines"
    # The deckMode transition (welcome -> grid) settles; a capture too early
    # shows both states overlapped, which is useless as the visual record.
    sleep 3
    local deck="$WORK/deck-grid.png" id
    if id="$(await_window '$4 >= 600')" && screencapture -x -l"$id" "$deck"; then
        ok "DECK grid captured: $deck"
    else
        bad "DECK no Deck window to capture"
    fi
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

check_orphans() {
    sleep 1
    local n
    n="$(e2e_app_pids | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan PocketDeck processes" || bad "C9 $n orphan PocketDeck processes"
    n="$(pgrep -f -- "--events $WORK/events.jsonl" | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan fakephone processes" || bad "C9 $n orphan fakephone processes"
}

# build_e2e_app — bundles the current tree to build/e2e/PocketDeck.app.
build_e2e_app() {
    if ! "$MACOS/scripts/bundle.sh" "$E2E_BUNDLE" --variant e2e > "$WORK/bundle.log" 2>&1; then
        say "could not bundle $E2E_BUNDLE:"; tail -20 "$WORK/bundle.log"; return 1
    fi
}

which_check="${1:-all}"
case "$which_check" in
    qr|pair|render|resize|input|mouseback|input-global|pause|direct|nav|mirror|spotlight|pinch|chrome|trackpad|clip|sharein|links|share|apk|drop|dock|nickname|notify|audio|handoff|deck|all) ;;
    *) say "usage: check-e2e.sh [qr|pair|render|resize|input|mouseback|input-global|pause|direct|nav|mirror|spotlight|pinch|chrome|trackpad|clip|sharein|links|share|apk|drop|dock|nickname|notify|audio|handoff|deck|all]"; exit 2 ;;
esac
acquire_lock
wait_for_other_runs
pick_run
mkdir -p "$WORK"
say "run: port $PORT, work $WORK, profile $PROFILE, app $E2E_BUNDLE"
build_e2e_app || exit 1
build_cgevent || exit 1
build_share_driver || exit 1
build_watch || exit 1
build_vdisplay || exit 1
build_load || exit 1
init_watchdog
start_load
start_vdisplay || exit 1
start_watch
case "$which_check" in
    qr)       check_qr ;;
    pair)     check_pair ;;
    mirror)   check_mirror ;;
    render)   check_render ;;
    resize)   check_resize ;;
    input)    check_input ;;
    mouseback) check_mouseback ;;
    input-global) check_input_global ;;
    pinch)    check_pinch ;;
    chrome)   check_chrome ;;
    trackpad) check_trackpad ;;
    pause)    check_pause ;;
    direct)   check_direct ;;
    nav)      check_nav ;;
    spotlight) check_spotlight ;;
    clip)     check_clip ;;
    sharein)  check_sharein ;;
    links)    check_links ;;
    share)    check_share ;;
    apk)      check_apk ;;
    drop)     check_drop ;;
    dock)     check_dock ;;
    nickname) check_nickname ;;
    deck)     check_deck ;;
    notify)   check_notify ;;
    audio)    check_audio ;;
    handoff)  check_handoff ;;
    all)      check_qr; check_pair; check_render; check_resize; check_input; check_mouseback; check_pinch
              check_chrome; check_trackpad; check_pause; check_direct; check_nav; check_mirror; check_spotlight; check_clip; check_sharein; check_links; check_share; check_apk; check_drop; check_dock; check_nickname
              check_notify; check_audio; check_handoff; check_deck; check_orphans ;;
esac

quiet_report
watchdog_report
load_report
say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" = "0" ]
