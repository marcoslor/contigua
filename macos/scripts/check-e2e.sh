#!/usr/bin/env bash
# End-to-end checks C3-C13 for the macOS client against tools/fakephone.
#
#   ./scripts/check-e2e.sh [qr|pair|gates|tls|render|resize|input|hover|mouseback|input-global|pause|direct|nav|mirror|spotlight|intents|mcp|focus|controls|pinch|chrome|menus|density|trackpad|clip|sharein|links|share|apk|drop|dock|nickname|notify|notify-actions|notify-media|media|audio|handoff|deck|all [--shard N/M]]
#
# Every check starts from a clean slate (the shared-app checks share one, see
# "The shared app" below): no PocketDeck or fakephone processes
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
# build/e2e/PocketDeck.app, rebuilt from the current tree when it changed
# (PD_E2E_PREBUILT names a bundle built elsewhere, e.g. the host side of a VM
# run, and skips the rebuild). The
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
# The fake phone needs a TLS 1.3 interpreter (docs/design/e2ee.md §6): the
# system python3 links LibreSSL, so PD_FAKE_TLS_PYTHON names python3.11+.
FAKE_PY="${PD_FAKE_TLS_PYTHON:-$(command -v python3.11 || echo /usr/bin/python3)}"
"$FAKE_PY" -c 'import sys, ssl; sys.exit(0 if sys.version_info[:2] >= (3,11) and not ssl.OPENSSL_VERSION.startswith("LibreSSL") else 3)' 2>/dev/null || {
    say "$FAKE_PY cannot serve TLS 1.3; set PD_FAKE_TLS_PYTHON to a python3.11+ built on OpenSSL 3"
    exit 3
}
E2E_BUNDLE="${PD_E2E_PREBUILT:-$MACOS/build/e2e/PocketDeck.app}"
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
        end_shared
        kill_e2e_app
        stop_fakephone
        stop_vdisplay
        stop_watchdog app
        unregister_share
        unregister_files
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
    # v2 pairing state = the Mac identity + per-phone pins in the profile
    # folder; the checks pair from scratch each run, so both must go. v1's
    # pairkeys.json is gone; IdentityMigrationV2 wipes it on the next start.
    local support="$HOME/Library/Application Support/PocketDeck-$PROFILE"
    rm -f "$support/pairkeys.json" "$support/identity.json" "$support/pins.json"
    defaults delete "$DEFAULTS_SUITE" >/dev/null 2>&1
    return 0
}

clean() {
    end_shared
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
# stdout goes to fake.log, stderr to fake.err (fakephone puts the listening
# line and its receive diagnostics on stderr): grep both when a line may be
# either. Starts fakephone with FAKE_PY — it needs a TLS 1.3 python.
start_fake() {
    local state="${1:-$WORK/state.json}"
    # shellcheck disable=SC2086
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow --allow-delay "${FAKE_ALLOW_DELAY:-0}" ${FAKE_ARGS:-} \
        --events "$WORK/events.jsonl" \
        --state "$state" > "$WORK/fake.log" 2> "$WORK/fake.err" &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" "$WORK/fake.err" 2>/dev/null && return 0
        sleep 0.25
    done
    say "fakephone did not start:"; cat "$WORK/fake.log" "$WORK/fake.err"; return 1
}

# launch <args...> — starts the app as a direct child so `wait` works. Quiet runs
# add --background: no activation, no Dock icon, windows on a virtual display.
launch() {
    local quiet=()
    [ "$VISIBLE" = "1" ] || quiet=(--background)
    "$APP" --profile "$PROFILE" ${quiet[@]+"${quiet[@]}"} "$@" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
    start_watchdog app "$APP_PID"
}

# gui_run <command...> — run in the VM's logged-in GUI (Aqua) session. check-e2e
# itself runs over ssh; `open` and accessibility scripting need that session.
gui_run() {
    perl -e 'alarm 150; exec @ARGV' sudo -n launchctl asuser "$(id -u)" sudo -n -u "$(id -un)" "$@"
}

# open_quiet <open args...> — LaunchServices `open` that does not bring the app
# forward in a quiet run.
open_quiet() { if [ "$VISIBLE" = "1" ]; then open "$@"; else open -g "$@"; fi; }

# skip <name> <reason> — a step this machine cannot run. A SKIP is not a
# failure: the suite says why it did not run and moves on.
skip() { say "SKIP $1 ($2)"; }

# skip_visible <name> — a step that needs real input through the window server.
skip_visible() { skip "$1" "needs real input; PD_E2E_VISIBLE=1 runs it"; }

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
# kills its processes and appends "WATCHDOG killed reason=…" to the run's log;
# watchdog_report below turns that into the run's FAIL. One watchdog guards the
# whole run through its targets file, one "<slot> <pid>" line per slot; <slot>
# pairs the start with the stop.
start_watchdog() {
    local slot="$1" target="$2"
    set_watchdog_target "$slot" "$target"
    if [ -z "${WD_PID:-}" ] || ! kill -0 "$WD_PID" 2>/dev/null; then
        "$WATCHDOG" --targets "$WATCHDOG_TARGETS" >> "$WATCHDOG_LOG" 2>&1 &
        WD_PID=$!
    fi
}

# set_watchdog_target <slot> [pid] — the slot's line in the targets file is
# replaced (or removed without a pid); the file is swapped in whole.
set_watchdog_target() {
    local slot="$1" target="${2:-}"
    { grep -v "^$slot " "$WATCHDOG_TARGETS" 2>/dev/null
      [ -z "$target" ] || echo "$slot $target"; } > "$WATCHDOG_TARGETS.tmp"
    mv "$WATCHDOG_TARGETS.tmp" "$WATCHDOG_TARGETS"
}

# stop_watchdog <slot> — nothing to watch in the slot any more. The watchdog
# itself stops with the last slot, so no watcher outlives the run.
stop_watchdog() {
    local slot="$1"
    [ -n "${WATCHDOG_TARGETS:-}" ] && [ -f "$WATCHDOG_TARGETS" ] || return 0
    set_watchdog_target "$slot"
    [ -s "$WATCHDOG_TARGETS" ] && return 0
    rm -f "$WATCHDOG_TARGETS"
    if [ -n "${WD_PID:-}" ]; then
        kill "$WD_PID" >/dev/null 2>&1
        wait "$WD_PID" 2>/dev/null
        WD_PID=""
    fi
    return 0
}

# init_watchdog — the run's watchdog log, empty at its start (the lock is held,
# so no other run's lines can be in it).
init_watchdog() {
    WATCHDOG_LOG="$WORK-watchdog.txt"
    WATCHDOG_TARGETS="$WORK-watchdog-targets.txt"
    : > "$WATCHDOG_LOG"
    rm -f "$WATCHDOG_TARGETS"
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
# --quit-after is only a safety bound. The shared app (below) is not stopped:
# its windows close and its stream state is forgotten, ready for the next check.
stop_app() {
    if [ -n "${SHARED_PID:-}" ] && [ "$APP_PID" = "$SHARED_PID" ]; then
        control reset || say "shared app: reset answered '$CONTROL_REPLY'"
        return 0
    fi
    kill "$APP_PID" >/dev/null 2>&1
    wait "$APP_PID" 2>/dev/null
}

# --- The shared app -------------------------------------------------------
#
# The checks that test neither launch, pairing nor first run (the window,
# input, chrome, audio and drop checks) share one running app and one phone
# instead of each launching its own: launch_shared starts it (a fresh launch,
# from a clean slate and pairing from scratch like any other), begin_shared
# hands it from one check to the next. Between checks the app gets a `reset`
# through its --debug-control folder (DebugControl.swift): every stream window
# closes as the person closes one and the stream state is forgotten (stream ids
# from 1, no remembered frames or styles: `reset prefs`), and the phone's event
# log starts empty. Between two phases of one check (next_shared) a plain
# `reset` keeps the remembered frames and styles, as a relaunch did. A check opens its windows with open_shared, which takes a launch's
# per-window options (--open, --float-windows, --debug-input-script, ...).
# stop_app resets the shared app; stop_fakephone leaves the shared phone up.
# Any check that runs `clean` (every check that needs a fresh launch) ends them.

CONTROL_SEQ=0

# control <command...> — runs one command in the shared app and waits for its
# answer (CONTROL_REPLY); true when the answer is "ok".
control() {
    local dir="$WORK-control" name
    CONTROL_SEQ=$((CONTROL_SEQ + 1))
    name="c$CONTROL_SEQ"
    printf '%s\n' "$*" > "$dir/$name.tmp" && mv "$dir/$name.tmp" "$dir/$name.cmd"
    if ! wait_until 10 [ -s "$dir/$name.done" ]; then
        CONTROL_REPLY="no answer in 10 s"
        return 1
    fi
    CONTROL_REPLY="$(cat "$dir/$name.done")"
    rm -f "$dir/$name.done"
    [ "$CONTROL_REPLY" = "ok" ]
}

# launch_shared <launch args...> — a fresh launch (after clean and start_fake,
# like any check's) that the following shared checks keep using.
launch_shared() {
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --debug-control "$WORK-control" "$@"
    SHARED_PID="$APP_PID"
    SHARED_FAKE_PID="$FAKE_PID"
}

shared_alive() {
    [ -n "${SHARED_PID:-}" ] && kill -0 "$SHARED_PID" 2>/dev/null \
        && [ -n "${SHARED_FAKE_PID:-}" ] && kill -0 "$SHARED_FAKE_PID" 2>/dev/null
}

# begin_shared — the start of a shared check: the running shared app, reset and
# with an empty phone event log and work dir, or else a fresh one.
begin_shared() {
    if shared_alive && control reset prefs; then
        find "$WORK" -mindepth 1 -maxdepth 1 ! -name events.jsonl ! -name state.json \
            ! -name 'fake*.log' ! -name fake.err ! -name app.log -exec rm -rf {} +
        : > "$WORK/events.jsonl"
        APP_PID="$SHARED_PID"
        FAKE_PID="$SHARED_FAKE_PID"
        return 0
    fi
    shared_alive && say "shared app: reset answered '$CONTROL_REPLY'; launching a new one"
    clean
    start_fake || return 1
    launch_shared --connect "127.0.0.1:$PORT"
    # The windows open once the session is ready (open_shared waits for it).
}

# next_shared — between two phases of one shared check: the phase's windows
# close and the phone's event log starts empty, as a relaunch against a fresh
# fakephone gave.
next_shared() {
    stop_app
    : > "$WORK/events.jsonl"
}

# open_shared <launch args...> — the check's windows in the shared app; the
# session may still be getting ready after a fresh launch.
open_shared() {
    local tries=60
    while ! control open "$@"; do
        tries=$((tries - 1))
        if [ "$CONTROL_REPLY" != "not online" ] || [ "$tries" -le 0 ]; then
            bad "shared app: open $* answered '$CONTROL_REPLY'"
            return 1
        fi
        sleep 0.5
    done
    APP_PID="$SHARED_PID"
}

# end_shared — the shared app and its phone stop (by their own PIDs only: an
# orphan of any check must still be found by C9).
end_shared() {
    [ -n "${SHARED_PID:-}" ] || return 0
    kill "$SHARED_PID" >/dev/null 2>&1
    wait "$SHARED_PID" 2>/dev/null
    [ -n "${SHARED_FAKE_PID:-}" ] && kill "$SHARED_FAKE_PID" >/dev/null 2>&1
    SHARED_PID=""
    SHARED_FAKE_PID=""
    wait_until 5 no_fakephone
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
        # A run is a bash whose script ($4) is check-e2e.sh. A wrapper that only
        # names it later on its command line (a lock script waiting its turn, or
        # holding the lock for this very run) is not one.
        others="$(ps -axo pid=,ppid=,command= | awk -v me="$$" \
            '$1 != me && $2 != me && $3 ~ /bash$/ && $4 ~ /check-e2e\.sh$/ {print $1}')"
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
# The shared phone (above) stays up for the next shared check.
stop_fakephone() {
    [ -n "${SHARED_PID:-}" ] && return 0
    [ -n "${WORK:-}" ] && pkill -f -- "--events $WORK/events.jsonl" >/dev/null 2>&1
}

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

# wait_until <seconds> <command...> — polls every 0.25 s until the command
# succeeds, for at most <seconds> of wall time. A deadline, not a try count: a
# probe that itself blocks (run_limited 15 ls on a stalled mount) would stretch
# a count of 4 tries per second into hours.
wait_until() {
    local end=$((SECONDS + $1))
    shift
    while :; do
        "$@" && return 0
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 0.25
    done
}

# events_have <text> — the fakephone event log contains the text.
events_have() { grep -qF -- "$1" "$WORK/events.jsonl" 2>/dev/null; }

# last_video_size — the newest video config's pixels, for a FAIL message: a
# window the screen clamps is what C6 usually catches.
last_video_size() {
    grep '"ev":"video"' "$WORK/events.jsonl" 2>/dev/null | grep '"config":true' | tail -1 \
        | grep -o '"w":[0-9]*,"h":[0-9]*' | tail -1
}

# await_app <seconds> <command...> — a positive step's end: the app has done what
# the step needs once the command succeeds, so it is stopped then instead of
# running out its --quit-after (which stays the step's upper bound).
await_app() {
    local seconds="$1"
    shift
    wait_until "$seconds" "$@"
    stop_app
}

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

# shot_window <window-id> <file> — the window's own pixels only, no shadow:
# the edge checks sample just inside the frame, so the capture must be exactly
# the window (screencapture -o drops the shadow -l would add).
shot_window() {
    local id="$1" file="$2"
    screencapture -x -o -l"$id" "$file"
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

# check_qr — the Mac shows a QR (c/n/f/s), the phone "scans" it (--qr-uri),
# answers pair.qr on the Mac's probe, and the live session completes with
# pair.ok; no pair.request ever leaves the Mac. The Allow gate is auto.
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
    wait_until 15 windows_at_least 2 \
        && ok "C3 QR sheet is on screen (launcher + sheet)" \
        || bad "C3 no sheet window: $(windows | tr '\n' ' ')"
    case "$(cat "$WORK/qr.txt")" in
        pocketdeck://pair?c=*"&n="*"&f="*"&s="*) ok "C3 payload is a pocketdeck://pair c/n/f/s URI" ;;
        *) bad "C3 payload shape: $(cat "$WORK/qr.txt")" ;;
    esac
    [ "$(grep -o 'f=[0-9a-f]*' "$WORK/qr.txt" | cut -c3- | tr -d '\n' | wc -c | tr -d ' ')" = "64" ] \
        && ok "C3 the Mac fingerprint f is 64 hex" || bad "C3 f is not 64 hex"
    [ "$(grep -o 's=[0-9a-f]*' "$WORK/qr.txt" | cut -c3- | tr -d '\n' | wc -c | tr -d ' ')" = "32" ] \
        && ok "C3 the one-time secret s is 32 hex (never a v1 k= key)" \
        || bad "C3 s is not 32 hex"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C3 live session tried pair.request while a QR was pending" \
        || ok "C3 no pair.request before the scan"

    # The phone now "scans": the same phone second start with the staged
    # pending QR; a Mac whose handshake fingerprint matches f gets pair.qr.
    stop_fakephone
    sleep 1
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --state "$WORK/state.json" --events "$WORK/events.jsonl" \
        --qr-uri "$(cat "$WORK/qr.txt")" > "$WORK/fake2.log" 2>&1 &
    FAKE_PID=$!
    qr_done() { events_have '"state":"auth_ok"' && events_have '"pkg":"com.android.settings"'; }
    await_app 30 qr_done
    grep -q '"t":"pair.qr"' "$WORK/events.jsonl" \
        && ok "C3 phone proved the scan with pair.qr" || bad "C3 no pair.qr"
    grep -q '"t":"pair.ok"' "$WORK/events.jsonl" \
        && ok "C3 pair.ok completed the QR pairing" || bad "C3 no pair.ok"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C3 pair.request after the scan" || ok "C3 no pair.request at all"
    grep -q '"t":"apps.list"' "$WORK/events.jsonl" \
        && ok "C3 app list requested after pairing" || bad "C3 no apps.list"
    grep -q '"t":"window.open"' "$WORK/events.jsonl" && grep -q '"pkg":"com.android.settings"' "$WORK/events.jsonl" \
        && ok "C3 auto-opened app after pairing" || bad "C3 no window.open"
    # The probe session ends `paired`; the reconnect after it authenticates
    # from the stored pins alone (auth_ok, the phone's pin of this Mac).
    grep -q '"state":"paired"' "$WORK/events.jsonl" \
        && [ "$(grep -c '"state":"auth_ok"' "$WORK/events.jsonl")" -ge 1 ] \
        && ok "C3 pins stored, reconnect authenticated" \
        || bad "C3 no reconnect auth_ok ($(grep -c '"state":"auth_ok"' "$WORK/events.jsonl" 2>/dev/null))"
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
    three_streams() {
        [ "$(grep '"ev":"video"' "$WORK/events.jsonl" | grep -o 'stream":[0-9]*' | sort -u | wc -l | tr -d ' ')" = "3" ]
    }
    await_app 30 three_streams
    grep -q '"state":"paired"' "$WORK/events.jsonl" \
        && ok "C4 first launch paired after an 8 s wait for Allow" || bad "C4 first launch did not pair"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && ok "C4 pair.request sent" || bad "C4 no pair.request"
    grep -q '"t":"pair.commit"' "$WORK/events.jsonl" \
        && ok "C4 phone committed before the Mac could release anything (pair.commit)" \
        || bad "C4 no pair.commit"
    grep -q '"t":"pair.nonce"' "$WORK/events.jsonl" \
        && ok "C4 Mac released its nonce (pair.nonce)" || bad "C4 no pair.nonce"
    grep -q '"t":"pair.reveal"' "$WORK/events.jsonl" \
        && ok "C4 phone revealed its nonce (pair.reveal)" || bad "C4 no pair.reveal"
    grep -q '"t":"pair.confirm"' "$WORK/events.jsonl" \
        && bad "C4 sent pair.confirm (the code is never typed)" || ok "C4 no pair.confirm"
    mac_code() {
        log show --last 4m --info --style syslog \
            --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null \
            | grep -o 'pairing code derived for this screen: [0-9]*' | grep -o '[0-9]*' | tail -1
    }
    wait_until 25 [ -n "$(mac_code)" ] || true
    phone_code="$(grep -o 'Pairing code: [0-9]*' "$WORK/fake.log" | grep -o '[0-9]*' | tail -1)"
    mac="$(mac_code)"
    for c in "$mac" "$phone_code"; do
        case "$c" in
            [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
            *) bad "C4 pairing code missing or not 6 digits (mac='${mac:-none}' phone='${phone_code:-none}')" ;;
        esac
    done
    [ -n "$mac" ] && [ "$mac" = "$phone_code" ] \
        && ok "C4 the code is the same on both screens ($mac; one §4 exporter)" \
        || bad "C4 the screens' codes disagree (mac='${mac:-none}' phone='${phone_code:-none}')"
    [ "$(count_events '"t":"window.open"')" = "3" ] \
        && ok "C4 three window.open" || bad "C4 expected 3 window.open, got $(count_events '"t":"window.open"')"
    grep -q '"pkg":"com.android.settings"' "$WORK/events.jsonl" && grep -q '"pkg":"com.whatsapp"' "$WORK/events.jsonl" \
        && ok "C4 both app packages" || bad "C4 missing an app package"
    grep -q '"mode":"phone"' "$WORK/events.jsonl" \
        && ok "C4 phone mode window" || bad "C4 missing phone mode window"
    local streams
    streams="$(grep '"ev":"video"' "$WORK/events.jsonl" | grep -o 'stream":[0-9]*' | sort -u | wc -l | tr -d ' ')"
    [ "$streams" = "3" ] && ok "C4 video configs for 3 streams" || bad "C4 configs for $streams streams"

    # second launch, same fakephone + stored pins: must authenticate without pairing
    : > "$WORK/events.jsonl"
    launch --connect "127.0.0.1:$PORT" --open-phone --quit-after 8
    await_app 8 events_have '"state":"auth_ok"'
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "C4 second launch auth_ok" || bad "C4 second launch did not auth"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C4 second launch tried to pair again" || ok "C4 second launch skipped pairing"
    stop_fakephone
}

# --- B3: the phone's connection gates --------------------------------------

# check_gates — the phone's "Allow new pairings" refuses an unknown Mac before
# any code, a paired Mac still connects with it off, and "Allow connections"
# refuses the paired Mac too. The Mac shows the phone's own sentence and retries
# on its normal backoff, not in a tight loop.
check_gates() {
    clean
    local banner="$WORK/banner.txt" attempts

    # 1. Pairings off, unknown Mac: refused at the handshake, no pairing traffic.
    rm -f "$WORK/state.json"
    FAKE_ARGS="--refuse-pairings" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-banner "$banner" --quit-after 20
    wait_until 20 events_have '"state":"refused_pairing"' \
        && ok "B3 pairings off: unknown Mac refused at the handshake" \
        || bad "B3 pairings off: no refusal event"
    wait_until 10 eval '[ "$(mac_failed_line)" = "session failed: pairing_off" ]' \
        && ok "B3 pairings off: Mac read pairing_off" \
        || bad "B3 pairings off: Mac reason '$(mac_failed_line)'"
    wait_until 10 grep -qF "isn't accepting new pairings." "$banner" \
        && ok "B3 pairings off: Mac shows \"$(cat "$banner")\"" \
        || bad "B3 pairings off: banner '$(cat "$banner" 2>/dev/null)'"
    events_have '"t":"pair.request"' \
        && bad "B3 pairings off: Mac still sent pair.request" \
        || ok "B3 pairings off: no pairing request left the Mac"
    stop_app
    stop_fakephone
    sleep 1

    # 2. Pair normally, so the phone has a pin for this Mac.
    : > "$WORK/events.jsonl"
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 16
    await_app 16 events_have '"state":"paired"'
    events_have '"state":"paired"' \
        && ok "B3 paired a Mac for the gate checks" || bad "B3 could not pair"
    stop_fakephone
    sleep 1

    # 3. Pairings off, the same paired Mac: it still connects.
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--refuse-pairings" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 16
    await_app 16 events_have '"state":"auth_ok"'
    events_have '"state":"auth_ok"' \
        && ok "B3 pairings off: the paired Mac still authenticated" \
        || bad "B3 pairings off: the paired Mac was refused"
    stop_fakephone
    sleep 1

    # 4. Master off: the paired Mac is refused, and the retries use the backoff.
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    FAKE_ARGS="--refuse-connections" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-banner "$banner" --quit-after 30
    wait_until 20 events_have '"state":"refused_connections"' \
        && ok "B3 connections off: paired Mac refused at the handshake" \
        || bad "B3 connections off: no refusal event"
    wait_until 10 eval '[ "$(mac_failed_line)" = "session failed: connections_off" ]' \
        && ok "B3 connections off: Mac read connections_off" \
        || bad "B3 connections off: Mac reason '$(mac_failed_line)'"
    wait_until 10 grep -qF "Connections are turned off on FakePhone." "$banner" \
        && ok "B3 connections off: Mac shows \"$(cat "$banner")\"" \
        || bad "B3 connections off: banner '$(cat "$banner" 2>/dev/null)'"
    # Six seconds is several backoff slots (1, 2, 4 s), never a storm.
    sleep 6
    attempts="$(count_events '"state":"refused_connections"')"
    [ "$attempts" -ge 2 ] && [ "$attempts" -le 6 ] \
        && ok "B3 connections off: $attempts attempts in the backoff window" \
        || bad "B3 connections off: $attempts attempts in the backoff window (tight loop or gave up)"
    stop_app
    stop_fakephone
}

# --- TLS transport matrix (docs/design/e2ee.md §6; the relay row stays with
# the relay's own checks, the code-equality row rides `pair`) ----------------

# mac_failed_line — the last `session failed:` detail this run's app logged.
mac_failed_line() {
    log show --last 5m --info --style syslog \
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null \
        | grep -o 'session failed: [a-z_-]*' | tail -1
}

# probe_close ×3 — the Mac's Bonjour resolve shape: open a TCP connection and
# close it without sending anything (review R4-b).
probe_close_x3() {
    "$FAKE_PY" - "$PORT" <<'PY'
import socket, sys
for _ in range(3):
    probe = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
    probe.close()
PY
}

check_tls() {
    local line rotated_fp pidA pidB exporters
    clean
    say "TLS: the phone is a TLS-only listener; the matrix (§6) runs against it"
    start_fake || return 1

    # (1) plaintext refused: a plain TCP client never gets a protocol byte.
    out="$(printf '{"t":"hello","v":1,"clientId":"probe","name":"nc"}\n' | nc -w 2 127.0.0.1 "$PORT" 2>/dev/null || true)"
    case "$out" in
        *'"t":"welcome"'*|*'"t":"error"'*|*'"t":"challenge"'*)
            bad "TLS1 plaintext was answered with protocol bytes" ;;
        *) ok "TLS1 a plaintext connection is refused (no welcome) and the session stays dead" ;;
    esac

    # (R4-b) open-and-close probes are quiet: no session events, no pairing
    # prompt, no error log; the next real session still pairs.
    stop_fakephone
    sleep 1
    start_fake || return 1
    probe_close_x3 || { bad "TLS R4-b probes could not connect"; stop_fakephone; return 1; }
    events_have '"state":"open"' \
        && bad "TLS R4-b a probe got a session event" \
        || ok "TLS R4-b aborted connections left no session events"
    events_have '"t":"pair.' \
        && bad "TLS R4-b a probe reached pairing traffic" \
        || ok "TLS R4-b aborted connections never reach pairing"
    if grep -q "session error" "$WORK/fake.err" 2>/dev/null; then
        bad "TLS R4-b the phone logged a session error for the probes"
    else
        ok "TLS R4-b the phone logged nothing at error level"
    fi
    launch --connect "127.0.0.1:$PORT" --quit-after 20
    await_app 20 events_have '"state":"paired"'
    if grep -q '"state":"paired"' "$WORK/events.jsonl"; then
        ok "TLS R4-b the phone stayed healthy: the next real session pairs"
    else
        bad "TLS R4-b no pairing after the aborted probes"
    fi
    stop_app
    stop_fakephone
    sleep 1

    # (7) two sessions, never resumed: every accept is a full TLS 1.3
    # handshake, so each session's exporter hash differs (R3). --connect on
    # both: mDNS discovery could otherwise answer for a phone this rig no
    # longer controls, and the claim is about the two handshakes below.
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 20
    await_app 20 events_have '"state":"auth_ok"'
    pidA="$APP_PID"
    stop_fakephone
    sleep 1
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 9
    await_app 9 events_have '"state":"auth_ok"'
    pidB="$APP_PID"
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "TLS7 the second session completed" || bad "TLS7 no second session"
    exporters="$(log show --last 6m --info --style syslog \
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND (processID == $pidA OR processID == $pidB)" 2>/dev/null \
        | grep -o 'v2 exporter sha256: [0-9a-f]*' | sort -u | wc -l | tr -d ' ')"
    [ "$exporters" -ge 2 ] \
        && ok "TLS7 $exporters distinct exporters over 2 sessions (full handshakes, no resumption)" \
        || bad "TLS7 exporters repeat like a resumed session would ($exporters distinct)"
    stop_app
    stop_fakephone
    sleep 1

    # (3) the phone's cert rotated: the Mac refuses at TLS verify
    # ("certificate changed"), the pin survives (re-pair keeps it, §7), and the
    # person's re-pair restores it.
    FAKE_ARGS="--tls-identity $WORK/rotated-phone.identity" start_fake || return 1
    rotated_fp="$(grep -ho 'fakephone identity fp: [0-9a-f]*' "$WORK/fake.err" "$WORK/fake.log" "$WORK/fake3.log" 2>/dev/null | tail -1 | cut -d' ' -f4)"
    launch --connect "127.0.0.1:$PORT" --quit-after 16
    wait_app
    line="$(mac_failed_line)"
    case "$line" in
        "session failed: pin-mismatch")
            ok "TLS3 rotated phone cert refused (pin-mismatch)" ;;
        *)
            bad "TLS3 expected session failed: pin-mismatch, got: ${line:-nothing}" ;;
    esac
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && bad "TLS3 authenticated with a rotated phone" || ok "TLS3 no auth against the rotated phone"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "TLS3 pairing traffic hit the rotated phone" \
        || ok "TLS3 no pairing traffic under a stale pin"
    [ -f "$HOME/Library/Application Support/PocketDeck-$PROFILE/pins.json" ] \
        && ok "TLS3 the pin record survived the refusal (re-pair keeps it, §7)" \
        || bad "TLS3 the pin record vanished on a refused session"
    stop_app
    stop_fakephone
    sleep 1
    # the person's re-pair step (§7): drop the phone from My Devices and pair
    # again (--reset-pairing clears the Mac's pin + mirror; the phone's own pin
    # of the Mac is untouched and the reconnect lands pinless: the rotated
    # phone's cert becomes the stored pin on welcome).
    FAKE_ARGS="--tls-identity $WORK/rotated-phone.identity" start_fake || return 1
    launch --reset-pairing --connect "127.0.0.1:$PORT" --quit-after 18
    rotated_pinned() {
        events_have '"state":"auth_ok"' && [ -n "$rotated_fp" ] && grep -q "\"phoneFingerprintHex\":\"$rotated_fp\"" \
            "$HOME/Library/Application Support/PocketDeck-$PROFILE/pins.json" 2>/dev/null
    }
    await_app 18 rotated_pinned
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "TLS3 the re-pair reconnect authenticated" \
        || bad "TLS3 the re-pair never reconnected"
    if [ -n "$rotated_fp" ] && grep -q "\"phoneFingerprintHex\":\"$rotated_fp\"" \
            "$HOME/Library/Application Support/PocketDeck-$PROFILE/pins.json" 2>/dev/null; then
        ok "TLS3 the rotated phone's fingerprint is the stored pin now"
    else
        bad "TLS3 the pin store does not hold the rotated phone's fingerprint"
    fi
    stop_app
    stop_fakephone
    sleep 1

    # (2) a v1 phone: `version`, then nothing (the v1 path is gone). A clean
    # slate: the row above left the Mac pinned to the rotated phone.
    clean
    FAKE_ARGS="--legacy-phone" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 14
    wait_app
    line="$(mac_failed_line)"
    case "$line" in
        "session failed: version")
            ok "TLS2 a v1 phone is refused with the version reason" ;;
        *) bad "TLS2 expected session failed: version, got: ${line:-nothing}" ;;
    esac
    stop_app
    stop_fakephone
    sleep 1

    # (4) the MAC's cert rotated: the phone refuses the reconnect with bad_pin
    # ("This Mac's certificate changed; pair again") — the design's refusal
    # row; the un-blocked re-pair (phone-side purge) is out of the matrix.
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 20
    await_app 20 events_have '"state":"auth_ok"'
    grep -q '"state":"paired"' "$WORK/events.jsonl" \
        && ok "TLS4 paired before the Mac rotation" || bad "TLS4 never paired"
    stop_app
    sleep 1
    "$FAKE_PY" - "$WORK/macrot.identity" "$HOME/Library/Application Support/PocketDeck-$PROFILE/identity.json" <<'PY'
import json, os, subprocess, sys
identity_dir, identity_file = sys.argv[1], sys.argv[2]
os.makedirs(identity_dir, exist_ok=True)
key = os.path.join(identity_dir, "key.pem")
cert = os.path.join(identity_dir, "cert.pem")
subprocess.run(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey",
                "-noout", "-out", key], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["/usr/bin/openssl", "req", "-new", "-x509", "-key", key, "-days", "366",
                "-subj", "/CN=PocketDeck rotated", "-out", cert], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.chmod(key, 0o600)
der = subprocess.run(["/usr/bin/openssl", "pkcs8", "-topk8", "-nocrypt", "-in", key],
                     check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode()
pem = subprocess.run(["/usr/bin/openssl", "x509", "-in", cert],
                     check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode()
with open(identity_file) as fp:
    identity = json.load(fp)
# The stored shapes are FULL PEM text (CryptoKit's pemRepresentation), key first
# written 0600 by the atomic save below; keep the §3 fields exactly.
identity["certPem"] = pem
identity["keyP8"] = der
tmp = identity_file + ".tmp"
with open(tmp, "w") as fp:
    json.dump(identity, fp)
os.chmod(tmp, 0o600)
os.replace(tmp, identity_file)
PY
    : > "$WORK/events.jsonl"
    launch --quit-after 16
    wait_app
    line="$(mac_failed_line)"
    case "$line" in
        "session failed: bad_pin")
            ok "TLS4 rotated Mac cert refused by the phone (bad_pin)" ;;
        *) bad "TLS4 expected session failed: bad_pin, got: ${line:-nothing}" ;;
    esac
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && bad "TLS4 authenticated with a rotated Mac cert" || ok "TLS4 no auth with the rotated Mac cert"
    stop_app
    stop_fakephone

    # (8) log hygiene: no key material, no exporter bytes, no secrets in any
    # log this run produced (R3 hygiene; hashes and fingerprints are allowed).
    if grep -IHnE 'BEGIN [A-Z ]*PRIVATE|-----BEGIN CERTIFICATE|EXPORTER_SECRET|exportKeyingMaterial|pocketdeck-memory-only' "$WORK/app.log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null | grep -q .; then
        bad "TLS8 key material in a log"
    else
        ok "TLS8 no key material, exporter bytes or secrets in any log"
    fi
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- C5: rendering --------------------------------------------------------

check_render() {
    begin_shared || return 1
    open_shared --open com.android.settings --open-phone --float-windows || return 1
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
    begin_shared || return 1
    # The video's pixels are the window's points at the run's backing scale
    # (VideoGeometry.displayPixels), so each pt size below is the pixel size
    # these assertions have always named, divided by that scale: at 1x the
    # window is twice as big in points and the phone sees what it saw at 2x.
    # The cap case asks for more than 2560 pt at 1x so the 2560 px cap stays in
    # play; a window bigger than the display has to be possible for any of this
    # to mean anything, and the app sets frames rather than dragging them.
    local scale="$RUN_SCALE" w h
    w=$((1600 / scale)); h=$((1200 / scale))
    open_shared --open com.android.settings --resize-stream "1:${w}x${h}-pt" || return 1
    # The window is wxh pt and the video is all of it.
    wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":1600,"h":1200' \
        && ok "C6 new video config 1600x1200 (the whole ${w}x${h} pt window, at ${scale}x)" || bad "C6 no new config"
    events_have '"t":"window.resize"' \
        && ok "C6 window.resize sent" || bad "C6 no window.resize"
    screenshot "$w" "$WORK/resize.png" && say "screenshot: $WORK/resize.png"
    stop_app

    # Non-16:9 shapes: tall, then ultra-wide (capped at 2560 px, aspect kept).
    w=$((1200 / scale)); h=$((1800 / scale))
    if [ "${PD_E2E_TALL_SCREEN:-1}" = "0" ]; then
        # The VM's display cannot host this window: at 2x its guest offers no
        # mode with 952 pt of visible height (the VM screen is small and a
        # headless boot keeps the guest's own mode). A 1x screen would need
        # 1800 pt, and every other size here is written for 2x.
        skip "C6 the tall shape" "no 2x mode on this screen has 952 pt of visible height, so a ${w}x${h} pt window would be clamped"
    else
        open_shared --open com.android.settings --resize-stream "1:${w}x${h}-pt" || return 1
        if wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":1200,"h":1792'; then
            ok "C6 tall shape resized to 1200x1792 (${w}x${h} pt at ${scale}x, floored to 16)"
        else
            bad "C6 no tall config (last video $(last_video_size))"
        fi
        screenshot "$w" "$WORK/resize-tall.png" && say "screenshot: $WORK/resize-tall.png"
        stop_app
    fi

    w=$((3200 / scale)); h=$((1000 / scale))
    open_shared --open com.android.settings --resize-stream "1:${w}x${h}-pt" || return 1
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

    # --- Live resize: the old frame fills the window until the answer ---
    # A fresh phone holds its VIDEO_CONFIG back for a moment after
    # window.resize (--resize-delay-ms). The app asks 2 s after the window
    # opens, so the window keeps the old frame in its new shape: while the
    # answer is pending the frame is cropped to fill it (no black bars), and
    # the answer's own frame is the normal rule again. The screenshots are
    # taken within the 2 s fill timeout (VideoLayerView.resizeFillTimeout).
    end_shared
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--resize-delay-ms 4000" start_fake || return 1
    FAKE_ARGS=""
    launch_shared --connect "127.0.0.1:$PORT" || return 1
    local fw=640 fh=640 bar=28 edges win ew eh
    ew=$((fw * scale / 16 * 16)); eh=$((fh * scale / 16 * 16))
    open_shared --open com.android.settings --float-windows \
        --resize-stream "1:${fw}x${fh}-pt" || return 1
    wait_until 30 events_have '"ev":"video","stream":1,"config":true' \
        || bad "C6 live resize: no first video config"
    if win="$(await_window "\$4 == $fw")" && shot_window "$win" "$WORK/resize-fill.png"; then
        # The screenshot is taken as the window takes its new shape (inside
        # the 2 s fill timeout); the phone's held answer comes 0.3 s later.
        wait_until 5 events_have '"ev":"resize","held":true' \
            && ok "C6 live resize: the phone held its answer (no config at the new size yet)" \
            || bad "C6 live resize: the phone did not hold the resize answer"
        edges="$(edge_kinds "$WORK/resize-fill.png" "$fw" $((fh + bar)) "$bar")"
        [ "$edges" = "left=stream right=stream bottom=stream top=stream" ] \
            && ok "C6 live resize: the last frame fills the window, no black bars while the answer is held ($edges)" \
            || bad "C6 live resize: bars while the answer is held ($edges)"
        say "screenshot: $WORK/resize-fill.png"
    else
        bad "C6 live resize: no window ${fw} pt wide to capture"
    fi
    wait_until 30 events_have "\"ev\":\"video\",\"stream\":1,\"config\":true,\"w\":${ew},\"h\":${eh}" \
        || bad "C6 live resize: no answer at ${ew}x${eh} (last video $(last_video_size))"
    local tries=12
    while [ "$tries" -gt 0 ]; do
        shot_window "$win" "$WORK/resize-fill-done.png" || break
        edges="$(edge_kinds "$WORK/resize-fill-done.png" "$fw" $((fh + bar)) "$bar")"
        [ "$edges" = "left=stream right=stream bottom=stream top=stream" ] && break
        sleep 0.25
        tries=$((tries - 1))
    done
    [ "$edges" = "left=stream right=stream bottom=stream top=stream" ] \
        && ok "C6 live resize: after the answer the picture is the settled one ($edges)" \
        || bad "C6 live resize: after the answer ($edges)"
    say "screenshot: $WORK/resize-fill-done.png"

    # The phone window mirrors the phone's own screen: no fill, no crop, and
    # the bar above it mirrors the screen's top rows (never a black gap).
    next_shared
    open_shared --open-phone --float-windows || return 1
    wait_until 30 events_have '"ev":"video","stream":1,"config":true' \
        || bad "C6 phone window: no video config"
    local pw ph
    read -r win _ _ pw ph <<< "$(windows | awk '$5 > $4 {print; exit}')"
    if [ -n "${win:-}" ] && shot_window "$win" "$WORK/resize-phone.png"; then
        edges="$(edge_kinds "$WORK/resize-phone.png" "$pw" "$ph" "$bar")"
        case "$edges" in
            *"top=black"*) bad "C6 phone window: black under the bar ($edges)" ;;
            *) ok "C6 phone window: the mirror's letterbox is unchanged, no black under the bar ($edges)" ;;
        esac
        say "screenshot: $WORK/resize-phone.png"
    else
        bad "C6 phone window: no portrait window to capture"
    fi
    # The delayed phone must not serve the next check in a shared run.
    end_shared
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
    begin_shared || return 1
    printf '%s\n' "click 0.5 0.5" "drag 0.5 0.5 0.7 0.5" "scroll 3" "scroll -2" "type hi" \
        "rightclick 0.5 0.5" > "$WORK/input.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/input.txt" || return 1
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

# --- Hover ----------------------------------------------------------------

# hv_hover_count <action> — how many hover frames of that action the fakephone
# received on stream 1 (0 enter, 1 move, 2 exit).
hv_hover_count() {
    local n
    n="$(grep -c "\"kind\":\"hover\",\"stream\":1,\"action\":$1," "$WORK/events.jsonl" 2>/dev/null || true)"
    echo "${n:-0}"
}

# check_hover — the Mac pointer over the video is a mouse hovering Android:
# HOVER (0x13) becomes ACTION_HOVER_ENTER/MOVE/EXIT. Moving in enters and
# moves, leaving the video exits, a click sends the exit before its touch
# DOWN and the next move enters again after the release, and Settings ▸ Input
# "Hover over Android apps" off sends no hover at all. Scripted only: the
# driver delivers the moves to the view, so no pointer, focus or window
# position is involved (a real-pointer variant would be visible-only).
check_hover() {
    begin_shared || return 1
    rm -f "$WORK"/hv-*
    cat > "$WORK/hover.txt" <<SCRIPT
hover 0.5 0.5
waitfile $WORK/hv-enter
hover 0.55 0.5
wait 0.03
hover 0.6 0.5
wait 0.03
hover 0.65 0.45
wait 0.03
hover 0.7 0.4
waitfile $WORK/hv-out
hoverout
waitfile $WORK/hv-click
click 0.5 0.5
waitfile $WORK/hv-again
hover 0.5 0.5
waitfile $WORK/hv-off
hoversetting off
waitfile $WORK/hv-moves
hover 0.3 0.3
hover 0.7 0.7
hover 0.9 0.9
wait 0.6
SCRIPT
    open_shared --open com.android.settings --debug-input-script "$WORK/hover.txt" || return 1
    wait_until 30 eval '[ "$(hv_hover_count 0)" -ge 1 ]' \
        || { bad "HV the pointer over the video sent no hover enter"; say "app log: $(tail -3 "$WORK/app.log")"; }

    # Enter carries the point in video coordinates.
    python3 - "$WORK/events.jsonl" <<'PY' && ok "HV enter at the point the pointer is over" \
        || bad "HV enter has the wrong coordinates"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if '"kind":"hover","stream":1,"action":0' in l]
e = rows[0]
sys.exit(0 if abs(e["nx"] - 0.5) <= 0.03 and abs(e["ny"] - 0.5) <= 0.03 else 1)
PY
    touch "$WORK/hv-enter"

    wait_until 10 eval '[ "$(hv_hover_count 1)" -ge 1 ]' \
        && ok "HV moves follow the enter ($(hv_hover_count 1))" \
        || bad "HV no hover move reached the phone"
    touch "$WORK/hv-out"

    wait_until 10 eval '[ "$(hv_hover_count 2)" -ge 1 ]' \
        && ok "HV leaving the video sends the exit" \
        || bad "HV no hover exit after hoverout"
    touch "$WORK/hv-click"

    wait_until 10 eval '[ "$(grep -c "\"kind\":\"touch\",\"stream\":1,\"action\":0" "$WORK/events.jsonl")" -ge 1 ]' \
        && ok "HV a click still sends its touch down" \
        || bad "HV the click made no touch down"
    touch "$WORK/hv-again"

    wait_until 10 eval '[ "$(hv_hover_count 0)" -ge 2 ]' \
        && ok "HV the next move after the release enters again" \
        || bad "HV no second enter after the click"

    # Order: the exit precedes the click's DOWN, the UP precedes the re-enter.
    python3 - "$WORK/events.jsonl" <<'PY' && ok "HV exit before the touch DOWN, enter again after the UP" \
        || bad "HV hover and touch order is wrong"
import json, sys
rows = []
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") != "input" or e.get("stream") != 1:
        continue
    if e.get("kind") == "hover":
        rows.append(("hover", e["action"]))
    elif e.get("kind") == "touch":
        rows.append(("touch", e["action"]))
down = next(i for i, r in enumerate(rows) if r == ("touch", 0))
up = next(i for i, r in enumerate(rows) if r == ("touch", 1))
exit_before_down = any(r == ("hover", 2) for r in rows[:down])
enter_after_up = any(r == ("hover", 0) for r in rows[up + 1:])
sys.exit(0 if exit_before_down and enter_after_up else 1)
PY

    # Rate: at most one move per 16 ms (62/s); the Mac coalesces, so no two
    # received moves are closer than a frame.
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
moves = []
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "input" and e.get("kind") == "hover" and e.get("stream") == 1 and e.get("action") == 1:
        moves.append(e["ts"])
if not moves:
    print("no moves"); sys.exit(0)
gaps = [b - a for a, b in zip(moves, moves[1:])]
span = max(moves) - min(moves)
rate = (len(moves) - 1) / span if span > 0 else 0.0
ok = (not gaps or min(gaps) >= 0.012) and rate <= 62.0
print("%s %d moves, min gap %.1f ms, %.1f/s" %
      ("ok" if ok else "bad", len(moves), (min(gaps) * 1000) if gaps else 0.0, rate))
sys.exit(0 if ok else 1)
PY
    [ $? -eq 0 ] && ok "HV the move rate is held to one per frame" || bad "HV the move rate is too high"

    # Setting off: the moves after it send nothing at all. The script turns it
    # off after hv-off and only moves after hv-moves, so the count in between
    # is the baseline.
    local before after
    touch "$WORK/hv-off"
    sleep 1.0
    before="$(grep -c '"kind":"hover"' "$WORK/events.jsonl" 2>/dev/null || true)"
    touch "$WORK/hv-moves"
    sleep 1.5
    after="$(grep -c '"kind":"hover"' "$WORK/events.jsonl" 2>/dev/null || true)"
    [ "${after:-0}" = "${before:-0}" ] \
        && ok "HV the setting off sends no hover (${after:-0} frames before and after)" \
        || bad "HV the setting off still sent $((after - before)) hover frames"

    stop_app
}


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
    begin_shared || return 1

    # Phase A: an app window (the only stream window -> stream 1). Floated, so a
    # visible run's real press lands on it and not on the Deck.
    rm -f "$WORK"/mb-step-*
    printf '%s\n' "sidebutton 3" "waitfile $WORK/mb-step-forward" "sidebutton 4" \
        "waitfile $WORK/mb-step-held" "sidebutton 3 0.4 80 6 12" \
        "waitfile $WORK/mb-step-key" "key cmd+[" > "$WORK/mb-a.txt"
    open_shared --open com.android.settings --float-windows --debug-input-script "$WORK/mb-a.txt" || return 1
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
    # Phase B: the phone-mode window (also a stream window -> stream 1 again).
    next_shared
    printf '%s\n' "sidebutton 3" > "$WORK/mb-b.txt"
    open_shared --open-phone --float-windows --debug-input-script "$WORK/mb-b.txt" || return 1
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
}

# --- C13: pinch / rotate gestures ------------------------------------------
# check_pinch — trackpad pinch and rotate are synthesized as a two-pointer
# TOUCH sequence: down(0), down(1), coalesced moves, up(1), up(0). The pair's
# distance follows the pinch scale, its pixel-space angle follows the rotation;
# the right click at the end of the script says the whole script was delivered.
#
# The script leads with "wait 1.5": right after launch the opening app's stream
# window is key, then the deck and the pairing sheet take it back in turn — a
# key change mid-gesture cancels the gesture by design, and a script armed on
# the video-size note starts inside that churn. C15's scripts wait for the same
# reason; the gestures land the same either way, just after the windows settle.
check_pinch() {
    begin_shared || return 1
    printf '%s\n' "wait 1.5" "pinch 0.5 0.5 1.5" "pinch 0.5 0.5 0.6" \
        "rotate 0.5 0.5 90" "rightclick 0.5 0.5" > "$WORK/pinch.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/pinch.txt" || return 1
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
# "style=framed|immersive lights=shown|hidden pill=shown|hidden
#  title_visible=yes|no lights_managed=us|appkit fullscreen=yes|no clicks=N"
# (N = clicks that reached the bar or the pill; in native full screen the
# system's titlebar shows the title and places the lights).
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

# edge_kinds <png> <w-pt> <h-pt> <bar-pt> — the window's own pixels just inside
# its left, right, bottom and (just under the bar) top edges, as "left=… right=…
# bottom=… top=…" with each "backdrop", "black" or "stream". <h-pt> is the whole
# window, bar included; <bar-pt> is the framed bar's height (0 without one).
# Black is the video layer's own letterbox (the live-resize fill's opposite).
edge_kinds() {
    python3 - "$@" <<'PY'
import subprocess, sys
path, wpt, hpt, barpt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
size = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
                      capture_output=True, text=True).stdout.strip().split(",")
w, h = int(size[0]), int(size[1])
scale = w / wpt
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     capture_output=True).stdout
def kind(x, y):
    i = (int(y) * w + int(x)) * 3
    r, g, b = raw[i], raw[i + 1], raw[i + 2]
    # The backdrop is (46, 115, 217); the samples avoid the patterns' dark bars.
    if b > 170 and r < 110 and g < 160:
        return "backdrop"
    if max(r, g, b) < 40:
        return "black"
    return "stream"
mid = (barpt + (hpt - barpt) / 2) * scale
print("left=%s right=%s bottom=%s top=%s" % (
    kind(2 * scale, mid), kind(w - 2 * scale - 1, mid),
    kind(w / 10, h - 2 * scale - 1), kind(w / 10, (barpt + 2) * scale)))
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
    begin_shared || return 1
    rm -f "$WORK/chrome.txt"
    local on_virtual=()
    [ "$VISIBLE" = "1" ] || on_virtual=(--virtual)
    "$CGBIN" backdrop --file "$WORK/backdrop.txt" --seconds 120 ${on_virtual[@]+"${on_virtual[@]}"} &
    local backdrop=$!
    # The stream's video pixels: 900x600 pt at the run's backing scale, floored
    # to 16 (VideoGeometry.displayPixels) — 1792x1200 in a 2x run, the one size
    # the phone is told and the display keeps through every style and switch.
    local wake hake
    wake=$((900 * RUN_SCALE / 16 * 16)); hake=$((600 * RUN_SCALE / 16 * 16))

    # --- Framed: the permanent bar over the stream ---
    # The pointer rests in the window, below the bar.
    printf '%s\n' "hoverat 0 200" > "$WORK/chrome-framed.txt"
    open_shared --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-framed.txt" \
        || { kill "$backdrop"; return 1; }
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
    next_shared
    # The script waits for the check's go before clicking the pill's minimise light.
    rm -f "$WORK/chrome-step-minimise"
    # In a VM the scripted click is an in-app NSEvent pair that the window server
    # never sees, so the Dock's minimise animation freezes on its first frame.
    # Visible runs click through the window server instead; quiet runs keep the
    # scripted click, which is what the host's reference run exercises.
    if [ "$VISIBLE" = "1" ]; then
        printf '%s\n' "wait 0.6" "windowstyle toggle" "wait 4" \
            "hover 0.02 0.03" "wait 0.15" "click 0.02 0.03" "wait 1.2" \
            "waitfile $WORK/chrome-step-minimise" "wait 8" > "$WORK/chrome-immersive.txt"
    else
        printf '%s\n' "wait 0.6" "windowstyle toggle" "wait 4" \
            "hover 0.02 0.03" "wait 0.15" "click 0.02 0.03" "wait 1.2" \
            "waitfile $WORK/chrome-step-minimise" "clickat -406 20" "wait 8" > "$WORK/chrome-immersive.txt"
    fi
    open_shared --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-immersive.txt" \
        || { kill "$backdrop"; return 1; }
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
    # event dispatch to the light. Visible runs send it as a real click so the
    # window server (and the Dock's animation) sees it.
    touch "$WORK/chrome-step-minimise"
    if [ "$VISIBLE" = "1" ]; then
        cg_input click --window "$win" --dx -406 --top 20
    fi
    sleep 1
    window_gone "$win" \
        && ok "C14 a click on the pill's minimise light minimised the window" \
        || bad "C14 the minimise light click did not minimise (window is still listed)"
    [ "$(count_events '"kind":"touch","stream":1,"action":0')" -eq "$touches" ] \
        && ok "C14 and no touch reached the phone from the chrome" \
        || bad "C14 the chrome's click reached the phone as touch"
    next_shared

    # --- Switching with ⌥⌘F, near the top of the screen ---
    rm -f "$WORK/chrome-step-top"
    printf '%s\n' "wait 0.6" "click 0.5 0.5" "wait 0.8" "key opt+cmd+f" \
        "waitfile $WORK/chrome-step-top" "windowtop" "wait 9" \
        "key opt+cmd+f" "wait 3" "key opt+cmd+f" "wait 3" "key opt+cmd+f" "wait 8" > "$WORK/chrome-switch.txt"
    open_shared --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-switch.txt" \
        || { kill "$backdrop"; return 1; }
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

    # --- C2: native full screen ---
    # The bar macOS reveals at the top edge is the system's: the window's title
    # and the standard traffic lights in their standard place, in both styles;
    # the stream stays full-bleed under it. Entering full screen switches the
    # Space, which only a visible run can do (the quiet run's virtual display
    # has none), so this is a VISIBLE-only step.
    if [ "$VISIBLE" = "1" ]; then
        next_shared
        rm -f "$WORK/c2-step-framed" "$WORK/c2-step-exit-framed" \
            "$WORK/c2-step-immersive" "$WORK/c2-step-exit-immersive"
        printf '%s\n' "wait 1" "windowstyle framed" "wait 1" "fullscreen" "wait 6" \
            "waitfile $WORK/c2-step-framed 60" "fullscreen" "wait 6" \
            "waitfile $WORK/c2-step-exit-framed 60" "windowstyle immersive" "wait 2" "fullscreen" "wait 6" \
            "waitfile $WORK/c2-step-immersive 60" "fullscreen" "wait 6" \
            "waitfile $WORK/c2-step-exit-immersive 60" "wait 10" > "$WORK/chrome-fullscreen.txt"
        open_shared --open com.android.settings \
            --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-fullscreen.txt" \
            || { kill "$backdrop"; return 1; }
        win="$(await_window '$4 == 900 && $5 == 628')" \
            || { bad "C2 no framed window before full screen"; kill "$backdrop"; return 1; }

        local full
        full="$(await_window '$4 > 900 && $5 > 628')" \
            && ok "C2 framed full screen fills the screen ($(windows | awk -v i="$full" '$1 == i {print $4 "x" $5}'))" \
            || bad "C2 framed full screen: the window did not fill the screen"
        wait_until 15 chrome_is "style=framed lights=shown pill=hidden title_visible=yes lights_managed=appkit fullscreen=yes" \
            && ok "C2 framed full screen: the revealed bar shows the title and the standard lights ($(chrome_state))" \
            || bad "C2 framed full screen: $(chrome_state)"
        # The system's bar only slides down when the pointer reaches the top
        # edge; look at it there.
        cg_input move --window "$full" --top 0
        sleep 1
        screencapture -x "$WORK/chrome-fullscreen-framed.png" && say "screenshot: $WORK/chrome-fullscreen-framed.png"
        touch "$WORK/c2-step-framed"

        win="$(await_window '$4 == 900 && $5 == 628')" \
            && ok "C2 leaving framed full screen restores the 900x628 window" \
            || bad "C2 leaving framed full screen: $(windows | awk '$4 == 900 {print $4 "x" $5}')"
        wait_until 15 chrome_is "style=framed lights=shown pill=hidden title_visible=no lights_managed=us fullscreen=no" \
            && ok "C2 and the framed bar's lights come back, title hidden ($(chrome_state))" \
            || bad "C2 after framed full screen: $(chrome_state)"
        touch "$WORK/c2-step-exit-framed"

        win="$(await_window '$4 == 900 && $5 == 600')" \
            && ok "C2 the style switch after full screen took the bar away (900x600)" \
            || bad "C2 immersive after full screen: $(windows | awk '$4 == 900 {print $4 "x" $5}')"
        full="$(await_window '$4 > 900 && $5 > 600')" \
            && ok "C2 immersive full screen fills the screen ($(windows | awk -v i="$full" '$1 == i {print $4 "x" $5}'))" \
            || bad "C2 immersive full screen: the window did not fill the screen"
        wait_until 15 chrome_is "style=immersive lights=shown pill=hidden title_visible=yes lights_managed=appkit fullscreen=yes" \
            && ok "C2 immersive full screen: the revealed bar shows the title and the standard lights ($(chrome_state))" \
            || bad "C2 immersive full screen: $(chrome_state)"
        cg_input move --window "$full" --top 0
        sleep 1
        screencapture -x "$WORK/chrome-fullscreen-immersive.png" && say "screenshot: $WORK/chrome-fullscreen-immersive.png"
        touch "$WORK/c2-step-immersive"

        win="$(await_window '$4 == 900 && $5 == 600')" \
            && ok "C2 leaving immersive full screen restores the 900x600 window" \
            || bad "C2 leaving immersive full screen: $(windows | awk '$4 == 900 {print $4 "x" $5}')"
        wait_until 15 chrome_is "style=immersive lights=hidden pill=hidden title_visible=no lights_managed=us fullscreen=no" \
            && ok "C2 and immersive is back at rest: no lights, no pill, title hidden ($(chrome_state))" \
            || bad "C2 after immersive full screen: $(chrome_state)"
        touch "$WORK/c2-step-exit-immersive"
        # Leave the pointer where it was, not on the screen's top edge.
        cg_input move --window "$win" --dx 0 --dy 0
    else
        skip_visible "C2 native full screen (a real Space switch)"
    fi

    kill "$backdrop" 2>/dev/null; wait "$backdrop" 2>/dev/null
    stop_app
    stop_fakephone
}

# --- MENUS: the View and Window menus (menu-polish) -------------------------

# check_menus — the View menu has no section titles and no full-screen item;
# Framed/Immersive are plain radio items; the Window menu owns the only full
# screen item (🌐F); every item the app draws itself has an SF Symbol. The
# window's Enter/Exit title needs native full screen (a real Space), so that
# step is visible-only.
check_menus() {
    begin_shared || return 1
    rm -f "$WORK/menus.json" "$WORK/menus-step-full" "$WORK/menus-step-exit" "$WORK/menus-full.json" \
        "$WORK/menus-step-touch" "$WORK/menus-touch.png" "$WORK/chrome.txt"
    printf '%s\n' "wait 1.5" "menudump $WORK/menus.json" \
        "showtouches on" "wait 1" "hover 0.5 0.5" "wait 0.3" \
        "waitfile $WORK/menus-step-touch 60" "fingerpinch 0.5 0.01 1.25 4" "wait 1" \
        "waitfile $WORK/menus-step-full 60" "fullscreen" "wait 6" \
        "menudump $WORK/menus-full.json" \
        "waitfile $WORK/menus-step-exit 60" "fullscreen" "wait 6" > "$WORK/menus.txt"
    open_shared --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
        --debug-input-script "$WORK/menus.txt" || return 1
    wait_until 20 [ -s "$WORK/menus.json" ] || {
        bad "MENUS no menu dump in 20 s ($WORK/menus.json)"
        say "app log: $(tail -3 "$WORK/app.log")"
        stop_app; stop_fakephone; return 1
    }

    # The View menu, top to bottom: the design's items, nothing else — no
    # section title (the old Picker's "Window Style" header) and no full-screen
    # item. Separators are shown as —.
    python3 - "$WORK/menus.json" <<'PY' && ok "MENUS View menu is exactly the design's items, no section titles" \
        || bad "MENUS View menu is not the design"
import json, sys
root = json.load(open(sys.argv[1]))
view = next((i for i in root["items"] if i["title"] == "View"), None)
if view is None:
    print("no View menu"); sys.exit(1)
seq = ["—" if item["isSeparator"] else item["title"] for item in view["submenu"]]
want = ["Find Apps", "Phone Window", "Continue on Mac", "—", "Show Touches", "Live Text", "—",
        "Framed", "Immersive", "—", "Density", "Toggle Window Style"]
if seq != want:
    print("View:", seq, "wanted:", want); sys.exit(1)
PY

    python3 - "$WORK/menus.json" <<'PY' && ok "MENUS no section title and no full-screen item in View" \
        || bad "MENUS View still carries a section title or a full-screen item"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
titles = [item["title"] for item in view["submenu"]]
if "Window Style" in titles:
    print("the Window Style section title is still there"); sys.exit(1)
if any("Full Screen" in title for title in titles):
    print("a full-screen item is in View:", titles); sys.exit(1)
PY

    python3 - "$WORK/menus.json" <<'PY' && ok "MENUS Framed/Immersive are radio items with exactly one checked" \
        || bad "MENUS the style radios are wrong"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
framed, immersive = by_title.get("Framed"), by_title.get("Immersive")
if not framed or not immersive:
    print("Framed/Immersive missing"); sys.exit(1)
if sorted([framed["state"], immersive["state"]]) != ["off", "on"]:
    print("states:", framed["state"], immersive["state"]); sys.exit(1)
if framed["hasImage"] or immersive["hasImage"]:
    print("a radio item carries an icon"); sys.exit(1)
PY

    # The Window menu's own full-screen item, and the only one in the tree.
    python3 - "$WORK/menus.json" <<'PY' && ok "MENUS Window holds the only full-screen item, Enter Full Screen 🌐F" \
        || bad "MENUS the Window menu's full-screen item is wrong"
import json, sys
def walk(items):
    for item in items:
        yield item
        if item.get("submenu"):
            yield from walk(item["submenu"])
root = json.load(open(sys.argv[1]))
window = next((i for i in root["items"] if i["title"] == "Window"), None)
if window is None:
    print("no Window menu"); sys.exit(1)
in_window = [i for i in window["submenu"] if "Full Screen" in i["title"]]
if len(in_window) != 1:
    print("Window full-screen items:", [i["title"] for i in in_window]); sys.exit(1)
item = in_window[0]
if item["title"] != "Enter Full Screen":
    print("title:", item["title"]); sys.exit(1)
if item["keyEquivalent"] != "f" or item["modifiers"] != ["function"]:
    print("shortcut:", repr(item["keyEquivalent"]), item["modifiers"]); sys.exit(1)
everywhere = [i for i in walk(root["items"]) if "Full Screen" in i["title"]]
if len(everywhere) != 1:
    print("full-screen items in the tree:", [i["title"] for i in everywhere]); sys.exit(1)
PY

    # The app's own items carry SF Symbols (the system's items stay as AppKit
    # draws them and are not in this list).
    python3 - "$WORK/menus.json" <<'PY' && ok "MENUS every item the app draws has an SF Symbol" \
        || bad "MENUS an app item is missing its icon"
import json, sys
def walk(items):
    for item in items:
        yield item
        if item.get("submenu"):
            yield from walk(item["submenu"])
root = json.load(open(sys.argv[1]))
items = list(walk(root["items"]))
missing = []
for title in ["Add Phone…", "Find Apps", "Phone Window", "Continue on Mac", "Show Touches",
              "Live Text", "Density", "Toggle Window Style", "Back", "Home", "Recents",
              "Enter Full Screen"]:
    found = next((i for i in items if i["title"] == title), None)
    if found is None:
        missing.append(title + " (missing)")
    elif not found["hasImage"]:
        missing.append(title)
if missing:
    print("no image:", missing); sys.exit(1)
PY

    # The Show Touches dots are drawn outside the view the bar mirrors.
    wait_until 10 eval 'grep -q "dots=outside" "$WORK/chrome.txt" 2>/dev/null' \
        && ok "MENUS the Show Touches dots are outside the bar's mirror ($(chrome_state))" \
        || bad "MENUS the dot layer is still inside the mirrored content: $(chrome_state)"

    # Show Touches on, the pointer hovering the video and a trackpad touch at
    # the stream's top edge: the bar above it must stay clean. The driver's
    # fingers are scripted, so a quiet run captures the same thing (the
    # capture is of the window, on this run's display).
    touch "$WORK/menus-step-touch"
    sleep 1.5
    local win
    win="$(await_window '$4 == 900 && $5 == 628')" \
        && screencapture -x -o -l"$win" "$WORK/menus-touch.png" \
        && ok "MENUS captured the bar with Show Touches on: $WORK/menus-touch.png" \
        || bad "MENUS no window to capture the bar"
    grep -q "touches=on" "$WORK/chrome.txt" 2>/dev/null \
        && grep -qE "dot_count=[1-9]" "$WORK/chrome.txt" 2>/dev/null \
        && ok "MENUS the dots are drawn while the fingers are down ($(chrome_state))" \
        || bad "MENUS no touch dots during the pinch: $(chrome_state)"
    sleep 4

    if [ "$VISIBLE" = "1" ]; then
        touch "$WORK/menus-step-full"
        wait_until 20 [ -s "$WORK/menus-full.json" ] || {
            bad "MENUS no second dump after entering full screen"
            stop_app; stop_fakephone; return 1
        }
        python3 - "$WORK/menus-full.json" <<'PY' && ok "MENUS in full screen the Window item reads Exit Full Screen, still the only one" \
            || bad "MENUS the full-screen title did not follow the key window"
import json, sys
def walk(items):
    for item in items:
        yield item
        if item.get("submenu"):
            yield from walk(item["submenu"])
root = json.load(open(sys.argv[1]))
everywhere = [i for i in walk(root["items"]) if "Full Screen" in i["title"]]
if len(everywhere) != 1:
    print("full-screen items:", [i["title"] for i in everywhere]); sys.exit(1)
item = everywhere[0]
if item["title"] != "Exit Full Screen":
    print("title:", item["title"]); sys.exit(1)
if item["keyEquivalent"] != "f" or item["modifiers"] != ["function"]:
    print("shortcut:", repr(item["keyEquivalent"]), item["modifiers"]); sys.exit(1)
PY
        # Leave full screen; the next checks share this app.
        touch "$WORK/menus-step-exit"
        sleep 7
    else
        skip_visible "MENUS the Exit Full Screen title (native full screen needs a real Space)"
    fi
    stop_app
    stop_fakephone
}

# --- C16: density ----------------------------------------------------------

# The dpi the phone last got for a stream (its window.open or window.resize).
stream_dpi() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys

last = None
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if msg.get("t") in ("window.open", "window.resize") and msg.get("stream") == int(sys.argv[2]):
        last = msg.get("dpi")
print(last if last is not None else "none")
PY
}

# stream_dpi_is STREAM DPI — for wait_until (a plain [ ] would evaluate its
# command substitution once, before the app had a chance to resize).
stream_dpi_is() { [ "$(stream_dpi "$1")" = "$2" ]; }

# density_stored_is PACKAGE VALUE — the stored override, for wait_until.
density_stored_is() {
    [ "$(defaults read "$DEFAULTS_SUITE" "chrome.density.$1" 2>/dev/null)" = "$2" ]
}

# check_density — View ▸ Density (WindowDensity.swift): an app's override
# changes the dpi the phone gets for that app's windows (160 × backing scale ×
# density, over the window's 900x600 pt stream quantised to 16 px) and leaves
# another app's windows alone; "Default" clears it and the window follows
# Settings → General again. The choice lands under chrome.density.<package>
# (the style store's scheme), and the profile reset forgets it.
check_density() {
    begin_shared || return 1
    # The app's dpi: 160 × the quantised video width / the 900 pt stream, at
    # the run's backing scale (VideoGeometry.dpi).
    local pw base high
    pw=$((900 * RUN_SCALE / 16 * 16))
    base=$(python3 -c "print(int(160 * $pw / 900 + 0.5))")
    high=$(python3 -c "print(int(160 * $pw / 900 * 1.25 + 0.5))")
    rm -f "$WORK/density-step-restore"
    printf '%s\n' "wait 0.8" "density com.android.settings 125" \
        "waitfile $WORK/density-step-restore 60" \
        "density com.android.settings default" "wait 6" > "$WORK/density.txt"
    open_shared --open com.android.settings,com.whatsapp --debug-input-script "$WORK/density.txt" || return 1
    wait_until 30 events_have '"ev":"video","stream":2,' \
        || { bad "C16 no video for the second app's window"; stop_app; stop_fakephone; return 1; }

    wait_until 20 stream_dpi_is 1 "$high" \
        && ok "C16 View ▸ Density 125% took the settings window's dpi to $high" \
        || bad "C16 settings window dpi: $(stream_dpi 1) (wanted $high)"
    [ "$(stream_dpi 2)" = "$base" ] \
        && ok "C16 the other app's window kept its dpi ($base)" \
        || bad "C16 the other app's window followed: $(stream_dpi 2) (wanted $base)"
    python3 - "$WORK/events.jsonl" "$base" <<'PY' && ok "C16 and was never resized for the override" \
        || bad "C16 the other app's window saw a density resize"
import json, sys

base, seen = int(sys.argv[2]), False
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if msg.get("t") in ("window.open", "window.resize") and msg.get("stream") == 2:
        seen = True
        if msg.get("dpi") != base:
            sys.exit(1)
sys.exit(0 if seen else 1)
PY
    [ "$(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>/dev/null)" = "1.25" ] \
        && ok "C16 the override is stored under the package's key" \
        || bad "C16 the stored key: $(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>&1)"

    touch "$WORK/density-step-restore"
    wait_until 20 stream_dpi_is 1 "$base" \
        && ok "C16 Default cleared the override: the window is back at $base" \
        || bad "C16 after Default the window's dpi is $(stream_dpi 1) (wanted $base)"
    if defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" >/dev/null 2>&1; then
        bad "C16 Default left the stored override behind"
    else
        ok "C16 Default removed the stored override"
    fi

    # The profile reset (--debug-control reset prefs) forgets overrides too.
    printf '%s\n' "wait 0.6" "density com.android.settings 150" "wait 5" > "$WORK/density-reset.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/density-reset.txt" || return 1
    wait_until 20 density_stored_is com.android.settings 1.5 \
        && ok "C16 150% is stored for the app" \
        || bad "C16 150% was not stored: $(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>&1)"
    control reset prefs && ok "C16 the profile reset ran" \
        || bad "C16 the profile reset answered '$CONTROL_REPLY'"
    if defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" >/dev/null 2>&1; then
        bad "C16 the profile reset left the override behind"
    else
        ok "C16 the profile reset forgot the override"
    fi
    stop_app
    stop_fakephone
}

# --- C15: trackpad gestures ---------------------------------------------------

# check_trackpad — a two-finger scroll is a one-finger touch drag, a wheel is
# still SCROLL, and raw trackpad fingers (modelled by the scripted driver) make
# the pinch and rotate pointers. Momentum events must reach the phone as nothing.
check_trackpad() {
    begin_shared || return 1
    # The script starts at the first video config. The main thread is busy with
    # the opening frames for a few hundred ms after that, which would stretch one
    # step of the first gesture past the cadence C15 measures. Settle first: the
    # first frame is shown within milliseconds, and the rest is margin.
    printf '%s\n' "wait 1.5" "trackscroll 200" "scroll 3" "fingerscroll -200" "fingerpinch 0.5 0.5 1.8" \
        "fingerrotate 0.5 0.5 90" "rightclick 0.5 0.5" > "$WORK/trackpad.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/trackpad.txt" || return 1
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

# pause_verdict — "scripted=N others=N unanswered=N stray=N" over stream 1's
# window.pause/window.resume pairs so far.
pause_verdict() {
    python3 - "$WORK/events.jsonl" <<'PY' || true
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
}

check_pause() {
    begin_shared || return 1
    local opened verdict
    open_shared --open com.android.settings --minimize-stream 1:6 --deminimize-stream 1:11 || return 1
    opened="$(date +%s)"
    # Another window passing over the test window makes macOS report it occluded,
    # which is a pause/resume pair of its own. The scripted minimize holds the
    # stream paused for the 5 s between the two timers; count that pair, require
    # every pause to be answered by a resume, and report any short pair that is
    # not ours instead of letting it decide the verdict. The window is watched
    # for the same 16 s a launch with --quit-after 16 gave it.
    while [ $(($(date +%s) - opened)) -lt 16 ]; do sleep 0.5; done
    verdict="$(pause_verdict)"
    say "C8 pause/resume pairs: $verdict"
    case "$verdict" in
        *"scripted=1 "*) ok "C8 exactly one scripted window.pause/window.resume pair (5 s apart)" ;;
        *) bad "C8 scripted pair: $verdict" ;;
    esac
    case "$verdict" in
        *"unanswered=0 stray=0"*) ok "C8 every window.pause is answered by a window.resume" ;;
        *) bad "C8 unbalanced pause/resume: $verdict" ;;
    esac
    stop_app
}

# --- C10: direct reconnect to a dozing phone (no mDNS) ---------------------

# check_direct — pair over --connect, then restart the app with no discovery
# at all: it must reconnect through the remembered IPv4 address. A different
# device id behind the same address must be refused and the address dropped.
check_direct() {
    clean
    # Phase A: pair; `welcome` stores the pin (pins.json) + address (prefs).
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 16
    address_cached() { defaults read "$DEFAULTS_SUITE" cachedAddresses 2>/dev/null | grep -qF "127.0.0.1:$PORT"; }
    await_app 16 eval 'events_have "\"state\":\"paired\"" && address_cached'
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
    await_app 20 events_have '"state":"auth_ok"'
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "C10b reconnected through the cached address (auth_ok)" \
        || bad "C10b no auth_ok via the cached address"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C10b paired again instead of using the stored pin" \
        || ok "C10b used the stored pin"
    stop_fakephone
    sleep 1

    # Phase C: a different phone (its own TLS identity) now answers on
    # that address: the Mac's pin check refuses the TLS handshake before
    # any pairing traffic (v2 keeps C10's device-id rule as a pin mismatch).
    : > "$WORK/events.jsonl"
    rm -f "$WORK/state-other.json"
    start_fake "$WORK/state-other.json" || return 1
    launch --quit-after 16
    wait_app
    mac_pin_refusal() {
        log show --last 4m --info --style syslog \
            --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null \
            | grep -qF 'session failed: pin-mismatch'
    }
    wait_until 20 mac_pin_refusal \
        && ok "C10c refused the different phone at TLS verify (pin-mismatch)" \
        || bad "C10c the session did not fail with pin-mismatch"
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && bad "C10c authenticated against a different phone" \
        || ok "C10c refused the different phone (no auth_ok)"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "C10c tried to pair with a foreign phone" \
        || ok "C10c sent no pairing traffic to the foreign phone"
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
    begin_shared || return 1

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
    printf '%s\n' "key cmd+[" "key esc" > "$WORK/input-back.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/input-back.txt" || return 1
    wait_until 30 nav_at_least 1 back \
        && ok "C11 ⌘[ in an app window -> nav back" || bad "C11 no nav back after ⌘["
    wait_until 30 nav_at_least 2 back \
        && ok "C11 Esc in an app window -> nav back" || bad "C11 no second nav back after Esc"

    # Phase B: a phone-mode window -> ⇧⌘H home, ⌘↑ recents (both stream 1).
    next_shared
    printf '%s\n' "key cmd+shift+h" "key cmd+up" > "$WORK/input-phone.txt"
    open_shared --open-phone --debug-input-script "$WORK/input-phone.txt" || return 1
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
    local portrait landscape
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

# xctest_available — `swift test` needs the XCTest runner, which comes with
# Xcode. A guest with Command Line Tools only (the e2e VM) has swiftc but no
# usr/bin/xctest, so the unit-test fallback below cannot run there.
xctest_available() { [ -x "$(xcode-select -p 2>/dev/null)/usr/bin/xctest" ]; }

# check_spotlight — after an app list arrives the apps are indexed. mdfind is
# tried first; an unsigned dev bundle may not be able to write the Spotlight
# index, in which case the unit tests (item builder + throttle) and the app's
# own index log line are the evidence.
check_spotlight() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 18
    # Read the app's index log line now: the log window is relative to the
    # time of the query, and the unit tests below can take minutes.
    # The index follows the app list; the log is only read once it arrived.
    await_app 18 eval 'events_have "\"t\":\"apps.list\"" && spotlight_logged'
    local logged hit
    logged="$(spotlight_log_line)"
    hit="$(mdfind 'kMDItemContentDescription == "Android app on FakePhone"' 2>/dev/null | head -3 || true)"
    if [ -n "$hit" ]; then
        ok "C12 mdfind found indexed phone apps: $(echo "$hit" | tr '\n' ' ')"
    else
        say "C12 mdfind lists nothing (an unsigned dev bundle cannot surface in the Spotlight index); falling back to the unit test + the app's log line"
        if xctest_available; then
            local out
            # The debug test build is reused when it is newer than the sources
            # (K2 leaves one); otherwise swift test builds it as before.
            local build_args=()
            newer_than "$MACOS/.build/debug/PocketDeckTests.xctest/Contents/MacOS/PocketDeckTests" "${APP_SOURCES[@]}" "$MACOS/Tests" \
                || build_args=(--skip-build)
            out="$(cd "$MACOS" && swift test ${build_args[@]+"${build_args[@]}"} --filter SpotlightTests 2>&1 || true)"
            if echo "$out" | grep -q "with 0 failures"; then
                ok "C12 Spotlight unit tests pass (builder + throttled re-index + domain removal)"
            else
                bad "C12 Spotlight unit tests failed"
            fi
        else
            skip "C12 Spotlight unit tests" "this toolchain has no XCTest runner: $(xcode-select -p 2>/dev/null) has no usr/bin/xctest"
        fi
        if [ -n "$logged" ]; then
            ok "C12 the app logged the index attempt ($logged)"
        else
            bad "C12 no spotlight log line from the app (indexing never attempted)"
        fi
    fi
    stop_fakephone
}

# --- Intents (Siri, Shortcuts, Spotlight actions) -------------------------

# intent_event <name> [key value ...] — the last JSON line the app logged for
# that intent (and matching fields), as JSON. The app writes one per intent.
intent_event() {
    python3 - "$WORK/app.log" "$@" <<'PY'
import json, sys
log, name = sys.argv[1], sys.argv[2]
want = dict(zip(sys.argv[3::2], sys.argv[4::2]))
found = None
try:
    lines = open(log, errors="replace")
except OSError:
    sys.exit(1)
for raw in lines:
    raw = raw.strip()
    if not raw.startswith("{"):
        continue
    try:
        event = json.loads(raw)
    except ValueError:
        continue
    if event.get("intent") == name and all(str(event.get(k)) == v for k, v in want.items()):
        found = event
if found is None:
    sys.exit(1)
print(json.dumps(found))
PY
}

# intent_field <json> <key> — the value as JSON ("null" when absent).
intent_field() {
    python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]).get(sys.argv[2])))' "$1" "$2"
}

# drop_event_for <name> — the fakephone's drop event for that file, as JSON.
drop_event_for() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "drop" and event.get("files") \
            and event["files"][0].get("name") == sys.argv[2]:
        print(json.dumps(event))
        sys.exit(0)
sys.exit(1)
PY
}

# intents_metadata_ok — the built bundle carries Metadata.appintents with the
# six intents, the Focus filter, the manual DND intent, the two entities/queries
# and the provider's seven shortcuts (a plain JSON read; no Shortcuts app, no
# registration).
intents_metadata_ok() {
    python3 - "$E2E_BUNDLE/Contents/Resources/Metadata.appintents/extract.actionsdata" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        data = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
actions = set(data.get("actions") or {})
intents = {"OpenPhoneAppIntent", "OpenPhoneScreenIntent", "PhoneBatteryIntent",
           "SendLinkToPhoneIntent", "SendFileToPhoneIntent", "RingPhoneIntent"}
shortcuts = data.get("autoShortcuts") or []
phrases = [p.get("key", "") for s in shortcuts for p in (s.get("phraseTemplates") or [])]
ok = actions == intents | {"PocketDeckFocusFilter", "SetPhoneDNDIntent"} \
    and set(data.get("entities") or {}) >= {"PhoneEntity", "PhoneAppEntity"} \
    and set(data.get("queries") or {}) >= {"PhoneEntityQuery", "PhoneAppEntityQuery"} \
    and {s.get("actionIdentifier") for s in shortcuts} == intents | {"SetPhoneDNDIntent"} \
    and all(s.get("phraseTemplates") for s in shortcuts) \
    and any("${applicationName}" in p for p in phrases)
sys.exit(0 if ok else 1)
PY
}

# check_intents — the five intents through the same bridge Shortcuts runs
# (--debug-intent): open app/phone, link, 1 MiB file, battery live and after the
# phone is gone, and an unknown app as a human error with the app still alive.
check_intents() {
    # What the system reads, before anything starts (a fast plist/JSON read).
    intents_metadata_ok \
        && ok "INTENTS the bundle's Metadata.appintents lists 8 actions, 2 entities and 7 shortcuts" \
        || bad "INTENTS the bundle's Metadata.appintents is missing or incomplete ($E2E_BUNDLE)"
    clean
    start_fake || return 1
    python3 - "$WORK" <<'PY'
import os, sys
with open(os.path.join(sys.argv[1], "intent-1mb.bin"), "wb") as f:
    f.write(os.urandom(1024 * 1024))
PY
    launch --connect "127.0.0.1:$PORT" \
        --debug-intent "battery" \
        --debug-intent "open-app com.android.settings" \
        --debug-intent "open-phone" \
        --debug-intent "send-link https://example.com/intents" \
        --debug-intent "send-file $WORK/intent-1mb.bin" \
        --debug-intent "open-app org.example.missing" \
        --quit-after 120

    local line
    if wait_until 40 intent_event battery; then
        line="$(intent_event battery)"
        [ "$(intent_field "$line" ok)" = "true" ] \
            && [ "$(intent_field "$line" level)" = "87" ] \
            && [ "$(intent_field "$line" live)" = "true" ] \
            && [ "$(intent_field "$line" dialog)" = '"FakePhone: 87 %"' ] \
            && ok "INTENTS battery answers live from the phone's state (87 %)" \
            || bad "INTENTS live battery line is wrong: $line"
    else
        bad "INTENTS no battery line from the app"
    fi

    if wait_until 40 intent_event open-app args com.android.settings; then
        line="$(intent_event open-app args com.android.settings)"
        [ "$(intent_field "$line" ok)" = "true" ] \
            && [ "$(intent_field "$line" dialog)" = '"Opened Settings on FakePhone."' ] \
            && ok "INTENTS open-app ran the Spotlight open path (Settings)" \
            || bad "INTENTS open-app line is wrong: $line"
    else
        bad "INTENTS open-app com.android.settings produced no line"
    fi
    events_have '"pkg":"com.android.settings"' && events_have '"t":"window.open"' \
        && ok "INTENTS the phone opened a window for the app's package" \
        || bad "INTENTS the phone never received window.open for com.android.settings"

    if wait_until 30 intent_event open-phone; then
        line="$(intent_event open-phone)"
        [ "$(intent_field "$line" ok)" = "true" ] && events_have '"mode":"phone"' \
            && ok "INTENTS open-phone opened the whole-phone window" \
            || bad "INTENTS open-phone line is wrong: $line"
    else
        bad "INTENTS open-phone produced no line"
    fi

    if wait_until 40 intent_event send-link; then
        line="$(intent_event send-link)"
        [ "$(intent_field "$line" ok)" = "true" ] \
            && events_have '"ev":"link"' && events_have 'https://example.com/intents' \
            && ok "INTENTS send-link reached the phone through link.open" \
            || bad "INTENTS send-link line or phone event is wrong: $line"
    else
        bad "INTENTS send-link produced no line"
    fi

    if wait_until 40 intent_event send-file; then
        line="$(intent_event send-file)"
        [ "$(intent_field "$line" ok)" = "true" ] && [ "$(intent_field "$line" files)" = "1" ] \
            && ok "INTENTS send-file accepted the file (1 MiB)" \
            || bad "INTENTS send-file line is wrong: $line"
    else
        bad "INTENTS send-file produced no line"
    fi
    if wait_until 60 drop_event_for intent-1mb.bin; then
        local want
        want="$(shasum -a 256 "$WORK/intent-1mb.bin" | cut -c1-64)"
        drop_event_for intent-1mb.bin | python3 -c \
            'import json,sys; e=json.load(sys.stdin); f=e["files"][0]; sys.exit(0 if e["ok"] and f["size"]==1048576 and f["match"] and f["sha256"]==sys.argv[1] else 1)' "$want" \
            && ok "INTENTS the phone received intent-1mb.bin with a matching sha256 (${want:0:12}…)" \
            || bad "INTENTS the received file's sha256/size is wrong"
    else
        bad "INTENTS the phone never received intent-1mb.bin"
    fi

    if wait_until 30 intent_event open-app args org.example.missing; then
        line="$(intent_event open-app args org.example.missing)"
        [ "$(intent_field "$line" ok)" = "false" ] \
            && [ "$(intent_field "$line" error)" = '"app_not_found"' ] \
            && echo "$line" | grep -q "No phone app matches" \
            && ok "INTENTS an unknown app answers a human error (app_not_found)" \
            || bad "INTENTS unknown app line is wrong: $line"
    else
        bad "INTENTS unknown app produced no line"
    fi
    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] \
        && ok "INTENTS the app survived every intent (one instance)" \
        || bad "INTENTS the app died or a second instance appeared"

    # Battery after the phone is gone: the last value and its age, no wake.
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    sleep 65
    launch --connect "127.0.0.1:$PORT" --debug-intent "battery" --quit-after 12
    if wait_until 20 intent_event battery; then
        line="$(intent_event battery)"
        [ "$(intent_field "$line" ok)" = "true" ] \
            && [ "$(intent_field "$line" level)" = "87" ] \
            && [ "$(intent_field "$line" live)" = "false" ] \
            && echo "$line" | grep -qE '"FakePhone: 87 % (1|2) min ago"' \
            && ok "INTENTS battery after the phone left: last value and age" \
            || bad "INTENTS stale battery line is wrong: $line"
    else
        bad "INTENTS no battery line after the phone left"
    fi
    stop_app
}

# --- Automation server (MCP) -------------------------------------------------
# check_mcp — the app's private socket, the stdio shim and the 13 tools: state,
# open an app, a screenshot, input frames, a link and a 1 MiB file. With the
# setting off the shim must print the Settings hint and fail. The peer-uid check
# cannot be exercised without a second local account; the unit tests cover the
# server, this run notes the skip.
check_mcp() {
    local shim="$E2E_BUNDLE/Contents/Helpers/pocketdeck-mcp"
    local support="$HOME/Library/Application Support/PocketDeck-$PROFILE"
    local sock="$support/mcp.sock"
    if [ ! -x "$shim" ]; then
        bad "MCP the bundle has no Contents/Helpers/pocketdeck-mcp"
        return 1
    fi
    clean
    start_fake || return 1
    rm -f "$sock"
    launch --connect "127.0.0.1:$PORT" --quit-after 60
    sleep 2
    if [ -S "$sock" ]; then
        bad "MCP a socket exists with the setting off"
    else
        local status=0
        "$shim" --profile "$PROFILE" </dev/null > "$WORK/shim-off.out" 2> "$WORK/shim-off.err" || status=$?
        if [ "$status" -ne 0 ] && grep -q "Turn on Settings › Automation in PocketDeck" "$WORK/shim-off.err"; then
            ok "MCP with the setting off the shim prints the Settings hint and exits non-zero"
        else
            bad "MCP off: status $status, stderr: $(head -1 "$WORK/shim-off.err")"
        fi
    fi
    stop_app

    python3 - "$WORK/mcp-1mb.bin" <<'PY'
import os, sys
with open(sys.argv[1], "wb") as f:
    f.write(os.urandom(1024 * 1024))
PY
    launch --mcp-enable --connect "127.0.0.1:$PORT" --quit-after 240
    if ! wait_until 30 test -S "$sock"; then
        bad "MCP --mcp-enable did not create $sock"
        stop_app
        return 1
    fi
    ok "MCP the setting on creates the private socket"
    if "$FAKE_PY" "$MACOS/scripts/mcp-driver.py" \
            --shim "$shim" --profile "$PROFILE" --events "$WORK/events.jsonl" \
            --file "$WORK/mcp-1mb.bin" --link "https://example.com/mcp" \
            > "$WORK/mcp-driver.log" 2>&1; then
        :
    else
        say "mcp driver output:"; cat "$WORK/mcp-driver.log"
    fi
    local line
    while IFS= read -r line; do
        case "$line" in
            PASS\ *) ok "${line#PASS }" ;;
            FAIL\ *) bad "${line#FAIL }" ;;
            DRIVER\ passed*) : ;;
            DRIVER\ *) say "MCP ${line#DRIVER }" ;;
        esac
    done < "$WORK/mcp-driver.log"
    if ! grep -q '^DRIVER passed=' "$WORK/mcp-driver.log"; then
        bad "MCP the driver never completed"
    fi
    ! grep -qiE "fatal|protocol error" "$WORK/app.log" 2>/dev/null \
        && ok "MCP the app logged no fatal/protocol error" \
        || bad "MCP the app log has fatal/protocol lines"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    skip "MCP a second uid" "needs another local account; the peer uid check is unit-tested"
}

# --- Focus → phone Do Not Disturb (docs/design/focus.md) -------------------

# focus_event <name> [key value ...] — the last focus JSON line the app logged
# for that hook (filter, reconcile, dnd) and matching fields, as JSON.
focus_event() {
    python3 - "$WORK/app.log" "$@" <<'PY'
import json, sys
log, name = sys.argv[1], sys.argv[2]
want = dict(zip(sys.argv[3::2], sys.argv[4::2]))
found = None
try:
    lines = open(log, errors="replace")
except OSError:
    sys.exit(1)
for raw in lines:
    raw = raw.strip()
    if not raw.startswith("{"):
        continue
    try:
        event = json.loads(raw)
    except ValueError:
        continue
    if event.get("focus") == name and all(str(event.get(k)).lower() == v.lower() for k, v in want.items()):
        found = event
if found is None:
    sys.exit(1)
print(json.dumps(found))
PY
}

# dnd_is <mode> — the phone's last DND event carries that mode.
dnd_is() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
mode = None
for line in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "dnd":
        mode = event.get("mode")
sys.exit(0 if mode == sys.argv[2] else 1)
PY
}

# dnd_count — how many DND changes the fake phone has applied.
dnd_count() { grep -c '"ev":"dnd"' "$WORK/events.jsonl" 2>/dev/null || true; }

# dnd_rx_count — how many phone.dnd messages the fake phone has received.
dnd_rx_count() { grep -c '"t":"phone.dnd"' "$WORK/events.jsonl" 2>/dev/null || true; }

# dnd_more_than <n> — the fake phone applied more than n DND changes.
dnd_more_than() { [ "$(dnd_count)" -gt "$1" ]; }

check_focus() {
    # What the system reads, before anything starts.
    intents_metadata_ok \
        && ok "FOCUS the bundle's metadata lists the Focus filter and the DND intent" \
        || bad "FOCUS the bundle's metadata is missing the filter or the DND intent ($E2E_BUNDLE)"

    # (1) the filter silences the phone, and its end brings it back.
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-focus "on priority" --quit-after 40
    wait_until 25 dnd_is priority \
        && ok "FOCUS filter on turned the phone's DND to priority" \
        || bad "FOCUS filter on did not turn the phone's DND to priority"
    events_have '"t":"phone.dnd"' \
        && ok "FOCUS the Mac sent phone.dnd" \
        || bad "FOCUS no phone.dnd reached the phone"
    stop_app
    launch --connect "127.0.0.1:$PORT" --debug-focus "off" --quit-after 40
    wait_until 25 dnd_is off \
        && ok "FOCUS filter off turned the phone's DND back off" \
        || bad "FOCUS filter off did not turn the phone's DND off"
    stop_app

    # (2) a person's own DND is never turned off.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--dnd-person priority" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-focus "on priority" --quit-after 40
    wait_until 25 dnd_is priority \
        && ok "FOCUS a person's own priority DND stays on when the filter asks for it" \
        || bad "FOCUS a person's own priority DND was changed by the filter"
    stop_app
    local before
    before="$(dnd_count)"
    launch --connect "127.0.0.1:$PORT" --debug-focus "off" --quit-after 40
    wait_until 25 dnd_more_than "$before" \
        && sleep 1
    dnd_is priority \
        && ok "FOCUS the restore rule left the person's DND alone when the filter ended" \
        || bad "FOCUS the restore rule turned off a DND the person set"
    stop_app

    # (3) filter on while disconnected: applied once, on connect.
    stop_fakephone
    wait_until 5 no_fakephone
    start_fake || return 1
    launch --debug-focus "on alarms" --quit-after 5
    wait_until 10 focus_event filter enabled true \
        && ok "FOCUS a disconnected Mac stored the filter's wanted state" \
        || bad "FOCUS the filter's wanted state was not stored"
    stop_app
    launch --connect "127.0.0.1:$PORT" --quit-after 40
    wait_until 25 dnd_is alarms \
        && ok "FOCUS the phone that connected later got the stored filter (alarms)" \
        || bad "FOCUS a later connection never got the stored filter"
    sleep 3
    [ "$(dnd_rx_count)" = "1" ] \
        && ok "FOCUS the stored filter was applied exactly once" \
        || bad "FOCUS the stored filter was applied $(dnd_rx_count) times: $(grep '"t":"phone.dnd"' "$WORK/events.jsonl" 2>/dev/null | tr '\n' '|')"
    stop_app

    # (4) an old phone: no dnd in state, menu item disabled, nothing sent.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--dnd-unsupported" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-dnd on --quit-after 25
    wait_until 20 focus_event dnd supported false \
        && ok "FOCUS an old phone leaves the menu item disabled (no dnd in state)" \
        || bad "FOCUS --debug-dnd did not report an unsupported phone"
    [ "$(dnd_rx_count)" = "0" ] \
        && ok "FOCUS nothing is sent to a phone that cannot take it (no error spam)" \
        || bad "FOCUS a phone.dnd was sent to an old phone"
    stop_app
    stop_fakephone
}

# --- controls: Control Center snapshot and requests (docs/design/controls.md) ---

# controls_driver — the extension's side: reads the snapshot and sends one
# request line over the group socket. No widget extension is built on the host;
# --controls-dir puts both in the run's work folder.
controls_driver() { python3 "$MACOS/scripts/controls-driver.py" "$@"; }

controls_snapshot_is() { controls_driver wait "$WORK/controls" "$1" "${@:2}" >/dev/null 2>&1; }

controls_request() { controls_driver request "$WORK/controls" "$@"; }

controls_reply_is() {
    local reply
    reply="$(controls_request "$@")"
    printf '%s\n' "$reply" >> "$WORK/controls-replies.jsonl"
    python3 - "$reply" <<'PY'
import json, sys
try:
    reply = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if reply.get("ok") is True else 1)
PY
}

controls_error_is() {
    local expected="$1" reply
    shift
    reply="$(controls_request "$@" 2>> "$WORK/controls-driver.err")"
    printf '%s\n' "$reply" >> "$WORK/controls-replies.jsonl"
    python3 - "$reply" "$expected" <<'PY'
import json, sys
try:
    reply = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if reply.get("ok") is False and reply.get("error") == sys.argv[2] else 1)
PY
}

ringer_is() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
mode = None
for line in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "ringer":
        mode = event.get("mode")
sys.exit(0 if mode == sys.argv[2] else 1)
PY
}

ring_received() {
    grep -q '"ev":"ring"' "$WORK/events.jsonl" 2>/dev/null
}

check_controls() {
    # (1) the snapshot the extension reads, and DND from a control.
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --controls-dir "$WORK/controls" --quit-after 120
    controls_snapshot_is 25 connected=true dnd=off \
        && ok "CONTROLS the snapshot says connected with DND off" \
        || bad "CONTROLS no connected/off snapshot: $(controls_driver snapshot "$WORK/controls" 2>&1 | tail -1)"
    controls_driver snapshot "$WORK/controls" 2>/dev/null | grep -q 'FakePhone' \
        && ok "CONTROLS the snapshot names the phone" \
        || bad "CONTROLS the snapshot has no phone name"
    controls_reply_is dnd on \
        && ok "CONTROLS dnd on accepted" \
        || bad "CONTROLS dnd on was refused"
    wait_until 3 dnd_is priority \
        && ok "CONTROLS dnd on reached the phone as priority" \
        || bad "CONTROLS the phone never got phone.dnd priority"
    controls_snapshot_is 3 dnd=priority \
        && ok "CONTROLS the snapshot followed to dnd priority within 3 s" \
        || bad "CONTROLS the snapshot did not follow the DND change"
    controls_reply_is dnd off \
        && ok "CONTROLS dnd off accepted" \
        || bad "CONTROLS dnd off was refused"
    wait_until 5 dnd_is off \
        && ok "CONTROLS dnd off restored the DND PocketDeck set" \
        || bad "CONTROLS dnd off did not restore the phone"

    # (2) Ring and Ringer.
    controls_reply_is ring \
        && ok "CONTROLS ring accepted" \
        || bad "CONTROLS ring was refused"
    wait_until 3 ring_received \
        && ok "CONTROLS ring reached the phone as phone.ring" \
        || bad "CONTROLS the phone never got phone.ring"
    controls_snapshot_is 3 ringing=true \
        && ok "CONTROLS the snapshot says ringing" \
        || bad "CONTROLS the snapshot never said ringing"
    controls_reply_is ringer silent \
        && ok "CONTROLS ringer silent accepted" \
        || bad "CONTROLS ringer silent was refused"
    wait_until 3 ringer_is silent \
        && ok "CONTROLS ringer silent reached the phone as phone.ringer" \
        || bad "CONTROLS the phone never got phone.ringer silent"
    controls_snapshot_is 3 ringer=silent \
        && ok "CONTROLS the snapshot followed the ringer" \
        || bad "CONTROLS the snapshot did not follow the ringer"
    controls_reply_is ringer loud 2>/dev/null \
        && bad "CONTROLS a bad ringer mode was accepted" \
        || ok "CONTROLS a bad ringer mode is refused"
    stop_app

    # (3) a person's own DND is never touched by the control.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--dnd-person priority" start_fake || return 1
    rm -rf "$WORK/controls"
    launch --connect "127.0.0.1:$PORT" --controls-dir "$WORK/controls" --quit-after 90
    controls_snapshot_is 25 dnd=priority \
        && ok "CONTROLS a person's DND shows in the snapshot" \
        || bad "CONTROLS the person's DND never reached the snapshot"
    controls_reply_is dnd off \
        && ok "CONTROLS dnd off accepted for a person's DND" \
        || bad "CONTROLS dnd off was refused for a person's DND"
    sleep 2
    dnd_is priority \
        && ok "CONTROLS the restore rule left the person's DND alone" \
        || bad "CONTROLS the control turned off a DND the person set"
    controls_snapshot_is 3 dnd=priority \
        && ok "CONTROLS the snapshot still says priority" \
        || bad "CONTROLS the snapshot changed a person's DND"
    stop_app

    # (4) an old phone: no ringer in state, a clear refusal, no silent no-op.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--ringer-unsupported" start_fake || return 1
    rm -rf "$WORK/controls"
    launch --connect "127.0.0.1:$PORT" --controls-dir "$WORK/controls" --quit-after 60
    controls_snapshot_is 25 connected=true \
        && ok "CONTROLS the old phone still connects" \
        || bad "CONTROLS the old phone never connected"
    controls_error_is no_ringer ringer silent \
        && ok "CONTROLS a phone without ringer support answers no_ringer" \
        || bad "CONTROLS a phone without ringer support did not answer no_ringer"
    grep -q '"t":"phone.ringer"' "$WORK/events.jsonl" \
        && bad "CONTROLS a phone.ringer was sent to a phone that cannot take it" \
        || ok "CONTROLS nothing is sent to a phone without ringer support"

    # (5) fakephone gone: the snapshot says disconnected, requests say why.
    stop_fakephone
    controls_snapshot_is 5 connected=false \
        && ok "CONTROLS the snapshot says disconnected when the phone goes" \
        || bad "CONTROLS the snapshot stayed connected after the phone left"
    controls_error_is not_connected ring \
        && ok "CONTROLS a request without a phone answers not_connected" \
        || bad "CONTROLS a request without a phone did not answer not_connected"
    python3 - "$WORK/controls-replies.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1], errors="replace"):
    try:
        reply = json.loads(line)
    except ValueError:
        continue
    if reply.get("error") == "not_connected" and "connected" in (reply.get("message") or ""):
        sys.exit(0)
sys.exit(1)
PY
    [ $? = 0 ] \
        && ok "CONTROLS the not_connected reply says \"Phone isn't connected\"" \
        || bad "CONTROLS the not_connected reply has no message"
    stop_app
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
    begin_shared || return 1
    open_shared --open com.android.settings --audio-stats "$WORK/audio.json" || return 1
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
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
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
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
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
    launch --connect "127.0.0.1:$PORT" ${requests[@]+"${requests[@]}"} --quit-after 120

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

# check_files — read-only phone files, slices S1+S2 (docs/design/files.md §6,
# docs/PROTOCOL.md "Phone files"). The check builds a fake /sdcard, starts the
# fake phone on it and runs the app's --debug-fs-script (FsDebug.swift): each
# step's result is one `fsdebug: {...}` JSON line on app.log, with name hashes
# instead of names. Asserts: root listing names+sizes (hidden/Android rules),
# 1500-file paging, the three fs_denied paths, two whole-file reads by SHA-256,
# a stale etag, and a cancelled read that stops the phone's stream.
check_files() {
    clean
    python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]
root = os.path.join(work, "fsroot")
for folder in ("Documents", "Documents/notes", "DCIM/Camera", "many", "Android/data/x"):
    os.makedirs(os.path.join(root, folder), exist_ok=True)
open(os.path.join(root, "Android/data/x/y"), "wb").write(b"hidden")
open(os.path.join(root, ".hidden"), "wb").write(b"hidden")
# ~40 files: 36 small ones across the folders, then the two big ones.
for i in range(36):
    folder = ["Documents", "DCIM/Camera", "Documents/notes", ""][i % 4]
    with open(os.path.join(root, folder, "file%02d.txt" % i), "wb") as handle:
        handle.write(("small %d\n" % i).encode() * (i + 1))
with open(os.path.join(root, "big3.bin"), "wb") as handle:
    handle.write(os.urandom(3 * 1024 * 1024))
with open(os.path.join(root, "big32.bin"), "wb") as handle:
    handle.write(os.urandom(32 * 1024 * 1024))
for i in range(1500):
    open(os.path.join(root, "many", "m%04d.txt" % i), "wb").close()
PY
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-chunk-delay-ms 4" start_fake || return 1
    printf '%s\n' \
        "list" "listall many" "stat big3.bin" \
        "list .." "list /sdcard" "list Android/data" \
        "read big3.bin $WORK/out3.bin" \
        "read big32.bin $WORK/out32.bin" \
        "read big32.bin $WORK/stale.bin 0 1048576 stale" \
        "read big32.bin $WORK/cancel.bin 0 33554432 - 100" \
        > "$WORK/fs.txt"
    launch --connect "127.0.0.1:$PORT" --debug-fs-script "$WORK/fs.txt" --quit-after 300
    fs_done() { grep -q '"op":"done"' "$WORK/app.log" 2>/dev/null; }
    if ! wait_until 180 fs_done; then
        bad "FILES the debug script never finished: $(grep 'fsdebug:' "$WORK/app.log" | tail -3)"
        stop_app; stop_fakephone; return 1
    fi
    sleep 1   # the fake's writer logs the last FS_DATA frames it wrote
    python3 - "$WORK" "$WORK/fsroot" > "$WORK/fs-results.txt" <<'PY'
import hashlib, json, os, sys
work, root = sys.argv[1], sys.argv[2]
results = []

def report(ok, text):
    results.append(("ok " if ok else "bad ") + text)

lines = []
for raw in open(os.path.join(work, "app.log"), errors="replace"):
    at = raw.find("fsdebug: ")
    if at < 0:
        continue
    try:
        lines.append(json.loads(raw[at + len("fsdebug: "):]))
    except ValueError:
        pass

def h(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]

def sha_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()

def listings(path):
    return [line for line in lines if line.get("op") == "list" and line.get("ok")
            and line.get("p") == h(path)]

def failure(path, op="list"):
    for line in lines:
        if line.get("op") == op and line.get("p") == h(path) and line.get("ok") is False:
            return line.get("code")
    return None

# 1. The root listing: what a person calls phone storage, with real sizes.
expected = set()
for name in os.listdir(root):
    if name.startswith(".") or name == "Android":
        continue
    info = os.lstat(os.path.join(root, name))
    size = 0 if os.path.isdir(os.path.join(root, name)) else info.st_size
    expected.add((h(name), 1 if os.path.isdir(os.path.join(root, name)) else 0, size))
pages = listings("")
got = set()
for page in pages:
    for item in page.get("items", []):
        got.add((item["n"], item["d"], item["s"]))
report(len(got) == len(expected) and got == expected,
       "FILES the root listing has every visible name and size (%d items, hidden/Android "
       "left out)" % len(got))

# 2. Paging over a 1500-file folder: every name exactly once.
pages = listings("many")
names = [item["n"] for page in pages for item in page.get("items", [])]
want = {h("m%04d.txt" % i) for i in range(1500)}
report(len(pages) >= 2 and len(names) == 1500 and len(set(names)) == 1500 and set(names) == want,
       "FILES paging read all 1500 names exactly once in %d pages" % len(pages))

# 3. stat.
stat = next((line for line in lines if line.get("op") == "stat" and line.get("ok")), None)
report(bool(stat) and stat["s"] == 3 * 1024 * 1024 and stat["d"] == 0
       and stat["p"] == h("big3.bin"),
       "FILES stat reports big3.bin as a 3 MiB file")

# 4. The refused paths.
denied = [failure(".."), failure("/sdcard"), failure("Android/data")]
report(denied == ["fs_denied"] * 3,
       "FILES '..', an absolute path and Android/data answer fs_denied (%s)" % denied)

# 5. Whole-file reads: the phone's sha256, the app's sha256 and the file on disk agree.
def read_ok(name, size):
    want = sha_file(os.path.join(root, name))
    done = [line for line in lines if line.get("op") == "read" and line.get("ok")
            and line.get("p") == h(name) and line.get("bytes") == size]
    if not done:
        report(False, "FILES %s never read back" % name)
        return
    out = os.path.join(work, "out3.bin" if name == "big3.bin" else "out32.bin")
    report(done[-1]["sha256"] == want and sha_file(out) == want,
           "FILES %s read back byte-identical (%d bytes, sha %s...)" % (name, size, want[:12]))

read_ok("big3.bin", 3 * 1024 * 1024)
read_ok("big32.bin", 32 * 1024 * 1024)

# 6. A stale etag is refused and leaves no file.
report(failure("big32.bin", op="read") == "fs_stale"
       and not os.path.exists(os.path.join(work, "stale.bin")),
       "FILES a stale etag answers fs_stale and writes nothing")

# 7. A cancelled read stops; the fake logged no chunk after the cancel marker.
cancelled = any(line.get("op") == "read" and line.get("ok") is False
                and line.get("p") == h("big32.bin") and line.get("code") == "cancelled"
                for line in lines)
read_id, before, after = None, 0, 0
order = []   # ("sent"|"cancel", id) in the fake's write order
for raw in open(os.path.join(work, "fake.err"), errors="replace"):
    line = raw.strip()
    if line.startswith("fakephone: fs cancel id="):
        order.append(("cancel", int(line.rsplit("=", 1)[1])))
    elif line.startswith("fakephone: fs sent id="):
        order.append(("sent", int(line.split()[3].split("=")[1])))
at = next((i for i, item in enumerate(order) if item[0] == "cancel"), None)
if at is not None:
    read_id = order[at][1]
    before = sum(1 for kind, ident in order[:at] if kind == "sent" and ident == read_id)
    after = sum(1 for kind, ident in order[at + 1:] if kind == "sent" and ident == read_id)
report(cancelled and read_id is not None and before > 0 and after <= 1,
       "FILES the cancelled read stopped on the phone (cancel after %d chunks, %d chunk "
       "after it)" % (before, after))

for line in results:
    print(line)
PY
    while IFS= read -r line; do
        case "$line" in
            ok\ *) ok "${line#ok }" ;;
            bad\ *) bad "${line#bad }" ;;
        esac
    done < "$WORK/fs-results.txt"
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
    # A slow phone: its confirmation for the tail is repeated after the Mac's
    # reader is at EOF, which is the offset race the sender must ignore.
    FAKE_ARGS="--drop-ack-delay 0.3" begin_shared || return 1

    python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
# 32 MiB: enough chunks that the phone's 250 ms progress lags the wire.
with open(os.path.join(work, "drop-32mb.bin"), "wb") as f:
    f.write(os.urandom(32 * 1024 * 1024))
# 3 MB of random bytes: a real chunked transfer, small enough to hash quickly.
with open(os.path.join(work, "drop-3mb.bin"), "wb") as f:
    f.write(os.urandom(3 * 1024 * 1024))
# The negative case: the trip stands in for a file over the cap.
with open(os.path.join(work, "tripped.bin"), "wb") as f:
    f.write(b"PD_FAKE_DOWNSIZE" + os.urandom(64 * 1024))
PY

    # drop_event <name> <ok|bad> — the first event for that file and outcome.
    drop_event() {
        python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
name, want_ok = sys.argv[2], sys.argv[3] == "ok"
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "drop" and e.get("ok") == want_ok and e.get("files") \
            and e["files"][0].get("name") == name:
        print(json.dumps(e))
        sys.exit(0)
sys.exit(1)
PY
    }
    drop_found() { drop_event "$@" >/dev/null; }
    log_has() { drop_log | grep -qF -- "$1"; }
    fake_log_has() { grep -qF -- "$1" "$WORK/fake.log" "$WORK/fake.err" 2>/dev/null; }

    # The waits keep the drops apart: FileDropSender takes one file at a time
    # and would refuse the next while the one before is still in flight.
    printf '%s\n' "dropfile $WORK/drop-32mb.bin" "wait 20" \
        "dropfile $WORK/drop-3mb.bin" "wait 8" "dropfile $WORK/tripped.bin" "wait 5" \
        > "$WORK/drop.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/drop.txt" || return 1

    local event want
    # The 32 MiB drop with the late tail confirmation: every byte exactly once.
    if wait_until 90 drop_found drop-32mb.bin ok; then
        event="$(drop_event drop-32mb.bin ok)"
        want="$(shasum -a 256 "$WORK/drop-32mb.bin" | cut -c1-64)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); f=e["files"]; sys.exit(0 if len(f)==1 and f[0]["name"]=="drop-32mb.bin" and f[0]["size"]==32*1024*1024 and f[0]["match"] and f[0]["sha256"]==sys.argv[1] else 1)' "$want" \
            && ok "DROP fakephone got drop-32mb.bin (32 MiB) with a matching sha256 (${want:0:12}…)" \
            || bad "DROP 32 MiB sha256/size mismatch: $event (want $want)"
    else
        bad "DROP fakephone never received the 32 MiB file"
    fi
    wait_until 30 fake_log_has "33554432 bytes (drop-32mb.bin) -> sha ok" \
        && ok "DROP fakephone received all 33554432 bytes over DROP_DATA" \
        || bad "DROP fakephone did not log the full 32 MiB: $(grep -i drop "$WORK/fake.log" "$WORK/fake.err" | tail -3)"
    # The late confirmation must not have moved the sender back into the file.
    sleep 1
    if fake_log_has "more bytes than announced"; then
        bad "DROP the sender re-sent bytes after EOF: $(grep -h 'more bytes than announced' "$WORK/fake.log" "$WORK/fake.err" | tail -2)"
    else
        ok "DROP no tail re-send: received bytes == announced bytes"
    fi

    if wait_until 60 drop_found drop-3mb.bin ok; then
        event="$(drop_event drop-3mb.bin ok)"
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

    if wait_until 60 drop_found tripped.bin bad; then
        event="$(drop_event tripped.bin bad)"
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

# unregister_files — the File Provider extension leaves PlugInKit too (it is
# only ever registered inside the e2e VM, but cleanup does not rely on that).
unregister_files() {
    local appex="$E2E_BUNDLE/Contents/PlugIns/Files.appex"
    [ -d "$appex" ] && pluginkit -r "$appex" >/dev/null 2>&1
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

# --- Finder bridge (docs/design/files.md §3, files-bridge) ------------------
#
# The app's side of phone files in Finder, with no File Provider on this Mac:
# the app listens on a socket in the run's work dir (`--files-bridge-dir`, a
# test hook) and scripts/files-bridge-driver.py speaks the extension's wire at
# it. Asserts hello, the root listing (hidden/Android rules), paging, stat, two
# byte-identical whole-file reads, a cancel that stops the phone's stream, the
# fs_denied path, and `offline` after fakephone is killed.

# files_bridge_socket — the socket path `--files-bridge-dir $WORK/bridge` uses.
files_bridge_socket() {
    if [ "$PROFILE" = default ]; then
        printf '%s\n' "$WORK/bridge/files.sock"
    else
        printf '%s\n' "$WORK/bridge/files-$PROFILE.sock"
    fi
}

# files_bridge_driver <phase> — run the driver and turn its lines into PASS/FAIL.
files_bridge_driver() {
    local phase="$1" out="$WORK/bridge-$1.txt"
    shift || true
    "$MACOS/scripts/files-bridge-driver.py" --socket "$(files_bridge_socket)" \
        --root "$WORK/fsroot" --work "$WORK" --fake-err "$WORK/fake.err" \
        --phase "$phase" "$@" > "$out" 2>&1
    while IFS= read -r line; do
        case "$line" in
            ok\ *) ok "${line#ok }" ;;
            bad\ *) bad "${line#bad }" ;;
            *) [ -n "$line" ] && say "    $line" ;;
        esac
    done < "$out"
}

check_files_bridge() {
    clean
    python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
root = os.path.join(work, "fsroot")
for folder in ("Documents", "Documents/notes", "DCIM/Camera", "many", "Android/data/x"):
    os.makedirs(os.path.join(root, folder), exist_ok=True)
open(os.path.join(root, "Android/data/x/y"), "wb").write(b"hidden")
open(os.path.join(root, ".hidden"), "wb").write(b"hidden")
# ~40 files in Documents; the rest of the root is the same shape as `files`.
for i in range(40):
    with open(os.path.join(root, "Documents", "file%02d.txt" % i), "wb") as handle:
        handle.write(("small %d\n" % i).encode() * (i + 1))
with open(os.path.join(root, "DCIM/Camera/photo.jpg"), "wb") as handle:
    handle.write(b"\xff\xd8\xff\xe0" + os.urandom(4096))
with open(os.path.join(root, "big3.bin"), "wb") as handle:
    handle.write(os.urandom(3 * 1024 * 1024))
with open(os.path.join(root, "big32.bin"), "wb") as handle:
    handle.write(os.urandom(32 * 1024 * 1024))
for i in range(1500):
    open(os.path.join(root, "many", "m%04d.txt" % i), "wb").close()
PY
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-chunk-delay-ms 4" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --files-bridge-dir "$WORK/bridge"
    wait_until 30 file_has "files-bridge: ok" "$WORK/app.log" \
        && ok "BRIDGE the app listens on the test bridge socket" \
        || bad "BRIDGE no bridge socket: $(grep 'files-bridge' "$WORK/app.log" | tail -2)"
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "BRIDGE the app never authenticated"; stop_app; stop_fakephone; return 1; }
    files_bridge_driver online
    # The phone goes away: every dataless request must answer offline.
    stop_fakephone
    wait_until 5 no_fakephone
    files_bridge_driver offline
    # Nothing about the bridge may put a name, a path or bytes in the app log:
    # os_log carries op names, counts and lengths only (design §4).
    log show --last 3m --info \
        --predicate 'subsystem == "dev.pocketdeck.mac" AND category == "files"' 2>/dev/null \
        | grep -o 'bridge: .*' > "$WORK/bridge-log.txt" 2>/dev/null || true
    if grep -q "bridge: list page" "$WORK/bridge-log.txt"; then
        ok "BRIDGE the app logged op names and counts only"
    else
        bad "BRIDGE the app logged no bridge activity: $(head -2 "$WORK/bridge-log.txt")"
    fi
    if python3 - "$WORK/fsroot" "$WORK/bridge-log.txt" <<'PY'
import os, sys
root, log = sys.argv[1], sys.argv[2]
text = open(log, errors="replace").read()
names = set(os.listdir(root)) | set(os.listdir(os.path.join(root, "Documents")))
# A logged name would read like a path or a quoted name; op words ("too many
# live ids") must not trip the check.
bad = [name for name in names
       if ("/" + name) in text or (name + "/") in text or ('"' + name + '"') in text]
sys.exit(1 if bad else 0)
PY
    then
        ok "BRIDGE no file name from the tree appears in the app log"
    else
        bad "BRIDGE a file name appears in the app log"
    fi
    stop_app
}


# check_files_write — the write path (slice S4, docs/design/files.md §6): the
# driver plays the extension and drives create/modify/delete over the app's
# bridge. Asserts a 3 MiB and a 32 MiB create land byte-identical with no
# staging file left, edit/rename/move keep the item id, delete removes it, a
# stale base keeps both copies, a write into Android/data is denied, and a
# phone killed mid-write ends the request offline with nothing partial left
# after it restarts. No File Provider anywhere.
check_files_write() {
    clean
    python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
root = os.path.join(work, "fsroot")
for folder in ("Documents", "DCIM/Camera", "Android/data/x"):
    os.makedirs(os.path.join(root, folder), exist_ok=True)
open(os.path.join(root, "Android/data/x/y"), "wb").write(b"hidden")
open(os.path.join(root, ".hidden"), "wb").write(b"hidden")
with open(os.path.join(root, "Documents/notes.txt"), "wb") as handle:
    handle.write(b"small notes\n")
with open(os.path.join(root, "DCIM/Camera/photo.jpg"), "wb") as handle:
    handle.write(b"\xff\xd8\xff\xe0" + b"p" * 4096)
PY
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-write-delay-ms 1" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --files-bridge-dir "$WORK/bridge"
    wait_until 30 file_has "files-bridge: ok" "$WORK/app.log" \
        && ok "WRITE the app listens on the test bridge socket" \
        || bad "WRITE no bridge socket: $(grep 'files-bridge' "$WORK/app.log" | tail -2)"
    if ! wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""'; then
        bad "WRITE the app never authenticated"
        stop_app; stop_fakephone; return 1
    fi
    files_bridge_driver write
    files_bridge_driver kill --fake-pid "$FAKE_PID"
    wait_until 10 no_fakephone
    # The phone comes back on the same tree: a killed write must have left
    # neither its staging file nor a partial target.
    FAKE_ARGS="--fs-root $WORK/fsroot" start_fake || { bad "WRITE fakephone did not restart"; stop_app; return 1; }
    sleep 1
    if python3 - "$WORK/fsroot" <<'PY'
import os, sys
root = sys.argv[1]
staging = [os.path.join(base, name) for base, _d, names in os.walk(root)
           for name in names if name.startswith(".pocketdeck-") and name.endswith(".part")]
partial = os.path.exists(os.path.join(root, "PDWrite-kill.bin"))
print("staging=%d partial=%s" % (len(staging), partial))
sys.exit(1 if staging or partial else 0)
PY
    then
        ok "WRITE the killed write left no staging file and no partial file"
    else
        bad "WRITE the killed write left something behind on the fake tree"
    fi
    # Nothing about a write may put a name or a byte value in the app log.
    log show --last 3m --info \
        --predicate 'subsystem == "dev.pocketdeck.mac" AND category == "files"' 2>/dev/null \
        | grep -o 'bridge: write.*' > "$WORK/write-log.txt" 2>/dev/null || true
    if grep -q "bridge: write" "$WORK/write-log.txt"; then
        ok "WRITE the app logged write op names and sizes only"
    else
        bad "WRITE the app logged no write activity"
    fi
    if python3 - "$WORK/fsroot" "$WORK/write-log.txt" <<'PY'
import os, sys
root, log = sys.argv[1], sys.argv[2]
text = open(log, errors="replace").read()
names = set(os.listdir(root)) | {"a3.bin", "a32.bin", "stale.bin", "renamed.bin", "PDWrite"}
bad = [name for name in names if name and (name + " (from Mac)" in text or "/" + name in text)]
sys.exit(1 if bad else 0)
PY
    then
        ok "WRITE no file name from the tree appears in the app log"
    else
        bad "WRITE a file name appears in the app log"
    fi
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# check_files_watch — remote changes (slice S5, docs/design/files.md §2/§5):
# the driver plays the extension, opens folder A (bridge watch), and creates,
# edits, renames and deletes files there while fakephone watches. Each move must
# arrive as a bridge signal plus the right delta (the rename keeps the item id),
# a change in an unwatched folder B must say nothing, the Mac's own write must
# not echo, and closing A (or killing the driver) must stop the watch on the
# phone. No File Provider anywhere.
WATCH_FOLDERS=""   # the 65 folders the watch-set step touches, set by the check

check_files_watch() {
    clean
    python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
root = os.path.join(work, "fsroot")
for folder in ("A", "B"):
    os.makedirs(os.path.join(root, folder), exist_ok=True)
open(os.path.join(root, "A", "seed.txt"), "wb").write(b"seed\n")
open(os.path.join(root, "B", "other.txt"), "wb").write(b"other\n")
# 65 folders for the watch-set cap: the 65th touch drops the least recently
# touched and the phone never watches more than 64.
for index in range(65):
    os.makedirs(os.path.join(root, "W%02d" % index), exist_ok=True)
PY
    WATCH_FOLDERS="$(python3 -c 'print(",".join("W%02d" % i for i in range(65)))')"
    FAKE_ARGS="--fs-root $WORK/fsroot" start_fake || return 1
    # The ten minutes are shortened for this run only (design "S5 round 3").
    PD_FILES_WATCH_TTL=20 launch --connect "127.0.0.1:$PORT" --files-bridge-dir "$WORK/bridge"
    wait_until 30 file_has "files-bridge: ok" "$WORK/app.log" \
        && ok "WATCH the app listens on the test bridge socket" \
        || bad "WATCH no bridge socket: $(grep 'files-bridge' "$WORK/app.log" | tail -2)"
    if ! wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""'; then
        bad "WATCH the app never authenticated"
        stop_app; stop_fakephone; return 1
    fi
    # Idle before anyone opens a folder.
    if grep -q "watch on" "$WORK/fake.err" 2>/dev/null; then
        bad "WATCH the phone watched something before a folder was opened"
    else
        ok "WATCH nothing is watched while no folder is open"
    fi
    files_bridge_driver watch
    if grep -q "watch on 1" "$WORK/fake.err" 2>/dev/null; then
        ok "WATCH the phone watched the open folder"
    else
        bad "WATCH the phone never watched the folder"
    fi
    if grep -q "changes" "$WORK/fake.err" 2>/dev/null; then
        ok "WATCH the phone reported coalesced changes as counts"
    else
        bad "WATCH the phone logged no change batch"
    fi
    # The watch set: 65 folders keep at most 64 (LRU), and a folder untouched
    # for the test-shortened TTL is unwatched. The driver plays the extension.
    "$MACOS/scripts/files-bridge-driver.py" --socket "$(files_bridge_socket)" \
        --root "$WORK/fsroot" --work "$WORK" --fake-err "$WORK/fake.err" \
        --phase watchset --ttl 20 --watch-folders "$WATCH_FOLDERS" \
        > "$WORK/bridge-watchset.txt" 2>&1
    while IFS= read -r line; do
        case "$line" in
            ok\ *) ok "${line#ok }" ;;
            bad\ *) bad "${line#bad }" ;;
            *) [ -n "$line" ] && say "    $line" ;;
        esac
    done < "$WORK/bridge-watchset.txt"
    if grep -q "fakephone: watch on 64" "$WORK/fake.err" 2>/dev/null; then
        ok "WATCH the phone never watched more than 64 folders"
    else
        bad "WATCH the phone's watch count went past 64: $(grep "watch on" "$WORK/fake.err" | tail -1)"
    fi
    if [ "$(grep -c "fakephone: watch off" "$WORK/fake.err" 2>/dev/null || true)" -ge 2 ]; then
        ok "WATCH watches were dropped: the LRU at the cap and the TTL expiry"
    else
        bad "WATCH no watch off beyond the first: $(grep "watch off" "$WORK/fake.err" | tail -1)"
    fi
    # Names never reach the app log; counts and ids only (design §4).
    log show --last 3m --info \
        --predicate 'subsystem == "dev.pocketdeck.mac" AND category == "files"' 2>/dev/null \
        | grep -o 'bridge: .*' > "$WORK/watch-log.txt" 2>/dev/null || true
    if python3 - "$WORK/watch-log.txt" <<'PY'
import sys
text = open(sys.argv[1], errors="replace").read()
names = ("A", "B", "seed.txt", "one.txt", "one-renamed.txt", "two.txt", "after.txt")
sys.exit(1 if any(("/" + name) in text or ('"' + name + '"') in text for name in names) else 0)
PY
    then
        ok "WATCH the app log carries no file names"
    else
        bad "WATCH a file name appears in the app log"
    fi
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- Phone files in Finder (docs/design/files.md §1/§5, files-domain) ------
#
# The real thing end to end: the app adds its domain, the sandboxed replicated
# extension answers from the app's bridge, and the mount shows the fake phone's
# tree. It adds a File Provider domain, so it refuses to run anywhere but the
# e2e VM (vm-e2e.sh exports PD_E2E_IN_VM=1). Every sub-step records its own
# PASS/FAIL; the first failure never aborts the run.

# The e2e bundle is built with --variant e2e, so its extension and group carry
# that name; the domain identifier is the profile name.
FILES_ID="dev.pocketdeck.mac.files-e2e"
FILES_GROUP="group.dev.pocketdeck.mac.files-e2e"

files_appex() { printf '%s\n' "$E2E_BUNDLE/Contents/PlugIns/Files.appex"; }

# files_oneshot <action> <logfile>: one `--files-domain` action; the app prints
# its result and exits itself (except add, which stays up and runs the bridge).
files_oneshot() {
    PD_E2E_IN_VM=1 "$APP" --profile "$PROFILE" --files-domain "$1" > "$2" 2>&1
}

# files_list — refresh $WORK/list.txt from `--files-domain list`.
files_list() {
    files_oneshot list "$WORK/list.txt" || true
}

# files_field <name> — one field of this profile's domain line in list.txt.
files_field() {
    sed -n "s/^files-domain list: id=$PROFILE .* $1=\([^ ]*\).*/\1/p" "$WORK/list.txt" | tail -1
}

# files_display_name — the domain's display name, which carries spaces.
files_display_name() {
    sed -n "s/^files-domain list: id=$PROFILE .*display=\(.*\) disconnected=.*/\1/p" \
        "$WORK/list.txt" | tail -1
}

# files_display_is <name> — refresh the domain list and compare the name.
files_display_is() {
    files_list
    [ "$(files_display_name)" = "$1" ]
}

# files_fetch_ms <path> — read the whole file through the mount and print the
# wall time in ms: the same materialization Finder and Quick Look trigger.
files_fetch_ms() {
    python3 - "$1" <<'PY'
import sys, time
start = time.time()
with open(sys.argv[1], "rb") as handle:
    while handle.read(1 << 20):
        pass
print(int((time.time() - start) * 1000))
PY
}

# files_fetch_ms_warm <path> — the same, with one retry. The first access to a
# dataless item right after a 1500-entry enumeration can time out in the mount
# (Errno 60) before the extension is asked at all (the VM run of 2026-10-20 did
# exactly that); the retry is what Finder itself does, and the extension's own
# `fetch done ... ms=` line below still catches a slow fetch either way.
files_fetch_ms_warm() {
    local first
    first="$(files_fetch_ms "$1" 2>> "$WORK/fetch-time.err")"
    if [ -n "$first" ]; then printf '%s\n' "$first"; return 0; fi
    sleep 2
    files_fetch_ms "$1" 2>> "$WORK/fetch-time.err"
}

# files_domain_path — the domain root's user-visible URL, from `--files-domain list`.
files_domain_path() {
    sed -n "s/^files-domain list: path id=$PROFILE //p" "$WORK/list.txt" | tail -1
}

file_has() { grep -qF -- "$1" "$2" 2>/dev/null; }

# files_log — every line this app's files subsystems logged in the last minutes.
files_log() {
    log show --last 10m --info \
        --predicate 'subsystem == "dev.pocketdeck.mac" AND category == "files"' 2>/dev/null
}

# files_root_lists <path> — the domain answers a listing (not a disabled or
# timed-out mount).
files_root_lists() {
    [ -n "${1:-}" ] && [ "$(run_limited 15 ls "$1" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]
}

# files_disconnected <yes|no> — this profile's domain says so in list.txt.
files_disconnected() {
    files_list
    [ "$(files_field disconnected)" = "$1" ]
}

# files_enable_provider — a new File Provider domain starts user-disabled: every
# job fails with FP -2011 "Sync is not enabled" and the mount times out, until
# the person turns the extension on in System Settings › General › Login Items &
# Extensions › Extensions. There is no API for that switch (fileproviderctl has
# no enable command; `pluginkit -e use` does not move it), so the check walks the
# same path a person does: the app's URL opens the pane, then the accessibility
# tree presses the app's info button and its "File Provider" toggle. The screen
# is the VM's fixed 1024x768 points.
files_enable_provider() {
    cat > "$WORK/enable-files.sh" <<'SH'
#!/bin/bash
set -e
open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions"
sleep 3
osascript <<'OSA'
tell application "System Events"
	tell process "System Settings"
		-- "By App" (the pane remembers whichever side was picked last).
		set rb to radio button 1 of radio group 1 of group 3 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window "Login Items & Extensions"
		if (value of rb) is 0 then click rb
		delay 0.5
		-- The app's row may be below the fold.
		set value of scroll bar 1 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window "Login Items & Extensions" to 1.0
		delay 0.5
		-- Its info button sits on the same row as the app name.
		tell group 4 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window "Login Items & Extensions"
			set rowY to item 2 of (get position of static text "PocketDeck")
			repeat with b in (get buttons)
				set btnY to item 2 of (get position of b)
				if btnY > (rowY - 4) and btnY < (rowY + 4) then
					click b
					exit repeat
				end if
			end repeat
		end tell
		delay 1
		set cb to checkbox "File Provider" of group 2 of scroll area 1 of group 1 of sheet 1 of window "Login Items & Extensions"
		if (value of cb) is 0 then click cb
		delay 0.5
		if (value of cb) is not 1 then error "the File Provider switch did not turn on"
		try
			click button "Done" of sheet 1 of window "Login Items & Extensions"
		end try
	end tell
end tell
OSA
SH
    gui_run bash "$WORK/enable-files.sh"
}

# run_limited <seconds> <command...> — a provider that never answers must not
# hang the run (ls/cat on a stalled domain would).
run_limited() { local secs="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

# files_tree — the fake /sdcard: folders, ~40 files in Documents, 1500 in many
# (so the enumerator follows pages), a 3 MiB file, a 32 MiB file, a real JPEG,
# and the things the domain must hide (Android/, dots).
files_tree() {
    python3 - "$WORK" <<'PY'
import base64, os, sys
work = sys.argv[1]
root = os.path.join(work, "fsroot")
for folder in ("Documents", "Documents/notes", "DCIM/Camera", "many",
               "Android/data/x", ".Trash"):
    os.makedirs(os.path.join(root, folder), exist_ok=True)
open(os.path.join(root, "Android/data/x/y"), "wb").write(b"hidden")
open(os.path.join(root, ".hidden"), "wb").write(b"hidden")
open(os.path.join(root, ".Trash", "gone.txt"), "wb").write(b"hidden")
for i in range(40):
    with open(os.path.join(root, "Documents", "file%02d.txt" % i), "wb") as handle:
        handle.write(("small %d\n" % i).encode() * (i + 1))
# A valid 1x1 JPEG, so Quick Look has something to render.
jpeg = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a"
    "HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAA"
    "AAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")
open(os.path.join(root, "DCIM/Camera/photo.jpg"), "wb").write(jpeg)
with open(os.path.join(root, "big3.bin"), "wb") as handle:
    handle.write(os.urandom(3 * 1024 * 1024))
# One exact mebibyte for the fetch-time check (the extension logs bytes).
open(os.path.join(root, "open1m.bin"), "wb").write(os.urandom(1024 * 1024))
with open(os.path.join(root, "big32.bin"), "wb") as handle:
    handle.write(os.urandom(32 * 1024 * 1024))
for i in range(1500):
    open(os.path.join(root, "many", "m%04d.txt" % i), "wb").close()
PY
}

# files_visible_root — the names the person should see (sorted, one per line).
files_visible_root() {
    python3 - "$WORK/fsroot" <<'PY'
import os, sys
root = sys.argv[1]
print("\n".join(sorted(name for name in os.listdir(root)
                       if not name.startswith(".") and name != "Android")))
PY
}

check_files_domain() {
    if [ "${PD_E2E_IN_VM:-0}" != "1" ]; then
        bad "FILES-DOMAIN refuses to run on the host (it adds a File Provider domain); run macos/scripts/vm-e2e.sh files-domain"
        return
    fi
    clean
    local appex; appex="$(files_appex)"

    # -- The bundle shape the File Provider extension point needs --------------
    /usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$appex/Contents/Info.plist" 2>/dev/null \
        | grep -qx "com.apple.fileprovider-nonui" \
        && ok "FILES bundle has Files.appex (com.apple.fileprovider-nonui)" \
        || bad "FILES Files.appex missing or wrong NSExtensionPointIdentifier"
    local principal documentgroup bundle_group
    principal="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$appex/Contents/Info.plist" 2>/dev/null)"
    documentgroup="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionFileProviderDocumentGroup' "$appex/Contents/Info.plist" 2>/dev/null)"
    bundle_group="$(/usr/libexec/PlistBuddy -c 'Print :PDFilesGroup' "$appex/Contents/Info.plist" 2>/dev/null)"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionFileProviderSupportsEnumeration' "$appex/Contents/Info.plist" 2>/dev/null)" = "true" ] \
        && [ "$documentgroup" = "$FILES_GROUP" ] && [ "$bundle_group" = "$FILES_GROUP" ] && [ -n "$principal" ] \
        && ok "FILES principal=$principal, enumerates, document group $documentgroup" \
        || bad "FILES Info.plist lacks enumeration/document group/principal class"
    codesign --verify --deep --strict "$E2E_BUNDLE" 2>/dev/null \
        && codesign -d --entitlements - "$appex" 2>/dev/null | grep -q app-sandbox \
        && codesign -d --entitlements - "$appex" 2>/dev/null | grep -q "$FILES_GROUP" \
        && ok "FILES codesign --deep --strict passes; extension sandboxed, group $FILES_GROUP" \
        || bad "FILES codesign verify failed or the extension lacks sandbox/app group"
    codesign -d --entitlements - "$E2E_BUNDLE" 2>/dev/null | grep -q "$FILES_GROUP" \
        && ok "FILES the app carries the same App Group" || bad "FILES the app has no App Group"
    codesign -d --entitlements - "$appex" 2>/dev/null | grep -q "temporary-exception" \
        && bad "FILES the extension still carries the experiment's temporary exception" \
        || ok "FILES the extension has no temporary sandbox exception"

    # -- The fake phone and the app (the domain is added at launch) ------------
    files_tree
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-chunk-delay-ms 4" start_fake || return 1
    "$LSREGISTER" -f "$E2E_BUNDLE" >/dev/null 2>&1
    pluginkit -a "$appex" >/dev/null 2>&1
    pluginkit -e use -i "$FILES_ID" >/dev/null 2>&1
    pluginkit -m -p com.apple.fileprovider-nonui -v > "$WORK/pluginkit.txt" 2>&1
    file_has "$appex" "$WORK/pluginkit.txt" \
        && ok "FILES pluginkit lists the extension at $appex" \
        || bad "FILES pluginkit does not list $appex ($(head -3 "$WORK/pluginkit.txt" | tr '\n' ' '))"
    # The domain must not exist from an earlier run: remove it, then add. After
    # the bundle and its extension are registered: run before that, the remove
    # said "not found" while a domain left by a run that was cut short (a VM's
    # disk persists) stayed registered, stuck in its disk import, and every
    # later run re-added onto it. The listings around it are the evidence.
    files_oneshot list "$WORK/list-before.txt" >/dev/null 2>&1 || true
    files_oneshot remove "$WORK/remove-before.txt" >/dev/null 2>&1 || true
    files_oneshot list "$WORK/list-after-remove.txt" >/dev/null 2>&1 || true
    # The removal deletes the domain's CloudStorage folder after its completion
    # handler: an add before that finds the old folder and imports it from disk
    # (every listing then stalls). Wait for the folder to go.
    stale_domain_folder() { ls -d "$HOME"/Library/CloudStorage/PocketDeck-* >/dev/null 2>&1; }
    wait_until 60 eval '! stale_domain_folder' \
        || bad "FILES the removed domain's folder is still in CloudStorage after 60 s"

    launch --connect "127.0.0.1:$PORT" --files-domain add
    wait_until 30 file_has "files-domain add: ok" "$WORK/app.log" \
        && ok "FILES NSFileProviderManager.add ok" \
        || bad "FILES add failed: $(grep 'files-domain' "$WORK/app.log" | head -2 | tr '\n' ' ')"
    wait_until 20 file_has "files-domain bridge group: ok" "$WORK/app.log" \
        && ok "FILES the bridge listens on the App Group socket" \
        || bad "FILES no App Group socket: $(grep 'files-domain bridge' "$WORK/app.log" | tr '\n' ' ')"
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "FILES the app never authenticated"; stop_app; stop_fakephone; return 1; }

    files_list
    file_has "files-domain list: id=$PROFILE" "$WORK/list.txt" \
        && ok "FILES getDomains shows the profile's domain" \
        || bad "FILES getDomains does not show the domain: $(head -2 "$WORK/list.txt" | tr '\n' ' ')"

    local root; root="$(files_domain_path)"
    # The person's one-time step: a fresh domain is user-disabled (FP -2011).
    files_enable_provider > "$WORK/enable-files.txt" 2>&1 || true
    wait_until 90 files_root_lists "$root" \
        && ok "FILES the System Settings switch is on; the domain enumerates" \
        || bad "FILES still user-disabled after the System Settings switch ($(tail -2 "$WORK/enable-files.txt" | tr '\n' ' '))"
    if [ -z "$root" ] || [ ! -d "$root" ]; then
        bad "FILES no visible domain path (list: $root)"
        kill_e2e_app
        files_oneshot remove "$WORK/remove.txt" || true
        unregister_files
        return 1
    fi
    ok "FILES the domain is mounted at $root"
    run_limited 15 ls -la "$HOME/Library/CloudStorage/" > "$WORK/cloudstorage.txt" 2>&1 || true
    echo "CloudStorage:"; sed 's/^/    /' "$WORK/cloudstorage.txt"

    # -- The mount is the phone's shared storage ------------------------------
    run_limited 60 ls "$root" 2>/dev/null | sort > "$WORK/domain-root.txt"
    files_visible_root > "$WORK/expected-root.txt"
    cmp -s "$WORK/domain-root.txt" "$WORK/expected-root.txt" \
        && ok "FILES the root lists the fake tree and leaves out Android and dots ($(wc -l < "$WORK/domain-root.txt" | tr -d ' ') items)" \
        || bad "FILES root differs: $(diff "$WORK/expected-root.txt" "$WORK/domain-root.txt" | head -4 | tr '\n' ' ')"
    local docs many
    docs="$(run_limited 60 ls "$root/Documents" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$docs" = "41" ] \
        && ok "FILES Documents lists its 40 files and one folder ($docs entries)" \
        || bad "FILES Documents has $docs entries, wanted 41"
    many="$(run_limited 120 ls "$root/many" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$many" = "1500" ] \
        && ok "FILES many lists all 1500 names across pages" \
        || bad "FILES many lists $many names, wanted 1500"

    # -- The location names the phone (user request, "Fixes 10-20") -----------
    # The domain was added at launch, before any phone was known; the session
    # then remembered the phone and its name, and the domain was updated in
    # place. The location is "PocketDeck (<the name every surface uses>)".
    wait_until 60 files_display_is "PocketDeck (FakePhone)" \
        && ok "FILES the Finder location is \"PocketDeck (FakePhone)\"" \
        || bad "FILES the location is \"$(files_display_name)\", wanted \"PocketDeck (FakePhone)\""

    # -- A fetch is one round trip, not twenty seconds ("Fixes 10-20") --------
    # The extension used to wait for a terminal reply that never came, until
    # the socket's 20 s receive timeout: a 412-byte Quick Look file took 20 s,
    # twice. Small (≤ 1 KB) and 1 MiB reads must finish well under 3 s.
    local small_size small_ms small_log big_ms big_log
    small_size="$(stat -f%z "$WORK/fsroot/Documents/file01.txt" 2>/dev/null || echo 0)"
    small_ms="$(files_fetch_ms_warm "$root/Documents/file01.txt")"
    big_ms="$(files_fetch_ms_warm "$root/open1m.bin")"
    files_log > "$WORK/files-log-fetch.txt" 2>/dev/null || true
    small_log="$(sed -n "s/.*fetch done bytes=$small_size ms=\([0-9]*\).*/\1/p" "$WORK/files-log-fetch.txt" | tail -1)"
    big_log="$(sed -n "s/.*fetch done bytes=1048576 ms=\([0-9]*\).*/\1/p" "$WORK/files-log-fetch.txt" | tail -1)"
    [ "$small_size" -gt 0 ] && [ "$small_size" -le 1024 ] \
        && ok "FILES the small file is $small_size bytes" \
        || bad "FILES the small file is $small_size bytes, wanted ≤ 1024"
    [ -n "$small_ms" ] && [ "$small_ms" -lt 3000 ] \
        && ok "FILES a $small_size-byte fetch takes ${small_ms} ms (extension logged ${small_log:-?} ms)" \
        || bad "FILES the $small_size-byte fetch took ${small_ms} ms (wanted < 3000; extension ${small_log:-no line})"
    [ -n "$big_ms" ] && [ "$big_ms" -lt 3000 ] \
        && ok "FILES a 1 MiB fetch takes ${big_ms} ms (extension logged ${big_log:-?} ms)" \
        || bad "FILES the 1 MiB fetch took ${big_ms} ms (wanted < 3000; extension ${big_log:-no line})"
    [ -n "$small_log" ] && [ "$small_log" -lt 3000 ] \
        && ok "FILES the extension logged the small fetch at ${small_log} ms" \
        || bad "FILES the extension's small fetch line is '${small_log:-missing}'"
    [ -n "$big_log" ] && [ "$big_log" -lt 3000 ] \
        && ok "FILES the extension logged the 1 MiB fetch at ${big_log} ms" \
        || bad "FILES the extension's 1 MiB fetch line is '${big_log:-missing}'"

    # -- A name that appeared on the phone after the listing (collision) ------
    # A photo taken since the Mac looked: the name is not in the enumeration,
    # so the copy is a create. The phone refuses it (exclusive); the Mac's file
    # must not replace the phone's. A POSIX create has no "pick another name"
    # step, so the system retries the same name: what matters here is that the
    # phone's bytes survive every retry.
    python3 - "$WORK/fsroot/Documents/collide.bin" "$WORK/collide-mac.bin" <<'PY'
import os, sys
open(sys.argv[1], "wb").write(b"the phone's own bytes\n" * 900)
open(sys.argv[2], "wb").write(os.urandom(64 * 1024))
PY
    local phone_collide_sha mac_collide_sha
    phone_collide_sha="$(shasum -a 256 "$WORK/fsroot/Documents/collide.bin" | cut -c1-64)"
    mac_collide_sha="$(shasum -a 256 "$WORK/collide-mac.bin" | cut -c1-64)"
    run_limited 180 cp "$WORK/collide-mac.bin" "$root/Documents/collide.bin" 2> "$WORK/collide.err" || true
    local landed=""
    for _ in $(seq 1 90); do
        landed="$(python3 - "$WORK/fsroot/Documents" "$mac_collide_sha" "$phone_collide_sha" <<'PY'
import hashlib, os, sys
folder, want, phone = sys.argv[1], sys.argv[2], sys.argv[3]
for name in sorted(os.listdir(folder)):
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        continue
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if digest == want and digest != phone:
        print(name)
        break
PY
)"
        [ -n "$landed" ] && break
        sleep 2
    done
    files_log > "$WORK/collide-log.txt" 2>/dev/null || true
    local refusals=0
    refusals="$(grep -c 'write failed code=fs_exists' "$WORK/collide-log.txt" 2>/dev/null || true)"
    local phone_kept="no"
    [ "$(shasum -a 256 "$WORK/fsroot/Documents/collide.bin" | cut -c1-64)" = "$phone_collide_sha" ] \
        && phone_kept="yes"
    printf 'name=%s\nphone_kept=%s\nrefusals=%s\ncp_error=%s\n' \
        "$landed" "$phone_kept" "$refusals" "$(head -1 "$WORK/collide.err")" > "$WORK/collision.txt"
    [ "$phone_kept" = "yes" ] \
        && ok "WRITE a copy onto a name the phone has leaves the phone's bytes" \
        || bad "WRITE the collision copy replaced the phone's file"
    # S5: the extension resolves the collision itself, so the Mac's copy lands
    # as `collide 2.bin` and nothing is left pending for it.
    [ "$landed" = "collide 2.bin" ] \
        && ok "WRITE the copy lands under the next free name (name hash $(printf '%s' "$landed" | shasum -a 256 | cut -c1-12))" \
        || bad "WRITE the collision copy landed as '${landed:-nothing}' (refusals=$refusals)"
    if [ -n "$landed" ]; then
        rm -f "$WORK/fsroot/Documents/$landed"
    fi
    if command -v fileproviderctl >/dev/null 2>&1; then
        perl -e 'alarm 20; exec @ARGV' fileproviderctl dump > "$WORK/fp-collide.txt" 2>&1 || true
        local pending_collide
        pending_collide="$(grep -Eic 'collide.*(pending|upload)' "$WORK/fp-collide.txt" || true)"
        [ "${pending_collide:-0}" = "0" ] \
            && ok "WRITE nothing is pending for the collision copy in fileproviderctl dump" \
            || bad "WRITE the collision copy is still pending ($pending_collide lines)"
    fi

    # -- Bytes: the phone's exact file, out of the mount ----------------------
    local want
    want="$(shasum -a 256 "$WORK/fsroot/big3.bin" | cut -c1-64)"
    run_limited 180 cat "$root/big3.bin" > "$WORK/cat3.bin" 2> "$WORK/cat3.err"
    [ "$(shasum -a 256 "$WORK/cat3.bin" 2>/dev/null | cut -c1-64)" = "$want" ] \
        && ok "FILES cat of the 3 MiB file is byte-identical (sha ${want:0:12}...)" \
        || bad "FILES cat differs: $(head -1 "$WORK/cat3.err")"
    run_limited 180 cp "$root/big3.bin" "$WORK/cp3.bin" 2> "$WORK/cp3.err"
    [ "$(shasum -a 256 "$WORK/cp3.bin" 2>/dev/null | cut -c1-64)" = "$want" ] \
        && ok "FILES a copy out of the mount is byte-identical" \
        || bad "FILES cp differs: $(head -1 "$WORK/cp3.err")"

    # -- Quick Look of a jpg from the tree ------------------------------------
    perl -e 'alarm 90; exec @ARGV' qlmanage -t -s 128 -o "$WORK" "$root/DCIM/Camera/photo.jpg" > "$WORK/qlmanage.txt" 2>&1 || true
    ls "$WORK"/photo.jpg.png >/dev/null 2>&1 \
        && ok "FILES Quick Look wrote a thumbnail of the jpg ($WORK/photo.jpg.png)" \
        || bad "FILES Quick Look wrote no jpg thumbnail: $(tail -2 "$WORK/qlmanage.txt" | tr '\n' ' ')"

    # -- A preview writes nothing to the phone ("Fixes 10-20") ----------------
    # Opening or previewing an item made the system send a modify that changes
    # nothing the phone stores (last-used date, tags, favourite rank); the old
    # extension forwarded it, so the phone re-wrote the file. The fix answers
    # locally: no `bridge: modify` line, and the preview's watch names the
    # file's folder, never the file (`fs_not_a_dir`).
    files_log > "$WORK/files-log-preview-before.txt" 2>/dev/null || true
    local modify_before modify_after watch_failures
    modify_before="$(grep -c 'bridge: modify' "$WORK/files-log-preview-before.txt" 2>/dev/null || true)"
    perl -e 'alarm 90; exec @ARGV' qlmanage -t -s 64 -o "$WORK" "$root/Documents/file02.txt" \
        > "$WORK/qlmanage-small.txt" 2>&1 || true
    perl -e 'alarm 90; exec @ARGV' qlmanage -t -s 128 -o "$WORK" "$root/DCIM/Camera/photo.jpg" \
        > "$WORK/qlmanage-again.txt" 2>&1 || true
    sleep 4
    files_log > "$WORK/files-log-preview-after.txt" 2>/dev/null || true
    modify_after="$(grep -c 'bridge: modify' "$WORK/files-log-preview-after.txt" 2>/dev/null || true)"
    [ "${modify_after:-0}" -eq "${modify_before:-0}" ] \
        && ok "FILES a preview sends no bridge modify (${modify_before:-0} before, ${modify_after:-0} after)" \
        || bad "FILES a preview sent $(( ${modify_after:-0} - ${modify_before:-0} )) bridge modify line(s)"
    watch_failures="$(grep -c 'fs_not_a_dir' "$WORK/files-log-preview-after.txt" 2>/dev/null || true)"
    [ "${watch_failures:-0}" -eq 0 ] \
        && ok "FILES no watch named a file (no fs_not_a_dir)" \
        || bad "FILES $watch_failures watch(es) named a file (fs_not_a_dir)"

    # -- The extension served it over the bridge ------------------------------
    files_log > "$WORK/files-log.txt"
    file_has "bridge: list page" "$WORK/files-log.txt" \
        && ok "FILES the app's bridge logged listings" \
        || bad "FILES no bridge listing in the log"
    if grep -q "init profile=" "$WORK/files-log.txt" \
        && grep -q "fetch done" "$WORK/files-log.txt"; then
        ok "FILES the extension ran and fetched through the bridge"
    else
        bad "FILES no extension init/fetch in the log: $(grep -E 'init|fetch' "$WORK/files-log.txt" | head -3 | tr '\n' ' ')"
    fi
    if python3 - "$WORK/fsroot" "$WORK/files-log.txt" <<'PY'
import os, sys
root, log = sys.argv[1], sys.argv[2]
text = open(log, errors="replace").read()
names = set(os.listdir(root)) | set(os.listdir(os.path.join(root, "Documents")))
bad = [name for name in names
       if ("/" + name) in text or (name + "/") in text or ('"' + name + '"') in text]
sys.exit(1 if bad else 0)
PY
    then
        ok "FILES no file name from the tree appears in the logs"
    else
        bad "FILES a file name appears in the logs"
    fi
    if command -v fileproviderctl >/dev/null 2>&1; then
        perl -e 'alarm 20; exec @ARGV' fileproviderctl dump > "$WORK/fileproviderctl.txt" 2>&1 || true
    else
        echo "fileproviderctl not found" > "$WORK/fileproviderctl.txt"
    fi
    grep -qE "enabled: +yes" "$WORK/fileproviderctl.txt" \
        && ok "FILES fileproviderctl says the domain is enabled" \
        || bad "FILES fileproviderctl does not show an enabled domain"

    # -- Writes: create, edit, rename, mkdir, delete (S4) --------------------
    # The person's actions are Finder's ordinary ones; the check looks at the
    # fake phone's tree, which is the only side that can prove the bytes.
    local up3
    python3 - "$WORK/up3.bin" <<'PY'
import os, sys
open(sys.argv[1], "wb").write(os.urandom(3 * 1024 * 1024))
PY
    up3="$(shasum -a 256 "$WORK/up3.bin" | cut -c1-64)"
    run_limited 240 cp "$WORK/up3.bin" "$root/Documents/upload3.bin" 2> "$WORK/up3.err" || true
    wait_until 180 eval "[ -f \"$WORK/fsroot/Documents/upload3.bin\" ]" \
        && ok "WRITE a 3 MiB copy into the mount lands on the fake phone" \
        || bad "WRITE the copy never reached the phone: $(head -1 "$WORK/up3.err")"
    wait_until 120 eval "[ \"\$(shasum -a 256 \"$WORK/fsroot/Documents/upload3.bin\" 2>/dev/null | cut -c1-64)\" = \"$up3\" ]" \
        && ok "WRITE the phone's bytes are the copied file's (sha ${up3:0:12}...)" \
        || bad "WRITE the phone's bytes differ from the copy"

    # An edit in place: append and let the provider upload the new content.
    printf 'an edit from the Mac\n' >> "$root/Documents/upload3.bin" 2>/dev/null || true
    # Appending changed the bytes; the phone must reach the mount's new size.
    local want_size
    want_size="$(stat -f%z "$root/Documents/upload3.bin" 2>/dev/null || echo 0)"
    wait_until 120 eval "[ \"\$(stat -f%z \"$WORK/fsroot/Documents/upload3.bin\" 2>/dev/null || echo 0)\" = \"$want_size\" ]" \
        && ok "WRITE an edit in place reaches the phone (size $want_size)" \
        || bad "WRITE the edit never reached the phone (mount $want_size, phone $(stat -f%z "$WORK/fsroot/Documents/upload3.bin" 2>/dev/null || echo 0))"

    # A rename in the same folder: the fake tree follows, and the mount still
    # shows one entry (the item was not duplicated). The identifier itself is
    # asserted by the host `files-write` driver (same id before and after).
    run_limited 120 mv "$root/Documents/upload3.bin" "$root/Documents/renamed3.bin" 2> "$WORK/mv.err" || true
    wait_until 120 eval "[ -f \"$WORK/fsroot/Documents/renamed3.bin\" ] && [ ! -f \"$WORK/fsroot/Documents/upload3.bin\" ]" \
        && ok "WRITE a rename follows on the phone (name hash $(printf renamed3.bin | shasum -a 256 | cut -c1-12))" \
        || bad "WRITE the rename did not reach the phone: $(head -1 "$WORK/mv.err")"
    local renamed_count
    renamed_count="$(run_limited 60 ls "$root/Documents" 2>/dev/null | grep -c '^renamed3.bin$' || true)"
    [ "$renamed_count" = "1" ] \
        && ok "WRITE the renamed item appears once in the folder (no duplicate)" \
        || bad "WRITE the renamed item appears $renamed_count times"

    # mkdir and delete.
    run_limited 120 mkdir "$root/Documents/PDNew" 2> "$WORK/mkdir-write.err" || true
    wait_until 120 eval "[ -d \"$WORK/fsroot/Documents/PDNew\" ]" \
        && ok "WRITE mkdir reaches the phone" \
        || bad "WRITE mkdir did not reach the phone: $(head -1 "$WORK/mkdir-write.err")"
    run_limited 120 rm "$root/Documents/renamed3.bin" 2> "$WORK/rm-write.err" || true
    wait_until 120 eval "[ ! -f \"$WORK/fsroot/Documents/renamed3.bin\" ]" \
        && ok "WRITE delete removes the file on the phone" \
        || bad "WRITE delete did not reach the phone: $(head -1 "$WORK/rm-write.err")"
    run_limited 120 rmdir "$root/Documents/PDNew" 2>/dev/null || true
    wait_until 60 eval "[ ! -d \"$WORK/fsroot/Documents/PDNew\" ]" || true

    # -- The phone goes away: disconnected, cached file still opens -----------
    stop_fakephone
    wait_until 5 no_fakephone
    wait_until 45 files_disconnected true \
        && ok "FILES the phone leaving disconnects the domain" \
        || bad "FILES the domain is not disconnected: $(grep "id=$PROFILE " "$WORK/list.txt" | head -1)"
    run_limited 60 cat "$root/big3.bin" > "$WORK/cached3.bin" 2>/dev/null
    [ "$(shasum -a 256 "$WORK/cached3.bin" 2>/dev/null | cut -c1-64)" = "$want" ] \
        && ok "FILES the already-fetched file still opens while the phone is away" \
        || bad "FILES the cached file did not open while the phone is away"
    # While the phone is away a copy is accepted locally (a pending item); it
    # must land once the phone is back.
    local pending_sha
    pending_sha="$(shasum -a 256 "$WORK/up3.bin" | cut -c1-64)"
    run_limited 120 cp "$WORK/up3.bin" "$root/Documents/pending.bin" 2> "$WORK/pending.err" || true
    PENDING_WRITTEN=0
    [ -e "$root/Documents/pending.bin" ] && PENDING_WRITTEN=1
    ok "WRITE a copy made while the phone is away is accepted locally"

    # -- The phone comes back: reconnect --------------------------------------
    FAKE_ARGS="--fs-root $WORK/fsroot" start_fake "$WORK/state.json" || true
    wait_until 60 files_disconnected false \
        && ok "FILES the domain reconnects when the phone is back" \
        || bad "FILES the domain did not reconnect: $(grep "id=$PROFILE " "$WORK/list.txt" | head -1)"
    wait_until 60 files_root_lists "$root" || true
    if [ "${PENDING_WRITTEN:-0}" = "1" ]; then
        wait_until 180 eval "[ \"\$(shasum -a 256 \"$WORK/fsroot/Documents/pending.bin\" 2>/dev/null | cut -c1-64)\" = \"$pending_sha\" ]" \
            && ok "WRITE the pending copy lands on the phone after the reconnect (sha ${pending_sha:0:12}...)" \
            || bad "WRITE the pending copy never landed"
        rm -f "$WORK/fsroot/Documents/pending.bin"
    else
        bad "WRITE the offline copy was refused instead of kept pending: $(head -1 "$WORK/pending.err")"
    fi
    local want32
    want32="$(shasum -a 256 "$WORK/fsroot/big32.bin" | cut -c1-64)"
    run_limited 240 cat "$root/big32.bin" > "$WORK/cat32.bin" 2>/dev/null
    [ "$(shasum -a 256 "$WORK/cat32.bin" 2>/dev/null | cut -c1-64)" = "$want32" ] \
        && ok "FILES after the reconnect the 32 MiB file reads byte-identical" \
        || bad "FILES the 32 MiB file after reconnect is not identical"

    # -- Phone-side changes reach the mount (S5, design §2/§5) ---------------
    # Documents is open in Finder: a file made on the phone must appear in the
    # mount within 10 s, a rename must replace it, a delete must remove it, and
    # closing Finder must stop the phone's watch.
    local watch_before watch_after watch_on_before
    watch_before="$(grep -c "watch off" "$WORK/fake.err" 2>/dev/null || true)"
    watch_on_before="$(grep -c "watch on" "$WORK/fake.err" 2>/dev/null || true)"
    open -a Finder "$root/Documents" >/dev/null 2>&1 || true
    # The change below has to happen *after* the phone started watching the
    # folder: a file that predates the watch is in its baseline, not a change.
    for _ in $(seq 1 40); do
        [ "$(grep -c "watch on" "$WORK/fake.err" 2>/dev/null || true)" -gt "${watch_on_before:-0}" ] && break
        sleep 0.25
    done
    sleep 1
    python3 - "$WORK/fsroot/Documents" <<'PY'
import os, sys
open(os.path.join(sys.argv[1], "phonechange.txt"), "wb").write(b"made on the phone\n")
PY
    local seen="no" started took
    started=$SECONDS
    while [ $((SECONDS - started)) -lt 10 ]; do
        if run_limited 15 ls "$root/Documents" 2>/dev/null | grep -qx 'phonechange.txt'; then
            seen="yes"; break
        fi
        sleep 0.5
    done
    took=$((SECONDS - started))
    [ "$seen" = "yes" ] && [ "$took" -le 10 ] \
        && ok "WATCH a file created on the phone appears in the mount in ${took}s" \
        || bad "WATCH the phone-side create never reached the mount"
    python3 - "$WORK/fsroot/Documents" <<'PY'
import os, sys
folder = sys.argv[1]
os.rename(os.path.join(folder, "phonechange.txt"),
          os.path.join(folder, "phonechange-renamed.txt"))
PY
    seen="no"
    started=$SECONDS
    while [ $((SECONDS - started)) -lt 10 ]; do
        listing="$(run_limited 15 ls "$root/Documents" 2>/dev/null)"
        if printf '%s\n' "$listing" | grep -qx 'phonechange-renamed.txt' \
            && ! printf '%s\n' "$listing" | grep -qx 'phonechange.txt'; then
            seen="yes"; break
        fi
        sleep 0.5
    done
    took=$((SECONDS - started))
    [ "$seen" = "yes" ] && [ "$took" -le 10 ] \
        && ok "WATCH a rename on the phone follows in the mount in ${took}s (one entry)" \
        || bad "WATCH the phone-side rename did not follow in the mount"
    sleep 2
    screencapture -x "$WORK/finder-watch.png" 2>/dev/null \
        && ok "WATCH screenshot of Finder after the phone-side change: $WORK/finder-watch.png" \
        || bad "WATCH the screenshot after the phone-side change failed"
    if grep -q "watch on" "$WORK/fake.err" 2>/dev/null; then
        ok "WATCH the extension asked the phone to watch the open folder"
    else
        files_log > "$WORK/files-log-watch.txt" 2>/dev/null || true
        bad "WATCH the phone was never asked to watch anything (bridge watch lines: $(grep -c 'bridge: watch' "$WORK/files-log-watch.txt" 2>/dev/null || echo 0), phone-side applies: $(grep -c 'phone watch on' "$WORK/files-log-watch.txt" 2>/dev/null || echo 0))"
    fi
    python3 - "$WORK/fsroot/Documents" <<'PY'
import os, sys
os.unlink(os.path.join(sys.argv[1], "phonechange-renamed.txt"))
PY
    seen="no"
    started=$SECONDS
    while [ $((SECONDS - started)) -lt 10 ]; do
        if ! run_limited 15 ls "$root/Documents" 2>/dev/null | grep -qx 'phonechange-renamed.txt'; then
            seen="yes"; break
        fi
        sleep 0.5
    done
    took=$((SECONDS - started))
    [ "$seen" = "yes" ] && [ "$took" -le 10 ] \
        && ok "WATCH a delete on the phone removes the entry from the mount in ${took}s" \
        || bad "WATCH the phone-side delete did not reach the mount"
    # Round 3 keeps a folder for ten minutes after the last touch: closing the
    # window ends the pushes, not the phone's watch, because the change that
    # arrives with no extension running is exactly the one this round is for.
    osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1 || true
    sleep 4
    watch_after="$(grep -c "watch off" "$WORK/fake.err" 2>/dev/null || true)"
    [ "${watch_after:-0}" -eq "${watch_before:-0}" ] \
        && ok "WATCH closing Finder leaves the folder watched for its ten minutes" \
        || bad "WATCH closing Finder dropped the phone's watch at once"

    # -- With no extension process running (the case rounds 1-2 lost) ---------
    # The phone keeps watching; the app re-lists, records the delta and signals
    # the working set, which is what starts an extension again.
    local extension_alive
    extension_alive="$(pgrep -f "Files.appex/Contents/MacOS/Files" 2>/dev/null | head -1 || true)"
    if [ -n "$extension_alive" ]; then
        for _ in $(seq 1 20); do
            extension_alive="$(pgrep -f "Files.appex/Contents/MacOS/Files" 2>/dev/null | head -1 || true)"
            [ -z "$extension_alive" ] && break
            sleep 0.5
        done
    fi
    if [ -n "$extension_alive" ]; then
        pkill -f "Files.appex/Contents/MacOS/Files" 2>/dev/null || true
        sleep 1
        extension_alive="$(pgrep -f "Files.appex/Contents/MacOS/Files" 2>/dev/null | head -1 || true)"
    fi
    [ -z "$extension_alive" ] \
        && ok "WATCH no extension process is running in the guest" \
        || bad "WATCH an extension process is still running ($extension_alive)"
    files_log > "$WORK/files-log-pre-signal.txt" 2>/dev/null || true
    local signals_before changes_before
    signals_before="$(grep -c "signal working set" "$WORK/files-log-pre-signal.txt" 2>/dev/null || true)"
    changes_before="$(grep -c "working set changes" "$WORK/files-log-pre-signal.txt" 2>/dev/null || true)"
    python3 - "$WORK/fsroot/Documents" <<'PY'
import os, sys
open(os.path.join(sys.argv[1], "phonechange2.txt"), "wb").write(b"no extension running\n")
PY
    seen="no"
    started=$SECONDS
    while [ $((SECONDS - started)) -lt 10 ]; do
        if run_limited 15 ls "$root/Documents" 2>/dev/null | grep -qx 'phonechange2.txt'; then
            seen="yes"; break
        fi
        sleep 0.5
    done
    took=$((SECONDS - started))
    [ "$seen" = "yes" ] && [ "$took" -le 10 ] \
        && ok "WATCH with no extension running a phone-side create reaches the mount in ${took}s" \
        || bad "WATCH the phone-side create was lost with no extension running"
    sleep 2
    screencapture -x "$WORK/finder-signal.png" 2>/dev/null \
        && ok "WATCH screenshot of Finder after the working-set signal: $WORK/finder-signal.png" \
        || bad "WATCH the screenshot after the working-set signal failed"
    files_log > "$WORK/files-log-signal.txt" 2>/dev/null || true
    local signals_after changes_after errors_after
    signals_after="$(grep -c "signal working set" "$WORK/files-log-signal.txt" 2>/dev/null || true)"
    changes_after="$(grep -c "working set changes" "$WORK/files-log-signal.txt" 2>/dev/null || true)"
    errors_after="$(grep -c "signal working set failed" "$WORK/files-log-signal.txt" 2>/dev/null || true)"
    [ "${signals_after:-0}" -gt "${signals_before:-0}" ] \
        && ok "WATCH the app signalled the working set (${signals_before:-0} -> ${signals_after:-0}, errors ${errors_after:-0})" \
        || bad "WATCH the app never signalled the working set"
    [ "${changes_after:-0}" -gt "${changes_before:-0}" ] \
        && ok "WATCH the working set was enumerated after the signal (${changes_before:-0} -> ${changes_after:-0})" \
        || bad "WATCH the working-set enumeration never ran after the signal"
    if [ "${errors_after:-0}" -gt 0 ]; then
        say "    $(grep "signal working set failed" "$WORK/files-log-signal.txt" | tail -2 | sed 's/^[^]]*] //')"
    fi
    rm -f "$WORK/fsroot/Documents/phonechange2.txt"

    # -- Finder shows it (screenshot) -----------------------------------------
    # The collision retries can still be in flight minutes later: after all of
    # that, the phone's own file must still be the phone's.
    if [ -n "${phone_collide_sha:-}" ] && [ -f "$WORK/fsroot/Documents/collide.bin" ]; then
        [ "$(shasum -a 256 "$WORK/fsroot/Documents/collide.bin" | cut -c1-64)" = "$phone_collide_sha" ] \
            && ok "WRITE late create retries still did not replace the phone's file" \
            || bad "WRITE a late create retry replaced the phone's file"
        rm -f "$WORK/fsroot/Documents/collide.bin"
    fi
    open -a Finder "$root" >/dev/null 2>&1 || true
    sleep 4
    screencapture -x "$WORK/finder.png" 2>/dev/null \
        && ok "FILES screenshot of Finder at the domain root: $WORK/finder.png" \
        || bad "FILES screencapture failed"
    open -a Finder "$root/Documents" >/dev/null 2>&1 || true
    sleep 4
    screencapture -x "$WORK/finder-documents.png" 2>/dev/null \
        && ok "FILES screenshot of Finder in Documents: $WORK/finder-documents.png" \
        || bad "FILES screencapture (Documents) failed"
    # -- A rename updates the location in place ("Fixes 10-20") ---------------
    # The nickname path Settings → Devices → Rename uses (`--set-nickname`),
    # on a second launch so the first one's "PocketDeck (FakePhone)" above is a
    # settled state. The domain is re-added with the same identifier and the
    # new display name: macOS updates it, so the CloudStorage folder and its
    # cached files stay (the same inode, and the root still lists).
    local folder_before inode_before
    folder_before="$(ls -d "$HOME"/Library/CloudStorage/PocketDeck-* 2>/dev/null | head -1)"
    inode_before="$(stat -f%i "$folder_before" 2>/dev/null || true)"
    kill_e2e_app
    wait_until 20 eval '[ -z "$(e2e_app_pids)" ]' || true
    launch --connect "127.0.0.1:$PORT" --files-domain add --set-nickname "Nicky"
    wait_until 30 eval 'events_have "\"state\":\"auth_ok\"" || events_have "\"state\":\"paired\""' \
        || bad "FILES the rename launch never authenticated"
    wait_until 60 files_display_is "PocketDeck (Nicky)" \
        && ok "FILES a nickname rename updates the location to \"PocketDeck (Nicky)\"" \
        || bad "FILES the location after the rename is \"$(files_display_name)\", wanted \"PocketDeck (Nicky)\""
    local folder_after inode_after root_after
    folder_after="$(ls -d "$HOME"/Library/CloudStorage/PocketDeck-* 2>/dev/null | head -1)"
    inode_after="$(stat -f%i "$folder_after" 2>/dev/null || true)"
    [ -n "$inode_before" ] && [ "$inode_before" = "$inode_after" ] \
        && ok "FILES the rename kept the CloudStorage folder (inode ${inode_before:-?})" \
        || bad "FILES the CloudStorage folder changed across the rename (${inode_before:-none} -> ${inode_after:-none})"
    files_list
    root_after="$(files_domain_path)"
    wait_until 60 files_root_lists "$root_after" \
        && ok "FILES the renamed domain still lists the phone's tree" \
        || bad "FILES the renamed domain does not list at '${root_after:-no path}'"

    # -- Remove the domain, it must be gone -----------------------------------
    kill_e2e_app
    stop_fakephone
    files_oneshot remove "$WORK/remove.txt" || true
    file_has "files-domain remove: ok" "$WORK/remove.txt" \
        && ok "FILES remove ok" \
        || bad "FILES remove: $(head -1 "$WORK/remove.txt")"
    files_list
    file_has "count=0" "$WORK/list.txt" \
        && ok "FILES domain gone from getDomains" \
        || bad "FILES domain still listed: $(grep 'count=' "$WORK/list.txt")"
    unregister_files
    sleep 1
    pluginkit -m -p com.apple.fileprovider-nonui -v > "$WORK/pluginkit-after.txt" 2>&1
    file_has "$appex" "$WORK/pluginkit-after.txt" \
        && bad "FILES the extension is still registered after the check" \
        || ok "FILES $FILES_ID unregistered after the check"
}


# --- C1: the camera wire (docs/PROTOCOL.md "Camera") ----------------------
#
# fakephone + deckctl only: the check is the wire, not the Mac app. It runs
# three fake phones: a normal one (list → start → frames → busy → stop), one
# that evicts the capture after a second (the person's camera app wins), and
# one whose "Let Macs use the camera" is off.

# camctl <deckctl args...> — one deckctl run against this check's fake phone.
camctl() {
    "$FAKE_PY" "$ROOT/tools/fakephone/deckctl.py" --host 127.0.0.1 --port "$PORT" \
        --state "$WORK/deck.json" --pair "$@"
}

check_cam_wire() {
    clean
    start_fake || return 1

    camctl cam list > "$WORK/cam-list.txt" 2> "$WORK/cam-list.err"
    if [ $? -ne 0 ]; then
        bad "CAM-WIRE cam.list failed: $(cat "$WORK/cam-list.err")"
    elif grep -q "cam.cams count=2" "$WORK/cam-list.txt" && grep -q "facing=back" "$WORK/cam-list.txt"; then
        ok "CAM-WIRE cam.list: 2 cameras"
    else
        bad "CAM-WIRE cam.list: $(tr '\n' ' ' < "$WORK/cam-list.txt")"
    fi

    # Start, measure 3 s, ask for a second stream while the first runs, stop.
    camctl cam start --stream 7 --seconds 3 --busy-stream 8 \
        --save-h264 "$WORK/cam.h264" > "$WORK/cam-start.txt" 2> "$WORK/cam-start.err"
    local rc=$?
    local frames fps
    if [ "$rc" -ne 0 ]; then
        bad "CAM-WIRE cam.start failed: $(tail -2 "$WORK/cam-start.err")"
    else
        frames="$(sed -n 's/.*cam\.stats .*frames=\([0-9]*\).*/\1/p' "$WORK/cam-start.txt" | tail -1)"
        fps="$(sed -n 's/.*cam\.stats .*\(fps=[0-9.]*\).*/\1/p' "$WORK/cam-start.txt" | tail -1)"
        [ -n "$frames" ] && [ "$frames" -ge 60 ] \
            && ok "CAM-WIRE 3 s of frames: $frames ($fps)" \
            || bad "CAM-WIRE only $frames frames in 3 s ($fps)"
        grep -q "first_key=True sps_pps=True" "$WORK/cam-start.txt" \
            && ok "CAM-WIRE the first keyframe carries SPS/PPS" \
            || bad "CAM-WIRE first frame: $(grep 'cam.stats' "$WORK/cam-start.txt")"
        grep -q "key_gap_ms=none" "$WORK/cam-start.txt" \
            && bad "CAM-WIRE only one keyframe in 3 s (interval is 2 s)" \
            || ok "CAM-WIRE keyframe interval: $(sed -n 's/.*\(key_gap_ms=[0-9]*\).*/\1/p' "$WORK/cam-start.txt")"
        grep -q "state=streaming" "$WORK/cam-start.txt" \
            && ok "CAM-WIRE cam.state streaming" \
            || bad "CAM-WIRE no streaming state"
        grep -q "cam.busy stream=8 state=busy" "$WORK/cam-start.txt" \
            && ok "CAM-WIRE a second cam.start is busy" \
            || bad "CAM-WIRE second start: $(grep 'cam.busy' "$WORK/cam-start.txt")"
        grep -q "state=stopped" "$WORK/cam-start.txt" \
            && ok "CAM-WIRE cam.stop answers stopped" \
            || bad "CAM-WIRE cam.stop: $(grep 'cam.state' "$WORK/cam-start.txt" | tail -1)"
        # Frames really stopped: the camera is free again, so a second capture
        # on the same stream starts and streams instead of answering busy.
        local again
        camctl cam start --stream 7 --seconds 2 > "$WORK/cam-again.txt" 2> "$WORK/cam-again.err"
        again="$(sed -n 's/.*cam\.stats .*frames=\([0-9]*\).*/\1/p' "$WORK/cam-again.txt" | tail -1)"
        if grep -q "^cam.state stream=7 state=streaming" "$WORK/cam-again.txt" \
            && [ -n "$again" ] && [ "$again" -ge 20 ]; then
            ok "CAM-WIRE the camera was free again after stop ($again frames)"
        else
            bad "CAM-WIRE the camera was not free after stop: $(tail -2 "$WORK/cam-again.txt" | tr '\n' ' ')"
        fi
        [ -s "$WORK/cam.h264" ] && ffprobe -v error -show_entries stream=codec_name,width,height \
            -of csv=p=0 "$WORK/cam.h264" > "$WORK/cam-probe.txt" 2>/dev/null \
            && grep -q "h264,1280,720" "$WORK/cam-probe.txt" \
            && ok "CAM-WIRE the Annex-B decodes as 1280x720 H.264" \
            || bad "CAM-WIRE the Annex-B does not probe as 1280x720 H.264"
    fi
    stop_fakephone
    sleep 1

    # The person's own camera app takes the camera: evicted, no retry, no frames.
    FAKE_ARGS="--cam-evict-after 1" start_fake || return 1
    camctl cam start --stream 9 --seconds 2 --await-terminal --wait 10 \
        > "$WORK/cam-evict.txt" 2> "$WORK/cam-evict.err"
    if grep -q "cam.state stream=9 state=evicted" "$WORK/cam-evict.txt"; then
        ok "CAM-WIRE eviction reports evicted"
        grep -q "cam.after_terminal frames=0" "$WORK/cam-evict.txt" \
            && ok "CAM-WIRE no frames after the eviction" \
            || bad "CAM-WIRE frames arrived after the eviction"
        grep -q "^cam.state stream=9 state=streaming" "$WORK/cam-evict.txt" \
            && ok "CAM-WIRE the capture streamed before the eviction" \
            || bad "CAM-WIRE the capture never streamed"
    else
        bad "CAM-WIRE eviction: $(grep 'cam.state' "$WORK/cam-evict.txt" | tail -1)"
    fi
    # A capture is never retried: after evicted, nothing starts on its own.
    grep -q "state=streaming" <(tail -2 "$WORK/cam-evict.txt") \
        && bad "CAM-WIRE the capture restarted after the eviction" \
        || ok "CAM-WIRE the capture was not retried"
    stop_fakephone
    sleep 1

    # The setting off: empty list, every start refused with off.
    FAKE_ARGS="--camera-off" start_fake || return 1
    camctl cam list > "$WORK/cam-off-list.txt" 2>&1
    grep -q "cam.cams count=0" "$WORK/cam-off-list.txt" \
        && ok "CAM-WIRE the setting off lists no camera" \
        || bad "CAM-WIRE the setting off still lists cameras"
    camctl cam start --stream 11 --wait 5 > "$WORK/cam-off.txt" 2>&1
    grep -q "state=off" "$WORK/cam-off.txt" \
        && ok "CAM-WIRE the setting off refuses cam.start with off" \
        || bad "CAM-WIRE off: $(grep 'cam.state' "$WORK/cam-off.txt" | tail -1)"
    stop_fakephone
}

# --- C2: the Phone Camera window (docs/design/camera.md) ------------------
#
# fakephone + the Mac app, quiet. The window is opened from --debug-control:
# it lists the fake's two cameras and starts 1280x720@30 on the stream id the
# window allocator chose; frames decode, the window follows the stream's
# aspect; switching camera stops the first capture and starts the other on a
# fresh stream; closing sends cam.stop. Then the phone with the setting off
# (state off), one whose camera app evicts mid-stream (evicted, nothing
# restarts until Try Again) and a session end (disconnected, no restart on
# reconnect). The no-Mac-camera rule is repeated against the built bundle.

camline() { grep 'camera window: state=' "$WORK/app.log" 2>/dev/null | tail -1; }
cam_state() { camline | sed -n 's/.*state=\([a-z]*\).*/\1/p'; }
cam_frames() { local f; f="$(camline | sed -n 's/.*frames=\([0-9]*\).*/\1/p')"; echo "${f:-0}"; }
cam_starts() { local n; n="$(grep -c '"t":"cam.start"' "$WORK/events.jsonl" 2>/dev/null)"; echo "${n:-0}"; }
cam_stops() { local n; n="$(grep -c '"t":"cam.stop"' "$WORK/events.jsonl" 2>/dev/null)"; echo "${n:-0}"; }
cam_start_line() { grep -o '"t":"cam.start"[^}]*}' "$WORK/events.jsonl" 2>/dev/null | sed -n "${1}p"; }
# cam_start_field INDEX FIELD — one field of the INDEXth cam.start the phone
# received. JSON key order is not stable, so the checks never match on it.
cam_start_field() {
    python3 - "$WORK/events.jsonl" "$1" "$2" <<'PY'
import json, sys
path, index, field = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = []
try:
    with open(path) as f:
        for line in f:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            message = event.get("msg") or {}
            if event.get("ev") == "rx" and message.get("t") == "cam.start":
                rows.append(message)
except OSError:
    pass
if 0 < index <= len(rows):
    value = rows[index - 1].get(field)
    if value is not None:
        print(value)
PY
}
cam_frames_at_least() { [ "$(cam_state)" = streaming ] && [ "$(cam_frames)" -ge "$1" ]; }
cam_state_is() { [ "$(cam_state)" = "$1" ]; }
cam_starts_at_least() { [ "$(cam_starts)" -ge "$1" ]; }
cam_starts_above() { [ "$(cam_starts)" -gt "$1" ]; }
cam_stops_above() { [ "$(cam_stops)" -gt "$1" ]; }
cam_size_720() { camline | grep -q 'size=1280x720'; }

# cam_open_window — the debug command, waiting for the session after a phone
# restart ("not online" until it reconnects).
cam_open_window() {
    local tries=60
    while ! control camera open; do
        if [ "$CONTROL_REPLY" != "not online" ] || [ "$tries" -le 0 ]; then
            bad "CAM-WINDOW camera open answered '$CONTROL_REPLY'"
            return 1
        fi
        tries=$((tries - 1))
        sleep 0.5
    done
    return 0
}

# cam_window_aspect — some window of the app has 16:9 content (the framed
# window's frame carries the 28 pt bar above the stream).
cam_window_aspect() {
    windows | awk '{ content = $5 - 28; if (content > 0) { r = $4 / content; if (r > 1.70 && r < 1.85) found = 1 } } END { exit found ? 0 : 1 }'
}

# cam_window_id — that window's id, for the visible run's screenshots.
cam_window_id() {
    windows | awk '{ content = $5 - 28; if (content > 0) { r = $4 / content; if (r > 1.70 && r < 1.85) { print $1; exit } } }'
}

check_cam_window() {
    clean
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    start_fake || return 1
    launch --debug-control "$WORK-control" --connect "127.0.0.1:$PORT" --quit-after 240

    # -- The no-Mac-camera rule, against what ships: the app binary and plist.
    if strings -a "$APP" | grep -qE 'AVCaptureDevice|CMIOExtension|CoreMediaIO'; then
        bad "CAM-WINDOW the app binary names a Mac camera API"
    elif /usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" \
        "$E2E_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
        bad "CAM-WINDOW the app bundle asks for camera permission"
    else
        ok "CAM-WINDOW no Mac camera API in the app target"
    fi

    # -- Open: cam.list, then a 1280x720 capture on a Mac-chosen stream.
    cam_open_window || return 1
    wait_until 20 cam_frames_at_least 1 \
        || { bad "CAM-WINDOW no frame (state=$(cam_state) line=$(camline))"; stop_fakephone; return 1; }
    wait_until 10 cam_starts_at_least 1 \
        || { bad "CAM-WINDOW the phone saw no cam.start"; stop_fakephone; return 1; }
    local stream1 w1 h1 id1
    stream1="$(cam_start_field 1 stream)"
    w1="$(cam_start_field 1 w)"
    h1="$(cam_start_field 1 h)"
    id1="$(cam_start_field 1 id)"
    if [ -n "$stream1" ] && [ "$stream1" -ge 1 ]; then
        ok "CAM-WINDOW cam.start on the Mac-chosen stream $stream1"
    else
        bad "CAM-WINDOW cam.start stream: $(cam_start_line 1)"
    fi
    if [ "$w1" = "1280" ] && [ "$h1" = "720" ] && [ "$id1" = "0" ]; then
        ok "CAM-WINDOW the default back camera at 1280x720"
    else
        bad "CAM-WINDOW cam.start fields: $(cam_start_line 1)"
    fi

    # 3 s more of frames, then the stream's size and the window's aspect.
    sleep 3
    local frames
    frames="$(cam_frames)"
    [ "$frames" -ge 30 ] \
        && ok "CAM-WINDOW $frames frames in 3 s" \
        || bad "CAM-WINDOW only $frames frames in 3 s"
    wait_until 5 cam_size_720 \
        && ok "CAM-WINDOW the stream is 1280x720" \
        || bad "CAM-WINDOW size: $(camline)"
    wait_until 5 cam_window_aspect \
        && ok "CAM-WINDOW the window follows the stream's 16:9 aspect" \
        || bad "CAM-WINDOW window shape: $(windows | tr '\n' ' ')"
    titles_have "Phone Camera" \
        && ok "CAM-WINDOW the window is titled Phone Camera" \
        || bad "CAM-WINDOW title: $(window_titles "$APP_PID" | tr '\n' '|')"
    # Visible runs (the VM) keep one screenshot of the streaming window; a
    # quiet host run never takes one.
    if [ "$VISIBLE" = "1" ]; then
        local shot
        shot="$(cam_window_id)"
        if [ -n "$shot" ] && shot_window "$shot" "$WORK/camera-streaming.png"; then
            ok "CAM-WINDOW screenshot: $WORK/camera-streaming.png"
        else
            bad "CAM-WINDOW no screenshot of the streaming window"
        fi
    fi

    # -- Switch camera (fakephone lists two): stop, then start the other id on
    #    a fresh stream.
    local stops_before
    stops_before="$(cam_stops)"
    control camera switch || bad "CAM-WINDOW switch answered '$CONTROL_REPLY'"
    wait_until 10 cam_starts_at_least 2 \
        || { bad "CAM-WINDOW the switch sent no second cam.start"; stop_fakephone; return 1; }
    local stream2 id2
    stream2="$(cam_start_field 2 stream)"
    id2="$(cam_start_field 2 id)"
    [ -n "$stream2" ] && [ "$stream2" != "$stream1" ] \
        && ok "CAM-WINDOW the switch moved to a fresh stream ($stream1 -> $stream2)" \
        || bad "CAM-WINDOW switch stream: $(cam_start_line 2)"
    [ "$id2" = "1" ] \
        && ok "CAM-WINDOW switched to the front camera (id 1)" \
        || bad "CAM-WINDOW switch camera: $(cam_start_line 2)"
    [ "$(cam_stops)" -gt "$stops_before" ] \
        && ok "CAM-WINDOW cam.stop before the switch" \
        || bad "CAM-WINDOW no cam.stop before the switch"
    wait_until 15 cam_frames_at_least 1 \
        && ok "CAM-WINDOW the other camera streams" \
        || bad "CAM-WINDOW the other camera sent no frame (line=$(camline))"

    # -- Close: cam.stop and no camera lines afterwards.
    stops_before="$(cam_stops)"
    control camera close || bad "CAM-WINDOW close answered '$CONTROL_REPLY'"
    wait_until 10 cam_stops_above "$stops_before" \
        && ok "CAM-WINDOW closing sent cam.stop" \
        || bad "CAM-WINDOW closing sent no cam.stop"
    local last
    last="$(camline)"
    sleep 1.5
    [ "$(camline)" = "$last" ] \
        && ok "CAM-WINDOW frames stopped after close" \
        || bad "CAM-WINDOW camera lines continued after close: $(camline)"

    # -- The setting off on the phone: the window says so.
    stop_fakephone
    sleep 1
    FAKE_ARGS="--camera-off" start_fake || return 1
    cam_open_window || return 1
    wait_until 20 cam_state_is off \
        && ok "CAM-WINDOW the setting off shows the off message" \
        || bad "CAM-WINDOW off state: $(camline)"
    control camera close || true

    # -- The person's camera app takes the camera: evicted, no retry until the
    #    button is pressed.
    stop_fakephone
    sleep 1
    FAKE_ARGS="--cam-evict-after 2" start_fake || return 1
    cam_open_window || return 1
    wait_until 20 cam_state_is evicted \
        && ok "CAM-WINDOW the eviction shows the evicted message" \
        || bad "CAM-WINDOW eviction state: $(camline)"
    if [ "$VISIBLE" = "1" ]; then
        local shot
        shot="$(cam_window_id)"
        if [ -n "$shot" ] && shot_window "$shot" "$WORK/camera-evicted.png"; then
            ok "CAM-WINDOW screenshot: $WORK/camera-evicted.png"
        else
            bad "CAM-WINDOW no screenshot of the evicted message"
        fi
    fi
    local starts_before
    starts_before="$(cam_starts)"
    sleep 3
    [ "$(cam_starts)" = "$starts_before" ] \
        && ok "CAM-WINDOW nothing restarted the capture after evicted" \
        || bad "CAM-WINDOW the capture restarted on its own after evicted"
    control camera retry || bad "CAM-WINDOW retry answered '$CONTROL_REPLY'"
    wait_until 10 cam_starts_above "$starts_before" \
        && ok "CAM-WINDOW Try Again started a new capture" \
        || bad "CAM-WINDOW Try Again sent no cam.start"
    local stream3
    stream3="$(cam_start_field "$(cam_starts)" stream)"
    [ -n "$stream3" ] && [ "$stream3" != "$stream2" ] \
        && ok "CAM-WINDOW the retry used a fresh stream ($stream3)" \
        || bad "CAM-WINDOW retry stream: $(cam_start_line "$(cam_starts)")"

    # -- Session end: disconnected, and a reconnect never restarts it.
    stop_fakephone
    wait_until 20 cam_state_is disconnected \
        && ok "CAM-WINDOW the session end shows Phone disconnected" \
        || bad "CAM-WINDOW session end state: $(camline)"
    start_fake || return 1
    wait_until 30 grep -q '"ev":"session","state":"auth_ok"' "$WORK/events.jsonl" \
        || wait_until 5 grep -q '"ev":"session","state":"paired"' "$WORK/events.jsonl"
    sleep 2
    grep -q '"t":"cam.list"' "$WORK/events.jsonl" \
        && bad "CAM-WINDOW the reconnect restarted the camera on its own" \
        || ok "CAM-WINDOW the reconnect sent no cam.list"
    [ "$(cam_state)" = disconnected ] \
        && ok "CAM-WINDOW still disconnected after the reconnect" \
        || bad "CAM-WINDOW reconnect state: $(camline)"

    stop_fakephone
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
# still works; turning the setting off stops a running automatic shim (its window
# stays) but leaves a hand-added one running.
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

    # Turning the setting off while an automatic identity runs: the shim stops,
    # the window stays (the identity was only the Dock tile), and nothing
    # re-identifies the window while the setting is off.
    printf 'wait 25\ndockapps off\n' > "$WORK/dock-off-script.txt"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" \
        --debug-input-script "$WORK/dock-off-script.txt" --quit-after 80
    wait_until 30 window_rx window.open "$pkg" \
        && ok "DOCK toggle: window.open arrived for $pkg" \
        || { bad "DOCK toggle: no window.open for $pkg"; stop_app; stop_fakephone; return 1; }
    wait_until 30 eval '[ -n "$(dock_shim_pids)" ]' \
        && ok "DOCK toggle: the automatic shim runs while the setting is on" \
        || bad "DOCK toggle: the shim never ran"
    local kept
    kept="$(windows | wc -l | tr -d ' ')"
    wait_until 30 eval '[ "$(defaults read "$DEFAULTS_SUITE" showAppsInDock 2>/dev/null)" = "0" ]' \
        && ok "DOCK toggle: the setting is off" || bad "DOCK toggle: the setting never turned off"
    wait_until 20 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "DOCK toggle: the running automatic shim quit" || bad "DOCK toggle: the shim kept running"
    wait_until 10 eval '[ "$(windows | wc -l | tr -d " ")" -ge "$kept" ]' \
        && ok "DOCK toggle: the window stayed open" || bad "DOCK toggle: the window closed with the shim"
    sleep 5
    [ -z "$(dock_shim_pids)" ] \
        && ok "DOCK toggle: no identity comes back while the setting is off" \
        || bad "DOCK toggle: an identity started while the setting was off"
    stop_app
    # The next phase waits for a bundle to appear; a leftover one would satisfy
    # that wait at once and its shim would be the one opened and (replaced by
    # the app's own --dock-add) stopped.
    remove_dock_apps

    # Pinned (Add to Dock) identities follow the existing rule: turning the
    # setting off leaves them running with their window.
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" \
        --debug-input-script "$WORK/dock-off-script.txt" --quit-after 80
    wait_until 30 shim_made \
        || { bad "DOCK pinned: no Dock app in $dir"; stop_app; stop_fakephone; return 1; }
    shim="$(ls -d "$dir"/*.app | head -1)"
    open_quiet "$shim"
    wait_until 20 window_rx window.open "$pkg" \
        && ok "DOCK pinned: the shim opened its window" || bad "DOCK pinned: no window.open for $pkg"
    wait_until 20 eval '[ -n "$(dock_shim_pids)" ]' \
        && ok "DOCK pinned: the shim runs" || bad "DOCK pinned: the shim is not running"
    wait_until 30 eval '[ "$(defaults read "$DEFAULTS_SUITE" showAppsInDock 2>/dev/null)" = "0" ]' \
        && ok "DOCK pinned: the setting turned off" || bad "DOCK pinned: the setting never turned off"
    sleep 5
    [ -n "$(dock_shim_pids)" ] \
        && ok "DOCK pinned: the hand-added shim keeps running" \
        || bad "DOCK pinned: the setting stopped a hand-added shim"
    wait_until 5 windows_at_least 1 \
        && ok "DOCK pinned: its window is still open" || bad "DOCK pinned: the window is gone"
    stop_app
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
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
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
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
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
            if grep -qE 'pd-notify-(title|text)-[0-9]' "$file" 2>/dev/null; then
                say "  notification text in $file"
                return 1
            fi
        done
        return 0
    }

    start_fake || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "NOTIFY no device id in the fakephone listening line"; stop_fakephone; return 1; }
    # The per-phone opt-in is a stored default of the e2e profile, off by default
    # (check_dock seeds showAppsInDock the same way).
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    # Dock auto-identity is on by default: phase (a) opens an app window and
    # would leave a shim that phase (f) then relaunches as a Dock open, which
    # this check would read as the click's window. Dock has its own check.
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO

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
    media_played() {
        python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "media" and event.get("kind") == "rx" and event.get("action") == "play":
        sys.exit(0)
sys.exit(1)
PY
    }
    wait_until 20 media_played \
        && ok "NOTIFY the Now Playing control reached the phone (media.command play)" \
        || bad "NOTIFY no media.command play at the phone"
    log_has "media command play" \
        && ok "NOTIFY the command went through the Now Playing handler" \
        || bad "NOTIFY the command was not recorded"

    # (e) privacy: no notification text in any log.
    no_notify_text "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/events.jsonl" \
        && ok "NOTIFY no notification text in the app log, share log, fake log or event log" \
        || bad "NOTIFY notification text leaked"

    # (f) "When I click a phone notification" (ROADMAP D2): Open on Mac (the
    # default, used above) opens the window and runs the action there; Open on
    # phone asks for display 0 and opens no window; Do nothing sends nothing.
    notify_open_rx() {
        python3 - "$WORK/events.jsonl" "$1" "${2:-}" <<'PY'
import json, sys
target, stream = sys.argv[2], sys.argv[3]
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "notify" and event.get("kind") == "open" and event.get("target") == target:
        if not stream or str(event.get("stream")) == stream:
            sys.exit(0)
sys.exit(1)
PY
    }
    wait_until 20 notify_open_rx window 2 \
        && ok "NOTIFY Open on Mac: notify.open target=window stream=2" \
        || bad "NOTIFY Open on Mac: no notify.open for the clicked window"

    # Open on phone: the same click, with the setting stored for this phone.
    stop_app
    defaults write "$DEFAULTS_SUITE" "notify.click.$device" -string phone
    : > "$WORK/events.jsonl"
    cat > "$script" <<'EOF'
wait 3
notifyclick pd-n1
EOF
    launch --connect "127.0.0.1:$PORT" --quit-after 45 --share-log "$WORK/notify-phone.log" \
        --open com.whatsapp --debug-input-script "$script"
    wait_until 30 notify_open_rx phone "" \
        && ok "NOTIFY Open on phone: notify.open target=phone" \
        || bad "NOTIFY Open on phone: no notify.open target=phone"
    sleep 2
    ! window_rx window.open "com.android.settings" \
        && ok "NOTIFY Open on phone: no Mac window for the clicked app" \
        || bad "NOTIFY Open on phone: the clicked app's window opened anyway"

    # Do nothing: the click is recorded, but no message and no window.
    stop_app
    defaults write "$DEFAULTS_SUITE" "notify.click.$device" -string none
    : > "$WORK/events.jsonl"
    cat > "$script" <<'EOF'
wait 3
notifyclick pd-n1
EOF
    launch --connect "127.0.0.1:$PORT" --quit-after 45 --share-log "$WORK/notify-none.log" \
        --open com.whatsapp --debug-input-script "$script"
    wait_until 20 grep -qF -- "notify click id=pd-n1" "$WORK/notify-none.log" 2>/dev/null \
        && ok "NOTIFY Do nothing: the click reached the routing" \
        || bad "NOTIFY Do nothing: the click never reached the routing"
    sleep 2
    ! notify_open_rx window "" && ! notify_open_rx phone "" \
        && ok "NOTIFY Do nothing: no notify.open was sent" \
        || bad "NOTIFY Do nothing: notify.open was sent anyway"
    ! window_rx window.open "com.android.settings" \
        && ok "NOTIFY Do nothing: no Mac window opened" \
        || bad "NOTIFY Do nothing: a window opened anyway"
    defaults delete "$DEFAULTS_SUITE" "notify.click.$device" >/dev/null 2>&1

    # (b) opt-in off (the default): nothing is forwarded, nothing is asked.
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
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

# check_notify_actions — deeper notifications, part 1 (docs/design/notify.md):
# the phone's buttons and reply field on the banner, a clear in both directions,
# per-app mute and Copy code. Quiet share-log run: ids, indexes, lengths and the
# category hash only; the fake code is compared by hash and never printed.
check_notify_actions() {
    clean
    local log="$WORK/notify-actions.log" script="$WORK/notify-actions-input.txt" device
    local code_hash code_types
    log_has() { grep -qF -- "$1" "$log" 2>/dev/null; }
    # notify_rx KIND ID [I] [TEXTLEN] — a fakephone notification event.
    notify_rx() {
        python3 - "$WORK/events.jsonl" "$@" <<'PY'
import json, sys
path = sys.argv[1]
kind = sys.argv[2]
want_id = sys.argv[3] if len(sys.argv) > 3 else None
want_i = sys.argv[4] if len(sys.argv) > 4 else None
want_len = sys.argv[5] if len(sys.argv) > 5 else None
for line in open(path):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") != "notify" or event.get("kind") != kind:
        continue
    if want_id is not None and event.get("id") != want_id:
        continue
    if want_i is not None and str(event.get("i")) != want_i:
        continue
    if want_len is not None and str(event.get("textLen")) != want_len:
        continue
    sys.exit(0)
sys.exit(1)
PY
    }

    start_fake || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "NOTIFY-ACTIONS no device id in the fakephone listening line"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    # No Dock auto-identity: it would open windows behind this check's back
    # (docs/design/dock.md has its own check).
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO
    # The mute test: one package muted before the launch; its post must be dropped.
    defaults write "$DEFAULTS_SUITE" "notify.mute.$device" -array com.slack

    # A reply action, a plain button, a dismiss, an ongoing dismiss (refused on
    # the Mac) and Copy code, all through the handlers a banner response runs.
    cat > "$script" <<'EOF'
wait 3
notifyaction pd-a1 1 pd-reply-1
notifyaction pd-a1 0
notifycopy pd-a4
notifydismiss pd-a3
notifydismiss pd-a2
EOF
    launch --connect "127.0.0.1:$PORT" --quit-after 60 --share-log "$log" \
        --open com.whatsapp --debug-input-script "$script"

    # (a) the wire carried the shapes: counts and the category hash, no text.
    wait_until 20 log_has "notify post id=pd-a1 pkg=com.whatsapp" \
        && ok "NOTIFY-ACTIONS pd-a1 (reply shape) recorded" \
        || bad "NOTIFY-ACTIONS pd-a1 not recorded: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    log_has "actions=2 reply=1" \
        && ok "NOTIFY-ACTIONS the reply shape advertised 2 actions, one reply" \
        || bad "NOTIFY-ACTIONS the reply shape's action counts are wrong"
    log_has "code=0 ongoing=0 category=pd.n." \
        && ok "NOTIFY-ACTIONS the category is a shape hash" \
        || bad "NOTIFY-ACTIONS no category hash for pd-a1"
    wait_until 20 log_has "notify post id=pd-a4 pkg=com.whatsapp" \
        && ok "NOTIFY-ACTIONS pd-a4 (code shape) recorded" \
        || bad "NOTIFY-ACTIONS pd-a4 not recorded"
    grep -q "notify post id=pd-a4 .*code=1" "$log" 2>/dev/null \
        && ok "NOTIFY-ACTIONS the code was found in the notification" \
        || bad "NOTIFY-ACTIONS the code was not found"

    # (b) muted: com.slack's post is dropped before it is shown.
    wait_until 20 log_has "notify muted pkg=com.slack" \
        && ok "NOTIFY-ACTIONS the muted package was dropped" \
        || bad "NOTIFY-ACTIONS no muted line"
    ! log_has "notify post id=pd-a5" \
        && ok "NOTIFY-ACTIONS the muted package got no banner" \
        || bad "NOTIFY-ACTIONS the muted package was posted anyway"

    # (c) reply and button: the phone logs the right index and text length.
    wait_until 20 log_has "notify action id=pd-a1 i=1 textLen=10" \
        && ok "NOTIFY-ACTIONS the reply action was sent" \
        || bad "NOTIFY-ACTIONS no reply action in the share log"
    wait_until 20 notify_rx action pd-a1 1 10 \
        && ok "NOTIFY-ACTIONS the phone got the reply (i=1, length 10)" \
        || bad "NOTIFY-ACTIONS the phone logged no reply action"
    wait_until 20 notify_rx action pd-a1 0 0 \
        && ok "NOTIFY-ACTIONS the phone got the button (i=0, no text)" \
        || bad "NOTIFY-ACTIONS the phone logged no button action"

    # (d) dismiss: the clearable one goes out, the ongoing one does not.
    wait_until 20 notify_rx dismiss pd-a2 \
        && ok "NOTIFY-ACTIONS the phone got notify.dismiss for the banner" \
        || bad "NOTIFY-ACTIONS the phone logged no dismiss"
    log_has "notify dismiss id=pd-a3 refused=ongoing" \
        && ok "NOTIFY-ACTIONS the ongoing notification was refused" \
        || bad "NOTIFY-ACTIONS the ongoing refusal is not in the share log"
    ! notify_rx dismiss pd-a3 \
        && ok "NOTIFY-ACTIONS no dismiss was sent for the ongoing notification" \
        || bad "NOTIFY-ACTIONS the ongoing notification was dismissed anyway"

    # (e) the phone taking a notification away clears the banner (notify.remove).
    wait_until 20 log_has "notify remove id=pd-n2" \
        && ok "NOTIFY-ACTIONS the phone's notify.remove reached the Mac" \
        || bad "NOTIFY-ACTIONS notify.remove was not recorded"

    # (f) Copy code: value and length by hash, the concealed/transient types,
    # then the clipboard is cleared again. Nothing here prints the code.
    wait_until 20 log_has "notify copy id=pd-a4 len=6" \
        && ok "NOTIFY-ACTIONS Copy code copied a 6-char code" \
        || bad "NOTIFY-ACTIONS no copy line"
    if [ -n "$(pbpaste 2>/dev/null)" ]; then
        code_hash="$(pbpaste | shasum -a 256 | cut -d' ' -f1)"
        code_types="$(xcrun swift -e 'import AppKit; print((NSPasteboard.general.types ?? []).map { $0.rawValue }.joined(separator: ","))' 2>/dev/null)"
        [ "$(printf '%s' 482913 | shasum -a 256 | cut -d' ' -f1)" = "$code_hash" ] \
            && ok "NOTIFY-ACTIONS the pasteboard holds the code (hash match)" \
            || bad "NOTIFY-ACTIONS the pasteboard does not hold the code"
        case "$code_types" in
            *org.nspasteboard.ConcealedType*) ok "NOTIFY-ACTIONS the pasteboard item is concealed" ;;
            *) bad "NOTIFY-ACTIONS the pasteboard item is not concealed ($code_types)" ;;
        esac
        case "$code_types" in
            *org.nspasteboard.TransientType*) ok "NOTIFY-ACTIONS the pasteboard item is transient" ;;
            *) bad "NOTIFY-ACTIONS the pasteboard item is not transient" ;;
        esac
        pbcopy < /dev/null
    else
        bad "NOTIFY-ACTIONS the pasteboard is empty after Copy code"
    fi

    # (g) privacy: no notification or reply text in any log.
    ! grep -qE 'pd-notify-(title|text)-[0-9]|pd-reply-1|482913' \
        "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null \
        && ok "NOTIFY-ACTIONS no notification or reply text reached a log" \
        || bad "NOTIFY-ACTIONS notification text leaked"

    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "notify.mute.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# check_notify_media — notification pictures and Android 16 Live Updates
# (docs/design/notify.md, "Part 2b design"). Quiet share-log run: the post line
# carries the picture's mime/size/dimensions and its temp path, the live lines
# carry ids, progress buckets and timestamps, and `livedump` reads the menu bar's
# Live section. Nothing reaches Notification Center; no picture bytes are logged.
check_notify_media() {
    clean
    local log="$WORK/notify-media.log" script="$WORK/notify-media-input.txt" device path dir mode
    log_has() { grep -qF -- "$1" "$log" 2>/dev/null; }
    # live_rx ID — one line per applied update, oldest first.
    live_lines() { grep -E "notify live id=$1 progress=" "$log" 2>/dev/null || true; }

    FAKE_ARGS="--notify-media" start_fake '' || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "NOTIFY-MEDIA no device id in the fakephone listening line"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO
    # A live row click runs the click route; "none" keeps it from opening a window.
    defaults write "$DEFAULTS_SUITE" "notify.click.$device" -string none

    cat > "$script" <<EOF
wait 3
notifyclick pd-l1
livedump $WORK/notify-media-live-1.json
wait 3
livedump $WORK/notify-media-live-2.json
wait 6
livedump $WORK/notify-media-live-3.json
wait 3
livedump $WORK/notify-media-live-4.json
EOF
    # The picture and Live Update shapes arrive on notify.enable; the fake also
    # ends pd-m1 after 8 s and pd-l1 after its twenty seconds of updates.
    launch --connect "127.0.0.1:$PORT" --quit-after 70 \
        --open com.whatsapp --share-log "$log" --debug-input-script "$script"

    # (a) the picture joins its post: mime, dimensions, size and a temp file.
    wait_until 20 log_has "notify post id=pd-m1 pkg=com.whatsapp" \
        || { bad "NOTIFY-MEDIA pd-m1 not recorded: $(tr '\n' '|' < "$log" 2>/dev/null)"; stop_app; stop_fakephone; return 1; }
    log_has "image=image/jpeg w=160 h=120 size=1615 attachment=" \
        && ok "NOTIFY-MEDIA the picture joined the post (jpeg 160x120, 1615 B)" \
        || bad "NOTIFY-MEDIA the post carries no image facts"
    path="$(sed -n 's/.*attachment=\([^ ]*\).*/\1/p' "$log" | head -1)"
    if [ -n "$path" ] && [ -f "$path" ]; then
        ok "NOTIFY-MEDIA the attachment temp file exists"
        mode="$(stat -f %Lp "$path" 2>/dev/null)"
        [ "$mode" = "600" ] \
            && ok "NOTIFY-MEDIA the temp file is 0600" \
            || bad "NOTIFY-MEDIA the temp file is $mode, not 600"
        dir="$(dirname "$path")"
        mode="$(stat -f %Lp "$dir" 2>/dev/null)"
        [ "$mode" = "700" ] \
            && ok "NOTIFY-MEDIA its directory is 0700" \
            || bad "NOTIFY-MEDIA its directory is $mode, not 700"
        case "$path" in
            */Caches/PocketDeck-"$PROFILE"/notify/*) ok "NOTIFY-MEDIA the temp file is in the profile's caches" ;;
            *) bad "NOTIFY-MEDIA the temp file is outside the profile's caches ($path)" ;;
        esac
    else
        bad "NOTIFY-MEDIA no attachment temp file"
    fi

    # (b) an oversized picture is refused and the banner still posts without it.
    wait_until 20 log_has "notify post id=pd-m2 pkg=com.whatsapp" \
        && ok "NOTIFY-MEDIA the oversized picture's banner still posted" \
        || bad "NOTIFY-MEDIA pd-m2 not recorded"
    log_has "notify image id=pd-m2 refused=bytes" \
        && ok "NOTIFY-MEDIA the oversized picture was refused" \
        || bad "NOTIFY-MEDIA the oversized picture was not refused"
    ! grep -q "notify post id=pd-m2 .*image=" "$log" 2>/dev/null \
        && ok "NOTIFY-MEDIA the refused picture was not attached" \
        || bad "NOTIFY-MEDIA the refused picture was attached anyway"

    # (c) the phone taking pd-m1 away removes the attachment temp file.
    wait_until 25 log_has "notify remove id=pd-m1" \
        && ok "NOTIFY-MEDIA the phone removed the picture notification" \
        || bad "NOTIFY-MEDIA no notify.remove for pd-m1"
    if [ -n "$path" ] && [ ! -e "$path" ]; then
        ok "NOTIFY-MEDIA the temp file went away with the banner"
    else
        bad "NOTIFY-MEDIA the temp file outlived its banner"
    fi

    # (d) Live Updates: one banner, in-place updates at most once per second.
    grep -q "notify post id=pd-l1 pkg=com.uber .* live=1" "$log" 2>/dev/null \
        && ok "NOTIFY-MEDIA the first live post is marked live" \
        || bad "NOTIFY-MEDIA pd-l1 was not recorded as live"
    [ "$(grep -c "notify post id=pd-l1 " "$log" 2>/dev/null)" = "1" ] \
        && ok "NOTIFY-MEDIA live updates never posted a second banner" \
        || bad "NOTIFY-MEDIA a live update posted another banner"
    local updates
    updates="$(live_lines pd-l1)"
    [ "$(printf '%s\n' "$updates" | grep -c .)" -ge 2 ] \
        && ok "NOTIFY-MEDIA live updates arrived in place ($(printf '%s\n' "$updates" | grep -c .) lines)" \
        || bad "NOTIFY-MEDIA no in-place live updates in the share log"
    printf '%s\n' "$updates" | python3 -c '
import sys, re
times = []
for line in sys.stdin:
    m = re.search(r" at=(\d+)$", line.strip())
    if m:
        times.append(int(m.group(1)))
if len(times) < 2:
    print("fewer than two timed updates"); sys.exit(1)
gaps = [b - a for a, b in zip(times, times[1:])]
if min(gaps) < 950:
    print("updates %.0f ms apart" % min(gaps)); sys.exit(1)
print("gaps at least %d ms" % min(gaps))
' > "$WORK/notify-media-gaps.txt" 2>&1 \
        && ok "NOTIFY-MEDIA live updates are coalesced to one per second ($(cat "$WORK/notify-media-gaps.txt"))" \
        || bad "NOTIFY-MEDIA live updates are faster than one per second ($(cat "$WORK/notify-media-gaps.txt"))"
    wait_until 10 log_has "notify live id=pd-l1 end" \
        && ok "NOTIFY-MEDIA the ended live item was removed from the section" \
        || bad "NOTIFY-MEDIA no live-end line"
    wait_until 10 log_has "notify remove id=pd-l1" \
        && ok "NOTIFY-MEDIA the phone's notify.remove ended the live item" \
        || bad "NOTIFY-MEDIA no notify.remove for pd-l1"

    # (e) the menu bar's Live section: the rows, an advancing item, the end.
    for f in 1 2 3 4; do
        wait_until 30 [ -s "$WORK/notify-media-live-$f.json" ] \
            || { bad "NOTIFY-MEDIA no livedump $f"; break; }
    done
    python3 - "$WORK" <<'PY' && ok "NOTIFY-MEDIA the Live section lists both items and drops the ended one" \
        || bad "NOTIFY-MEDIA the Live section does not match"
import json, sys, os
work = sys.argv[1]
def load(n):
    path = os.path.join(work, "notify-media-live-%d.json" % n)
    return {row["id"]: row for row in json.load(open(path))["live"]}
first, second, third, fourth = load(1), load(2), load(3), load(4)
if set(first) != {"pd-l1", "pd-l2"}:
    print("first rows:", sorted(first)); sys.exit(1)
if first["pd-l1"]["pkg"] != "com.uber" or first["pd-l1"]["chipLen"] != 5:
    print("pd-l1 row:", first["pd-l1"]); sys.exit(1)
if not first["pd-l2"]["chrono"] or not first["pd-l2"]["countDown"]:
    print("pd-l2 is not a countdown chronometer:", first["pd-l2"]); sys.exit(1)
if ":" not in first["pd-l2"]["title"]:
    print("pd-l2 has no clock:", first["pd-l2"]["title"]); sys.exit(1)
if not (0 <= first["pd-l1"]["progress"] < second["pd-l1"]["progress"] <= 1):
    print("pd-l1 did not advance:", first["pd-l1"]["progress"], second["pd-l1"]["progress"]); sys.exit(1)
if "▮" not in first["pd-l1"]["title"] or "▯" not in first["pd-l1"]["title"]:
    print("no text progress bar:", first["pd-l1"]["title"]); sys.exit(1)
if "pd-l1" in third or "pd-l1" in fourth:
    print("the ended item is still listed:", sorted(third), sorted(fourth)); sys.exit(1)
PY

    # (f) a live row's click runs the click route; "none" opened nothing.
    log_has "notify click id=pd-l1" \
        && ok "NOTIFY-MEDIA clicking a live row ran the click route" \
        || bad "NOTIFY-MEDIA the live row click was not recorded"
    ! grep -q '"kind":"open"' "$WORK/events.jsonl" 2>/dev/null \
        && ok "NOTIFY-MEDIA the 'do nothing' choice sent no notify.open" \
        || bad "NOTIFY-MEDIA a notify.open was sent anyway"

    # (g) nothing about the notification or the picture reached a log.
    ! grep -qE 'pd-notify-(title|text)-[0-9]|/9j/4AAQ|[A-Za-z0-9+/]{200,}' \
        "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null \
        && ok "NOTIFY-MEDIA no notification text or picture bytes reached a log" \
        || bad "NOTIFY-MEDIA notification text or picture bytes leaked"

    stop_fakephone
    wait_until 10 no_fakephone
    # A disconnect deletes the attachment directory (nothing outlives the phone).
    sleep 2
    [ -z "$(ls -A "$HOME/Library/Caches/PocketDeck-$PROFILE/notify" 2>/dev/null)" ] \
        && ok "NOTIFY-MEDIA the disconnect left no attachment behind" \
        || bad "NOTIFY-MEDIA an attachment survived the disconnect"
    stop_app

    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "notify.click.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
}

# check_media — "Media part 2" (docs/design/notify.md, v0.2 #9): the artwork,
# the position bar and seek, the choice among several playing apps and the
# phone's media volume, then an older phone that knows none of it. Quiet
# share-log run: the log carries bytes, dimensions and hash prefixes, never the
# picture or any track text.
check_media() {
    clean
    local log="$WORK/media.log" script="$WORK/media-input.txt" device
    local oldlog="$WORK/media-older.log" oldscript="$WORK/media-older-input.txt"
    log_has() { grep -qF -- "$1" "$log" 2>/dev/null; }
    old_log_has() { grep -qF -- "$1" "$oldlog" 2>/dev/null; }
    # media_events KIND [EXTRA] — the fake's media events of that kind.
    seen_choose() { media_events choose | grep -q '"key": "s2"'; }
    seen_second_seek() {
        [ "$(media_count rx action=seek)" -ge 2 ] && media_events rx action=seek | grep -q '"positionMs": 5000'
    }
    media_events() {
        python3 - "$WORK/events.jsonl" "$1" "${2:-}" <<'PY'
import json, sys
kind, extra = sys.argv[2], sys.argv[3]
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") != "media" or event.get("kind") != kind:
        continue
    if extra and not all(str(event.get(k)) == v for k, v in (x.split("=", 1) for x in extra.split(","))):
        continue
    print(json.dumps(event, sort_keys=True))
PY
    }
    media_count() { media_events "$1" "${2:-}" | grep -c . ; }

    # (a) two playing apps: the list, the state, the artwork.
    FAKE_ARGS="--media" start_fake '' || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "MEDIA no device id in the fakephone listening line"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO
    # The debug script arms on the window's first video size change, so a window
    # is opened (quiet: on the run's virtual display).
    cat > "$script" <<'EOF'
wait 4
mediacmd seek 45000
wait 2
mediacmd volume 99
wait 2
mediacmd choose s2
wait 3
mediacmd seek 5000
wait 2
EOF
    launch --connect "127.0.0.1:$PORT" --quit-after 45 --share-log "$log" \
        --open com.whatsapp --debug-input-script "$script"

    wait_until 20 log_has "media sessions n=2 chosen=s1" \
        && ok "MEDIA the phone listed both playing apps, the first chosen" \
        || bad "MEDIA no media.sessions line: $(tr '\n' '|' < "$log" 2>/dev/null)"
    wait_until 20 log_has "media set playing=true" \
        && ok "MEDIA media.state drove Now Playing" \
        || bad "MEDIA no media.state record"
    grep -qE "media set .*canSeek=1 volume=8 volumeMax=15" "$log" 2>/dev/null \
        && ok "MEDIA the state carries canSeek and the session volume (8/15)" \
        || bad "MEDIA no canSeek/volume in the state record: $(grep 'media set' "$log" 2>/dev/null | head -1)"
    wait_until 20 grep -q "media art w=160 h=120 bytes=" "$log" 2>/dev/null \
        && ok "MEDIA the artwork arrived (jpeg 160x120)" \
        || bad "MEDIA no media art record"
    # Artwork once per change: one send for the first session so far.
    [ "$(grep -c "media art w=" "$log" 2>/dev/null)" = "1" ] \
        && [ "$(media_count art)" = "1" ] \
        && ok "MEDIA the artwork was sent once, not once per state" \
        || bad "MEDIA artwork sent $(grep -c 'media art w=' "$log" 2>/dev/null) times ($(media_count art) from the phone)"

    # (b) the position bar: 45 s asked, the track is 30 s, so 30 s goes out.
    wait_until 20 grep -q "media command seek positionMs=30000" "$log" 2>/dev/null \
        && ok "MEDIA a seek past the end was clamped to the track (30000 ms)" \
        || bad "MEDIA no clamped seek record: $(grep 'media command' "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 20 [ "$(media_count rx action=seek)" -ge 1 ] \
        && ok "MEDIA the phone received the seek" \
        || bad "MEDIA the phone received no seek"
    media_events rx action=seek | grep -q '"positionMs": 30000' \
        && ok "MEDIA the seek reached the phone with the clamped value" \
        || bad "MEDIA the seek value at the phone: $(media_events rx action=seek | tr '\n' '|')"
    # The next state confirms where the session now is (the fake answers).
    wait_until 20 grep -qE "media set .*elapsedMs=30000" "$log" 2>/dev/null \
        && ok "MEDIA the next media.state confirmed the new position" \
        || bad "MEDIA no state after the seek: $(grep 'media set' "$log" 2>/dev/null | tail -1)"

    # (c) volume: 99 asked, the session tops at 15.
    wait_until 20 grep -q "media command volume level=15" "$log" 2>/dev/null \
        && ok "MEDIA the volume was clamped to the session maximum (15)" \
        || bad "MEDIA no clamped volume record: $(grep 'media command' "$log" 2>/dev/null | tr '\n' '|')"
    media_events rx action=volume | grep -q '"level": 15' \
        && ok "MEDIA the volume reached the phone as 15" \
        || bad "MEDIA the volume at the phone: $(media_events rx action=volume | tr '\n' '|')"
    wait_until 20 grep -qE "media set .*volume=15 volumeMax=15" "$log" 2>/dev/null \
        && ok "MEDIA the next media.state reflects the new volume" \
        || bad "MEDIA the volume did not come back in a state"

    # (d) choosing: the second app takes over, its state and art follow.
    wait_until 20 seen_choose \
        && ok "MEDIA media.choose reached the phone" \
        || bad "MEDIA the phone saw no media.choose ($(media_events choose | tr '\n' '|'))"
    wait_until 20 log_has "media sessions n=2 chosen=s2" \
        && ok "MEDIA the next sessions list shows the picked app" \
        || bad "MEDIA the chosen key never moved: $(grep 'media sessions' "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 20 grep -qE "media set .*key=s2" "$log" 2>/dev/null \
        && ok "MEDIA the next media.state carries the picked session's key" \
        || bad "MEDIA no state for the picked session"
    wait_until 20 [ "$(grep -c 'media art w=' "$log" 2>/dev/null)" = "2" ] \
        && ok "MEDIA the picked app's artwork arrived once more" \
        || bad "MEDIA the picked app's artwork did not arrive"
    wait_until 20 seen_second_seek \
        && ok "MEDIA a seek on the picked session reached the phone (5000 ms)" \
        || bad "MEDIA no second seek at the phone ($(media_events rx | tr '\n' '|'))"

    # (e) no track text or picture bytes in any log.
    ! grep -qE 'pd-media-(title|artist|album)-9|/9j/4AAQ' \
        "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null \
        && ok "MEDIA no track text or artwork bytes reached a log" \
        || bad "MEDIA track text or artwork bytes leaked"

    # The next fakephone start empties the shared event log; keep this phase's.
    cp "$WORK/events.jsonl" "$WORK/media-events-phase1.jsonl" 2>/dev/null
    stop_app
    stop_fakephone
    wait_until 10 no_fakephone
    sleep 2

    # (f) an older phone: today's media.state only; no sessions, no artwork,
    # no canSeek/volume, and the Mac keeps its single-session behaviour.
    FAKE_ARGS="--older-phone" start_fake '' || return 1
    cat > "$oldscript" <<'EOF'
wait 5
mediacmd play
wait 1
EOF
    launch --connect "127.0.0.1:$PORT" --quit-after 40 --share-log "$oldlog" \
        --open com.whatsapp --debug-input-script "$oldscript"
    wait_until 20 old_log_has "media set playing=true" \
        && ok "MEDIA the older phone's state still reaches Now Playing" \
        || bad "MEDIA no state from the older phone: $(tr '\n' '|' < "$oldlog" 2>/dev/null)"
    grep -qE "media set .*canSeek=0 volume=-1 volumeMax=-1 key=-" "$oldlog" 2>/dev/null \
        && ok "MEDIA the older phone's state carries none of the new fields" \
        || bad "MEDIA unexpected older-phone record: $(grep 'media set' "$oldlog" 2>/dev/null | head -1)"
    ! grep -q "media sessions" "$oldlog" 2>/dev/null \
        && ok "MEDIA no session list from the older phone" \
        || bad "MEDIA the older phone produced a media.sessions line"
    ! grep -q "media art" "$oldlog" 2>/dev/null \
        && ok "MEDIA no artwork from the older phone" \
        || bad "MEDIA the older phone produced a media art line"
    wait_until 25 old_log_has "media command play" \
        && ok "MEDIA a transport command still works with the older phone" \
        || bad "MEDIA the older phone got no command"

    stop_app
    stop_fakephone
    wait_until 10 no_fakephone

    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
}

check_notify_vm() {
    if [ "${PD_E2E_IN_VM:-0}" != "1" ] || [ "${VISIBLE:-0}" != "1" ]; then
        skip "notify-vm" "real banners and AX presses, inside the VM's visible run"
        # The quiet watcher needs a moment to install its handlers before
        # stop_watch; without it a run this short has no QUIET line.
        sleep 1
        return 0
    fi
    clean
    local shots="$WORK/shots" device result
    mkdir -p "$shots"
    notify_rx() {
        python3 - "$WORK/events.jsonl" "$@" <<'PY'
import json, sys
path = sys.argv[1]
kind = sys.argv[2]
want_id = sys.argv[3] if len(sys.argv) > 3 else None
want_i = sys.argv[4] if len(sys.argv) > 4 else None
want_len = sys.argv[5] if len(sys.argv) > 5 else None
for line in open(path):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") != "notify" or event.get("kind") != kind:
        continue
    if want_id is not None and event.get("id") != want_id:
        continue
    if want_i is not None and str(event.get("i")) != want_i:
        continue
    if want_len is not None and str(event.get("textLen")) != want_len:
        continue
    sys.exit(0)
sys.exit(1)
PY
    }
    # ax_press NAME [PROCESS] — click the first AX button with that title/
    # description in Notification Center. Names only, never the notification text.
    ax_press() {
        osascript - "$1" "${2:-NotificationCenter}" <<'OSA' 2>/dev/null
on run argv
    set wanted to item 1 of argv
    set procName to item 2 of argv
    tell application "System Events"
        if not (exists process procName) then return "noproc"
        tell process procName
            with timeout of 20 seconds
                repeat with w in windows
                    if my walk(w, wanted) is "clicked" then return "clicked"
                end repeat
            end timeout
        end tell
    end tell
    return "notfound"
end run

on walk(container, wanted)
    tell application "System Events"
        try
            set kids to UI elements of container
        on error
            return "no"
        end try
        repeat with e in kids
            try
                if role of e is "AXButton" then
                    set label to ""
                    try
                        set label to title of e
                    end try
                    if label is "" then
                        try
                            set label to description of e
                        end try
                    end if
                    if label is "" then
                        try
                            set label to help of e
                        end try
                    end if
                    if label is wanted then
                        click e
                        return "clicked"
                    end if
                end if
            end try
            try
                if my walk(e, wanted) is "clicked" then return "clicked"
            end try
        end repeat
    end tell
    return "no"
end walk
OSA
    }
    # banner_close — the usual close names, else the banner's top-left corner.
    banner_close() {
        ax_press "Close" >/dev/null && return 0
        ax_press "Clear" >/dev/null && return 0
        ax_press "Dismiss" >/dev/null && return 0
        ax_press "Close Notification" >/dev/null && return 0
        local frame x y
        frame="$(osascript <<'OSA' 2>/dev/null
tell application "System Events" to tell process "NotificationCenter"
    repeat with w in windows
        set s to size of w
        if (item 1 of s) > 250 and (item 1 of s) < 700 and (item 2 of s) > 40 then
            set p to position of w
            return ((item 1 of p) as string) & "," & ((item 2 of p) as string)
        end if
    end repeat
end tell
return ""
OSA
)"
        [ -n "$frame" ] || return 1
        x="$(echo "$frame" | cut -d, -f1)"
        y="$(echo "$frame" | cut -d, -f2)"
        "$CGBIN" click "$((x + 16))" "$((y + 16))" >/dev/null 2>&1 || return 1
        return 0
    }
    shot() { screencapture -x "$shots/$1" >/dev/null 2>&1 || true; }
    # banner_present — a notification window is on screen (its frame is sane).
    banner_present() {
        [ -n "$(osascript <<'OSA' 2>/dev/null
tell application "System Events" to tell process "NotificationCenter"
    repeat with w in windows
        set s to size of w
        if (item 1 of s) > 250 and (item 1 of s) < 700 and (item 2 of s) > 40 then return "yes"
    end repeat
end tell
return ""
OSA
)" ]
    }
    # status_menu open|titles — open the app's menu bar item, or read its items
    # (open it first). One per line for titles.
    status_menu() {
        osascript - "$1" <<'OSA' 2>/dev/null
on run argv
    set mode to item 1 of argv
    tell application "System Events" to tell process "PocketDeck"
        if not (exists menu bar item 1 of menu bar 2) then return "nostatus"
        if mode is "open" then
            click menu bar item 1 of menu bar 2
            delay 1
            return "opened"
        end if
        set names to {}
        repeat with i in menu items of menu 1 of menu bar item 1 of menu bar 2
            set end of names to (title of i as string)
        end repeat
        return names
    end tell
end run
OSA
    }


    # One shape at a time: a single banner is unambiguous for AX and the person.
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO
    stop_fakephone
    FAKE_ARGS="--notify-only pd-a1" start_fake || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "NOTIFY-VM no device id"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    launch --connect "127.0.0.1:$PORT" --quit-after 150
    # The first real banner may come with the system's permission prompt.
    sleep 2
    # The system asks once per guest image; "Allow" may belong to any of these.
    for proc in NotificationCenter UserNotificationCenter PocketDeck "PocketDeck Notifications"; do
        ax_press "Allow" "$proc" >/dev/null
    done
    wait_until 10 grep -q "notify authorization" "$WORK/app.log" 2>/dev/null || true
    grep -q "notify authorization granted=true" "$WORK/app.log" 2>/dev/null \
        && ok "NOTIFY-VM macOS authorized PocketDeck's notifications" \
        || bad "NOTIFY-VM the guest refuses PocketDeck's notifications (no banner can appear; reset the guest's TCC answer)"
    wait_until 20 events_have '"id":"pd-a1"' \
        || { bad "NOTIFY-VM the phone never posted"; stop_app; stop_fakephone; return 1; }
    sleep 3
    shot "reply-banner.png"
    result="$(ax_press "Reply")"
    [ "$result" = "clicked" ] \
        && ok "NOTIFY-VM the banner's Reply button was pressed" \
        || bad "NOTIFY-VM no Reply button in the banner ($result)"
    sleep 1
    shot "reply-field.png"
    osascript -e 'tell application "System Events" to keystroke "pd-reply-1"' >/dev/null 2>&1 || true
    sleep 0.5
    ax_press "Send" >/dev/null
    sleep 0.5
    osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1 || true
    wait_until 20 notify_rx action pd-a1 1 10 \
        && ok "NOTIFY-VM the typed reply reached the phone (i=1, length 10)" \
        || bad "NOTIFY-VM the phone got no reply action"
    shot "reply-sent.png"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # Copy code on a real banner; the guest's pasteboard is read and cleared.
    FAKE_ARGS="--notify-only pd-a4" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 90
    wait_until 20 events_have '"id":"pd-a4"' \
        || { bad "NOTIFY-VM the code shape never posted"; stop_app; stop_fakephone; return 1; }
    sleep 3
    shot "code-banner.png"
    result="$(ax_press "Copy code")"
    [ "$result" = "clicked" ] \
        && ok "NOTIFY-VM the banner's Copy code button was pressed" \
        || bad "NOTIFY-VM no Copy code button ($result)"
    sleep 1
    [ "$(pbpaste 2>/dev/null | wc -c | tr -d ' ')" = "6" ] \
        && ok "NOTIFY-VM the code is on the guest's pasteboard (6 bytes)" \
        || bad "NOTIFY-VM the pasteboard does not hold a 6-byte code"
    pbcopy < /dev/null
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # A banner clear must reach the delegate (.customDismissAction) and become
    # notify.dismiss at the phone.
    FAKE_ARGS="--notify-only pd-a2" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 90
    wait_until 20 events_have '"id":"pd-a2"' \
        || { bad "NOTIFY-VM the dismissable shape never posted"; stop_app; stop_fakephone; return 1; }
    sleep 3
    shot "dismiss-banner.png"
    banner_close
    sleep 2
    shot "dismiss-after.png"
    wait_until 20 notify_rx dismiss pd-a2 \
        && ok "NOTIFY-VM clearing the banner sent notify.dismiss (customDismissAction works)" \
        || bad "NOTIFY-VM no notify.dismiss after clearing the banner (.customDismissAction not delivered)"

    stop_fakephone
    wait_until 5 no_fakephone
    # Part 2b: a picture on a real banner. The screenshot is the proof for the
    # person; the check asserts the banner window is really there.
    FAKE_ARGS="--notify-only pd-m1" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 90
    wait_until 25 events_have '"id":"pd-m1"' \
        || { bad "NOTIFY-VM the picture notification never posted"; stop_app; stop_fakephone; return 1; }
    sleep 4
    shot "picture-banner.png"
    banner_present \
        && ok "NOTIFY-VM the picture notification is on screen (picture-banner.png)" \
        || bad "NOTIFY-VM no banner for the picture notification"
    banner_close || true
    sleep 1
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    stop_fakephone
    wait_until 5 no_fakephone
    # Part 2b: the menu bar's Live section with a row that advances. Two shots a
    # few seconds apart, the menu left open in between.
    FAKE_ARGS="--notify-only pd-l1" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 90
    wait_until 25 events_have '"id":"pd-l1"' \
        || { bad "NOTIFY-VM the Live Update never posted"; stop_app; stop_fakephone; return 1; }
    sleep 3
    shot "live-banner.png"
    result="$(status_menu open)"
    result="$(status_menu titles)"
    case "$result" in
        *"Live on"*) ok "NOTIFY-VM the menu bar has a Live section on screen" ;;
        *) bad "NOTIFY-VM no Live section in the menu bar ($result)" ;;
    esac
    shot "live-menu-1.png"
    sleep 4
    shot "live-menu-2.png"
    result="$(status_menu titles)"
    case "$result" in
        *"com.uber — "*) ok "NOTIFY-VM the Live row shows its app and progress/clock" ;;
        *) bad "NOTIFY-VM the Live row is not in the menu ($result)" ;;
    esac
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
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
    # The shared app's own launch: the checks after this one use it.
    launch_shared --connect "127.0.0.1:$PORT"
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
}


# --- Live Text (ROADMAP v0.2 #3) ------------------------------------------

# frames_n — the newest frame counter line's cumulative count (--frame-events).
frames_n() {
    grep '"ev":"frames"' "$WORK/events.jsonl" 2>/dev/null | tail -1 \
        | grep -o '"n":[0-9]*' | cut -d: -f2
}

# The mode's script (--debug-livetext, DebugLiveText.swift): enter on the
# video-filled stream, read the word back through VisionKit, stay in the mode
# while the harness sends input that must not reach the phone, copy the frozen
# frame, leave, then enter again and resize the window: that drops to idle.
check_livetext() {
    clean
    FAKE_ARGS="--text-frame POCKETDECK --frame-events" start_fake || return 1
    FAKE_ARGS=""
    rm -f "$WORK/lt-input-go" "$WORK/lt-copy-go" "$WORK/livetext.png"
    printf '%s\n' \
        "enter 1" \
        "wait-analysis POCKETDECK" \
        "waitfile $WORK/lt-copy-go" \
        "copy-image $WORK/livetext.png" \
        "exit" \
        "wait-idle" \
        "enter 1" \
        "wait-analysis" \
        "resize 1 1200 800" \
        "wait-idle" > "$WORK/livetext.txt"
    printf '%s\n' \
        "waitfile $WORK/lt-input-go" \
        "click 0.5 0.5" \
        "type hi" \
        "scroll 3" \
        "hover 0.5 0.5" \
        "rightclick 0.5 0.5" > "$WORK/lt-input.txt"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --debug-livetext "$WORK/livetext.txt" --debug-input-script "$WORK/lt-input.txt" \
        --quit-after 120
    wait_until 30 events_have '"ev":"video","stream":1,"config":true' \
        || { bad "LT no video config"; stop_app; stop_fakephone; return 1; }

    # Enter + VisionKit: the frozen frame carries POCKETDECK.
    if wait_until 45 grep -q '"op":"analysis"' "$WORK/app.log"; then
        local line
        line="$(grep '"op":"analysis"' "$WORK/app.log" | tail -1)"
        case "$line" in
            *'"state":"shown"'*) ok "LT enter froze the frame and VisionKit finished" ;;
            *) bad "LT analysis did not reach shown ($line)" ;;
        esac
        case "$line" in
            *'"hasText":true'*) ok "LT the overlay found text" ;;
            *) bad "LT no text in the frozen frame ($line)" ;;
        esac
        case "$line" in
            *'"contains":true'*) ok "LT the analysis reads POCKETDECK" ;;
            *) bad "LT the analysis does not contain POCKETDECK ($line)" ;;
        esac
    else
        bad "LT no analysis result (app log: $(tail -3 "$WORK/app.log"))"
    fi

    # While frozen the phone must receive no input at all and send no frames.
    sleep 0.5
    local frames_frozen inputs_before inputs_after frames_after
    frames_frozen="$(frames_n)"
    inputs_before="$(count_events '"ev":"input"')"
    touch "$WORK/lt-input-go"
    sleep 3
    inputs_after="$(count_events '"ev":"input"')"
    [ "$inputs_after" = "$inputs_before" ] \
        && ok "LT no INPUT frame reached the phone in the mode ($inputs_before before, $inputs_after after click/type/scroll/hover/right-click)" \
        || bad "LT input reached the phone in the mode ($inputs_before -> $inputs_after)"
    frames_after="$(frames_n)"
    [ "${frames_after:-0}" = "${frames_frozen:-0}" ] \
        && ok "LT the phone stopped sending frames while frozen (n=$frames_after)" \
        || bad "LT frames kept flowing in the mode (n ${frames_frozen:-0} -> ${frames_after:-0})"

    # Copy Window Image: a PNG of exactly the stream's pixels.
    touch "$WORK/lt-copy-go"
    if wait_until 20 grep -q '"op":"copy"' "$WORK/app.log"; then
        local copy pw ph
        copy="$(grep '"op":"copy"' "$WORK/app.log" | tail -1)"
        if [ -s "$WORK/livetext.png" ]; then
            read -r pw ph <<< "$(python3 - "$WORK/livetext.png" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read(33)
if data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit(1)
w, h = struct.unpack(">II", data[16:24])
print(w, h)
PY
)"
            local want_w want_h
            want_w="$(grep -o '"w":[0-9]*' <<< "$copy" | cut -d: -f2)"
            want_h="$(grep -o '"h":[0-9]*' <<< "$copy" | cut -d: -f2)"
            if [ "${pw:-0}" = "${want_w:-x}" ] && [ "${ph:-0}" = "${want_h:-x}" ]; then
                ok "LT copy-image wrote a ${pw}x${ph} PNG, the stream's own pixels"
            else
                bad "LT copy-image is ${pw:-?}x${ph:-?}, the frame says ${want_w:-?}x${want_h:-?}"
            fi
        else
            bad "LT copy-image wrote no file ($copy)"
        fi
    else
        bad "LT no copy-image result"
    fi

    # Exit: live video again, the phone's frames flow (the counter moves).
    if wait_until 20 grep -q '"op":"idle"' "$WORK/app.log" \
        && grep '"op":"idle"' "$WORK/app.log" | tail -1 | grep -q '"ok":true' \
        && grep '"op":"idle"' "$WORK/app.log" | tail -1 | grep -q '"state":"idle"'; then
        ok "LT exit left the mode"
    else
        bad "LT exit stayed in the mode"
    fi
    local resumed
    resumed="$(frames_n)"
    # "Changed", not "grew": a resumed stream may restart the fakephone's
    # encoder, and its frame counter with it.
    if wait_until 20 eval '[ -n "$(frames_n)" ] && [ "$(frames_n)" != "${resumed:-0}" ]'; then
        ok "LT video frames render again after exit (n $resumed -> $(frames_n))"
    else
        bad "LT no frames after exit (n $resumed -> $(frames_n))"
    fi

    # A stream resize while in the mode drops back to idle.
    # The second enter runs VisionKit again; under load that alone can take
    # half a minute.
    if wait_until 60 [ "$(grep -c '"op":"resize"' "$WORK/app.log")" -ge 1 ]; then
        wait_until 15 [ "$(grep -c '"op":"idle"' "$WORK/app.log")" -ge 2 ] \
            && ok "LT a stream resize while in the mode dropped back to idle" \
            || bad "LT the resize did not return the mode to idle"
    else
        bad "LT the second enter/resize phase did not run"
    fi
    stop_app
    stop_fakephone
}

check_orphans() {
    end_shared
    sleep 1
    local n
    n="$(e2e_app_pids | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan PocketDeck processes" || bad "C9 $n orphan PocketDeck processes"
    n="$(pgrep -f -- "--events $WORK/events.jsonl" | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan fakephone processes" || bad "C9 $n orphan fakephone processes"
}

# newer_than <file> <path...> — some file under the paths changed after <file>
# (true when <file> does not exist).
newer_than() {
    local stamp="$1"
    shift
    [ -e "$stamp" ] || return 0
    [ -n "$(find "$@" -newer "$stamp" -print -quit 2>/dev/null)" ]
}

APP_SOURCES=("$MACOS/Sources" "$MACOS/Shim" "$MACOS/Extensions" "$MACOS/Package.swift"
             "$MACOS/Package.resolved" "$MACOS/scripts/bundle.sh")

# build_e2e_app — bundles the current tree to build/e2e/PocketDeck.app, once per
# run and only when a source changed since the bundle was made (bundle.sh's
# `swift build` costs half a minute of CPU even when it has nothing to do).
# PD_E2E_REBUILD=1 bundles anyway. PD_E2E_PREBUILT names a bundle built
# elsewhere (vm-e2e.sh builds it on the host and copies it into the guest);
# then nothing is rebuilt here.
build_e2e_app() {
    [ -z "${PD_E2E_PREBUILT:-}" ] || return 0
    if [ "${PD_E2E_REBUILD:-0}" != "1" ] && ! newer_than "$APP" "${APP_SOURCES[@]}"; then
        say "bundle: $E2E_BUNDLE is newer than its sources; not rebuilt (PD_E2E_REBUILD=1 does)"
        return 0
    fi
    if ! "$MACOS/scripts/bundle.sh" "$E2E_BUNDLE" --variant e2e > "$WORK/bundle.log" 2>&1; then
        say "could not bundle $E2E_BUNDLE:"; tail -20 "$WORK/bundle.log"; return 1
    fi
}

# shellcheck source=e2e-checks.sh
. "$MACOS/scripts/e2e-checks.sh"

usage() {
    say "usage: check-e2e.sh [$(check_list)|all [--shard N/M]]"
    exit 2
}

which_check="${1:-all}"
if [ "$which_check" = "all" ]; then
    CHECKS=("${ALL_CHECKS[@]}")
elif valid_check "$which_check"; then
    CHECKS=("$which_check")
else
    usage
fi
# `all --shard N/M`: the Nth of M consecutive slices of `all` (with C9 at the
# end of each), so a full run can be spread over several idle periods.
if [ "${2:-}" = "--shard" ]; then
    [ "$which_check" = "all" ] || usage
    case "${3:-}" in
        [1-9]/[1-9]|[1-9]/[1-9][0-9]|[1-9][0-9]/[1-9][0-9]) ;;
        *) usage ;;
    esac
    shard="${3%/*}" shards="${3#*/}"
    [ "$shard" -le "$shards" ] || usage
    from=$(( (shard - 1) * ${#ALL_CHECKS[@]} / shards ))
    to=$(( shard * ${#ALL_CHECKS[@]} / shards ))
    CHECKS=("${ALL_CHECKS[@]:$from:$((to - from))}")
elif [ $# -gt 1 ]; then
    usage
fi
acquire_lock
wait_for_other_runs
pick_run
mkdir -p "$WORK"
say "run: port $PORT, work $WORK, profile $PROFILE, app $E2E_BUNDLE"
[ "$which_check" = "all" ] && say "checks: ${CHECKS[*]}"
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
for check in "${CHECKS[@]}"; do
    # PD_E2E_MARKS (scripts/e2e-cost.py --by-check): when each check started.
    [ -n "${PD_E2E_MARKS:-}" ] && echo "$(date +%s) $check" >> "$PD_E2E_MARKS"
    "check_${check//-/_}"
done
[ "$which_check" = "all" ] && check_orphans

quiet_report
watchdog_report
load_report
say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" = "0" ]
