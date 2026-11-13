#!/usr/bin/env bash
# End-to-end checks C3-C13 for the macOS client against tools/fakephone.
#
#   ./scripts/check-e2e.sh [qr|pair|gates|forgot|pairflow|tls|render|resize|crisp|input|hover|mouseback|input-global|pause|direct|nav|mirror|spotlight|intents|mcp|focus|controls|pinch|chrome|menus|density|trackpad|clip|sharein|links|share|apk|drop|paste|dock|shortcuts|nickname|notify|notify-actions|notify-media|media|audio|handoff|deck|zoom|nfr|bar-title|phones|chain|all [--shard N/M]]
#
# Every check starts from a clean slate (the shared-app checks share one, see
# "The shared app" below): no Contigua or fakephone processes
# left by an earlier run, a fresh fakephone state file and no pairing key in
# the Keychain (a key created by a *different* build would make macOS prompt
# for Keychain access, which is why C4 asks for the key to be deleted first).
#
# Runs are serialized by a lock: they share the port, the work dir and the
# Contigua/fakephone processes, so an overlapping run would kill the other.
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
# build/e2e/Contigua.app, rebuilt from the current tree when it changed
# (PD_E2E_PREBUILT names a bundle built elsewhere, e.g. the host side of a VM
# run, and skips the rebuild). The
# default profile (the user's pairings, cached phones and defaults) and the
# user's build/Contigua.app are never read, rebuilt or killed here.
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
    echo "$FAKE_PY cannot serve TLS 1.3; set PD_FAKE_TLS_PYTHON to a python3.11+ built on OpenSSL 3" >&2
    exit 3
}
E2E_BUNDLE="${PD_E2E_PREBUILT:-$MACOS/build/e2e/Contigua.app}"
APP="$E2E_BUNDLE/Contents/MacOS/Contigua"
CGINPUT="$MACOS/scripts/cgevent-input.swift"
TOOLS="/tmp/contigua-e2e-tools"
# Named by the source's hash: other checkouts share $TOOLS, and a helper built from
# their (older or newer) source must not be taken for this one.
CGBIN="$TOOLS/cgevent-$(shasum "$CGINPUT" | cut -c1-12)"
MENUBAR_SRC="$MACOS/scripts/menubar-item.swift"
MENUBARBIN="$TOOLS/menubar-item-$(shasum "$MENUBAR_SRC" | cut -c1-12)"
AXDUMP_SRC="$MACOS/scripts/ax-dump.swift"
AXDUMPBIN="$TOOLS/ax-dump-$(shasum "$AXDUMP_SRC" | cut -c1-12)"
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
LOCK_DIR="/tmp/contigua-e2e.lock"
KEYCHAIN_SERVICE="app.contigua.mac.$PROFILE"
DEFAULTS_SUITE="app.contigua.mac.$PROFILE"

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

# The one machine-readable place for NFR limits (docs/NFR.md).
NFR_LIMITS="${CONTIGUA_NFR_LIMITS:-$MACOS/scripts/nfr-limits.json}"

# nfr_limit KEY — that limit from nfr-limits.json. A missing key is a broken
# check, not a pass: it stops the run instead of silently disabling a limit.
nfr_limit() {
    local value
    value="$(python3 - "$NFR_LIMITS" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    limits = json.load(handle)
value = limits.get(sys.argv[2])
if isinstance(value, bool) or value is None:
    sys.exit(3)
print(value)
PY
)" || { say "NFR limits: no '$1' in $NFR_LIMITS"; exit 3; }
    printf '%s\n' "$value"
}

# PIDs of the e2e app only: the command line must start with the e2e executable.
# The user's build/Contigua.app is a different path and never matches.
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

# release_inputs — lift any key or mouse button the rig left down (cgevent-input
# release-all). Only the run that holds the lock may: cutting another run's
# drag short is not ours to do.
release_inputs() {
    [ -n "${HOLDS_LOCK:-}" ] || return 0
    [ -x "$CGBIN" ] && "$CGBIN" release-all >/dev/null 2>&1
    return 0
}

# Only a run that holds the lock may stop processes: a run that gave up waiting
# for the lock must leave the running one's app and fakephone alone.
finish() {
    if [ -n "${HOLDS_LOCK:-}" ]; then
        release_inputs
        end_shared
        kill_e2e_app
        stop_fakephone
        stop_vdisplay
        stop_watchdog app
        unregister_share
        unregister_files
        remove_dock_apps
        sweep_test_registrations
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
    # Bounded: a blocked `security` call is the other unbounded step `clean`
    # makes on every styles cell.
    local removed=0
    while run_limited 10 security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; do
        removed=$((removed + 1))
        [ "$removed" -lt 20 ] || break
    done
    # Pairing state = the Mac identity + per-phone pins in the profile
    # folder; the checks pair from scratch each run, so both must go.
    local support="$HOME/Library/Application Support/Contigua-$PROFILE"
    rm -f "$support/identity.json" "$support/pins.json"
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
    mkdir -p "$WORK" "$SHOTS"
    clear_profile_state
}

# sweep_test_registrations — remove the test copies and extensions a run (or a
# killed run) left in LaunchServices and PlugInKit. The allow-list, the removal
# and the one count line live in the script (docs/design/e2e-rig.md); it always
# exits 0, so cleanup can never turn a check's result into a failure.
sweep_test_registrations() {
    bash "$MACOS/scripts/sweep-test-registrations.sh" || true
}

# start_fake [state-file] — same port every time, never mDNS. FAKE_ALLOW_DELAY
# makes the "person" take that many seconds to tap Allow; FAKE_ARGS adds flags.
# stdout goes to fake.log, stderr to fake.err (fakephone puts the listening
# line and its receive diagnostics on stderr): grep both when a line may be
# either. Starts fakephone with FAKE_PY — it needs a TLS 1.3 python.
start_fake() {
    local state="${1:-$WORK/state.json}"
    # The phone's name may carry a space, so it cannot ride the word-split
    # FAKE_ARGS; it is one quoted element of a non-empty array.
    local args=(--port "$PORT" --no-mdns --auto-allow --allow-delay "${FAKE_ALLOW_DELAY:-0}")
    [ -n "${FAKE_NAME:-}" ] && args+=(--name "$FAKE_NAME")
    # shellcheck disable=SC2086
    "$FAKE_PY" "$FAKEPHONE" "${args[@]}" ${FAKE_ARGS:-} \
        --events "$WORK/events.jsonl" \
        --state "$state" > "$WORK/fake.log" 2> "$WORK/fake.err" &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" "$WORK/fake.err" 2>/dev/null && return 0
        sleep 0.25
    done
    say "fakephone did not start:"; cat "$WORK/fake.log" "$WORK/fake.err"; return 1
}

# apply_mac_defaults — experiment keys for the run's profile (`stream.present=
# paced stream.pixels=panel`). check-e2e clears the suite at every check's
# start, so an outside `defaults write` would not survive; this is the hook the
# strategy bench uses to run the same checks with a Mac switch on.
apply_mac_defaults() {
    local pair
    for pair in ${PD_E2E_MAC_DEFAULTS:-}; do
        defaults write "$DEFAULTS_SUITE" "${pair%%=*}" -string "${pair#*=}"
    done
}

# launch <args...> — starts the app as a direct child so `wait` works. Quiet runs
# add --background: no activation, no Dock icon, windows on a virtual display.
launch() {
    local quiet=() arg previous=""
    apply_mac_defaults
    [ "$VISIBLE" = "1" ] || quiet=(--background)
    # A relaunch must never be read through the last launch's chrome state (it
    # may already say loading=0): the file starts empty with every launch.
    for arg in "$@"; do
        [ "$previous" = "--debug-chrome-state" ] && rm -f "$arg"
        previous="$arg"
    done
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

# vdisplay_size_for <check> — the display a check draws on. Only the deck
# check's wide steps draw a window bigger than the default screen (the person's
# 1960x1100 Deck; DECK-4/DECK-24) and AppKit shrinks a window to the screen, so
# only that check gets a display that big. Everything else — deckrail's gate A
# included — keeps the run's 1280x800, the size the checks' screen arithmetic is
# written against.
vdisplay_size_for() {
    case "$1" in
        deck|deckstart) echo "2240x1170" ;;
        *) echo "1280x800" ;;
    esac
}

# vdisplay_scale_for <check> — the backing scale its assertions are written
# against. The crispness check describes its windows in Retina pixels (ISS-39);
# every other check runs at 1x, as before.
vdisplay_scale_for() {
    case "$1" in
        crisp) echo 2 ;;
        bar-title) echo 2 ;;
        *) echo 1 ;;
    esac
}

# ensure_vdisplay <check> — the display this check draws on, created or swapped
# at the check boundary. A swap stops this run's app first: a window left on a
# display that goes away jumps to the person's screen.
ensure_vdisplay() {
    local want want_scale
    want="$(vdisplay_size_for "$1")"
    want_scale="$(vdisplay_scale_for "$1")"
    [ "$want" = "${VDISPLAY_SIZE:-}" ] && [ "$want_scale" = "${RUN_SCALE:-}" ] && return 0
    kill_e2e_app
    sleep 1
    stop_vdisplay
    start_vdisplay "$want" "$want_scale"
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
    local size="${1:-1280x800}" scale="${2:-1}"
    # A visible run is on the person's own screens: the app looks for no display
    # of its own there and makes none, so this run makes none either. Those
    # screens are Retina at 2x — the scale the numbers these checks have always
    # been written against.
    if [ "$VISIBLE" = "1" ]; then
        VDISPLAY_ID=""
        VDISPLAY_SIZE="$size"
        RUN_SCALE=2
        return 0
    fi
    VDISPLAY_FILE="$WORK-vdisplay.txt"
    rm -f "$VDISPLAY_FILE"
    "$VDISPLAYBIN" --profile "$PROFILE" --size "$size" --scale "$scale" > "$VDISPLAY_FILE" 2>&1 &
    VDISPLAY_PID=$!
    start_watchdog vdisplay "$VDISPLAY_PID"
    local tries=40
    while [ "$tries" -gt 0 ]; do
        grep -qE '^(id=|FAIL)' "$VDISPLAY_FILE" && break
        sleep 0.25
        tries=$((tries - 1))
    done
    VDISPLAY_ID="$(sed -n 's/^id=\([0-9]*\).*/\1/p' "$VDISPLAY_FILE" | head -1)"
    VDISPLAY_SIZE="$(sed -n 's/^id=[0-9]* w=\([0-9]*\) h=\([0-9]*\).*/\1x\2/p' "$VDISPLAY_FILE" | head -1)"
    RUN_SCALE="$(sed -n 's/^id=[0-9]* .*scale=\([0-9]*\).*/\1/p' "$VDISPLAY_FILE" | head -1)"
    if [ -z "$VDISPLAY_ID" ]; then
        say "FAIL vdisplay: no virtual display for the run ($(tr '\n' ' ' < "$VDISPLAY_FILE"))"
        say "the run stops here: its checks are written against that display"
        stop_vdisplay
        return 1
    fi
    say "run display: virtual display $VDISPLAY_ID, ${VDISPLAY_SIZE:-$size} at scale ${RUN_SCALE:-1} (held for the check)"
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
        # Keep the phone's own files: its state, the TLS identity next to it
        # (a restart must serve the certificate the Mac pinned, not mint a
        # new one the pin refuses), and its logs. Everything else is the
        # previous check's.
        find "$WORK" -mindepth 1 -maxdepth 1 ! -name events.jsonl ! -name state.json \
            ! -name 'state.json.identity' ! -name 'fake*.log' ! -name fake.err ! -name app.log -exec rm -rf {} +
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
    if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
        release_inputs
        rm -rf "$LOCK_DIR"
    fi
    return 0
}

# A run from another checkout or an older copy of this script does not take
# the lock, and its clean-up kills every Contigua process it finds. Wait for
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
# fixed 47000 and /tmp/contigua-e2e, and their clean-up would break this run.
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
    WORK="/tmp/contigua-e2e-$PORT"
    # A check's screenshots outlive its phases: clean() empties WORK, and the
    # shots a check takes in an early phase are still the record of it.
    SHOTS="$WORK-shots"
    mkdir -p "$SHOTS"
}

# Only this run's fakephones (every one is started with this run's --events).
# WORK is unset if the run gave up waiting for the lock before choosing a port.
# The shared phone (above) stays up for the next shared check.
stop_fakephone() {
    [ -n "${SHARED_PID:-}" ] && return 0
    [ -n "${WORK:-}" ] && pkill -f -- "--events $WORK/events.jsonl" >/dev/null 2>&1
    # The phones check runs two fake phones with their own logs.
    [ -n "${WORK:-}" ] && pkill -f -- "--events $WORK/phones-" >/dev/null 2>&1
}

# The CGEvent helper is compiled once: `swift file.swift` re-interprets the
# source on every call, which is seconds per window lookup.
build_cgevent() {
    if [ ! -x "$CGBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$CGINPUT" -o "$CGBIN" >/dev/null 2>&1 || { say "could not build $CGINPUT"; return 1; }
    fi
}



# build_menubar_item — the status item's own frame and its real clicks (a left
# click toggles the panel, a right click opens its menu), found by process id.
build_menubar_item() {
    if [ ! -x "$MENUBARBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$MENUBAR_SRC" -o "$MENUBARBIN" >/dev/null 2>&1 \
            || { say "could not build $MENUBAR_SRC"; return 1; }
    fi
}

build_ax_dump() {
    if [ ! -x "$AXDUMPBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$AXDUMP_SRC" -o "$AXDUMPBIN" >/dev/null 2>&1 \
            || { say "could not build $AXDUMP_SRC"; return 1; }
    fi
}

# wait_for_menu <shown|gone> — the status item's own menu, by the window server
# (a menu is a window far above the panel's level). Real input opens it, so a
# visible check reads the menu a person sees, not a model of it.
wait_for_menu() {
    local want="$1"
    for _ in $(seq 1 40); do
        [ "$("$MENUBARBIN" menu "$APP_PID")" = "$want" ] && return 0
        sleep 0.1
    done
    return 1
}

# ax_tree — what a screen reader hears inside this run's windows, one element
# per line ("AXButton title=[…] desc=[…] help=[…] id=[panel.gear]"). SwiftUI
# keeps that in the accessibility server, not in the views a probe can walk.
ax_tree() { "$AXDUMPBIN" "$APP_PID" 2>&1; }

# windows() — the CGWindow list of Contigua's own windows without a title:
# Only this run's app: the installed app and other checkouts put Contigua
# windows on the same screen, and a check must never match theirs (a phone
# window of the person's own app is portrait and never turns).
windows() {
    if [ -n "${APP_PID:-}" ]; then "$CGBIN" list --pid "$APP_PID"; else "$CGBIN" list; fi
}

# popup_windows — menu and other popup windows on screen (layer >= 100), of any
# app: a check uses it to prove that the menu it opened is closed again. The
# Window Server's menu-bar window sits at a giant layer and is not a popup.
popup_windows() {
    "$CGBIN" all 2>/dev/null | awk '
        $0 !~ /owner=Window Server/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^layer=/) { split($i, part, "=")
                    if (part[2] >= 100 && part[2] < 10000) n++ } } }
        END { print n + 0 }'
}

# window_titles [pid>0] — the Dock/⌘-Tab-style AX title of each window, one per
# line. A pid pins this run's app: other checkouts run their own Contigua.
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

# video_config_have W H — a VIDEO_CONFIG of stream 1 at exactly W x H. The
# event carries `codec` between `config` and `w` (HEVC), so a raw contiguous
# text match cannot be used.
video_config_have() {
    grep -F '"ev":"video"' "$WORK/events.jsonl" 2>/dev/null \
        | grep -F '"stream":1' | grep -F '"config":true' \
        | grep -qF "\"w\":$1,\"h\":$2"
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

# await_window <awk-condition> — prints the id of the first Contigua window
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

count_events() {
    local n
    n="$(grep -c "$1" "$WORK/events.jsonl" 2>/dev/null || true)"
    echo "${n:-0}"
}

# fake_counter writes|input — the fake phone's cumulative counter (the newest
# `counters` event). 0 before the phone has seen anything. A read-only flow's
# side effects are the difference between two reads (docs/NFR.md).
fake_counter() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
value = 0
for line in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "counters":
        value = event.get(sys.argv[2], value)
print(value if isinstance(value, str) else int(value))
PY
}

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
        && ok "[PAIR-9] C3 QR sheet is on screen (launcher + sheet)" \
        || bad "[PAIR-9] C3 no sheet window: $(windows | tr '\n' ' ')"
    case "$(cat "$WORK/qr.txt")" in
        contigua://pair?c=*"&n="*"&f="*"&s="*) ok "[PAIR-9] C3 payload is a contigua://pair c/n/f/s URI" ;;
        *) bad "[PAIR-9] C3 payload shape: $(cat "$WORK/qr.txt")" ;;
    esac
    [ "$(grep -o 'f=[0-9a-f]*' "$WORK/qr.txt" | cut -c3- | tr -d '\n' | wc -c | tr -d ' ')" = "64" ] \
        && ok "[PAIR-9] C3 the Mac fingerprint f is 64 hex" || bad "[PAIR-9] C3 f is not 64 hex"
    [ "$(grep -o 's=[0-9a-f]*' "$WORK/qr.txt" | cut -c3- | tr -d '\n' | wc -c | tr -d ' ')" = "32" ] \
        && ok "C3 the one-time secret s is 32 hex (never a v1 k= key)" \
        || bad "[PAIR-9] C3 s is not 32 hex"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "[PAIR-10] C3 live session tried pair.request while a QR was pending" \
        || ok "[PAIR-10] C3 no pair.request before the scan"

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
        && ok "[PAIR-10] C3 phone proved the scan with pair.qr" || bad "[PAIR-10] C3 no pair.qr"
    grep -q '"t":"pair.ok"' "$WORK/events.jsonl" \
        && ok "[PAIR-10] C3 pair.ok completed the QR pairing" || bad "[PAIR-10] C3 no pair.ok"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "[PAIR-10] C3 pair.request after the scan" || ok "[PAIR-10] C3 no pair.request at all"
    grep -q '"t":"apps.list"' "$WORK/events.jsonl" \
        && ok "C3 app list requested after pairing" || bad "C3 no apps.list"
    grep -q '"t":"window.open"' "$WORK/events.jsonl" && grep -q '"pkg":"com.android.settings"' "$WORK/events.jsonl" \
        && ok "C3 auto-opened app after pairing" || bad "C3 no window.open"
    # The probe session ends `paired`; the reconnect after it authenticates
    # from the stored pins alone (auth_ok, the phone's pin of this Mac).
    grep -q '"state":"paired"' "$WORK/events.jsonl" \
        && [ "$(grep -c '"state":"auth_ok"' "$WORK/events.jsonl")" -ge 1 ] \
        && ok "[PAIR-11] C3 pins stored, reconnect authenticated" \
        || bad "[PAIR-11] C3 no reconnect auth_ok ($(grep -c '"state":"auth_ok"' "$WORK/events.jsonl" 2>/dev/null))"
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
        && ok "[PAIR-5] C4 first launch paired after an 8 s wait for Allow" || bad "[PAIR-5] C4 first launch did not pair"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && ok "[PAIR-3] C4 pair.request sent" || bad "[PAIR-3] C4 no pair.request"
    grep -q '"t":"pair.commit"' "$WORK/events.jsonl" \
        && ok "[PAIR-3] C4 phone committed before the Mac could release anything (pair.commit)" \
        || bad "[PAIR-3] C4 no pair.commit"
    grep -q '"t":"pair.nonce"' "$WORK/events.jsonl" \
        && ok "[PAIR-3] C4 Mac released its nonce (pair.nonce)" || bad "[PAIR-3] C4 no pair.nonce"
    grep -q '"t":"pair.reveal"' "$WORK/events.jsonl" \
        && ok "[PAIR-3] C4 phone revealed its nonce (pair.reveal)" || bad "[PAIR-3] C4 no pair.reveal"
    grep -q '"t":"pair.confirm"' "$WORK/events.jsonl" \
        && bad "[PAIR-3] C4 sent pair.confirm (the code is never typed)" || ok "[PAIR-3] C4 no pair.confirm"
    mac_code() {
        log show --last 4m --info --style syslog \
            --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
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
        && ok "[PAIR-4] C4 the code is the same on both screens ($mac; one §4 exporter)" \
        || bad "[PAIR-4] C4 the screens' codes disagree (mac='${mac:-none}' phone='${phone_code:-none}')"
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
        && ok "[PAIR-8] C4 second launch auth_ok" || bad "[PAIR-8] C4 second launch did not auth"
    grep -q '"t":"pair.request"' "$WORK/events.jsonl" \
        && bad "[PAIR-8] C4 second launch tried to pair again" || ok "[PAIR-8] C4 second launch skipped pairing"

    # PAIR-5: inside the phone's 30 s window the phone answers its own code,
    # and the Mac's sheet says to wait rather than repeating the denial.
    stop_fakephone
    wait_until 5 no_fakephone
    clean
    FAKE_ARGS="--pair-cooldown" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 30
    pair_ax() { ax_tree; }
    wait_until 25 eval 'pair_ax | grep -qF "Wait a moment, then try again."' \
        && ok "[PAIR-5] C4 the phone's cooldown reads \"Wait a moment, then try again.\"" \
        || bad "[PAIR-5] C4 the cooldown sentence is missing ($(ax_tree | tr '\n' '|' | cut -c1-220))"
    ! pair_ax | grep -qF "Pairing was denied on the phone." \
        && ok "[PAIR-5] C4 the cooldown is not shown as a fresh denial" \
        || bad "[PAIR-5] C4 the cooldown repeated the denial sentence"
    pair_ax | grep -qF "Try again" \
        && ok "[PAIR-5] C4 the sheet still offers Try again for after the window" \
        || bad "[PAIR-5] C4 the cooldown sheet lost Try again"
    stop_app
    stop_fakephone

    # PAIR-6/M8: a phone that never answers. Its prompt may be invisible when
    # its notifications are off, so at 20 s the Mac says so.
    wait_until 5 no_fakephone
    clean
    FAKE_ALLOW_DELAY=200 start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 50
    wait_until 20 eval 'pair_ax | grep -qF "Tap Allow on your phone if it shows the same code."' \
        && ok "[PAIR-6] C4 the code sheet is up while the phone decides" \
        || bad "[PAIR-6] C4 no code sheet while the phone never answered"
    ! pair_ax | grep -qF "notifications may be turned off" \
        && ok "[PAIR-6] C4 the notifications hint waits for the 20 s mark" \
        || bad "[PAIR-6] C4 the notifications hint appeared too early"
    sleep 21
    pair_ax | grep -qF "Check your phone: Contigua's notifications may be turned off." \
        && ok "[PAIR-6] C4 at 20 s the Mac names the phone's notifications as the possible cause" \
        || bad "[PAIR-6] C4 the 20 s notifications hint is missing ($(ax_tree | tr '\n' '|' | cut -c1-260))"
    stop_app
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
        && ok "[PAIR-12] B3 pairings off: unknown Mac refused at the handshake" \
        || bad "[PAIR-12] B3 pairings off: no refusal event"
    wait_until 10 eval '[ "$(mac_failed_line)" = "session failed: pairing_off" ]' \
        && ok "[PAIR-13] B3 pairings off: Mac read pairing_off" \
        || bad "[PAIR-13] B3 pairings off: Mac reason '$(mac_failed_line)'"
    wait_until 10 grep -qF "isn't accepting new pairings." "$banner" \
        && ok "[PAIR-13] B3 pairings off: Mac shows \"$(cat "$banner")\"" \
        || bad "[PAIR-13] B3 pairings off: banner '$(cat "$banner" 2>/dev/null)'"
    events_have '"t":"pair.request"' \
        && bad "[PAIR-12] B3 pairings off: Mac still sent pair.request" \
        || ok "[PAIR-12] B3 pairings off: no pairing request left the Mac"
    stop_app
    stop_fakephone
    sleep 1

    # 2. Pair normally, so the phone has a pin for this Mac.
    : > "$WORK/events.jsonl"
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 16
    await_app 16 events_have '"state":"paired"'
    events_have '"state":"paired"' \
        && ok "[PAIR-12] B3 paired a Mac for the gate checks" || bad "[PAIR-12] B3 could not pair"
    stop_fakephone
    sleep 1

    # 3. Pairings off, the same paired Mac: it still connects.
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--refuse-pairings" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 16
    await_app 16 events_have '"state":"auth_ok"'
    events_have '"state":"auth_ok"' \
        && ok "[PAIR-12] B3 pairings off: the paired Mac still authenticated" \
        || bad "[PAIR-12] B3 pairings off: the paired Mac was refused"
    stop_fakephone
    sleep 1

    # 4. Master off: the paired Mac is refused, and the retries use the backoff.
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    FAKE_ARGS="--refuse-connections" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-banner "$banner" --quit-after 45
    wait_until 20 events_have '"state":"refused_connections"' \
        && ok "[PAIR-12] B3 connections off: paired Mac refused at the handshake" \
        || bad "[PAIR-12] B3 connections off: no refusal event"
    wait_until 10 eval '[ "$(mac_failed_line)" = "session failed: connections_off" ]' \
        && ok "[PAIR-13] B3 connections off: Mac read connections_off" \
        || bad "[PAIR-13] B3 connections off: Mac reason '$(mac_failed_line)'"
    wait_until 10 grep -qF "Connections are turned off on FakePhone." "$banner" \
        && ok "[PAIR-13] B3 connections off: Mac shows \"$(cat "$banner")\"" \
        || bad "[PAIR-13] B3 connections off: banner '$(cat "$banner" 2>/dev/null)'"
    grep -qF "Turn on Allow connections in Contigua on your phone." "$banner" \
        && ok "[PAIR-35] B3 connections off: the banner names the phone's switch" \
        || bad "[PAIR-35] B3 connections off: no switch line in '$(cat "$banner" 2>/dev/null)'"
    # PAIR-35: one attempt per 30 s, never the 1/2/4 s loop.
    sleep 6
    attempts="$(count_events '"state":"refused_connections"')"
    [ "$attempts" -ge 1 ] && [ "$attempts" -le 2 ] \
        && ok "[PAIR-35] B3 connections off: $attempts attempt(s) in the first 6 s" \
        || bad "[PAIR-35] B3 connections off: $attempts attempts in the first 6 s (tight loop)"
    sleep 26
    attempts="$(count_events '"state":"refused_connections"')"
    [ "$attempts" -ge 2 ] && [ "$attempts" -le 3 ] \
        && ok "[PAIR-35] B3 connections off: $attempts attempt(s) by 32 s (one per 30 s)" \
        || bad "[PAIR-35] B3 connections off: $attempts attempts by 32 s"
    stop_app
    stop_fakephone
}

# sessions_opened — how many connections the fake accepted this run. A plain
# `grep -c` prints 0 and exits 1 when nothing matches, so the count is read with
# `|| true` and stays one number for the arithmetic test below.
sessions_opened() {
    local n
    n="$(grep -c '"ev":"session","state":"open"' "$WORK/events.jsonl" 2>/dev/null || true)"
    echo "${n:-0}"
}

# check_forgot — PAIR-23: a Mac that still holds this phone's pin but was
# forgotten on the phone (Forget) is told at once and stops retrying, instead of
# waiting out its 15 s handshake timeout and looping on the backoff.
check_forgot() {
    clean
    local banner="$WORK/banner.txt" before after ctl="$WORK-control" dump="$WORK/settings.txt"
    rm -rf "$ctl"; mkdir -p "$ctl"

    # 0. Forget while connected (PAIR-30/32/33): the phone tells the live Mac it
    # was forgotten; the banner is up at once, it stays, no attempt follows, and
    # a relaunch starts in the stored state without a dial. R1 asserts the
    # rendered Deck (its AX tree, not only controller.banner) and the Settings
    # row at the same moment.
    : > "$WORK/fake-ctl"
    FAKE_ARGS="--ctl-file $WORK/fake-ctl" start_fake || return 1
    rm -f "$banner" "$dump"
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" \
        --debug-banner "$banner" --quit-after 60
    # The app has to stay up to receive the forget (`await_app` would stop it
    # the moment it paired); the launch's --quit-after is the phase's bound.
    wait_until 20 events_have '"state":"paired"' \
        || { bad "[PAIR-30] F0 could not connect"; stop_app; stop_fakephone; return 1; }
    wait_until 10 events_have '"t":"apps.list"' \
        && ok "[PAIR-30] F0 the Mac is connected before the phone forgets it" \
        || { bad "[PAIR-30] F0 could not connect"; stop_app; stop_fakephone; return 1; }
    # Settings open and live before the forget, so its row is read at the same
    # moment as the Deck's (R1: one value, not two clocks). The pairing sheet
    # closes 0.6 s after welcome; a sheet up would swallow the Settings scene.
    sleep 2
    control settings-open >/dev/null 2>&1
    wait_until 25 windows_at_least 2 || { bad "[R1] F0 the Settings window never opened"; stop_app; stop_fakephone; return 1; }
    sleep 2
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] && control settings-select "phone:$device" >/dev/null 2>&1
    connected_shown() { control settings-report "$dump" >/dev/null 2>&1; sleep 0.4; grep -q 'header.state=Connected' "$dump" 2>/dev/null; }
    wait_until 20 connected_shown \
        || { control settings-dump "$WORK/geom.txt" >/dev/null 2>&1; say "DEBUG geom: $(cat "$WORK/geom.txt" 2>/dev/null | tr '\n' ' ')"; say "DEBUG dump: $(cat "$dump" 2>/dev/null | tr '\n' '|')"; say "DEBUG windows: $(windows | tr '\n' ' ')"; bad "[R1] F0 Settings never showed the connected state"; stop_app; stop_fakephone; return 1; }
    before="$(sessions_opened)"
    printf 'forget\n' > "$WORK/fake-ctl"
    wait_until 2 eval 'ax_tree | grep -qF "no longer trusts this Mac."' \
        && ok "[R1] F0 the rendered Deck shows the trust-lost banner within 2 s" \
        || bad "[R1] F0 no rendered banner within 2 s ($(ax_tree | tr '\n' '|' | cut -c1-220))"
    wait_until 2 eval 'ax_tree | grep -qE "(title|desc)=\[Settings\].*enabled=\[0\]"' \
        && ok "[R1] F0 the Deck's app tiles are disabled within 2 s" \
        || bad "[R1] F0 the app tiles stayed enabled ($(ax_tree | grep -c 'enabled=\[0\]' | tr -d ' ') disabled)"
    pair_again_shown() { control settings-report "$dump" >/dev/null 2>&1; sleep 0.4; grep -q 'header.state=Pair again' "$dump" 2>/dev/null; }
    wait_until 2 pair_again_shown \
        && ok "[R1] F0 Settings reads Pair again at the same moment" \
        || bad "[R1] F0 Settings header.state=$(sed -n 's/^header.state=//p' "$dump" 2>/dev/null | head -1)"
    wait_until 2 grep -q 'header.action=Pair Again…' "$dump" \
        && ok "[PAIR-34] F0 Settings offers Pair Again…" \
        || bad "[PAIR-34] F0 Settings action=$(sed -n 's/^header.action=//p' "$dump" 2>/dev/null | head -1)"
    grep -qF "no longer trusts this Mac." "$banner" \
        && ok "[PAIR-30] F0 the model banner is up too" \
        || bad "[PAIR-30] F0 no model banner: '$(cat "$banner" 2>/dev/null)'"
    sleep 4
    ax_tree | grep -qF "no longer trusts this Mac." \
        && ok "[PAIR-33] F0 the rendered banner is still there after 4 s (no dismiss)" \
        || bad "[PAIR-33] F0 the rendered banner went away"
    sleep 16
    after="$(sessions_opened)"
    [ "$after" -le "$before" ] \
        && ok "[PAIR-30] F0 no further attempt for 20 s ($before -> $after)" \
        || bad "[PAIR-30] F0 the Mac kept connecting ($before -> $after)"
    stop_app
    stop_fakephone

    # 0b. Relaunch: the stored trust loss starts the Deck in it with no dial.
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    launch --debug-banner "$banner" --quit-after 8
    wait_until 2 grep -qF "no longer trusts this Mac." "$banner" \
        && ok "[PAIR-32] F0 a relaunch starts in trust lost" \
        || bad "[PAIR-32] F0 no banner on the relaunch: '$(cat "$banner" 2>/dev/null)'"
    [ "$(sessions_opened)" -eq 0 ] \
        && ok "[PAIR-30] F0 the relaunch made no attempt" \
        || bad "[PAIR-30] F0 the relaunch dialed the phone"
    stop_app

    # Reset: phase 0 left this profile pinned to a phone whose fake store is
    # empty (the forget cleared it). The existing phases start from a clean
    # slate so the next `--connect` pairs instead of meeting a stale pin.
    clean

    # 1. Pair, so the Mac holds this phone's pin.
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 20
    await_app 20 events_have '"state":"paired"'
    events_have '"state":"paired"' \
        && ok "[PAIR-23] F1 paired a Mac, so it holds the phone's pin" \
        || { bad "[PAIR-23] F1 could not pair"; stop_fakephone; return 1; }

    # 2. The phone forgets every Mac (its own identity and id stay).
    stop_fakephone
    sleep 1
    FAKE_ARGS="--forget-macs" start_fake || return 1
    before="$(sessions_opened)"
    rm -f "$banner"
    launch --connect "127.0.0.1:$PORT" --debug-banner "$banner" --quit-after 30

    # 3. The phone answers not_paired; from that moment the Mac has 2 s to say
    # so (the app's own launch time is not the connect the person waits on).
    wait_until 15 events_have '"state":"refused_not_paired"'         && ok "[PAIR-23] F2 the phone answered not_paired instead of staying silent"         || bad "[PAIR-23] F2 the phone left the Mac waiting"
    wait_until 2 grep -qF "no longer trusts this Mac." "$banner"         && ok "[PAIR-23] F2 the Mac says \"$(cat "$banner")\" within 2 s"         || bad "[PAIR-23] F2 no banner within 2 s: '$(cat "$banner" 2>/dev/null)'"
    wait_until 2 eval '[ "$(mac_failed_line)" = "session failed: not_paired" ]'         && ok "[PAIR-23] F2 the Mac read not_paired"         || bad "[PAIR-23] F2 Mac reason '$(mac_failed_line)'"

    # 4. No retry loop: twenty seconds without another connection.
    sleep 20
    after="$(sessions_opened)"
    [ "$after" -le "$((before + 1))" ] \
        && ok "[PAIR-23] F3 no further connect attempts for 20 s ($before -> $after)" \
        || bad "[PAIR-23] F3 the Mac kept connecting ($before -> $after)"
    stop_app
    stop_fakephone
}

# check_pairflow — ISS-8/R1–R3: the person's sequence after a forget on the
# phone, replayed on the fake. The Deck (rendered AX), Settings and the sheet
# read one link; a deny, a Cancel and Allow connections off/on never dead-end;
# the phone's post-deny cooldown is told as `pair_cooldown`, counted down, and
# ends in a new prompt when the person asks for one.
check_pairflow() {
    clean
    local ctl="$WORK-control" banner="$WORK/banner.txt" dump="$WORK/settings.txt"
    local fake_ctl="$WORK/fake-ctl" before
    pair_commits() { grep -c '"t":"pair.commit"' "$WORK/events.jsonl" 2>/dev/null || true; }
    paired_events() { grep -c '"state":"paired"' "$WORK/events.jsonl" 2>/dev/null || true; }
    rm -rf "$ctl"; mkdir -p "$ctl"; : > "$fake_ctl"
    # Fixture name only (the phone's own name is what the Mac shows).
    FAKE_NAME="Galaxy S25+" FAKE_ARGS="--ctl-file $fake_ctl" start_fake || return 1
    rm -f "$banner" "$dump"
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" \
        --debug-banner "$banner" --quit-after 240
    wait_until 20 events_have '"state":"paired"' \
        || { bad "[R3] PF0 could not pair"; stop_app; stop_fakephone; return 1; }
    wait_until 10 events_have '"t":"apps.list"' \
        || { bad "[R3] PF0 no app list"; stop_app; stop_fakephone; return 1; }

    # R1: the phone forgets while connected; the rendered Deck and the open
    # Settings page show the same state at the same moment. The pairing sheet
    # closes 0.6 s after welcome; a sheet up would swallow the Settings scene.
    sleep 2
    control settings-open >/dev/null 2>&1
    wait_until 25 windows_at_least 2 || { bad "[R1] PF0 the Settings window never opened"; stop_app; stop_fakephone; return 1; }
    sleep 2
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] && control settings-select "phone:$device" >/dev/null 2>&1
    connected_shown() { control settings-report "$dump" >/dev/null 2>&1; sleep 0.4; grep -q 'header.state=Connected' "$dump" 2>/dev/null; }
    wait_until 20 connected_shown \
        || { bad "[R1] PF0 Settings never showed Connected"; stop_app; stop_fakephone; return 1; }
    printf 'forget\n' > "$fake_ctl"
    wait_until 2 eval 'ax_tree | grep -qF "no longer trusts this Mac."' \
        && ok "[R1] PF0 the rendered Deck shows the banner within 2 s" \
        || bad "[R1] PF0 no rendered banner within 2 s"
    wait_until 2 eval 'ax_tree | grep -qE "(title|desc)=\[Settings\].*enabled=\[0\]"' \
        && ok "[R1] PF0 the rendered app tiles are disabled within 2 s" \
        || bad "[R1] PF0 the rendered app tiles stayed enabled"
    pair_again_shown() { control settings-report "$dump" >/dev/null 2>&1; sleep 0.4; grep -q 'header.state=Pair again' "$dump" 2>/dev/null; }
    wait_until 2 pair_again_shown \
        && ok "[R1] PF0 Settings reads Pair again at the same moment" \
        || bad "[R1] PF0 Settings header.state=$(sed -n 's/^header.state=//p' "$dump" 2>/dev/null | head -1)"

    # The fake restarts (the phone's app), armed to deny the next two prompts.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_NAME="Galaxy S25+" FAKE_ARGS="--deny 1 --ctl-file $fake_ctl" start_fake || return 1

    # P1: Pair Again from the Deck's banner is the control a person presses.
    before="$(pair_commits)"
    "$AXDUMPBIN" "$APP_PID" --press "Pair again" >/dev/null 2>&1 \
        && ok "[R3] PF1 the Deck banner offers Pair again" \
        || bad "[R3] PF1 no Pair again button in the Deck's AX tree"
    wait_until 20 eval '[ "$(pair_commits)" -gt "$before" ]' \
        && ok "[R3] PF1 Pair Again reaches the phone's prompt" \
        || bad "[R3] PF1 Pair Again never reached the phone"
    wait_until 5 eval 'ax_tree | grep -qF "Pairing was denied on the phone."' \
        && ok "[R2] PF1 the phone's denial reaches the sheet" \
        || bad "[R2] PF1 no denial sentence"
    ax_tree | grep -qE 'value=\[[0-9]+ s\]' \
        && ok "[R2] PF1 the denial shows the cooldown countdown" \
        || bad "[R2] PF1 no countdown under the denial"
    ax_tree | grep -qE 'desc=\[Try again\].*enabled=\[0\]' \
        && ok "[R2] PF1 Try again waits for the countdown" \
        || bad "[R2] PF1 Try again was enabled inside the phone's window"
    "$AXDUMPBIN" "$APP_PID" --press Cancel >/dev/null 2>&1 \
        && ok "[R3] PF1 Cancel is the sheet's own button" \
        || bad "[R3] PF1 no Cancel button"
    wait_until 10 eval '! ax_tree | grep -qF "Pair with Galaxy S25+"' \
        && ok "[R3] PF1 Cancel closes the sheet" \
        || bad "[R3] PF1 the sheet stayed after Cancel"

    # P1b: a second Pair Again inside the phone's 30 s window is refused with
    # pair_cooldown (no new prompt, no pair.commit): the sheet says to wait.
    # Re-arm the window so this step cannot race the 30 s.
    printf 'cooldown 30\n' > "$fake_ctl"
    sleep 0.3
    before="$(pair_commits)"
    "$AXDUMPBIN" "$APP_PID" --press "Pair again" >/dev/null 2>&1 || true
    wait_until 15 eval 'ax_tree | grep -qF "Wait a moment, then try again."' \
        && ok "[R2] PF1 a second Pair Again inside the window says to wait" \
        || bad "[R2] PF1 the second Pair Again did not meet the cooldown"
    [ "$(pair_commits)" -le "$before" ] \
        && ok "[R2] PF1 no prompt followed inside the phone's window" \
        || bad "[R2] PF1 the phone prompted inside its window"
    "$AXDUMPBIN" "$APP_PID" --press Cancel >/dev/null 2>&1 || true
    wait_until 10 eval '! ax_tree | grep -qF "Pair with Galaxy S25+"' || true

    # P2: Allow connections off says why; back on, the phone's window is still
    # running, so Pair Again meets `pair_cooldown` (not a TLS failure).
    printf 'connections off\n' > "$fake_ctl"
    sleep 0.5
    "$AXDUMPBIN" "$APP_PID" --press "Pair again" >/dev/null 2>&1 || true
    wait_until 15 eval 'ax_tree | grep -qF "Connections are turned off on Galaxy S25+."' \
        && ok "[PAIR-13] PF2 connections off is named in the sheet" \
        || bad "[PAIR-13] PF2 the connections-off refusal was not shown"
    "$AXDUMPBIN" "$APP_PID" --press Cancel >/dev/null 2>&1 || true
    wait_until 10 eval '! ax_tree | grep -qF "Pair with Galaxy S25+"' || true
    printf 'connections on\n' > "$fake_ctl"
    sleep 0.5

    # Re-arm the phone's window so this step is deterministic whatever the
    # earlier steps cost; the Mac's own 30 s deadline starts at the refusal.
    printf 'cooldown 30\n' > "$fake_ctl"
    sleep 0.3
    "$AXDUMPBIN" "$APP_PID" --press "Pair again" >/dev/null 2>&1 || true
    wait_until 15 eval 'ax_tree | grep -qF "Wait a moment, then try again."' \
        && ok "[R2] PF3 inside the phone's window the sheet says to wait" \
        || bad "[R2] PF3 no cooldown sentence"
    ! ax_tree | grep -qF "Pairing was denied on the phone." \
        && ok "[R2] PF3 the cooldown is not shown as a fresh denial" \
        || bad "[R2] PF3 the cooldown repeated the denial sentence"
    wait_until 3 eval '[ "$(mac_failed_line)" = "session failed: pair_cooldown" ]' \
        && ok "[R2] PF3 the Mac read pair_cooldown, not tls" \
        || bad "[R2] PF3 the Mac read '$(mac_failed_line)'"
    # The phone's window closes; the Mac's own countdown still runs to 0.
    printf 'cooldown end\n' > "$fake_ctl"
    # R3: the countdown ends, Try again becomes available, and the person's
    # click gets a prompt (the third one is allowed by the fake).
    wait_until 40 eval 'ax_tree | grep -qE "desc=\[Try again\].*enabled=\[1\]"' \
        && ok "[R2] PF3 Try again is offered when the countdown ends" \
        || bad "[R2] PF3 Try again never came back"
    before="$(pair_commits)"
    paired_before="$(paired_events)"
    "$AXDUMPBIN" "$APP_PID" --press "Try again" >/dev/null 2>&1 || true
    wait_until 20 eval '[ "$(pair_commits)" -gt "$before" ]' \
        && ok "[R3] PF3 Try again after the window reaches the phone's prompt" \
        || bad "[R3] PF3 Try again after the window dead-ended"
    wait_until 20 eval '[ "$(paired_events)" -gt "$paired_before" ]' \
        && ok "[R3] PF3 the pairing completes after the window" \
        || bad "[R3] PF3 the pairing did not complete"
    wait_until 15 eval '! ax_tree | grep -qF "no longer trusts this Mac."' \
        && ok "[R1] PF3 the trust-lost banner clears on the pairing" \
        || bad "[R1] PF3 the trust-lost banner stayed after pairing"

    # R4: the UI actions and the link transitions are greppable. The unified
    # log can lag a second, so each read retries.
    # grep -c, not -q: -q closes the pipe on the first match, log show takes
    # SIGPIPE, and `set -o pipefail` would read the pipeline as a miss.
    app_log_has() {
        [ "$(log show --last 6m --info --style syslog \
            --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
            | grep -cF "$1")" -gt 0 ]
    }
    wait_until 5 app_log_has "ui: pair-again source=deck" \
        && ok "[R4] PF the Deck's Pair Again logs one ui line" \
        || bad "[R4] PF no ui: pair-again source=deck line"
    wait_until 5 app_log_has "ui: pairing-sheet cancel" \
        && ok "[R4] PF Cancel logs one ui line" \
        || bad "[R4] PF no ui: pairing-sheet cancel line"
    wait_until 5 app_log_has "link: pairing(contacting) --fail:pair_cooldown--> pairing(coolingDown)" \
        && ok "[R4] PF the link machine logs the cooldown transition" \
        || bad "[R4] PF no link: ... pair_cooldown ... line"
    stop_app
    stop_fakephone
}

# --- TLS transport matrix (docs/design/e2ee.md §6; the relay row stays with
# the relay's own checks, the code-equality row rides `pair`) ----------------

# mac_failed_line — the last `session failed:` detail this run's app logged.
mac_failed_line() {
    log show --last 5m --info --style syslog \
        --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
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
    # handshake, so each session's 8-hex exporter prefix differs (R3; R5
    # keeps the full hash out of the log). --connect on
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
        --predicate "subsystem == \"app.contigua.mac\" AND (processID == $pidA OR processID == $pidB)" 2>/dev/null \
        | grep -oE 'v2 exporter ready [0-9a-f]{8}' | sort -u | wc -l | tr -d ' ')"
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
    [ -f "$HOME/Library/Application Support/Contigua-$PROFILE/pins.json" ] \
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
            "$HOME/Library/Application Support/Contigua-$PROFILE/pins.json" 2>/dev/null
    }
    await_app 18 rotated_pinned
    grep -q '"state":"auth_ok"' "$WORK/events.jsonl" \
        && ok "TLS3 the re-pair reconnect authenticated" \
        || bad "TLS3 the re-pair never reconnected"
    if [ -n "$rotated_fp" ] && grep -q "\"phoneFingerprintHex\":\"$rotated_fp\"" \
            "$HOME/Library/Application Support/Contigua-$PROFILE/pins.json" 2>/dev/null; then
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
    # The phone holds the old session's slot through its 30 s path grace
    # (PATH-6), so the next connection would be answered `busy`, not judged on
    # the rotated certificate. A restarted phone frees the slot and keeps the
    # pin in state.json, which is what this row is about.
    stop_fakephone
    wait_until 5 no_fakephone
    start_fake || return 1
    "$FAKE_PY" - "$WORK/macrot.identity" "$HOME/Library/Application Support/Contigua-$PROFILE/identity.json" <<'PY'
import json, os, subprocess, sys
identity_dir, identity_file = sys.argv[1], sys.argv[2]
os.makedirs(identity_dir, exist_ok=True)
key = os.path.join(identity_dir, "key.pem")
cert = os.path.join(identity_dir, "cert.pem")
subprocess.run(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey",
                "-noout", "-out", key], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(["/usr/bin/openssl", "req", "-new", "-x509", "-key", key, "-days", "366",
                "-subj", "/CN=Contigua rotated", "-out", cert], check=True,
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
    if grep -IHnE 'BEGIN [A-Z ]*PRIVATE|-----BEGIN CERTIFICATE|EXPORTER_SECRET|exportKeyingMaterial|contigua-memory-only' "$WORK/app.log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null | grep -q .; then
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

# band_edges PNG — black edges of the drawn picture in a window screenshot,
# from the chrome state's frame= (window points) and video= (the picture's rect).
band_edges() {
    local file="$1" fw fh vx vy vw vh
    read -r fw fh vx vy vw vh <<<"$(chrome_state | tr ' ' '\n' \
        | awk -F'[=x,]' '/^frame=/ {printf "%s %s ", $2, $3} /^video=/ {printf "%s %s %s %s", $2, $3, $4, $5}')"
    python3 "$MACOS/scripts/band-edges.py" "$file" "$fw" "$fh" "$vx" "$vy" "$vw" "$vh"
}

# check_mirror_band — the phone mirror's black band (the person's report,
# 2026-10-22). A real phone's frame can carry a band at the right and bottom
# when its encoder size and the screen's aspect differ; --pad makes one, and
# window.content says where the picture is. At every window size the picture
# the Mac draws must have no black edge: the Mac crops to the picture.
check_mirror_band() {
    clean
    rm -f "$WORK/chrome.txt"
    FAKE_ARGS="--first-frame-delay 1 --pad" start_fake || return 1
    mkdir -p "$WORK/control"
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK/control" --quit-after 90
    if ! wait_until 20 chrome_has "loading=0"; then
        bad "BAND the mirror showed no first frame (state: $(chrome_state))"
        stop_app; stop_fakephone; return 1
    fi
    local step size previous file id edges
    # Portrait window sizes in points, odd ones included: each changes the aspect a little.
    step=0
    for size in "" 430x760 384x571 333x741 512x611 297x645; do
        step=$((step + 1))
        if [ -n "$size" ]; then
            previous="$(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+')"
            mirror_control resize-step "${size%x*}" "${size#*x}" \
                || { bad "BAND step $step: resize-step: $CONTROL_REPLY"; break; }
            wait_until 15 [ "$(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+')" != "$previous" ] \
                || { bad "BAND step $step: the window did not change size"; break; }
        fi
        # The picture of the new size: a config and its first frame, then the grab.
        sleep 2
        file="$WORK/band-$step.png"
        id="$(await_window '$5 > $4')" || { bad "BAND step $step: no phone window"; break; }
        screencapture -x -o -l"$id" "$file"
        edges="$(band_edges "$file")"
        if [ "$edges" = "top=0 bottom=0 left=0 right=0" ]; then
            ok "BAND step $step: no black edge ($(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+'), picture $(chrome_state | grep -oE 'video=[0-9,]+'))"
        else
            bad "BAND step $step: black edges $edges ($(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+'), picture $(chrome_state | grep -oE 'video=[0-9,]+'))"
        fi
    done
    stop_app
    stop_fakephone
}

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
    wait_until 30 video_config_have 1600 1200 \
        && ok "[WIN-5] C6 new video config 1600x1200 (the whole ${w}x${h} pt window, at ${scale}x)" || bad "[WIN-5] C6 no new config"
    events_have '"t":"window.resize"' \
        && ok "[WIN-6] C6 window.resize sent" || bad "[WIN-6] C6 no window.resize"
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
        if wait_until 30 video_config_have 1200 1800; then
            ok "[WIN-5] C6 tall shape resized to 1200x1800 (${w}x${h} pt at ${scale}x, the encoder's 2 px alignment)"
        else
            bad "[WIN-5] C6 no tall config (last video $(last_video_size))"
        fi
        screenshot "$w" "$WORK/resize-tall.png" && say "screenshot: $WORK/resize-tall.png"
        stop_app
    fi

    w=$((3200 / scale)); h=$((1000 / scale))
    open_shared --open com.android.settings --resize-stream "1:${w}x${h}-pt" || return 1
    wait_until 30 video_config_have 2560 800 \
        && ok "[WIN-5] C6 ultra-wide capped to 2560x800 (aspect kept)" || bad "[WIN-5] C6 no capped config"
    # dpi = 160 x the video's pixel ratio x density (VideoGeometry.dpi): the
    # capped 2560 px across the window's w pt.
    local want_dpi=$((160 * 2560 / w))
    events_have "\"dpi\":$want_dpi" \
        && ok "[WIN-5] C6 capped size lowers the dpi to $want_dpi" || bad "[WIN-5] C6 dpi did not follow the cap"
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
    ew=$((fw * scale)); eh=$((fh * scale))
    open_shared --open com.android.settings --float-windows \
        --resize-stream "1:${fw}x${fh}-pt" || return 1
    wait_until 30 events_have '"ev":"video","stream":1,"config":true' \
        || bad "C6 live resize: no first video config"
    if win="$(await_window "\$4 == $fw")" && { sleep 0.2; shot_window "$win" "$WORK/resize-fill.png"; }; then
        # The screenshot is taken as the window takes its new shape (inside
        # the 2 s fill timeout); the phone's held answer comes 0.3 s later.
        wait_until 5 events_have '"ev":"resize","held":true' \
            && ok "C6 live resize: the phone held its answer (no config at the new size yet)" \
            || bad "C6 live resize: the phone did not hold the resize answer"
        edges="$(edge_kinds "$WORK/resize-fill.png" "$fw" $((fh + bar)) "$bar")"
        [ "$edges" = "left=stream right=stream bottom=stream top=stream" ] \
            && ok "[WIN-6] C6 live resize: the last frame fills the window, no black bars while the answer is held ($edges)" \
            || bad "[WIN-6] C6 live resize: bars while the answer is held ($edges)"
        say "screenshot: $WORK/resize-fill.png"
    else
        bad "C6 live resize: no window ${fw} pt wide to capture"
    fi
    wait_until 30 video_config_have "$ew" "$eh" \
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
        && ok "[WIN-6] C6 live resize: after the answer the picture is the settled one ($edges)" \
        || bad "[WIN-6] C6 live resize: after the answer ($edges)"
    say "screenshot: $WORK/resize-fill-done.png"

    # A fast drag: ten steps 30 ms apart while the phone holds its answer. At
    # every step the last frame must cover the window (video_gap=0): the
    # display layer follows the view with no implicit animation, so no black
    # band appears while the picture catches up (the person's recording).
    end_shared
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--resize-delay-ms 6000" start_fake || return 1
    FAKE_ARGS=""
    launch_shared --connect "127.0.0.1:$PORT" --debug-chrome-state "$WORK/chrome.txt" || return 1
    # The previous phase's last line is not this window's: start clean.
    rm -f "$WORK/chrome.txt"
    local step maxgap=0 gap deadline args=(--open com.android.settings --float-windows --debug-chrome-state "$WORK/chrome.txt")
    for step in 0 1 2 3 4 5 6 7 8 9; do
        args+=(--resize-stream "1:$(printf '%dx%d-pt@0.%02d' \
            $((520 + step * 30)) $((520 + step * 22)) $((30 + step * 3)))")
    done
    open_shared "${args[@]}" || return 1
    deadline=$(( $(now_ms) + 1500 ))
    while [ "$(now_ms)" -lt "$deadline" ]; do
        gap="$(chrome_state | grep -oE 'video_gap=[0-9]+' | cut -d= -f2)"
        if [ -n "$gap" ] && [ "$gap" -gt "$maxgap" ]; then maxgap="$gap"; fi
        sleep 0.02
    done
    [ "$maxgap" -le 1 ] \
        && ok "[WIN-6] C6 fast resize: the picture covered the window at every step (max video_gap ${maxgap} px)" \
        || bad "[WIN-6] C6 fast resize: a black band while the layer caught up (max video_gap ${maxgap} px)"
    stop_app
    stop_fakephone

    # The phone window mirrors the phone's own screen: no fill, no crop, and
    # the bar above it mirrors the screen's top rows (never a black gap).
    next_shared
    open_shared --open-phone --float-windows --debug-chrome-state "$WORK/chrome.txt" || return 1
    wait_until 30 events_have '"ev":"video","stream":1,"config":true' \
        || bad "C6 phone window: no video config"
    local pw ph
    read -r win _ _ pw ph <<< "$(windows | awk '$5 > $4 {print; exit}')"
    if [ -n "${win:-}" ] && shot_window "$win" "$WORK/resize-phone.png"; then
        # The phone's own pattern has black regions at its edges; the precise
        # rule is the gap between the content and the drawn picture.
        if chrome_has "video_gap=0"; then
            ok "C6 phone window: the mirror fills the content, no black band (video_gap=0)"
        else
            bad "C6 phone window: a black band under the bar (state: $(chrome_state))"
        fi
        say "screenshot: $WORK/resize-phone.png"
    else
        bad "C6 phone window: no portrait window to capture"
    fi

    # A scripted drag on the phone window: ten monotonic proposals through the
    # same windowWillResize call AppKit makes for a mouse move. The window must
    # never snap back (v104 fought the hand: a mostly-down step after a
    # mostly-across one returned a smaller frame).
    local step prev_h="" frame_h monotonic=1
    for step in 0 1 2 3 4 5 6 7 8 9; do
        control resize-step $((500 + step * 30)) $((900 + step * 40)) \
            || { bad "C6 phone drag: resize-step: $CONTROL_REPLY"; monotonic=0; break; }
        frame_h="$(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+' | tail -1 | cut -dx -f2)"
        [ -n "$frame_h" ] || { bad "C6 phone drag: no frame in the chrome state"; monotonic=0; break; }
        if [ -n "$prev_h" ] && [ "$frame_h" -lt "$prev_h" ]; then
            bad "C6 phone drag: the window snapped back at step $step (${prev_h} -> ${frame_h})"
            monotonic=0
            break
        fi
        prev_h="$frame_h"
    done
    [ "$monotonic" = 1 ] \
        && ok "C6 phone drag: a monotonic drag keeps a monotonic window (height ${prev_h} pt)"
    # The delayed phone must not serve the next check in a shared run.
    end_shared
    check_mirror_band
}

# --- C6a: dragbar (WIN-58) -------------------------------------------------

check_dragbar() {
    clean
    # The phone answers a resize the way the real one did while the person
    # dragged: 30-55 ms to encode its first frame at the new size, plus the
    # link. 150 ms keeps the last frame filling the window long enough to see
    # what the screen shows while it catches up.
    FAKE_ARGS="--resize-delay-ms 150" start_fake || return 1
    FAKE_ARGS=""
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$PORT" --debug-control "$WORK-control" --quit-after 180
    local tries=60
    while ! control open --open com.android.settings --float-windows \
        --resize-stream "1:480x400-pt@0.2" --debug-chrome-state "$WORK/chrome.txt"; do
        tries=$((tries - 1))
        if [ "$CONTROL_REPLY" != "not online" ] || [ "$tries" -le 0 ]; then
            bad "DRAGBAR open: $CONTROL_REPLY"
            stop_app; stop_fakephone; return 1
        fi
        sleep 0.5
    done
    if ! wait_until 30 events_have '"ev":"video","stream":1,"config":true'; then
        bad "DRAGBAR no first video config"
        stop_app; stop_fakephone; return 1
    fi
    local bar=28
    local id
    id="$(await_window '$4 == 480 && $5 == 428')" \
        || { bad "DRAGBAR no 480x428 pt window (480x400 stream + 28 pt bar)"; stop_app; stop_fakephone; return 1; }
    wait_until 10 chrome_has "loading=0" \
        || bad "DRAGBAR the first frame never filled the window (state: $(chrome_state))"
    sleep 1

    local spec name amount steps out cap before after before_config summary
    # 25 pt per data step: about 1500 pt/s at a 60 Hz cadence. The window
    # starts at 480x428; right +300 and bottom +200 fit the 1280x800 run
    # display, and top +100 (growing upward) still fits.
    for spec in "right:300:12" "bottom:200:8" "top:100:4"; do
        IFS=: read -r name amount steps <<<"$spec"
        out="$WORK/dragbar-$name"
        rm -rf "$out"; mkdir -p "$out"
        before="$(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+' | tail -1)"
        before_config="$(last_config_size)"
        # `screencapture -l` reads the window's own pixels with no shadow, as
        # the chrome check does; a process per shot reaches about 7 frames a
        # second, which the report states.
        ( n=0; end=$(( $(now_ms) + 900 ))
          while [ "$(now_ms)" -lt "$end" ]; do
              n=$((n + 1))
              screencapture -x -o -l"$id" "$out/f-$n.png" 2>/dev/null || break
          done ) &
        cap=$!
        # The window's own live-resize path, one step every 16 ms. A quiet
        # host run may not post real mouse events (the pointer must stay on
        # the person's screen); `--post-to-pid` events do not start AppKit's
        # frame drag, and a visible run is not allowed for this check.
        control resize-drag "$name" "$amount" "$steps" 16 \
            || bad "DRAGBAR $name: resize-drag: $CONTROL_REPLY"
        wait "$cap"
        after="$(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+' | tail -1)"
        if [ "$after" = "$before" ]; then
            bad "DRAGBAR $name: the drag did not resize the window ($before)"
        else
            say "DRAGBAR $name: window $before -> $after"
        fi
        wait_until 10 config_changed_from "$before_config" \
            || bad "DRAGBAR $name: the phone did not answer the drag's resize (last $(last_config_size))"
        summary="$(python3 "$MACOS/scripts/window-bands.py" --dir "$out" --bar "$bar" --scale "${RUN_SCALE:-1}")"
        case "$summary" in
            *"bad=none"*)
                ok "[WIN-58] DRAGBAR $name edge: no black strip wider than 2 px on any frame ($summary)" ;;
            *)
                bad "[WIN-58] DRAGBAR $name edge: a black strip on the screen ($summary)" ;;
        esac
        [ -f "$out/worst-$name.png" ] && say "crop: $out/worst-$name.png"
        sleep 0.4
    done
    stop_app
    stop_fakephone
}

# --- C6b: crispness (ISS-39) ---------------------------------------------

# The last app stream's video config, as "WxH" pixels.
last_config_size() {
    python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
size = ""
for line in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "video" and event.get("config") and event.get("stream") == 1:
        size = "%dx%d" % (event.get("w"), event.get("h"))
print(size)
PY
}

# config_changed_from <WxH> — the newest config is a different, real size.
config_changed_from() {
    local now
    now="$(last_config_size)"
    [ -n "$now" ] && [ "$now" != "$1" ]
}

# window_at <W> — the first window is W points wide and its first frame is up.
window_at() {
    python3 - "$(chrome_state)" "$1" <<'PY'
import re, sys
state, width = sys.argv[1], int(sys.argv[2])
frame = re.search(r"frame=(\d+)x(\d+)", state)
sys.exit(0 if frame and int(frame.group(1)) == width and "loading=0" in state else 1)
PY
}

# check_crisp — the phone draws a still pattern of 1 px line pairs and small
# text; the Mac's window is captured at backing pixels and compared with the
# encoder's own source. The pair is one size whose pixels are not multiples of
# 16 (2406x1386 at 2x) and one that is (2400x1376). On a phone that reports its
# encoder alignment the moved metric is the proof (ISS-39).
check_crisp() {
    local control="1200x688" odd="1203x693"
    local cr="$WORK/crisp" scale="$RUN_SCALE"
    check_crisp_size() {
        local label="$1" w="${2%x*}" h="${2#*x}"
        local want_w=$((w * scale)) want_h=$((h * scale)) win crop gt initial metrics psnr contrast shot_h
        rm -f "$WORK/chrome.txt"
        open_shared --open com.android.settings --float-windows \
            --resize-stream "1:${w}x${h}-pt" --debug-chrome-state "$WORK/chrome.txt" \
            || { bad "[CRISP] $label: the window did not open"; return 1; }
        initial="$(last_config_size)"
        wait_until 30 config_changed_from "$initial" \
            || { bad "[CRISP] $label: no config after the resize (still ${initial:-none})"; return 1; }
        win="$(await_window "\$4 == $w")" \
            || { bad "[CRISP] $label: no ${w}x${h} pt window"; return 1; }
        # The answer's own frame, then a moment of stillness: the pattern is
        # static, so this is the fresh keyframe the resize's new encoder sent.
        wait_until 10 window_at "$w" \
            || { bad "[CRISP] $label: the window never settled at ${w} pt wide ($(chrome_state | grep -oE ' frame=[0-9x]+' | tr '\n' ' '))"; return 1; }
        sleep 1
        shot_window "$win" "$WORK/crisp-$label-window.png" \
            || { bad "[CRISP] $label: no window capture"; return 1; }
        # The video is the window's bottom h*scale rows (the framed bar sits
        # above it). This is the drawn rect for these two sizes both before
        # the fix (the quantisation is stretched) and after it (1:1).
        shot_h="$(sips -g pixelHeight "$WORK/crisp-$label-window.png" 2>/dev/null \
            | awk '/pixelHeight/{print $2}')"
        [ -n "$shot_h" ] || { bad "[CRISP] $label: cannot read the capture"; return 1; }
        crop="0,$((shot_h / scale - h)),$w,$h"
        gt="$(last_config_size)"
        [ -f "$cr/pattern-$gt.png" ] \
            || { bad "[CRISP] $label: the phone wrote no pattern for $gt (have: $(ls "$cr" 2>/dev/null | tr '\n' ' '))"; return 1; }
        metrics="$(python3 "$MACOS/scripts/crisp-metric.py" \
            --capture "$WORK/crisp-$label-window.png" --reference "$cr/pattern-$gt.png" \
            --regions "$cr/pattern-$gt.json" --crop "$crop" --scale "$scale" \
            --save-crop "$SHOTS/crisp-$label.png" \
            --save-zoom "$SHOTS/crisp-$label-zoom4.png" 2>&1)" \
            || { bad "[CRISP] $label: the metric failed: $metrics"; return 1; }
        psnr="$(sed -n 's/.*psnr=\([0-9.]*\).*/\1/p' <<<"$metrics")"
        contrast="$(sed -n 's/.*contrast=\([0-9.]*\).*/\1/p' <<<"$metrics")"
        say "CRISP $label window=${w}x${h}pt stream=$gt $metrics"
        echo "$psnr $contrast" > "$WORK/crisp-$label.txt"
        [ "$gt" = "${want_w}x${want_h}" ] \
            && ok "[CRISP] $label: the stream is the window's ${want_w}x${want_h} backing pixels" \
            || bad "[CRISP] $label: the stream is $gt, not the window's ${want_w}x${want_h} backing pixels"
    }

    end_shared
    rm -rf "$cr"
    mkdir -p "$cr" "$SHOTS"
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--encoder-report --encoder-align 2 --crisp-pattern $cr" start_fake || return 1
    FAKE_ARGS=""
    launch_shared --connect "127.0.0.1:$PORT" || return 1

    check_crisp_size control "$control"
    next_shared
    check_crisp_size odd "$odd"

    local c_psnr c_con o_psnr o_con
    read -r c_psnr c_con < "$WORK/crisp-control.txt" 2>/dev/null || true
    read -r o_psnr o_con < "$WORK/crisp-odd.txt" 2>/dev/null || true
    if [ -n "${c_psnr:-}" ] && [ -n "${o_psnr:-}" ]; then
        # The fixed non-multiple size must reach the control within this margin:
        # the same encoder, bitrate and decoder, so the only difference left is
        # the size's phase against the window's pixels.
        if python3 - "$c_psnr" "$c_con" "$o_psnr" "$o_con" <<'PY'
import sys
control_psnr, control_con, odd_psnr, odd_con = (float(v) for v in sys.argv[1:5])
# The measured pair: 49.31 dB / 1.000 control and 52.66 dB / 1.000 on the
# non-multiple size with the fix; 40.89 dB / 0.801 when it was stretched.
# 1 dB and 0.03 leave room for one encoder keyframe's own noise.
sys.exit(0 if odd_psnr >= control_psnr - 1.0 and odd_con >= control_con - 0.03 else 1)
PY
        then
            ok "[CRISP] non-multiple size scores like the control (psnr ${o_psnr} vs ${c_psnr} dB, contrast ${o_con} vs ${c_con})"
        else
            bad "[CRISP] non-multiple size is worse than the control (psnr ${o_psnr} vs ${c_psnr} dB, contrast ${o_con} vs ${c_con})"
        fi
    fi
    say "screenshots: $SHOTS/crisp-control.png $SHOTS/crisp-control-zoom4.png $SHOTS/crisp-odd.png $SHOTS/crisp-odd-zoom4.png"
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
    # The script's right click is the "delivered" signal and asserts one Back,
    # so the Input setting is Back here; the default (Long press) has its own
    # steps in `mouseback`.
    control secondary-click back || bad "C7 secondary-click back: $CONTROL_REPLY"
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
    # The real right click below is the "delivered" signal and asserts Back.
    defaults write "$DEFAULTS_SUITE" "input.secondaryClick" -string back
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
        "waitfile $WORK/mb-step-key" "key cmd+[" \
        "waitfile $WORK/mb-step-secondary" "rightclick 0.5 0.5" \
        "waitfile $WORK/mb-step-backset" "rightclick 0.5 0.5" > "$WORK/mb-a.txt"
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
    # A secondary click (Settings ▸ Input, the default Long press): the touch
    # goes down at the pointer and stays down for the long-press timeout, then
    # up — no nav back. A quick two-finger click still opens the context menu.
    control secondary-click longPress || bad "MB secondary-click longPress: $CONTROL_REPLY"
    touch "$WORK/mb-step-secondary"
    if wait_until 10 eval '[ "$(mb_touch_count 1)" = "2" ]'; then
        ok "MB secondary click: the long press sent one down and one up"
    else
        bad "MB secondary click: $(mb_touch_count 1) touch frames (wanted 2)"
    fi
    hold="$(python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
down = up = None
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "input" and event.get("kind") == "touch" and event.get("stream") == 1:
        if event.get("action") == 0: down = event["ts"]
        if event.get("action") == 1: up = event["ts"]
print("%.2f" % ((up - down) if down is not None and up is not None else 0))
PY
)"
    if awk -v h="$hold" 'BEGIN { exit !(h >= 0.5) }'; then
        ok "MB secondary click: the touch was held ${hold}s (Android's long press)"
    else
        bad "MB secondary click: the touch was held only ${hold}s"
    fi
    [ "$(mb_nav_count 1 back)" = "3" ] \
        && ok "MB secondary click: the default long press sent no Back" \
        || bad "MB secondary click leaked a Back: $(mb_nav_count 1 back)"
    control secondary-click back || bad "MB secondary-click back: $CONTROL_REPLY"
    touch "$WORK/mb-step-backset"
    wait_until 10 eval '[ "$(mb_nav_count 1 back)" = "4" ]' \
        && ok "MB secondary click with the Back setting -> exactly one nav back" \
        || bad "MB secondary click Back: $(mb_nav_count 1 back) nav back"
    [ "$(mb_touch_count 1)" = "2" ] \
        && ok "MB secondary click with the Back setting made no touch" \
        || bad "MB secondary click Back made $(mb_touch_count 1) touch frames"
    control secondary-click longPress >/dev/null 2>&1 || true

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
    # The closing right click is the "delivered" signal and asserts Back.
    control secondary-click back || bad "C13 secondary-click back: $CONTROL_REPLY"
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
# "style=immersive|framed lights=shown|hidden fullbar=shown|hidden
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

# frame_strip_spread <png> <w-pt> <h-pt> — the Framed frame's four 3 pt
# margins and the picture between them: each margin is material (little
# variation), the picture is the live stream (spread >= 40).
frame_strip_spread() {
    python3 - "$@" <<'PY'
import subprocess, sys
path, wpt, hpt = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
size = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height",
                       "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip().split(",")
w, h = int(size[0]), int(size[1])
scale = w / wpt
raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                     capture_output=True).stdout
def spread(pixels):
    lo, hi = [255] * 3, [0] * 3
    for i in pixels:
        for c in range(3):
            v = raw[i + c]
            lo[c] = min(lo[c], v); hi[c] = max(hi[c], v)
    return max(hi[c] - lo[c] for c in range(3))
def row(y, xs):
    return [(int(y) * w + int(x)) * 3 for x in xs]
def col(x, ys):
    return [(int(y) * w + int(x)) * 3 for y in ys]
xs = range(int(120 * scale), w - int(120 * scale), 4)
ys = range(int(80 * scale), h - int(80 * scale), 4)
left = spread(col(int(3 * scale), ys))
right = spread(col(w - int(3 * scale) - 1, ys))
top = spread(row(int(3 * scale), xs))
bottom = spread(row(h - int(3 * scale) - 1, xs))
mid = spread(row(h // 2, range(int(20 * scale), w - int(20 * scale), 4)))
def mark(value, limit):
    return "ok" if value <= limit else "bad"
print("left=%s(%d) right=%s(%d) top=%s(%d) bottom=%s(%d) mid=%s(%d)"
      % (mark(left, 30), left, mark(right, 30), right, mark(top, 30), top,
         mark(bottom, 30), bottom, "ok" if mid >= 40 else "bad", mid))
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
    "$CGBIN" backdrop --file "$WORK/backdrop.txt" --seconds 180 ${on_virtual[@]+"${on_virtual[@]}"} &
    local backdrop=$!
    # The stream's video pixels: 900x600 pt at the run's backing scale, the
    # window's exact pixels at the encoder's 2 px alignment.
    local wake hake style_key
    wake=$((900 * RUN_SCALE)); hake=$((600 * RUN_SCALE))
    style_key="chrome.style.com.android.settings"

    # --- Immersive: the default bar over the stream ---
    defaults delete "$DEFAULTS_SUITE" "$style_key" 2>/dev/null
    printf '%s\n' "hoverat 0 200" > "$WORK/chrome-immersive.txt"
    open_shared --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-immersive.txt" \
        || { kill "$backdrop"; return 1; }
    wait_until 30 events_have '"ev":"video","stream":1,' || { bad "C14 no video config"; kill "$backdrop"; stop_app; stop_fakephone; return 1; }
    local win
    win="$(await_window '$4 == 900 && $5 == 628')" || { bad "C14 no 900x628 pt Immersive window (900x600 stream + 28 pt bar)"; kill "$backdrop"; stop_app; stop_fakephone; return 1; }
    ok "[WIN-4] C14 Immersive is the 900x600 pt stream plus a 28 pt bar, nothing at the sides or bottom (900x628)"
    chrome_is "style=immersive lights=shown fullbar=hidden" \
        && ok "[WIN-7] C14 no stored choice opens Immersive with its bar and lights" \
        || bad "[WIN-7] C14 Immersive at rest: $(chrome_state)"
    chrome_has "can_fullscreen=1" \
        && ok "[WIN-14] C14 an app window may go full screen" \
        || bad "[WIN-14] C14 an app window lost full screen ($(chrome_state))"
    local before
    before="$(window_opens_resizes)"
    case "$before" in
        "open=${wake}x${hake} "*) ok "[WIN-5] C14 window.open is ${wake}x${hake}: the 900x600 pt stream at ${RUN_SCALE}x, no bar in it" ;;
        *) bad "[WIN-5] C14 window.open size: $before" ;;
    esac
    screencapture -x -o -l"$win" "$WORK/chrome-immersive.png" && say "screenshot: $WORK/chrome-immersive.png"
    local bar spread seam tries=40
    while [ "$tries" -gt 0 ]; do
        bar="$(bar_pixels "$WORK/chrome-immersive.png" 900 628)"
        spread="$(echo "$bar" | sed -n 's/.*spread=\([0-9]*\).*/\1/p')"
        seam="$(echo "$bar" | sed -n 's/.*seam=\([0-9]*\).*/\1/p')"
        [ "${spread:-0}" -ge 40 ] && break
        sleep 0.25
        screencapture -x -o -l"$win" "$WORK/chrome-immersive.png"
        tries=$((tries - 1))
    done
    [ "${spread:-0}" -ge 40 ] \
        && ok "[WIN-67] C14 the bar is the mirrored stream, not flat (row spread $spread)" \
        || bad "[WIN-67] C14 the bar is flat (spread ${spread:-0}): no mirror"
    [ "${seam:-255}" -le 60 ] \
        && ok "[WIN-67] C14 the bar's seam row tracks the stream's top row (mean diff $seam)" \
        || bad "[WIN-67] C14 the seam does not track the stream (mean diff ${seam:-255})"
    local x y w h edges
    read -r x y w h <<< "$(windows | awk -v id="$win" '$1 == id {print $2, $3, $4, $5}')"
    screencapture -x -R"$x,$y,$w,$h" "$WORK/chrome-immersive-frame.png"
    edges="$(edge_pixels "$WORK/chrome-immersive-frame.png" "$w" "$h")"
    [ "$edges" = "left=stream right=stream bottom=stream" ] \
        && ok "[WIN-4] C14 the Immersive window's sides and bottom are the stream's edges ($edges)" \
        || bad "[WIN-4] C14 Immersive window edges: $edges"

    # WIN-61: real clicks through the window server on the band. A quiet run
    # cannot post them, so this step runs visible.
    if [ "$VISIBLE" = "1" ]; then
        local bar_touches bar_touches_after bar_clicks bar_clicks_after
        local geom win_h layout_h titlebar band_click
        geom="$(sed -n 's/.* \(geom=.*\)/\1/p' "$WORK/chrome.txt")"
        win_h="$(sed -n 's/.*win:[0-9-]*,[0-9-]*,[0-9]*x\([0-9]*\).*/\1/p' <<< "$geom")"
        layout_h="$(sed -n 's/.*layout:[0-9-]*,[0-9-]*,[0-9]*x\([0-9]*\).*/\1/p' <<< "$geom")"
        titlebar=$(( win_h - layout_h ))
        band_click=$(( titlebar - 2 ))
        say "BAR geometry: $geom (titlebar $titlebar pt, band click $band_click pt)"
        bar_touches="$(grep -c '"kind":"touch","stream":1,"action":0' "$WORK/events.jsonl" 2>/dev/null || true)"
        bar_clicks="$(chrome_state | sed -n 's/.*clicks=\([0-9]*\).*/\1/p')"
        cg_input click --window "$win" --top 14 --dx -200
        sleep 0.6
        cg_input click --window "$win" --top "$band_click" --dx 0
        sleep 0.6
        cg_input click --window "$win" --top "$band_click" --dx 200
        sleep 1
        bar_touches_after="$(grep -c '"kind":"touch","stream":1,"action":0' "$WORK/events.jsonl" 2>/dev/null || true)"
        bar_clicks_after="$(chrome_state | sed -n 's/.*clicks=\([0-9]*\).*/\1/p')"
        [ "$bar_touches_after" -eq "$bar_touches" ] \
            && ok "[WIN-61] C14 real clicks in the bar's band made no touch ($bar_touches)" \
            || bad "[WIN-61] C14 the bar's band click reached the phone as a touch ($bar_touches -> $bar_touches_after)"
        [ "${bar_clicks_after:-0}" -gt "${bar_clicks:-0}" ] \
            && ok "[WIN-61] C14 the clicks were the window's own press (clicks $bar_clicks -> $bar_clicks_after)" \
            || bad "[WIN-61] C14 the bar's band click never reached the chrome (clicks ${bar_clicks:-?} -> ${bar_clicks_after:-?})"
    else
        skip_visible "WIN-61 the bar's band click as a real CGEvent"
    fi
    next_shared

    # --- Framed: the real frame round the picture ---
    rm -f "$WORK/chrome-step-framed" "$WORK/chrome-step-framed-clicks"
    printf '%s\n' "wait 0.6" "windowstyle framed" "wait 1.5" "waitfile $WORK/chrome-step-framed 60" \
        "clickat -450 300" "wait 0.3" "clickat 450 300" "wait 0.3" \
        "clickat 0 640" "wait 0.3" "clickat -450 640" "wait 0.3" \
        "clickat 0 20" "wait 0.3" "waitfile $WORK/chrome-step-framed-clicks 60" "wait 6" > "$WORK/chrome-framed.txt"
    open_shared --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-framed.txt" \
        || { kill "$backdrop"; return 1; }
    win="$(await_window '$4 == 900 && $5 == 628')" || { bad "C14 no window for the Framed switch"; kill "$backdrop"; stop_app; stop_fakephone; return 1; }
    wait_until 8 win_size "$win" 910 643 \
        && ok "[WIN-4] [WIN-71] C14 Framed is the stream plus 38 pt above and 5 pt on the other three sides (910x643)" \
        || bad "[WIN-4] C14 the Framed window is not 910x643: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
    wait_until 5 chrome_is "style=framed" \
        && chrome_has "video=5,38,900,600" \
        && ok "[WIN-71] C14 the picture's rect is the stream inside the frame (rounded 5,38,900,600)" \
        || bad "[WIN-71] C14 the Framed picture's rect: $(chrome_state)"
    before="$(window_opens_resizes)"
    case "$before" in
        "open=${wake}x${hake} "*) ok "[WIN-5] C14 the Framed window still asks for the stream's ${wake}x${hake}, not the window's pixels" ;;
        *) bad "[WIN-5] C14 the Framed window.open size: $before" ;;
    esac
    [ "$(defaults read "$DEFAULTS_SUITE" "$style_key" 2>/dev/null)" = "mat" ] \
        && ok "[WIN-7] C14 Framed's stored value is its own (mat), never the old framed string" \
        || bad "[WIN-7] C14 the stored style key: $(defaults read "$DEFAULTS_SUITE" "$style_key" 2>&1)"
    screencapture -x -o -l"$win" "$WORK/chrome-framed.png" && say "screenshot: $WORK/chrome-framed.png"
    local strips frame_touches frame_touches_after
    strips="$(frame_strip_spread "$WORK/chrome-framed.png" 910 643)"
    say "C14 Framed bands: $strips"
    case "$strips" in
        *"left=ok"*"right=ok"*"top=ok"*"bottom=ok"*)
            ok "[WIN-71] C14 the four frame margins are the material, not the stream" ;;
        *) bad "[WIN-71] C14 the Framed margins do not read as chrome: $strips" ;;
    esac
    case "$strips" in
        *"mid=ok"*) ok "[WIN-71] C14 and the picture between them is the live stream" ;;
        *) bad "[WIN-71] C14 the Framed picture is flat: $strips" ;;
    esac
    frame_touches="$(count_events '"kind":"touch","stream":1,"action":0')"
    touch "$WORK/chrome-step-framed"
    sleep 2.5
    frame_touches_after="$(count_events '"kind":"touch","stream":1,"action":0')"
    [ "$frame_touches_after" -eq "$frame_touches" ] \
        && ok "[WIN-61] C14 presses in the four margins and a rounded corner made no touch ($frame_touches)" \
        || bad "[WIN-61] C14 a frame press reached the phone as a touch ($frame_touches -> $frame_touches_after)"
    touch "$WORK/chrome-step-framed-clicks"
    next_shared

    # --- ⌥⌘F flips the pair both ways ---
    rm -f "$WORK/chrome-step-toggle1" "$WORK/chrome-step-toggle2" "$WORK/chrome-step-toggle3"
    printf '%s\n' "wait 0.6" "click 0.5 0.5" "wait 0.8" "key opt+cmd+f" \
        "waitfile $WORK/chrome-step-toggle1 60" "wait 0.4" "key opt+cmd+f" \
        "waitfile $WORK/chrome-step-toggle2 60" "wait 0.4" "key opt+cmd+f" \
        "waitfile $WORK/chrome-step-toggle3 60" "wait 8" > "$WORK/chrome-toggle.txt"
    open_shared --open com.android.settings --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-toggle.txt" \
        || { kill "$backdrop"; return 1; }
    win="$(await_window '$4 == 900 || $4 == 910')" || { bad "C14 no window for the toggle"; kill "$backdrop"; return 1; }
    wait_until 8 win_size "$win" 910 643 \
        && ok "[WIN-7] C14 the stored framed choice opens Framed (910x643)" \
        || bad "[WIN-7] C14 the stored style did not open its window: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
    touch "$WORK/chrome-step-toggle1"
    wait_until 8 win_size "$win" 900 628 \
        && ok "[WIN-7] C14 ⌥⌘F from Framed takes the frame away: 900x628" \
        || bad "[WIN-7] C14 ⌥⌘F did not reach Immersive: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
    touch "$WORK/chrome-step-toggle2"
    wait_until 8 win_size "$win" 910 643 \
        && ok "[WIN-7] C14 ⌥⌘F from Immersive brings the frame back: 910x643" \
        || bad "[WIN-7] C14 ⌥⌘F did not reach Framed: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
    touch "$WORK/chrome-step-toggle3"
    wait_until 8 win_size "$win" 900 628 \
        && ok "[WIN-7] C14 and again to Immersive: 900x628" \
        || bad "[WIN-7] C14 the toggle pair did not complete ($(windows | awk -v id="$win" '$1 == id {print $4, $5}'))"
    case "$(resize_sizes)" in
        "${wake}x${hake}") ok "[WIN-5] C14 the virtual display kept the stream's size through both styles" ;;
        none) ok "[WIN-5] C14 the virtual display changed nothing: one stream size throughout" ;;
        *) bad "C14 the virtual display changed: $(resize_sizes)" ;;
    esac

    # --- Full screen: the acrylic bar, hidden then revealed (WIN-8, WIN-14) ---
    if [ "$VISIBLE" = "1" ]; then
        local style_pair style_name want_windowed want_w want_h
        for style_pair in "immersive:900x628" "framed:910x643"; do
            style_name="${style_pair%%:*}"
            want_windowed="${style_pair##*:}"
            want_w="${want_windowed%x*}"
            want_h="${want_windowed#*x}"
            next_shared
            rm -f "$WORK/fs-hidden" "$WORK/fs-revealed" "$WORK/fs-left" "$WORK/fs-exit" "$WORK/fs-done"
            printf '%s\n' "wait 1" "windowstyle $style_name" "wait 1" "fullscreen" "wait 6" \
                "waitfile $WORK/fs-hidden 90" "waitfile $WORK/fs-revealed 90" \
                "waitfile $WORK/fs-left 90" "fullscreen" "wait 8" "waitfile $WORK/fs-exit 90" \
                "fullscreen" "wait 6" "waitfile $WORK/fs-done 90" "wait 10" > "$WORK/chrome-fs.txt"
            open_shared --open com.android.settings \
                --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-fs.txt" \
                || { kill "$backdrop"; return 1; }
            win="$(await_window '$4 == 900 || $4 == 910')" || { bad "C14 no window before full screen"; kill "$backdrop"; return 1; }
            if wait_until 20 chrome_all fullscreen=yes fullbar=hidden fullbar_visible=0; then
                ok "[WIN-8] [WIN-14] C14 $style_name full screen starts with the bar hidden ($(chrome_state))"
            else
                bad "[WIN-8] [WIN-14] C14 $style_name never entered full screen: $(chrome_state)"
                continue
            fi
            sleep 0.4
            screencapture -x "$WORK/chrome-fs-$style_name-hidden.png" && say "screenshot: $WORK/chrome-fs-$style_name-hidden.png"
            touch "$WORK/fs-hidden"
            # The absolute point is the screen's top edge; a full-screen
            # window is not in the on-screen list cgevent's --window reads.
            # 6 pt is inside the bar's 8 pt edge band but below the system
            # menu bar's own reveal strip, which would otherwise cover it.
            cg_input moveat --x 200 --y 6
            if wait_until 8 chrome_has "fullbar=shown"; then
                wait_until 4 chrome_has "lights=shown"
                ok "[WIN-8] C14 $style_name: a rest at the top edge reveals the acrylic bar with its lights ($(chrome_state))"
            else
                bad "[WIN-8] C14 $style_name: the top edge revealed nothing: $(chrome_state)"
            fi
            wait_until 4 chrome_has "bar_title=1" \
                && ok "[WIN-8] C14 $style_name: the full-screen bar carries the name" \
                || bad "[WIN-8] C14 $style_name: no title on the full-screen bar ($(chrome_state))"
            sleep 0.3
            screencapture -x "$WORK/chrome-fs-$style_name-revealed.png" && say "screenshot: $WORK/chrome-fs-$style_name-revealed.png"
            local fs_touches fs_clicks fs_touches_after fs_clicks_after
            fs_touches="$(count_events '"kind":"touch","stream":1,"action":0')"
            fs_clicks="$(chrome_state | sed -n 's/.*clicks=\([0-9]*\).*/\1/p')"
            touch "$WORK/fs-revealed"
            sleep 0.5
            cg_input clickat --x 200 --y 14
            sleep 0.8
            fs_touches_after="$(count_events '"kind":"touch","stream":1,"action":0')"
            fs_clicks_after="$(chrome_state | sed -n 's/.*clicks=\([0-9]*\).*/\1/p')"
            [ "$fs_touches_after" -eq "$fs_touches" ] \
                && ok "[WIN-61] C14 $style_name: a click on the full-screen bar made no touch" \
                || bad "[WIN-61] C14 $style_name: the full-screen bar click reached the phone"
            [ "${fs_clicks_after:-0}" -gt "${fs_clicks:-0}" ] \
                && ok "[WIN-61] C14 $style_name: and it was the window's own press" \
                || bad "[WIN-61] C14 $style_name: the full-screen bar click did not reach the chrome"
            cg_input moveat --x 200 --y 400
            if wait_until 8 chrome_has "fullbar=hidden"; then
                ok "[WIN-8] C14 $style_name: leaving the bar hides it ($(chrome_state))"
            else
                bad "[WIN-8] C14 $style_name: the bar stayed after the pointer left: $(chrome_state)"
            fi
            touch "$WORK/fs-left"
            wait_until 12 win_size "$win" "$want_w" "$want_h" \
                && ok "[WIN-14] C14 $style_name: leaving full screen restores the windowed chrome" \
                || bad "[WIN-14] C14 $style_name: exit did not restore the window: $(windows | awk -v id="$win" '$1 == id {print $4, $5}')"
            touch "$WORK/fs-exit"
            touch "$WORK/fs-done"
        done

        # --- Always Visible keeps the full-screen bar up (WIN-9) ---
        next_shared
        rm -f "$WORK/fs-always" "$WORK/fs-short" "$WORK/fs-always-done"
        printf '%s\n' "wait 1" "hidecontrols always" "wait 1" "fullscreen" "wait 6" \
            "waitfile $WORK/fs-always 90" "waitfile $WORK/fs-short 90" "hidecontrols short" "wait 3" "fullscreen" "wait 8" \
            "waitfile $WORK/fs-always-done 90" "wait 10" > "$WORK/chrome-fs-always.txt"
        open_shared --open com.android.settings \
            --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/chrome-fs-always.txt" \
            || { kill "$backdrop"; return 1; }
        win="$(await_window '$4 == 900')" || { bad "C14 no window for Always Visible"; kill "$backdrop"; return 1; }
        if wait_until 20 chrome_all fullscreen=yes fullbar=shown; then
            ok "[WIN-9] C14 Always Visible: the window fills the screen and shows the bar at once ($(chrome_state))"
        else
            bad "[WIN-9] C14 Always Visible did not enter full screen with the bar: $(chrome_state)"
        fi
        cg_input moveat --x 200 --y 500
        sleep 2
        chrome_has "fullbar=shown" \
            && ok "[WIN-9] C14 Always Visible: still up past the hide delay with the pointer away" \
            || bad "[WIN-9] C14 Always Visible hid after the delay: $(chrome_state)"
        [ "$(defaults read "$DEFAULTS_SUITE" "immersive.revealDelay" 2>/dev/null)" = "alwaysVisible" ] \
            && ok "[WIN-9] C14 Always Visible is stored as the one reveal choice" \
            || bad "[WIN-9] C14 Always Visible stored: $(defaults read "$DEFAULTS_SUITE" immersive.revealDelay 2>&1)"
        touch "$WORK/fs-always"
        sleep 0.5
        touch "$WORK/fs-short"
        wait_until 8 chrome_has "fullbar=hidden" \
            && ok "[WIN-9] C14 picking Short takes the shown full-screen bar away" \
            || bad "[WIN-9] C14 Short did not hide the bar: $(chrome_state)"
        touch "$WORK/fs-always-done"
        wait_until 12 chrome_all fullscreen=no fullbar=hidden \
            && ok "[WIN-14] C14 leaving full screen ends the bar's machine" \
            || bad "[WIN-14] C14 after Always Visible full screen: $(chrome_state)"
    else
        skip_visible "C2 full screen and the acrylic bar (a real Space switch and pointer)"
    fi

    # --- Settings: the real window fits the screen and General scrolls ---
    # The reported bug (1680x1050): the General tab ended at "Default window
    # density" and the rows below could not be reached. The dump is the real
    # window: its frame against the screen, the page's scroll view (a document
    # taller than its clip), and whether the last row is on screen once
    # scrolled to the end. The window is the sidebar's 720 pt. (A synthetic
    # wheel event cannot prove a person's scroll here: it is windowless under a
    # quiet run; the VM's visible run does that.)
    next_shared
    rm -f "$WORK/settings-report.txt"
    printf '%s\n' "density com.example.app0 125" "density com.example.app1 125" \
        "density com.example.app2 125" "density com.example.app3 125" \
        "density com.example.app4 125" "density com.example.app5 125" \
        "opensettings" "wait 1" > "$WORK/chrome-settings.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/chrome-settings.txt" \
        || { kill "$backdrop"; return 1; }
    sleep 2
    control settings-dump "$WORK/settings-report.txt" >/dev/null 2>&1
    local report
    report="$(cat "$WORK/settings-report.txt" 2>/dev/null)"
    if [ -z "$report" ]; then
        bad "C14 Settings: the window did not open ($CONTROL_REPLY)"
    else
        say "C14 Settings: $(echo "$report" | tr '\n' ' ')"
        case "$report" in
            *"fits=1"*) ok "C14 Settings window fits the screen's visible frame" ;;
            *) bad "C14 Settings window is taller than the screen" ;;
        esac
        case "$report" in
            *"window=720x"*) ok "C14 Settings: the window is the sidebar's 720 pt wide" ;;
            *) bad "C14 Settings: the window is not 720 pt wide ($(echo "$report" | tr '\n' ' '))" ;;
        esac
        case "$report" in
            *"scroll=1"*) ok "C14 Settings: the page's rows live in a scroll view" ;;
            *) bad "C14 Settings: no scroll view under the page" ;;
        esac
        # The window takes the room the screen allows: at the 450 pt SwiftUI
        # default the General tab was cropped at "Default window density" while
        # the top of the screen was free.
        local content cap
        content="$(sed -n 's/^content=//p' <<< "$report")"
        cap="$(sed -n 's/^cap=//p' <<< "$report")"
        if [ -n "$content" ] && [ -n "$cap" ] && [ "$content" -ge "$cap" ]; then
            ok "C14 Settings: the window takes the screen's room ($content pt of $cap)"
        else
            bad "C14 Settings: the window is shorter than the screen allows (content ${content:-?} pt, cap ${cap:-?})"
        fi
        case "$report" in
            *"at_end=1"*) ok "C14 Settings: the page scrolls to its end" ;;
            *) bad "C14 Settings: the page does not reach its end" ;;
        esac
        case "$report" in
            *"last_visible=1"*) ok "C14 Settings: the open page's last row is reachable" ;;
            *) bad "C14 Settings: the last row is not reachable ($(echo "$report" | tr '\n' ' '))" ;;
        esac
    fi

    # --- CONV-MAC-12: an AX resize stays inside the screen ---
    # A tiler or a script sets a window's size through Accessibility, far past
    # the screen. Every window type — stream, phone mirror, Deck, Settings —
    # must read back no larger than the visible frame: a window a person cannot
    # reach or shrink is the bug this rule exists for.
    rm -f "$WORK/visibleframe.txt" "$WORK/ax-size.txt"
    control open --open-phone --debug-chrome-state "$WORK/chrome.txt" \
        || bad "C12 open-phone: $CONTROL_REPLY"
    sleep 2
    control visibleframe "$WORK/visibleframe.txt" \
        || bad "C12 visibleframe: $CONTROL_REPLY"
    local max_w max_h
    if read -r max_w max_h < "$WORK/visibleframe.txt" 2>/dev/null && [ -n "${max_h:-}" ]; then
        say "C12 the screen's visible frame is ${max_w}x${max_h} pt"
        ax_resize_all 4000 4000 "$WORK/ax-size.txt"
        python3 - "$WORK/ax-size.txt" "$max_w" "$max_h" <<'PY' && ok "[WIN-19] C12 an AX resize to 4000 pt leaves every window inside the visible frame (${max_w}x${max_h})" \
            || bad "[WIN-19] C12 an AX resize left a window larger than the screen"
import sys
max_w, max_h = int(sys.argv[2]), int(sys.argv[3])
rows = []
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 2 or "x" not in parts[1]:
        continue
    title, size = parts[0], parts[1]
    w, h = (int(v) for v in size.split("x"))
    rows.append((title, w, h))
if len(rows) != 4:
    print("windows measured:", rows); sys.exit(1)
print("C12 measured:", ", ".join("%s %dx%d" % row for row in rows))
for title, w, h in rows:
    if w > max_w or h > max_h:
        print("%r is %dx%d, past %dx%d" % (title, w, h, max_w, max_h)); sys.exit(1)
PY
    else
        bad "C12 no visible frame from the app ($(cat "$WORK/visibleframe.txt" 2>/dev/null))"
    fi

    kill "$backdrop" 2>/dev/null; wait "$backdrop" 2>/dev/null
    stop_app
    stop_fakephone
}

# --- MENUS: the whole menu bar after every rebuild (menu-ux) ----------------

# The items the app draws itself, and who may own them. Every one is a SwiftUI
# command's item, so SwiftUI owns it: "MenuItemCallback" for a Button or a
# Toggle, "SwiftUIMenu" for a submenu's parent. An item owned by one of the
# app's own types is one the app built with AppKit and put in the menu itself —
# the pattern that loses items on a rebuild. The owners are the system's; a new
# SwiftUI owner would have to be added, and the app's own types never are.
#
# menu_dump_ok PATH — one dump is the design and structurally sound, and no item
# in it is an AppKit item the app installed: no leading or doubled separator
# anywhere (File/Window/Help still carry the system's own trailing separator
# until the File/Window/Help cleanup), no trailing separator in the app's own
# menus, the View menu is exactly the design's items in order, exactly one of
# Framed/Immersive is checked, and every item the app draws belongs to SwiftUI.
# Every dump below is taken after a step that makes SwiftUI re-evaluate the
# commands, which is where the old injected items vanished and their separators
# closed the gap.
menu_dump_ok() {
    python3 - "$1" <<'PY'
import json, re, sys
APP_ITEMS = ["Add Phone…", "Find Apps", "Phone Mirror", "Open Current App on Mac", "Show Touches",
             "Live Text", "Framed", "Immersive", "Hide Controls", "Density",
             "Turn Off Phone Screen", "Do Not Disturb", "Ring Phone", "Install APK…",
             "Back", "Home", "Recents"]
# SwiftUI items often have no target at all (nil action target); an item the
# app installed with AppKit carries one of the app's own classes.
SYSTEM_OWNERS = {"MenuItemCallback", "SwiftUIMenu", "NSMenu", "NSWindow", "NSApplication",
                 "AppKitApplication", "NSMenuItem", None}
def walk(items):
    for item in items:
        yield item
        if item.get("submenu"):
            yield from walk(item["submenu"])
root = json.load(open(sys.argv[1]))
problems = []
for line in root.get("problems") or []:
    problems.append("shape " + line)
titles = [i["title"] for i in root["items"]]
if titles != ["Contigua", "File", "Edit", "View", "Phone", "Navigate", "Window", "Help"]:
    problems.append("menus: %r" % (titles,))
WANT = {
    "View": ["Find Apps", "—", "Immersive", "Framed", "—", "Hide Controls", "—",
             "Show Touches", "Live Text", "—", "Icon Size", "—", "Density"],
    "Phone": ["Phone Mirror", "Open … on Mac", "—", "Turn Off Phone Screen",
              "Do Not Disturb", "Ring Phone", "—", "Install APK…"],
    "Navigate": ["Back", "Home", "Recents"],
    # File's New item names the key window's app ("New Chrome Window") and
    # reads "New Window" with no app window key (MENU-2), so it is checked by
    # its shape here and by name in the multiwin check.
    "File": ["Add Phone…", "—", "New … Window", "—", "Close", "Close All"],
    "Help": [],
}
for title, want in WANT.items():
    menu = next((i for i in root["items"] if i["title"] == title), None)
    if menu is None:
        problems.append("no %s menu" % title)
        continue
    seq = ["—" if item["isSeparator"] else item["title"] for item in menu["submenu"]
           if not item.get("hidden")]
    if title == "File":
        seq = ["—" if row == "—" else ("New … Window" if row.startswith("New ") and row.endswith(" Window") else row)
               for row in seq]
    if title == "Phone":
        # The handoff item names the app a fresh foreground reply reports; the
        # dump may carry any "Open <app> on Mac" (PANEL-28).
        seq = ["Open … on Mac" if row.startswith("Open ") and row.endswith(" on Mac") else row
               for row in seq]
    if title == "View" and seq and seq[-1] in ("Enter Full Screen", "Exit Full Screen"):
        # AppKit appends its own item (fn-F) to the app's View NSMenu; the
        # design's list is the app's items, and the system item is checked
        # separately as last in View (MENU-4). The separator before it shows
        # in the open menu (the prototype's sheet) but not in this dump.
        visible = [i for i in menu["submenu"] if not i.get("hidden")]
        last = visible[-1]
        if "function" in last["modifiers"] and "control" not in last["modifiers"]:
            seq = seq[:-2] if len(seq) >= 2 and seq[-2] == "—" else seq[:-1]
    if seq != want:
        problems.append("%s: %r wanted %r" % (title, seq, want))
view = next((i for i in root["items"] if i["title"] == "View"), None)
if view is not None:
    by_title = {item["title"]: item for item in view["submenu"]}
    states = [by_title.get("Framed", {}).get("state"), by_title.get("Immersive", {}).get("state")]
    if sorted(states) != ["off", "on"]:
        problems.append("style radios: %r" % (states,))
installed = [(i["title"], i.get("targetClass")) for i in walk(root["items"])
             if (i["title"] in APP_ITEMS or re.fullmatch(r"Open .+ on Mac", i["title"]))
             and i.get("targetClass") not in SYSTEM_OWNERS]
if installed:
    problems.append("items the app installed with AppKit: %r" % (installed,))
# Full screen is AppKit's own, last in View: the app shows no item for it
# (MENU-4, MENU-7). Its one ⌃⌘F item is hidden and allowed to keep the key
# (MENU-8); AppKit appends its own fn-F item to the same NSMenu.
mine = [i for i in walk(root["items"])
        if re.fullmatch(r"(Enter|Exit) Full Screen", i["title"])
        and "control" in i["modifiers"]]
shown = [i["title"] for i in mine
         if not (i.get("hidden") and i.get("allowsKeyWhenHidden"))]
if shown:
    problems.append("the app shows a full-screen item with ⌃⌘F: %r" % (shown,))
if len([i for i in mine if i.get("hidden")]) > 1:
    problems.append("more than one hidden full-screen alternate")
if problems:
    print("; ".join(problems)); sys.exit(1)
PY
}

# full_screen_bar_ok PATH LABEL [REQUIRED] — the bar's full-screen structure
# (MENU-4, MENU-7): the app draws no full-screen item of its own, AppKit's own
# is last in View after a separator with fn-F, and Window keeps the system's
# tiling group (Full Screen Tile, or its "Enter Full Screen" parent on some
# builds). REQUIRED=1 fails when the system item is absent; a quiet tier may
# not show it, and then the line says so instead of pretending.
full_screen_bar_ok() {
    python3 - "$1" "$2" "${3:-0}" <<'PY'
import json, re, sys
path, label, required = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
root = json.load(open(path))
def walk(items):
    for item in items:
        yield item
        if item.get("submenu"):
            yield from walk(item["submenu"])
app_items = list(walk(root.get("items") or []))
# AppKit appends its own item to the app's NSMenu too. The app's only own item
# carries ⌃⌘F and is hidden with its key allowed (MENU-8); anything visible is
# a leftover (MENU-4, MENU-7).
mine = [i for i in app_items
        if re.fullmatch(r"(Enter|Exit) Full Screen", i["title"]) and "control" in i["modifiers"]]
shown = [i["title"] for i in mine
         if not (i.get("hidden") and i.get("allowsKeyWhenHidden"))]
if shown:
    print("%s: the app shows its own full-screen item %r" % (label, shown)); sys.exit(1)
if len([i for i in mine if i.get("hidden")]) > 1:
    print("%s: more than one hidden full-screen alternate" % label); sys.exit(1)
bar = root.get("displayed")
if not bar:
    print("%s: no displayed menu bar" % label); sys.exit(1)
def tiling_heading(menu, item):
    # Window's tiling group can be a disabled childless heading (its submenu
    # appears only when tiling is available); it is not a second command.
    return (menu == "Window" and not item.get("submenu")
            and item["title"] in ("Full Screen Tile", "Enter Full Screen", "Exit Full Screen")
            and not item["enabled"])

hits = [(m["title"], i) for m in bar for i in walk(m.get("submenu") or [])
        if re.fullmatch(r"(Enter|Exit) Full Screen", i["title"]) and not i.get("submenu")
        and not tiling_heading(m["title"], i)]
if len(hits) > 1:
    print("%s: %d full-screen items on the bar: %r"
          % (label, len(hits), [(m, i["title"]) for m, i in hits]))
    sys.exit(1)
view = next((m for m in bar if m["title"] == "View"), None)
window = next((m for m in bar if m["title"] == "Window"), None)
# The system's tiling group: "Move & Resize ›" always, and "Full Screen Tile"
# (a submenu when tiling is available, a disabled heading otherwise). Some
# macOS 26 builds titled the parent "Enter Full Screen ›".
tiling = [(i["title"], len(i.get("submenu") or [])) for i in (window or {}).get("submenu") or []
          if i["title"] in ("Full Screen Tile", "Enter Full Screen", "Exit Full Screen", "Move & Resize")]
if not any(title == "Move & Resize" for title, _ in tiling) or len(tiling) < 2:
    print("%s: Window lost the system's window group: %r" % (label, tiling)); sys.exit(1)
groups = [t for t in tiling if t[0] != "Move & Resize"]
if not hits:
    if required:
        print("%s: AppKit's View full-screen item is not on the displayed bar" % label); sys.exit(1)
    print("%s: AppKit has not placed its View item in this tier; Window keeps %s"
          % (label, ", ".join(t for t, _ in groups)))
    sys.exit(0)
menu, item = hits[0]
if menu != "View":
    print("%s: the full-screen item is in %s, not View" % (label, menu)); sys.exit(1)
items = (view or {}).get("submenu") or []
visible = [i for i in items if not i["isSeparator"]]
if not visible or visible[-1] is not item:
    print("%s: the full-screen item is not last in View: %r" % (label, [i["title"] for i in items]))
    sys.exit(1)
if item["keyEquivalent"] != "f" or "function" not in item["modifiers"]:
    print("%s: the system item's shortcut is %r %r, wanted fn-F"
          % (label, item["keyEquivalent"], item["modifiers"]))
    sys.exit(1)
print("%s: no app full-screen item; View ends with %s (fn-F, enabled=%s); Window keeps %s"
      % (label, item["title"], item["enabled"], ", ".join(t for t, _ in groups)))
PY
}

# full_screen_item_enabled_ok PATH enabled|disabled LABEL — AppKit reads the key
# window: the Deck and app windows may go full screen, the Phone Mirror opts
# out. An item AppKit has not placed yet is not a failure here (the structural
# check above says whether it must be there).
full_screen_item_enabled_ok() {
    python3 - "$1" "$2" "$3" "${4:-1}" <<'PY'
import json, re, sys
path, want, label, strict = sys.argv[1], sys.argv[2] == "enabled", sys.argv[3], sys.argv[4] != "0"
root = json.load(open(path))
def walk(items):
    for item in items:
        yield item
        if item.get("submenu"):
            yield from walk(item["submenu"])
item = next((i for m in root.get("displayed") or [] for i in walk(m.get("submenu") or [])
             if re.fullmatch(r"(Enter|Exit) Full Screen", i["title"]) and not i.get("submenu")), None)
if item is None:
    print("%s: the system item is not in this tier" % label); sys.exit(0)
if item["enabled"] != want:
    message = ("%s: %s is enabled=%s, wanted %s"
               % (label, item["title"], item["enabled"], "enabled" if want else "disabled"))
    if strict:
        print(message); sys.exit(1)
    print(message + " (quiet tier: the app is not frontmost; not asserted)")
    sys.exit(0)
print("%s: %s enabled=%s" % (label, item["title"], item["enabled"]))
PY
}

# menu_window_rect — the open menu's window bounds as "x,y,w,h" for
# `screencapture -R` (a menu is its own layer-101 window).
menu_window_rect() {
    "$CGBIN" all 2>/dev/null | python3 - <<'PY'
import re, sys
for line in sys.stdin:
    # The open menu is a layer-101 window. Its owner is the app on most
    # builds; a menu drawn in another process still has the same layer.
    if "layer=101" not in line or "owner=Window Server" in line:
        continue
    m = re.search(r"bounds=\{\{(-?[\d.]+), (-?[\d.]+)\}, \{(-?[\d.]+), (-?[\d.]+)\}\}", line)
    if m:
        print(",".join(str(int(float(v))) for v in m.groups()))
        sys.exit(0)
PY
}

# app_menu_rect — this run's open menu window, "x,y,w,h" in Quartz points.
# Filtered to the app's own windows: another app's menu is never ours to read.
app_menu_rect() {
    "$MENUBARBIN" layers "$APP_PID" 2>/dev/null | awk '
        $2 >= 100 && $2 < 1000 && $5 >= 100 && $6 >= 60 { print $3","$4","$5","$6; exit }'
}

# window_rect_at X Y — the app window below a menu that contains that Quartz
# point, "x,y,w,h". The hosted card is the window under its own gear.
window_rect_at() {
    "$MENUBARBIN" layers "$APP_PID" 2>/dev/null | awk -v px="$1" -v py="$2" '
        $2 < 100 && px >= $3 && px <= $3 + $5 && py >= $4 && py <= $4 + $6 {
            print $3","$4","$5","$6; exit
        }'
}

# union_rect A B — the two "x,y,w,h" rects' union, with a 10 pt margin, for a
# screenshot that shows a control and its menu together.
union_rect() {
    python3 - "$1" "$2" <<'PY'
import sys
a = [int(v) for v in sys.argv[1].split(",")]
b = [int(v) for v in sys.argv[2].split(",")]
x = min(a[0], b[0]) - 10
y = min(a[1], b[1]) - 10
right = max(a[0] + a[2], b[0] + b[2]) + 10
bottom = max(a[1] + a[3], b[1] + b[3]) + 10
print(f"{x},{y},{right - x},{bottom - y}")
PY
}

# e2e_menu_shot FILE MENU — hold one of the app's menus open through its
# tracking loop and capture the screen cropped to that menu, then wait for it to
# close. A menu that is gone at the shutter is retried once (round 5's empty
# shots).
e2e_menu_shot() {
    local file="$1" menu="$2" report="$1.json" attempt rect
    for attempt in 1 2; do
        control menutrack "$report" "$menu" 4 >/dev/null \
            || { bad "$menu menutrack: $CONTROL_REPLY"; return 1; }
        sleep 1.6
        rect="$(menu_window_rect)"
        if [ -n "$rect" ]; then
            screencapture -x -R "$rect" "$file" \
                && say "shot: $file (the open $menu menu, $rect)" \
                || bad "no screenshot of the $menu menu"
            wait_until 15 [ -s "$report" ] \
                || { bad "$menu menutrack never reported and closed"; return 1; }
            return 0
        fi
        wait_until 15 [ -s "$report" ] \
            || { bad "$menu menutrack never reported and closed"; return 1; }
        wait_until 10 eval '[ "$(popup_windows)" -eq 0 ]' \
            || { bad "$menu menu was still open before the retry"; return 1; }
        [ "$attempt" = 1 ] && skip "$menu menu shot" "no menu on screen at the shutter; retrying"
    done
    bad "$menu menu shot: no open menu window in two attempts"
    return 1
}

# check_menus — the View menu has no section titles; the app draws no
# full-screen item, and AppKit's own is last in View (fn-F) with the Window
# tiling group left alone; Framed/Immersive are plain radio items; every item
# the app draws itself has an SF Symbol. The whole bar is dumped after each kind
# of rebuild the menu is known to lose items on, the last one with no stream
# window open (where the person's installed app lost them). The window's
# Enter/Exit title needs native full screen (a real Space), so that step is
# visible-only.
check_menus() {
    begin_shared || return 1
    rm -f "$WORK"/menus-*.json "$WORK"/menus-step-* "$WORK/menus.txt" "$WORK/menus-touch.png" "$WORK/chrome.txt"
    # A visible run can require AppKit's View item; a quiet tier may not show
    # it at all, and the structural check says so instead of pretending.
    local fs_required=0
    [ "$VISIBLE" = 1 ] && fs_required=1
    # The review shots (visible VM only; one appearance per boot): the View and
    # Window menus under each kind of key window.
    local appearance="${PD_E2E_SHOT_APPEARANCE:-dark}"
    mkdir -p "$WORK/shots"

    # dump_and_assert N — the dump the control route wrote, checked.
    dump_and_assert() {
        local reason
        wait_until 20 [ -s "$WORK/menus-$1.json" ] || {
            bad "MENUS no dump $1 in 20 s ($WORK/menus-$1.json)"
            say "app log: $(tail -3 "$WORK/app.log")"
            return 1
        }
        if reason="$(menu_dump_ok "$WORK/menus-$1.json")"; then
            ok "[MENU-10] dump $1: the whole bar is the design after the rebuild"
        else
            bad "[MENU-10] dump $1 is not the design: $reason"
        fi
        assert_bar "$WORK/menus-$1.json" "dump $1"
    }

    # assert_bar PATH LABEL — the rules that hold across every menu in the bar
    # as a person reads it (the dump's `displayed` tree, AppKit's own additions
    # included): no title twice, no stray separator, no Apple feedback item.
    # AppKit's window-tiling group headings repeat the name of the item below
    # them (a disabled heading with no action, then the item), so a heading is
    # not a second item.
    assert_bar() {
        local path="$1" label="$2" rule verdict detail
        while IFS='|' read -r rule verdict detail; do
            [ -n "$rule" ] || continue
            case "$verdict" in
                ok) ok "[MENU-11] $label: $rule" ;;
                *) bad "[MENU-11] $label: $rule ($detail)" ;;
            esac
        done < <(python3 - "$path" <<'PY'
import json, re, sys

root = json.load(open(sys.argv[1]))
bar = root.get("displayed")
rules = ["no title appears twice across the bar",
         "no adjacent, leading or trailing separator",
         "no Send … Feedback item in Help"]
if not bar:
    for rule in rules:
        print("|".join([rule, "fail", "the dump has no displayed menu bar"]))
    raise SystemExit

occurrences = []
def walk(menu, items):
    for item in items:
        occurrences.append((menu, items, item))
        if item.get("submenu"):
            walk(menu + "/" + item["title"], item["submenu"])
for menu in bar:
    walk(menu["title"], menu.get("submenu") or [])

def heading(menu, siblings, item):
    return (not item["enabled"] and not item.get("submenu") and not item["keyEquivalent"]
            and any(other is not item and other["title"] == item["title"] for other in siblings))

# AppKit's window-tiling group parent repeats no app item: it is the system's,
# and MENU-11 excepts the group headings. On some macOS 26 builds the group
# is "Full Screen Tile ›"; on others it read "Enter Full Screen ›".
def tiling_group(menu, item):
    return (menu == "Window" and item.get("submenu")
            and item["title"] in ("Full Screen Tile", "Enter Full Screen", "Exit Full Screen"))

# AppKit's window list (Window ▸ after "Bring All to Front") is not the app's
# items: two windows may carry the same title (the Deck names the phone, and so
# does its mirror), and the window server, not this app, decides what to show.
def in_window_list(menu, siblings, item):
    if menu != "Window":
        return False
    titles = [other["title"] for other in siblings]
    if "Bring All to Front" not in titles:
        return False
    index = titles.index("Bring All to Front")
    return siblings.index(item) > index

counts = {}
for menu, siblings, item in occurrences:
    if (item["isSeparator"] or heading(menu, siblings, item) or tiling_group(menu, item)
            or in_window_list(menu, siblings, item)):
        continue
    counts[item["title"]] = counts.get(item["title"], 0) + 1
dups = sorted("%s (%d)" % (title, n) for title, n in counts.items() if n > 1)
print("|".join([rules[0], "fail" if dups else "ok", ", ".join(dups)]))

shape = []
for menu in bar:
    stack = [(menu["title"], menu.get("submenu") or [])]
    while stack:
        name, items = stack.pop()
        seq = ["—" if item["isSeparator"] else item["title"] for item in items]
        if seq and seq[0] == "—":
            shape.append(name + ": leading separator")
        if seq and seq[-1] == "—":
            shape.append(name + ": trailing separator")
        for index in range(1, len(seq)):
            if seq[index] == "—" and seq[index - 1] == "—":
                shape.append("%s: separator %d follows another" % (name, index + 1))
        for item in items:
            if item.get("submenu"):
                stack.append((name + "/" + item["title"], item["submenu"]))
print("|".join([rules[1], "fail" if shape else "ok", "; ".join(shape)]))

feedback = [menu + "/" + item["title"] for menu, _, item in occurrences
            if not item["isSeparator"]
            and (re.match(r"^Send .*Feedback", item["title"]) or "Feedback to Apple" in item["title"])]
print("|".join([rules[2], "fail" if feedback else "ok", ", ".join(feedback)]))
PY
)
    }

    # dump_stable N — the bar as it is now, after AppKit has added its own
    # items: re-dump until two dumps a second apart agree (max 10 s). AppKit
    # adds the View menu's full-screen item and Help's feedback item the first
    # time the bar is read, which is why one dump can catch it mid-build.
    dump_stable() {
        local n="$1" attempt cur prev=""
        for attempt in $(seq 1 10); do
            rm -f "$WORK/menus-$n.json"
            control menudump "$WORK/menus-$n.json" || {
                bad "MENUS menudump $n: $CONTROL_REPLY"
                return 1
            }
            cur="$(python3 - "$WORK/menus-$n.json" <<'PY'
import json, sys
print(json.dumps(json.load(open(sys.argv[1])).get("displayed"), sort_keys=True))
PY
)"
            [ -n "$prev" ] && [ "$cur" = "$prev" ] && return 0
            prev="$cur"
            sleep 1
        done
        bad "MENUS dump $n: the menu bar did not settle in 10 s"
        return 1
    }

    # dump_now N — the bar as it is now: the dump comes from the control route
    # (the app's own menudump), so it is possible at a moment no debug-input
    # script is running, e.g. after the last stream window closed.
    dump_now() {
        dump_stable "$1" && dump_and_assert "$1"
    }

    # One script for the whole check: the picks are the real items (menupick:
    # the item's own target and action), and the markers pace them so the shell
    # can read the bar between them.
    cat > "$WORK/menus.txt" <<EOF
wait 1.5
waitfile $WORK/menus-step-2 60
menupick View/Show Touches
wait 1.2
waitfile $WORK/menus-step-3 60
menupick View/Framed
wait 1.5
waitfile $WORK/menus-step-4 60
menupick View/Immersive
wait 1.5
waitfile $WORK/menus-step-7 60
menupick View/Density/125%
wait 1.2
waitfile $WORK/menus-step-touch 60
showtouches on
wait 1
hover 0.5 0.5
wait 0.3
fingerpinch 0.5 0.01 1.25 4
wait 1
waitfile $WORK/menus-step-framed 60
key opt+cmd+f
wait 1.5
waitfile $WORK/menus-step-full 60
fullscreen
wait 6
waitfile $WORK/menus-step-exit 60
fullscreen
wait 6
EOF
    # 0: no stream window is open — only the Deck is there, and it is key.
    # The View menu's style pair acts on the key stream window, so neither item
    # may be checked or enabled; the Window menu lists the open window the
    # standard way, with no empty row under "Bring All to Front".
    dump_stable 0 || { stop_app; stop_fakephone; return 1; }
    assert_bar "$WORK/menus-0.json" "dump 0"
    if reason="$(full_screen_bar_ok "$WORK/menus-0.json" "dump 0" "$fs_required")"; then
        ok "[MENU-7] $reason"
    else
        bad "[MENU-7] dump 0: $reason"
    fi
    if reason="$(full_screen_item_enabled_ok "$WORK/menus-0.json" enabled "dump 0 (the Deck can go full screen)" "$fs_required")"; then
        say "[MENU-7] $reason"
    else
        bad "[MENU-7] dump 0: $reason"
    fi
    python3 - "$WORK/menus-0.json" <<'PY' && ok "[MENU-9] with no stream window: Framed/Immersive are disabled and neither is checked" \
        || bad "[MENU-9] the style pair still acts with no stream window"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
pair = [by_title.get("Framed"), by_title.get("Immersive")]
if None in pair:
    print("the style pair is missing"); sys.exit(1)
if [item["state"] for item in pair] != ["off", "off"]:
    print("states:", [item["state"] for item in pair]); sys.exit(1)
if [item["enabled"] for item in pair] != [False, False]:
    print("enabled:", [item["enabled"] for item in pair]); sys.exit(1)
PY
    local ax_titles
    ax_titles="$(window_titles "$APP_PID")"
    python3 - "$WORK/menus-0.json" "$ax_titles" <<'PY' && ok "[MENU-7] the Window menu lists the open windows and has no empty or hidden item" \
        || bad "[MENU-7] the Window menu has an empty row or no window list"
import json, sys
root = json.load(open(sys.argv[1]))
def window_menu(items):
    return next((i for i in items if i["title"] == "Window"), None)
def problems(items, path):
    out = []
    for item in items:
        if item["hidden"]:
            out.append("%s: hidden %r" % (path, item["title"]))
        if not item["isSeparator"] and not item["title"].strip():
            out.append("%s: empty item" % path)
    return out
found = []
for tree in ("items", "displayed"):
    menu = window_menu(root.get(tree) or [])
    if menu is None:
        found.append("%s: no Window menu" % tree)
        continue
    found += problems(menu.get("submenu") or [], tree + "/Window")
window = window_menu(root["items"])
items = (window.get("submenu") if window else []) or []
titles = [i["title"] for i in items]
if "Bring All to Front" not in titles:
    found.append("no Bring All to Front")
else:
    # AppKit's own list: the items after "Bring All to Front" that open a
    # window (the window list's entries target their NSWindow).
    listed = sorted(i["title"] for i in items[titles.index("Bring All to Front") + 1:]
                    if not i["isSeparator"] and (i.get("targetClass") or "").endswith("Window"))
    # An untitled window (the status item's) is not a window a person reaches
    # from the menu, and AppKit does not list it.
    open_titles = sorted(t for t in sys.argv[2].splitlines() if t.strip() and t.strip() != "-")
    if listed != open_titles:
        found.append("window list %r, open windows %r" % (listed, open_titles))
if found:
    print("; ".join(found)); sys.exit(1)
PY

    open_shared --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
        --debug-input-script "$WORK/menus.txt" || return 1
    # The Deck's icon size is a stored choice: start from 100 %, so the View
    # menu's checkmark is the known one (DECK-6, MENU-9).
    control deckzoom 1 >/dev/null || bad "MENUS deckzoom 1: $CONTROL_REPLY"
    sleep 0.5

    # 1: a fresh launch with one stream window open.
    dump_now 1 || { stop_app; stop_fakephone; return 1; }
    if reason="$(full_screen_item_enabled_ok "$WORK/menus-1.json" enabled "dump 1 (an app window can go full screen)" "$fs_required")"; then
        say "[MENU-7] $reason"
    else
        bad "[MENU-7] dump 1: $reason"
    fi
    if [ "$VISIBLE" = 1 ]; then
        control activate || bad "MENUS activate for the stream shots: $CONTROL_REPLY"
        sleep 1
        e2e_menu_shot "$WORK/shots/$appearance-view-stream.png" View
        e2e_menu_shot "$WORK/shots/$appearance-window-stream.png" Window
    else
        skip "MENUS the View and Window shots with an app window key" "visible VM run only"
    fi

    # The status item's own menu (CONV-MAC-10): the three app commands the
    # panel's footer used to carry. The dump is the builder's own item list, so
    # a quiet run reads the menu a person gets without popping it on screen.
    rm -f "$WORK/menus-icon.json"
    control iconmenu "$WORK/menus-icon.json" \
        || bad "MENUS iconmenu: $CONTROL_REPLY"
    python3 - "$WORK/menus-icon.json" <<'PY' && ok "[CONV-MAC-10] [PANEL-3] the icon's menu is Settings… ⌘, · About Contigua · rule · Quit Contigua ⌘Q" \
        || bad "[PANEL-3] the icon's menu is not Settings…/About/Quit"
import json, sys
rows = json.load(open(sys.argv[1]))
titles = [row["title"] for row in rows]
if titles != ["Settings…", "About Contigua", "-", "Quit Contigua"]:
    print("titles:", titles); sys.exit(1)
keys = [row["key"] for row in rows]
if keys != [",", "", "", "q"]:
    print("keys:", keys); sys.exit(1)
if [row["separator"] for row in rows] != [False, False, True, False]:
    print("separators:", rows); sys.exit(1)
if not all(row["command"] for row in rows if not row["separator"] and row["key"]):
    print("keys are not ⌘ shortcuts:", rows); sys.exit(1)
PY
    # 2: after View ▸ Show Touches was toggled (the commands read its state).
    touch "$WORK/menus-step-2"; sleep 1.5; dump_now 2
    # 3 and 4: after switching the style to Framed and back to Immersive.
    touch "$WORK/menus-step-3"; sleep 1.5
    wait_until 5 grep -q "style=framed" "$WORK/chrome.txt" \
        && ok "[MENU-4] choosing Framed took the window to the framed style" \
        || bad "[MENU-4] choosing Framed left $(grep -o 'style=[a-z]*' "$WORK/chrome.txt" | tail -1)"
    dump_now 3
    # The pair's mark and Hide Controls' enablement follow the key window: the
    # items are SwiftUI's (a rebuild cannot drop them), and MenuMarks writes
    # their values when the menu opens.
    python3 - "$WORK/menus-3.json" <<'PY' && ok "[MENU-9] after choosing Framed: it is checked and Hide Controls is enabled" \
        || bad "[MENU-9] the View menu did not follow the style change"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
if by_title["Framed"]["state"] != "on" or by_title["Immersive"]["state"] != "off":
    print("states:", by_title["Framed"]["state"], by_title["Immersive"]["state"]); sys.exit(1)
hide = by_title.get("Hide Controls")
if hide is None or not hide.get("enabled"):
    print("Hide Controls:", hide); sys.exit(1)
PY
    touch "$WORK/menus-step-4"; sleep 1.5; dump_now 4
    python3 - "$WORK/menus-4.json" <<'PY' && ok "[MENU-9] back on Immersive: it is checked and Hide Controls stays enabled (a key stream window)" \
        || bad "[MENU-9] the View menu did not follow the style back"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
if by_title["Framed"]["state"] != "off" or by_title["Immersive"]["state"] != "on":
    print("states:", by_title["Framed"]["state"], by_title["Immersive"]["state"]); sys.exit(1)
hide = by_title.get("Hide Controls")
if hide is None or not hide.get("enabled"):
    print("Hide Controls:", hide); sys.exit(1)
PY
    # The Deck's icon size is a stored choice: its checkmark follows ⌘+ / ⌘−
    # while the Deck is key (DECK-6, MENU-9). This is the store the keys write;
    # the menu reads it when it opens.
    control deckzoom 1.25 >/dev/null || bad "MENUS deckzoom 1.25: $CONTROL_REPLY"
    sleep 0.5; dump_now 16
    python3 - "$WORK/menus-16.json" <<'PY' && ok "[MENU-9] after the icon size became 125 %: 125 % is checked and 100 % is not" \
        || bad "[MENU-9] the View menu did not follow the icon size"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
icon = next(i for i in view["submenu"] if i["title"] == "Icon Size")
by_title = {i["title"]: i for i in icon["submenu"] if not i["isSeparator"]}
if by_title["125 %"]["state"] != "on" or by_title["100 %"]["state"] != "off":
    print("states:", {k: v["state"] for k, v in by_title.items()}); sys.exit(1)
PY
    control deckzoom 1 >/dev/null || bad "MENUS deckzoom 1 (restore): $CONTROL_REPLY"
    sleep 0.5

    # 5: after a second stream window opened (a different key window).
    control open --open com.whatsapp --debug-chrome-state "$WORK/chrome.txt" \
        || bad "MENUS shared app: opening a second window answered '$CONTROL_REPLY'"
    sleep 1.5; dump_now 5
    # 6: after it closed and the first window is key again.
    control open --close-stream 2:0 --debug-chrome-state "$WORK/chrome.txt" \
        || bad "MENUS shared app: closing the second window answered '$CONTROL_REPLY'"
    sleep 1.5; dump_now 6
    # 7: after a Density pick rebuilt the submenu.
    touch "$WORK/menus-step-7"; sleep 1.5; dump_now 7
    # 8 and 9: after the key window changed to the phone window and back.
    control open --open-phone --debug-chrome-state "$WORK/chrome.txt" \
        || bad "MENUS shared app: opening the phone window answered '$CONTROL_REPLY'"
    sleep 1.5; dump_now 8
    if reason="$(full_screen_item_enabled_ok "$WORK/menus-8.json" disabled "dump 8 (the Phone Mirror opts out)" "$fs_required")"; then
        ok "[MENU-7] $reason"
    else
        bad "[MENU-7] dump 8: $reason"
    fi
    if [ "$VISIBLE" = 1 ]; then
        control activate || bad "MENUS activate for the phone shots: $CONTROL_REPLY"
        sleep 1
        e2e_menu_shot "$WORK/shots/$appearance-view-phone.png" View
        e2e_menu_shot "$WORK/shots/$appearance-window-phone.png" Window
    else
        skip "MENUS the View and Window shots with the Phone Mirror key" "visible VM run only"
    fi
    control open --close-stream 3:0 --debug-chrome-state "$WORK/chrome.txt" \
        || bad "MENUS shared app: closing the phone window answered '$CONTROL_REPLY'"
    sleep 1.5; dump_now 9
    if reason="$(full_screen_item_enabled_ok "$WORK/menus-9.json" enabled "dump 9 (an app window is key again)" "$fs_required")"; then
        ok "[MENU-7] $reason"
    else
        bad "[MENU-7] dump 9: $reason"
    fi

    # 14 and 15: the menu-bar extra scene goes away and comes back. The app's
    # body reads that setting, so SwiftUI re-evaluates the whole scene graph —
    # commands included — and rebuilds the main menu. That is the real rebuild a
    # quiet run can force (it cannot activate the app, the other way in), and it
    # is where the person's installed app lost the items while the two dividers
    # around them met.
    defaults write "$DEFAULTS_SUITE" showMenuBar -bool false
    sleep 2; dump_now 14
    defaults write "$DEFAULTS_SUITE" showMenuBar -bool true
    sleep 2; dump_now 15

    # The View menu, top to bottom: the design's items, nothing else — no
    # section title (the old Picker's "Window Style" header) and no full-screen
    # item. Separators are shown as —.
    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-4] View menu is exactly the design's items, no section titles" \
        || bad "[MENU-4] View menu is not the design"
import json, sys
root = json.load(open(sys.argv[1]))
view = next((i for i in root["items"] if i["title"] == "View"), None)
if view is None:
    print("no View menu"); sys.exit(1)
titles = [item["title"] for item in view["submenu"]]
if "Window Style" in titles:
    print("the Window Style section title is still there"); sys.exit(1)
# AppKit's own Enter Full Screen (fn-F) is the one full-screen item allowed in
# View; an app item would carry ⌃⌘F (MENU-4, MENU-7).
mine = [i["title"] for i in view["submenu"]
        if "Full Screen" in i["title"] and "control" in i["modifiers"]
        and not (i.get("hidden") and i.get("allowsKeyWhenHidden"))]
if mine:
    print("an app full-screen item is shown in View:", mine); sys.exit(1)
PY

    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-4] Framed/Immersive are radio items with exactly one checked, and ⌥⌘F is on the pair" \
        || bad "[MENU-4] the style radios are wrong"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
framed, immersive = by_title.get("Framed"), by_title.get("Immersive")
if not framed or not immersive:
    print("Framed/Immersive missing"); sys.exit(1)
if sorted([framed["state"], immersive["state"]]) != ["off", "on"]:
    print("states:", framed["state"], immersive["state"]); sys.exit(1)
if not (framed["enabled"] and immersive["enabled"]):
    print("the pair is disabled with a stream window key"); sys.exit(1)
if framed["hasImage"] or immersive["hasImage"]:
    print("a radio item carries an icon"); sys.exit(1)
# A choice cannot also be a submenu's parent: both are plain items.
if framed.get("submenu"):
    print("Framed has a submenu"); sys.exit(1)
if immersive.get("submenu"):
    print("Immersive has a submenu"); sys.exit(1)
# ⌥⌘F belongs to the pair, and the old separate toggle is gone.
shortcuts = [(i["title"], i["keyEquivalent"], i["modifiers"]) for i in (framed, immersive)
             if i["keyEquivalent"] == "f"]
if shortcuts != [("Framed", "f", ["command", "option"])] and shortcuts != [("Immersive", "f", ["command", "option"])]:
    print("⌥⌘F on the pair:", shortcuts); sys.exit(1)
if "Toggle Window Style" in by_title:
    print("the separate Toggle Window Style item is still there"); sys.exit(1)
PY

    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-4] Icon Size is the four percentages, the stored one checked" \
        || bad "[MENU-4] the Icon Size submenu is wrong"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
icon = next(i for i in view["submenu"] if i["title"] == "Icon Size")
sub = icon.get("submenu") or []
seq = ["—" if i["isSeparator"] else i["title"] for i in sub]
want = ["75 %", "100 %", "125 %", "150 %"]
if seq != want:
    print("Icon Size:", seq, "wanted:", want); sys.exit(1)
checked = [i["title"] for i in sub if not i["isSeparator"] and i["state"] == "on"]
if checked != ["100 %"]:
    print("checked:", checked); sys.exit(1)
if any(i["keyEquivalent"] for i in sub if not i["isSeparator"]):
    print("an Icon Size item carries a key: the keys stay on Density", sub); sys.exit(1)
if not icon["hasImage"]:
    print("Icon Size has no symbol"); sys.exit(1)
PY

    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-4] Density is Default (N%), the other percentages, then Larger/Smaller/Actual Size" \
        || bad "[MENU-4] the Density submenu is wrong"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
density = next(i for i in view["submenu"] if i["title"] == "Density")
seq = ["—" if i["isSeparator"] else i["title"] for i in density.get("submenu") or []]
want = ["Default (100%)", "—", "75%", "125%", "150%", "—", "Larger", "Smaller", "Actual Size"]
if seq != want:
    print("Density:", seq, "wanted:", want); sys.exit(1)
by_title = {i["title"]: i for i in density["submenu"] if not i["isSeparator"]}
for title, key in [("Larger", "+"), ("Smaller", "-"), ("Actual Size", "0")]:
    item = by_title[title]
    if item["keyEquivalent"] != key or item["modifiers"] != ["command"]:
        print(title, "shortcut:", repr(item["keyEquivalent"]), item["modifiers"]); sys.exit(1)
if by_title["Default (100%)"]["state"] != "on":
    print("Default is not checked with no override:", by_title["Default (100%)"]["state"]); sys.exit(1)
PY

    # The menu is read as a person sees it (the dump's displayed tree), which
    # makes SwiftUI re-evaluate the commands: with the fake phone online, the
    # controls that can work are enabled, and the one that cannot — Turn Off
    # Phone Screen, with no phone window — stays disabled.
    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-5] the Phone menu: ⌘P/⇧⌘C, its controls enabled for the online phone, Turn Off Phone Screen disabled" \
        || bad "[MENU-5] a Phone control that cannot work is enabled"
import json, sys
root = json.load(open(sys.argv[1]))
phone = next(i for i in root["items"] if i["title"] == "Phone")
by_title = {i["title"]: i for i in phone["submenu"] if not i["isSeparator"]}
if by_title["Phone Mirror"]["keyEquivalent"] != "p" or by_title["Phone Mirror"]["modifiers"] != ["command"]:
    print("Phone Mirror shortcut:", repr(by_title["Phone Mirror"]["keyEquivalent"]),
          by_title["Phone Mirror"]["modifiers"]); sys.exit(1)
handoff = next((i for i in phone["submenu"]
                 if i["keyEquivalent"] == "c" and "shift" in i["modifiers"]), None)
if handoff is None:
    print("no ⇧⌘C handoff item:", [i["title"] for i in phone["submenu"]]); sys.exit(1)
if not (handoff["title"].startswith("Open ") and handoff["title"].endswith(" on Mac")):
    print("handoff title:", handoff["title"]); sys.exit(1)
if by_title["Turn Off Phone Screen"]["enabled"]:
    print("Turn Off Phone Screen is enabled with no phone window"); sys.exit(1)
for title in ("Phone Mirror", "Do Not Disturb", "Ring Phone", "Install APK…"):
    if not by_title[title]["enabled"]:
        print(title, "is disabled while the phone is online"); sys.exit(1)
if not handoff["enabled"]:
    print("the handoff item is disabled while the phone is online"); sys.exit(1)
PY

    # The temporary Bar Prototype picker is gone: the bar has one geometry
    # (BarGeometry) and no menu item to choose another.
    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-4] no Bar Prototype item (one bar geometry)" \
        || bad "[MENU-4] a Bar Prototype item is still in View"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
if any(i["title"] == "Bar Prototype" for i in view["submenu"]):
    print("Bar Prototype is still there"); sys.exit(1)
PY

    # Immersive is a plain radio item (no submenu); the reveal choice lives in
    # Hide Controls and follows the key stream window in either style.
    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-4] Hide Controls holds the delays and is enabled while Framed" \
        || bad "[MENU-4] Hide Controls is wrong while framed"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
imm = next(i for i in view["submenu"] if i["title"] == "Immersive")
if imm.get("submenu"):
    print("Immersive has a submenu"); sys.exit(1)
hide = next(i for i in view["submenu"] if i["title"] == "Hide Controls")
sub = hide.get("submenu") or []
seq = ["—" if item["isSeparator"] else item["title"] for item in sub]
want = ["Instantly", "Short", "Long", "—", "Always Visible"]
if seq != want:
    print("Hide Controls:", seq, "wanted:", want); sys.exit(1)
checked = [item["title"] for item in sub if item["state"] == "on"]
if checked != ["Short"]:
    print("checked:", checked); sys.exit(1)
if not hide.get("enabled"):
    print("Hide Controls is disabled"); sys.exit(1)
PY

    # The bar's full-screen structure on the bar a person reads: no app item,
    # AppKit's own last in View with fn-F, Window's tiling group untouched.
    # A visible run requires AppKit's item; a quiet tier may not show it.
    if reason="$(full_screen_bar_ok "$WORK/menus-1.json" "dump 1" "$fs_required")"; then
        ok "[MENU-7] $reason"
    else
        bad "[MENU-7] dump 1: $reason"
    fi
    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-8] ⌃⌘F is a hidden View item that keeps its key; AppKit's fn-F item stays visible and untouched" \
        || bad "[MENU-8] the ⌃⌘F alternate is missing, shown, or lost its key"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
app = [i for i in view["submenu"]
       if i["title"] == "Enter Full Screen" and "control" in i["modifiers"]]
if len(app) != 1:
    print("⌃⌘F items in View:", app); sys.exit(1)
item = app[0]
if not item.get("hidden") or not item.get("allowsKeyWhenHidden"):
    print("hidden/allowsKeyWhenHidden:", item.get("hidden"), item.get("allowsKeyWhenHidden")); sys.exit(1)
if item["keyEquivalent"] != "f" or sorted(item["modifiers"]) != ["command", "control"]:
    print("shortcut:", repr(item["keyEquivalent"]), item["modifiers"]); sys.exit(1)
system = [i for i in view["submenu"]
          if i["title"] == "Enter Full Screen" and "control" not in i["modifiers"]]
if any(i.get("hidden") for i in system):
    print("the system's fn-F item was hidden"); sys.exit(1)
PY

    # The app's own items carry SF Symbols (the system's items stay as AppKit
    # draws them and are not in this list).
    python3 - "$WORK/menus-1.json" <<'PY' && ok "[MENU-1] every item the app draws has an SF Symbol" \
        || bad "[MENU-1] an app item is missing its icon"
import json, sys
def walk(items):
    for item in items:
        yield item
        if item.get("submenu"):
            yield from walk(item["submenu"])
root = json.load(open(sys.argv[1]))
items = list(walk(root["items"]))
missing = []
for title in ["Add Phone…", "Find Apps", "Phone Mirror", "Open Current App on Mac", "Show Touches",
              "Live Text", "Icon Size", "Density", "Larger", "Smaller", "Actual Size", "Back",
              "Home", "Recents"]:
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
        && ok "[MENU-4] the Show Touches dots are outside the bar's mirror ($(chrome_state))" \
        || bad "[MENU-4] the dot layer is still inside the mirrored content: $(chrome_state)"

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
    wait_until 5 eval 'grep -q "touches=on" "$WORK/chrome.txt" && grep -qE "dot_count=[1-9]" "$WORK/chrome.txt"' \
        && ok "[MENU-4] the dots are drawn while the fingers are down ($(chrome_state))" \
        || bad "[MENU-4] no touch dots during the pinch: $(chrome_state)"
    # The style pick waits until the dots' shot is taken: Framed draws no dots.
    touch "$WORK/menus-step-framed"
    sleep 4

    # The menu bar is a window panel now (docs/design/mac-redesign.md §3.8):
    # the phone card, not the old status line and its "Open Contigua"/"Phone
    # screen" items.
    control panelopen || bad "MENUS panelopen: $CONTROL_REPLY"
    control paneldump panel "$WORK/menus-panel.json" || bad "MENUS paneldump: $CONTROL_REPLY"
    python3 - "$WORK/menus-panel.json" <<'PY' && ok "[PANEL-5] the menu bar hosts the phone panel, none of the old menu items" \
        || bad "[PANEL-5] the menu bar is not the panel"
import json, sys
root = json.load(open(sys.argv[1]))
if root["width"] != 300:
    print("width:", root["width"]); sys.exit(1)
kinds = [row["kind"] for row in root["items"]]
for kind in ["gear", "volume", "dnd", "ringer", "ring", "screen", "phoneScreen", "findApps"]:
    if kind not in kinds:
        print("missing", kind, kinds); sys.exit(1)
if "installApk" in kinds:
    print("Install APK… is a card row again:", kinds); sys.exit(1)
# The handoff row is the card's own (PANEL-28): it names the app the phone last
# reported in front, and the card asks task.front when it opens. It is not one
# of the old status-line items, so it belongs here.
for row in root["items"]:
    if row["kind"] == "continueOnMac" and not row["label"].startswith("Open "):
        print("handoff row:", row); sys.exit(1)
for footed in ["settings", "quit"]:
    if footed in kinds:
        print(footed, "is a row; it belongs to the icon's menu", kinds); sys.exit(1)
if kinds.index("volume") > kinds.index("dnd"):
    print("Sound is not above the modules:", kinds); sys.exit(1)
if kinds.index("dnd") > kinds.index("ringer") or kinds.index("ringer") > kinds.index("ring"):
    print("modules out of order:", kinds); sys.exit(1)
focus = next(row["label"] for row in root["items"] if row["kind"] == "dnd")
if focus != "Focus":
    print("the Focus module is named", repr(focus)); sys.exit(1)
labels = [row["label"] for row in root["items"]]
for gone in ["Open Contigua", "Phone screen"]:
    if gone in labels:
        print("the old menu item survived:", gone); sys.exit(1)
if len(root["controls"]) < 6:
    print("controls:", len(root["controls"])); sys.exit(1)
PY
    control panelclose || bad "MENUS panelclose: $CONTROL_REPLY"

    if [ "$VISIBLE" = "1" ]; then
        # The pair's marks were asserted in the shared block above, which this
        # run executes too; this block adds what needs a real Space and real
        # input. The app must be front for a real key to reach its menu
        # equivalents (setup); the keys are then pressed through cgevent with
        # an app window key, both ways.
        control activate || bad "MENUS activate: $CONTROL_REPLY"
        sleep 1
        if cg_input key --keycode 3 --ctrl --cmd; then
            wait_until 20 chrome_has "fullscreen=yes" \
                && ok "[MENU-4] ⌃⌘F entered full screen with an app window key ($(chrome_state))" \
                || bad "[MENU-4] ⌃⌘F did not enter full screen: $(chrome_state)"
            cg_input key --keycode 3 --ctrl --cmd \
                || bad "MENUS the second ⌃⌘F press did not post"
            wait_until 20 chrome_has "fullscreen=no" \
                && ok "[MENU-4] ⌃⌘F left full screen again" \
                || bad "[MENU-4] ⌃⌘F did not leave full screen: $(chrome_state)"
        else
            bad "MENUS the ⌃⌘F press did not post"
        fi
        if cg_input key --keycode 3 --fn; then
            wait_until 20 chrome_has "fullscreen=yes" \
                && ok "[MENU-4] fn-F entered full screen with an app window key" \
                || bad "[MENU-4] fn-F did not enter full screen: $(chrome_state)"
            cg_input key --keycode 3 --fn || bad "MENUS the second fn-F press did not post"
            wait_until 20 chrome_has "fullscreen=no" \
                && ok "[MENU-4] fn-F left full screen again" \
                || bad "[MENU-4] fn-F did not leave full screen: $(chrome_state)"
        else
            bad "MENUS the fn-F press did not post"
        fi
        touch "$WORK/menus-step-full"
        sleep 7
        # The title can only follow the window if the window went to a Space.
        chrome_has "fullscreen=yes" \
            && ok "[MENU-7] the shared app entered a Space (fullscreen=yes)" \
            || bad "[MENU-7] the shared app did not enter full screen: $(chrome_state)"
        dump_now 10
        if reason="$(full_screen_bar_ok "$WORK/menus-10.json" "dump 10 (in full screen)" 1)"; then
            case "$reason" in
                *"Exit Full Screen"*) ok "[MENU-7] $reason" ;;
                *) bad "[MENU-7] in full screen the system item did not read Exit Full Screen: $reason" ;;
            esac
        else
            bad "[MENU-7] dump 10: $reason"
        fi
        # Leave full screen; the next checks share this app.
        touch "$WORK/menus-step-exit"
        sleep 7

        # 12: the last stream window closed, no window can put the items back.
        # The person's installed app lost them exactly here (the two dividers
        # around them met). A quiet run cannot do this step: the app stops
        # answering its control channel once its last window is gone.
        control open --close-stream 1:0 --debug-chrome-state "$WORK/chrome.txt" \
            || bad "MENUS shared app: closing the last stream window answered '$CONTROL_REPLY'"
        sleep 1.5; dump_now 12
        if reason="$(full_screen_bar_ok "$WORK/menus-12.json" "dump 12 (the Deck is key)" 1)"; then
            ok "[MENU-7] $reason"
        else
            bad "[MENU-7] dump 12: $reason"
        fi
        if reason="$(full_screen_item_enabled_ok "$WORK/menus-12.json" enabled "dump 12 (the Deck can go full screen)" 1)"; then
            ok "[MENU-7] $reason"
        else
            bad "[MENU-7] dump 12: $reason"
        fi
        # The Deck is the window a person reads these menus over; the app must
        # be front and the Deck visible after the last stream window closed.
        control deckfocus grid || bad "MENUS deckfocus for the Deck shots: $CONTROL_REPLY"
        sleep 1
        e2e_menu_shot "$WORK/shots/$appearance-view-deck.png" View
        e2e_menu_shot "$WORK/shots/$appearance-window-deck.png" Window
        # 13: a stream window open again.
        control open --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
            || bad "MENUS shared app: reopening a stream window answered '$CONTROL_REPLY'"
        sleep 2; dump_now 13
    else
        skip_visible "MENUS the full-screen key presses and the Exit Full Screen title (a real Space)"
        skip_visible "MENUS the bar and the View/Window shots with the Deck key (a quiet app stops answering then)"
    fi

    # A menu held open for 5 s while the state under it changes (MENU-17): the
    # person's 10-27 report was a submenu that kept appearing and disappearing
    # while they hovered it. A battery report, a Now Playing change and an
    # occlusion flip are not values the menu shows, so nothing may rebuild its
    # items — a rebuild closes the menu under the pointer.
    rm -f "$WORK/menus-track.json"
    control menutrack "$WORK/menus-track.json" "View/Density" 5 \
        || bad "MENUS menutrack: $CONTROL_REPLY"
    control menu-burst on || bad "MENUS menu-burst on: $CONTROL_REPLY"
    wait_until 25 [ -s "$WORK/menus-track.json" ] \
        || bad "MENUS no tracked-menu report in 25 s (the menu never closed)"
    control menu-burst off >/dev/null 2>&1
    python3 - "$WORK/menus-track.json" <<'PY' && ok "[MENU-17] a menu open for 5 s: 12 state changes, no rebuild, its items and submenu are the same objects, it stayed open" \
        || bad "[MENU-17] the open menu was rebuilt or closed under the pointer"
import json, sys

report = json.load(open(sys.argv[1]))
problems = []
if not report.get("opened"):
    problems.append("the menu never opened")
if report.get("state_changes", 0) < 10:
    problems.append("%d state changes while it was open" % report.get("state_changes", 0))
if report.get("builds_during", 0) != 0:
    problems.append("%d rebuilds while it tracked" % report["builds_during"])
if report.get("items_changed"):
    problems.append("its items were replaced (%d -> %d)" % (report["item_count_before"], report["item_count_after"]))
if not report.get("submenu_same_object"):
    problems.append("the submenu object changed")
if not report.get("submenu_opened"):
    problems.append("the submenu never opened")
if not any(path.startswith("View/Density") for path in report.get("tracking_at_end") or []):
    problems.append("it was not still open at the end: %r" % (report.get("tracking_at_end"),))
print("; ".join(problems))
sys.exit(1 if problems else 0)
PY

    # The same 10 s cap closes it (cancelTracking). The report is written while
    # the menu is still open (that is what `tracking_at_end` measures), so a
    # popup left on screen here is the round-3 wedge: the next step's menu
    # would be refused as "a menu track is already running".
    wait_until 10 eval '[ "$(popup_windows)" -eq 0 ]' \
        && ok "[MENU-17] the tracked menu closed by its own cap" \
        || { bad "[MENU-17] the menu the check opened was still tracking after its cap"
             "$CGBIN" all 2>/dev/null | awk '$0 ~ /layer=[0-9]+/ { for (i = 1; i <= NF; i++) if ($i ~ /^layer=/) { split($i, p, "="); if (p[2] >= 100) print "  popup: " $0 } }'; }


    # ISS-93: the values a person reads come from a menu that is really
    # tracking. `menudump`'s route writes the marks itself before it reads
    # them, so it passed while a real open showed the launch values; this
    # reads the items mid-track, after AppKit's own tracking loop has begun.
    view_marks() {  # FILE SCENE
        python3 - "$1" "$2" <<'PY'
import json, sys

report = json.load(open(sys.argv[1]))
scene = sys.argv[2]
marks = report.get("marks") or []
rows = {}
for row in marks:
    if not row["separator"]:
        rows.setdefault(row["title"], []).append(row)
problems = []

def one(title):
    found = rows.get(title) or []
    if len(found) != 1:
        problems.append("%s: %d rows" % (title, len(found)))
        return {}
    return found[0]

for title in ("Framed", "Immersive"):
    item = one(title)
    wanted = "on" if scene == "stream-framed" and title == "Framed" else "off"
    if item.get("state") != wanted:
        problems.append("%s checked %r" % (title, item.get("state")))
    wanted_enabled = scene == "stream-framed"
    if bool(item.get("enabled")) != wanted_enabled:
        problems.append("%s enabled %r" % (title, item.get("enabled")))
for title in ("Hide Controls", "Density"):
    item = one(title)
    # Hide Controls follows a key stream window in either style (ISS-45);
    # Density needs an app window, which this scene has.
    wanted = scene == "stream-framed"
    if bool(item.get("enabled")) != wanted:
        problems.append("%s enabled %r" % (title, item.get("enabled")))
for title in ("Show Touches", "Live Text"):
    item = one(title)
    wanted_enabled = scene == "stream-framed"
    if bool(item.get("enabled")) != wanted_enabled:
        problems.append("%s enabled %r" % (title, item.get("enabled")))
    if item.get("state") != ("on" if wanted_enabled and title == "Show Touches" else "off"):
        problems.append("%s checked %r" % (title, item.get("state")))
visible = [row for row in marks
           if row["title"] == "Enter Full Screen" and not row["hidden"]]
if len(visible) != 1:
    problems.append("%d visible Enter Full Screen items" % len(visible))
icon = one("Icon Size")
children = {row["title"]: row for row in icon.get("children") or [] if not row["separator"]}
if scene in ("deck", "icon-100"):
    wanted, other = "100 %", "75 %"
elif scene == "icon-75":
    wanted, other = "75 %", "100 %"
else:
    wanted = other = None
if wanted:
    if children.get(wanted, {}).get("state") != "on":
        problems.append("%s checked %r" % (wanted, children.get(wanted, {}).get("state")))
    if children.get(other, {}).get("state") != "off":
        problems.append("%s still checked %r" % (other, children.get(other, {}).get("state")))
if problems:
    print("; ".join(problems))
sys.exit(1 if problems else 0)
PY
    }
    tracked_view() {  # FILE
        rm -f "$1"
        control menutrack "$1" View 3 || bad "MENUS menutrack View: $CONTROL_REPLY"
        wait_until 20 [ -s "$1" ] || bad "MENUS no tracked View report in 20 s"
    }
    # ISS-88: the Deck key with a stream window still open behind it. The
    # stream window is framed with Show Touches on (the script above set both);
    # with a non-stream window key, none of the stream-only View items may stay
    # checked or enabled, and the keys that carry them must not run on the
    # hidden window or leak into the Deck's search field. `deckfocus` makes the
    # Deck key the way a click does (the Deck's own makeKey).
    dump_now 17
    python3 - "$WORK/menus-17.json" <<'PY' && ok "MENUS setup: the stream window is key, framed, with Show Touches on" \
        || bad "MENUS setup: the stream window is not key/framed with Show Touches on"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
if by_title["Framed"]["state"] != "on" or not by_title["Framed"]["enabled"]:
    print("Framed:", by_title["Framed"]); sys.exit(1)
if by_title["Show Touches"]["state"] != "on" or not by_title["Show Touches"]["enabled"]:
    print("Show Touches:", by_title["Show Touches"]); sys.exit(1)
PY
    tracked_view "$WORK/menus-viewtrack-stream.json"
    view_marks "$WORK/menus-viewtrack-stream.json" stream-framed \
        && ok "[MENU-9] with a framed stream window key, read while View tracks: Framed checked, the pair, Show Touches and Density enabled, Live Text unchecked, one Enter Full Screen" \
        || bad "[MENU-9] a real View open does not follow the key stream window"
    control deckfocus grid || bad "MENUS deckfocus grid (the Deck key): $CONTROL_REPLY"
    sleep 1
    dump_stable 18 || { stop_app; stop_fakephone; return 1; }
    assert_bar "$WORK/menus-18.json" "dump 18"
    python3 - "$WORK/menus-18.json" <<'PY' && ok "[MENU-9] the Deck key with a stream window open behind it: Framed/Immersive, Hide Controls, Show Touches, Live Text and Density are off and disabled" \
        || bad "[MENU-9] the Deck key left a stream-only View item checked or enabled"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
problems = []
for title in ("Framed", "Immersive"):
    item = by_title.get(title)
    if item is None or item["state"] != "off" or item["enabled"]:
        problems.append("%s: %r" % (title, item))
for title in ("Hide Controls", "Show Touches", "Live Text", "Density"):
    item = by_title.get(title)
    if item is None or item["enabled"]:
        problems.append("%s enabled: %r" % (title, item))
for title in ("Show Touches", "Live Text"):
    item = by_title.get(title)
    if item is None or item["state"] != "off":
        problems.append("%s checked: %r" % (title, item))
if problems:
    print("; ".join(problems)); sys.exit(1)
PY
    python3 - "$WORK/menus-18.json" <<'PY' && ok "[MENU-6] the Deck key disables Navigate's three stream items" \
        || bad "[MENU-6] a Navigate item stays enabled with the Deck key"
import json, sys
root = json.load(open(sys.argv[1]))
navigate = next(i for i in root["items"] if i["title"] == "Navigate")
by_title = {item["title"]: item for item in navigate["submenu"]}
problems = [title for title in ("Back", "Home", "Recents")
            if by_title.get(title, {}).get("enabled") is not False]
if problems:
    print("enabled with the Deck key:", problems); sys.exit(1)
PY
    python3 - "$WORK/menus-18.json" <<'PY' && ok "[MENU-5] the Deck key disables Turn Off Phone Screen; the phone's own items keep their rule" \
        || bad "[MENU-5] the Deck key changed the Phone menu's own mapping"
import json, sys
root = json.load(open(sys.argv[1]))
phone = next(i for i in root["items"] if i["title"] == "Phone")
by_title = {item["title"]: item for item in phone["submenu"] if not item["isSeparator"]}
problems = []
if by_title["Turn Off Phone Screen"]["enabled"]:
    problems.append("Turn Off Phone Screen is enabled with the Deck key")
for title in ("Phone Mirror", "Do Not Disturb", "Ring Phone", "Install APK…"):
    if not by_title[title]["enabled"]:
        problems.append(title + " is disabled while the phone is online")
if problems:
    print("; ".join(problems)); sys.exit(1)
PY
    # The keys the disabled items carry: ⇧⌘T, ⌥⌘F, ⌘+/⌘−/⌘0 must not reach the
    # hidden stream window (its style, touches and density stay) and must not
    # type into the Deck's search field.
    local density_before density_after
    density_before="$(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>/dev/null || echo none)"
    control deckfocus search || bad "MENUS deckfocus search for the Deck-key keys: $CONTROL_REPLY"
    control deckquery keep || bad "MENUS deckquery for the Deck-key keys: $CONTROL_REPLY"
    sleep 0.3
    local stroke
    for stroke in "shift+cmd+t" "option+cmd+f" "cmd+=" "cmd+-" "cmd+0"; do
        control key "$stroke" || bad "MENUS key $stroke with the Deck key: $CONTROL_REPLY"
    done
    sleep 1
    density_after="$(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>/dev/null || echo none)"
    control decksearch "$WORK/menus-decksearch.json" || bad "MENUS decksearch after the keys: $CONTROL_REPLY"
    python3 - "$WORK/menus-decksearch.json" <<'PY' && ok "[MENU-9] ⇧⌘T, ⌥⌘F and ⌘+/⌘−/⌘0 with the Deck key leave the Deck's search field alone" \
        || bad "[MENU-9] a stream-only key leaked into the Deck's search field"
import json, sys
root = json.load(open(sys.argv[1]))
if not root["focused"] or root["text"] != "keep" or root["keyWindow"] != "deck":
    print(root); sys.exit(1)
PY
    grep -q "style=framed" "$WORK/chrome.txt" 2>/dev/null \
        && grep -q "touches=on" "$WORK/chrome.txt" 2>/dev/null \
        && [ "$density_before" = "$density_after" ] \
        && ok "[MENU-9] the same keys did not reach the stream window behind the Deck (style, touches and density unchanged)" \
        || bad "[MENU-9] a stream-only key acted on the hidden stream window: $(chrome_state), density $density_before -> $density_after"

    control deckzoom 1 >/dev/null || bad "MENUS deckzoom 1 for the tracked View: $CONTROL_REPLY"
    sleep 0.5
    tracked_view "$WORK/menus-viewtrack-deck.json"
    view_marks "$WORK/menus-viewtrack-deck.json" deck \
        && ok "[MENU-9] the Deck key with a stream window open behind it, read while View tracks: every stream-only item is off and disabled, one Enter Full Screen, Icon Size 100 % checked" \
        || bad "[MENU-9] a real View open shows the launch values, not the Deck key's"
    control menupick "View/Icon Size/75 %" || bad "MENUS icon size pick 75 %: $CONTROL_REPLY"
    sleep 1
    tracked_view "$WORK/menus-viewtrack-icon.json"
    view_marks "$WORK/menus-viewtrack-icon.json" icon-75 \
        && ok "[MENU-9] after picking 75 %, the first View open marks 75 % (not the previous 100 %)" \
        || bad "[MENU-9] the Icon Size mark is one pick behind on the first open after the pick"
    control deckzoom 1 >/dev/null || bad "MENUS deckzoom 1 (restore): $CONTROL_REPLY"

    # A relaunch: the same bar, built once from scratch. The shared app is
    # replaced, so the shell takes the new PID for the bookkeeping.
    kill "$SHARED_PID" >/dev/null 2>&1
    wait "$SHARED_PID" 2>/dev/null
    launch --connect "127.0.0.1:$PORT" --open com.android.settings --debug-control "$WORK-control" \
        --debug-chrome-state "$WORK/chrome.txt"
    SHARED_PID="$APP_PID"
    # The stream window is what the View menu follows: dump once it exists (a
    # dump taken before it would say, correctly, that nothing is checked).
    rm -f "$WORK/chrome.txt"
    wait_until 20 eval 'grep -q "frame=" "$WORK/chrome.txt" 2>/dev/null' \
        || bad "MENUS the relaunched stream window never appeared"
    sleep 1
    # The relaunched app's Deck takes the key window (its own open is a task
    # after launch), so the style pair is off and disabled: a rebuild cannot
    # leave a mark on it. The rest of the bar is checked as a person reads it.
    dump_stable 11 || { stop_app; stop_fakephone; return 1; }
    assert_bar "$WORK/menus-11.json" "dump 11"
    python3 - "$WORK/menus-11.json" <<'PY' && ok "[MENU-9] after a relaunch the Deck is key: the style pair is off and disabled" \
        || bad "[MENU-9] a relaunch left the style pair on or enabled"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(i for i in root["items"] if i["title"] == "View")
by_title = {item["title"]: item for item in view["submenu"]}
pair = [by_title.get("Framed"), by_title.get("Immersive")]
if None in pair or [item["state"] for item in pair] != ["off", "off"] \
        or [item["enabled"] for item in pair] != [False, False]:
    print("pair:", pair); sys.exit(1)
PY
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
    # A phone that answers a resize with nothing (an old build: no
    # `window.resize.ack`, and a same-size dpi change keeps the encoder, so no
    # new CONFIG either). One unanswered request used to swallow every later
    # press, so the window stayed at the first density until it was reopened:
    # the burst must still reach the phone's last value (WIN-37). This runs
    # before the shared app, against its own phone, so nothing acking can
    # answer for it.
    clean
    FAKE_ARGS="--no-resize-ack" start_fake || return 1
    grep -q "window.resize acks off" "$WORK/fake.err" \
        || { bad "C16 the old-phone phase's fakephone does not say acks are off"; end_shared; return 1; }
    say "C16 old-phone phase: fakephone answers no resize"
    launch_shared --connect "127.0.0.1:$PORT"
    open_shared --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" || return 1
    wait_until 20 events_have '"ev":"video","stream":1,' \
        || { bad "C16 no video for the old-phone burst window"; end_shared; return 1; }
    sleep 1
    # The launch's pairing sheet takes the key window from the first stream
    # window and leaves none when it closes (C13's scripts wait out the same
    # churn). A person brings the window back by clicking its Deck tile; the
    # keys below need it key or they land nowhere.
    control open --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" || return 1
    control keywindow "$WORK/keywindow.txt" >/dev/null 2>&1 || true
    [ "$(sed -n 2p "$WORK/keywindow.txt" 2>/dev/null)" = "Settings (FakePhone)" ] \
        && ok "C16 the old-phone window is key before the burst" \
        || bad "C16 the old-phone window is not key before the burst ($(tr '\n' '|' < "$WORK/keywindow.txt" 2>/dev/null))"
    local press pw0 top0
    pw0=$((900 * RUN_SCALE))
    top0=$(python3 -c "print(int(160 * $pw0 / 900 * 1.5 + 0.5))")
    for press in 1 2 3 4 5 6 7 8 9 10; do
        control key "cmd+=" || bad "C16 old-phone burst press $press: $CONTROL_REPLY"
    done
    wait_until 20 density_stored_is com.android.settings 1.5 \
        || bad "[WIN-37] C16 the old-phone burst left the override: $(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>&1)"
    wait_until 8 stream_dpi_is 1 "$top0" \
        && ok "[WIN-37] an old phone that answers nothing still gets the last density ($top0)" \
        || bad "[WIN-37] C16 the old-phone burst stopped at dpi $(stream_dpi 1) (wanted $top0)"
    end_shared

    begin_shared || return 1
    # The app's dpi: 160 × the exact video width / the 900 pt stream, at the
    # run's backing scale (VideoGeometry.dpi).
    local pw base high
    pw=$((900 * RUN_SCALE))
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
        && ok "[WIN-10] C16 View ▸ Density 125% took the settings window's dpi to $high" \
        || bad "[WIN-10] C16 settings window dpi: $(stream_dpi 1) (wanted $high)"
    [ "$(stream_dpi 2)" = "$base" ] \
        && ok "[WIN-10] C16 the other app's window kept its dpi ($base)" \
        || bad "[WIN-10] C16 the other app's window followed: $(stream_dpi 2) (wanted $base)"
    python3 - "$WORK/events.jsonl" "$base" <<'PY' && ok "[WIN-10] C16 and was never resized for the override" \
        || bad "[WIN-10] C16 the other app's window saw a density resize"
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
        && ok "[WIN-10] C16 the override is stored under the package's key" \
        || bad "[WIN-10] C16 the stored key: $(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>&1)"

    touch "$WORK/density-step-restore"
    wait_until 20 stream_dpi_is 1 "$base" \
        && ok "[WIN-10] C16 Default cleared the override: the window is back at $base" \
        || bad "[WIN-10] C16 after Default the window's dpi is $(stream_dpi 1) (wanted $base)"
    if defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" >/dev/null 2>&1; then
        bad "[WIN-10] C16 Default left the stored override behind"
    else
        ok "[WIN-10] C16 Default removed the stored override"
    fi

    # The burst (the 10-27 report): ten ⌘+ presses as fast as the control route
    # can post them, from 100 % to the 150 % clamp and past it. The Mac sends one
    # request per new value and nothing at the clamp — every repeated request
    # re-attached the phone's encoder and cost frames — so the phone sees two
    # distinct resizes, never the same one twice (docs/NFR.md `density_burst_*`).
    # `key` is a real key event through the application's own dispatch: the menu
    # equivalent first, then the window's responder chain, the person's path.
    next_shared
    open_shared --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" || return 1
    wait_until 20 events_have '"ev":"video","stream":1,' \
        || { bad "C16 no video for the burst window"; stop_app; stop_fakephone; return 1; }
    sleep 1
    local press top
    for press in 1 2 3 4 5 6 7 8 9 10; do
        control key "cmd+=" || bad "C16 burst press $press: $CONTROL_REPLY"
    done
    sleep 2
    top=$(python3 -c "print(int(160 * $pw / 900 * 1.5 + 0.5))")
    wait_until 20 density_stored_is com.android.settings 1.5 \
        && ok "[WIN-10] C16 ten ⌘+ presses reach the 150% clamp and stop there" \
        || bad "[WIN-10] C16 the burst left the override: $(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>&1), dpi now $(stream_dpi 1)"
    if python3 - "$WORK/events.jsonl" "$high" "$top" <<'PY'
import json, sys

high, top = int(sys.argv[2]), int(sys.argv[3])
sent = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if msg.get("t") == "window.resize" and msg.get("stream") == 1:
        sent.append((msg.get("w"), msg.get("h"), msg.get("dpi")))
if len(sent) != 2:
    print("%d resizes, wanted 2: %r" % (len(sent), sent)); sys.exit(1)
if [dpi for _, _, dpi in sent] != [high, top]:
    print("resizes %r, wanted dpi %d then %d" % (sent, high, top)); sys.exit(1)
PY
    then
        ok "[MENU-4] the burst sent one resize per new density and nothing at the clamp"
    else
        bad "[MENU-4] the burst sent a request the Mac already had"
    fi

    # The profile reset (--debug-control reset prefs) forgets overrides too.
    printf '%s\n' "wait 0.6" "density com.android.settings 150" "wait 5" > "$WORK/density-reset.txt"
    open_shared --open com.android.settings --debug-input-script "$WORK/density-reset.txt" || return 1
    wait_until 20 density_stored_is com.android.settings 1.5 \
        && ok "[WIN-10] C16 150% is stored for the app" \
        || bad "[WIN-10] C16 150% was not stored: $(defaults read "$DEFAULTS_SUITE" "chrome.density.com.android.settings" 2>&1)"
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

# check_trackpad — a two-finger scroll is a one-finger touch drag, a wheel is
# still SCROLL, and raw trackpad fingers (modelled by the scripted driver) make
# the pinch and rotate pointers. Momentum events must reach the phone as nothing.
check_trackpad() {
    begin_shared || return 1
    # The closing right click is the "delivered" signal; make it a Back rather
    # than the default long press, whose touch would be a fifth gesture.
    control secondary-click back || bad "C15 secondary-click back: $CONTROL_REPLY"
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
    control secondary-click longPress >/dev/null 2>&1 || true
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
            --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
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

# The latest VIDEO_CONFIG's picture size for the mirror (WxH), or nothing.
last_video_shape() {
    python3 - "$WORK/events.jsonl" <<'PY' || true
import json, sys
w = h = None
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "video" and e.get("stream") == 1 and e.get("config"):
        w, h = e["w"], e["h"]
if w and h:
    print("%dx%d" % (w, h))
PY
}

# frame_video_ratio W H [BAR] — the video area (window minus the style's bar)
# as width/height. ISS-63: the mirror's area must match the picture's shape.
frame_video_ratio() {
    python3 -c 'import sys; w, h, bar = map(float, sys.argv[1:]); print("%.6f" % (w / max(h - bar, 1)))' \
        "$1" "$2" "${3:-28}"
}

# The window's video area (frame minus the style's bar) as width/height, from
# the chrome state.
window_video_ratio() {
    local state frame style bar w h
    state="$(chrome_state)"
    frame="$(printf '%s' "$state" | grep -oE 'frame=[0-9]+x[0-9]+' | head -1 | cut -d= -f2)"
    style="$(printf '%s' "$state" | grep -oE 'style=[a-z]+' | head -1 | cut -d= -f2)"
    [ -n "$frame" ] || return 1
    w="${frame%x*}"
    h="${frame#*x}"
    # The two-style windowed chrome: Immersive adds the 28 pt bar above the
    # stream, Framed insets 38 pt above and 5 pt on the other three sides.
    if [ "$style" = "framed" ]; then
        w=$((w - 10)); h=$((h - 43))
    else
        h=$((h - 28))
    fi
    frame_video_ratio "$w" "$h" 0
}

# aspect_ok RATIO W H — true when RATIO is W/H within 1%.
aspect_ok() {
    python3 -c 'import sys
r, w, h = map(float, sys.argv[1:])
want = w / h
sys.exit(0 if abs(r - want) <= 0.01 * want else 1)' "$1" "$2" "$3"
}

# check_mirror — the phone window shows display 0 at the screen's aspect; when
# the phone turns to landscape the stream and the window turn with it.
# mirror_control CMD... — one command to the mirror check's own control host
# (launched with --debug-control "$WORK/control"); its one-line answer lands in
# CONTROL_REPLY, "ok" on success.
mirror_control() {
    local dir="$WORK/control" name
    CONTROL_SEQ=$((CONTROL_SEQ + 1))
    name="m$CONTROL_SEQ"
    printf '%s\n' "$*" > "$dir/$name.tmp" && mv "$dir/$name.tmp" "$dir/$name.cmd"
    if ! wait_until 10 [ -s "$dir/$name.done" ]; then
        CONTROL_REPLY="no answer in 10 s"
        return 1
    fi
    CONTROL_REPLY="$(cat "$dir/$name.done")"
    rm -f "$dir/$name.done"
    [ "$CONTROL_REPLY" = "ok" ]
}

check_mirror() {
    # The opening cover (docs/UX.md): from the open until the first frame the
    # window is frozen behind the phone's name and a spinner; after 20 s it
    # says it could not open. The fake holds the first frame so a quiet run
    # can see both ends.
    clean
    rm -f "$WORK/chrome.txt"
    # ISS-63: a remembered frame from another phone, style or screen (432×870
    # for this 1080×2340 phone) must not open the mirror wider than its picture.
    defaults write "$DEFAULTS_SUITE" streamFrames -dict phone -string '{{120, 30}, {432, 870}}'
    FAKE_ARGS="--first-frame-delay 25" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --quit-after 40
    if wait_until 10 chrome_has "loading=1"; then
        ok "[MIRROR-2] opening cover: loading=1 right after the window opened"
    else
        bad "[MIRROR-2] opening cover: no loading cover (state: $(chrome_state))"
    fi
    local opening_id opening_ratio opening_w opening_h
    if opening_id="$(await_window '$5 > $4 * 1.5')"; then
        read -r opening_w opening_h <<<"$(windows | awk -v i="$opening_id" '$1 == i {print $4, $5}')"
        opening_ratio="$(frame_video_ratio "$opening_w" "$opening_h")"
        if aspect_ok "$opening_ratio" 1080 2340; then
            ok "[MIRROR-24] a wrong-shaped saved frame opens in the phone's shape (${opening_w}x${opening_h}, video area ${opening_ratio})"
        else
            bad "[MIRROR-24] the mirror opened wrong-shaped from the saved frame (${opening_w}x${opening_h}, video area ${opening_ratio})"
        fi
    else
        bad "[MIRROR-24] no phone window to measure after the saved-frame open"
    fi
    if wait_until 25 chrome_has "loading=failed"; then
        ok "[MIRROR-2] opening cover: after 20 s without a frame it says it could not open"
    else
        bad "[MIRROR-2] opening cover: no failure after 20 s (state: $(chrome_state))"
    fi
    stop_app
    stop_fakephone

    clean
    rm -f "$WORK/chrome.txt"
    # ISS-63 again, now with a picture: the first VIDEO_CONFIG's shape must
    # agree with the window's video area, even though the saved frame was not
    # the phone's shape.
    defaults write "$DEFAULTS_SUITE" streamFrames -dict phone -string '{{120, 30}, {432, 870}}'
    # The first frame 3 s in: long enough for the cover to be seen, short
    # enough for the aspect and rotation steps below.
    # --frame-events: one `frames` event a second per stream, so the panel-off
    # step can show the mirror kept rendering. --panel-ends-after: the person's
    # power button on the phone ends "Turn Off Phone Screen" a few seconds later.
    FAKE_ARGS="--first-frame-delay 3 --rotate-after 6 --screen-off-after 14 --frame-events --panel-ends-after 12" \
        start_fake || return 1
    # The pointer comes to the top edge to bring the header in (glass nav buttons).
    printf '%s\n' "wait 1" "hoverat 0 200" "wait 0.03" "hoverat 0 150" "wait 0.03" "hoverat 0 120" \
        "wait 0.03" "hoverat 0 90" "wait 0.03" "hoverat 0 70" "wait 0.03" "hoverat 0 58" > "$WORK/mirror.txt"
    mkdir -p "$WORK/control"
    # The shot this phase records is dark (docs/UX.md): the app's own
    # --appearance flag, so the person's system setting is never touched.
    dark_args=()
    [ "$VISIBLE" = 1 ] && dark_args=(--appearance dark)
    # The run's own waits (rotation, stale frame, wake, panel) exceed a minute on
    # a loaded Mac; the app must outlive them or every later control command
    # lands with no app to read it.
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/mirror.txt" \
        --debug-control "$WORK/control" --quit-after 120 ${dark_args[@]+"${dark_args[@]}"}
    if wait_until 5 chrome_has "loading=1"; then
        ok "[MIRROR-2] opening cover: the window is covered before its first frame"
    else
        bad "[MIRROR-2] opening cover: the window showed no cover before the first frame (state: $(chrome_state))"
    fi
    if wait_until 15 chrome_has "loading=0"; then
        ok "[MIRROR-2] opening cover: the first frame took the cover away"
    else
        bad "[MIRROR-2] opening cover: the cover stayed after the first frame (state: $(chrome_state))"
    fi
    local picture_shape picture_ratio
    if picture_shape="$(last_video_shape)" && [ -n "$picture_shape" ] \
        && picture_ratio="$(window_video_ratio)" \
        && aspect_ok "$picture_ratio" "${picture_shape%x*}" "${picture_shape#*x}"; then
        ok "[MIRROR-24] the first picture's shape matches the window's video area (${picture_shape}, area ${picture_ratio})"
    else
        bad "[MIRROR-24] the window's video area does not match the picture ($(chrome_state | grep -oE 'frame=[0-9]+x[0-9]+'), picture ${picture_shape:-none})"
    fi
    # repro wake-on-open: opening the window sends one phone.wake.
    if wait_until 15 events_have '"t":"phone.wake"'; then
        ok "[MIRROR-3] repro wake-on-open: opening the phone window sent phone.wake"
    else
        bad "[MIRROR-3] repro wake-on-open: the phone got no phone.wake on open"
    fi
    local portrait landscape
    if portrait="$(await_window '$5 > $4 * 1.5')"; then
        ok "[MIRROR-4] phone window is portrait ($(windows | awk -v i="$portrait" '$1 == i {print $4 "x" $5}'))"
    else
        bad "[MIRROR-4] no portrait phone window"; stop_app; stop_fakephone; return 1
    fi
    # No full screen for the phone window (the mirror in native full screen
    # looks bad): it opts out in its collection behavior, so the green button
    # only zooms and AppKit disables the system's View item for it.
    if wait_until 3 chrome_has "can_fullscreen=0"; then
        ok "[MIRROR-4] the phone window offers no full screen ($(chrome_state))"
    else
        bad "[MIRROR-4] the phone window still offers full screen ($(chrome_state))"
    fi
    if chrome_has "collection_none=1"; then
        ok "[MIRROR-4] the phone window's collection behavior is fullScreenNone"
    else
        bad "[MIRROR-4] the phone window's collection behavior allows full screen ($(chrome_state))"
    fi
    wait_until 15 events_have '"ev":"video"' || true
    case "$(mirror_aspect)" in
        *" ok") ok "[MIRROR-4] stream has the phone screen's aspect ($(mirror_aspect))" ;;
        *) bad "[MIRROR-4] stream aspect is not the phone's ($(mirror_aspect))" ;;
    esac
    wait_until 3 chrome_is "header=shown" && sleep 0.4
    if landscape="$(await_window "\$1 == $portrait && \$4 > \$5 * 1.5")"; then
        ok "[MIRROR-5] window turned with the phone ($(windows | awk -v i="$landscape" '$1 == i {print $4 "x" $5}'))"
    else
        bad "[MIRROR-5] window did not turn to landscape"
    fi
    wait_until 10 landscape_config \
        && ok "[MIRROR-5] landscape VIDEO_CONFIG sent" || bad "[MIRROR-5] no landscape VIDEO_CONFIG"
    # One mirror per phone (the person's report, 2026-10-22): asking for the
    # phone's mirror again raises the open one. Before the fix every ask opened
    # another window on another stream. Phone ▸ Phone Mirror, the panel's row and
    # the Deck's button all end in ConnectionController.openPhoneWindow, so the
    # check asks that function three more times (`phone-mirror`). ⌘P itself is
    # the menu's key equivalent, which SwiftUI runs only for the frontmost app:
    # a quiet launch is not one, so ⌘P prints SKIP here (see the step below).
    local mirrors press before opens streams menu_flag
    before="$(count_events '"t":"window.open"')"
    for press in 1 2 3; do
        mirror_control phone-mirror || bad "MIRROR Phone Mirror ask $press: $CONTROL_REPLY"
        sleep 0.4
    done
    sleep 1
    # The asks opened nothing new (window.open), and the phone's video configs
    # name one stream: one mirror for the phone.
    opens="$(count_events '"t":"window.open"')"
    streams="$(grep '"ev":"video"' "$WORK/events.jsonl" 2>/dev/null | grep -o 'stream":[0-9]*' | sort -u | wc -l | tr -d ' ')"
    if [ "$opens" = "1" ] && [ "$streams" = "1" ]; then
        ok "[MIRROR-1] Phone Mirror asked three more times: one window.open, one stream"
    else
        bad "[MIRROR-1] Phone Mirror asked three more times: $opens window.open ($before before the asks), $streams streams (want 1 and 1)"
    fi
    # A mirror is portrait or landscape; the Deck is 760x560 (1.36), so the
    # two phone aspects pick the mirrors in either orientation — a window that
    # just opened is portrait until its first frame turns it.
    mirrors="$(windows | awk '($5 > $4 * 1.5) || ($4 > $5 * 1.5)' | wc -l | tr -d ' ')"
    if [ "$mirrors" = "1" ]; then
        ok "[MIRROR-1] Phone Mirror asked three more times: one phone window on screen"
    else
        bad "[MIRROR-1] Phone Mirror asked three more times: $mirrors phone windows on screen"
    fi
    # The menu item must be enabled while the phone is online. Read from a
    # validated menu (menudump validates it as an opened menu does); read-only.
    mirror_control menudump "$WORK/menu-mirror.json" || bad "MIRROR menu dump: $CONTROL_REPLY"
    python3 - "$WORK/menu-mirror.json" <<'PY' && ok "[MIRROR-1] Phone ▸ Phone Mirror (⌘P) is enabled while the phone is online" \
        || bad "[MIRROR-1] Phone ▸ Phone Mirror (⌘P) is disabled while the phone is online"
import json, sys
root = json.load(open(sys.argv[1]))
phone = next(i for i in root["items"] if i["title"] == "Phone")
item = next(i for i in phone["submenu"] if i["title"] == "Phone Mirror")
raise SystemExit(0 if item["enabled"] else 1)
PY
    # ⌘P: the key needs the frontmost app. A quiet run must not activate the app
    # (focus_changes stays 0), so the key press is the VM run's step.
    skip "MIRROR ⌘P press" "a quiet launch is not the frontmost app; the key needs a visible run"

    # repro stale-frame: the panel times out, the fake stops frames, and the
    # window shows "screen off" within the limit docs/NFR.md sets — never the
    # last frame as if live.
    local stale_ms stale_s
    stale_ms="$(nfr_limit stale_picture_ms)"
    stale_s="$(( (stale_ms + 999) / 1000 ))"
    wait_until 20 events_have '"ev":"screen","state":"off"' \
        || bad "MIRROR the fake never reported the screen off"
    if wait_until "$stale_s" chrome_has "screen=off overlay=1"; then
        ok "[MIRROR-6] repro stale-frame: screen off put the cover up within ${stale_ms} ms ($(chrome_state))"
    else
        bad "[MIRROR-6] repro stale-frame: the window kept the last frame as live ($(chrome_state))"
    fi
    if [ "$(phone_screen_log)" -ge 1 ]; then
        ok "[MIRROR-21] the app logged phone window: screen=off overlay=1"
    else
        say "MIRROR the unified log has no screen-off line on this Mac (empty log store); the chrome state is the evidence"
    fi
    local frames_before_wake
    frames_before_wake="$(last_frame_event)"
    # The Wake Screen route (the button is unit-tested; a scripted click needs
    # real input): one more phone.wake, the fake sends screen on, frames resume.
    # A resumed encoder with the same picture needs no new VIDEO_CONFIG (a sync
    # frame carries no new parameter sets), so the frames themselves are the
    # evidence, not a second identical config.
    printf 'wake-phone\n' > "$WORK/control/wake.cmd"
    if wait_until 10 wake_done_ok; then
        ok "[MIRROR-7] Wake Screen ran"
    else
        bad "[MIRROR-7] Wake Screen did not run: $(cat "$WORK/control/wake.done" 2>/dev/null)"
    fi
    if [ "$(grep -c '"t":"phone.wake"' "$WORK/events.jsonl")" -ge 2 ]; then
        ok "[MIRROR-7] Wake Screen sent phone.wake ($(grep -c '"t":"phone.wake"' "$WORK/events.jsonl") total)"
    else
        bad "[MIRROR-7] Wake Screen sent no phone.wake"
    fi
    wait_until 10 events_have '"ev":"screen","state":"on"' \
        && ok "[MIRROR-7] the fake came back on" || bad "[MIRROR-7] the fake never reported screen on"
    if wait_until 10 chrome_has "screen=on overlay=0"; then
        ok "[MIRROR-7] the cover cleared after the wake ($(chrome_state))"
    else
        bad "[MIRROR-7] the cover stayed up after the wake ($(chrome_state))"
    fi
    if wait_until 10 more_frame_events "$frames_before_wake"; then
        ok "[MIRROR-7] frames resumed after the wake (frame events to $(last_frame_event))"
    else
        bad "[MIRROR-7] frames did not resume after the wake (frame events $(last_frame_event))"
    fi
    # "Turn Off Phone Screen" (docs/design/phone-mirror.md): Phone ▸ the item's
    # own action, the phone hears phone.panel off, the mirror keeps sending
    # frames and the bar says so; the phone's power press ends it and the Mac
    # follows the echoed state.
    if wait_until 3 chrome_has "panel_off=0"; then
        ok "[MIRROR-9] Turn Off Phone Screen is off by default (panel_off=0)"
    else
        bad "[MIRROR-9] the phone window does not report panel_off ($(chrome_state))"
    fi
    local frames_before
    frames_before="$(last_frame_event)"
    printf 'panel-menu\n' > "$WORK/control/panel-menu.cmd"
    if wait_until 5 panel_menu_done; then
        ok "[MIRROR-9] the Turn Off Phone Screen menu item ran"
    else
        bad "[MIRROR-9] the menu item did not run: $(cat "$WORK/control/panel-menu.done" 2>/dev/null)"
    fi
    # The fake's own event for the request (its rx JSON sorts keys, so the
    # request line itself is not a stable match).
    if wait_until 10 events_have '"ev":"panel","state":"off"'; then
        ok "[MIRROR-9] the menu item sent phone.panel off and the phone applied it"
    else
        bad "[MIRROR-9] the phone got no phone.panel off"
    fi
    if wait_until 5 chrome_has "panel_off=1"; then
        ok "[MIRROR-10] the bar and the chrome state follow the phone's panel=off"
    else
        bad "[MIRROR-10] the indicator did not follow state.panel ($(chrome_state))"
    fi
    if wait_until 8 more_frame_events "$frames_before"; then
        ok "[MIRROR-9] the mirror keeps sending frames while the panel is off (frame events to $(last_frame_event))"
    else
        bad "[MIRROR-9] the mirror stopped sending frames with the panel off (frame events $(last_frame_event))"
    fi
    if wait_until 15 events_have '"ev":"panel","state":"on"'; then
        ok "[MIRROR-12] the phone ended the panel-off (the person's power button)"
    else
        bad "[MIRROR-12] the phone never ended the panel-off"
    fi
    if wait_until 5 chrome_has "panel_off=0"; then
        ok "[MIRROR-12] the indicator went away when the phone ended it"
    else
        bad "[MIRROR-12] the indicator stayed after the phone ended it ($(chrome_state))"
    fi

    # The bar's Back / Home / Recents buttons take a real click: the debug
    # route hit-tests each button's window location and posts the mouse events
    # to the control it finds, so the button's own mouseDown/mouseUp run. v103
    # moved the buttons into glass capsules and their hit test stopped matching
    # the point; the old route called the action and never saw it.
    for button in back home recents; do
        before="$(nav_rx_count "$button")"
        printf 'nav-click %s\n' "$button" > "$WORK/control/nav-$button.cmd"
        if wait_until 5 nav_click_done "$button"; then
            if wait_until 10 nav_clicked "$button" "$before"; then
                ok "[MIRROR-13] a click on the $button bar button -> nav $button"
            else
                bad "[MIRROR-13] the $button bar button sent no nav $button"
            fi
        else
            bad "MIRROR the $button bar button click did not run: $(cat "$WORK/control/nav-$button.done" 2>/dev/null)"
        fi
    done

    # The bar's keyboard route (MIRROR-13, misses.md M1): Tab is the phone's (a
    # Mac with Full Keyboard Access on spends it on the window's focus order, so
    # only the bar's own state is asserted here), ⌃Tab is the Mac's and takes the
    # focus into the bar, Return presses the focused button, ←/→ and Tab move,
    # Esc gives the keyboard back without sending Back.
    local tab_key_before tab_key_after back_before back_after
    tab_key_before="$(grep -c '"kind":"key"[^}]*"keycode":61' "$WORK/events.jsonl" 2>/dev/null || echo 0)"
    mirror_control key tab || bad "MIRROR-13 keyboard: key tab: $CONTROL_REPLY"
    if chrome_has "bar_focus=none"; then
        ok "[MIRROR-13] Tab did not move the bar's focus"
    else
        bad "[MIRROR-13] Tab moved the bar's focus ($(chrome_state))"
    fi
    mirror_control key ctrl+tab || bad "MIRROR-13 keyboard: key ctrl+tab: $CONTROL_REPLY"
    if wait_until 5 chrome_has "bar_focus=0"; then
        ok "[MIRROR-13] ⌃Tab put the keyboard on the bar's first button (Back)"
    else
        bad "[MIRROR-13] ⌃Tab did not focus the bar ($(chrome_state))"
    fi
    if [ "$VISIBLE" = 1 ]; then
        sleep 1
        # The mirror window is the one whose frame the chrome state reports (the
        # phone turned to landscape earlier, so size alone does not find it).
        local bar_frame bar_w bar_h bar_id
        bar_frame="$(sed -n 's/.* frame=\([0-9]*\)x\([0-9]*\).*/\1 \2/p' "$WORK/chrome.txt")"
        read -r bar_w bar_h <<<"$bar_frame"
        mirror_control bar-appearance "$WORK/bar-appearance.txt" \
            && say "shot appearance: $(cat "$WORK/bar-appearance.txt")"
        if bar_id="$(await_window "\$4 == $bar_w && \$5 == $bar_h")" \
            && screencapture -x -l"$bar_id" "$SHOTS/bar-focus.png"; then
            say "shot: $SHOTS/bar-focus.png"
        else
            bad "MIRROR-13 keyboard: no shot of the focus ring"
        fi
    fi
    # Return presses Back: the same nav the click and the menu send.
    back_before="$(nav_rx_count back)"
    mirror_control key return || bad "MIRROR-13 keyboard: key return: $CONTROL_REPLY"
    if wait_until 10 nav_clicked back "$back_before"; then
        ok "[MIRROR-13] Return on the focused Back sent nav back"
    else
        bad "[MIRROR-13] Return on the bar sent no nav back"
    fi
    # Tab while the bar has the focus moves to the next button and stays out of
    # the phone.
    tab_key_after="$(grep -c '"kind":"key"[^}]*"keycode":61' "$WORK/events.jsonl" 2>/dev/null || echo 0)"
    mirror_control key right || bad "MIRROR-13 keyboard: key right: $CONTROL_REPLY"
    if wait_until 5 chrome_has "bar_focus=1"; then
        ok "[MIRROR-13] → moved the keyboard to the next bar button (Home)"
    else
        bad "[MIRROR-13] → did not move the bar's focus ($(chrome_state))"
    fi
    # Esc gives the keyboard back to the picture; a focused Esc must not become
    # the phone's Back, which is what Esc means on the picture.
    back_before="$(nav_rx_count back)"
    mirror_control key esc || bad "MIRROR-13 keyboard: key esc: $CONTROL_REPLY"
    if wait_until 5 chrome_has "bar_focus=none"; then
        ok "[MIRROR-13] Esc returned the keyboard to the picture"
    else
        bad "[MIRROR-13] Esc left the bar's focus on ($(chrome_state))"
    fi
    sleep 0.5
    back_after="$(nav_rx_count back)"
    if [ "$back_after" = "$back_before" ]; then
        ok "[MIRROR-13] the Esc that left the bar sent no Back to the phone"
    else
        bad "[MIRROR-13] the Esc that left the bar also sent Back"
    fi
    if [ "$(grep -c '"kind":"key"[^}]*"keycode":61' "$WORK/events.jsonl" 2>/dev/null || echo 0)" = "$tab_key_after" ]; then
        ok "[MIRROR-13] the bar's keys never reached the phone while it had the keyboard"
    else
        bad "[MIRROR-13] a bar key leaked to the phone"
    fi

    # A person's click on the bar control (the menu route above is a different
    # control): the click goes through the button's own mouse events, and the
    # glyph must follow the phone's `state.panel` within panel_glyph_ms. The
    # fake answers at once, so the limit is the Mac's hop from the report to the
    # redraw. A second run reports 1000 ms late (--panel-delay-ms): the glyph
    # must stay put until the report arrives — it follows the phone, never the
    # click.
    local glyph_ms glyph_limit
    glyph_limit="$(nfr_limit panel_glyph_ms)"
    for fake_delay in 0 1000; do
        # A fresh profile per run: "Turn Off Phone Screen" is remembered per
        # phone, so the first run's clicks would otherwise reopen it already off.
        clean
        mkdir -p "$WORK/control"
        printf '%s\n' "wait 1" "hoverat 0 200" "wait 0.03" "hoverat 0 120" \
            "wait 0.03" "hoverat 0 70" "wait 0.03" "hoverat 0 58" > "$WORK/panel-hover.txt"
        FAKE_ARGS="--panel-delay-ms $fake_delay" start_fake || return 1
        launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
            --debug-chrome-state "$WORK/chrome.txt" --debug-input-script "$WORK/panel-hover.txt" \
            --debug-control "$WORK/control" --quit-after 60
        if ! wait_until 15 chrome_has "loading=0"; then
            bad "MIRROR panel glyph (report +${fake_delay} ms): the window never showed a frame"
            stop_app; stop_fakephone; return 1
        fi
        if ! wait_until 5 chrome_has "panel_off=0"; then
            bad "MIRROR panel glyph (report +${fake_delay} ms): panel_off is not reported"
            stop_app; stop_fakephone; return 1
        fi
        sleep 0.6
        rm -f "$WORK/control/panel-click.done"
        printf 'panel-click\n' > "$WORK/control/panel-click.cmd"
        if ! wait_until 5 panel_click_done; then
            bad "MIRROR panel glyph: the bar control click did not run: $(cat "$WORK/control/panel-click.done" 2>/dev/null)"
            stop_app; stop_fakephone; return 1
        fi
        if [ "$fake_delay" = "0" ]; then
            # Both ways: the same click turns it off, then back on.
            for glyph_want in 1 0; do
                if [ "$glyph_want" = "0" ]; then
                    rm -f "$WORK/control/panel-click.done"
                    printf 'panel-click\n' > "$WORK/control/panel-click.cmd"
                    wait_until 5 panel_click_done \
                        || bad "MIRROR panel glyph: the second bar control click did not run"
                fi
                if ! wait_until 5 chrome_has "panel_off=$glyph_want"; then
                    bad "MIRROR panel glyph: the glyph did not follow state.panel (panel_off=$glyph_want, $(chrome_state))"
                    continue
                fi
                glyph_ms="$(panel_glyph_ms)"
                if python3 -c "import sys; sys.exit(0 if 0 <= $glyph_ms <= $glyph_limit else 1)"; then
                    ok "[MIRROR-10] a bar-control click redrew the glyph in ${glyph_ms} ms (panel_off=$glyph_want, limit ${glyph_limit} ms)"
                else
                    bad "[MIRROR-10] a bar-control click took ${glyph_ms} ms to redraw the glyph (panel_off=$glyph_want, limit ${glyph_limit} ms)"
                fi
            done
        else
            sleep 0.3
            if chrome_has "panel_off=0"; then
                ok "[MIRROR-10] the glyph waits for the phone's report (+${fake_delay} ms), not the click"
            else
                bad "[MIRROR-10] the glyph changed on the click, before the phone reported (report +${fake_delay} ms)"
            fi
            if wait_until 5 chrome_has "panel_off=1"; then
                glyph_ms="$(panel_glyph_ms)"
                if python3 -c "import sys; sys.exit(0 if 900 <= $glyph_ms <= $fake_delay + $glyph_limit else 1)"; then
                    ok "[MIRROR-10] the glyph followed the late report in ${glyph_ms} ms (Mac hop $((glyph_ms - fake_delay)) ms)"
                else
                    bad "[MIRROR-10] the late report took ${glyph_ms} ms to redraw the glyph (limit $((fake_delay + glyph_limit)) ms)"
                fi
            else
                bad "MIRROR the glyph never followed the late state.panel"
            fi
        fi
        stop_app
        stop_fakephone
        wait_until 5 no_fakephone
    done

    # A secure surface (fakephone --secure-after): Android blanks the phone's
    # PIN pad, keyguard bouncer or a FLAG_SECURE app, so the phone reports
    # state.secure and sends black frames. The window shows the same blurred
    # cover with "Android doesn't let Contigua show this screen." and no
    # button, within 2 s of the phone's report, and clears when it reports the
    # surface gone.
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--secure-after 4" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --quit-after 35
    if wait_until 20 events_have '"ev":"secure","state":"on"'; then
        local secure_at elapsed
        secure_at="$(python3 -c 'import time; print(time.time())')"
        # wait_until counts whole seconds, so it brackets the wait; the limit is
        # measured on the clock.
        if wait_until 5 chrome_has "overlay=1 secure=1"; then
            elapsed="$(python3 -c "import time; print('%.2f' % (time.time() - $secure_at))")"
            if python3 -c "import sys; sys.exit(0 if $elapsed <= 2 else 1)"; then
                ok "[MIRROR-8] a secure surface covers the window within 2 s (${elapsed}s)"
            else
                bad "[MIRROR-8] a secure surface took ${elapsed}s to cover the window"
            fi
        else
            bad "MIRROR a secure surface did not cover the window ($(chrome_state))"
        fi
    else
        bad "MIRROR the fake never reported a secure surface"
    fi
    if [ "$(secure_log_count)" -ge 1 ]; then
        ok "[MIRROR-21] the app logged phone window: secure=1 overlay=1"
    else
        say "MIRROR the unified log has no secure line on this Mac (empty log store); the chrome state is the evidence"
    fi
    if wait_until 15 chrome_has "secure=0"; then
        ok "[MIRROR-8] the secure cover cleared when the phone reported the surface gone"
    else
        bad "[MIRROR-8] the secure cover stayed up ($(chrome_state))"
    fi
    stop_app
    stop_fakephone
    # The Mac button tells the truth (fakephone --panel-refuse): a phone that
    # answers `phone.panel` with error unavailable never turned its screen off,
    # so the button stays unchecked and a 2 s pill says so.
    wait_until 5 no_fakephone
    rm -f "$WORK/control/panel-menu.done" "$WORK/control/panel-menu.cmd"
    FAKE_ARGS="--panel-refuse --first-frame-delay 1" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK/control" --quit-after 30
    if wait_until 20 chrome_has "loading=0"; then
        ok "[MIRROR-11] refusal: the refused phone's window opened"
    else
        bad "[MIRROR-11] refusal: the phone window never got its first frame ($(chrome_state))"
    fi
    if wait_until 3 chrome_has "panel_off=0"; then
        ok "[MIRROR-11] refusal: the button starts unchecked"
    else
        bad "[MIRROR-11] refusal: the button did not start unchecked ($(chrome_state))"
    fi
    printf 'panel-menu\n' > "$WORK/control/panel-menu.cmd"
    if wait_until 5 panel_menu_done; then
        ok "[MIRROR-11] refusal: Turn Off Phone Screen ran"
    else
        bad "[MIRROR-11] refusal: the menu item did not run: $(cat "$WORK/control/panel-menu.done" 2>/dev/null)"
    fi
    # The error is answered at once, and the pill lasts 2 s: read it before
    # anything else could take it down.
    if wait_until 3 chrome_has "panel_off=0 panel_pill=1 panel_pill_failed=1"; then
        ok "[MIRROR-11] refusal: a 2 s pill says the phone didn't turn its screen off, button unchecked"
    else
        bad "[MIRROR-11] refusal: no failure pill or the button moved ($(chrome_state))"
    fi
    if wait_until 10 events_have '"t":"phone.panel"'; then
        ok "[MIRROR-11] refusal: the phone heard phone.panel"
    else
        bad "[MIRROR-11] refusal: the phone got no phone.panel"
    fi
    if grep -F '"t":"phone.panel"' "$WORK/events.jsonl" | grep -qF '"ignorePower":false'; then
        ok "[MIRROR-9] the request carries ignorePower (off by default)"
    else
        bad "[MIRROR-9] phone.panel carried no ignorePower field"
    fi
    stop_app
    stop_fakephone

    # PANEL-12/PANEL-19 (misses.md M3): a mirror open does not make Turn Off
    # Screen possible while the phone is away. With the fake stopped the tile is
    # disabled with the offline sentence and a click sends nothing; before the
    # fix the request went into a dead session and the 2 s pill blamed the
    # phone for not turning its screen off.
    wait_until 5 no_fakephone
    clean
    mkdir -p "$WORK/control"
    start_fake || return 1
    dark_args=()
    [ "$VISIBLE" = 1 ] && dark_args=(--appearance dark)
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK/control" --quit-after 90 \
        ${dark_args[@]+"${dark_args[@]}"}
    if ! wait_until 25 chrome_has "loading=0"; then
        bad "PANEL offline tile: the mirror never showed a frame"
        stop_app; stop_fakephone; return 1
    fi
    # The same panel a person reads (the menu bar's content), over the mirror.
    mirror_control panelopen || bad "PANEL offline tile: panelopen: $CONTROL_REPLY"
    rm -f "$WORK/panel-up.json"
    mirror_control paneldump panel "$WORK/panel-up.json" \
        || bad "PANEL offline tile: paneldump (online): $CONTROL_REPLY"
    python3 - "$WORK/panel-up.json" <<'PY' \
        && ok "[PANEL-12] a connected phone with a mirror open leaves Turn Off Screen enabled" \
        || bad "[PANEL-12] Turn Off Screen is disabled while the phone is connected"
import json, sys
root = json.load(open(sys.argv[1]))
tile = next(row for row in root["items"] if row["kind"] == "screen")
if not tile["enabled"]:
    print("online tile:", tile); sys.exit(1)
PY
    stop_fakephone
    # "Reconnecting…" then "Offline" after 15 s without a session (panel.md).
    panel_is_offline() {
        mirror_control paneldump panel "$WORK/panel-offline.json" >/dev/null 2>&1 || return 1
        python3 - "$WORK/panel-offline.json" <<'PY'
import json, sys
try:
    root = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if root.get("status") == "Offline" else 1)
PY
    }
    if wait_until 30 panel_is_offline; then
        ok "[PANEL-12] the panel reads Offline after the phone went away"
    else
        bad "[PANEL-12] the panel never read Offline ($(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status"))' "$WORK/panel-offline.json" 2>/dev/null))"
    fi
    python3 - "$WORK/panel-offline.json" <<'PY' \
        && ok "[PANEL-19] offline: Turn Off Screen is disabled with \"Connect your phone to use these.\"" \
        || bad "[PANEL-19] offline: Turn Off Screen stayed enabled or lost its reason"
import json, sys
root = json.load(open(sys.argv[1]))
tile = next(row for row in root["items"] if row["kind"] == "screen")
if tile["enabled"]:
    print("offline tile:", tile); sys.exit(1)
if root["reason"] != "Connect your phone to use these.":
    print("reason:", root["reason"]); sys.exit(1)
PY
    # [MIRROR-14] The mirror bar's own Turn Off Phone Screen is disabled with
    # the offline reason too, and a click at it sends no phone.panel.
    chrome_has "bar_offline=1" \
        && ok "[WIN-22] the bar is offline after the phone went away" \
        || bad "[WIN-22] the bar does not report the link down: $(chrome_state)"
    chrome_has "bar_enabled=none" \
        && ok "[WIN-22] every phone-side bar control is disabled offline (Turn Off Phone Screen included)" \
        || bad "[WIN-22] a bar control stayed enabled offline: $(chrome_state)"
    local bar_requests bar_panels
    bar_requests="$(sed -n 's/.* panel_requests=\([0-9]*\).*/\1/p' <<< "$(chrome_state)")"
    bar_panels="$(count_events '"t":"phone.panel"' | head -1)"
    mirror_control panel-click || true
    sleep 1
    [ "$(sed -n 's/.* panel_requests=\([0-9]*\).*/\1/p' <<< "$(chrome_state)")" = "$bar_requests" ] \
        && [ "$(count_events '"t":"phone.panel"' | head -1)" = "$bar_panels" ] \
        && ok "[MIRROR-14] a click on the dimmed Turn Off Phone Screen sent no phone.panel" \
        || bad "[MIRROR-14] the disabled bar button still sent a request"

    # A click on the disabled tile sends nothing: the Mac's own count of
    # phone.panel messages stays at zero, and the probe refuses the click.
    if mirror_control panelclick panel panel.screen; then
        bad "PANEL-19 offline: the disabled tile took a click"
    else
        ok "[PANEL-19] offline: a click on the disabled tile is refused ($CONTROL_REPLY)"
    fi
    if wait_until 5 chrome_has "panel_requests=0"; then
        ok "[PANEL-12] offline: the click sent zero phone.panel"
    else
        bad "[PANEL-12] offline: a click sent phone.panel ($(chrome_state))"
    fi
    # The shot the brief asks for: the disabled tile and its reason (visible
    # runs only: a quiet run may not touch the person's appearance).
    if [ "$VISIBLE" = 1 ]; then
        sleep 1
        local panel_id
        if panel_id="$(await_window '$4 == 320')" \
            && screencapture -x -l"$panel_id" "$SHOTS/panel-offline.png"; then
            say "shot: $SHOTS/panel-offline.png"
        else
            bad "PANEL offline tile: no shot of the panel"
        fi
    fi
    stop_app
    stop_fakephone

    # MIRROR-2 (misses.md M2): a phone that cannot capture display 0 answers
    # window.open with error{mirror_unavailable} (fakephone
    # --mirror-unavailable). The window says one sentence at once and offers
    # Close only: no Try Again, no 20 s generic failure, and no second
    # window.open. Before the fix it sat on the cover for 20 s, said "Couldn't
    # open your phone." and Try Again failed the same way.
    wait_until 5 no_fakephone
    clean
    mkdir -p "$WORK/control"
    FAKE_ARGS="--mirror-unavailable" start_fake || return 1
    dark_args=()
    [ "$VISIBLE" = 1 ] && dark_args=(--appearance dark)
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK/control" --quit-after 45 \
        ${dark_args[@]+"${dark_args[@]}"}
    if wait_until 15 chrome_has "loading=failed"; then
        ok "[MIRROR-2] a phone that can't mirror says so as the window opens"
    else
        bad "[MIRROR-2] a phone that can't mirror got no sentence ($(chrome_state))"
    fi
    if wait_until 3 chrome_has "cover_buttons=close"; then
        ok "[MIRROR-2] the sentence offers Close only (no Try Again)"
    else
        bad "[MIRROR-2] the refused cover offers Try Again ($(chrome_state))"
    fi
    if log show --last 2m --info \
        --predicate 'subsystem == "app.contigua.mac" AND category == "video"' 2>/dev/null \
        | grep -q "opening refused"; then
        ok "[MIRROR-21] the app logged the refusal as a state, nothing about content"
    else
        say "MIRROR the unified log has no refusal line on this Mac; the chrome state is the evidence"
    fi
    # Past the 20 s mark the generic failure must not take the sentence over.
    sleep 21
    if chrome_has "loading=failed cover_phase=failed cover_buttons=close"; then
        ok "[MIRROR-2] the refusal stands 20 s later (no generic failure, no retry loop)"
    else
        bad "[MIRROR-2] the cover changed after 20 s ($(chrome_state))"
    fi
    if [ "$(count_events '"t":"window.open"')" = "1" ]; then
        ok "[MIRROR-2] one window.open: the refused phone was never asked again"
    else
        bad "[MIRROR-2] window.open was sent $(count_events '"t":"window.open"') times"
    fi
    if [ "$VISIBLE" = 1 ]; then
        sleep 1
        if screenshot_portrait "$SHOTS/mirror-unavailable.png"; then
            say "shot: $SHOTS/mirror-unavailable.png"
        else
            bad "MIRROR-2 no shot of the refused cover"
        fi
    fi
    stop_app
    stop_fakephone
}

# secure_log_count — how many secure-cover lines the app wrote in the last 2 minutes.
secure_log_count() { log show --last 2m --info \
    --predicate 'subsystem == "app.contigua.mac" AND category == "video"' 2>/dev/null |
    grep -c 'phone window: secure=1 overlay=1' ; }

# nav_rx_count <action> — stream 1's `nav` messages of that action, as the
# fakephone received them.
nav_rx_count() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
action = sys.argv[2]
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if isinstance(msg, dict) and msg.get("t") == "nav" \
            and msg.get("stream") == 1 and msg.get("action") == action:
        count += 1
print(count)
PY
}

nav_click_done() { [ "$(cat "$WORK/control/nav-$1.done" 2>/dev/null)" = "ok" ]; }
nav_clicked() { [ "$(nav_rx_count "$1")" -gt "$2" ]; }

# chrome_has <text> — the chrome state file contains text.
chrome_has() { case "$(chrome_state)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
# chrome_frame_live — a live picture is on screen: the opening cover is gone,
# no window is opening and the newest frame is under a second old. A capture
# taken before this proves the cover, not the style.
chrome_frame_live() {
    local state age
    state="$(chrome_state)"
    case "$state" in *"loading=0"*) ;; *) return 1 ;; esac
    case "$state" in *"cover_phase=0"*) ;; *) return 1 ;; esac
    case "$state" in *"opening=0"*) ;; *) return 1 ;; esac
    case "$state" in *"cover_visible=0"*) ;; *) return 1 ;; esac
    age="$(printf '%s\n' "$state" | sed -n 's/.* frame_age_ms=\([-0-9]*\).*/\1/p')"
    [ -n "$age" ] || return 1
    case "$age" in -*) return 1 ;; esac
    [ "$age" -le 1000 ]
}
# chrome_all <field>... — every field anywhere in the state (the state's first
# field is the style; a later field never starts the line).
chrome_all() {
    local field
    for field in "$@"; do chrome_has "$field" || return 1; done
}

# phone_screen_log — how many times the app logged the sleeping-panel line in
# the last 2 minutes (states only, never pixels).
phone_screen_log() { log show --last 2m --info \
    --predicate 'subsystem == "app.contigua.mac" AND category == "video"' 2>/dev/null |
    grep -c 'phone window: screen=off overlay=1' ; }

wake_done_ok() { [ "$(cat "$WORK/control/wake.done" 2>/dev/null)" = "ok" ]; }

panel_menu_done() { [ "$(cat "$WORK/control/panel-menu.done" 2>/dev/null)" = "ok" ]; }

panel_click_done() { [ "$(cat "$WORK/control/panel-click.done" 2>/dev/null)" = "ok" ]; }

# panel_off_rx_count — how many phone.panel off requests the fake has received.
panel_off_rx_count() {
    grep -F '"t":"phone.panel"' "$WORK/events.jsonl" 2>/dev/null | grep -cF '"off":true' || true
}

# panel_off_events — how many times the fake reported state.panel off (the hold
# is actually on: the person's screen is dark).
panel_off_events() { grep -cF '"ev":"panel","state":"off"' "$WORK/events.jsonl" 2>/dev/null || true; }


# panel_glyph_ms — the click -> glyph time the app recorded for its last panel
# click: `panel_click_at` is the control's own click, `panel_glyph_at` the
# `state.panel` that redrew the bar (host uptime ms, in the chrome state). -1
# until both are written.
panel_glyph_ms() {
    python3 - "$(chrome_state)" <<'PY'
import sys
fields = dict(part.split("=", 1) for part in sys.argv[1].split() if "=" in part)
try:
    print(int(fields["panel_glyph_at"]) - int(fields["panel_click_at"]))
except (KeyError, ValueError):
    print(-1)
PY
}

# last_frame_event — the last `frames` counter stream 1 reported (--frame-events).
last_frame_event() {
    python3 - "$WORK/events.jsonl" <<'FRAMES'
import json, sys
last = 0
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "frames" and e.get("stream") == 1:
        last = max(last, int(e.get("n") or 0))
print(last)
FRAMES
}

more_frame_events() { [ "$(last_frame_event)" -gt "$1" ]; }

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

# spotlight_line — the app's newest Spotlight line from the last three minutes:
# "spotlight: indexing N apps" is the attempt, "spotlight: verified N of M ..."
# the proof that a CSSearchQuery found the items back, "spotlight: unavailable"
# the door being shut on this build.
spotlight_line() {
    log show --last 3m --info \
        --predicate 'subsystem == "app.contigua.mac" AND process == "Contigua"' 2>/dev/null \
        | grep -o 'spotlight: [A-Za-z][^"]*' | tail -1
}

# spotlight_refusal — what corespotlightd said when it refused the client, so a
# failed check names the gate instead of guessing at our code.
spotlight_refusal() {
    log show --last 3m \
        --predicate 'process == "corespotlightd" AND eventMessage CONTAINS "Rejecting bundle ID"' 2>/dev/null \
        | grep -o 'Rejecting bundle ID.*' | tail -1
}

# check_spotlight — the fake phone's apps reach the Spotlight index and come
# back through a CSSearchQuery within 30 s. CoreSpotlight only returns a
# bundle the items of that bundle, and mdfind cannot see CoreSpotlight items at
# all (macos/scripts/spotlight-probe.swift shows both), so the app itself asks
# its index back and logs the count; that line is the proof. The attempt alone
# is not: an index that silently holds nothing looked green here for months.
check_spotlight() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 60
    # The index follows the app list, and the query back gets up to 30 s.
    await_app 45 eval 'grep -qE "spotlight: (verified|unavailable)" <<< "$(spotlight_line)"'
    local line found total
    line="$(spotlight_line)"
    case "$line" in
        "spotlight: verified "*)
            found="$(sed -n 's/^spotlight: verified \([0-9]*\) of .*/\1/p' <<< "$line")"
            total="$(sed -n 's/^spotlight: verified [0-9]* of \([0-9]*\) apps.*/\1/p' <<< "$line")"
            if [ -n "$found" ] && [ "$found" -ge 1 ]; then
                ok "[SPOT-1] a CSSearchQuery found $found of $total phone apps in the Spotlight index"
            else
                bad "[SPOT-1] the app indexed $total apps but found none of them back in the index"
            fi
            ;;
        "spotlight: unavailable"*)
            bad "[SPOT-2] CoreSpotlight refused this build (${line#spotlight: }); daemon: $(spotlight_refusal)"
            ;;
        *)
            bad "[SPOT-1] the app never confirmed its apps are in the index (last line: ${line:-none}); daemon: $(spotlight_refusal)"
            ;;
    esac
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
ok = actions == intents | {"ContiguaFocusFilter", "SetPhoneDNDIntent"} \
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
    [ "$(window_open_count com.android.settings)" = "1" ] \
        && ok "[WIN-2] INTENTS a second Open Phone App intent raised the window (one window.open)" \
        || bad "[WIN-2] INTENTS two intents sent $(window_open_count com.android.settings) window.open"

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
    local shim="$E2E_BUNDLE/Contents/Helpers/contigua-mcp"
    local support="$HOME/Library/Application Support/Contigua-$PROFILE"
    local sock="$support/mcp.sock"
    if [ ! -x "$shim" ]; then
        bad "MCP the bundle has no Contents/Helpers/contigua-mcp"
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
        if [ "$status" -ne 0 ] && grep -q "Turn on Settings › Automation in Contigua" "$WORK/shim-off.err"; then
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

# dnd_rx_at_least <n> — the fake phone has received at least n phone.dnd messages.
dnd_rx_at_least() { [ "$(dnd_rx_count)" -ge "$1" ]; }

# auth_count_at_least <n> — the fake phone has accepted at least n sessions
# (a drop and the Mac's reconnect is the second one; the fake's own memory, the
# DND mode and the panel hold, lives across them as the phone's service does).
auth_count_at_least() {
    local count
    count="$(grep -cF '"ev":"session","state":"open"' "$WORK/events.jsonl" 2>/dev/null || true)"
    [ "${count:-0}" -ge "$1" ]
}

# dnd_by_mac_count — how many DND changes the fake applied from a Mac command.
dnd_by_mac_count() { grep -cF '"byMac":true' "$WORK/events.jsonl" 2>/dev/null || true; }

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

# --- the person's own change on the phone wins (docs/specs/controls.md) ---

# check_dnd_edge — the person's report of 10-28: "Contigua keeps turning DND
# on after I turned it off on the phone". A Focus applies DND; the person turns
# it off on the phone; the session drops and comes back. The reconnect must send
# no phone.dnd (the Mac's memory already holds that value for this phone), and a
# change of the Mac-side intent still sends: the Focus ending, then a new Focus.
check_dnd_edge() {
    clean
    FAKE_ARGS="--dnd-person-after 2 --drop-after 8" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-focus "on priority" --quit-after 150
    if wait_until 25 dnd_is priority; then
        ok "[CTRL-2] the Focus started and the phone's DND came on (priority)"
    else
        bad "[CTRL-2] the Focus did not turn the phone's DND on"
    fi
    if wait_until 15 dnd_is off; then
        ok "[CTRL-4] the person turned DND off on the phone"
    else
        bad "[CTRL-4] the fake phone never reported the person's DND change"
    fi
    local sent
    sent="$(dnd_rx_count)"
    if wait_until 45 auth_count_at_least 2; then
        ok "[CTRL-3] the session dropped and the same phone reconnected"
    else
        bad "[CTRL-3] the fake phone never saw a second session (no reconnect)"
    fi
    sleep 4
    if [ "$(dnd_rx_count)" = "$sent" ]; then
        ok "[CTRL-3] the reconnect sent no phone.dnd (the stored intent was already applied)"
    else
        bad "[CTRL-3] the reconnect re-sent phone.dnd ($sent before, $(dnd_rx_count) after)"
    fi
    if dnd_is off; then
        ok "[CTRL-4] the phone stayed off across the reconnect"
    else
        bad "[CTRL-4] the reconnect turned the person's DND back on"
    fi
    stop_app

    # The Mac-side intent still applies on its edge: the Focus ends, then a new
    # Focus starts. Both are launches, which is also the Focus ending while the
    # phone and the app were apart.
    sent="$(dnd_rx_count)"
    launch --connect "127.0.0.1:$PORT" --debug-focus "off" --quit-after 60
    if wait_until 25 dnd_rx_at_least "$((sent + 1))"; then
        ok "[CTRL-2] the Focus ended and the Mac sent phone.dnd off"
    else
        bad "[CTRL-2] the Focus ended and no phone.dnd was sent"
    fi
    if wait_until 10 dnd_is off; then
        ok "[CTRL-4] the Focus end left the person's off in place (the restore rule)"
    else
        bad "[CTRL-4] the Focus end did not leave the phone off"
    fi
    stop_app
    sent="$(dnd_rx_count)"
    launch --connect "127.0.0.1:$PORT" --debug-focus "on priority" --quit-after 60
    if wait_until 25 dnd_rx_at_least "$((sent + 1))"; then
        ok "[CTRL-2] a new Focus start sent phone.dnd priority again"
    else
        bad "[CTRL-2] a new Focus start sent nothing"
    fi
    if wait_until 15 dnd_is priority; then
        ok "[CTRL-2] the phone took the new Focus (priority)"
    else
        bad "[CTRL-2] the new Focus did not reach the phone"
    fi
    stop_app
    stop_fakephone
}

# check_panel_edge — the second person report: "the phone screen sometimes goes
# black while an app window is mirrored and I'm using the phone". A hold the
# person ended with the phone's power button was re-asserted when the mirror
# reopened on a reconnect, from the Mac's remembered per-phone setting. The same
# edge rule applies: a person's wake stands until the person asks on the Mac.
check_panel_edge() {
    clean
    mkdir -p "$WORK/control"
    # The person's power press ends the hold 3 s after the request; the session
    # drops at 18 s, well after that press.
    FAKE_ARGS="--first-frame-delay 1 --panel-ends-after 3 --drop-after 18" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK/control" --quit-after 150
    if wait_until 20 chrome_has "loading=0"; then
        ok "[CTRL-6] the phone window opened with the panel on (nothing held)"
    else
        bad "[CTRL-6] the phone window never showed a frame ($(chrome_state))"
    fi
    # The person's Mac-side action: Phone ▸ Turn Off Phone Screen.
    printf 'panel-menu\n' > "$WORK/control/panel-menu.cmd"
    if ! wait_until 5 panel_menu_done; then
        bad "[CTRL-6] the menu item did not run: $(cat "$WORK/control/panel-menu.done" 2>/dev/null)"
        stop_app; stop_fakephone; return 1
    fi
    if wait_until 10 events_have '"ev":"panel","state":"off"'; then
        ok "[CTRL-6] Turn Off Phone Screen sent phone.panel off and the phone held it"
    else
        bad "[CTRL-6] the phone never held the panel"
    fi
    if wait_until 15 events_have '"ev":"panel","state":"on"'; then
        ok "[CTRL-5] the person's power press ended the hold on the phone"
    else
        bad "[CTRL-5] the person's power press did not end the hold"
    fi
    local sent held
    sent="$(panel_off_rx_count)"
    held="$(panel_off_events)"
    if wait_until 45 auth_count_at_least 2; then
        ok "[CTRL-5] the session dropped and the same phone reconnected"
    else
        bad "[CTRL-5] the fake phone never saw a second session (no reconnect)"
    fi
    sleep 4
    if [ "$(panel_off_rx_count)" = "$sent" ]; then
        ok "[CTRL-5] the reconnect and the reopened mirror did not ask for the panel again"
    else
        bad "[CTRL-5] the reopened mirror re-sent phone.panel off ($sent before, $(panel_off_rx_count) after)"
    fi
    if [ "$(panel_off_events)" = "$held" ]; then
        ok "[CTRL-5] the phone's own panel state stayed on across the reconnect"
    else
        bad "[CTRL-5] the phone went dark again after the person had turned the panel back on"
    fi
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
    FAKE_ARGS="--foreground-pkg com.example.maps --ignore-task-front" start_fake || return 1
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$PORT" --controls-dir "$WORK/controls" \
        --debug-control "$WORK-control" --quit-after 120
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
        && ok "CONTROLS dnd off restored the DND Contigua set" \
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

    # (2b) Panel P2: the Ringer module's menu chooses Vibrate, the volume slider
    # sends the phone's music stream, and the menu bar panel's gear opens the
    # icon's menu. The Settings…/Quit footer rows are gone: the icon's menu has
    # them (CONV-MAC-10).
    control panelopen || bad "CONTROLS panelopen: $CONTROL_REPLY"
    control paneldump panel "$WORK/controls-panel.json" || bad "CONTROLS paneldump: $CONTROL_REPLY"
    python3 - "$WORK/controls-panel.json" <<'PY' && ok "[PANEL-5] the panel is P2 with the gear first and Sound above the modules; [PANEL-26] no handoff row before the phone answers task.front" \
        || bad "[PANEL-5] the panel is not P2"
import json, sys
root = json.load(open(sys.argv[1]))
if root["width"] != 300:
    print("width:", root["width"]); sys.exit(1)
if not root["mapped"]:
    print("items:", len(root["items"]), "controls:", len(root["controls"])); sys.exit(1)
kinds = [row["kind"] for row in root["items"]]
if kinds[:6] != ["gear", "volume", "dnd", "ringer", "ring", "screen"]:
    print("items:", kinds); sys.exit(1)
if "installApk" in kinds:
    print("Install APK… is a card row again:", kinds); sys.exit(1)
rows = {row["kind"]: row for row in root["items"]}
if not rows["ringer"]["enabled"]:
    print("ringer:", rows["ringer"]); sys.exit(1)
if not rows["volume"]["enabled"]:
    print("volume:", rows["volume"]); sys.exit(1)
if not rows["gear"]["enabled"] or rows["gear"]["label"] != "Settings and more":
    print("gear:", rows["gear"]); sys.exit(1)
enabled = [row for row in root["items"] if row["enabled"]]
volume_index = next(i for i, row in enumerate(enabled) if row["kind"] == "volume")
volume = root["controls"][volume_index]
if volume["height"] > 20 or volume["width"] < 150:
    print("volume control:", volume); sys.exit(1)
PY
    python3 - "$WORK/controls-panel.json" <<'PY' && ok "[CONV-MAC-10] [PANEL-17] the panel has no Settings/Quit footer rows: they are the icon's menu" \
        || bad "[PANEL-17] the panel still carries footer rows"
import json, sys
root = json.load(open(sys.argv[1]))
kinds = [row["kind"] for row in root["items"]]
if "settings" in kinds or "quit" in kinds:
    print("items:", kinds); sys.exit(1)
PY
    # What a screen reader hears on the gear (CONV-MAC-21), read from the
    # accessibility tree: its name, a help tag naming the three commands, and
    # the gear first in the card's AX order — the key order `focusOrder` names.
    local gear_ax
    gear_ax="$(ax_tree)"
    case "$gear_ax" in
        *"desc=[Settings and more] help=[Settings, About and Quit] id=[panel.gear]"*)
            ok "[PANEL-21] the gear's VoiceOver name and help tag reach the AX tree: Settings and more · Settings, About and Quit" ;;
        NO-WINDOWS|"")
            bad "CONTROLS the AX tree is empty for this run ($gear_ax)" ;;
        *) bad "CONTROLS the gear's AX name and help are missing ($(printf '%s' "$gear_ax" | grep -m1 'panel.gear\|NO-WINDOWS' | cut -c1-200))" ;;
    esac
    case "$(printf '%s\n' "$gear_ax" | grep -v '^AXWindow' | head -1)" in
        *"id=[panel.gear]"*)
            ok "[PANEL-7] the gear is the card's first control in the AX order" ;;
        *) bad "[PANEL-7] the gear is not first in the AX order ($(printf '%s' "$gear_ax" | head -2 | tr '\n' '|' | cut -c1-200))" ;;
    esac
    control panelringer panel vibrate || bad "CONTROLS panelringer: $CONTROL_REPLY"
    wait_until 3 ringer_is vibrate \
        && ok "[PANEL-10] the Ringer tile's menu sent phone.ringer vibrate" \
        || bad "[PANEL-10] the Ringer tile's menu sent no phone.ringer vibrate"
    local volume_before
    volume_before="$(grep -c '"ev":"volume"' "$WORK/events.jsonl" 2>/dev/null || true)"
    control panelvolumedrag panel 0.2 "$WORK/controls-volume.json" \
        || bad "CONTROLS panelvolumedrag: $CONTROL_REPLY"
    python3 - "$WORK/controls-volume.json" <<'PY' && ok "[PANEL-13] the slider follows every drag step and ignores the phone echo mid-drag" \
        || bad "[PANEL-13] the slider did not follow the drag"
import json, sys
try:
    trace = json.load(open(sys.argv[1]))
except (OSError, ValueError) as error:
    print("no trace:", error); sys.exit(1)
steps = [row for row in trace if 1 <= row["step"] <= 10]
if len(steps) != 10:
    print("steps:", len(steps)); sys.exit(1)
for row in steps:
    if abs(row["display"] - row["target"]) > 0.04:
        print("step", row["step"], "showed", row["display"], "not", row["target"],
              "phone", row["phone"]); sys.exit(1)
if not any(abs(row["display"] - row["phone"]) > 0.02 for row in steps):
    print("no phone echo landed during the drag:", steps); sys.exit(1)
if abs(trace[-1]["display"] - 0.2) > 0.04:
    print("release showed", trace[-1]); sys.exit(1)
PY
    local volume_after volume_sends
    volume_after="$(grep -c '"ev":"volume"' "$WORK/events.jsonl" 2>/dev/null || true)"
    volume_sends=$(( ${volume_after:-0} - ${volume_before:-0} ))
    [ "$volume_sends" -ge 2 ] && [ "$volume_sends" -le 4 ] \
        && ok "[PANEL-13] the drag sent phone.volume $volume_sends times (throttled to 10/s plus the release)" \
        || bad "[PANEL-13] the drag sent phone.volume $volume_sends times, not the throttled count"
    wait_until 20 events_have '"ev":"volume","level":3' \
        && ok "[PANEL-13] the panel's volume slider sent phone.volume 3/15" \
        || bad "[PANEL-13] the panel's volume slider sent no phone.volume"
    control panelclose || bad "CONTROLS panelclose: $CONTROL_REPLY"

    # The Deck's popover compiles the same view without the footer.
    control deckpanel || bad "CONTROLS deckpanel: $CONTROL_REPLY"
    rm -f "$WORK/controls-deck-panel.json"
    local tries=20
    while [ "$tries" -gt 0 ]; do
        control paneldump deck "$WORK/controls-deck-panel.json" >/dev/null 2>&1 && break
        tries=$((tries - 1)); sleep 0.5
    done
    python3 - "$WORK/controls-deck-panel.json" <<'PY' && ok "[PANEL-18] the Deck popover has P2's modules and no Settings/Quit footer" \
        || bad "[PANEL-18] the Deck popover kept the menu bar footer"
import json, sys
try:
    root = json.load(open(sys.argv[1]))
except (OSError, ValueError) as error:
    print("no dump:", error); sys.exit(1)
kinds = [row["kind"] for row in root["items"]]
want = ["volume", "dnd", "ringer", "ring", "screen", "phoneScreen", "findApps"]
if kinds != want:
    print("items:", kinds); sys.exit(1)
if "settings" in kinds or "quit" in kinds:
    print("footer in the popover:", kinds); sys.exit(1)
PY
    control panelclose >/dev/null 2>&1
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
        ok "[MEDIA-8] C14 Mac received audio (config + >=10 frames)"
    else
        bad "C14 no audio at the Mac: $(cat "$WORK/audio.json" 2>/dev/null || echo 'no stats file')"
    fi
    python3 - "$WORK/audio.json" <<'PY' && ok "[MEDIA-9] C14 AAC 48k stereo tone" || bad "C14 unexpected audio format: $(cat "$WORK/audio.json" 2>/dev/null)"
import json, sys
stats = json.load(open(sys.argv[1]))
assert stats.get("codec") == 3, stats
assert stats.get("sampleRate") == 48000, stats
assert stats.get("channels", 2) == 2, stats
PY
    grep -q '"t":"audio.start"' "$WORK/events.jsonl" \
        && ok "[MEDIA-8] C14 audio.start sent" || bad "C14 no audio.start in phone log"
    grep -q '"ev":"audio"' "$WORK/events.jsonl" \
        && ok "[MEDIA-8] C14 phone streamed audio" || bad "C14 no audio event in phone log"
    stop_app
    stop_fakephone
}

# --- C9: no leftovers -----------------------------------------------------

# check_clip — plain-text clipboard sync both ways (docs/PROTOCOL.md "Clipboard
# sync"). A fresh profile shares nothing until the person turns the switch on
# (AGENTS.md: sharing is opt-in): the phone's clip at welcome is not applied and
# the Mac's own copy is not sent. With the switch on, the fakephone sends
# pd-clip-1 right after welcome: the Mac's pasteboard must show it, and the Mac
# must not send it back. Then the Mac copies pd-clip-2 and the fakephone must log
# it. The person's pasteboard is saved first and put back when this check
# returns, failures included (text only: other types are lost).
check_clip() {
    clean
    local saved="$WORK/pasteboard.saved"
    pbpaste > "$saved" 2>/dev/null
    trap 'pbcopy < "$saved"; trap - RETURN' RETURN

    clip_is() { [ "$(pbpaste)" = "$1" ]; }
    authenticated() { events_have '"state":"auth_ok"' || events_have '"state":"paired"'; }

    # (a) A fresh profile: the setting is off by default, so nothing travels in
    # either direction — neither what the phone already had nor a later copy.
    # The Mac tells the phone its switch is off (SHARE-13); the phone's own copy
    # after that never reaches the wire.
    printf '%s' pd-clip-0 | pbcopy
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --events "$WORK/events.jsonl" --state "$WORK/state.json" \
        --clip-on-welcome pd-clip-1 --clip-copy pd-clip-3 --clip-copy-after 6 \
        > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" && break
        sleep 0.25
    done
    grep -q "listening" "$WORK/fake.log" || { bad "CLIP fakephone did not start"; return 1; }

    launch --connect "127.0.0.1:$PORT" --quit-after 60
    wait_until 30 authenticated \
        || bad "CLIP the app never authenticated on a fresh profile"
    wait_until 20 events_have '"dir":"gate","on":false' \
        && ok "[SHARE-13] CLIP the Mac told the phone its switch is off" \
        || bad "[SHARE-13] CLIP the phone was never told the switch is off"
    clip_is pd-clip-0 \
        && ok "[SHARE-13] CLIP a fresh profile applies nothing: pd-clip-1 never landed" \
        || bad "[SHARE-13] CLIP a fresh profile applied the phone's clip ('$(pbpaste)')"
    printf '%s' pd-clip-2 | pbcopy
    sleep 4
    ! events_have '"dir":"rx","text":"pd-clip-2"' \
        && ok "[SHARE-13] CLIP a fresh profile sends nothing: the Mac's copy never reached the phone" \
        || bad "[SHARE-13] CLIP a fresh profile sent pd-clip-2 to the phone"
    wait_until 20 events_have '"dir":"suppressed"' \
        && ok "[SHARE-13] CLIP the phone kept its later copy: a suppressed copy, no clip.set" \
        || bad "[SHARE-13] CLIP the phone's copy after the gate went off was not suppressed"
    ! events_have '"dir":"rx","text":"pd-clip-3"' \
        && ok "[SHARE-13] CLIP no clip.set for the copy made after the gate went off" \
        || bad "[SHARE-13] CLIP the phone sent pd-clip-3 with the gate off"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # (b) The person turns the switch on in Settings ▸ General: the phone is told
    # again, and both directions work.
    defaults write "$DEFAULTS_SUITE" shareClipboard -bool true
    printf '%s' pd-clip-0 | pbcopy
    "$FAKE_PY" "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --events "$WORK/events.jsonl" --state "$WORK/state.json" \
        --clip-copy pd-clip-1 --clip-copy-after 3 > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" && break
        sleep 0.25
    done
    grep -q "listening" "$WORK/fake.log" || { bad "CLIP fakephone did not start"; return 1; }

    launch --connect "127.0.0.1:$PORT" --quit-after 90
    wait_until 20 events_have '"dir":"gate","on":true' \
        && ok "[SHARE-13] CLIP turning the switch on tells the phone again" \
        || bad "[SHARE-13] CLIP the phone never heard the switch turn on"
    wait_until 30 clip_is pd-clip-1 \
        && ok "[SHARE-1] CLIP phone -> Mac: pbpaste shows pd-clip-1" \
        || bad "[SHARE-1] CLIP pbpaste shows '$(pbpaste)', not pd-clip-1"
    sleep 2
    ! events_have '"dir":"rx","text":"pd-clip-1"' \
        && ok "[SHARE-1] CLIP the Mac does not send pd-clip-1 back" \
        || bad "[SHARE-1] CLIP the Mac echoed pd-clip-1 to the phone"

    printf '%s' pd-clip-2 | pbcopy
    wait_until 30 events_have '"dir":"rx","text":"pd-clip-2"' \
        && ok "[SHARE-1] CLIP Mac -> phone: fakephone logs clip.set pd-clip-2" \
        || bad "[SHARE-1] CLIP fakephone did not log clip.set pd-clip-2"

    # A Finder copy carries the file's name as text next to its URL (SHARE-2).
    # The name must never reach the phone; a non-image file sends nothing.
    printf 'Contigua e2e fixture' > "$WORK/pd-finder-copy.txt"
    PD_PB_PATH="$WORK/pd-finder-copy.txt" xcrun swift -e '
import AppKit
let path = ProcessInfo.processInfo.environment["PD_PB_PATH"]!
let board = NSPasteboard.general
board.clearContents()
let item = NSPasteboardItem()
item.setString((path as NSString).lastPathComponent, forType: .string)
item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
board.writeObjects([item])
' >/dev/null 2>&1 \
        && ok "[SHARE-2] CLIP wrote a Finder-style file copy" \
        || bad "[SHARE-2] CLIP could not write a Finder-style file copy"
    sleep 3
    ! events_have '"dir":"rx","text":"pd-finder-copy.txt"' \
        && ok "[SHARE-2] CLIP a Finder file copy never sends its name as text" \
        || bad "[SHARE-2] CLIP a Finder file copy sent its name to the phone"

    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    defaults delete "$DEFAULTS_SUITE" shareClipboard >/dev/null 2>&1
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
        && ok "[SHARE-4] SHAREIN url -> the Mac would open https://example.com/sharein" \
        || bad "[SHARE-4] SHAREIN no 'would open https://example.com/sharein' in the share log"
    wait_until 30 saved_image && [ "$(shasum -a 256 < "$dir/pd-share.png" | cut -d' ' -f1)" = "$(shasum -a 256 < "$image" | cut -d' ' -f1)" ] \
        && ok "[SHARE-5] SHAREIN image -> share dir has pd-share.png with the same sha256" \
        || bad "[SHARE-5] SHAREIN image missing or different in $dir ($(ls -a "$dir" 2>/dev/null | tr '\n' ' '))"
    wait_until 30 clip_is pd-share-text-1 \
        && ok "[SHARE-4] SHAREIN text -> pbpaste shows pd-share-text-1" \
        || bad "[SHARE-4] SHAREIN pbpaste shows '$(pbpaste)', not pd-share-text-1"
    log_has "notify Copied from FakePhone: file:///etc/hosts" && ! log_has "would open file:" \
        && ok "[SHARE-4] SHAREIN a file: URL is copied as text, never opened" \
        || bad "[SHARE-4] SHAREIN file: URL handling wrong: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    log_has "notify Image from FakePhone: pd-share.png" \
        && ok "[SHARE-4] SHAREIN notifications recorded (Copied from / Image from FakePhone)" \
        || bad "[SHARE-4] SHAREIN no image notification in the share log"
    sleep 2
    ! events_have '"dir":"rx","text":"pd-share-text-1"' \
        && ok "[SHARE-1] SHAREIN the shared text is not echoed back as clip.set" \
        || bad "[SHARE-1] SHAREIN the Mac echoed the shared text to the phone"
    [ -z "$(ls -A "$dir" | grep '^\.')" ] \
        && ok "[SHARE-5] SHAREIN no partial files left in the share dir" \
        || bad "[SHARE-5] SHAREIN leftovers in $dir: $(ls -A "$dir" | tr '\n' ' ')"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# check_links — links Mac -> phone (docs/design/links.md). A contigua://open URL
# goes to the running e2e app, which sends link.open: the fakephone logs it and a
# stream window opens with video. A file: link is refused on the Mac and never
# reaches the phone. `open -a` names the e2e bundle so LaunchServices cannot hand the
# URL to another Contigua copy; the check first makes sure LaunchServices knows the
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

    open_quiet -a "$E2E_BUNDLE" "contigua://open?url=https%3A%2F%2Fexample.com"
    wait_until 30 link_logged "https://example.com" \
        && ok "[SHARE-8] LINKS fakephone logs link.open https://example.com" \
        || bad "[SHARE-8] LINKS fakephone did not log link.open https://example.com"
    wait_until 30 stream_video && wait_until 15 windows_at_least 2 \
        && ok "[SHARE-8] LINKS a stream window opened with video ($(windows | wc -l | tr -d ' ') windows)" \
        || bad "[SHARE-8] LINKS no stream window/video for the link"
    local link_want="$((900 * RUN_SCALE))x$((600 * RUN_SCALE))"
    wait_until 5 [ "$(rx_size link.open)" = "$link_want" ] \
        && ok "[WIN-5] LINKS the link window asked for its 900x600 pt stream ($link_want)" \
        || bad "[WIN-5] LINKS link.open asked for $(rx_size link.open), not $link_want"

    open_quiet -a "$E2E_BUNDLE" "contigua://open?url=file%3A%2F%2F%2Fetc%2Fhosts"
    sleep 3
    ! events_have 'file:///etc/hosts' \
        && ok "[SHARE-7] LINKS a file: link never reaches the phone" \
        || bad "[SHARE-7] LINKS the Mac sent a file: link to the phone"

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] && ! pgrep -fx "$APP" >/dev/null \
        && ok "[SHARE-9] LINKS the URL went to the running e2e app (one instance)" \
        || bad "[SHARE-9] LINKS open started another Contigua instance"
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
        --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
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
    launch --connect "127.0.0.1:$PORT" ${requests[@]+"${requests[@]}"} --quit-after 300

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
            && ok "[FILES-16] APK fakephone got tiny.apk with a matching sha256 (${want:0:12}…)" \
            || bad "[FILES-16] APK sha256 mismatch: $event (want $want)"
    else
        bad "APK fakephone never received the install"
    fi
    wait_until 15 log_has "apk: phone received all" && log_has "apk: sending 1 part(s)" \
        && ok "[FILES-16] APK progress shown ($(apk_log | grep -m1 'apk: sending'); $(apk_log | grep -m1 'received all'))" \
        || bad "[FILES-16] APK no progress logged: $(apk_log | tail -3)"
    # The result's sentence names the app and is private (CONV-PD-05); the log's
    # closed code says what happened, and ApkInstallMessage's wording is K2's
    # (ApkBundleTests).
    wait_until 15 log_has "apk: result ok: installed" \
        && ok "[FILES-18] APK result: the install finished (ok)" \
        || bad "[FILES-18] APK no success result: $(apk_log | tail -2)"
    apps_refreshed() { [ "$(apps_lists)" -gt "$before" ]; }
    wait_until 10 apps_refreshed \
        && ok "[FILES-18] APK the app list was refreshed after the install" \
        || bad "[FILES-18] APK no apps.list after the install"

    open_apk "$WORK/old.apk"
    wait_until 30 log_has "apk: result failed: INSTALL_FAILED_VERSION_DOWNGRADE" \
        && ok "[FILES-18] APK downgrade failure: the phone's INSTALL_FAILED_VERSION_DOWNGRADE code" \
        || bad "[FILES-18] APK no downgrade result: $(apk_log | tail -2)"

    open_apk "$WORK/bundle.apks"
    if wait_until 30 apk_found 2 ok; then
        event="$(apk_event 2 ok)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); f=e["files"]; sys.exit(0 if [x["name"] for x in f]==["base-master.apk","base-arm64_v8a.apk"] and all(x["match"] for x in f) else 1)' \
            && ok "[FILES-16] APK .apks sent base + split, both sha256 match" \
            || bad "[FILES-16] APK .apks parts wrong: $event"
    else
        bad "APK the .apks install never arrived"
    fi

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] \
        && ok "[FILES-16] APK the files went to the running e2e app (one instance)" \
        || bad "[FILES-16] APK open started another Contigua instance"

    # FILES-16: the phone is paired but away. The install waits, on screen,
    # with Cancel, and lands when the link returns.
    apk_ax() { ax_tree; }
    stop_fakephone
    wait_until 5 no_fakephone
    sleep 2
    open_apk "$WORK/tiny.apk"
    wait_until 20 eval 'apk_ax | grep -qF "Waiting for your phone…"' \
        && ok "[FILES-16] APK a paired phone that is away shows the Waiting phase" \
        || bad "[FILES-16] APK no Waiting phase while the phone is away"
    apk_ax | grep -qF "Connect your phone to install apps on it." \
        && ok "[FILES-16] APK the sentence names the connection, not pairing again" \
        || bad "[FILES-16] APK the offline sentence: $(apk_ax | grep -i 'install apps' | head -1)"
    start_fake || return 1
    wait_until 60 eval 'events_have "\"state\":\"auth_ok\"" || events_have "\"state\":\"paired\""' \
        && ok "[FILES-16] APK the Mac reconnected when the phone came back" \
        || bad "[FILES-16] APK the Mac never reconnected after the phone returned"
    wait_until 90 apk_found 1 ok \
        && ok "[FILES-16] APK the waiting install proceeded when the phone came back" \
        || bad "[FILES-16] APK the waiting install never landed ($(grep -c '"ev":"apk"' "$WORK/events.jsonl" 2>/dev/null || echo 0) apk events; pill: $(apk_ax | grep -iE 'install|waiting|phone' | head -3 | tr '\n' '|'))"

    # Cancel in the waiting phase drops the file: nothing is sent later.
    stop_fakephone
    wait_until 5 no_fakephone
    sleep 2
    open_apk "$WORK/tiny.apk"
    wait_until 20 eval 'apk_ax | grep -qF "Waiting for your phone…"' \
        && ok "[FILES-16] APK Cancel is available while waiting" \
        || bad "[FILES-16] APK no Waiting phase for the Cancel case"
    "$AXDUMPBIN" "$APP_PID" --press Cancel > "$WORK/apk-cancel.txt" 2>&1 \
        && ok "[FILES-16] APK the waiting pill's Cancel was pressed" \
        || bad "[FILES-16] APK the Cancel press: $(head -2 "$WORK/apk-cancel.txt" | tr '\n' ' ')"
    wait_until 10 eval 'apk_ax | grep -qF "Install cancelled."' \
        && ok "[FILES-16] APK Cancel says the install was cancelled" \
        || bad "[FILES-16] APK Cancel left the waiting phase up"
    start_fake || return 1
    sleep 8
    ! apk_found 1 ok \
        && ok "[FILES-16] APK a cancelled waiting install never reaches the phone" \
        || bad "[FILES-16] APK the cancelled install landed on the phone"
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
# Android's transient entries, inside a folder: never listed, never digested.
open(os.path.join(root, "DCIM/Camera/.trashed-abc"), "wb").write(b"trashed")
open(os.path.join(root, "DCIM/Camera/.pending-def"), "wb").write(b"pending")
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
        "listall DCIM/Camera" "digest DCIM/Camera" "digest big3.bin" \
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

def visible(path):
    return sorted((name for name in os.listdir(path)
                   if not name.startswith(".trashed-")
                   and not name.startswith(".pending-")
                   and not (name.startswith(".contigua-") and name.endswith(".part"))),
                  key=lambda name: name.encode("utf-8"))

def independent_digest(path):
    """docs/PROTOCOL.md's digest, computed without the phone: 16 bytes of
    SHA-256 over `name \\0 ino \\0 size \\0 mtime \\n` in name-byte order."""
    digest = hashlib.sha256()
    for name in visible(path):
        info = os.lstat(os.path.join(path, name))
        size = 0 if os.path.isdir(os.path.join(path, name)) else info.st_size
        digest.update(name.encode("utf-8")); digest.update(b"\0")
        digest.update(str(info.st_ino).encode("ascii")); digest.update(b"\0")
        digest.update(str(size).encode("ascii")); digest.update(b"\0")
        digest.update(str(info.st_mtime_ns // 1000000).encode("ascii")); digest.update(b"\n")
    return digest.hexdigest()[:32]

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
       "[FILES-5] FILES the root listing has every visible name and size (%d items, hidden/Android "
       "left out)" % len(got))

# 2. Paging over a 1500-file folder: every name exactly once.
pages = listings("many")
names = [item["n"] for page in pages for item in page.get("items", [])]
want = {h("m%04d.txt" % i) for i in range(1500)}
report(len(pages) >= 2 and len(names) == 1500 and len(set(names)) == 1500 and set(names) == want,
       "[FILES-6] FILES paging read all 1500 names exactly once in %d pages" % len(pages))

# 3. stat.
stat = next((line for line in lines if line.get("op") == "stat" and line.get("ok")), None)
report(bool(stat) and stat["s"] == 3 * 1024 * 1024 and stat["d"] == 0
       and stat["p"] == h("big3.bin"),
       "[FILES-6] FILES stat reports big3.bin as a 3 MiB file")

# 4. The refused paths.
denied = [failure(".."), failure("/sdcard"), failure("Android/data")]
report(denied == ["fs_denied"] * 3,
       "[FILES-5] FILES '..', an absolute path and Android/data answer fs_denied (%s)" % denied)

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
           "[FILES-7] FILES %s read back byte-identical (%d bytes, sha %s...)" % (name, size, want[:12]))

read_ok("big3.bin", 3 * 1024 * 1024)
read_ok("big32.bin", 32 * 1024 * 1024)

# 6. A stale etag is refused and leaves no file.
report(failure("big32.bin", op="read") == "fs_stale"
       and not os.path.exists(os.path.join(work, "stale.bin")),
       "[FILES-7] FILES a stale etag answers fs_stale and writes nothing")

# 6b. FILES-35: the listing and the digest both leave Android's transient names
# out, and the phone's digest is the documented hash (checked against the bytes
# the harness computes itself).
camera = os.path.join(root, "DCIM", "Camera")
names = [item["n"] for page in listings("DCIM/Camera") for item in page.get("items", [])]
want_names = {h(name) for name in visible(camera)}
report(len(names) == len(want_names) and set(names) == want_names,
       "[FILES-35] FILES the listing leaves the transient names out (%d items)" % len(names))
digest_line = next((line for line in lines if line.get("op") == "digest"
                    and line.get("ok") and line.get("p") == h("DCIM/Camera")), None)
report(digest_line is not None and digest_line.get("digest") == independent_digest(camera),
       "[FILES-35] FILES the phone's digest is the documented hash over the visible entries")
report(failure("big3.bin", op="digest") == "fs_not_found",
       "[FILES-35] FILES a file answers not_found for its digest")

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
       "[FILES-7] FILES the cancelled read stopped on the phone (cancel after %d chunks, %d chunk "
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
# Downloads/Contigua (a chunk holding PD_FAKE_DOWNSIZE trips the 200 MiB rule).
# Clipboard images have no DebugInput action, so nothing is scripted for them.
drop_log() {
    log show --last 3m --info \
        --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
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
# SHARE-17: one app-window drop with a target, one Deck drop without, and the
# three files a Finder copy + ⌘V turns into one batch.
with open(os.path.join(work, "drop-target.bin"), "wb") as f:
    f.write(b"target" + os.urandom(1024))
with open(os.path.join(work, "deck-drop.bin"), "wb") as f:
    f.write(b"deck" + os.urandom(1024))
for index in range(1, 4):
    with open(os.path.join(work, "paste-%d.txt" % index), "wb") as f:
        f.write(("paste %d" % index).encode())
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
    # drop_start_event <name> - the first `drop.start` for that file.
    drop_start_event() {
        python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
name = sys.argv[2]
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "drop.start" and e.get("name") == name:
        print(json.dumps(e))
        sys.exit(0)
sys.exit(1)
PY
    }
    drop_start_found() { drop_start_event "$@" >/dev/null; }
    # batch_starts - the three ⌘V files each name the window and their i of 3.
    batch_starts() {
        python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
seen = {}
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "drop.start" and str(e.get("name", "")).startswith("paste-"):
        seen[e["name"]] = (e.get("target"), e.get("index"), e.get("count"))
want = {"paste-%d.txt" % i: ("com.android.settings", i, 3) for i in range(1, 4)}
sys.exit(0 if seen == want else 1)
PY
    }
    batch_results() {
        python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
ok = set()
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "drop" and e.get("ok") and e.get("files"):
        ok.add(e["files"][0].get("name"))
sys.exit(0 if {"paste-%d.txt" % i for i in (1, 2, 3)} <= ok else 1)
PY
    }
    log_has() { drop_log | grep -qF -- "$1"; }
    fake_log_has() { grep -qF -- "$1" "$WORK/fake.log" "$WORK/fake.err" 2>/dev/null; }

    # The waits keep the drops apart: FileDropSender takes one file at a time
    # and would refuse the next while the one before is still in flight.
    printf '%s\n' "dropfile $WORK/drop-32mb.bin" "wait 20" \
        "dropfile $WORK/drop-3mb.bin" "wait 8" "dropfile $WORK/tripped.bin" "wait 12" \
        "dropfile $WORK/drop-target.bin" "wait 10" \
        "deckdrop $WORK/deck-drop.bin" "wait 8" \
        "pastefiles $WORK/paste-1.txt $WORK/paste-2.txt $WORK/paste-3.txt" \
        "keyraw cmd+v" "wait 20" \
        > "$WORK/drop.txt"
    open_shared --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
        --debug-input-script "$WORK/drop.txt" || return 1

    local event want
    # The 32 MiB drop with the late tail confirmation: every byte exactly once.
    if wait_until 90 drop_found drop-32mb.bin ok; then
        event="$(drop_event drop-32mb.bin ok)"
        want="$(shasum -a 256 "$WORK/drop-32mb.bin" | cut -c1-64)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); f=e["files"]; sys.exit(0 if len(f)==1 and f[0]["name"]=="drop-32mb.bin" and f[0]["size"]==32*1024*1024 and f[0]["match"] and f[0]["sha256"]==sys.argv[1] else 1)' "$want" \
            && ok "[FILES-13] DROP fakephone got drop-32mb.bin (32 MiB) with a matching sha256 (${want:0:12}…)" \
            || bad "[FILES-13] DROP 32 MiB sha256/size mismatch: $event (want $want)"
    else
        bad "DROP fakephone never received the 32 MiB file"
    fi
    wait_until 30 fake_log_has "33554432 bytes (drop-32mb.bin) -> sha ok" \
        && ok "[FILES-13] DROP fakephone received all 33554432 bytes over DROP_DATA" \
        || bad "[FILES-13] DROP fakephone did not log the full 32 MiB: $(grep -i drop "$WORK/fake.log" "$WORK/fake.err" | tail -3)"
    # The late confirmation must not have moved the sender back into the file.
    sleep 1
    if fake_log_has "more bytes than announced"; then
        bad "[FILES-13] DROP the sender re-sent bytes after EOF: $(grep -h 'more bytes than announced' "$WORK/fake.log" "$WORK/fake.err" | tail -2)"
    else
        ok "[FILES-13] DROP no tail re-send: received bytes == announced bytes"
    fi

    if wait_until 60 drop_found drop-3mb.bin ok; then
        event="$(drop_event drop-3mb.bin ok)"
        want="$(shasum -a 256 "$WORK/drop-3mb.bin" | cut -c1-64)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); f=e["files"]; sys.exit(0 if len(f)==1 and f[0]["name"]=="drop-3mb.bin" and f[0]["size"]==3*1024*1024 and f[0]["match"] and f[0]["sha256"]==sys.argv[1] else 1)' "$want" \
            && ok "[FILES-13] DROP fakephone got drop-3mb.bin (3 MB) with a matching sha256 (${want:0:12}…)" \
            || bad "[FILES-13] DROP sha256/size mismatch: $event (want $want)"
    else
        bad "DROP fakephone never received the file"
    fi
    # The log carries the size and a closed outcome, never the file's name
    # (CONV-PD-05); the sentence the pill shows is pinned by K2 (FileDropTests).
    wait_until 15 log_has "drop: sending 3145728 bytes" \
        && ok "[FILES-13] DROP the window's handler announced the file's 3145728 bytes" \
        || bad "[FILES-13] DROP no drop: sending line: $(drop_log | tail -3)"
    wait_until 15 log_has "drop: ok: saved" \
        && ok "[FILES-13] DROP result: the phone saved the file" \
        || bad "[FILES-13] DROP no success result: $(drop_log | tail -2)"
    # No chunk leaves before the phone's opening drop.progress (the sender waits for
    # it), so the whole file arriving proves the progress message was parsed; the
    # byte count is the wire's DROP_DATA total.
    wait_until 15 fake_log_has "3145728 bytes (drop-3mb.bin) -> sha ok" \
        && ok "[FILES-13] DROP fakephone received all 3145728 bytes over DROP_DATA" \
        || bad "[FILES-13] DROP fakephone did not log the full 3 MB: $(grep -i drop "$WORK/fake.log" | tail -2)"

    if wait_until 60 drop_found tripped.bin bad; then
        event="$(drop_event tripped.bin bad)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); sys.exit(0 if e["code"]=="too_large" and not e["files"][0].get("match") else 1)' \
            && ok "[FILES-15] DROP the over-cap trip answered ok=false too_large" \
            || bad "[FILES-15] DROP the negative event is wrong: $event"
    else
        bad "DROP the PD_FAKE_DOWNSIZE trip never reached fakephone"
    fi
    wait_until 15 log_has "drop: failed: too_large" \
        && ok "[FILES-15] DROP the refusal is the phone's too_large code" \
        || bad "[FILES-15] DROP no refusal result: $(drop_log | tail -2)"

    # B1: the outcome pill is not a fixture of the window. The sender's own
    # timeout is the only hide (5 s), so the chrome state must show the outcome
    # and then nothing about a second later.
    if chrome_has "drop_pill=shown"; then
        ok "[FILES-14] DROP the outcome pill is on the window after the drop (state: $(chrome_state))"
    else
        bad "[FILES-14] DROP no drop pill on the window after the drop (state: $(chrome_state))"
    fi
    if wait_until 7 chrome_has "drop_pill=hidden"; then
        ok "[FILES-14] DROP the outcome pill hid after the transfer's 5 s timeout (state: $(chrome_state))"
    else
        bad "[FILES-14] DROP the outcome pill was still on the window 7 s after the outcome (state: $(chrome_state))"
    fi

    # SHARE-17: the app window's package rides drop.start; the Deck's drop is
    # the same path with no target. The dropped file's own fields are 1 of 1.
    if wait_until 40 drop_start_found drop-target.bin; then
        event="$(drop_start_event drop-target.bin)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); sys.exit(0 if e.get("target")=="com.android.settings" and e.get("index")==1 and e.get("count")==1 else 1)' \
            && ok "[SHARE-17] DROP an app window's drop names its package (index 1 of 1)" \
            || bad "[SHARE-17] DROP the app window's target/batch is wrong: $event"
    else
        bad "[SHARE-17] DROP no drop.start for the app-window drop"
    fi
    if wait_until 40 drop_start_found deck-drop.bin; then
        event="$(drop_start_event deck-drop.bin)"
        echo "$event" | python3 -c 'import json,sys; e=json.load(sys.stdin); sys.exit(0 if e.get("target") is None and e.get("index")==1 and e.get("count")==1 else 1)' \
            && ok "[SHARE-17] DROP a Deck drop carries no target (the chooser stays)" \
            || bad "[SHARE-17] DROP the Deck drop named a target: $event"
    else
        bad "[SHARE-17] DROP no drop.start for the Deck drop"
    fi
    if wait_until 60 batch_starts; then
        ok "[SHARE-17] DROP ⌘V with a 3-file copy sent 3 drop.start with target and i of 3"
    else
        bad "[SHARE-17] DROP the ⌘V batch did not send 3 drop.start: $(grep -h 'drop.start' "$WORK/events.jsonl" | tail -3)"
    fi
    wait_until 30 batch_results \
        && ok "[SHARE-17] DROP the phone saved all 3 files of the ⌘V batch" \
        || bad "[SHARE-17] DROP not every ⌘V file got a successful drop.result"

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] \
        && ok "DROP the app survived the failed drop (one instance)" \
        || bad "DROP the app died or a second instance appeared"
    stop_app
}

# check_drop_sources — SHARE-18 (docs/design/dragdrop.md): a drag carrying image
# data and one carrying an http(s) link become files for the existing drop path;
# a text/html answer refuses with the spec's copy and the drop pill. The refusal
# is captured light and dark for review. A file promise needs a real
# NSFilePromiseReceiver, which the scripted input cannot make: K2 covers both
# delivery and the 30 s silence.
check_drop_sources() {
    clean
    local shots="$ROOT/.work/paste-drop"
    mkdir -p "$shots"
    python3 - "$WORK" <<'PY'
import os, struct, sys, zlib
work = sys.argv[1]
serve = os.path.join(work, "http")
os.makedirs(serve, exist_ok=True)
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
rows = b"".join(b"\x00" + bytes((x * 7 + y * 13) % 256 for x in range(32 * 3)) for y in range(32))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(os.path.join(serve, "source.png"), "wb").write(png)
open(os.path.join(serve, "page.html"), "w").write("<html><body>not an image</body></html>")
PY
    local http_port
    http_port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
    ( cd "$WORK/http" && python3 -m http.server "$http_port" --bind 127.0.0.1 \
        > "$WORK/http.log" 2>&1 ) &
    local http_pid=$!
    trap 'kill $http_pid 2>/dev/null; wait $http_pid 2>/dev/null; trap - RETURN' RETURN
    python3 - "$http_port" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
for _ in range(100):
    s = socket.socket(); s.settimeout(0.1)
    try:
        s.connect(("127.0.0.1", port)); s.close(); sys.exit(0)
    except OSError:
        time.sleep(0.05)
    finally:
        s.close()
sys.exit(1)
PY
    [ $? = 0 ] || { bad "DROP-SOURCES: the local server did not start"; return 1; }

    drop_named() {
        python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
name = sys.argv[2]
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "drop" and e.get("ok") and e.get("files") \
            and e["files"][0].get("name") == name:
        print(json.dumps(e)); sys.exit(0)
sys.exit(1)
PY
    }
    drop_has() { drop_named "$1" >/dev/null; }
    no_drop_named() { ! drop_named "$1" >/dev/null; }
    png_size() { wc -c < "$WORK/http/source.png" | tr -d ' '; }

    # phase APPEARANCE TAG
    drop_sources_phase() {
        local appearance="$1" tag="$2"
        rm -f "$WORK/events.jsonl" "$WORK/chrome.txt"
        FAKE_ARGS="" start_fake || return 1
        printf '%s\n' \
            "dropimage $WORK/http/source.png" "wait 8" \
            "dropurl http://127.0.0.1:$http_port/source.png" "wait 5" \
            "dropurl http://127.0.0.1:$http_port/page.html" "wait 2" \
            > "$WORK/drop-sources.txt"
        launch --connect "127.0.0.1:$PORT" --appearance "$appearance" \
            --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
            --debug-input-script "$WORK/drop-sources.txt"
        if ! wait_until 30 chrome_has "frame="; then
            bad "DROP-SOURCES $tag: no app window"; stop_app; stop_fakephone; return 1
        fi
        local size
        size="$(png_size)"
        if wait_until 40 drop_has "Image.png"; then
            drop_named "Image.png" | python3 -c 'import json,sys; f=json.load(sys.stdin)["files"][0]; sys.exit(0 if f.get("mime")=="image/png" and f.get("size")==int(sys.argv[1]) else 1)' "$size" \
                && ok "[SHARE-18] DROP-SOURCES $tag: image data became Image.png (${size} bytes, image/png)" \
                || bad "DROP-SOURCES $tag: Image.png has the wrong size or MIME"
        else
            bad "DROP-SOURCES $tag: the phone never received Image.png"
        fi
        if wait_until 40 drop_has "source.png"; then
            drop_named "source.png" | python3 -c 'import json,sys; f=json.load(sys.stdin)["files"][0]; sys.exit(0 if f.get("mime")=="image/png" and f.get("size")==int(sys.argv[1]) else 1)' "$size" \
                && ok "[SHARE-18] DROP-SOURCES $tag: the link's image became source.png (${size} bytes, image/png)" \
                || bad "DROP-SOURCES $tag: source.png has the wrong size or MIME"
        else
            bad "DROP-SOURCES $tag: the phone never received the image link"
        fi
        if wait_until 30 chrome_has "drop_refusal=not_image"; then
            chrome_has "drop_pill=shown" \
                && ok "[SHARE-18] DROP-SOURCES $tag: a text/html answer showed the refusal pill" \
                || bad "DROP-SOURCES $tag: the refusal token has no pill"
            screenshot 900 "$shots/drop-refusal-$tag.png" \
                && ok "[SHARE-18] DROP-SOURCES $tag: refusal screenshot" \
                || bad "DROP-SOURCES $tag: no refusal screenshot"
        else
            bad "DROP-SOURCES $tag: no not_image refusal (state: $(chrome_state))"
        fi
        no_drop_named "page.html" \
            && ok "[SHARE-18] DROP-SOURCES $tag: the text/html answer sent no file" \
            || bad "DROP-SOURCES $tag: the text/html answer was sent as a file"
        stop_app
        stop_fakephone
        wait_until 5 no_fakephone
    }

    for spec in ${PD_E2E_DROP_SOURCE_PHASES:-light dark}; do
        drop_sources_phase "$spec" "$spec"
    done

    say "screenshots: $shots/drop-refusal-{light,dark}.png"
}

# check_paste — ⌘V with an image (SHARE-16, docs/design/dragdrop.md). The image
# goes to the phone as clip.image.*; the fake's `clip.image.done` is the gate for
# exactly one KEY 279 (no meta). Without an answer the timeout sends no key and
# shows the failure pill. The three pill states are captured light and dark for
# review (the pasteboard is saved and put back, text only, as check_clip does).
check_paste() {
    clean
    local saved="$WORK/pasteboard.saved" shots="$ROOT/.work/paste-drop"
    mkdir -p "$shots"
    pbpaste > "$saved" 2>/dev/null
    trap 'pbcopy < "$saved" 2>/dev/null; trap - RETURN' RETURN
    python3 - "$WORK/paste.png" <<'PY2'
import struct, sys, zlib
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
rows = b"".join(b"\x00" + bytes((x * 5 + y * 11) % 256 for x in range(48 * 3)) for y in range(48))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 48, 48, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY2

    printf '%s\n' "pasteimage $WORK/paste.png" "keyraw cmd+v" "wait 9" > "$WORK/paste.txt"

    paste_key_count() {
        python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
count = 0
for line in open(sys.argv[1]):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("ev") == "input" and e.get("kind") == "key" and e.get("action") == 0 \
            and e.get("keycode") == 279 and e.get("meta") == 0:
        count += 1
print(count)
PY
    }
    one_paste_key() { [ "$(paste_key_count)" = "1" ]; }
    no_paste_key() { [ "$(paste_key_count)" = "0" ]; }
    clip_seen() { grep -q '"dir":"rx".*"paste":true' "$WORK/events.jsonl" 2>/dev/null; }

    # phase APPEARANCE done|none TAG
    paste_phase() {
        local appearance="$1" expect="$2" tag="$3"
        rm -f "$WORK/events.jsonl" "$WORK/chrome.txt"
        if [ "$expect" = "done" ]; then
            FAKE_ARGS="--clip-done-delay 2"
        else
            FAKE_ARGS="--no-clip-done"
        fi
        start_fake || return 1
        launch --connect "127.0.0.1:$PORT" --appearance "$appearance" \
            --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
            --debug-input-script "$WORK/paste.txt"
        if ! wait_until 30 chrome_has "frame="; then
            bad "PASTE $tag: no app window"; stop_app; stop_fakephone; return 1
        fi
        if ! wait_until 15 clip_seen; then
            bad "PASTE $tag: the phone never received the image (paste flag missing)"; \
                stop_app; stop_fakephone; return 1
        fi
        if [ "$expect" = "done" ]; then
            if wait_until 5 chrome_has "paste_pill=pasting"; then
                chrome_has "paste_button=0" \
                    && ok "[SHARE-16] PASTE $tag: the Pasting pill has no button" \
                    || bad "PASTE $tag: the Pasting pill offered a button"
                screenshot 900 "$shots/paste-pasting-$tag.png" \
                    && ok "[SHARE-16] PASTE $tag: the Pasting pill is up while the phone writes the clip" \
                    || bad "PASTE $tag: no Pasting screenshot"
            else
                bad "PASTE $tag: no Pasting pill"
            fi
            if wait_until 15 one_paste_key; then
                ok "[SHARE-16] PASTE $tag: the confirmation sent exactly one KEY 279 with no meta"
            else
                bad "PASTE $tag: no single KEY 279 after clip.image.done ($(paste_key_count) keys)"
            fi
            sleep 1
            [ "$(paste_key_count)" = "1" ] \
                && ok "[SHARE-16] PASTE $tag: the paste sends one key, never a repeat" \
                || bad "PASTE $tag: the paste repeated its key"
            wait_until 5 chrome_has "paste_pill=pasted" \
                && screenshot 900 "$shots/paste-pasted-$tag.png" \
                && ok "[SHARE-16] PASTE $tag: the Image pasted pill and its Share button" \
                || bad "PASTE $tag: no Image pasted pill"
            chrome_has "paste_button=1" \
                && ok "[SHARE-16] PASTE $tag: the outcome pill's one button is reachable" \
                || bad "PASTE $tag: the outcome pill has no button"
        else
            # The 3 s wait passes with no answer: the failure pill, and not one key.
            if wait_until 10 chrome_has "paste_pill=failed"; then
                screenshot 900 "$shots/paste-failed-$tag.png"
                ok "[SHARE-16] PASTE $tag: no confirmation showed the Nothing pasted pill"
            else
                bad "PASTE $tag: no failure pill after the timeout (state: $(chrome_state))"
            fi
            no_paste_key \
                && ok "[SHARE-16] PASTE $tag: the timeout sent no key" \
                || bad "PASTE $tag: a key was sent without a confirmation"
            chrome_has "paste_button=1" \
                && ok "[SHARE-16] PASTE $tag: the failure pill's Share button is there" \
                || bad "PASTE $tag: the failure pill has no button"
        fi
        stop_app
        stop_fakephone
        wait_until 5 no_fakephone
    }

    for spec in ${PD_E2E_PASTE_PHASES:-light:done dark:done light:none dark:none}; do
        paste_phase "${spec%%:*}" "${spec##*:}" "${spec%%:*}"
    done

    say "screenshots: $shots/paste-pasting-{light,dark}.png $shots/paste-pasted-{light,dark}.png $shots/paste-failed-{light,dark}.png"
}

# --- Share extension ------------------------------------------------------

SHARE_ID="app.contigua.mac.share-e2e"
SHARE_TITLE="Open on Phone (e2e)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# The share driver links the extension's own hand-off code (LinkShare.swift), so its
# name hashes both sources.
build_share_driver() {
    local hash
    hash="$(cat "$MACOS/scripts/share-driver.swift" "$MACOS/Sources/Contigua/LinkShare.swift" | shasum | cut -c1-12)"
    SHAREBIN="$TOOLS/share-driver-$hash"
    if [ ! -x "$SHAREBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O -parse-as-library "$MACOS/scripts/share-driver.swift" "$MACOS/Sources/Contigua/LinkShare.swift" \
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
        && ok "[SHARE-9] SHARE bundle has Share.appex ($SHARE_ID, com.apple.share-services)" \
        || bad "[SHARE-9] SHARE Share.appex missing or wrong Info.plist"
    codesign --verify --deep --strict "$E2E_BUNDLE" 2>/dev/null \
        && codesign -d --entitlements - "$appex" 2>/dev/null | grep -q app-sandbox \
        && ok "[SHARE-9] SHARE codesign --deep --strict passes; the extension is sandboxed" \
        || bad "[SHARE-9] SHARE codesign verify failed or the extension is not sandboxed"

    "$LSREGISTER" -f "$E2E_BUNDLE" >/dev/null 2>&1
    pluginkit -a "$appex" >/dev/null 2>&1
    pluginkit -e use -i "$SHARE_ID" >/dev/null 2>&1
    wait_until 10 share_listed \
        && ok "[SHARE-9] SHARE pluginkit lists $SHARE_ID" || bad "[SHARE-9] SHARE pluginkit does not list $SHARE_ID"

    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 120
    authenticated() { events_have '"state":"auth_ok"' || events_have '"state":"paired"'; }
    wait_until 30 authenticated \
        || { bad "SHARE the app never authenticated"; stop_app; stop_fakephone; unregister_share; return 1; }

    link_event() { grep -F '"ev": "link"' "$WORK/events.jsonl" 2>/dev/null | grep -qF "\"url\": \"$1\"" \
        || grep -F '"ev":"link"' "$WORK/events.jsonl" 2>/dev/null | grep -qF "\"url\":\"$1\""; }

    "$SHAREBIN" handoff "$E2E_BUNDLE" "look at https://example.com/handoff please" > "$WORK/share-a.log" 2>&1
    wait_until 20 link_event "https://example.com/handoff" \
        && ok "[SHARE-9] SHARE hand-off: text with a link -> fakephone logs link.open" \
        || bad "[SHARE-9] SHARE hand-off did not reach the phone ($(cat "$WORK/share-a.log"))"
    ! "$SHAREBIN" handoff "$E2E_BUNDLE" "no link in here" >/dev/null 2>&1 \
        && ! "$SHAREBIN" handoff "$E2E_BUNDLE" "file:///etc/hosts" >/dev/null 2>&1 \
        && ok "[SHARE-7] SHARE hand-off refuses text without a link and file: URLs" \
        || bad "[SHARE-7] SHARE hand-off accepted non-link text or a file: URL"

    "$SHAREBIN" service "$SHARE_TITLE" "https://example.com/extension" > "$WORK/share-b.log" 2>&1
    wait_until 20 link_event "https://example.com/extension" \
        && ok "[SHARE-9] SHARE the sandboxed extension -> fakephone logs link.open" \
        || bad "[SHARE-9] SHARE the extension did not reach the phone ($(tr '\n' ' ' < "$WORK/share-b.log"))"

    [ "$(e2e_app_pids | wc -l | tr -d ' ')" = "1" ] && ! pgrep -fx "$APP" >/dev/null \
        && ok "[SHARE-9] SHARE the links went to the running e2e app (one instance)" \
        || bad "[SHARE-9] SHARE the hand-off started another Contigua instance"
    pkill -fx "$APP" >/dev/null 2>&1
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    unregister_share
    wait_until 10 eval '! share_listed' \
        && ok "[SHARE-9] SHARE $SHARE_ID unregistered after the check" || bad "[SHARE-9] SHARE $SHARE_ID still registered"
}

# --- Finder bridge (docs/design/files.md §3, files-bridge) ------------------
#
# The app's side of phone files in Finder, with no File Provider on this Mac:
# the app listens on a socket in the run's work dir (`--files-bridge-dir`, a
# test hook) and scripts/files-bridge-driver.py speaks the extension's wire at
# it. Asserts hello, the root listing (hidden/Android rules), paging, stat, two
# byte-identical whole-file reads, a cancel that stops the phone's stream, the
# fs_denied path, and `offline` after fakephone is killed.

# files_bridge_socket — the socket path `--files-bridge-dir $WORK/bridge` uses
# (or BRIDGE_DIR, for the relaunch phase's own directory).
files_bridge_socket() {
    local dir="${BRIDGE_DIR:-$WORK/bridge}"
    if [ "$PROFILE" = default ]; then
        printf '%s\n' "$dir/files.sock"
    else
        printf '%s\n' "$dir/files-$PROFILE.sock"
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
with open(os.path.join(root, "Documents/report.pdf"), "wb") as handle:
    handle.write(b"%PDF-1.4\n")
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
    # A relaunch with Finder files already on: the domain is still added, the
    # bridge socket died with the old process, and v103 returned from
    # ensureDomain() before starting it — the extension then found "the app is
    # not reachable" and Finder said "Your device couldn't connect to the
    # server". The hook presents the domain as existing (no File Provider on
    # this Mac); the bridge must come up anyway and answer hello.
    stop_app
    defaults write "$DEFAULTS_SUITE" files.showInFinder -bool true
    launch --connect "127.0.0.1:$PORT" --files-domain-seen "$WORK/bridge-seen"
    if wait_until 20 [ -S "$WORK/bridge-seen/files-$PROFILE.sock" ]; then
        ok "BRIDGE a relaunch with the domain present brings the socket up"
        BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver online
    else
        bad "BRIDGE a relaunch with the domain present left no bridge socket"
        stop_app
        stop_fakephone
        return 1
    fi
    # Thumbnails (FILES-22/23/25/26/29, R-1). The fake phone serves one
    # synthetic 16x16 JPEG; the tree has a PDF and a text file next to the
    # photo, so the app's type filter can be seen keeping them off the phone.
    python3 - "$WORK" <<'THUMBFIX'
import base64, os, sys
work = sys.argv[1]
jpeg = ("/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAoKCwoLDQ0N"
        "DQ0NEA8QEBAQEBAQEBAQEBISEhUVFRISEhAQEhIUFBUVFxcXFRUVFRcXGRkZHh4cHCMj"
        "JCsrM//EAEwAAQEAAAAAAAAAAAAAAAAAAAAGAQEBAAAAAAAAAAAAAAAAAAAFBhABAAAAAAAA"
        "AAAAAAAAAAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIABAAEAMBIgACEQADEQD/2gAM"
        "AwEAAhEDEQA/AJ0BVAH/2Q==")
with open(os.path.join(work, "thumb.jpg"), "wb") as handle:
    handle.write(base64.b64decode(jpeg))
open(os.path.join(work, "fsroot", "Documents", "report.pdf"), "wb").write(b"%PDF-1.4\n")
THUMBFIX
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg" start_fake || return 1
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "BRIDGE THUMB the app never re-authenticated"; stop_app; stop_fakephone; return 1; }
    BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver thumb --thumb-fixture "$WORK/thumb.jpg"
    if python3 - "$WORK/events.jsonl" <<'THUMBCOUNT'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], errors="replace") if line.strip()]
thumbs = [e for e in events if e.get("ev") == "fs" and e.get("kind") == "thumb"]
# Exactly one ask reached the phone, for the photo, at the long side.
sys.exit(0 if len(thumbs) == 1 and thumbs[0].get("size") == 512 else 1)
THUMBCOUNT
    then
        ok "BRIDGE [FILES-22/23] one fs.thumb at 512: the PDF and the folder asked nothing"
    else
        bad "BRIDGE [FILES-22/23] the phone saw the wrong fs.thumb count or size"
    fi
    # A phone that holds every answer: 3 live, the fourth queued, then the
    # deadline on the one still held.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg --fs-thumb-mode hold" start_fake || return 1
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "BRIDGE THUMB the app never re-authenticated (hold)"; stop_app; stop_fakephone; return 1; }
    BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver thumb-hold
    cp "$WORK/fake.err" "$WORK/fake-thumb-hold.err" 2>/dev/null || true
    cp "$WORK/events.jsonl" "$WORK/events-thumb-hold.jsonl" 2>/dev/null || true
    # hold_once: the first answer is held, so the fourth ask starts only when
    # two of the first three end.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg --fs-thumb-mode hold_once" start_fake || return 1
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "BRIDGE THUMB the app never re-authenticated (hold_once)"; stop_app; stop_fakephone; return 1; }
    BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver thumb-once
    cp "$WORK/fake.err" "$WORK/fake-thumb-once.err" 2>/dev/null || true
    cp "$WORK/events.jsonl" "$WORK/events-thumb-once.jsonl" 2>/dev/null || true
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg --fs-thumb-mode hold" start_fake || return 1
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "BRIDGE THUMB the app never re-authenticated (timeout)"; stop_app; stop_fakephone; return 1; }
    BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver thumb-timeout
    cp "$WORK/fake.err" "$WORK/fake-thumb-timeout.err" 2>/dev/null || true
    # A slow phone: one generator at 1 s a picture, 12 asks queued three at a
    # time. The last waits ~9 s before it starts — past the old 8 s measured
    # from the ask — and still answers: queue time is not the phone's work.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg --fs-thumb-delay-ms 1000" start_fake || return 1
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "BRIDGE THUMB the app never re-authenticated (slow)"; stop_app; stop_fakephone; return 1; }
    BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver thumb-slow --thumb-fixture "$WORK/thumb.jpg"
    cp "$WORK/fake.err" "$WORK/fake-thumb-slow.err" 2>/dev/null || true
    log show --last 6m --info \
        --predicate 'subsystem == "app.contigua.mac" AND category == "files"' 2>/dev/null \
        | grep -oE 'thumb: .*|fs: cancel.*|bridge: fs cancel|session: fs.cancel sent.*' > "$WORK/thumb-log.txt" 2>/dev/null || true
    say "thumb queue log: $(tail -6 "$WORK/thumb-log.txt" | tr '\n' ' ')"
    sends="$(grep -c 'session: fs.cancel sent ok=true' "$WORK/thumb-log.txt" 2>/dev/null || true)"
    [ "${sends:-0}" -ge 5 ] \
        && ok "BRIDGE [FILES-25/29] the app sent all five fs.cancel messages ($sends)" \
        || bad "BRIDGE [FILES-25/29] the app sent $sends fs.cancel messages, wanted 5"
    # A phone that makes no picture: fs_no_thumb is permanent and a text file
    # never asks at all.
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg --fs-thumb-mode no_thumb" start_fake || return 1
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "BRIDGE THUMB the app never re-authenticated (no_thumb)"; stop_app; stop_fakephone; return 1; }
    BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver thumb-none
    # The phone goes away: every dataless request must answer offline. The
    # session's teardown runs through its rejoin grace, so let detach() land
    # before asking the bridge (a hello during it still says connected).
    stop_fakephone
    wait_until 5 no_fakephone
    sleep 3
    BRIDGE_DIR="$WORK/bridge-seen" files_bridge_driver offline
    # Nothing about the bridge may put a name, a path or bytes in the app log:
    # os_log carries op names, counts and lengths only (design §4).
    log show --last 3m --info \
        --predicate 'subsystem == "app.contigua.mac" AND category == "files"' 2>/dev/null \
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
           for name in names if name.startswith(".contigua-") and name.endswith(".part")]
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
        --predicate 'subsystem == "app.contigua.mac" AND category == "files"' 2>/dev/null \
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
# Android's transient entries, at two depths: neither is a phone file.
open(os.path.join(root, "A", ".trashed-x"), "wb").write(b"trashed\n")
open(os.path.join(root, "A", ".pending-x"), "wb").write(b"pending\n")
# [FILES-33] B is the folder Finder is not showing: five files the reconnect's
# resync must compare without a listing from the extension.
for index in range(1, 6):
    open(os.path.join(root, "B", "b%d.txt" % index), "wb").write(b"b\n")
# [FILES-31] the folder the record outlives the app for: five files now, two
# gone and one added while the app is stopped.
os.makedirs(os.path.join(root, "P"), exist_ok=True)
for index in range(1, 6):
    open(os.path.join(root, "P", "p%d.txt" % index), "wb").write(b"file\n")
# 65 folders for the watch-set cap: the 65th touch drops the least recently
# touched and the phone never watches more than 64.
for index in range(65):
    os.makedirs(os.path.join(root, "W%02d" % index), exist_ok=True)
PY
    WATCH_FOLDERS="$(python3 -c 'print(",".join("W%02d" % i for i in range(65)))')"
    # The record and log are per profile and outlive a run: start from none so
    # the first listing's diff is this run's.
    rm -f "$HOME/Library/Application Support/Contigua-$PROFILE/files-ids.json" \
          "$HOME/Library/Application Support/Contigua-$PROFILE/files-replica.json"
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
        --predicate 'subsystem == "app.contigua.mac" AND category == "files"' 2>/dev/null \
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
    # [FILES-31] The replica record outlives the app: the phone loses two files
    # and gains one while the app is stopped, and the first listing after the
    # restart must report exactly that within 5 s.
    files_bridge_driver persist --stage before
    sleep 1  # the record and log are written in one coalesced save (250 ms)
    stop_app
    python3 - "$WORK" <<'PY'
import os, sys
folder = os.path.join(sys.argv[1], "fsroot", "P")
names = sorted(os.listdir(folder))
os.unlink(os.path.join(folder, names[0]))
os.unlink(os.path.join(folder, names[1]))
open(os.path.join(folder, "p6.txt"), "wb").write(b"six\n")
PY
    PD_FILES_WATCH_TTL=20 launch --connect "127.0.0.1:$PORT" --files-bridge-dir "$WORK/bridge"
    wait_until 30 file_has "files-bridge: ok" "$WORK/app.log" \
        && ok "PERSIST the restarted app listens on the test bridge socket" \
        || bad "PERSIST no bridge socket after the restart: $(grep 'files-bridge' "$WORK/app.log" | tail -2)"
    files_bridge_driver persist --stage after
    log show --last 3m --info \
        --predicate 'subsystem == "app.contigua.mac" AND category == "files"' 2>/dev/null \
        | grep -o 'bridge: .*' > "$WORK/persist-log.txt" 2>/dev/null || true
    if python3 - "$WORK/persist-log.txt" <<'PY'
import sys
text = open(sys.argv[1], errors="replace").read()
names = ("P", "p1.txt", "p6.txt")
sys.exit(1 if any(("/" + name) in text or ('"' + name + '"') in text for name in names) else 0)
PY
    then
        ok "PERSIST [FILES-31] the app log carries no file names"
    else
        bad "PERSIST [FILES-31] a file name appears in the app log"
    fi
    # [FILES-33] The reconnect resync: B is in the record but not on screen, and
    # its watch is allowed to lapse before the session drops, so only the ready's
    # one fs.digest can notice the phone's two deleted and one added file.
    files_bridge_driver resync --stage before
    sleep 21  # the test TTL is 20 s: the watch set is empty for the reconnect
    stop_fakephone
    wait_until 5 no_fakephone
    python3 - "$WORK" <<'PY'
import os, sys
folder = os.path.join(sys.argv[1], "fsroot", "B")
names = sorted(name for name in os.listdir(folder)
               if not name.startswith(".trashed-") and not name.startswith(".pending-"))
os.unlink(os.path.join(folder, names[0]))
os.unlink(os.path.join(folder, names[1]))
open(os.path.join(folder, "b-new.txt"), "wb").write(b"new\n")
PY
    FAKE_ARGS="--fs-root $WORK/fsroot" start_fake || return 1
    # The driver waits for the app's bridge to say connected, then reads the
    # working set: it never lists the folder itself.
    files_bridge_driver resync --stage after
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
FILES_ID="app.contigua.mac.files-e2e"
FILES_GROUP="group.app.contigua.mac.files-e2e"
# Rig waits for the files-domain check, not product limits: no nfr-limits.json
# entry. The one-time System Settings switch writes the File Provider's
# user-enabled flag and the system then launches the extension, and after a
# relaunch the extension reconnects on its own backoff schedule. verify-r3's VM
# run ran out of both windows (90 s and 60 s) while a busy VM was still starting
# them; the product came up fine just after. A generous window here only makes a
# failing run take longer to say so.
FILES_SWITCH_WAIT_S=300
FILES_RELAUNCH_WAIT_S=120

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
        --predicate 'subsystem == "app.contigua.mac" AND category == "files"' 2>/dev/null
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
			set rowY to item 2 of (get position of static text "Contigua")
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

# --- Thumbnails in Finder (docs/design/files.md "Thumbnails (S6)", files-thumbs)
#
# One VM boot, the real extension, in this order:
# (a) a fixture JPEG (photo.jpg) is served normally: the fake phone answers
#     fs.thumb, the extension hands the bytes to the system, and Finder's icon
#     view draws the picture. The fake's thumbnail is pure green, so the
#     screenshot proves the icon is the phone's picture, not a type icon.
# (b) a PDF beside it keeps its type icon and asks the phone nothing.
# (c) a second JPEG (lost.jpg) is held past the app's 8 s deadline: R-1's
#     serverUnreachable, one fs.cancel, and the system's re-ask behaviour is
#     recorded, never required (the measured fact in FILES-26).
# (d) the phone goes away: reopening the folder keeps the cached picture and
#     the type icons for the items without one, with no alert; Finder does not
#     ask again, which is the measured fact in FILES-26 (so no offline line).
# The file is never materialized: no fetchContents line may appear.
check_files_thumbs() {
    if [ "${PD_E2E_IN_VM:-0}" != "1" ]; then
        bad "FILES-THUMBS refuses to run on the host (it adds a File Provider domain); run macos/scripts/vm-e2e.sh files-thumbs"
        return
    fi
    clean
    local appex; appex="$(files_appex)"
    command -v ffmpeg >/dev/null || { bad "FILES-THUMBS ffmpeg is needed to make the fixtures"; return 1; }
    files_tree
    # A real 1200x900 photo, a second one for R-1, and a PDF beside them. The
    # fake phone's own 64x64 answer is pure green, so a green icon can only be
    # its thumbnail.
    ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=1200x900:rate=1" \
        -frames:v 1 -q:v 4 "$WORK/fsroot/DCIM/Camera/photo.jpg" >/dev/null 2>&1 \
        || { bad "FILES-THUMBS could not make the photo"; return 1; }
    ffmpeg -hide_banner -loglevel error -f lavfi -i "smptebars=size=1200x900:rate=1" \
        -frames:v 1 -q:v 4 "$WORK/fsroot/DCIM/Camera/lost.jpg" >/dev/null 2>&1 \
        || { bad "FILES-THUMBS could not make the R-1 photo"; return 1; }
    ffmpeg -hide_banner -loglevel error -f lavfi -i "color=c=lime:s=64x64" \
        -frames:v 1 -q:v 4 "$WORK/thumb.jpg" >/dev/null 2>&1 \
        || { bad "FILES-THUMBS could not make the thumbnail fixture"; return 1; }
    python3 - "$WORK/fsroot" <<'PY'
import os, sys
root = os.path.join(sys.argv[1], "DCIM")
open(os.path.join(root, "Camera", "report.pdf"), "wb").write(b"%PDF-1.4\n")
PY

    # photo.jpg answers at once; lost.jpg is held on every ask (the R-1 step),
    # so the positive picture is proven before anything can time out.
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg --fs-thumb-hold-name lost.jpg" start_fake || return 1
    "$LSREGISTER" -f "$E2E_BUNDLE" >/dev/null 2>&1
    pluginkit -a "$appex" >/dev/null 2>&1
    pluginkit -e use -i "$FILES_ID" >/dev/null 2>&1
    files_oneshot list "$WORK/list-before.txt" >/dev/null 2>&1 || true
    files_oneshot remove "$WORK/remove-before.txt" >/dev/null 2>&1 || true
    stale_domain_folder() { ls -d "$HOME"/Library/CloudStorage/Contigua-* >/dev/null 2>&1; }
    wait_until 60 eval '! stale_domain_folder' \
        || bad "FILES-THUMBS the removed domain's folder is still in CloudStorage after 60 s"

    launch --connect "127.0.0.1:$PORT" --files-domain add
    wait_until 30 file_has "files-domain add: ok" "$WORK/app.log" \
        && ok "FILES-THUMBS NSFileProviderManager.add ok" \
        || { bad "FILES-THUMBS add failed: $(grep 'files-domain' "$WORK/app.log" | head -2 | tr '\n' ' ')"; stop_app; stop_fakephone; return 1; }
    wait_until 20 file_has "files-domain bridge group: ok" "$WORK/app.log" \
        || bad "FILES-THUMBS no App Group bridge socket"
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "FILES-THUMBS the app never authenticated"; stop_app; stop_fakephone; return 1; }
    files_list
    local root; root="$(files_domain_path)"
    files_enable_provider > "$WORK/enable-files.txt" 2>&1 || true
    wait_until "$FILES_SWITCH_WAIT_S" files_root_lists "$root" \
        && ok "FILES-THUMBS the extension is enabled and the domain enumerates" \
        || { bad "FILES-THUMBS still user-disabled after the System Settings switch"; stop_app; stop_fakephone; return 1; }
    ok "FILES-THUMBS the domain is mounted at $root"

    # LaunchServices opens the folder without an AppleEvent to Finder (the
    # CloudStorage mount can block Finder's `open` past the -1712 timeout on
    # the first look); the window settings follow with their own timeout.
    finder_folder() {
        open -a Finder "$1" >/dev/null 2>&1 || true
        local deadline=$((SECONDS + 30)) id
        while [ $SECONDS -lt $deadline ]; do
            id="$("$CGBIN" list --owner Finder | head -1 | cut -f1)"
            [ -n "$id" ] && break
            sleep 0.5
        done
        osascript - "$1" <<'OSA'
on run argv
    with timeout of 30 seconds
        tell application "Finder"
            activate
            try
                set theWindow to front window
                set current view of theWindow to icon view
                set icon size of theWindow's icon view options to 128
                set bounds of theWindow to {80, 80, 900, 700}
                set toolbar visible of theWindow to false
                set statusbar visible of theWindow to false
            end try
        end tell
    end timeout
end run
OSA
    }
    finder_close() {
        osascript >/dev/null 2>&1 <<'OSA' || true
with timeout of 20 seconds
    tell application "Finder" to close every window
end timeout
OSA
    }
    thumb_logged() { files_log | grep -q "$1"; }
    # green_pixels <png> <skip-fraction>: the fake's pure-green thumbnail in
    # the content area. The sidebar is skipped so its icons cannot count.
    green_pixels() {
        local png="$1" skip="$2" width height
        width="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$png" 2>/dev/null)"
        height="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$png" 2>/dev/null)"
        [ -n "$width" ] && [ -n "$height" ] || { echo 0; return; }
        ffmpeg -hide_banner -loglevel error -y -i "$png" -f rawvideo -pix_fmt rgb24 "$WORK/shot.rgb" >/dev/null 2>&1 || { echo 0; return; }
        python3 - "$WORK/shot.rgb" "$width" "$height" "$skip" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
width, height, skip = int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
start = int(width * skip)
count = 0
for y in range(height):
    row = y * width * 3
    for x in range(start, width):
        i = row + x * 3
        if data[i + 1] >= 200 and data[i] <= 90 and data[i + 2] <= 90:
            count += 1
print(count)
PY
    }

    # (a) The positive picture first: the normal answer, then the screenshot
    # before anything else happens to the window.
    finder_close
    finder_folder "$root/DCIM/Camera"
    wait_until 30 thumb_logged 'thumb done bytes=' \
        && ok "FILES-THUMBS [FILES-23] the extension handed the picture's bytes to the system" \
        || bad "FILES-THUMBS no thumb done after the normal ask"
    sleep 2
    rm -f "$SHOTS/after-files-thumbs.png"
    local finder_id; finder_id="$("$CGBIN" list --owner Finder | head -1 | cut -f1)"
    if [ -n "$finder_id" ] && screencapture -x -o -l"$finder_id" "$SHOTS/after-files-thumbs.png" 2>/dev/null; then
        cp "$SHOTS/after-files-thumbs.png" "$WORK/after-files-thumbs.png" 2>/dev/null || true
        ok "FILES-THUMBS screenshot: $SHOTS/after-files-thumbs.png"
    else
        bad "FILES-THUMBS could not capture the Finder window"
    fi
    local green; green="$(green_pixels "$SHOTS/after-files-thumbs.png" 0.35)"
    [ "${green:-0}" -ge 1000 ] \
        && ok "FILES-THUMBS [FILES-23] the icon view shows the phone's green picture ($green pixels)" \
        || bad "FILES-THUMBS the icon view shows no picture ($green green pixels)"

    # (b) The photo's answer is the fake's own bytes; the PDF never reached the
    # phone, and neither did the folder.
    if python3 - "$WORK" <<'PY'
import hashlib, json, os, sys
work = sys.argv[1]
def name_hash(name):
    return hashlib.sha256(name.encode("utf-8")).hexdigest()[:16]
photo, pdf = name_hash("photo.jpg"), name_hash("report.pdf")
expected = os.path.getsize(os.path.join(work, "thumb.jpg"))
events = [json.loads(line) for line in open(os.path.join(work, "events.jsonl"), errors="replace") if line.strip()]
fs = [e for e in events if e.get("ev") == "fs"]
answered = [e for e in fs if e.get("kind") == "thumb" and e.get("name") == photo]
asked_pdf = [e for e in fs if e.get("name") == pdf]
fake = open(os.path.join(work, "fake.err"), errors="replace").read()
pdf_accept = ("name=" + pdf) in fake
sys.exit(0 if answered
         and all(e.get("bytes") == expected and e.get("size", 0) > 0 for e in answered)
         and not asked_pdf and not pdf_accept else 1)
PY
    then
        ok "FILES-THUMBS [FILES-22/23] the phone answered the photo's fs.thumb and the PDF asked nothing"
    else
        bad "FILES-THUMBS the phone saw the wrong fs.thumb count or size"
    fi

    # (c) R-1 on lost.jpg: held past the deadline, one timeout and one
    # fs.cancel. What the system does next is recorded, not required.
    wait_until 30 thumb_logged 'thumb failed code=timeout' \
        && ok "FILES-THUMBS [FILES-26/R-1] the held second JPEG answered timeout at the deadline" \
        || bad "FILES-THUMBS no timeout line after the held ask"
    sleep 1
    if python3 - "$WORK" <<'PY'
import hashlib, json, os, sys
work = sys.argv[1]
lost = hashlib.sha256(b"lost.jpg").hexdigest()[:16]
events = [json.loads(line) for line in open(os.path.join(work, "events.jsonl"), errors="replace") if line.strip()]
fs = [e for e in events if e.get("ev") == "fs"]
held = [e for e in fs if e.get("kind") == "thumb.hold" and e.get("name") == lost]
cancelled = [e for e in fs if e.get("kind") == "thumb.cancelled" and e.get("name") == lost]
fake = open(os.path.join(work, "fake.err"), errors="replace").read()
receives = fake.count("fs cancel recv")
sys.exit(0 if len(held) == 1 and len(cancelled) == 1 and receives == 1 else 1)
PY
    then
        ok "FILES-THUMBS [FILES-26/R-1] the held ask produced one timeout and one fs.cancel"
    else
        bad "FILES-THUMBS the held ask did not produce one hold and one cancel"
    fi
    lost_holds() { python3 - "$WORK/events.jsonl" <<'PY'
import hashlib, json, sys
lost = hashlib.sha256(b"lost.jpg").hexdigest()[:16]
events = [json.loads(line) for line in open(sys.argv[1], errors="replace") if line.strip()]
print(len([e for e in events if e.get("ev") == "fs" and e.get("kind") == "thumb.hold"
           and e.get("name") == lost]))
PY
    }
    local holds; holds="$(lost_holds)"
    sleep 15
    if [ "$(lost_holds)" -gt "$holds" ]; then
        say "FILES-THUMBS [FILES-26] recorded: the system asked again by itself after the timeout"
    else
        say "FILES-THUMBS [FILES-26] recorded: no re-ask by itself within 15 s"
    fi
    finder_close
    finder_folder "$root/DCIM/Camera"
    sleep 15
    if [ "$(lost_holds)" -gt "$holds" ]; then
        say "FILES-THUMBS [FILES-26] recorded: reopening the folder asked again"
    else
        say "FILES-THUMBS [FILES-26] recorded: no re-ask on reopening within 15 s"
    fi

    files_log > "$WORK/thumb-log.txt" 2>/dev/null || true
    if grep -q "photo.jpg\|lost.jpg\|report.pdf" "$WORK/thumb-log.txt"; then
        bad "FILES-THUMBS [FILES-27] a file name appears in the thumbnail log"
    else
        ok "FILES-THUMBS [FILES-27] the thumbnail log carries no file name"
    fi
    if grep -q 'fetch done' "$WORK/thumb-log.txt"; then
        bad "FILES-THUMBS [FILES-23] the thumbnail materialized the file"
    else
        ok "FILES-THUMBS [FILES-23] no fetchContents: the item stayed undownloaded"
    fi

    # (d) The phone goes away. Finder does not ask again for a folder it has
    # already cached (FILES-26's measured fact), so reopening the same folder
    # is the person's next look: the picture it already has stays, the items
    # without one keep their type icons, and there is no alert. r2's "offline
    # line" assertion is dropped: no ask means no line, and that is the fact.
    local offline_before; offline_before="$(files_log | grep -c 'thumb failed code=offline' || true)"
    stop_fakephone
    wait_until 5 no_fakephone
    sleep 32
    finder_close
    finder_folder "$root/DCIM/Camera"
    sleep 3
    rm -f "$SHOTS/after-files-thumbs-offline.png"
    finder_id="$("$CGBIN" list --owner Finder | head -1 | cut -f1)"
    [ -n "$finder_id" ] && screencapture -x -o -l"$finder_id" "$SHOTS/after-files-thumbs-offline.png" 2>/dev/null \
        && { cp "$SHOTS/after-files-thumbs-offline.png" "$WORK/after-files-thumbs-offline.png" 2>/dev/null || true; ok "FILES-THUMBS screenshot: $SHOTS/after-files-thumbs-offline.png"; } \
        || bad "FILES-THUMBS could not capture the offline Finder window"
    if [ -f "$SHOTS/after-files-thumbs-offline.png" ]; then
        local green_off; green_off="$(green_pixels "$SHOTS/after-files-thumbs-offline.png" 0.35)"
        if [ "${green:-0}" -gt 0 ] && [ "${green_off:-0}" -ge $((green * 8 / 10)) ] \
                && [ "${green_off:-0}" -le $((green * 12 / 10)) ]; then
            ok "FILES-THUMBS [FILES-26] the phone-away folder keeps the cached picture and no new one ($green_off green pixels)"
        else
            bad "FILES-THUMBS the phone-away picture count changed ($green -> $green_off)"
        fi
    fi
    local offline_after; offline_after="$(files_log | grep -c 'thumb failed code=offline' || true)"
    if [ "${offline_after:-0}" -eq "${offline_before:-0}" ]; then
        say "FILES-THUMBS [FILES-26] recorded: the phone away did not ask again (no offline line)"
    else
        say "FILES-THUMBS [FILES-26] recorded: the phone away asked again (an offline line appeared)"
    fi
    say "FILES-THUMBS [FILES-26] no alert in the phone-away screenshot"

    finder_close
    stop_app
    files_oneshot remove "$WORK/remove.txt" >/dev/null 2>&1 || true
    unregister_files >/dev/null 2>&1 || true
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- Thumbnails at scale (FILES-30, files-thumbs-scale) ---------------------
#
# The person's report: a folder of thousands of images, scrolled far, and the
# thumbnails did not follow. One VM boot opens 3,000 small JPEGs in Finder's
# icon view, then scrolls to the middle and to the end. The fake phone answers
# one thumbnail at a time, 300 ms each (a real phone's pace), so the ~20 icons
# on a screen form a queue rather than filling at once.
#
# Records, ids/counts/sizes/durations only (FILES-27): the listing time for
# 3,000 names, Finder's batch sizes and cancels (the extension's `thumb batch`
# lines), and the time from the open / each scroll to the first picture on
# screen.
check_files_thumbs_scale() {
    if [ "${PD_E2E_IN_VM:-0}" != "1" ]; then
        bad "FILES-THUMBS-SCALE refuses to run on the host (it adds a File Provider domain); run macos/scripts/vm-e2e.sh files-thumbs-scale"
        return
    fi
    clean
    local appex; appex="$(files_appex)"
    command -v ffmpeg >/dev/null || { bad "FILES-THUMBS-SCALE ffmpeg is needed to make the fixtures"; return 1; }
    files_tree
    ffmpeg -hide_banner -loglevel error -f lavfi -i "color=c=lime:s=64x64" \
        -frames:v 1 -q:v 4 "$WORK/thumb.jpg" >/dev/null 2>&1 \
        || { bad "FILES-THUMBS-SCALE could not make the thumbnail fixture"; return 1; }
    # Fixture names only: 3,000 tiny JPEGs are the listing's weight, not the
    # picture's (the fake serves its own green fixture for any image name).
    python3 - "$WORK/fsroot" "$WORK/thumb.jpg" <<'PY'
import os, sys
root = os.path.join(sys.argv[1], "bulk")
os.makedirs(root, exist_ok=True)
data = open(sys.argv[2], "rb").read()
for i in range(3000):
    with open(os.path.join(root, "img%04d.jpg" % i), "wb") as handle:
        handle.write(data)
PY

    FAKE_ARGS="--fs-root $WORK/fsroot --fs-thumb $WORK/thumb.jpg --fs-thumb-delay-ms 300" start_fake || return 1
    "$LSREGISTER" -f "$E2E_BUNDLE" >/dev/null 2>&1
    pluginkit -a "$appex" >/dev/null 2>&1
    pluginkit -e use -i "$FILES_ID" >/dev/null 2>&1
    files_oneshot list "$WORK/list-before.txt" >/dev/null 2>&1 || true
    files_oneshot remove "$WORK/remove-before.txt" >/dev/null 2>&1 || true
    stale_domain_folder() { ls -d "$HOME"/Library/CloudStorage/Contigua-* >/dev/null 2>&1; }
    wait_until 60 eval '! stale_domain_folder' \
        || bad "FILES-THUMBS-SCALE the removed domain's folder is still in CloudStorage after 60 s"

    launch --connect "127.0.0.1:$PORT" --files-domain add
    wait_until 30 file_has "files-domain add: ok" "$WORK/app.log" \
        && ok "FILES-THUMBS-SCALE NSFileProviderManager.add ok" \
        || { bad "FILES-THUMBS-SCALE add failed"; stop_app; stop_fakephone; return 1; }
    wait_until 20 file_has "files-domain bridge group: ok" "$WORK/app.log" \
        || bad "FILES-THUMBS-SCALE no App Group bridge socket"
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || { bad "FILES-THUMBS-SCALE the app never authenticated"; stop_app; stop_fakephone; return 1; }
    files_list
    local root; root="$(files_domain_path)"
    files_enable_provider > "$WORK/enable-files.txt" 2>&1 || true
    # The domain becomes "Contigua (<phone>)" once the session knows the
    # phone, and its CloudStorage folder is renamed under the URL cached at add.
    # The first run waited its whole window on the old name (the folder was
    # already "Contigua-Contigua(FakePhone)" and the extension listed fine).
    # Re-read the URL on every try, and take the folder the rename left.
    domain_root_lists() {
        if [ ! -d "$root" ]; then
            files_list
            local fresh; fresh="$(files_domain_path)"
            [ -n "$fresh" ] && root="$fresh"
            [ -d "$root" ] \
                || root="$(ls -d "$HOME"/Library/CloudStorage/Contigua-* 2>/dev/null | head -1)"
        fi
        files_root_lists "$root"
    }
    wait_until "$FILES_SWITCH_WAIT_S" domain_root_lists \
        && ok "FILES-THUMBS-SCALE the extension is enabled and the domain enumerates" \
        || { bad "FILES-THUMBS-SCALE still user-disabled after the System Settings switch (folder $(ls -d "$HOME"/Library/CloudStorage/Contigua-* 2>/dev/null | head -1))"; stop_app; stop_fakephone; return 1; }

    # -- The listing's weight ------------------------------------------------
    # 120 s, not 20: the first run killed `ls` at 20 s and recorded 0 names for
    # a listing that was still enumerating, and a client killed inside a
    # readdir left Finder's window on that folder empty. The 5 s limit below is
    # the assertion; this cap only stops a hung mount.
    local bulk="$root/bulk" t0 t1 names listing_ms
    t0="$(now_ms)"
    names=0
    local listing_deadline
    listing_deadline=$((SECONDS + 120))
    # `ls` on a File Provider mount returns the names that have arrived so far
    # and can exit with none while the system is still walking the pages (the
    # 00:50 run: 0 names after 9.9 s, then the extension delivered 12 pages over
    # the next 6.5 s). Poll until the whole folder is there; the time from the
    # first request to that observation is what a person waits for. The 5 s
    # assertion below is unchanged.
    while [ $SECONDS -lt "$listing_deadline" ]; do
        run_limited 30 ls "$bulk" > "$WORK/bulk-ls.txt" 2>/dev/null || true
        names="$(wc -l < "$WORK/bulk-ls.txt" | tr -d ' ')"
        [ "${names:-0}" = "3000" ] && break
        sleep 0.5
    done
    t1="$(now_ms)"
    listing_ms=$((t1 - t0))
    say "FILES-THUMBS-SCALE listing: names=$names ms=$listing_ms"
    if [ "${names:-0}" = "3000" ] && [ "$listing_ms" -le 5000 ]; then
        ok "FILES-THUMBS-SCALE [FILES-30] 3,000 names listed in ${listing_ms} ms"
    else
        bad "FILES-THUMBS-SCALE listed ${names:-0} names in ${listing_ms} ms (want 3000 within 5000 ms)"
    fi

    # -- The listing's per-page breakdown ------------------------------------
    # One line per Finder page from the extension (count, hit|fetch, and
    # request→deliver ms) and the app's "bridge: list page" stamp. The app's
    # stamp splits a fetch into phone + relay (start → app reply) and our
    # delivery (app reply → Finder); consecutive starts give the system's gap
    # before it asked for the next page. Counts and durations only (FILES-27).
    files_log > "$WORK/listing-log.txt" 2>/dev/null || true
    # bash 3.2 scans a heredoc inside "$(...)" for quotes: write the
    # parser first, then run it.
    cat > "$WORK/listing-breakdown.py" <<'PY'
import re, sys
from datetime import datetime, timedelta

def stamp(line):
    text = line.strip()
    m = re.match(r"^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3,6})", text)
    if m:
        y, mo, d, h, mi, s, frac = m.groups()
        return datetime(int(y), int(mo), int(d), int(h), int(mi), int(s),
                        int(frac.ljust(6, "0")[:6]))
    m = re.match(r"^([A-Z][a-z]{2})\s+(\d{1,2}) (\d\d):(\d\d):(\d\d)\.(\d{3,6})", text)
    if m:
        now = datetime.now()
        month = datetime.strptime(m.group(1), "%b").month
        return datetime(now.year, month, int(m.group(2)), int(m.group(3)),
                        int(m.group(4)), int(m.group(5)),
                        int(m.group(6).ljust(6, "0")[:6]))
    return None

pages, relays = [], []
try:
    source = open(sys.argv[1], errors="replace")
except OSError:
    source = []
for line in source:
    at = stamp(line)
    m = re.search(r"enumerate page n=(\d+) phone=(hit|fetch) ms=(\d+)", line)
    if m:
        pages.append((at, int(m.group(1)), m.group(2), int(m.group(3))))
        continue
    m = re.search(r"bridge: list page items=(\d+)", line)
    if m:
        relays.append((at, int(m.group(1))))
if not pages:
    print("unavailable")
    raise SystemExit
rows = ["%d:%s:%d" % (n, phone, ms) for _, n, phone, ms in pages]
fetch = sum(1 for page in pages if page[2] == "fetch")
if any(at is None for at, _, _, _ in pages):
    # No usable log timestamps: the counts and each page's own duration are
    # still the measurement; only the gap needs the clock.
    print("pages=%d fetch=%d hit=%d ms_sum=%d per=%s"
          % (len(pages), fetch, len(pages) - fetch,
             sum(page[3] for page in pages), ",".join(rows[:16])))
    raise SystemExit
pages.sort()
relays = sorted(relay for relay in relays if relay[0] is not None)
# Split into passes wherever the system paused for more than 3 s (the root
# folder's pages and the measured folder's pages are different passes). Report
# the pass with the most items: that is the folder under test.
groups = []
for page in pages:
    start = page[0] - timedelta(milliseconds=page[3])
    if groups and start - groups[-1][-1][0] <= timedelta(seconds=2):
        groups[-1].append(page)
    else:
        groups.append([page])
group = max(groups, key=lambda g: (sum(p[1] for p in g), len(g)))
relay = ours = gap = 0
used = set()
previous = None
for at, n, phone, ms in group:
    start = at - timedelta(milliseconds=ms)
    if previous is not None:
        gap += max(0, int((start - previous).total_seconds() * 1000))
    previous = at
    if phone == "fetch":
        match = None
        for index, (reply_at, _) in enumerate(relays):
            if index in used or reply_at < start or reply_at > at:
                continue
            match = index
        if match is not None:
            used.add(match)
            relay += int((relays[match][0] - start).total_seconds() * 1000)
            ours += int((at - relays[match][0]).total_seconds() * 1000)
        else:
            ours += ms
    else:
        ours += ms
span = int((group[-1][0] - (group[0][0] - timedelta(milliseconds=group[0][3])))
           .total_seconds() * 1000)
print("pages=%d fetch=%d hit=%d relay_ms=%d our_ms=%d gap_ms=%d span_ms=%d per=%s"
      % (len(group), sum(1 for p in group if p[2] == "fetch"),
         sum(1 for p in group if p[2] != "fetch"), relay, ours, gap, span,
         ",".join("%d:%s:%d" % (n, phone, ms) for _, n, phone, ms in group[:16])))
PY
    local breakdown
    breakdown="$(python3 "$WORK/listing-breakdown.py" "$WORK/listing-log.txt")"
    say "FILES-THUMBS-SCALE listing breakdown: ${breakdown:-unavailable}"

    # -- Finder's icon view --------------------------------------------------
    finder_folder() {
        open -a Finder "$1" >/dev/null 2>&1 || true
        local deadline=$((SECONDS + 30)) id
        while [ $SECONDS -lt $deadline ]; do
            id="$("$CGBIN" list --owner Finder | head -1 | cut -f1)"
            [ -n "$id" ] && break
            sleep 0.5
        done
        osascript - "$1" <<'OSA'
on run argv
    with timeout of 30 seconds
        tell application "Finder"
            activate
            try
                set theWindow to front window
                set current view of theWindow to icon view
                set icon size of theWindow's icon view options to 128
                set bounds of theWindow to {80, 80, 900, 700}
                set toolbar visible of theWindow to false
                set statusbar visible of theWindow to false
            end try
        end tell
    end timeout
end run
OSA
    }
    finder_close() {
        osascript >/dev/null 2>&1 <<'OSA' || true
with timeout of 20 seconds
    tell application "Finder" to close every window
end timeout
OSA
    }
    finder_id() { "$CGBIN" list --owner Finder | head -1 | cut -f1; }
    # The extension's batch lines, one count per call: the movement signal and
    # the record (ids and counts only, FILES-27). It refreshes the log first;
    # a call costs a `log show`, so the scroll paths use it sparingly.
    batch_count() {
        files_log > "$WORK/scale-log.txt" 2>/dev/null || true
        grep -c "$1" "$WORK/scale-log.txt" 2>/dev/null || true
    }
    finder_shot() {
        local id; id="$(finder_id)"
        [ -n "$id" ] && screencapture -x -o -l"$id" "$1" 2>/dev/null
    }
    # The fake's picture is pure green; the sidebar is skipped so Finder's own
    # icons cannot count as one of ours.
    green_pixels() {
        local png="$1" skip="$2" width height
        width="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$png" 2>/dev/null)"
        height="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$png" 2>/dev/null)"
        [ -n "$width" ] && [ -n "$height" ] || { echo 0; return; }
        ffmpeg -hide_banner -loglevel error -y -i "$png" -f rawvideo -pix_fmt rgb24 "$WORK/shot.rgb" >/dev/null 2>&1 || { echo 0; return; }
        python3 - "$WORK/shot.rgb" "$width" "$height" "$skip" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
width, height, skip = int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
start = int(width * skip)
count = 0
for y in range(height):
    row = y * width * 3
    for x in range(start, width):
        i = row + x * 3
        if data[i + 1] >= 200 and data[i] <= 90 and data[i + 2] <= 90:
            count += 1
print(count)
PY
    }
    wait_first_picture() { # <label> <start_ms> <limit_s> -> "ms pixels" or "-1 pixels"
        local label="$1" start="$2" limit="$3" png
        png="$SHOTS/first-$label.png"
        local deadline=$((SECONDS + limit)) px=0
        while [ $SECONDS -lt $deadline ]; do
            if finder_shot "$png"; then
                px="$(green_pixels "$png" 0.35)"
                if [ "${px:-0}" -ge 1000 ]; then
                    echo "$(( $(now_ms) - start )) ${px:-0}"
                    return 0
                fi
            fi
            sleep 0.2
        done
        echo "-1 ${px:-0}"
        return 1
    }

    finder_close
    local open_start open_line start_ms start_px
    open_start="$(now_ms)"
    finder_folder "$bulk"
    if open_line="$(wait_first_picture start "$open_start" 40)"; then
        read -r start_ms start_px <<< "$open_line"
        ok "FILES-THUMBS-SCALE [FILES-30] first picture $start_ms ms after the view opened (${start_px} px)"
    else
        read -r start_ms start_px <<< "$open_line"
        bad "FILES-THUMBS-SCALE no picture within 40 s of opening the view (${start_px} px)"
        start_ms=-1
    fi

    # -- The scrolls ---------------------------------------------------------
    # 240 px per event: 200 events = 48,000 px, about half of the grid's
    # ~600 rows; the end is another 72,000 px, which clamps on the last row.
    scroll_finder() { # <events> [amount] [pixels|line]
        local id; id="$(finder_id)"
        [ -n "$id" ] || return 1
        if [ "${3:-pixels}" = "line" ]; then
            cg_input scroll --window "$id" --owner Finder --dy -"${2:-20}" --repeat "$1" --delay-ms 8
        else
            cg_input scroll --window "$id" --owner Finder --dy -"${2:-240}" --repeat "$1" --delay-ms 8 --pixels
        fi
    }
    scroll_picture() { # <label> <events> <limit_s> -> "ms pixels"
        local label="$1" events="$2" limit="$3" start png
        png="$SHOTS/scroll-$label.png"
        local before after
        before="$(batch_count 'thumb batch open')"
        start="$(now_ms)"
        scroll_finder "$events" || return 1
        sleep 1
        after="$(batch_count 'thumb batch open')"
        if [ "${after:-0}" -le "${before:-0}" ]; then
            # The pixel gesture moved nothing (some views ignore pixel units):
            # a line gesture is the wheel every other check uses.
            scroll_finder 60 20 line
        fi
        local deadline=$((SECONDS + limit)) px=0
        while [ $SECONDS -lt $deadline ]; do
            if finder_shot "$png"; then
                px="$(green_pixels "$png" 0.35)"
                if [ "${px:-0}" -ge 1000 ]; then
                    echo "$(( $(now_ms) - start )) ${px:-0}"
                    return 0
                fi
            fi
            sleep 0.2
        done
        echo "-1 ${px:-0}"
        return 1
    }

    local middle_line middle_ms middle_px
    if middle_line="$(scroll_picture middle 200 20)"; then
        read -r middle_ms middle_px <<< "$middle_line"
        ok "FILES-THUMBS-SCALE [FILES-30] first picture $middle_ms ms after the middle scroll (${middle_px} px)"
    else
        read -r middle_ms middle_px <<< "$middle_line"
        bad "FILES-THUMBS-SCALE no picture at the middle within 20 s (${middle_px} px)"
        middle_ms=-1
    fi
    sleep 2
    local end_line end_ms end_px
    if end_line="$(scroll_picture end 300 20)"; then
        read -r end_ms end_px <<< "$end_line"
        ok "FILES-THUMBS-SCALE [FILES-30] first picture $end_ms ms after the end scroll (${end_px} px)"
    else
        read -r end_ms end_px <<< "$end_line"
        bad "FILES-THUMBS-SCALE no picture at the end within 20 s (${end_px} px)"
        end_ms=-1
    fi
    finder_shot "$SHOTS/after-files-thumbs-scale-end.png" \
        && { cp "$SHOTS/after-files-thumbs-scale-end.png" "$WORK/" 2>/dev/null || true; \
             ok "FILES-THUMBS-SCALE screenshot: $SHOTS/after-files-thumbs-scale-end.png"; }

    # -- Scroll back to the start --------------------------------------------
    # Does Finder re-ask a cancelled id when it scrolls back over it? New batch
    # lines after the up-scroll are the only evidence the extension can see,
    # and they carry ids and counts only (FILES-27).
    sleep 2
    local back_before back_after
    back_before="$(batch_count 'thumb batch open')"
    scroll_back_finder() {
        local id; id="$(finder_id)"
        [ -n "$id" ] || return 1
        # 400 x 240 px, then wheel lines: the two gestures the other scrolls
        # fall back between, so a view that ignores pixel units still moves.
        cg_input scroll --window "$id" --owner Finder --dy 240 --repeat 400 --delay-ms 8 --pixels
        cg_input scroll --window "$id" --owner Finder --dy 20 --repeat 300 --delay-ms 8
    }
    scroll_back_finder || true
    sleep 3
    back_after="$(batch_count 'thumb batch open')"
    say "FILES-THUMBS-SCALE recorded: scroll-back opened $(( ${back_after:-0} - ${back_before:-0} )) new batches (Finder re-asks a cancelled id if > 0)"

    # -- What Finder asked and cancelled -------------------------------------
    sleep 5
    finder_close
    local opens cancels dones sizes
    opens="$(batch_count 'thumb batch open')"; opens="${opens:-0}"
    # Every batch completes once, including the ones the scroll cancelled: the
    # extension's done line follows the last answer. A base build without the
    # lines records 0/0, which the before run reads as "not logged".
    local waited=0
    while [ "$waited" -lt 30 ]; do
        dones="$(batch_count 'thumb batch done')"; dones="${dones:-0}"
        if [ "$opens" = "0" ] || [ "$dones" -ge "$opens" ]; then break; fi
        sleep 1
        waited=$((waited + 1))
    done
    cancels="$(batch_count 'thumb batch cancel')"; cancels="${cancels:-0}"
    sizes="$(sed -n 's/.*thumb batch open id=[0-9]* n=\([0-9]*\) .*/n=\1/p' "$WORK/scale-log.txt" | sort | uniq -c | tr '\n' ' ')"
    say "FILES-THUMBS-SCALE batches: open=$opens cancel=$cancels done=$dones sizes=${sizes:-none}"
    if [ "$opens" = "0" ]; then
        say "FILES-THUMBS-SCALE recorded: the build has no batch lines (before run)"
    elif [ "$dones" -ge "$opens" ]; then
        ok "FILES-THUMBS-SCALE [FILES-25] every batch completed ($dones of $opens)"
    else
        bad "FILES-THUMBS-SCALE $dones of $opens batches completed"
    fi
    say "FILES-THUMBS-SCALE recorded: batch sizes ${sizes:-none}; cancels $cancels"
    say "FILES-THUMBS-SCALE recorded: first picture start=${start_ms} ms middle=${middle_ms} ms end=${end_ms} ms"

    if grep -Eq 'img[0-9]{4}\.jpg' "$WORK/scale-log.txt"; then
        bad "FILES-THUMBS-SCALE [FILES-27] a file name appears in the thumbnail log"
    else
        ok "FILES-THUMBS-SCALE [FILES-27] the thumbnail log carries no file name"
    fi
    if grep -q 'fetch done' "$WORK/scale-log.txt"; then
        bad "FILES-THUMBS-SCALE [FILES-23] the thumbnail materialized the file"
    else
        ok "FILES-THUMBS-SCALE [FILES-23] no fetchContents: the items stayed undownloaded"
    fi
    if grep -q 'thumb failed code=fs_busy' "$WORK/scale-log.txt"; then
        bad "FILES-THUMBS-SCALE the Mac exceeded the phone's 3 live thumb ids"
    else
        ok "FILES-THUMBS-SCALE [FILES-25] the phone never answered fs_busy"
    fi

    stop_app
    files_oneshot remove "$WORK/remove.txt" >/dev/null 2>&1 || true
    unregister_files >/dev/null 2>&1 || true
    stop_fakephone
    wait_until 5 no_fakephone
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
    stale_domain_folder() { ls -d "$HOME"/Library/CloudStorage/Contigua-* >/dev/null 2>&1; }
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
    wait_until "$FILES_SWITCH_WAIT_S" files_root_lists "$root" \
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

    # -- A relaunch still works (the v103 regression) -------------------------
    # The bridge socket is process state. ensureDomain() used to return as soon
    # as the domain existed, before starting it, so after an app restart the
    # extension had nothing to reach: "Your device couldn't connect to the
    # server". Restart with the domain present and list again.
    # The VM's --files-domain add is the privileged shortcut and does not write
    # the setting a person's Settings toggle writes; set it first, or the
    # relaunch starts with Finder files off (a state the product never has with
    # the domain present) and the extension goes offline.
    defaults write "$DEFAULTS_SUITE" files.showInFinder -bool true
    stop_app
    launch --connect "127.0.0.1:$PORT"
    wait_until 30 eval 'events_have "\"state\":\"paired\"" || events_have "\"state\":\"auth_ok\""' \
        || bad "FILES the relaunch never authenticated"
    wait_until "$FILES_RELAUNCH_WAIT_S" files_root_lists "$root" \
        && ok "FILES a relaunch with the domain present lists again (the bridge came up)" \
        || bad "FILES a relaunch with the domain present lists nothing"

    # -- The location names the phone (user request, "Fixes 10-20") -----------
    # The domain was added at launch, before any phone was known; the session
    # then remembered the phone and its name, and the domain was updated in
    # place. The location is "Contigua (<the name every surface uses>)".
    wait_until 60 files_display_is "Contigua (FakePhone)" \
        && ok "FILES the Finder location is \"Contigua (FakePhone)\"" \
        || bad "FILES the location is \"$(files_display_name)\", wanted \"Contigua (FakePhone)\""

    # -- A fetch is one round trip, not twenty seconds ("Fixes 10-20") --------
    # The extension used to wait for a terminal reply that never came, until
    # the socket's 20 s receive timeout: a 412-byte Quick Look file took 20 s,
    # twice. The budget is docs/NFR.md's fetch_small_ms.
    local small_size small_ms small_log big_ms big_log fetch_limit
    fetch_limit="$(nfr_limit fetch_small_ms)"
    small_size="$(stat -f%z "$WORK/fsroot/Documents/file01.txt" 2>/dev/null || echo 0)"
    small_ms="$(files_fetch_ms_warm "$root/Documents/file01.txt")"
    big_ms="$(files_fetch_ms_warm "$root/open1m.bin")"
    files_log > "$WORK/files-log-fetch.txt" 2>/dev/null || true
    small_log="$(sed -n "s/.*fetch done bytes=$small_size ms=\([0-9]*\).*/\1/p" "$WORK/files-log-fetch.txt" | tail -1)"
    big_log="$(sed -n "s/.*fetch done bytes=1048576 ms=\([0-9]*\).*/\1/p" "$WORK/files-log-fetch.txt" | tail -1)"
    [ "$small_size" -gt 0 ] && [ "$small_size" -le 1024 ] \
        && ok "FILES the small file is $small_size bytes" \
        || bad "FILES the small file is $small_size bytes, wanted ≤ 1024"
    [ -n "$small_ms" ] && [ "$small_ms" -lt "$fetch_limit" ] \
        && ok "FILES a $small_size-byte fetch takes ${small_ms} ms (limit ${fetch_limit}; extension logged ${small_log:-?} ms)" \
        || bad "FILES the $small_size-byte fetch took ${small_ms} ms (wanted < ${fetch_limit}; extension ${small_log:-no line})"
    [ -n "$big_ms" ] && [ "$big_ms" -lt "$fetch_limit" ] \
        && ok "FILES a 1 MiB fetch takes ${big_ms} ms (limit ${fetch_limit}; extension logged ${big_log:-?} ms)" \
        || bad "FILES the 1 MiB fetch took ${big_ms} ms (wanted < ${fetch_limit}; extension ${big_log:-no line})"
    [ -n "$small_log" ] && [ "$small_log" -lt "$fetch_limit" ] \
        && ok "FILES the extension logged the small fetch at ${small_log} ms (limit ${fetch_limit})" \
        || bad "FILES the extension's small fetch line is '${small_log:-missing}'"
    [ -n "$big_log" ] && [ "$big_log" -lt "$fetch_limit" ] \
        && ok "FILES the extension logged the 1 MiB fetch at ${big_log} ms (limit ${fetch_limit})" \
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

    # -- FILES-8: Finder's own delete of a phone file -------------------------
    # The person's path: reveal the file in Finder, select it, ⌘⌫. The phone
    # has no Trash, so Finder must warn that the item will be deleted for ever
    # ("Delete Immediately"), not offer a Trash move that cannot happen.
    printf 'delete me\n' > "$WORK/fsroot/Documents/finder-delete.txt"
    wait_until 120 eval "[ -f \"$root/Documents/finder-delete.txt\" ]" \
        && ok "FILES the file for the Finder delete is in the mount" \
        || bad "FILES the Finder-delete file never appeared in the mount"
    cat > "$WORK/finder-delete.sh" <<SH
#!/bin/bash
set -e
osascript <<OSA
tell application "Finder"
    activate
    set folderRef to (POSIX file "$root/Documents") as alias
    open folderRef
    delay 1.5
    set target to file "finder-delete.txt" of folderRef
    set selection to {target}
    delay 0.5
end tell
tell application "System Events"
    tell process "Finder"
        key code 51 using command down
        delay 1.5
    end tell
end tell
OSA
/usr/sbin/screencapture -x "$WORK/finder-delete.png"
osascript <<OSA
tell application "System Events"
    tell process "Finder"
        set dialogTexts to {}
        set dialogButtons to {}
        repeat with w in windows
            try
                set dialogTexts to dialogTexts & (value of every static text of w)
            end try
            try
                set dialogButtons to dialogButtons & (name of every button of w)
            end try
            try
                set dialogTexts to dialogTexts & (value of every static text of sheet 1 of w)
                set dialogButtons to dialogButtons & (name of every button of sheet 1 of w)
            end try
        end repeat
        do shell script "printf '%s' " & quoted form of (dialogTexts as string) & " > " & quoted form of "$WORK/finder-dialog.txt"
        do shell script "printf '%s' " & quoted form of (dialogButtons as string) & " > " & quoted form of "$WORK/finder-buttons.txt"
        key code 36
        delay 1
    end tell
end tell
OSA
SH
    if gui_run bash "$WORK/finder-delete.sh" > "$WORK/finder-delete.log" 2>&1; then
        ok "FILES Finder selected the phone file and pressed ⌘⌫"
    else
        bad "FILES Finder could not delete the file: $(tail -2 "$WORK/finder-delete.log" | tr '\n' ' ')"
    fi
    sleep 2
    if grep -qi "immediately" "$WORK/finder-dialog.txt" 2>/dev/null; then
        ok "[FILES-8] Finder warns that the item is deleted immediately ($(head -c 160 "$WORK/finder-dialog.txt"))"
    else
        bad "[FILES-8] Finder did not show a Delete Immediately warning: \"$(cat "$WORK/finder-dialog.txt" 2>/dev/null | head -c 200)\" buttons: \"$(cat "$WORK/finder-buttons.txt" 2>/dev/null | head -c 120)\""
    fi
    ! grep -qi "Move to Trash" "$WORK/finder-buttons.txt" "$WORK/finder-dialog.txt" 2>/dev/null \
        && ok "[FILES-8] Finder did not offer a Trash move for a phone file" \
        || bad "[FILES-8] Finder offered Move to Trash for the location (a bug: the phone has no Trash)"
    wait_until 120 eval "[ ! -f \"$WORK/fsroot/Documents/finder-delete.txt\" ]" \
        && ok "[FILES-8] the delete reached the phone" \
        || bad "[FILES-8] the file is still on the phone after Finder's delete"
    [ ! -e "$WORK/fsroot/.Trash/finder-delete.txt" ] \
        && ok "[FILES-8] nothing landed in a phone-side Trash" \
        || bad "[FILES-8] the delete left a copy in .Trash"

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
    # The nickname path Settings ▸ Phones ▸ Rename uses (`--set-nickname`),
    # on a second launch so the first one's "Contigua (FakePhone)" above is a
    # settled state. The domain is re-added with the same identifier and the
    # new display name: macOS updates it, so the CloudStorage folder and its
    # cached files stay (the same inode, and the root still lists).
    local folder_before inode_before
    folder_before="$(ls -d "$HOME"/Library/CloudStorage/Contigua-* 2>/dev/null | head -1)"
    inode_before="$(stat -f%i "$folder_before" 2>/dev/null || true)"
    kill_e2e_app
    wait_until 20 eval '[ -z "$(e2e_app_pids)" ]' || true
    launch --connect "127.0.0.1:$PORT" --files-domain add --set-nickname "Nicky"
    wait_until 30 eval 'events_have "\"state\":\"auth_ok\"" || events_have "\"state\":\"paired\""' \
        || bad "FILES the rename launch never authenticated"
    wait_until 60 files_display_is "Contigua (Nicky)" \
        && ok "FILES a nickname rename updates the location to \"Contigua (Nicky)\"" \
        || bad "FILES the location after the rename is \"$(files_display_name)\", wanted \"Contigua (Nicky)\""
    local folder_after inode_after root_after
    folder_after="$(ls -d "$HOME"/Library/CloudStorage/Contigua-* 2>/dev/null | head -1)"
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


# --- Dock apps (docs/design/dock.md) --------------------------------------

# Dock apps of this run live only in $WORK/dock-apps, never in ~/Applications.
dock_dir() { echo "$WORK/dock-apps"; }

dock_shim_pids() { [ -n "${WORK:-}" ] && pgrep -f -- "$(dock_dir)/.*/Contents/MacOS/ContiguaShim"; }

# dock_shim_ready — the first built bundle is complete: icon written and signed
# (the directory appears while the build is still writing into it).
dock_shim_ready() {
    local shim
    shim="$(ls -d "$(dock_dir)"/*.app 2>/dev/null | head -1)"
    [ -n "$shim" ] && [ -s "$shim/Contents/Resources/AppIcon.icns" ] \
        && codesign --verify --strict "$shim" 2>/dev/null
}

# window_close_count — window.close messages the fakephone has received (the
# app sends one when a person closes a stream window).
window_close_count() { awk '/"ev":"rx"/ && /"t":"window.close"/ {n++} END {print n+0}' "$WORK/events.jsonl"; }

# Dock apps made from the profile folder are the automatic ones (a check that
# opens app windows without --dock-dir). Every run cleans its own.
profile_dock_dir() { echo "$HOME/Library/Application Support/Contigua-$PROFILE/Dock Apps"; }

# icon_pixel <png> <x> <y> — "R G B A" of one pixel of a rendered icon.
icon_pixel() {
    ffmpeg -v error -i "$1" -vf "crop=1:1:$2:$3" -f rawvideo -pix_fmt rgba - 2>/dev/null \
        | od -An -tu1 | tr -s ' ' | sed 's/^ //;s/ $//'
}

# near <pixel> <r> <g> <b> <tolerance> — the pixel's RGB is within tolerance.
near() {
    echo "$1" | awk -v r="$2" -v g="$3" -v b="$4" -v t="$5" '{
        dr = $1 - r; dg = $2 - g; db = $3 - b
        exit !((dr * dr + dg * dg + db * db) <= t * t)
    }'
}

# remove_dock_apps — this run's shims stop, leave LaunchServices and the disk.
remove_dock_apps() {
    [ -n "${WORK:-}" ] || return 0
    local pids app
    pids="$(dock_shim_pids)"
    [ -n "$pids" ] && kill $pids >/dev/null 2>&1
    pids="$(pgrep -f -- "$(profile_dock_dir)/.*/Contents/MacOS/ContiguaShim")"
    [ -n "$pids" ] && kill $pids >/dev/null 2>&1
    for app in "$(dock_dir)"/*.app "$(profile_dock_dir)"/*.app; do
        [ -d "$app" ] || continue
        # Bounded: a stalled LaunchServices made this step the VM run's hang.
        run_limited 15 "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
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

# rx_size <type> — the last message of that type the phone received, as WxH
# pixels from its own w/h fields (a link or handoff open's stream size).
rx_size() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
size = "none"
for line in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") != "rx":
        continue
    msg = event.get("msg") or {}
    if msg.get("t") == sys.argv[2]:
        size = "%sx%s" % (msg.get("w"), msg.get("h"))
print(size)
PY
}

# stream_after_close <stream> — what the fakephone received for that stream
# after the Mac's window.close for it, as the message types in arrival order
# ("none" when nothing). The phone forgets a stream at its close, so anything
# the Mac still sends for it comes back `error no_stream` (WIN-38).
stream_after_close() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
stream = int(sys.argv[2])
closed = False
late = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if event.get("ev") == "rx" and msg.get("t") == "window.close" and msg.get("stream") == stream:
        closed = True
        continue
    if not closed:
        continue
    if event.get("ev") == "rx" and msg.get("stream") == stream:
        late.append(str(msg.get("t")))
    elif event.get("ev") == "input" and event.get("stream") == stream:
        late.append("input:" + str(event.get("kind")))
print(",".join(late) if late else "none")
PY
}

# window_open_count <pkg> — how many window.open the fakephone received for the
# package (the raise rule: one, however many times the entry point is used).
window_open_count() {
    python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if event.get("ev") == "rx" and msg.get("t") == "window.open" and msg.get("pkg") == sys.argv[2]:
        count += 1
print(count)
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
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" \
        --debug-control "$WORK-control" --quit-after 120
    shim_made() { ls -d "$dir"/*.app >/dev/null 2>&1; }
    wait_until 30 shim_made || { bad "DOCK no Dock app created in $dir"; stop_app; stop_fakephone; return 1; }
    shim="$(ls -d "$dir"/*.app | head -1)"
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$shim/Contents/Info.plist" 2>/dev/null)"
    [ "$(basename "$shim")" = "WhatsApp (FakePhone).app" ] && [ "$id" = "app.contigua.dock.$PROFILE.$(/usr/libexec/PlistBuddy -c 'Print :PDDeviceId' "$shim/Contents/Info.plist").com-whatsapp" ] \
        && ok "DOCK created $(basename "$shim") ($id)" || bad "DOCK unexpected bundle $(basename "$shim") ($id)"
    wait_until 15 dock_shim_ready
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

    # The shim launched again (Launchpad, Spotlight, a Dock click) raises the
    # window it stands for instead of relaunching the app on the phone.
    local dock_opens dock_wins
    dock_opens="$(count_events '"t":"window.open"' | head -1)"
    dock_wins="$(windows | wc -l | tr -d ' ')"
    open_quiet "$shim"
    sleep 3
    [ "$(count_events '"t":"window.open"' | head -1)" = "$dock_opens" ] \
        && ok "[WIN-2] DOCK a second shim launch sent no window.open (still $dock_opens)" \
        || bad "[WIN-2] DOCK the shim relaunched the app on the phone"
    [ "$(windows | wc -l | tr -d ' ')" = "$dock_wins" ] \
        && ok "[WIN-2] DOCK the second shim launch raised the one window" \
        || bad "[WIN-2] DOCK the shim made a second window"
    control keywindow "$WORK/keywindow.txt" >/dev/null 2>&1 || true
    [ "$(sed -n 2p "$WORK/keywindow.txt" 2>/dev/null)" = "WhatsApp (FakePhone)" ] \
        && ok "[WIN-2] DOCK the raised window is key and front" \
        || bad "[WIN-2] DOCK the shim did not raise the window ($(tr '\n' '|' < "$WORK/keywindow.txt" 2>/dev/null))"

    kill $(dock_shim_pids) >/dev/null 2>&1
    wait_until 15 window_rx window.close \
        && ok "DOCK quitting the shim -> window.close" || bad "DOCK quitting the shim did not close the window"
    wait_until 10 eval '[ "$(windows | wc -l | tr -d " ")" -le "$before" ]' \
        && ok "DOCK the window is gone" || bad "DOCK the window is still open"
    stop_app
    remove_dock_apps

    # Automatic identity (default on): a window the app opens itself builds and
    # launches its shim, and the shim exits when the window closes.
    local auto_opens auto_closes
    auto_opens="$(window_open_count "$pkg")"
    auto_closes="$(window_close_count)"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" --close-stream 1:20 --quit-after 60
    wait_until 30 eval '[ "$(window_open_count "$pkg")" -gt "$auto_opens" ]' \
        && ok "DOCK auto: window.open arrived for $pkg" || bad "DOCK auto: no window.open for $pkg"
    wait_until 30 shim_made \
        && ok "DOCK auto: the window's Dock app was created ($(ls "$dir" | head -1))" \
        || bad "DOCK auto: no Dock app was created in $dir"
    wait_until 10 eval '[ -n "$(dock_shim_pids)" ]' \
        && ok "DOCK auto: the shim runs for the window (pid $(dock_shim_pids | tr '\n' ' '))" \
        || bad "DOCK auto: the shim is not running"
    # The close timer counts from the app becoming ready, so wait for the close
    # itself before judging the shim: a loaded Mac can run that timer seconds
    # late, and the exit has to be measured from the close.
    wait_until 30 eval '[ "$(window_close_count)" -gt "$auto_closes" ]' \
        && ok "DOCK auto: the window closed" || bad "DOCK auto: the window never closed"
    wait_until 20 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "DOCK auto: closing the window made the shim exit" || bad "DOCK auto: the shim outlives the window"
    stop_app
    wait_until 5 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "DOCK auto: quitting the app leaves no shim behind" || bad "DOCK auto: a shim survived the app"
    remove_dock_apps

    # A slow shim registers its observers after the host bound it
    # (--dock-debug-listen-delay, written into the bundle as PDListenDelay). The
    # bind's one `opened` is gone by then, so the shim must say it is listening
    # and be answered (docs/design/dock.md §Launch → window). While that answer
    # was lost, the shim quit at 30 s and closed the window with it.
    local ack_opens ack_closes ack_windows ack_started ack_pid ack_dump ack_ms
    ack_opens="$(window_open_count "$pkg")"
    ack_closes="$(window_close_count)"
    ack_started="$(date +%s)"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" \
        --dock-debug-listen-delay 2 --quit-after 60
    wait_until 30 eval '[ "$(window_open_count "$pkg")" -gt "$ack_opens" ]' \
        && ok "[DOCK-17] dock ack: window.open arrived for $pkg" \
        || { bad "[DOCK-17] dock ack: no window.open for $pkg"; stop_app; stop_fakephone; return 1; }
    wait_until 30 eval '[ -n "$(dock_shim_pids)" ]' \
        && ok "[DOCK-17] dock ack: the late-listening shim runs" \
        || { bad "[DOCK-17] dock ack: the shim never ran"; stop_app; stop_fakephone; return 1; }
    ack_pid="$(dock_shim_pids | head -1)"
    ack_windows="$(windows | wc -l | tr -d ' ')"
    while [ $(( $(date +%s) - ack_started )) -lt 40 ]; do sleep 1; done
    if [ -n "$ack_pid" ] && kill -0 "$ack_pid" 2>/dev/null; then
        ok "[DOCK-17] dock ack: the shim is alive 40 s after launch (pid $ack_pid)"
    else
        bad "[DOCK-17] dock ack: the shim quit before 40 s (pid ${ack_pid:-none}; launched at $ack_started, checked at $(date +%s))"
    fi
    [ "$(window_close_count)" = "$ack_closes" ] \
        && ok "[DOCK-17] dock ack: the window is still open at 40 s" \
        || bad "[DOCK-17] dock ack: the window closed at $(date +%s) (launched at $ack_started, $(( $(window_close_count) - ack_closes )) window.close sent)"
    [ "$(windows | wc -l | tr -d ' ')" -ge "$ack_windows" ] \
        && ok "[DOCK-17] dock ack: the app still has its window" \
        || bad "[DOCK-17] dock ack: a window disappeared ($ack_windows -> $(windows | wc -l | tr -d ' '))"
    # Read the whole dump first: under pipefail, grep -q closing the pipe early fails the pipeline.
    ack_dump="$(log show --last 3m --info \
        --predicate 'subsystem == "app.contigua.mac" AND category == "app"' 2>/dev/null)"
    if [ -n "$ack_pid" ] && grep -qF "dock: shim $ack_pid quit; closing stream" <<< "$ack_dump"; then
        bad "[DOCK-17] dock ack: the host closed the shim's stream (shim $ack_pid quit)"
        grep -F "dock: shim $ack_pid quit; closing stream" <<< "$ack_dump" | tail -1 | sed 's/^/  /'
    else
        ok "[DOCK-17] dock ack: no 'shim quit; closing stream' for it"
    fi
    # The handshake lands at once: the shim logs how long after listening it was bound.
    ack_dump="$(log show --last 3m --info --predicate 'process == "ContiguaShim"' 2>/dev/null)"
    ack_ms="$(grep -oE "dock shim $ack_pid bound, [0-9]+ ms after listening" <<< "$ack_dump" \
        | head -1 | grep -oE '[0-9]+ ms' | tr -dc '0-9')"
    if [ -n "$ack_ms" ] && [ "$ack_ms" -le 1500 ]; then
        ok "[DOCK-17] dock ack: bound $ack_ms ms after listening"
    else
        bad "[DOCK-17] dock ack: no bind within 1.5 s of listening (${ack_ms:-no log line})"
    fi
    stop_app
    remove_dock_apps

    # A bound shim outlived a killed app (ISS-6, DOCK-19): the shim watches the
    # host's process and quits when it ends, so no icon stays in the Dock until
    # the person quits it. SIGTERM is the check; a force quit takes the same
    # didTerminateApplication road.
    local term_opens term_pid term_started
    term_opens="$(window_open_count "$pkg")"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" --quit-after 60
    wait_until 30 shim_made \
        || { bad "[DOCK-19] dock term: no Dock app created"; stop_app; stop_fakephone; return 1; }
    shim="$(ls -d "$dir"/*.app | head -1)"
    wait_until 15 dock_shim_ready \
        || { bad "[DOCK-19] dock term: the bundle never finished"; stop_app; stop_fakephone; return 1; }
    open_quiet "$shim"
    wait_until 20 eval '[ "$(window_open_count "$pkg")" -gt "$term_opens" ]' \
        || { bad "[DOCK-19] dock term: no window.open for $pkg"; stop_app; stop_fakephone; return 1; }
    wait_until 15 eval '[ -n "$(dock_shim_pids)" ]' \
        || { bad "[DOCK-19] dock term: the shim never ran"; stop_app; stop_fakephone; return 1; }
    term_pid="$(dock_shim_pids | head -1)"
    shim_gone() { ! kill -0 "$1" 2>/dev/null; }
    sleep 1
    term_started="$(path_now)"
    kill -TERM "$APP_PID" >/dev/null 2>&1
    if wait_until 3 shim_gone "$term_pid"; then
        local term_dt
        term_dt="$(python3 -c "print('%.2f' % ($(path_now) - float('$term_started')))")"
        ok "[DOCK-19] dock term: the bound shim quit ${term_dt}s after the app was killed (pid $term_pid)"
    else
        bad "[DOCK-19] dock term: the shim outlived the killed app (pid $term_pid)"
    fi
    wait "$APP_PID" 2>/dev/null
    remove_dock_apps

    # A shim bundle from an older Contigua carries an older executable, which
    # still loses the bind's answer. The next app list replaces it while its
    # shim is not running (docs/design/dock.md §Lifecycle). The installed copy
    # is re-signed per bundle, so the bundle records the source shim's hash.
    local refresh_shim="$dir/WhatsApp (FakePhone).app" refresh_pids refresh_hash
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$pkg" --quit-after 60
    # Wait for the whole bundle: stopping the app between the executable copy
    # and the plist would age a half-built bundle.
    wait_until 30 eval '[ -s "$refresh_shim/Contents/Resources/AppIcon.icns" ] && /usr/libexec/PlistBuddy -c "Print :PDShimHash" "$refresh_shim/Contents/Info.plist" >/dev/null 2>&1' \
        || { bad "[DOCK-18] dock refresh: no complete shim to age"; stop_app; stop_fakephone; return 1; }
    stop_app
    refresh_pids="$(dock_shim_pids)"
    [ -n "$refresh_pids" ] && kill $refresh_pids >/dev/null 2>&1
    refresh_hash="$(shasum -a 256 "$E2E_BUNDLE/Contents/MacOS/ContiguaShim" | awk '{print $1}')"
    [ -n "$refresh_hash" ] \
        || { bad "[DOCK-18] dock refresh: no shim executable in the e2e bundle"; stop_app; stop_fakephone; return 1; }
    /usr/libexec/PlistBuddy -c 'Delete :PDShimHash' "$refresh_shim/Contents/Info.plist" >/dev/null 2>&1
    printf 'old shim' > "$refresh_shim/Contents/MacOS/ContiguaShim"
    [ "$(stat -f%z "$refresh_shim/Contents/MacOS/ContiguaShim" 2>/dev/null)" = "8" ] \
        && ok "[DOCK-18] dock refresh: aged the bundle (no shim hash, old executable)" \
        || bad "[DOCK-18] dock refresh: could not age the bundle (hash $(/usr/libexec/PlistBuddy -c 'Print :PDShimHash' "$refresh_shim/Contents/Info.plist" 2>/dev/null))"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --quit-after 40
    wait_until 30 eval '[ -n "$refresh_hash" ] && [ "$(/usr/libexec/PlistBuddy -c "Print :PDShimHash" "$refresh_shim/Contents/Info.plist" 2>/dev/null)" = "$refresh_hash" ]' \
        && ok "[DOCK-18] dock refresh: an older bundle was rebuilt with this build's shim" \
        || bad "[DOCK-18] dock refresh: the old bundle was not rebuilt (hash $(/usr/libexec/PlistBuddy -c 'Print :PDShimHash' "$refresh_shim/Contents/Info.plist" 2>/dev/null))"
    [ -x "$refresh_shim/Contents/MacOS/ContiguaShim" ] \
        && [ "$(stat -f%z "$refresh_shim/Contents/MacOS/ContiguaShim" 2>/dev/null)" -gt 1000 ] \
        && ok "[DOCK-18] dock refresh: the replaced executable is this build's" \
        || bad "[DOCK-18] dock refresh: the executable was not replaced ($(stat -f%z "$refresh_shim/Contents/MacOS/ContiguaShim" 2>/dev/null) bytes)"
    stop_app
    remove_dock_apps

    # The race, made deterministic (reviewer 10-30): a window that closes before
    # its identity finishes launching. The pending work is dropped, so no shim is
    # ever built for a stream that is gone (docs/design/dock.md §Lifecycle).
    local race_opens race_closes
    race_opens="$(window_open_count "$pkg")"
    race_closes="$(window_close_count)"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" --close-stream 1:3 \
        --dock-launch-delay 6 --quit-after 40
    wait_until 30 eval '[ "$(window_open_count "$pkg")" -gt "$race_opens" ]' \
        && ok "DOCK auto race: window.open arrived for $pkg" \
        || { bad "DOCK auto race: no window.open for $pkg"; stop_app; stop_fakephone; return 1; }
    wait_until 15 eval '[ "$(window_close_count)" -gt "$race_closes" ]' \
        && ok "DOCK auto race: the window closed before its identity launched" \
        || bad "DOCK auto race: the window never closed"
    sleep 8
    [ -z "$(dock_shim_pids)" ] \
        && ok "DOCK auto race: no shim was built for the closed stream" \
        || bad "DOCK auto race: a shim was built for a window that was gone"
    [ "$(window_open_count "$pkg")" = "$((race_opens + 1))" ] \
        && ok "DOCK auto race: no window came back with it" \
        || bad "DOCK auto race: a late launch brought its window back"
    stop_app
    wait_until 5 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "DOCK auto race: quitting the app leaves no shim behind" || bad "DOCK auto race: a shim survived the app"
    remove_dock_apps

    # The same race with the launch already in flight: the pid that lands after
    # its window closed is quit at once and logged, never bound.
    race_opens="$(window_open_count "$pkg")"
    race_closes="$(window_close_count)"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" --close-stream 1:3 \
        --dock-bind-delay 7 --quit-after 40
    wait_until 30 eval '[ "$(window_open_count "$pkg")" -gt "$race_opens" ]' \
        && ok "DOCK auto race: window.open arrived for $pkg (late launch)" \
        || { bad "DOCK auto race: no window.open for $pkg (late launch)"; stop_app; stop_fakephone; return 1; }
    wait_until 15 eval '[ "$(window_close_count)" -gt "$race_closes" ]' \
        && ok "DOCK auto race: the window closed while the launch was in flight" \
        || bad "DOCK auto race: the window never closed (late launch)"
    sleep 9
    [ -z "$(dock_shim_pids)" ] \
        && ok "DOCK auto race: a launch landing after its window closed is quit, not bound" \
        || bad "DOCK auto race: a shim outlived the window it was launched for"
    log show --last 3m --info \
        --predicate 'subsystem == "app.contigua.mac" AND category == "app"' 2>/dev/null \
        | grep -q "dock auto: late launch for closed stream 1" \
        && ok "DOCK auto race: the late launch was logged as a decision" \
        || bad "DOCK auto race: no 'late launch for closed stream' line"
    stop_app
    remove_dock_apps

    # A launch still in flight when the app quits: the shim it started is stopped
    # with the app, so the second assertion holds for a launch at quit too.
    race_opens="$(window_open_count "$pkg")"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$pkg" \
        --dock-bind-delay 20 --quit-after 6
    wait_until 30 eval '[ "$(window_open_count "$pkg")" -gt "$race_opens" ]' \
        && ok "DOCK auto race: window.open arrived for $pkg (quit)" \
        || { bad "DOCK auto race: no window.open for $pkg (quit)"; stop_app; stop_fakephone; return 1; }
    wait_until 15 eval '[ -n "$(dock_shim_pids)" ]' \
        && ok "DOCK auto race: the shim runs while its launch callback has not landed" \
        || bad "DOCK auto race: the shim never started"
    wait_until 15 eval '[ -z "$(e2e_app_pids)" ]' \
        || { bad "DOCK auto race: the app did not quit"; stop_app; stop_fakephone; return 1; }
    wait_until 5 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "DOCK auto race: quitting the app stops a shim it launched but never bound" \
        || bad "DOCK auto race: a shim it launched but never bound survived the app"
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
    remove_dock_apps

    # Icons (docs/design/dock.md §Icons): an adaptive app's shim carries one
    # 1024 px render in the macOS grid — PDIconVersion, clear corners, the bg
    # colour at the centre and the fg just off it — not a 96 px upscale.
    local adaptive="com.android.chrome" chrome version big corner centre inside
    chrome="$dir/Chrome (FakePhone).app"
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "$adaptive" --quit-after 60
    wait_until 30 eval '[ -d "$chrome" ]' \
        || { bad "DOCK icon: no shim for $adaptive"; stop_app; stop_fakephone; return 1; }
    # The bundle's folder exists a moment before its .icns is written (the
    # same gap the flat icons below wait out): stopping the app here would
    # leave the shim iconless and fail a check the app never finished.
    wait_until 30 eval '[ -f "$chrome/Contents/Resources/AppIcon.icns" ]'
    stop_app
    version="$(/usr/libexec/PlistBuddy -c 'Print :PDIconVersion' "$chrome/Contents/Info.plist" 2>/dev/null)"
    case "$version" in
        ''|*[!0-9]*) bad "DOCK icon: no PDIconVersion in the shim" ;;
        *) [ "$version" -ge 1 ] && ok "DOCK icon: PDIconVersion $version" \
               || bad "DOCK icon: PDIconVersion is $version" ;;
    esac
    if [ ! -f "$chrome/Contents/Resources/AppIcon.icns" ]; then
        bad "DOCK icon: the shim has no AppIcon.icns ($(ls "$chrome/Contents/Resources" 2>/dev/null | tr '\n' ' '))"
    else
        # sips renders the largest representation of the .icns, so its pixel
        # side is the top size the bundle carries.
        big="$WORK/shim-icon.png"
        sips -s format png "$chrome/Contents/Resources/AppIcon.icns" --out "$big" >/dev/null 2>&1
        local side
        side="$(sips -g pixelWidth "$big" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
        [ "$side" = "1024" ] \
            && ok "DOCK icon: the .icns's largest image is 1024 px" \
            || bad "DOCK icon: the .icns's largest image is ${side:-none} px"
        if [ "$side" = "1024" ]; then
            corner="$(icon_pixel "$big" 2 2)"
            centre="$(icon_pixel "$big" 512 512)"
            inside="$(icon_pixel "$big" 256 512)"
            if [ "$(echo "$corner" | awk '{print $4}')" = "0" ]; then
                ok "DOCK icon: the canvas corners are transparent"
            else
                bad "DOCK icon: a corner pixel is not transparent ($corner)"
            fi
            near "$centre" 255 255 255 4 \
                && ok "DOCK icon: the centre is the phone's bg colour ($centre)" \
                || bad "DOCK icon: the centre is not the bg colour ($centre)"
            near "$inside" 51 144 236 12 \
                && ok "DOCK icon: the fg layer is drawn on top ($inside)" \
                || bad "DOCK icon: the fg layer is missing ($inside)"
        fi
    fi

    # A shim from an older renderer is rebuilt the next time it is followed,
    # and LaunchServices re-reads it so the Dock shows the new icon.
    /usr/libexec/PlistBuddy -c 'Set :PDIconVersion 0' "$chrome/Contents/Info.plist" 2>/dev/null
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --open "$adaptive" --close-stream 1:12 --quit-after 45
    wait_until 40 eval '[ "$(/usr/libexec/PlistBuddy -c "Print :PDIconVersion" "$chrome/Contents/Info.plist" 2>/dev/null)" -ge 1 ] 2>/dev/null' \
        && ok "DOCK icon: an old-version shim was rebuilt" \
        || bad "DOCK icon: the old-version shim was not rebuilt"

    # A flat-only app's shim carries the same renderer (docs/design/dock.md
    # §Icons), drawn from the Dock's own 864 px flat: the rounded square covers
    # its tile and the disc keeps its white plate.
    local cover_app="$dir/Camera (FakePhone).app" plate_app="$dir/Gallery (FakePhone).app" flat_edge
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "com.android.camera2" --quit-after 90
    # The phone answers one session at a time; a busy one is retried with a
    # backoff, so this can take a while on a loaded host. Wait for the icon
    # itself, not the bundle's folder: the bundle exists a moment before its
    # .icns is written, and stopping the app in that gap leaves it iconless.
    wait_until 60 eval '[ -f "$cover_app/Contents/Resources/AppIcon.icns" ]' \
        || { bad "DOCK icon: no shim icon for the covering flat icon"; stop_app; stop_fakephone; return 1; }
    stop_app
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --dock-add "com.android.gallery3d" --quit-after 90
    wait_until 60 eval '[ -f "$plate_app/Contents/Resources/AppIcon.icns" ]' \
        || { bad "DOCK icon: no shim icon for the plating flat icon"; stop_app; stop_fakephone; return 1; }
    stop_app
    if [ -f "$cover_app/Contents/Resources/AppIcon.icns" ] \
        && [ -f "$plate_app/Contents/Resources/AppIcon.icns" ]; then
        sips -s format png "$cover_app/Contents/Resources/AppIcon.icns" \
            --out "$WORK/shim-cover.png" >/dev/null 2>&1
        sips -s format png "$plate_app/Contents/Resources/AppIcon.icns" \
            --out "$WORK/shim-plate.png" >/dev/null 2>&1
        flat_edge="$(icon_pixel "$WORK/shim-cover.png" 120 512)"
        near "$flat_edge" 0 128 96 8 \
            && ok "DOCK icon: a flat square covers its tile ($flat_edge)" \
            || bad "DOCK icon: the flat square did not cover ($flat_edge)"
        flat_edge="$(icon_pixel "$WORK/shim-plate.png" 120 512)"
        near "$flat_edge" 255 255 255 4 \
            && ok "DOCK icon: a flat disc keeps its white plate ($flat_edge)" \
            || bad "DOCK icon: the flat disc's plate is not white ($flat_edge)"
        flat_edge="$(icon_pixel "$WORK/shim-plate.png" 512 512)"
        near "$flat_edge" 200 60 60 8 \
            && ok "DOCK icon: the disc's own colour is inside the plate ($flat_edge)" \
            || bad "DOCK icon: the disc is not drawn ($flat_edge)"
    else
        bad "DOCK icon: a flat app's shim has no AppIcon.icns"
    fi
    remove_dock_apps

    # A visible run (the VM) records what the person sees: the Dock with a
    # phone app's shim next to the native icons, and the Deck grid.
    if [ "$VISIBLE" = "1" ]; then
        sleep 2
        screencapture -x "$WORK/shot-dock.png" >/dev/null 2>&1 \
            && ok "DOCK screenshot: $WORK/shot-dock.png" || say "no Dock screenshot"
        local deck_window
        if deck_window="$(await_window '$4 >= 600')"; then
            screencapture -x -l"$deck_window" "$WORK/shot-deck.png" >/dev/null 2>&1 \
                && ok "DOCK screenshot: Deck grid $WORK/shot-deck.png" || say "no Deck screenshot"
        fi
    fi
    stop_app
    remove_dock_apps

    stop_fakephone
    wait_until 5 no_fakephone
}

# --- Application shortcuts (docs/specs/dock.md) ---------------------------

# origins_of <bundle> — the shim's PDOrigins as one spaced string ("dock manual").
origins_of() {
    python3 - "$1/Contents/Info.plist" <<'PY'
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as handle:
        print(" ".join(plistlib.load(handle).get("PDOrigins", [])))
except Exception:
    print("")
PY
}

# check_shortcuts — DOCK-3 and DOCK-4: the Deck tile's menu actions (through the
# debug control route the Dock checks use, because a context menu cannot be
# clicked in a quiet run). Add to Applications creates the shim in the run's
# folder with the manual reason and opens no window; Add to Dock adds its reason
# and launches; Remove from Applications takes only manual; Remove from Dock App
# removes the bundle. Save all, reconcile, forget and Spotlight follow below.
check_shortcuts() {
    clean
    local dir="$WORK/dock-apps" pkg="com.whatsapp" shim label="WhatsApp (FakePhone).app"
    remove_dock_apps
    mkdir -p "$dir" "$WORK-control"
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --debug-control "$WORK-control" --quit-after 300
    wait_until 30 events_have '"t":"apps.icon"' \
        || { bad "SHORTCUTS the app list never arrived"; stop_app; stop_fakephone; return 1; }
    shim="$dir/$label"

    # Add to Applications: the action the tile's item runs.
    control shortcut add "$pkg" || bad "SHORTCUTS shortcut add: $CONTROL_REPLY"
    wait_until 30 eval '[ -d "$shim" ]' \
        || { bad "SHORTCUTS no shortcut bundle in $dir ($(ls "$dir" 2>/dev/null | tr '\n' ' '))"; stop_app; stop_fakephone; return 1; }
    [ "$(origins_of "$shim")" = "manual" ] \
        && ok "[DOCK-4] Add to Applications creates the shortcut with the manual reason" \
        || bad "[DOCK-4] the shortcut's reasons are '$(origins_of "$shim")'"
    [ -s "$shim/Contents/Resources/AppIcon.icns" ] \
        && ok "[DOCK-4] the shortcut carries the app's own icon" \
        || bad "[DOCK-4] the shortcut has no AppIcon.icns"
    [ "$(count_events '"t":"window.open"' | head -1)" = "0" ] \
        && ok "[DOCK-14] adding a shortcut launched nothing" \
        || bad "[DOCK-14] adding a shortcut opened a window"

    # Add to Dock on the same app: both reasons, and the Dock identity runs.
    control dock add "$pkg" || bad "SHORTCUTS dock add: $CONTROL_REPLY"
    wait_until 20 window_rx window.open "$pkg" \
        && ok "[DOCK-3] Add to Dock launched the app's window" \
        || bad "[DOCK-3] Add to Dock opened no window"
    wait_until 20 eval '[ "$(origins_of "$shim")" = "dock manual" ]' \
        && ok "[DOCK-3] Add to Dock kept the shortcut's manual reason" \
        || bad "[DOCK-3] the reasons after Add to Dock are '$(origins_of "$shim")'"

    # Remove from Applications: only manual goes; the Dock shim and its window stay.
    control shortcut remove "$pkg" || bad "SHORTCUTS shortcut remove: $CONTROL_REPLY"
    wait_until 20 eval '[ "$(origins_of "$shim")" = "dock" ]' \
        && ok "[DOCK-4] Remove from Applications removes only manual" \
        || bad "[DOCK-4] the reasons after Remove from Applications are '$(origins_of "$shim")'"
    [ -d "$shim" ] && ok "[DOCK-4] the Dock's shim stays" || bad "[DOCK-4] the Dock's shim was deleted"
    [ -n "$(dock_shim_pids)" ] && ok "[DOCK-4] its running identity stays" \
        || bad "[DOCK-4] Remove from Applications stopped the Dock identity"

    # Remove from Dock App: the bundle goes and the shim stops.
    control dock remove "$pkg" || bad "SHORTCUTS dock remove: $CONTROL_REPLY"
    wait_until 20 eval '[ ! -d "$shim" ]' \
        && ok "[DOCK-3] Remove from Dock App removes the bundle" \
        || bad "[DOCK-3] the bundle is still there after Remove from Dock App"
    wait_until 10 eval '[ -z "$(dock_shim_pids)" ]' \
        && ok "[DOCK-3] its shim stopped" || bad "[DOCK-3] the shim kept running"

    stop_app
    remove_dock_apps

    # --- Save all (docs/design/dock.md §Shortcuts, SET-DEV-25) -------------
    # 40 fakephone apps, the switch on through the page's own write path: one
    # shortcut per app, each with its icon, and no window opened along the way.
    count_shims() { ls -d "$dir"/*.app 2>/dev/null | wc -l | tr -d ' '; }
    count_icons() { local n=0 app; for app in "$dir"/*.app; do [ -s "$app/Contents/Resources/AppIcon.icns" ] && n=$((n + 1)); done; echo "$n"; }
    stop_fakephone
    FAKE_ARGS="--demo-apps 40" start_fake || { stop_fakephone; return 1; }
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --debug-control "$WORK-control" --quit-after 420
    wait_until 30 events_have '"t":"apps.icon"' \
        || { bad "SHORTCUTS the save-all app list never arrived"; stop_app; stop_fakephone; return 1; }
    control shortcutsall on || bad "SHORTCUTS save-all phase: shortcutsall on: $CONTROL_REPLY"
    wait_until 60 eval '[ "$(count_shims)" = "40" ]' || true
    if [ "$(count_shims)" != "40" ]; then
        control shortcutstats "$WORK/shortcut-stats.txt" >/dev/null 2>&1
        say "shortcuts after 60 s: $(tr '\n' ' ' < "$WORK/shortcut-stats.txt" 2>/dev/null)"
    fi
    wait_until 180 eval '[ "$(count_shims)" = "40" ]' \
        && ok "[DOCK-5] Save all made all 40 app shortcuts ($(ls "$dir" 2>/dev/null | tr '\n' ' ' | cut -c1-80)…)" \
        || bad "[DOCK-5] Save all made $(count_shims) of 40 shortcuts"
    [ "$(count_icons)" = "40" ] \
        && ok "[DOCK-6] every one of the 40 shortcuts carries its .icns" \
        || bad "[DOCK-6] only $(count_icons) of 40 shortcuts have an .icns"
    control deckquery "" >/dev/null 2>&1 \
        && ok "[DOCK-6] the Deck still answers while the shims are written" \
        || bad "[DOCK-6] the Deck stopped answering during the build"
    [ "$(count_events '"t":"window.open"' | head -1)" = "0" ] \
        && ok "[DOCK-14] Save all opened no window" \
        || bad "[DOCK-14] Save all opened a window"

    # Two shortcuts the person keeps another way: one manual, one Dock. Turning
    # the switch off removes only `all`, so exactly those two stay.
    control shortcut add com.whatsapp || bad "SHORTCUTS save-all phase: shortcut add: $CONTROL_REPLY"
    control dock add com.android.chrome || bad "SHORTCUTS save-all phase: dock add: $CONTROL_REPLY"
    wait_until 30 eval '[ "$(origins_of "$dir/WhatsApp (FakePhone).app")" = "manual all" ]' \
        && ok "[DOCK-2] WhatsApp carries all and manual" \
        || bad "[DOCK-2] WhatsApp's reasons are '$(origins_of "$dir/WhatsApp (FakePhone).app")'"
    wait_until 30 eval '[ "$(origins_of "$dir/Chrome (FakePhone).app")" = "dock all" ]' \
        && ok "[DOCK-2] Chrome carries all and dock" \
        || bad "[DOCK-2] Chrome's reasons are '$(origins_of "$dir/Chrome (FakePhone).app")'"
    control shortcutsall off || bad "SHORTCUTS save-all phase: shortcutsall off: $CONTROL_REPLY"
    wait_until 120 eval '[ "$(count_shims)" = "2" ]' \
        && ok "[DOCK-5] Save all off left only the manual and Dock shortcuts (2)" \
        || bad "[DOCK-5] Save all off left $(count_shims) shortcuts ($(ls "$dir" 2>/dev/null | tr '\n' ' '))"
    [ "$(origins_of "$dir/WhatsApp (FakePhone).app")" = "manual" ] \
        && ok "[DOCK-5] the manual shortcut lost only all" \
        || bad "[DOCK-5] WhatsApp's reasons after off: '$(origins_of "$dir/WhatsApp (FakePhone).app")'"
    [ "$(origins_of "$dir/Chrome (FakePhone).app")" = "dock" ] \
        && ok "[DOCK-5] the Dock shortcut lost only all" \
        || bad "[DOCK-5] Chrome's reasons after off: '$(origins_of "$dir/Chrome (FakePhone).app")'"

    stop_app
    stop_fakephone
    remove_dock_apps

    # --- Reconcile on an app list, and Spotlight (DOCK-7, DOCK-9) ----------
    # The phone drops WhatsApp (installed before the list arrives) and adds
    # Notes between two app lists: the uninstalled app's shim goes even with
    # Save all and manual on it, the new app gains Save all's reason, and the
    # index holds no item for an app that has a shim.
    FAKE_ARGS="--demo-apps 20 --drop-after 60 --apps-revise --apps-drop com.whatsapp --apps-add com.example.notes=Notes" \
        start_fake || { stop_fakephone; return 1; }
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --debug-control "$WORK-control" --quit-after 420
    wait_until 30 events_have '"t":"apps.icon"' \
        || { bad "SHORTCUTS the reconcile app list never arrived"; stop_app; stop_fakephone; return 1; }
    control shortcut add com.whatsapp || bad "SHORTCUTS reconcile: shortcut add: $CONTROL_REPLY"
    wait_until 30 eval '[ -d "$dir/WhatsApp (FakePhone).app" ]' \
        || { bad "SHORTCUTS reconcile: no WhatsApp shim before the change"; stop_app; stop_fakephone; return 1; }
    control shortcutsall on || bad "SHORTCUTS reconcile: shortcutsall on: $CONTROL_REPLY"
    wait_until 180 eval '[ "$(count_shims)" = "20" ]' \
        && ok "[DOCK-7] Save all made the 20 shortcuts before the app list changed" \
        || bad "[DOCK-7] only $(count_shims) of 20 shortcuts before the change"
    [ "$(origins_of "$dir/WhatsApp (FakePhone).app")" = "manual all" ] \
        && ok "[DOCK-7] the app that will be uninstalled carries manual and all" \
        || bad "[DOCK-7] WhatsApp's reasons before the change: '$(origins_of "$dir/WhatsApp (FakePhone).app")'"
    wait_until 120 eval '[ ! -d "$dir/WhatsApp (FakePhone).app" ]' \
        && ok "[DOCK-7] the uninstalled app's shim went, manual and all included" \
        || bad "[DOCK-7] the uninstalled app still has its shim"
    wait_until 120 eval '[ "$(origins_of "$dir/Notes (FakePhone).app")" = "all" ]' \
        && ok "[DOCK-7] the new app gained Save all's reason" \
        || bad "[DOCK-7] the new app's shim is '$(origins_of "$dir/Notes (FakePhone).app")'"
    [ "$(count_shims)" = "20" ] \
        && ok "[DOCK-7] the list is 20 again (19 kept, one added)" \
        || bad "[DOCK-7] the folder holds $(count_shims) shims, wanted 20"
    # Every app has a shim, so nothing of that phone is a CoreSpotlight item.
    local dev spot
    dev="$(/usr/libexec/PlistBuddy -c 'Print :PDDeviceId' "$dir/Notes (FakePhone).app/Contents/Info.plist" 2>/dev/null)"
    [ -n "$dev" ] || bad "[DOCK-8] no device id in the shim"
    sleep 2
    spot="$(/usr/bin/log show --last 5m --info \
        --predicate 'subsystem == "app.contigua.mac" AND process == "Contigua"' 2>/dev/null \
        | grep -o "spotlight: indexing [0-9]* apps for $dev" | tail -1)"
    [ "$spot" = "spotlight: indexing 0 apps for $dev" ] \
        && ok "[DOCK-9] no app with a shortcut is also a CoreSpotlight item (last index: $spot)" \
        || bad "[DOCK-9] the last Spotlight index was '${spot:-none}', wanted no items"

    # --- Forget removes every shim (DOCK-8) --------------------------------
    control settings-open >/dev/null 2>&1 || bad "[DOCK-8] settings-open: $CONTROL_REPLY"
    wait_until 25 windows_at_least 2 \
        || { bad "[DOCK-8] the Settings window never opened"; stop_app; stop_fakephone; return 1; }
    control settings-select "phone:$dev" >/dev/null 2>&1
    sleep 1
    control settings-forget "$dev" >/dev/null 2>&1 || bad "[DOCK-8] settings-forget: $CONTROL_REPLY"
    sleep 1
    control key tab >/dev/null 2>&1
    control key space >/dev/null 2>&1
    wait_until 30 eval '[ "$(count_shims)" = "0" ]' \
        && ok "[DOCK-8] forgetting the phone removed every shim, whatever its reasons" \
        || bad "[DOCK-8] $(count_shims) shims survived the forget ($(ls "$dir" 2>/dev/null | tr '\n' ' '))"

    stop_app
    stop_fakephone
    remove_dock_apps
    wait_until 5 no_fakephone
}


# --- multiwin: several windows of one app (WIN-24…WIN-36) ------------------
#
# One fake phone, one Chrome (the one fixture app that says `multi: true`) and
# Settings (one window at a time). Every proof goes through the person's own
# path: the Deck cell, ⌘N, ⌘`, ⌘W, the Dock shim's menu item (through the item's
# own target and action) and the files the app writes for the quiet run. Steps
# that would need a right click on the Deck cell print SKIP: K2
# (AppWindowMenuTests) proves that menu's rows, and the VM round can click it.

check_multiwin() {
    clean
    local dir="$WORK/dock-apps" ctl="$WORK-control" banner="$WORK/banner.txt"
    rm -rf "$dir"; mkdir -p "$dir" "$ctl"; remove_dock_apps
    rm -f "$WORK"/menus-*.json "$WORK"/wm-*.json "$WORK/chrome.txt"

    # The review's shots (visible run only, one appearance per boot:
    # PD_E2E_SHOT_APPEARANCE=dark|light, never both). They land in the work
    # dir, which the VM copies back with the run.
    local appearance="${PD_E2E_SHOT_APPEARANCE:-dark}"
    case "$appearance" in
        dark|light) ;;
        *) bad "MULTIWIN PD_E2E_SHOT_APPEARANCE must be dark or light (got '$appearance')"
           appearance=dark ;;
    esac
    mkdir -p "$WORK/shots"
    shot() {
        local file="$WORK/shots/$appearance-$1.png"
        screencapture -x "$file" && say "shot: $file" || bad "MULTIWIN no screenshot $1"
    }
    # menu_shot NAME MENU [ITEM] — one of the app's own menus, held open by the
    # same tracking loop a click starts, while the whole screen is captured. With
    # ITEM, the menu is positioned so that row's own corner is at a known point
    # (MenuTrack), the check moves the real pointer into it, waits up to 3 s for
    # its help tag, and only then takes the shot (WIN-27's sentences).
    #
    # The capture happens while the menu is confirmed on screen: a hover shot
    # keeps the menu up for 10 s (MenuTrack's maximum) and the check reads the
    # menu's own layer-101 window immediately before the shutter. A menu that
    # is already gone at that point is not a proof, so the shot is retaken once,
    # after the first menu has reported and closed. The run logs each capture's
    # elapsed time against that cap.
    menu_shot() {
        local name="$1" menu="$2" hover="${3:-}" report="$WORK/shots/$appearance-$1.json" seconds=4
        local point="$WORK/shots/$appearance-$1.point" attempt opened_at elapsed
        [ -n "$hover" ] && seconds=10
        for attempt in 1 2; do
            opened_at=$SECONDS
            local args=(menutrack "$report" "$menu" "$seconds")
            [ -n "$hover" ] && args+=("$hover" "$point")
            control "${args[@]}" \
                || { bad "MULTIWIN menutrack $menu: $CONTROL_REPLY"; return 1; }
            if [ -n "$hover" ]; then
                # The menu is up and the app wrote the row's own corner: a real
                # pointer move onto it, then a wait for the help tag (a small
                # window of its own). If none appears in 3 s the shot is still
                # taken — the report carries the sentence — and the run says so.
                if wait_until 4 [ -s "$point" ]; then
                    local px py before="$WORK/shots/$appearance-$1.before"
                    read -r px py < "$point"
                    app_window_ids > "$before"
                    cg_input moveat --x "$px" --y "$py" \
                        || bad "MULTIWIN the pointer move onto '$hover' did not post"
                    if wait_until 3 help_tag_up "$before"; then
                        ok "MULTIWIN the $menu help tag is on screen for shot $name"
                    else
                        skip "MULTIWIN the $menu help tag" "no new window within 3 s; the shot is kept and its report carries the sentence"
                        "$CGBIN" all 2>/dev/null | grep -F "pid=$APP_PID " | sed 's/^/  app window: /'
                    fi
                else
                    bad "MULTIWIN menutrack $menu wrote no hover point"
                fi
            else
                sleep 1.4
            fi
            elapsed=$((SECONDS - opened_at))
            if [ "$(open_menu_windows)" -le 0 ]; then
                # The menu closed before the shutter: the picture would be the
                # windows behind it (round 5, light 7).
                bad "MULTIWIN shot $name: no menu on screen at +${elapsed}s of its ${seconds}s cap"
            else
                # The menu is on screen at the shutter: that is the capture's
                # precondition. (A probe after the shutter is not: boot 8's
                # dark-6 and dark-7 images show the menu and the tag although
                # the menu was gone by the time screencapture returned.)
                shot "$name"
                say "MULTIWIN shot $name: captured at +${elapsed}s of the menu's ${seconds}s cap"
                break
            fi
            # The retry must not open a second menu over the first: wait for
            # this menu's report (the timer that writes it also cancels
            # tracking) and for its popup to be gone.
            wait_until 15 [ -s "$report" ] \
                || { bad "MULTIWIN menutrack $menu never reported and closed after ${seconds}s"
                     cg_input key --keycode 53 >/dev/null 2>&1 || true; return 1; }
            wait_until 8 eval '[ "$(popup_windows)" -eq 0 ]' \
                || { bad "MULTIWIN the $menu menu was still open before the retry"
                     cg_input key --keycode 53 >/dev/null 2>&1 || true; return 1; }
            [ "$attempt" = 1 ] || break
            skip "MULTIWIN shot $name" "the first capture raced the menu's close; taking it again"
        done
        if ! wait_until 15 [ -s "$report" ]; then
            bad "MULTIWIN menutrack $menu never reported and closed after ${seconds}s"
            # The tracking loop still takes events when a timer is late: Escape
            # closes the menu and gives the run its main thread back.
            cg_input key --keycode 53 >/dev/null 2>&1 || true
            return 1
        fi
        if [ -n "$hover" ]; then
            say "MULTIWIN $name help tag: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("help_tag",""))' "$report")"
        fi
        # The check closes its own menu before the next step: the report is
        # written by the timer that also cancels tracking, so this is the proof
        # the bar is free again (a popup is a layer-100 window of its own).
        wait_until 8 eval '[ "$(popup_windows)" -eq 0 ]' \
            || { bad "MULTIWIN the $menu menu was still open after its track"
                 cg_input key --keycode 53 >/dev/null 2>&1 || true; }
        sleep 0.2
    }
    # The ids of the app's on-screen windows: the menu is one of them, so a
    # window that appears after the pointer move is the help tag.
    app_window_ids() {
        "$CGBIN" all 2>/dev/null | grep -F "pid=$APP_PID " | sed -n 's/.* id=\([0-9]*\) .*/\1/p'
    }
    # help_tag_up BEFORE_FILE — a small new window of the app: the menu item's
    # help tag. Prints the window's id, layer and bounds, for the run log.
    help_tag_up() {
        "$CGBIN" all 2>/dev/null | python3 - "$APP_PID" "$1" <<'PY'
import re, sys
pid, before = sys.argv[1], sys.argv[2]
known = set(open(before).read().split())
for line in sys.stdin:
    if ("pid=" + pid + " ") not in line:
        continue
    m = re.search(r"id=(\d+) layer=(-?\d+) bounds=\{\{(-?[\d.]+), (-?[\d.]+)\}, \{(-?[\d.]+), (-?[\d.]+)\}\}", line)
    if not m:
        continue
    ident, layer, x, y, w, h = m.groups()
    if ident in known or float(h) > 150 or float(w) > 900:
        continue
    print("help tag: id=%s layer=%s bounds=%s,%s %sx%s" % (ident, layer, x, y, w, h))
    sys.exit(0)
sys.exit(1)
PY
    }
    # The app's windows at menu level: a popup menu is its own window (layer
    # 101), which is how a check sees that a right click opened one.
    menu_windows() {
        "$CGBIN" all 2>/dev/null | awk -v pid="$APP_PID" '
            $0 ~ ("pid=" pid " ") { for (i = 1; i <= NF; i++) {
                if ($i ~ /^layer=/) { split($i, part, "="); if (part[2] >= 100) n++ } } }
            END { print n + 0 }'
    }
    # The app's open menus, layer 101 only: a help tag is a small window of
    # its own (layer 103) that dies with the menu, so a capture guard must ask
    # for the menu, not for anything the menu left behind. Shot 7 reads this on
    # both sides of the shutter (round 5's light 7 had a report but no menu in
    # the frame).
    open_menu_windows() {
        "$CGBIN" all 2>/dev/null | awk -v pid="$APP_PID" '
            $0 ~ ("pid=" pid " ") { for (i = 1; i <= NF; i++) {
                if ($i ~ /^layer=/) { split($i, part, "="); if (part[2] == 101) n++ } } }
            END { print n + 0 }'
    }
    # Any process's popup window (a menu tracks in one, layer >= 100): the
    # check waits for zero before it opens the next menu. See `popup_windows`
    # at the top of the file.

    # The count of window.open the phone saw, and of the ones asking for an
    # extra task; `window.open` is logged verbatim by the fake.
    pw_opens() { count_events '"t":"window.open"' | head -1; }
    pw_instances() { count_events '"newInstance":true' | head -1; }
    pw_closes() { count_events '"t":"window.close"' | head -1; }
    pw_adopts() { count_events '"t":"window.adopt"' | head -1; }
    pw_input() { fake_counter input; }
    # One fake-phone window event kind (compact JSON lines).
    win_events() {
        python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
count = 0
for line in open(sys.argv[1], errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "window" and event.get("kind") == sys.argv[2]:
        count += 1
print(count)
PY
    }
    pw_opens_grew() { [ "$(pw_opens)" -gt "$1" ]; }
    pw_instances_at_least() { [ "$(pw_instances)" -ge "$1" ]; }
    pw_closes_grew() { [ "$(pw_closes)" -gt "$1" ]; }
    pw_input_grew() { [ "$(pw_input)" -gt "$1" ]; }
    chrome_window_opens() { [ "$(window_open_count com.android.chrome)" -eq "$1" ]; }
    pw_opens_reached() { [ "$(pw_opens)" -ge "$1" ]; }
    # The app's control route, retried while the session is still coming up.
    # The Deck itself opens half a second into a launch and can take the
    # keyboard after a window that opened first; asking for the same app again
    # raises its window (WIN-2), which focuses it the way a person's click does.
    ctl_open() {
        local tries=60
        while ! control open "$@"; do
            if [ "$CONTROL_REPLY" != "not online" ]; then
                bad "MULTIWIN open $*: $CONTROL_REPLY"; return 1
            fi
            tries=$((tries - 1))
            [ "$tries" -gt 0 ] || { bad "MULTIWIN open $*: never online"; return 1; }
            sleep 0.5
        done
        sleep 1.5
        control open "$@" >/dev/null 2>&1 || true
        sleep 0.5
    }
    # The front window's title, as the app itself reports it (the key window).
    front_title() {
        rm -f "$WORK/wm-key.txt"
        control keywindow "$WORK/wm-key.txt" >/dev/null 2>&1
        sed -n 2p "$WORK/wm-key.txt"
    }
    # The app must be the frontmost one for NSApp.keyWindow to exist and for a
    # real key to reach its menus. An automatic Dock shim no longer activates
    # itself (DockApps.open), but a launch can still land during a raise; a
    # person's next click would give the front back, so the check raises the
    # window again (setup, never a step proved by the ids below). `want` is a
    # title prefix: once the app has two windows the key one reads
    # "Chrome — Docs (FakePhone)" and "Chrome" names the app, not one window.
    focus_app() {
        local pkg="$1" want="$2" i=0 title
        [ "$VISIBLE" = 1 ] || return 0
        while [ "$i" -lt 20 ]; do
            control open --open "$pkg" >/dev/null 2>&1 || true
            sleep 0.5
            title="$(front_title)"
            case "$title" in
                "$want"*)
                    # A shim finishing its launch can activate itself a moment
                    # later; the window must still be front after that.
                    sleep 1.5
                    case "$(front_title)" in
                        "$want"*) return 0 ;;
                    esac
                    ;;
            esac
            i=$((i + 1))
        done
        bad "MULTIWIN focus: $pkg never came front ('$(front_title)')"
        return 1
    }
    # File ▸ New <App> Window, the same item ⌘N is on: its path from the dump.
    pick_new_window() {
        local expect="${1:-}" attempt item title
        for attempt in 1 2 3 4 5 6 7 8; do
            item="$(file_new_item)"
            title="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("title",""))' "$item")"
            [ -n "$title" ] || { bad "MULTIWIN no New item in File"; return 1; }
            if control menupick "File/$title"; then
                return 0
            fi
            # "disabled": the check wants the item to refuse the pick.
            [ "$expect" = "disabled" ] && return 1
            # The item may still be reading "Opening on your phone…" while the
            # window's first frame is on its way.
            sleep 1
        done
        bad "MULTIWIN File/$title: $CONTROL_REPLY (key window '$(front_title)')"
        return 1
    }

    # The File menu's New item as an opened menu shows it.
    file_new_item() {
        control menudump "$WORK/wm-menu.json" || { echo ""; return 1; }
        python3 - "$WORK/wm-menu.json" <<'PY'
import json, sys
root = json.load(open(sys.argv[1]))
# The app's own tree: the help tag is an NSMenuItem's, and the Accessibility
# tree a person reads does not carry it.
file = next((i for i in root.get("items") or [] if i["title"] == "File"), None)
item = next((i for i in (file or {}).get("submenu") or [] if i["title"].startswith("New")), None)
print(json.dumps(item or {}))
PY
    }

    # ---- Launch 1: the default cap (4), two windows, ⌘N, the menus, ⌘` ------
    local look=()
    [ "$VISIBLE" = 1 ] && look=(--appearance "$appearance")
    FAKE_ARGS="--label-after-window 2 --label-to Docs,Mail --tls-identity $WORK/phone.identity" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --dock-dir "$dir" --debug-control "$ctl" \
        ${look[@]+"${look[@]}"} \
        --debug-chrome-state "$WORK/chrome.txt" --debug-banner "$banner" --quit-after 300
    APP_PID="${APP_PID:-}"

    # [WIN-24] an app the phone says opens one window: the New item is disabled
    # with its sentence, and ⌘N sends nothing.
    ctl_open --open com.android.settings || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.settings \
        || { bad "MULTIWIN no window.open for Settings"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.settings "Settings (FakePhone)" || true
    local before="$(pw_opens)"
    pick_new_window disabled
    sleep 2
    [ "$(pw_opens)" = "$before" ] \
        && ok "[WIN-24] multi:false: the New item sent no window.open for Settings" \
        || bad "[WIN-24] multi:false: the New item sent a window.open ($before -> $(pw_opens))"
    if [ "$VISIBLE" = 1 ]; then
        # The person's own key: a real ⌘N on a window whose app has one
        # instance. The disabled item eats the key, so nothing goes out.
        before="$(pw_opens)"
        cg_input key --keycode 45 --cmd || bad "MULTIWIN the ⌘N press on Settings did not post"
        sleep 2
        [ "$(pw_opens)" = "$before" ] \
            && ok "[WIN-24] a real ⌘N on Settings sent no window.open" \
            || bad "[WIN-24] a real ⌘N on Settings sent a window.open ($before -> $(pw_opens))"
    else
        skip "MULTIWIN ⌘N on the keyboard" "a quiet host app runs SwiftUI menu actions only through the item; the item's ⌘N is read back from the bar, K2 NewWindowTests and the VM round press the key"
    fi
    local item; item="$(file_new_item)"
    python3 - "$item" <<'PY' && ok "[WIN-24] the File item reads New Settings Window, disabled, with its sentence" \
        || bad "[WIN-24] the File item for Settings is not the design: $item"
import json, sys
item = json.loads(sys.argv[1])
if item.get("title") != "New Settings Window": print("title", item.get("title")); sys.exit(1)
if item.get("enabled") is not False: print("enabled", item.get("enabled")); sys.exit(1)
if item.get("toolTip") != "Settings opens one window at a time.":
    print("help", item.get("toolTip")); sys.exit(1)
PY
    if [ "$VISIBLE" = 1 ]; then
        # 7: an app that opens one window: New Settings Window disabled, its
        # help tag ("Settings opens one window at a time.") held on screen by a
        # real pointer over the item. The fresh Settings shim can finish its
        # launch by activating itself, which takes an open menu down with it
        # (round 5's light 7 lost its menu exactly here); re-assert the front
        # window as setup right before the menu opens.
        focus_app com.android.settings "Settings (FakePhone)" || true
        menu_shot 7-settings-one-window File "New Settings Window"
    else
        skip "MULTIWIN the Settings shot" "needs the VM's screen; the disabled item and its sentence are asserted above and in K2 NewWindowTests"
    fi
    control menupick "File/Close" >/dev/null 2>&1   # the Settings window goes
    sleep 1

    # [WIN-36] every implicit entry point raises: the Deck cell twice and the
    # debug route's --open send no second window.open.
    ctl_open --open com.android.chrome || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.chrome \
        || { bad "MULTIWIN no window.open for Chrome"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.chrome "Chrome (FakePhone)" || true
    before="$(window_open_count com.android.chrome)"
    control deckclick Chrome >/dev/null 2>&1
    control deckclick Chrome >/dev/null 2>&1
    control open --open com.android.chrome >/dev/null 2>&1
    sleep 2
    [ "$(window_open_count com.android.chrome)" = "$before" ] \
        && ok "[WIN-36] Deck cell ×2 and --open raised the one Chrome window (no window.open)" \
        || bad "[WIN-36] an entry point opened a second window ($before -> $(window_open_count com.android.chrome))"
    [ "$(front_title)" = "Chrome (FakePhone)" ] \
        && ok "[WIN-36] the raise put that window in front" \
        || bad "[WIN-36] the raise left '$(front_title)' in front"

    # [WIN-25] the New item (⌘N): exactly one window.open carrying newInstance.
    before="$(pw_opens)"
    local instances_before
    instances_before="$(pw_instances)"
    if [ "$VISIBLE" = 1 ]; then
        # The person's own press: a real ⌘N through the window server. First
        # the Chrome window in front, so the key reaches this app's File menu.
        cg_input key --keycode 45 --cmd || bad "MULTIWIN the ⌘N press did not post"
        sleep 1.5
    else
        pick_new_window
    fi
    wait_until 20 eval '[ "$(pw_instances)" -gt "$instances_before" ]' \
        && ok "[WIN-25] ⌘N sent one window.open with newInstance" \
        || bad "[WIN-25] ⌘N sent no window.open with newInstance"
    [ "$(( $(pw_opens) - before ))" = "1" ] \
        && ok "[WIN-25] the New item sent exactly one window.open" \
        || bad "[WIN-25] the New item sent $(( $(pw_opens) - before )) window.open"
    control menudump "$WORK/wm-menu.json" >/dev/null 2>&1
    python3 - "$WORK/wm-menu.json" <<'PY' && ok "[WIN-25] the item carries ⌘N and its title names the key app" \
        || bad "[WIN-25] the New item's key or title is wrong"
import json, sys
root = json.load(open(sys.argv[1]))
file = [i for i in root["displayed"] if i["title"] == "File"][0]
new = [i for i in file["submenu"] if i["keyEquivalent"] == "n"
       and "shift" not in i["modifiers"]][0]
if new["title"] != "New Chrome Window": print("title", new["title"]); sys.exit(1)
if new["modifiers"] != ["command"]: print("modifiers", new["modifiers"]); sys.exit(1)
PY
    wait_until 25 titles_have "Chrome — Docs (FakePhone)" \
        || true

    # The phone renames the two tasks (--label-after-window 2): each window
    # takes its own label (WIN-28).
    wait_until 30 titles_have "Chrome — Docs (FakePhone)" \
        && wait_until 10 titles_have "Chrome — Mail (FakePhone)" \
        && ok "[WIN-28] window.title retitled both windows by their tasks" \
        || bad "[WIN-28] the windows did not take their task labels: $(window_titles "$APP_PID" | tr '\n' '|')"

    # The bar keeps no app full-screen item while two app windows are open; the
    # system's own View item follows the key window (MENU-4, MENU-7).
    rm -f "$WORK/wm-structure.json"
    control menudump "$WORK/wm-structure.json" || bad "MULTIWIN menudump: $CONTROL_REPLY"
    if reason="$(full_screen_bar_ok "$WORK/wm-structure.json" "multiwin (an app window key)" "$([ "$VISIBLE" = 1 ] && echo 1 || echo 0)")"; then
        ok "[MENU-7] $reason"
    else
        bad "[MENU-7] multiwin: $reason"
    fi

    if [ "$VISIBLE" = 1 ]; then
        # 1: two windows of one app, both live, named by their tasks (the bar
        # hides the title outside full screen; the Window menu and the Dock
        # shim name them). 5 and 2: the Window and File menus, held open the
        # way a click opens them.
        shot 1-two-windows
        menu_shot 5-window-menu Window
        menu_shot 2-file-menu File
    else
        skip "MULTIWIN the shots of the two windows and the File and Window menus" "visible VM run only (PD_E2E_SHOT_APPEARANCE=dark|light)"
    fi

    # [WIN-26] the Dock shim's menu and the Deck cell's rows are the same list,
    # with the front window's row checked.
    wait_until 25 grep -q "Chrome — Docs" "$ctl/dockmenu-com.android.chrome.json" 2>/dev/null \
        || bad "[WIN-26] the shim never got both windows' rows ($(ls "$ctl" 2>/dev/null | tr '\n' ' '))"
    python3 - "$ctl/dockmenu-com.android.chrome.json" <<'PY' && ok "[WIN-26] the Dock shim's menu is New + both windows, front to back, the front one checked" \
        || bad "[WIN-26] the Dock shim's menu is not the design"
import json, sys
rows = json.load(open(sys.argv[1]))
titles = ["—" if r.get("separator") else r.get("title") for r in rows]
if titles != ["New Chrome Window", "—", "Chrome — Mail", "Chrome — Docs"]:
    print("titles:", titles); sys.exit(1)
windows = rows[2:]
if [r.get("checked") for r in windows] != [True, False]:
    print("checked:", [r.get("checked") for r in windows]); sys.exit(1)
if not all(r.get("enabled") for r in rows if not r.get("separator")):
    print("a row is disabled"); sys.exit(1)
PY
    if [ "$VISIBLE" = 1 ]; then
        # 3: the shim's own menu, the New + windows list a Dock right click
        # shows (the Dock owns that click; the shim pops the same buildMenu).
        # The shim polls its debug directory every 0.2 s, so the check waits for
        # its popup window and captures at once, with the popup confirmed on
        # screen at the shutter and its 10 s cap still ahead (round 5, light 3
        # shot an empty screen after a popup that never appeared). The shim
        # consumes the request file even when it cannot open the menu, so a miss
        # is retried once with a fresh request, never stacked on a menu that is
        # still up.
        local base wrote_at elapsed attempt
        base="$(popup_windows)"
        for attempt in 1 2; do
            wrote_at=$SECONDS
            printf '10' > "$ctl/dockmenu-com.android.chrome-show"
            if ! wait_until 7 eval '[ "$(popup_windows)" -gt '"$base"' ]'; then
                # A popup that is late is still a popup: one more look.
                sleep 1.2
            fi
            elapsed=$((SECONDS - wrote_at))
            if [ "$(popup_windows)" -gt "$base" ]; then
                shot 3-dock-shim-menu
                ok "[WIN-26] the Dock shim's own menu opened for its shot"
                say "MULTIWIN shot 3-dock-shim-menu: captured at +${elapsed}s of the shim's 10s cap"
                break
            fi
            if [ "$attempt" = 1 ]; then
                # A request the shim consumed without a popup is a rig miss, not
                # a miss of the menu: the retry is the proof. Only the last
                # attempt's miss counts.
                skip "MULTIWIN the shim's menu shot" "the first request produced no popup; asking again"
                wait_until 10 eval '[ "$(popup_windows)" -le '"$base"' ]' \
                    || { bad "MULTIWIN the shim's menu was still open before the retry"; break; }
            else
                bad "MULTIWIN the shim's menu never appeared for its shot (waited ${elapsed}s of its 10s cap)"
            fi
        done
        wait_until 12 eval '[ "$(popup_windows)" -eq 0 ]' \
            || bad "MULTIWIN the shim's menu stayed open after its cap"
        focus_app com.android.chrome "Chrome" || true
    else
        skip "MULTIWIN the Dock shim's menu shot" "the Dock owns its icon's click; the rows are the dump above and K2 AppWindowMenuTests"
    fi
    # The live Deck list and the shim's own built menu are one rule read at the
    # same moment: the raise above refreshes the shim's menu (windowSetChanged),
    # so the comparison must read the shim's dump again, not a copy taken
    # before the shot. With two windows the front one decides the order, and
    # the old fixed titles assumed which window that was.
    deck_matches_shim() {
        control windowmenu "$WORK/wm-deck.json" com.android.chrome >/dev/null 2>&1 || return 1
        python3 - "$ctl/dockmenu-com.android.chrome.json" "$WORK/wm-deck.json" <<'PY'
import json, sys
shim = json.load(open(sys.argv[1]))
deck = json.load(open(sys.argv[2]))
def rows(items):
    return [(i["title"], i["enabled"], i["checked"]) for i in items if not i.get("separator")]
if rows(shim) != rows(deck):
    print("shim:", rows(shim)); print("deck:", rows(deck)); sys.exit(1)
if len(rows(deck)) != 3:
    print("rows:", [r[0] for r in rows(deck)]); sys.exit(1)
PY
    }
    wait_until 10 deck_matches_shim \
        && ok "[WIN-26] the Deck cell's rows are the same New + windows list, front one checked" \
        || bad "[WIN-26] the Deck cell's rows differ from the shim's menu"
    if [ "$VISIBLE" = 1 ]; then
        # The cell's own menu: the Deck in front, then a real pointer's
        # secondary click at the cell's place. A popup menu is a window of its
        # own (layer 101), which is how the click is proved; the shot shows the
        # rows.
        local menus_before cx cy
        control deckfocus grid || bad "MULTIWIN deckfocus for the right click: $CONTROL_REPLY"
        sleep 0.8
        control deckcellpoint Chrome "$WORK/deckpoint.txt" \
            || bad "MULTIWIN deckcellpoint: $CONTROL_REPLY"
        if [ -s "$WORK/deckpoint.txt" ]; then
            read -r cx cy < "$WORK/deckpoint.txt"
            menus_before="$(menu_windows)"
            cg_input rclickat --x "$cx" --y "$cy" || bad "MULTIWIN the right click did not post"
            sleep 1
            [ "$(menu_windows)" -gt "$menus_before" ] \
                && ok "[WIN-26] a real secondary click on the Deck cell opened its menu" \
                || bad "[WIN-26] the Deck cell's right click opened no menu ($menus_before menus before)"
            shot 4-deck-cell-menu
            cg_input key --keycode 53
            # The check closes its own menu before the next step takes the app.
            wait_until 8 eval '[ "$(menu_windows)" -eq "$menus_before" ]' \
                || bad "MULTIWIN the Deck cell's menu stayed open after Escape"
            sleep 0.2
        else
            bad "MULTIWIN no Deck cell point for the right click"
        fi
    else
        skip "MULTIWIN the Deck cell's right click" "needs a real pointer; K2 AppWindowMenuTests covers the same rows, the VM round clicks the cell"
    fi
    # A pick raises through the shim's own menu item (its target and action).
    # The row is read from the shim's live dump: the window that is not checked
    # is the one the pick has to raise. A fixed index 3 named Docs only while
    # the list kept its order; the Deck cell's right click above is a raise, and
    # the shim re-reads the front window on a raise (df7a162e), so in round 5b's
    # boots 8 and 9 index 3 already named the window in front and the pick
    # looked like it did nothing.
    local pick_index="" pick_title=""
    if python3 - "$ctl/dockmenu-com.android.chrome.json" "$WORK/wm-pick.txt" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
for index, row in enumerate(rows):
    if row.get("separator") or row.get("checked") or not row.get("enabled"):
        continue
    title = row.get("title", "")
    if title.startswith("Chrome — ") and title.count(" — ") == 1:
        with open(sys.argv[2], "w") as out:
            out.write("%d\n%s\n" % (index, title))
        sys.exit(0)
sys.exit(1)
PY
    then
        read -r pick_index < "$WORK/wm-pick.txt"
        pick_title="$(sed -n 2p "$WORK/wm-pick.txt")"
    fi
    if [ -n "$pick_title" ]; then
        printf '%s' "$pick_index" > "$ctl/dockmenu-com.android.chrome-press"
        wait_until 15 eval '[ "$(front_title)" = "'"$pick_title"' (FakePhone)" ]' \
            && ok "[WIN-26] picking the other window's row ($pick_title) raised that window" \
            || bad "[WIN-26] the pick of $pick_title left '$(front_title)' in front"
    else
        bad "MULTIWIN no unchecked Chrome window row in the shim's menu"
    fi

    # [WIN-29] one ⌘` per press, in front-to-back order, wrapping.
    local first second
    first="$(front_title)"
    local cycle_reply
    # The key itself: NSApp dispatches it to the item's ⌘` (the item's own
    # action), which is the path a person's press takes.
    if control key 'cmd+`'; then cycle_reply="pressed"; else cycle_reply="$CONTROL_REPLY"; fi
    sleep 1
    second="$(front_title)"
    [ "$second" != "$first" ] \
        && ok "[WIN-29] ⌘\` raised the next window ($first -> $second)" \
        || bad "[WIN-29] ⌘\` did nothing ($first; $cycle_reply)"
    control key 'cmd+`' >/dev/null 2>&1
    sleep 1
    [ "$(front_title)" = "$first" ] \
        && ok "[WIN-29] ⌘\` wrapped back to the first window" \
        || bad "[WIN-29] ⌘\` did not wrap ($(front_title))"
    control menudump "$WORK/wm-window.json" >/dev/null 2>&1
    python3 - "$WORK/wm-window.json" <<'PY' && ok "[WIN-29] Window holds one Next Window item, enabled with two windows, carrying ⌘\`" \
        || bad "[WIN-29] the Window menu's Next Window item is not the design"
import json, sys
root = json.load(open(sys.argv[1]))
window = [i for i in root["displayed"] if i["title"] == "Window"][0]
items = [i for i in window["submenu"] if i["title"] == "Next Window"]
if len(items) != 1: print("Next Window items:", len(items)); sys.exit(1)
if not items[0]["enabled"]: print("disabled"); sys.exit(1)
if items[0]["keyEquivalent"] != "`" or items[0]["modifiers"] != ["command"]:
    print("key", repr(items[0]["keyEquivalent"]), items[0]["modifiers"]); sys.exit(1)
cycles = [i for i in window["submenu"] if i["title"] == "Cycle Through Windows"]
if cycles: print("AppKit's Cycle Through Windows is still there"); sys.exit(1)
PY

    # [WIN-30] ⌘` sends nothing to the phone: no input, no window request.
    local input_before opens_before instances_before
    input_before="$(pw_input)"; opens_before="$(pw_opens)"; instances_before="$(pw_instances)"
    control key 'cmd+`' >/dev/null 2>&1 || true
    sleep 2
    [ "$(pw_input)" = "$input_before" ] && [ "$(pw_opens)" = "$opens_before" ] \
        && [ "$(pw_instances)" = "$instances_before" ] \
        && ok "[WIN-30] ⌘\` sent no input and no window.open" \
        || bad "[WIN-30] ⌘\` sent input=$(( $(pw_input) - input_before )) opens=$(( $(pw_opens) - opens_before ))"

    # [WIN-31] ⌘W closes one window: one window.close, the other streams and
    # takes input.
    local closes_before
    closes_before="$(pw_closes)"
    control menupick "File/Close" >/dev/null 2>&1
    wait_until 15 pw_closes_grew "$closes_before" \
        && ok "[WIN-31] ⌘W sent one window.close" \
        || bad "[WIN-31] ⌘W sent no window.close"
    [ "$(( $(pw_closes) - closes_before ))" = "1" ] \
        && ok "[WIN-31] exactly one window.close, for the window that closed" \
        || bad "[WIN-31] $(( $(pw_closes) - closes_before )) window.close for one ⌘W"
    input_before="$(pw_input)"
    control key "cmd+f" >/dev/null 2>&1
    wait_until 10 pw_input_grew "$input_before" \
        && ok "[WIN-31] the surviving window still takes input" \
        || bad "[WIN-31] the survivor stopped taking input"
    [ "$(front_title)" = "Chrome (FakePhone)" ] \
        && ok "[WIN-28] the lone survivor went back to the short title" \
        || bad "[WIN-28] the survivor reads '$(front_title)'"

    # [WIN-32] at the cap the Mac refuses the fifth window itself; [WIN-27] the
    # item reads the cap's sentence.
    local n
    for n in 1 2 3; do
        pick_new_window
        sleep 1.5
    done
    sleep 2
    before="$(pw_opens)"
    pick_new_window disabled
    sleep 2
    [ "$(pw_opens)" = "$before" ] \
        && ok "[WIN-32] at the phone's cap of 4 the Mac sent no window.open" \
        || bad "[WIN-32] a fifth window.open left the Mac ($before -> $(pw_opens))"
    item="$(file_new_item)"
    python3 - "$item" <<'PY' && ok "[WIN-27] at the cap the item reads \"Close a Chrome window to open another.\"" \
        || bad "[WIN-27] the cap's sentence is not on the item: $item"
import json, sys
item = json.loads(sys.argv[1])
if item.get("enabled") is not False: print("enabled", item.get("enabled")); sys.exit(1)
if item.get("toolTip") != "Close a Chrome window to open another.":
    print("help", item.get("toolTip")); sys.exit(1)
PY
    if [ "$VISIBLE" = 1 ]; then
        # 6: at the cap, New Chrome Window disabled with its help tag ("Close a
        # Chrome window to open another.") held on screen by a real pointer.
        menu_shot 6-at-the-cap File "New Chrome Window"
    else
        skip "MULTIWIN the shot at the cap" "needs the VM's screen; the disabled item and its sentence are asserted above"
    fi
    stop_app
    remove_dock_apps
    stop_fakephone
    wait_until 5 no_fakephone

    # ---- Launch 2: the cap follows the phone's number (WIN-32) -------------
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--max-windows 2 --tls-identity $WORK/phone.identity" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" \
        --debug-banner "$banner" --quit-after 120
    ctl_open --open com.android.chrome || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.chrome \
        || { bad "MULTIWIN cap 2: no window.open"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.chrome "Chrome (FakePhone)" || true
    pick_new_window
    wait_until 15 pw_instances_at_least 1 \
        && ok "[WIN-32] a phone at cap 2 still allows the second window" \
        || bad "[WIN-32] the second window was refused at cap 2"
    before="$(pw_opens)"
    pick_new_window disabled
    sleep 2
    [ "$(pw_opens)" = "$before" ] \
        && ok "[WIN-32] the cap follows the phone's number: the third open was refused" \
        || bad "[WIN-32] the Mac asked for a third window past a cap of 2"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # ---- Launch 3: a forced refusal closes the window and banners (WIN-32) --
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    FAKE_ARGS="--force-too-many-windows --tls-identity $WORK/phone.identity" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" \
        --debug-banner "$banner" --quit-after 120
    ctl_open --open com.android.chrome || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.chrome \
        || { bad "MULTIWIN forced: no window.open"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.chrome "Chrome (FakePhone)" || true
    pick_new_window
    wait_until 20 events_have '"kind":"refused"' \
        && ok "[WIN-32] the fake phone refused the extra window below its cap" \
        || bad "[WIN-32] the fake never refused"
    wait_until 15 grep -qF "Close a Chrome window to open another." "$banner" \
        && ok "[WIN-32] the Deck banner carries the cap's sentence" \
        || bad "[WIN-32] the banner reads '$(cat "$banner" 2>/dev/null | tail -1)'"
    # The window that asked closes; the phone's log keeps the refused request,
    # so count the Mac's windows, not the requests.
    chrome_windows() { window_titles "$APP_PID" | grep -c "Chrome"; }
    wait_until 15 eval '[ "$(window_titles "$APP_PID" | grep -c "Chrome")" = "1" ]' \
        && ok "[WIN-32] the refused window closed" \
        || bad "[WIN-32] the refused window stayed open ($(window_titles "$APP_PID" | tr '\n' '|'))"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # ---- Launch 4: a drop with two windows reopens two streams (WIN-34) ----
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    # The phone keeps its TLS identity across the restart (a new one would be a
    # different phone, and the Mac would refuse its own pin — `bad_pin`).
    FAKE_ARGS="--tls-identity $WORK/phone.identity" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" --quit-after 180
    ctl_open --open com.android.chrome || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.chrome \
        || { bad "MULTIWIN drop: no window.open"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.chrome "Chrome (FakePhone)" || true
    pick_new_window
    wait_until 15 pw_instances_at_least 1 \
        || { bad "MULTIWIN drop: the second window never opened"; stop_app; stop_fakephone; return 1; }
    sleep 1
    stop_fakephone
    sleep 2
    # The restarted phone opens the event log afresh, so what it holds after
    # this point is the reconnect's own traffic.
    FAKE_ARGS="--tls-identity $WORK/phone.identity" start_fake || return 1
    wait_until 90 pw_opens_reached 2 \
        && ok "[WIN-34] after the drop both windows re-opened their streams" \
        || bad "[WIN-34] the reconnect re-opened $(pw_opens) streams, not 2"
    python3 - "$WORK/events.jsonl" <<'PY' && ok "[WIN-34] the second window asks for its own task, the first does not" \
        || bad "[WIN-34] the reconnect's newInstance flags are wrong"
import json, sys
opens = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") or {}
    if event.get("ev") == "rx" and msg.get("t") == "window.open" and msg.get("pkg") == "com.android.chrome":
        opens.append(bool(msg.get("newInstance")))
if opens != [False, True]:
    print("flags:", opens); sys.exit(1)
PY
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # ---- Launch 5: the app's own New window (WIN-44…WIN-49) ----------------
    # The fake reports a task of the streamed app as the phone's listener
    # would; the New-item rule decides. The three cases below are one report
    # each: adopted, refused, and at the Mac's cap.
    chrome_windows() { window_titles "$APP_PID" | grep -c "Chrome"; }

    # A: the report becomes one more window and one adopt; the person then
    # opens the streamed app on the phone and that window closes quietly.
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    FAKE_ARGS="--report-task-after 5 --moved-to-phone-after 6 --tls-identity $WORK/phone.identity" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" --debug-banner "$banner" --quit-after 180
    ctl_open --open com.android.chrome || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.chrome \
        || { bad "MULTIWIN adopt: no window.open"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.chrome "Chrome (FakePhone)" || true
    local adopts_before
    adopts_before="$(pw_adopts)"
    wait_until 30 eval '[ "$(win_events task.report)" -ge 1 ]' \
        && ok "[WIN-44] the fake phone reported the app's own task once" \
        || bad "[WIN-44] no window.task reached the Mac"
    wait_until 20 eval '[ "$(pw_adopts)" -gt '"$adopts_before"' ]' \
        && ok "[WIN-45] the reported task sent one window.adopt" \
        || bad "[WIN-45] the Mac sent no window.adopt"
    [ "$(( $(pw_adopts) - adopts_before ))" = "1" ] \
        && ok "[WIN-45] exactly one adopt for one reported task" \
        || bad "[WIN-45] the Mac sent $(( $(pw_adopts) - adopts_before )) adopts for one task"
    wait_until 25 eval '[ "$(chrome_windows)" = "2" ]' \
        && ok "[WIN-45] the reported task opened one more window" \
        || bad "[WIN-45] the window count is $(chrome_windows), expected 2"
    wait_until 20 titles_have "Chrome — New tab (FakePhone)" \
        && ok "[WIN-45] the adopted window takes its task's label (WIN-28)" \
        || bad "[WIN-45] the adopted window is not titled by its task: $(window_titles "$APP_PID" | tr '\n' '|')"
    local closes_before
    closes_before="$(pw_closes)"
    wait_until 20 events_have '"kind":"moved_to_phone"' \
        && ok "[WIN-49] the fake phone moved the source task to its own screen" \
        || bad "[WIN-49] no moved_to_phone close reached the Mac"
    wait_until 15 eval '[ "$(chrome_windows)" = "1" ]' \
        && ok "[WIN-49] the moved window closed and the adopted one stayed" \
        || bad "[WIN-49] the moved window did not close (windows $(chrome_windows))"
    [ "$(pw_closes)" = "$closes_before" ] \
        && ok "[WIN-49] the moved window closed without a window.close back" \
        || bad "[WIN-49] the Mac answered moved_to_phone with a window.close"
    [ ! -s "$banner" ] \
        && ok "[WIN-49] moved_to_phone showed no launcher notice" \
        || bad "[WIN-49] the banner reads '$(tail -1 "$banner" 2>/dev/null)'"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # B: the phone refuses the move; that window closes quietly.
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    FAKE_ARGS="--report-task-after 5 --refuse-adopt --tls-identity $WORK/phone.identity" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" --debug-banner "$banner" --quit-after 180
    ctl_open --open com.android.chrome || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.chrome \
        || { bad "MULTIWIN refusal: no window.open"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.chrome "Chrome (FakePhone)" || true
    adopts_before="$(pw_adopts)"
    wait_until 20 eval '[ "$(pw_adopts)" -gt '"$adopts_before"' ]' \
        && ok "[WIN-46] the Mac asked the phone to adopt the task" \
        || bad "[WIN-46] the Mac sent no window.adopt"
    wait_until 20 events_have '"kind":"refused"' \
        && ok "[WIN-46] the fake phone refused the adopt" \
        || bad "[WIN-46] the fake never refused"
    wait_until 15 eval '[ "$(chrome_windows)" = "1" ]' \
        && ok "[WIN-46] cannot_adopt closed that window quietly" \
        || bad "[WIN-46] the refused window stayed open (windows $(chrome_windows))"
    [ ! -s "$banner" ] \
        && ok "[WIN-46] a refused adopt showed no launcher notice" \
        || bad "[WIN-46] the banner reads '$(tail -1 "$banner" 2>/dev/null)'"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # C: at the Mac's own cap, the task stays and the Deck says why.
    : > "$WORK/events.jsonl"
    rm -f "$banner"
    FAKE_ARGS="--report-task-after 15 --tls-identity $WORK/phone.identity" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" --debug-banner "$banner" --quit-after 180
    ctl_open --open com.android.chrome || { stop_app; stop_fakephone; return 1; }
    wait_until 20 window_rx window.open com.android.chrome \
        || { bad "MULTIWIN cap-adopt: no window.open"; stop_app; stop_fakephone; return 1; }
    sleep 1
    focus_app com.android.chrome "Chrome (FakePhone)" || true
    local n
    for n in 1 2 3; do
        pick_new_window
        sleep 1.5
    done
    sleep 2
    adopts_before="$(pw_adopts)"
    wait_until 30 eval '[ "$(win_events task.report)" -ge 1 ]' \
        && ok "[WIN-44] the report reached the Mac at the cap" \
        || bad "[WIN-44] no report at the cap"
    sleep 2
    [ "$(pw_adopts)" = "$adopts_before" ] \
        && ok "[WIN-45] at the Mac's cap the report sent no adopt" \
        || bad "[WIN-45] a window.adopt left the Mac at the cap"
    [ "$(chrome_windows)" = "4" ] \
        && ok "[WIN-45] at the cap the task opened no another window" \
        || bad "[WIN-45] the cap opened another window (windows $(chrome_windows))"
    wait_until 10 grep -qF "Close a Chrome window to open another." "$banner" \
        && ok "[WIN-45] the Deck carries the cap's sentence at the cap" \
        || bad "[WIN-45] the banner reads '$(tail -1 "$banner" 2>/dev/null)'"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    remove_dock_apps
}




# --- Several phones: slice 1, two live sessions and one current phone --------

# start_phone_fake <port> <tag> — one fakephone process with its own state,
# events and log (docs/design/multi-phone.md §8.1). Sets PHONE_FAKE_PID.
start_phone_fake() {
    local port="$1" tag="$2"
    "$FAKE_PY" "$FAKEPHONE" --port "$port" --no-mdns --auto-allow \
        --name "Fake $tag" --state "$WORK/phones-$tag-state.json" \
        --events "$WORK/phones-$tag-events.jsonl" \
        > "$WORK/phones-$tag.log" 2> "$WORK/phones-$tag.err" &
    PHONE_FAKE_PID=$!
    local _
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/phones-$tag.log" "$WORK/phones-$tag.err" 2>/dev/null && return 0
        sleep 0.25
    done
    say "fakephone $tag did not start:"; cat "$WORK/phones-$tag.log" "$WORK/phones-$tag.err"
    return 1
}

# check_phones — phase A of the `phones` check: pair A, pair B while A is kept
# by --connect-phone, A reconnects from its own pin while B is current, both
# answer pings for 20 s, and B's close leaves A online (PAIR-24..PAIR-29).
check_phones() {
    clean
    local port_a=47995 port_b=47994
    local ev_a="$WORK/phones-a-events.jsonl" ev_b="$WORK/phones-b-events.jsonl"
    local report="$WORK/phones.txt" id_a id_b status
    PHONE_FAKE_PID=""

    start_phone_fake "$port_a" a || return 1
    local pid_a="$PHONE_FAKE_PID"

    # First launch: pair A and remember its pin and cached address.
    launch --connect "127.0.0.1:$port_a" --quit-after 40
    wait_until 35 grep -qF -- '"state":"paired"' "$ev_a"
    if grep -qF -- '"state":"paired"' "$ev_a"; then
        ok "[PAIR-24] phones A paired first"
    else
        bad "[PAIR-24] phones A did not pair (events: $(tail -3 "$ev_a" 2>/dev/null | tr '\n' '|'))"
        stop_app; kill "$pid_a" 2>/dev/null; return 1
    fi
    id_a="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/phones-a-state.json" 2>/dev/null)"
    [ -n "$id_a" ] && ok "[PAIR-24] phones A has a device id" || bad "[PAIR-24] phones A has no device id"
    stop_app

    # Second launch: pair B as the current phone and reconnect A from its own
    # pin, kept by the test-hook claim, while B is current.
    start_phone_fake "$port_b" b || { kill "$pid_a" 2>/dev/null; return 1; }
    local pid_b="$PHONE_FAKE_PID"
    : > "$ev_a"; : > "$ev_b"
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$port_b" --connect-phone "127.0.0.1:$port_a" \
        --phones-report "$report" --debug-control "$WORK-control" --quit-after 90
    wait_until 35 grep -qF -- '"state":"paired"' "$ev_b" \
        && ok "[PAIR-24] phones B paired while A was live" \
        || bad "[PAIR-24] phones B did not pair"
    wait_until 25 grep -qF -- '"state":"auth_ok"' "$ev_a" \
        && ok "[PAIR-27] phones A reconnected from its pin" \
        || bad "[PAIR-27] phones A did not reconnect with its pin"
    grep -qF -- '"t":"pair.request"' "$ev_a" \
        && bad "[PAIR-27] phones A paired again instead of using its pin" \
        || ok "[PAIR-27] phones A sent no pair.request on reconnect"
    id_b="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/phones-b-state.json" 2>/dev/null)"
    [ -n "$id_b" ] && [ "$id_a" != "$id_b" ] \
        && ok "[PAIR-24] phones A and B have different device ids" \
        || bad "[PAIR-24] phones A and B share a device id"
    wait_until 25 grep -qF -- "phones=2 online=2 current=$id_b" "$report" \
        && ok "[PAIR-25] phones both online, current is B" \
        || bad "[PAIR-25] phones report never read both online with B current ($(cat "$report" 2>/dev/null | tr '\n' '|'))"
    grep -qF -- "id=$id_a state=online current=0" "$report" \
        && ok "[PAIR-25] phones A is online and not current" \
        || bad "[PAIR-25] phones A is not the non-current online row"
    grep -qF -- "id=$id_b state=online current=1" "$report" \
        && ok "[PAIR-25] phones B is the current online row" \
        || bad "[PAIR-25] phones B is not the current online row"
    # [DECK-30] With two phones remembered the Deck's title is the phone menu
    # (a popup button), not the plain phone name.
    if wait_until 10 eval 'ax_tree | grep -qE "(title|desc)=\[Phones\]"'; then
        ok "[DECK-30] with two phones the Deck's title is the phone menu"
    else
        bad "[DECK-30] the Deck has no phone menu with two phones ($(ax_tree | tr '\n' '|' | cut -c1-300))"
    fi

    # [PANEL-27] With two phones remembered the card names the phone in use and
    # the name is a checkmark pop-up; the card keeps its 300 pt width.
    control panelopen || bad "PHONES panelopen: $CONTROL_REPLY"
    control paneldump panel "$WORK/phones-panel.json" || bad "PHONES paneldump: $CONTROL_REPLY"
    python3 - "$WORK/phones-panel.json" <<'PY' \
        && ok "[PANEL-27] with two phones the card names the phone in use from its pop-up" \
        || bad "[PANEL-27] the two-phone card does not name the current phone"
import json, sys
root = json.load(open(sys.argv[1]))
kinds = [row["kind"] for row in root["items"]]
if kinds.count("phonePicker") != 1:
    print("phone pop-up items:", kinds); sys.exit(1)
if root["phone"] != "Fake b":
    print("card phone:", repr(root["phone"])); sys.exit(1)
if root["width"] != 300 or not root["mapped"]:
    print("width/mapped:", root["width"], root["mapped"]); sys.exit(1)
PY
    control panelclose >/dev/null 2>&1 || true

    # Both sessions answer the Mac's app-level ping for 20 s. The log is
    # cleared at the start of the window so each pong is inside it.
    : > "$ev_a"; : > "$ev_b"
    sleep 20
    grep -qF -- '"ev":"pong"' "$ev_a" \
        && ok "[PAIR-24] phones A answered a ping in the 20 s window" \
        || bad "[PAIR-24] phones A never answered a ping"
    grep -qF -- '"ev":"pong"' "$ev_b" \
        && ok "[PAIR-24] phones B answered a ping in the 20 s window" \
        || bad "[PAIR-24] phones B never answered a ping"
    grep -qF -- "phones=2 online=2 current=$id_b" "$report" \
        && ok "[PAIR-26] phones both stay online through the ping window" \
        || bad "[PAIR-26] phones lost a session during the ping window ($(cat "$report" 2>/dev/null | tr '\n' '|'))"

    # B's close (its process goes away) leaves A online and touches nothing of
    # A's session.
    kill "$pid_b" >/dev/null 2>&1
    wait "$pid_b" 2>/dev/null
    wait_until 20 grep -qF -- "phones=2 online=1 current=$id_b" "$report" \
        && ok "[PAIR-24] phones B's close leaves only A online" \
        || bad "[PAIR-24] phones B's close did not leave A alone online ($(cat "$report" 2>/dev/null | tr '\n' '|'))"
    grep -qF -- "id=$id_a state=online" "$report" \
        && ok "[PAIR-26] phones A's session still reads online after B's close" \
        || bad "[PAIR-26] phones A's session changed when B closed"
    status="$(grep -o "id=$id_b state=[^ ]*" "$report" | tail -1)"
    case "$status" in
        *state=online*) bad "[PAIR-26] phones B still reads online after its close" ;;
        *) ok "[PAIR-26] phones B alone reads offline after its close" ;;
    esac

    stop_app
    kill "$pid_a" >/dev/null 2>&1
    wait "$pid_a" 2>/dev/null
}

# --- Windows: one window per app, and the opening cover ---------------------

# check_windows — the app window's own behaviour, driven through the Deck's
# cells (the control a person clicks) and the window's chrome state. WIN-2: a
# second Deck click on an app whose window is open raises that window, with no
# second window.open. The opening-cover phases (WIN-11, the L1 design) follow.
check_windows() {
    begin_shared || return 1
    # The Deck arrives with the session: setup waits for it, the cell click is
    # the control under test.
    wait_until 20 control deckquery || bad "WINDOWS deckquery: $CONTROL_REPLY"
    wait_until 20 control deckfocus grid || bad "WINDOWS deckfocus: $CONTROL_REPLY"
    # The grid has drawn and its cells have their own places before the click:
    # a visible run's activation can otherwise land a click on the old layout.
    sleep 2
    local opens_before wins_before wins_one win
    opens_before="$(count_events '"t":"window.open"' | head -1)"
    wins_before="$(windows | wc -l | tr -d ' ')"
    control deckclick Chrome \
        || bad "WINDOWS the Deck cell click: $CONTROL_REPLY"
    wait_until 25 [ "$(count_events '"t":"window.open"' | head -1)" -gt "$opens_before" ] \
        && ok "WINDOWS the Deck cell opened an app window (one window.open)" \
        || bad "WINDOWS the Deck cell sent no window.open ($(count_events '"t":"window.open"' | head -1) total)"
    wait_until 25 events_have '"ev":"video"' \
        || bad "WINDOWS the opened stream sent no video"
    win="$(await_window '$4 == 900')" || bad "WINDOWS no 900 pt app window after the click"
    titles_have "Chrome (FakePhone)" \
        && ok "[WIN-3] WINDOWS the window is titled for the app and the phone" \
        || bad "[WIN-3] WINDOWS the window title: $(window_titles "$APP_PID" | tr '\n' '|')"
    # The bar's full-screen structure with an app window key: the app draws no
    # item of its own, and AppKit's own is last in View (MENU-4, MENU-7).
    rm -f "$WORK/windows-menu.json"
    control menudump "$WORK/windows-menu.json" || bad "WINDOWS menudump: $CONTROL_REPLY"
    if reason="$(full_screen_bar_ok "$WORK/windows-menu.json" "windows (an app window key)" "$([ "$VISIBLE" = 1 ] && echo 1 || echo 0)")"; then
        ok "[MENU-7] $reason"
    else
        bad "[MENU-7] windows: $reason"
    fi
    sleep 1
    wins_one="$(windows | wc -l | tr -d ' ')"

    # The person clicks the same cell again, now that the picture is in.
    local opens_one
    opens_one="$(count_events '"t":"window.open"' | head -1)"
    control deckfocus grid || bad "WINDOWS deckfocus (second click): $CONTROL_REPLY"
    control deckclick Chrome \
        || bad "WINDOWS the second Deck cell click: $CONTROL_REPLY"
    sleep 1
    [ "$(count_events '"t":"window.open"' | head -1)" = "$opens_one" ] \
        && ok "[WIN-2] WINDOWS a second Deck click sent no window.open (still $opens_one)" \
        || bad "[WIN-2] WINDOWS the second click asked for another stream ($(count_events '"t":"window.open"' | head -1) opens)"
    [ "$(windows | wc -l | tr -d ' ')" = "$wins_one" ] \
        && ok "[WIN-2] WINDOWS one window for the app, not two" \
        || bad "[WIN-2] WINDOWS the app has $(windows | wc -l | tr -d ' ') windows (one before the click)"
    control keywindow "$WORK/keywindow.txt" >/dev/null 2>&1 || true
    [ "$(sed -n 2p "$WORK/keywindow.txt" 2>/dev/null)" = "Chrome (FakePhone)" ] \
        && ok "[WIN-2] WINDOWS the existing window is key (raised)" \
        || bad "[WIN-2] WINDOWS the second click did not raise the window ($(tr '\n' '|' < "$WORK/keywindow.txt" 2>/dev/null))"

    # --- Find Apps (⌘K) and the search's Return ---------------------------
    # The same rule through the keyboard: ⌘K brings the Deck up, the query
    # narrows to one app and Return opens it; the second time raises it.
    local k_opens k_wins
    control key cmd+k || bad "WINDOWS ⌘K: $CONTROL_REPLY"
    sleep 1.5
    control deckquery WhatsApp || bad "WINDOWS deckquery (Find Apps): $CONTROL_REPLY"
    control key return || bad "WINDOWS Return in Find Apps: $CONTROL_REPLY"
    wait_until 20 window_rx window.open com.whatsapp \
        && ok "WINDOWS Find Apps' Return opened the app's window" \
        || bad "WINDOWS Find Apps' Return sent no window.open for WhatsApp"
    k_opens="$(count_events '"t":"window.open"' | head -1)"
    k_wins="$(windows | wc -l | tr -d ' ')"
    sleep 1
    control key cmd+k || bad "WINDOWS ⌘K (second time): $CONTROL_REPLY"
    sleep 0.5
    control deckquery WhatsApp || bad "WINDOWS deckquery (second Find): $CONTROL_REPLY"
    control key return || bad "WINDOWS Return in Find Apps (second time): $CONTROL_REPLY"
    sleep 1
    [ "$(count_events '"t":"window.open"' | head -1)" = "$k_opens" ] \
        && ok "[WIN-2] WINDOWS Find Apps' second Return sent no window.open (still $k_opens)" \
        || bad "[WIN-2] WINDOWS Find Apps asked for a second stream ($(count_events '"t":"window.open"' | head -1) opens)"
    [ "$(windows | wc -l | tr -d ' ')" = "$k_wins" ] \
        && ok "[WIN-2] WINDOWS Find Apps raised the existing window (one window)" \
        || bad "[WIN-2] WINDOWS Find Apps made a second window"
    control keywindow "$WORK/keywindow.txt" >/dev/null 2>&1 || true
    [ "$(sed -n 2p "$WORK/keywindow.txt" 2>/dev/null)" = "WhatsApp (FakePhone)" ] \
        && ok "[WIN-2] WINDOWS Find Apps' raise made the window key and front" \
        || bad "[WIN-2] WINDOWS Find Apps did not raise the window ($(tr '\n' '|' < "$WORK/keywindow.txt" 2>/dev/null))"
    end_shared

    # --- L1: opening -> slow -> Cancel ------------------------------------
    # The fake holds the first frame, so a quiet run sees the opening state
    # and, at 5 s, the slow one with Cancel.
    clean
    rm -f "$WORK/chrome.txt"
    mkdir -p "$WORK/control"
    FAKE_ARGS="--first-frame-delay 30" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK-control" --quit-after 75
    ax_has() { ax_tree | grep -qF -- "$1"; }
    wait_until 20 chrome_has "cover_phase=opening cover_buttons=none" \
        && ok "[WIN-11] L1 opening: the cover is up with no buttons ($(chrome_state | grep -o 'loading=[^ ]* .*cover_buttons=[^ ]*'))" \
        || bad "[WIN-11] L1 opening: $(chrome_state)"
    chrome_has "haze=0" \
        && ok "[WIN-40] the opening cover's ground takes the bar's haze away" \
        || bad "[WIN-40] the opening cover left the haze up: $(chrome_state)"
    # The shot first: the opening state lasts 5 s, and the accessibility walk
    # is slower than the rest of that window. Two seconds in, the phone's app
    # list and icon have usually arrived (a Deck click already has them).
    if [ "$VISIBLE" = 1 ]; then
        sleep 3
        local lid
        lid="$(await_window '$4 == 900')" \
            && screencapture -x -o -l"$lid" "$SHOTS/l1-opening.png" \
            && say "shot: $SHOTS/l1-opening.png" \
            || bad "L1 no opening shot"
    else
        skip_visible "L1 the opening cover's shot"
    fi
    wait_until 10 ax_has "Settings — opening on FakePhone" \
        && ok "[WIN-11] L1 the cover's title is \"<App> — opening on <phone>\"" \
        || bad "[WIN-11] L1 the cover's title: $(ax_tree | grep -i 'opening' | head -2 | tr '\n' '|')"
    wait_until 12 chrome_has "cover_phase=slow cover_buttons=cancel" \
        && ok "[WIN-11] L1 at 5 s: the slow state shows Cancel" \
        || bad "[WIN-11] L1 the slow state: $(chrome_state)"
    wait_until 10 ax_has "Taking longer than usual" \
        && ok "[WIN-11] L1 the slow state says \"Taking longer than usual\"" \
        || bad "[WIN-11] L1 the slow line is missing"
    if [ "$VISIBLE" = 1 ]; then
        if [ -n "${lid:-}" ]; then
            screencapture -x -o -l"$lid" "$SHOTS/l1-slow.png" && say "shot: $SHOTS/l1-slow.png"
        fi
    else
        skip_visible "L1 the slow cover's shot"
    fi
    control coverclick Cancel \
        || bad "L1 the Cancel click: $CONTROL_REPLY"
    wait_until 10 events_have '"t":"window.close"' \
        && ok "[WIN-11] L1 Cancel closes the window and sends window.close (the open is cancelled on the phone)" \
        || bad "[WIN-11] L1 Cancel sent no window.close"
    wait_until 5 eval '! windows | awk "\$4 == 900" | grep -q .' \
        && ok "[WIN-11] L1 Cancel closed the window" \
        || bad "[WIN-11] L1 the window stayed after Cancel"
    stop_app
    stop_fakephone

    # --- L1: the phone's refusal fails the cover at once ------------------
    clean
    rm -f "$WORK/chrome.txt"
    mkdir -p "$WORK/control"
    FAKE_ARGS="--window-refuse app_disabled" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK-control" --quit-after 60
    wait_until 20 chrome_has "cover_phase=failed cover_buttons=close" \
        && ok "[WIN-11] L1 a refused app: the failed state offers Close alone" \
        || bad "[WIN-11] L1 the refused cover: $(chrome_state)"
    wait_until 10 ax_has "FakePhone can't open Settings." \
        && ok "[WIN-11] L1 the refusal is \"<phone> can't open <app>.\"" \
        || bad "[WIN-11] L1 the refusal sentence: $(ax_tree | grep -i 'can.t open' | head -2 | tr '\n' '|')"
    wait_until 10 ax_has "The app is disabled on the phone." \
        && ok "[WIN-11] L1 the reason line maps the phone's error code" \
        || bad "[WIN-11] L1 the reason line is missing"
    ! ax_has "Try Again" \
        && ok "[WIN-11] L1 a refused open has no Try Again" \
        || bad "[WIN-11] L1 the refused cover still offers Try Again"
    if [ "$VISIBLE" = 1 ]; then
        local fid
        fid="$(await_window '$4 == 900')" \
            && screencapture -x -o -l"$fid" "$SHOTS/l1-refused.png" \
            && say "shot: $SHOTS/l1-refused.png" \
            || bad "L1 no refused shot"
        stop_app
        # A new launch is a new window: count this phase's opens on their own.
        : > "$WORK/events.jsonl"
        launch --connect "127.0.0.1:$PORT" --open com.android.settings --appearance light \
            --debug-chrome-state "$WORK/chrome.txt" --quit-after 30
        wait_until 20 chrome_has "cover_phase=failed cover_buttons=close" || bad "L1 the light refusal did not show"
        fid="$(await_window '$4 == 900')" \
            && screencapture -x -o -l"$fid" "$SHOTS/l1-refused-light.png" \
            && say "shot: $SHOTS/l1-refused-light.png" \
            || bad "L1 no light refused shot"
    else
        skip_visible "L1 the refusal's dark and light shots"
    fi
    sleep 21
    [ "$(count_events '"t":"window.open"' | head -1)" = "1" ] \
        && ok "[WIN-11] L1 the refused phone was never asked again (one window.open)" \
        || bad "[WIN-11] L1 the refused open sent $(count_events '"t":"window.open"' | head -1) window.open"
    [ "$(chrome_state | grep -o 'loading=[^ ]*')" = "loading=failed" ] \
        && ok "[WIN-11] L1 the refusal stands 21 s later (the clock does not replace it)" \
        || bad "[WIN-11] L1 the cover changed after the refusal: $(chrome_state | grep -o 'loading=[^ ]*')"
    stop_app
    stop_fakephone

    # --- L1 on the Phone Mirror: the same cover, "phone screen" wording ----
    clean
    rm -f "$WORK/chrome.txt"
    FAKE_ARGS="--mirror-unavailable" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --appearance dark \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK-control" --quit-after 45
    wait_until 20 chrome_has "cover_phase=failed cover_buttons=close" \
        && ok "[MIRROR-2] the Mirror wears the same cover, failed with Close only" \
        || bad "[MIRROR-2] the Mirror's refused cover: $(chrome_state)"
    # [WIN-22] A refused mirror freezes the bar's phone controls: a click at
    # Back sends no nav to a phone that cannot mirror.
    wait_until 5 chrome_has "bar_enabled=none" \
        && ok "[WIN-22] the refused mirror's bar controls are disabled" \
        || bad "[WIN-22] the refused mirror left a bar control enabled: $(chrome_state)"
    local refused_navs
    refused_navs="$(count_events '"t":"nav"' | head -1)"
    control nav-click back || true
    sleep 1
    [ "$(count_events '"t":"nav"' | head -1)" = "$refused_navs" ] \
        && ok "[WIN-22] a click on the disabled Back sent no nav to the phone" \
        || bad "[WIN-22] the disabled Back still reached the phone"
    wait_until 10 ax_has "FakePhone can't open the phone screen." \
        && ok "[MIRROR-2] the Mirror's sentence uses the phone-screen wording" \
        || bad "[MIRROR-2] the Mirror's sentence: $(ax_tree | grep -i 'phone screen' | head -2 | tr '\n' '|')"
    wait_until 10 ax_has "This phone can't share its screen with Contigua." \
        && ok "[MIRROR-2] conv-fixes-1's sentence is the refusal's reason line" \
        || bad "[MIRROR-2] the refusal's reason line is missing"
    if [ "$VISIBLE" = 1 ]; then
        if screenshot_portrait "$SHOTS/mirror-unavailable.png"; then
            say "shot: $SHOTS/mirror-unavailable.png"
        else
            bad "MIRROR-2 no shot of the refused cover"
        fi
    else
        skip_visible "MIRROR-2 the refused cover's shot"
    fi
    stop_app
    stop_fakephone

    # --- WIN-38: a Mac close is quiet -------------------------------------
    # The person closes a live app window with ⌘W while the pointer is over the
    # picture (a hover is live and a hover move is waiting in the mapper's 16 ms
    # throttle) and AppKit reports the key window occluded as it goes. Both used
    # to reach the phone after `window.close`; it answers `error no_stream` and
    # the launcher showed "That window is no longer open on the phone".
    clean
    rm -f "$WORK/banner.txt"
    start_fake || return 1
    printf 'wait 3\nhover 0.5 0.5\nhover 0.4 0.5\nkey cmd+w\nwait 10\n' > "$WORK/close-input.txt"
    launch --connect "127.0.0.1:$PORT" --open com.whatsapp \
        --debug-input-script "$WORK/close-input.txt" \
        --debug-banner "$WORK/banner.txt" --quit-after 30
    wait_until 25 window_rx window.open "com.whatsapp" \
        || bad "WIN-38 the app window never opened"
    wait_until 20 events_have '"ev":"video","stream":1,' \
        || bad "WIN-38 the stream never sent video"
    wait_until 15 window_rx window.close \
        || bad "WIN-38 the person's close sent no window.close"
    wait_until 10 eval '! windows | awk "\$4 == 900" | grep -q .' \
        && ok "[WIN-12] closing the app window closed it" \
        || bad "[WIN-12] the app window stayed after its close"
    # The phone's answer to a late message takes a round trip: give it 3 s.
    sleep 3
    late="$(stream_after_close 1)"
    [ "$late" = "none" ] \
        && ok "[WIN-38] the Mac sent nothing for the closed stream after its window.close" \
        || bad "[WIN-38] the Mac sent $late for stream 1 after its window.close"
    ! grep -qF "That window is no longer open on the phone" "$WORK/banner.txt" 2>/dev/null \
        && ok "[WIN-38] the launcher said nothing about the closed window" \
        || bad "[WIN-38] the launcher showed \"$(cat "$WORK/banner.txt" 2>/dev/null)\" after a close"
    stop_app
    stop_fakephone

    # --- WIN-40: the bar's system blur and its haze ----------------------
    # Live, the mirror's variableBlur carries the picked 15 pt radius and the
    # haze is up over the bar band; the opening cover's ground takes the haze
    # away (the L1 opening phase above).
    clean
    rm -f "$WORK/chrome.txt"
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --debug-chrome-state "$WORK/chrome.txt" --quit-after 45
    wait_until 20 events_have '"ev":"video"' \
        || bad "WIN-40 the stream never sent video"
    # Two fields, matched apart: the state line puts the tint and title between them.
    wait_until 15 eval 'chrome_has "bar_blur_radius=30 " && chrome_has " haze=1 "' \
        && ok "[WIN-40] the live bar's system blur is 30 and the haze is up ($(chrome_state | grep -o 'bar_blur_radius=[0-9]*\| haze=[0-9]*' | tr -d '\n'))" \
        || bad "[WIN-40] the live bar: $(chrome_state)"
    stop_app
    stop_fakephone
}

# --- Cover bar: WIN-11's opening cover in the immersive geometry ------------
#
# The visual record for the person's 11-03 report: a framed window with no
# first frame looks exactly as the same window does in immersive — one sheet
# over the whole window, the bar's band included — and the framed bar returns
# with the first frame. A quiet run captures the run's own virtual display;
# the record the reviewer sees is the VM's visible run. The two check names are
# the two appearances.

# --- Barname: the Framed bar's heavier blur, tint and centred name ----------
#
# The three fixture pictures (a white page, a dark page and a busy photo) in
# both appearances at 2x. Each phase reads the chrome state's tone and title
# rect, captures the real window and measures the worst band contrast behind
# the glyphs (bar-title-contrast.py, WIN-69). The phone mirror runs the same
# title with the phone's name (MIRROR-26). Visual record: $SHOTS/bar-title-*.

bar_title_field() { chrome_state | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }

# bar_title_measure <shot> <label> <right-inset> — one capture's title check:
# inside the lights and the right-hand row, and the measured contrast.
bar_title_measure() {
    local shot="$1" label="$2" right_inset="$3" rect tone frame_width limit measured
    rect="$(bar_title_field bar_title_rect)"
    tone="$(bar_title_field bar_title_tone)"
    frame_width="$(bar_title_field frame)"
    frame_width="${frame_width%%x*}"
    [ -n "$rect" ] && [ "$rect" != "none" ] || { bad "BAR-TITLE $label no title rect in the state"; return 1; }
    local rx rw right_bound
    IFS=, read -r rx _ rw _ <<<"$rect"
    right_bound=$((frame_width - right_inset))
    if [ "$rx" -ge 75 ] && [ $((rx + rw)) -le "$right_bound" ]; then
        ok "BAR-TITLE $label the title sits clear of the lights and the right-hand controls (x=$rx w=$rw)"
    else
        bad "BAR-TITLE $label the title overlaps a control: x=$rx w=$rw right-bound=$right_bound"
    fi
    limit="$(nfr_limit bar_title_contrast_min)"
    if measured="$(python3 "$MACOS/scripts/bar-title-contrast.py" "$shot" "$rect" "$frame_width" "$tone" "$limit" "$label" 2>&1)"; then
        ok "[WIN-69] BAR-TITLE $label contrast from the real capture: $measured"
    else
        bad "[WIN-69] BAR-TITLE $label contrast from the real capture: $measured"
    fi
}

check_bar_title() {
    local fixture appearance want win shot bar frame_width seam
    ax_has() { ax_tree | grep -qF -- "$1"; }
    for appearance in light dark; do
        for fixture in white-page dark-page busy-photo; do
            clean
            FAKE_ARGS="--image-frame $MACOS/scripts/fixtures/bar/$fixture.png" start_fake || return 1
            launch --connect "127.0.0.1:$PORT" --appearance "$appearance" \
                --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" --quit-after 70
            wait_until 25 events_have '"ev":"video"' \
                || bad "BAR-TITLE $appearance/$fixture the stream never sent video"
            wait_until 15 chrome_has "bar_title=1" \
                || bad "BAR-TITLE $appearance/$fixture no bar title: $(chrome_state)"
            # The sample is at most 2 Hz: one beat after the first frame.
            sleep 1
            case "$fixture/$appearance" in
                dark-page/*) want=light ;;
                *) want=dark ;;
            esac
            if wait_until 5 chrome_has "bar_title_tone=$want"; then
                ok "[WIN-69] BAR-TITLE $appearance/$fixture the tone follows the band: $want"
            else
                bad "[WIN-69] BAR-TITLE $appearance/$fixture wanted tone $want, state: $(bar_title_field bar_title_tone)"
            fi
            chrome_has "bar_blur_radius=30" && chrome_has "bar_tint=0.14 tint=1" \
                && ok "[WIN-67] BAR-TITLE $appearance/$fixture blur=30 tint=0.14 over the band" \
                || bad "[WIN-67] BAR-TITLE $appearance/$fixture bar: $(chrome_state)"
            if wait_until 5 ax_has "value=[Settings]"; then
                ok "[WIN-68] BAR-TITLE $appearance/$fixture the bar names the app alone"
            else
                bad "[WIN-68] BAR-TITLE $appearance/$fixture the bar's name: $(ax_tree | grep -i 'Settings' | head -2 | tr '\n' '|')"
            fi
            win="$(await_window '$4 == 900')" || { bad "BAR-TITLE $appearance/$fixture no 900 pt window"; continue; }
            shot="$SHOTS/bar-title-$fixture-$appearance.png"
            if shot_window "$win" "$shot"; then
                say "shot: $shot"
                bar_title_measure "$shot" "$appearance/$fixture" 43
            else
                bad "BAR-TITLE $appearance/$fixture no window capture"
            fi
            stop_app
            stop_fakephone
        done
    done

    # The Phone Mirror's bar names the phone, not the mirrored app (MIRROR-26).
    for appearance in light dark; do
        clean
        FAKE_ARGS="--image-frame $MACOS/scripts/fixtures/bar/white-page.png" start_fake || return 1
        launch --connect "127.0.0.1:$PORT" --appearance "$appearance" --open-phone \
            --debug-chrome-state "$WORK/chrome.txt" --quit-after 70
        wait_until 25 events_have '"ev":"video"' \
            || bad "BAR-TITLE phone/$appearance the stream never sent video"
        sleep 2
        # A portrait Mirror leaves less room than the phone's name needs, and
        # a name cut down to two letters reads worse than none (WIN-68).
        if chrome_has "bar_title=0 bar_title_tone=none bar_title_rect=none"; then
            ok "[MIRROR-26] BAR-TITLE phone/$appearance a name that does not fit is not drawn"
        else
            bad "[MIRROR-26] BAR-TITLE phone/$appearance wanted no title, state: $(chrome_state)"
        fi
        win="$(await_window '$5 > $4')" || { bad "BAR-TITLE phone/$appearance no portrait window"; continue; }
        shot="$SHOTS/bar-title-phone-$appearance.png"
        if shot_window "$win" "$shot"; then
            say "shot: $shot"
            # ISS-87: the picture's first rows must meet the 28 pt bar's
            # bottom edge; a backing row between them is a black line under
            # the bar in light and dark.
            bar="$(chrome_state | grep -oE ' bar:[0-9]+' | tail -1 | cut -d: -f2)"
            frame_width="$(bar_title_field frame)"
            frame_width="${frame_width%%x*}"
            if [ -n "$bar" ] && [ -n "$frame_width" ] \
                && seam="$(python3 "$MACOS/scripts/seam-gap.py" "$shot" "$frame_width" "$bar" 2>&1)"; then
                ok "[MIRROR-27] BAR-TITLE phone/$appearance no backing row at the bar's seam ($seam)"
            else
                bad "[MIRROR-27] BAR-TITLE phone/$appearance a backing row at the bar's seam (${seam:-no seam})"
            fi
        else
            bad "BAR-TITLE phone/$appearance no window capture"
        fi
        stop_app
        stop_fakephone
    done
}

check_cover_bar() {
    local appearance="$1" shots="$SHOTS/cover-bar" id style key width height style_name
    clean
    mkdir -p "$shots"
    local style_store="chrome.style.com.android.settings"

    # The opening cover is one sheet over the stored style's window: Framed's
    # 5/38 pt frame band is under it, and Immersive's 28 pt bar is. The fake
    # holds the first frame (and its video config), so no scripted driver runs.
    for style in framed immersive; do
        if [ "$style" = "framed" ]; then key=mat; width=910; height=643
        else key=immersive; width=900; height=628; fi
        defaults write "$DEFAULTS_SUITE" "$style_store" -string "$key"
        clean
        FAKE_ARGS="--first-frame-delay 30" start_fake || return 1
        launch --connect "127.0.0.1:$PORT" --appearance "$appearance" --open com.android.settings \
            --debug-chrome-state "$WORK/chrome.txt" --quit-after 25
        wait_until 20 chrome_has "loading=1 cover_phase=opening" \
            || bad "COVER-BAR $appearance $style no opening state: $(chrome_state)"
        id="$(await_window "\$4 == $width && \$5 == $height")" \
            || bad "COVER-BAR $appearance no $style window ($width x $height)"
        sleep 0.6
        if [ -n "$id" ]; then
            shot_window "$id" "$shots/$style-opening-$appearance.png" \
                && ok "COVER-BAR $appearance $style opening shot: $shots/$style-opening-$appearance.png" \
                || bad "COVER-BAR $appearance no $style opening shot"
        fi
        wait_until 8 chrome_has "cover_phase=slow cover_buttons=cancel" \
            || bad "COVER-BAR $appearance $style no slow state: $(chrome_state)"
        if [ -n "$id" ]; then
            shot_window "$id" "$shots/$style-slow-$appearance.png" \
                && ok "COVER-BAR $appearance $style slow shot: $shots/$style-slow-$appearance.png" \
                || bad "COVER-BAR $appearance no $style slow shot"
        fi
        stop_app
        stop_fakephone
    done

    # The first frame restores the stored style's windowed chrome: Immersive
    # brings its mirror and haze, Framed its material frame and no haze.
    for style in framed immersive; do
        if [ "$style" = "framed" ]; then key=mat; width=910; height=643
        else key=immersive; width=900; height=628; fi
        defaults write "$DEFAULTS_SUITE" "$style_store" -string "$key"
        clean
        start_fake || return 1
        launch --connect "127.0.0.1:$PORT" --appearance "$appearance" --open com.android.settings \
            --debug-chrome-state "$WORK/chrome.txt" --quit-after 25
        wait_until 20 events_have '"ev":"video"' || bad "COVER-BAR $appearance $style no video"
        wait_until 15 chrome_has "loading=0" \
            || bad "COVER-BAR $appearance $style the first frame did not land: $(chrome_state)"
        if [ "$style" = "immersive" ]; then
            wait_until 10 chrome_has "haze=1" \
                || bad "COVER-BAR $appearance immersive has no mirror"
        else
            chrome_has "haze=0" \
                || bad "COVER-BAR $appearance framed drew a mirror"
        fi
        id="$(await_window "\$4 == $width && \$5 == $height")" \
            || bad "COVER-BAR $appearance no live $style window"
        sleep 0.5
        if [ -n "$id" ]; then
            shot_window "$id" "$shots/$style-live-$appearance.png" \
                && ok "COVER-BAR $appearance $style live shot: $shots/$style-live-$appearance.png" \
                || bad "COVER-BAR $appearance no $style live shot"
        fi
        stop_app
        stop_fakephone
    done

    # The VM run copies $WORK back to the host, not the run's shot dir.
    mkdir -p "$WORK/cover-bar"
    cp -R "$shots/." "$WORK/cover-bar/"
    say "shots: $WORK/cover-bar ($appearance)"
}

check_cover_bar_dark() { check_cover_bar dark; }
check_cover_bar_light() { check_cover_bar light; }

# --- Styles: the two looks over the three fixtures ---------------------------
#
# The reviewer's visual record (ISS-45): every style × app / Phone Mirror ×
# appearance × windowed, and — in a visible run, where the pointer and the
# Space are real — full screen hidden and revealed, over the bar fixtures.
# Phone Mirror never goes full screen (WIN-72), so its full-screen cells do
# not exist. A quiet run takes the windowed cells only.
check_styles_shots() {
    local appearance style fixture surface key width height id full
    local style_store="chrome.style.com.android.settings"
    local shots="$SHOTS/styles"
    mkdir -p "$shots"
    for appearance in light dark; do
        for fixture in white-page dark-page busy-photo; do
            for surface in app mirror; do
                for style in immersive framed; do
                    clean
                    FAKE_ARGS="--image-frame $MACOS/scripts/fixtures/bar/$fixture.png" start_fake || return 1
                    if [ "$style" = "framed" ]; then key=mat; width=910; height=643
                    else key=immersive; width=900; height=628; fi
                    defaults write "$DEFAULTS_SUITE" "$style_store" -string "$key"
                    defaults write "$DEFAULTS_SUITE" "chrome.style.phone" -string "$key"
                    rm -f "$WORK/ss-begin" "$WORK/ss-hidden" "$WORK/ss-revealed" "$WORK/ss-exit" "$WORK/ss-done"
                    printf '%s\n' "wait 1" "waitfile $WORK/ss-begin 90" "fullscreen" "wait 5" \
                        "waitfile $WORK/ss-hidden 90" "waitfile $WORK/ss-revealed 90" \
                        "waitfile $WORK/ss-exit 90" "fullscreen" "wait 8" \
                        "waitfile $WORK/ss-done 90" "wait 5" > "$WORK/styles-fs.txt"
                    if [ "$surface" = "mirror" ]; then
                        launch --connect "127.0.0.1:$PORT" --appearance "$appearance" --open-phone \
                            --debug-chrome-state "$WORK/chrome.txt" --quit-after 70
                    else
                        local driver=()
                        [ "$VISIBLE" = "1" ] && driver=(--debug-input-script "$WORK/styles-fs.txt")
                        launch --connect "127.0.0.1:$PORT" --appearance "$appearance" \
                            --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
                            ${driver[@]+"${driver[@]}"} --quit-after 90
                    fi
                    wait_until 30 events_have '"ev":"video"' \
                        || bad "STYLES-SHOTS $appearance/$fixture/$style/$surface no video"
                    wait_until 30 chrome_frame_live \
                        || bad "STYLES-SHOTS $appearance/$fixture/$style/$surface never reached a live picture: $(chrome_state)"
                    if [ "$surface" = "app" ]; then
                        if [ "$style" = "immersive" ]; then
                            wait_until 10 eval 'chrome_has "bar_title=1" && ! chrome_has "bar_title_tone=none"' \
                                || bad "STYLES-SHOTS $appearance/$fixture/$style no toned bar title: $(chrome_state)"
                        else
                            wait_until 10 chrome_has "bar_title=1" \
                                || bad "STYLES-SHOTS $appearance/$fixture/$style no framed title: $(chrome_state)"
                        fi
                    fi
                    sleep 0.3
                    if ! chrome_frame_live; then
                        bad "STYLES-SHOTS $appearance/$fixture/$style/$surface is not live for its shot: $(chrome_state)"
                        stop_app
                        continue
                    fi
                    if [ "$surface" = "mirror" ]; then
                        id="$(await_window '$5 > $4')" || bad "STYLES-SHOTS $appearance/$fixture/$style no mirror window"
                    else
                        id="$(await_window "\$4 == $width && \$5 == $height")" \
                            || bad "STYLES-SHOTS $appearance/$fixture/$style no $width x $height window"
                    fi
                    if [ -n "$id" ]; then
                        shot_window "$id" "$shots/$style-$surface-$fixture-$appearance-windowed.png" \
                            && ok "STYLES-SHOTS $appearance/$fixture/$style/$surface windowed" \
                            || bad "STYLES-SHOTS $appearance/$fixture/$style/$surface no windowed shot"
                    fi
                    if [ "$surface" = "mirror" ]; then
                        chrome_has "can_fullscreen=0" \
                            && ok "[WIN-72] STYLES-SHOTS $appearance/$fixture/$style the Phone Mirror cannot go full screen" \
                            || bad "[WIN-72] STYLES-SHOTS $appearance/$fixture/$style the Phone Mirror offered full screen"
                    elif [ "$VISIBLE" = "1" ]; then
                        touch "$WORK/ss-begin"
                        full="$win"
                        if wait_until 20 chrome_all fullscreen=yes fullbar=hidden; then
                            ok "[WIN-8] STYLES-SHOTS $appearance/$fixture/$style full screen starts with the bar hidden ($(chrome_state))"
                        else
                            bad "[WIN-8] STYLES-SHOTS $appearance/$fixture/$style never entered full screen: $(chrome_state)"
                            stop_app
                            continue
                        fi
                        sleep 0.4
                        shot_window "$full" "$shots/$style-app-$fixture-$appearance-full-hidden.png" \
                            && ok "STYLES-SHOTS $appearance/$fixture/$style full hidden" \
                            || bad "STYLES-SHOTS $appearance/$fixture/$style no full-hidden shot"
                        touch "$WORK/ss-hidden"
                        # Inside the 8 pt edge band; below the system menu
                        # bar's own reveal strip.
                        cg_input moveat --x 200 --y 6
                        sleep 0.5
                        if wait_until 8 chrome_has "fullbar=shown"; then
                            ok "[WIN-8] STYLES-SHOTS $appearance/$fixture/$style a rest at the top edge reveals the bar ($(chrome_state))"
                            sleep 0.3
                            shot_window "$full" "$shots/$style-app-$fixture-$appearance-full-revealed.png" \
                                && ok "STYLES-SHOTS $appearance/$fixture/$style full revealed" \
                                || bad "STYLES-SHOTS $appearance/$fixture/$style no full-revealed shot"
                        else
                            bad "[WIN-8] STYLES-SHOTS $appearance/$fixture/$style the top edge revealed nothing: $(chrome_state)"
                        fi
                        touch "$WORK/ss-revealed"
                        touch "$WORK/ss-exit"
                        sleep 0.5
                        wait_until 15 win_size "$id" "$width" "$height" \
                            || bad "STYLES-SHOTS $appearance/$fixture/$style did not leave full screen"
                        touch "$WORK/ss-done"
                    else
                        skip_visible "STYLES-SHOTS $appearance/$fixture/$style full screen (a real Space and pointer)"
                    fi
                    stop_app
                done
            done
        done
    done
    mkdir -p "$WORK/styles-shots"
    cp -R "$shots/." "$WORK/styles-shots/"
    say "shots: $WORK/styles-shots"
}

# fullscreen_pair_pixels HIDDEN REVEALED W H — the full-screen bar as pixels:
# "hidden_edges=NN revealed_edges=NN bar_edge=NN title_edges=LL/CC". W x H is
# the full-screen window in points, never the windowed size, so `scale` is the
# capture's own backing scale. The band is the bar's 4..24 pt, away from the
# traffic lights and the controls row: hidden_edges is the picture's sharp
# detail where a hidden bar lets it show; revealed_edges is the same band once
# the acrylic is up (a material, not the picture copied); bar_edge is how far
# the bar moved the band; title_edges is the ink the centred name drew (plain
# left band / centre). A mirror would keep the picture's edges in the band.
fullscreen_pair_pixels() {
    python3 - "$@" <<'PY'
import subprocess, sys
hidden, revealed, wpt, hpt = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
def load(path):
    size = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height",
                           "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip().split(",")
    w, h = int(size[0]), int(size[1])
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True).stdout
    return w, h, raw
def pixel(raw, w, x, y):
    i = (y * w + x) * 3
    return raw[i:i+3]
def banddiff(a, b, wa, wb, y0, y1, x0, x1):
    total = count = 0
    for y in range(y0, y1, 2):
        for x in range(x0, x1, 4):
            pa, pb = pixel(a, wa, x, y), pixel(b, wb, x, y)
            total += sum(abs(pa[c] - pb[c]) for c in range(3))
            count += 3
    return total / max(count, 1)
def edges(raw, w, y0, y1, x0, x1):
    n = 0
    for y in range(y0, y1, 2):
        for x in range(x0, x1, 2):
            left, right = pixel(raw, w, x - 1, y), pixel(raw, w, x + 1, y)
            if sum(abs(left[c] - right[c]) for c in range(3)) > 60:
                n += 1
    return n
wh, hh, hr = load(hidden)
wr, rh, rr = load(revealed)
scale = wh / wpt
bx0 = int(100 * scale)
bx1 = min(int((wpt - 320) * scale), wh - 4)
by0 = int(4 * scale)
by1 = int(24 * scale)
# The title's own ink must not count as material: the bar comparison is the
# plain band on either side of the centred name.
gx0 = max(2, int(wh / 2 - 120 * scale))
gx1 = min(wh - 2, int(wh / 2 + 120 * scale))
cx0 = max(2, int(wh / 2 - 90 * scale))
cx1 = min(wh - 2, int(wh / 2 + 90 * scale))
lx0 = int(120 * scale)
lx1 = min(int(320 * scale), cx0 - int(10 * scale))
ty0 = int(6 * scale)
ty1 = int(22 * scale)
hidden_edges = edges(hr, wh, by0, by1, bx0, gx0) + edges(hr, wh, by0, by1, gx1, bx1)
revealed_edges = edges(rr, wr, by0, by1, bx0, gx0) + edges(rr, wr, by0, by1, gx1, bx1)
bar_edge = (banddiff(hr, rr, wh, wr, by0, by1, bx0, gx0)
            + banddiff(hr, rr, wh, wr, by0, by1, gx1, bx1)) / 2
left_edges = edges(rr, wr, ty0, ty1, lx0, lx1)
center_edges = edges(rr, wr, ty0, ty1, cx0, cx1)
print("hidden_edges=%d revealed_edges=%d bar_edge=%d title_edges=%d/%d"
      % (hidden_edges, revealed_edges, round(bar_edge), left_edges, center_edges))
PY
}

# --- Styles: the full-screen bar, app by style and appearance -----------------
#
# The reviewer's full-screen proof: both styles × light/dark, the bar hidden at
# entry (no bar pixels on the 28 pt line), then revealed by a rest at the top
# edge (an acrylic band, no copied picture, the centred name with ink), then
# hidden again and the windowed frame restored. The Phone Mirror never goes
# full screen (WIN-72), so its cells only assert that it cannot.
check_styles_fullscreen() {
    local appearance style key width height win full hidden revealed pixels
    local shots="$WORK-shots/fullscreen"
    mkdir -p "$shots"
    if [ "$VISIBLE" != "1" ]; then
        skip_visible "STYLES-FULLSCREEN full screen (a real Space and pointer)"
        return 0
    fi
    for appearance in light dark; do
        for style in immersive framed; do
            if [ "$style" = "framed" ]; then key=mat; width=910; height=643
            else key=immersive; width=900; height=628; fi
            clean
            FAKE_ARGS="--image-frame $MACOS/scripts/fixtures/bar/busy-photo.png" start_fake || return 1
            defaults write "$DEFAULTS_SUITE" "chrome.style.com.android.settings" -string "$key"
            rm -f "$WORK/fs-hidden" "$WORK/fs-revealed" "$WORK/fs-left" "$WORK/fs-exit" "$WORK/fs-done"
            printf '%s\n' "wait 1" "fullscreen" "wait 6" \
                "waitfile $WORK/fs-hidden 90" "waitfile $WORK/fs-revealed 90" \
                "waitfile $WORK/fs-left 90" "fullscreen" "wait 8" "waitfile $WORK/fs-exit 90" \
                "waitfile $WORK/fs-done 90" "wait 10" > "$WORK/fs.txt"
            launch --connect "127.0.0.1:$PORT" --appearance "$appearance" \
                --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
                --debug-input-script "$WORK/fs.txt" --quit-after 80
            wait_until 25 events_have '"ev":"video","stream":1,' \
                || { bad "STYLES-FULLSCREEN $appearance/$style no video"; stop_app; continue; }
            # The previous cell may have left the pointer on the top line;
            # take it away before the Space changes, or the bar is already
            # revealing when the hidden shot is due.
            cg_input moveat --x 200 --y 400
            if wait_until 20 chrome_all fullscreen=yes fullbar=hidden fullbar_visible=0; then
                ok "[WIN-8] STYLES-FULLSCREEN $appearance/$style full screen starts hidden ($(chrome_state))"
            else
                bad "[WIN-8] STYLES-FULLSCREEN $appearance/$style never entered full screen: $(chrome_state)"
                stop_app
                continue
            fi
            # The full screen can live in the system's full-screen window:
            # find the window whose frame the state now reports, never the
            # Deck's (it can be large too), and read its scale from that size.
            local fw fh
            fw="$(chrome_state | sed -n 's/.*geom=win:[0-9-]*,[0-9-]*,\([0-9]*\)x[0-9]*.*/\1/p')"
            fh="$(chrome_state | sed -n 's/.*geom=win:[0-9-]*,[0-9-]*,[0-9]*x\([0-9]*\).*/\1/p')"
            if [ -z "$fw" ] || [ -z "$fh" ]; then
                bad "STYLES-FULLSCREEN $appearance/$style the state has no window frame: $(chrome_state)"
                stop_app
                continue
            fi
            full="$(await_window "\$4 == $fw && \$5 == $fh")" \
                || { bad "STYLES-FULLSCREEN $appearance/$style no $fw x $fh full-screen window"; stop_app; continue; }
            if ! wait_until 15 chrome_frame_live; then
                bad "STYLES-FULLSCREEN $appearance/$style is not live for the hidden shot: $(chrome_state)"
                stop_app
                continue
            fi
            sleep 0.4
            hidden="$shots/$style-app-busy-photo-$appearance-full-hidden.png"
            shot_window "$full" "$hidden" \
                && ok "STYLES-FULLSCREEN $appearance/$style hidden shot" \
                || bad "STYLES-FULLSCREEN $appearance/$style no hidden shot"
            touch "$WORK/fs-hidden"
            # Inside the 8 pt edge band; below the system menu bar's strip.
            cg_input moveat --x 200 --y 6
            if wait_until 10 chrome_all fullbar=shown bar_title=1; then
                ok "[WIN-8] STYLES-FULLSCREEN $appearance/$style the top-edge rest reveals the bar with its name ($(chrome_state))"
            else
                bad "[WIN-8] STYLES-FULLSCREEN $appearance/$style the top edge revealed nothing: $(chrome_state)"
                touch "$WORK/fs-revealed" "$WORK/fs-left" "$WORK/fs-exit" "$WORK/fs-done"
                stop_app
                continue
            fi
            sleep 0.3
            if ! wait_until 8 chrome_frame_live; then
                bad "STYLES-FULLSCREEN $appearance/$style is not live for the revealed shot: $(chrome_state)"
            fi
            revealed="$shots/$style-app-busy-photo-$appearance-full-revealed.png"
            shot_window "$full" "$revealed" \
                && ok "STYLES-FULLSCREEN $appearance/$style revealed shot" \
                || bad "STYLES-FULLSCREEN $appearance/$style no revealed shot"
            touch "$WORK/fs-revealed"
            if pixels="$(fullscreen_pair_pixels "$hidden" "$revealed" "$fw" "$fh")"; then
                say "STYLES-FULLSCREEN $appearance/$style pixels: $pixels"
                local hde rde edge left center
                hde="$(printf '%s\n' "$pixels" | sed -n 's/.*hidden_edges=\([0-9]*\).*/\1/p')"
                rde="$(printf '%s\n' "$pixels" | sed -n 's/.*revealed_edges=\([0-9]*\).*/\1/p')"
                edge="$(printf '%s\n' "$pixels" | sed -n 's/.*bar_edge=\([0-9]*\).*/\1/p')"
                left="$(printf '%s\n' "$pixels" | sed -n 's/.*title_edges=\([0-9]*\)\/\([0-9]*\).*/\1/p')"
                center="$(printf '%s\n' "$pixels" | sed -n 's/.*title_edges=\([0-9]*\)\/\([0-9]*\).*/\2/p')"
                [ "${hde:-0}" -ge 8 ] \
                    && ok "[WIN-8] STYLES-FULLSCREEN $appearance/$style hidden: the top band is the picture, not the bar (edges $hde)" \
                    || bad "[WIN-8] STYLES-FULLSCREEN $appearance/$style hidden: no picture detail under the hidden bar (edges $hde)"
                [ "${edge:-0}" -ge 6 ] \
                    && ok "[WIN-8] STYLES-FULLSCREEN $appearance/$style the bar changed the band (edge $edge)" \
                    || bad "[WIN-8] STYLES-FULLSCREEN $appearance/$style the bar did not appear in pixels (edge $edge)"
                [ "${rde:-999}" -lt "${hde:-0}" ] \
                    && ok "[WIN-8] STYLES-FULLSCREEN $appearance/$style the bar is acrylic, not a copy of the picture ($rde < $hde)" \
                    || bad "[WIN-8] STYLES-FULLSCREEN $appearance/$style the bar keeps the picture's edges ($rde vs $hde)"
                [ "${center:-0}" -ge 10 ] && [ "${center:-0}" -ge $(( ${left:-0} + 6 )) ] \
                    && ok "[WIN-8] STYLES-FULLSCREEN $appearance/$style the title has ink edges (plain $left / centre $center)" \
                    || bad "[WIN-8] STYLES-FULLSCREEN $appearance/$style no readable title ink (plain $left / centre $center)"
            else
                bad "STYLES-FULLSCREEN $appearance/$style could not read the pixels"
            fi
            cg_input moveat --x 200 --y 400
            if wait_until 8 chrome_has "fullbar=hidden"; then
                ok "[WIN-8] STYLES-FULLSCREEN $appearance/$style leaving the bar hides it again"
            else
                bad "[WIN-8] STYLES-FULLSCREEN $appearance/$style the bar stayed: $(chrome_state)"
            fi
            touch "$WORK/fs-left"
            win="$(await_window "\$4 == $width && \$5 == $height")" \
                && ok "[WIN-14] STYLES-FULLSCREEN $appearance/$style leaving full screen restores $width x $height" \
                || bad "[WIN-14] STYLES-FULLSCREEN $appearance/$style exit did not restore $width x $height"
            touch "$WORK/fs-exit"
            touch "$WORK/fs-done"
            stop_app
        done
        # The Phone Mirror cannot go full screen in either style (WIN-72).
        for style in immersive framed; do
            if [ "$style" = "framed" ]; then key=mat; else key=immersive; fi
            clean
            FAKE_ARGS="--image-frame $MACOS/scripts/fixtures/bar/busy-photo.png" start_fake || return 1
            defaults write "$DEFAULTS_SUITE" "chrome.style.phone" -string "$key"
            launch --connect "127.0.0.1:$PORT" --appearance "$appearance" --open-phone \
                --debug-chrome-state "$WORK/chrome.txt" --quit-after 40
            wait_until 20 events_have '"ev":"video"' || bad "STYLES-FULLSCREEN $appearance/$style mirror no video"
            wait_until 12 chrome_all can_fullscreen=0 "style=$style" \
                && ok "[WIN-72] STYLES-FULLSCREEN $appearance/$style the Phone Mirror cannot go full screen" \
                || bad "[WIN-72] STYLES-FULLSCREEN $appearance/$style the Phone Mirror offered full screen: $(chrome_state)"
            stop_app
        done
    done
    mkdir -p "$WORK/shots/fullscreen"
    cp -R "$shots/." "$WORK/shots/fullscreen/" 2>/dev/null || true
    say "shots: $shots"
}

# --- Zoom: a stream window's double-click resize ----------------------------

# check_zoom — double-clicking a live stream window's title bar must resize it
# as smoothly as a live drag does, and must not re-render the phone per
# animation step. `--debug-stream-zoom` zooms the window through NSWindow.zoom
# (the title bar's own path), unzooms, then makes the same size change with a
# scripted live drag; the fake phone's log is the authority for the resize
# requests each phase sent and their sizes.
check_zoom() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open com.android.settings --float-windows \
        --debug-stream-zoom "$WORK/stream-zoom.json" --quit-after 60
    wait_until 25 window_rx window.open "com.android.settings" \
        || bad "ZOOM the app window never opened"
    if wait_until 60 [ -s "$WORK/stream-zoom.json" ]; then
        local limit report
        limit="$(nfr_limit stream_zoom_frame_p95_ms)"
        if report="$(python3 "$MACOS/scripts/stream-zoom.py" \
                "$WORK/stream-zoom.json" "$WORK/events.jsonl" "$limit")"; then
            ok "[WIN-41] ZOOM the zoom is handled like a live resize, once at the end ($report)"
        else
            bad "[WIN-41] ZOOM the zoom is not a live resize ($report)"
        fi
    else
        bad "ZOOM no measurement (--debug-stream-zoom)"
    fi
    stop_app
    stop_fakephone
}

# check_stats — the per-window stats line and the phone's counters (ISS-40).
# The fake phone reports 60 fps, 7 dropped deltas, a QP of 24 and one forced
# 300 ms gap; the Mac's 5 s line must show them. A covered window is paused and
# must log nothing until it is visible again.
check_stats() {
    clean
    FAKE_ARGS="--stats-drop 7 --stats-qp 24 --stats-retrans 2 --stats-no-frame --frame-gap-after 8 --frame-gap-ms 300 --no-backlog-restart" start_fake || return 1
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --debug-control "$WORK-control" --quit-after 150
    if ! wait_until 25 window_rx window.open "com.android.settings"; then
        bad "STATS the app window never opened"
        stop_app; stop_fakephone
        return 1
    fi
    stats_log() {
        /usr/bin/log show --last 5m --info --style syslog \
            --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
            | grep -F " stats stream="
    }
    stats_lines_file() {
        stats_log > "$WORK/stats.txt"
        grep -c . "$WORK/stats.txt" 2>/dev/null || true
    }
    stats_ready() { [ "$(stats_lines_file)" -ge 1 ]; }
    if ! wait_until 20 stats_ready; then
        bad "STATS no stats line within 20 s"
        stop_app; stop_fakephone
        return 1
    fi
    ok "STATS the first stats line appeared"
    # The fake encoder and the first frames take a few seconds: wait past the
    # 5 s warm-up lines, then judge the steady ones.
    sleep 20
    stats_lines_file >/dev/null
    python3 - "$WORK/stats.txt" > "$WORK/stats-metrics.txt" <<'PY'
import statistics, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if " stats stream=" not in line:
        continue
    fields = {}
    for word in line.split():
        if "=" in word:
            key, value = word.split("=", 1)
            fields[key] = value
    if fields.get("stream") == "1":
        rows.append(fields)
def number(key, row):
    try:
        return float(row[key])
    except (KeyError, ValueError):
        return None
steady = [r for r in rows if (number("rx_fps", r) or 0) > 0]
recent = steady[-3:] if steady else rows
rx = [v for v in (number("rx_fps", r) for r in recent) if v is not None]
shown = [v for v in (number("shown_fps", r) for r in recent) if v is not None]
e2e = [v for v in (number("e2e_p50", r) for r in recent) if v is not None]
drop = sum([int(number("phone_drop", r) or 0) for r in rows] + [0])
episodes = sum([int(number("drop_ep", r) or 0) for r in rows] + [0])
# The forced 300 ms gap is one freeze between 250 and 600 ms on some line.
# Startup can add its own, longer gaps on the first lines: judge every line
# on its own instead of summing them.
forced = [r for r in rows
          if int(number("freeze_n", r) or 0) == 1
          and 250 <= (number("freeze_ms", r) or 0) <= 600]
freeze = 1 if forced else 0
qp = [v for v in (number("qp_p95", r) for r in recent) if v is not None]
# `phone_n` counts the phone's 2 s messages folded into each 5 s line: the
# fake phone sends one every 2 s, so each steady line covers at least two.
phone = [int(number("phone_n", r) or 0) for r in recent]
# The fake phone's pts follows wall clock across its forced gap, so the gap is
# a freeze and not a hitch. Startup can still hand over a burst late; the
# steady lines are the ones the line-level contract is about.
hitch = max([int(number("hitch_n", r) or 0) for r in recent] + [0])
# X0: the socket's own reading is a number on every steady line (the first
# line of a window has no earlier reading for the out-of-order delta).
tcp_ok = 1 if recent and all(
    number(key, r) is not None
    for r in recent for key in ("tcp_srtt", "tcp_rttvar", "tcp_ooo_kb")) else 0
# The fake phone sends two resends and one timeout per 2 s message, so a 5 s
# line sums exactly 2× and 1× its phone_n.
resend_ok = 1 if recent and all(
    number("ph_retrans", r) == 2 * (number("phone_n", r) or 0)
    and number("ph_rto", r) == (number("phone_n", r) or 0)
    and number("ph_lost", r) == 0
    for r in recent) else 0
print(len(rows),
      round(statistics.median(rx), 1) if rx else "-",
      round(statistics.median(shown), 1) if shown else "-",
      round(statistics.median(e2e), 1) if e2e else "-",
      drop, episodes, freeze,
      round(statistics.median(qp), 1) if qp else "-",
      hitch,
      ",".join(str(value) for value in phone) if phone else "-",
      tcp_ok, resend_ok)
PY
    local lines rx shown e2e drop episodes freeze qp hitch phone_n tcp_ok resend_ok
    read -r lines rx shown e2e drop episodes freeze qp hitch phone_n tcp_ok resend_ok < "$WORK/stats-metrics.txt"
    # An empty or short metrics line must fail an assertion below, not stop the
    # check with `unbound variable`.
    lines="${lines:-0}"
    rx="${rx:--}"
    shown="${shown:--}"
    e2e="${e2e:--}"
    drop="${drop:-0}"
    episodes="${episodes:-0}"
    freeze="${freeze:-0}"
    qp="${qp:--}"
    hitch="${hitch:-0}"
    phone_n="${phone_n:--}"
    tcp_ok="${tcp_ok:-0}"
    resend_ok="${resend_ok:-0}"
    say "STATS lines=$lines rx_fps=$rx shown_fps=$shown e2e_p50=$e2e phone_drop=$drop drop_ep=$episodes freeze_n=$freeze qp_p95=$qp hitch_n=$hitch phone_n=$phone_n tcp_ok=$tcp_ok resend_ok=$resend_ok"
    if [ "$phone_n" != "-" ] && printf '%s\n' "$phone_n" | tr ',' '\n' | awk '$1 < 2 { exit 1 }'; then
        ok "STATS every steady line folded in at least two phone messages (phone_n=$phone_n)"
    else
        bad "STATS a steady line carried fewer than two phone messages (phone_n=$phone_n)"
    fi
    [ "${lines:-0}" -ge 3 ] \
        && ok "STATS $lines lines in the 20 s watch" \
        || bad "STATS only ${lines:-0} lines in the 20 s watch"
    # The fake phone's encoder is 60 fps; +-25% is 45..75, wide enough for a
    # quiet run's scheduling and narrow enough to catch a stalled picture.
    if [ "$rx" != "-" ] && awk -v v="$rx" 'BEGIN { exit !(v >= 45 && v <= 75) }'; then
        ok "STATS rx_fps=$rx is within +-25% of the fake phone's 60 fps (45..75)"
    else
        bad "STATS rx_fps=$rx is outside 45..75"
    fi
    if [ "$e2e" != "-" ] && awk -v v="$e2e" 'BEGIN { exit !(v >= 0 && v <= 250) }'; then
        ok "STATS e2e_p50=${e2e} ms is plausible for the fake phone's own pts clock"
    else
        bad "STATS e2e_p50=$e2e ms is missing or implausible"
    fi
    [ "$drop" = "21" ] && [ "$episodes" = "3" ] \
        && ok "STATS phone_drop sums the 7 deltas in each of the fake phone's three messages (21) and drop_ep their three episodes" \
        || bad "STATS phone_drop=$drop drop_ep=$episodes, expected 21 and 3"
    [ "$freeze" = "1" ] \
        && ok "STATS one line counts the forced 300 ms gap as a single 250..600 ms freeze" \
        || bad "STATS no line reported freeze_n=1 with 250..600 ms (startup gaps excluded)"
    [ "$qp" = "24.0" ] \
        && ok "STATS the fake codec's QP 24 reaches qp_p95" \
        || bad "STATS qp_p95=$qp, expected 24.0"
    [ "$hitch" = "0" ] \
        && ok "STATS hitch_n=0 on the fake phone's steady encoder (its forced gap is a freeze, not a hitch)" \
        || bad "STATS hitch_n=$hitch, expected 0 (the fake phone's pts follows wall clock)"
    [ "$tcp_ok" = "1" ] \
        && ok "STATS every steady line carries the socket's tcp_srtt, tcp_rttvar and tcp_ooo_kb" \
        || bad "STATS a steady line is missing a numeric tcp_srtt/tcp_rttvar/tcp_ooo_kb"
    [ "$resend_ok" = "1" ] \
        && ok "STATS ph_retrans and ph_rto sum the fake phone's per-message resends (2 and 1) and ph_lost stays 0" \
        || bad "STATS ph_retrans/ph_rto/ph_lost do not sum the phone's messages"

    # The summary script must read the same saved lines (the reviewer uses it
    # on the real phone).
    if python3 "$MACOS/scripts/stats-summary.py" --file "$WORK/stats.txt" > "$WORK/stats-summary.txt" \
            && grep -q "stream 1:" "$WORK/stats-summary.txt" \
            && grep -q "rx_fps" "$WORK/stats-summary.txt"; then
        ok "STATS stats-summary.py reads the lines"
    else
        bad "STATS stats-summary.py did not summarise the lines"
    fi

    # A covered window is paused: no line while covered, lines again after.
    local before after resumed
    stats_lines_file >/dev/null
    before="$(grep -c . "$WORK/stats.txt" 2>/dev/null || true)"
    # The app's own minimize path (windowDidMiniaturize -> setPaused), the
    # same one a person's click takes; occlude only changes the watchdog's
    # window state and does not pause the stream.
    control open --minimize-stream 1:3 --deminimize-stream 1:13 \
        || bad "STATS control open (minimize): $CONTROL_REPLY"
    sleep 2
    stats_lines_file >/dev/null
    before="$(grep -c . "$WORK/stats.txt" 2>/dev/null || true)"
    sleep 6
    stats_lines_file >/dev/null
    after="$(grep -c . "$WORK/stats.txt" 2>/dev/null || true)"
    [ "$after" = "$before" ] \
        && ok "STATS a minimized window logs nothing ($before lines before and after 6 s)" \
        || bad "STATS a minimized window logged $((after - before)) more lines"
    sleep 8
    stats_lines_file >/dev/null
    resumed="$(grep -c . "$WORK/stats.txt" 2>/dev/null || true)"
    [ "$resumed" -gt "$after" ] \
        && ok "STATS lines resume after the window is visible again" \
        || bad "STATS no line after the window was shown again"

    # Every field of the documented line is present.
    local line field missing=""
    line="$(tail -1 "$WORK/stats.txt")"
    case "$line" in *"stats stream="*) ;; *) missing=" stats" ;; esac
    for field in stream size view place rx_fps shown_fps int_p95 int_p99 \
                 freeze_n freeze_ms hitch_n hitch_ms late_p99 mac_drop \
                 mac_drop_flush mac_drop_not_ready mac_drop_before_config \
                 mac_drop_paced mac_drop_awaiting_key chain_fed \
                 phone_drop \
                 drop_ep drop_ms skip kf kf_req key_not_idr ph_key_not_idr \
                 kbps target_kbps qp_p50 qp_p95 enc_p50 enc_p95 queue_p95 \
                 e2e_p50 e2e_p95 max_gap_ms tcp_srtt tcp_rttvar tcp_ooo_kb \
                 ph_retrans ph_rto ph_lost codec qp_avg; do
        case "$line" in
            *"$field="*) ;;
            *) missing="$missing $field" ;;
        esac
    done
    [ -z "$missing" ] \
        && ok "STATS the line carries every documented field" \
        || bad "STATS the line is missing:$missing"
    case "$line" in
        *"codec=avc"*) ok "STATS the line names the default codec=avc" ;;
        *) bad "STATS the line has no codec=avc" ;;
    esac
    case "$line" in
        *"qp_avg=24.0"*) ok "STATS the line carries the phone's qp_avg=24.0" ;;
        *) bad "STATS the line has no qp_avg=24.0" ;;
    esac

    # WIN-66 (ISS-10): the phone's no-frame episode reaches the Mac's log as
    # its record and then its end, once each (the fake phone repeats the open
    # episode in a second message, so a duplicate line would show here).
    no_frame_log() {
        /usr/bin/log show --last 5m --info --style syslog \
            --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
            | grep -F " no frame "
    }
    local no_frame_lines no_frame_open no_frame_ended
    no_frame_lines="$(no_frame_log)"
    no_frame_open="$(printf '%s\n' "$no_frame_lines" | grep -cF " no frame for 1.5s phase=draining " || true)"
    no_frame_ended="$(printf '%s\n' "$no_frame_lines" | grep -cF " no frame ended outcome=late after 2600ms" || true)"
    if [ "$no_frame_open" = "1" ] \
            && printf '%s\n' "$no_frame_lines" | grep -qF "display=virtual task=launched on=on keyguard=showing doze=idle screen=on nudge=0 out=0 kf=0 bytes=0"; then
        ok "[WIN-66] STATS the Mac logs the phone's no-frame record once with its closed tokens"
    else
        bad "[WIN-66] STATS the no-frame record line is missing or repeated ($no_frame_open)"
    fi
    [ "$no_frame_ended" = "1" ] \
        && ok "[WIN-66] STATS the Mac logs the episode's late end once" \
        || bad "[WIN-66] STATS the ended line is missing or repeated ($no_frame_ended)"

    # The closing totals line (WIN-55/56): complete over the window's whole
    # life, including the minimize stop above (covered_ms). The bench reads
    # these, so the check proves every field and a lifetime counter.
    stats_total_log() {
        /usr/bin/log show --last 5m --info --style syslog \
            --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
            | grep -F " stats total stream=1 "
    }
    stats_total_ready() { [ -n "$(stats_total_log)" ]; }
    control open --close-stream 1:0 || bad "STATS the window did not close: $CONTROL_REPLY"
    if wait_until 5 stats_total_ready; then
        ok "STATS the closing totals line appeared"
    else
        bad "STATS no stats total line after the window closed"
    fi
    local total_line total_missing=""
    total_line="$(stats_total_log | tail -1)"
    for field in secs rx_frames shown_frames hitch_n hitch_ms late_p99 \
                 phone_n phone_frames kf kf_req key_not_idr ph_key_not_idr \
                 drop_ep drop_ms susp_n susp_ms \
                 bytes rx_kbps e2e_p50 e2e_p95 covered_ms max_gap_ms tcp_ooo_kb tcp_srtt_max \
                 ph_retrans ph_rto ph_lost codec qp_avg; do
        case "$total_line" in
            *"$field="*) ;;
            *) total_missing="$total_missing $field" ;;
        esac
    done
    [ -z "$total_missing" ] \
        && ok "STATS the totals line carries every documented field" \
        || bad "STATS the totals line is missing:$total_missing"
    local total_codec total_qp total_rx
    total_field() {
        printf '%s\n' "$total_line" | tr ' ' '\n' | grep -F "$1=" | head -1 | cut -d= -f2
    }
    total_codec="$(total_field codec)"
    total_qp="$(total_field qp_avg)"
    total_rx="$(total_field rx_kbps)"
    [ "$total_codec" = "avc" ] \
        && ok "STATS totals codec=avc on the default H.264 arm" \
        || bad "STATS totals codec=${total_codec:-missing}, expected avc"
    [ "$total_qp" = "24.0" ] \
        && ok "STATS totals qp_avg=24.0 counts the fake phone's QP" \
        || bad "STATS totals qp_avg=${total_qp:-missing}, expected 24.0"
    if awk -v v="$total_rx" 'BEGIN { exit !(v > 0) }'; then
        ok "STATS totals rx_kbps=$total_rx is the Mac's received rate"
    else
        bad "STATS totals rx_kbps=${total_rx:-missing} is not positive"
    fi
    local total_drop_ep total_covered total_secs total_rx total_gap total_keys
    total_gap="$(total_field max_gap_ms)"
    total_keys="$(total_field key_not_idr)"
    total_drop_ep="$(total_field drop_ep)"
    total_covered="$(total_field covered_ms)"
    total_secs="$(total_field secs)"
    total_rx="$(total_field rx_frames)"
    [ "$total_drop_ep" = "3" ] \
        && ok "STATS totals drop_ep=3 folds the whole life's three episodes into one line" \
        || bad "STATS totals drop_ep=$total_drop_ep, expected 3"
    if [ -n "$total_covered" ] && awk -v v="$total_covered" 'BEGIN { exit !(v > 0) }'; then
        ok "STATS totals covered_ms=$total_covered counts the minimized pause"
    else
        bad "STATS totals covered_ms=${total_covered:-missing} does not count the minimized pause"
    fi
    if awk -v s="$total_secs" -v r="$total_rx" 'BEGIN { exit !(s > 0 && r > 0) }'; then
        ok "STATS totals secs=$total_secs rx_frames=$total_rx cover a live window"
    else
        bad "STATS totals secs=${total_secs:-missing} rx_frames=${total_rx:-missing} are not positive"
    fi
    if awk -v v="$total_gap" 'BEGIN { exit !(v > 0 && v <= 2500) }'; then
        ok "STATS totals max_gap_ms=$total_gap is a measured gap under the frozen mark"
    else
        bad "STATS totals max_gap_ms=${total_gap:-missing} is missing or over 2500"
    fi
    # The fake phone flags a key frame only for a real IDR (proto.is_idr), so
    # a non-zero count here would mean the Mac's check reads the wrong units.
    [ "$total_keys" = "0" ] \
        && ok "STATS totals key_not_idr=0 on the fake phone's IDR key frames" \
        || bad "STATS totals key_not_idr=$total_keys, expected 0"
    stop_app
    stop_fakephone
}

# --- C18: chain (WIN-61) ----------------------------------------------------

# check_chain — the reference chain across config changes and resize storms.
# The fake phone re-sends its VIDEO_CONFIG every 4 s WITHOUT restarting the
# encoder (what the phone's resume does): the deltas that follow reference the
# frames the Mac just flushed, so a Mac that feeds them shows garbage until the
# next IDR. On top of that the phone mirror is resized every 2-4 s for 60 s.
# Pass: every break is restored by a keyframe within 600 ms, no delta reaches
# the layer while the chain is broken (`chain_fed=0`), and no display-layer
# failure. The reasons are printed for the report.
check_chain() {
    clean
    # Phase A: no storm, just the fake encoder's own 10 s GOP. The reviewer's
    # real-phone session showed one mac_drop in every 5 s line with kf=1; the
    # split names the path that discards at a keyframe.
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows
    if ! wait_until 30 events_have '"ev":"video","stream":1,"config":true'; then
        bad "[WIN-61] CHAIN the phone mirror never showed its first frame"
        stop_app; stop_fakephone; return 1
    fi
    sleep 35
    stop_app
    stop_fakephone
    /usr/bin/log show --last 4m --info --style syslog \
        --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
        > "$WORK/chain-baseline.txt"
    python3 - "$WORK/chain-baseline.txt" > "$WORK/chain-baseline-summary.txt" <<'PY'
import sys
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    if " stats stream=" not in line:
        continue
    fields = {}
    for word in line.split():
        if "=" in word:
            key, value = word.split("=", 1)
            fields[key] = value
    try:
        kf = int(fields.get("kf", "0"))
    except ValueError:
        continue
    if kf >= 1:
        keys = ("mac_drop", "mac_drop_flush", "mac_drop_not_ready",
                "mac_drop_before_config", "mac_drop_paced", "chain_fed")
        rows.append("kf=%d %s" % (kf, " ".join("%s=%s" % (k, fields.get(k, "-")) for k in keys)))
print(" | ".join(rows[-4:]) if rows else "none")
PY
    say "CHAIN baseline lines with kf>=1: $(cat "$WORK/chain-baseline-summary.txt")"

    # Phase B: the phone re-sends its config every 4 s without restarting the
    # encoder (what a resume does). Those configs are byte for byte the
    # applied one, so the Mac keeps its decoder and chain (WIN-63); the breaks
    # come from the resizes, every 2-4 s for 60 s, each a new size.
    clean
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    rm -f "$WORK/chrome.txt"
    FAKE_ARGS="--config-every 4" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --float-windows \
        --debug-chrome-state "$WORK/chrome.txt" --debug-control "$WORK-control"
    if ! wait_until 30 chrome_has "loading=0"; then
        bad "[WIN-61] CHAIN the phone mirror never showed its first frame (state: $(chrome_state))"
        stop_app; stop_fakephone; return 1
    fi
    # 60 s: a resize every 2-4 s through the window's own windowWillResize
    # path, while the phone's configs land every 4 s on their own.
    local deadline=$(( $(now_ms) + 60000 )) step=0 w h
    while [ "$(now_ms)" -lt "$deadline" ]; do
        w=$((480 + (step % 5) * 28))
        h=$((860 + (step % 4) * 40))
        control resize-step "$w" "$h" || bad "[WIN-61] CHAIN resize-step $w $h: $CONTROL_REPLY"
        step=$((step + 1))
        if [ $((step % 3)) -eq 0 ]; then sleep 4; else sleep 2; fi
    done
    # The last break may still be waiting for its keyframe; give it the same
    # 600 ms the rule gives the phone, then read the whole run's lines.
    sleep 1
    stop_app
    stop_fakephone
    /usr/bin/log show --last 6m --info --style syslog \
        --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
        > "$WORK/chain-log.txt"
    python3 - "$WORK/chain-log.txt" > "$WORK/chain-summary.txt" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
reasons = re.findall(r"chain broken reason=([a-z_]+)", text)
restored = [int(ms) for ms in re.findall(r"chain restored after (\d+)", text)]
stats = [line for line in text.splitlines() if " stats stream=" in line]
fed = []
for line in stats:
    match = re.search(r"chain_fed=(\d+)", line)
    if match:
        fed.append(int(match.group(1)))
failed = len(re.findall(r"display layer failed", text))
print(len(reasons), len(restored), max(restored or [0]), max(fed or [0]),
      min(fed or [0]), len(fed), failed,
      ",".join(sorted(set(reasons))) or "none")
PY
    read -r breaks restores longest fed_max fed_min stat_lines layer_failures reason_tokens \
        < "$WORK/chain-summary.txt"
    say "CHAIN breaks=$breaks restored=$restores longest_ms=$longest chain_fed_max=$fed_max lines=$stat_lines failures=$layer_failures reasons=$reason_tokens"
    [ "$breaks" -ge 10 ] \
        && ok "[WIN-61] CHAIN the storm broke the chain $breaks times (reasons: $reason_tokens)" \
        || bad "[WIN-61] CHAIN only $breaks chain breaks in 60 s of config and resize storms"
    [ "$restores" -ge 1 ] && [ "$longest" -le 600 ] \
        && ok "[WIN-61] CHAIN every restore (${restores} of them) came within ${longest} ms" \
        || bad "[WIN-61] CHAIN restore took ${longest} ms over ${restores} restores (limit 600)"
    [ "$fed_max" = "0" ] && [ "$stat_lines" -ge 3 ] \
        && ok "[WIN-61] CHAIN no delta reached the layer while awaiting a key (chain_fed=0 on $stat_lines lines)" \
        || bad "[WIN-61] CHAIN chain_fed reached $fed_max: deltas were fed after a break (${stat_lines} lines)"
    [ "$layer_failures" = "0" ] \
        && ok "[WIN-61] CHAIN no display layer failed" \
        || bad "[WIN-61] CHAIN $layer_failures display layer failures"
    case ",$reason_tokens," in
        *,config,*) ok "[WIN-61] CHAIN the reason tokens are closed ($reason_tokens)" ;;
        *) bad "[WIN-61] CHAIN no config break was logged (reasons: $reason_tokens)" ;;
    esac
}

# --- Phone nickname (docs/ROADMAP.md #1, #2) --------------------------------

# check_nickname — a nickname names the phone everywhere. It is set the way
# Settings stores it (a `phoneNicknames` map in the profile's defaults, written
# before launch) and through the real rename path (--set-nickname calls the
# same method the Rename dialog's button does). Assertions: the app window's
# title is "Settings (Nicky)" (the Dock/⌘-Tab identity), the Dock shim is
# "WhatsApp (Nicky).app", the phone window is titled with the nickname, and a
# check_netvideo — stream.net=video marks the dialled stream socket (N1). The
# session's strategy line carries the value getsockopt reads back, so the run
# proves the option landed instead of trusting the write.
check_netvideo() {
    clean
    defaults write "$DEFAULTS_SUITE" stream.net -string video
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 60
    net_strategy() {
        /usr/bin/log show --last 2m --info --style syslog \
            --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
            | grep -F "session mac strategy:"
    }
    video_line() { net_strategy | grep -F "net=video net_svc=3"; }
    if wait_until 20 video_line; then
        ok "N1 stream.net=video marks the stream socket (the read-back is 3)"
    else
        bad "N1 no 'session mac strategy: net=video net_svc=3' line; saw: $(net_strategy | tail -1)"
    fi
    stop_app
    stop_fakephone
    defaults delete "$DEFAULTS_SUITE" stream.net >/dev/null 2>&1
}


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
        && ok "[WIN-3] NICK the app window is titled \"Settings (Nicky)\"" \
        || bad "[WIN-3] NICK no \"Settings (Nicky)\" window: ($(window_titles | tr '\n' '|'))"
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
        && ok "[WIN-3] NICK the rename retitled the app window" \
        || bad "[WIN-3] NICK the rename did not retitle: ($(window_titles | tr '\n' '|'))"
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


# check_settings — the Settings window's sidebar (docs/specs/settings.md):
# the SET-WIN rules for the sidebar and the SET-DEV rules for a phone's page.
# The window reports what it renders (`settings-report`, a read of the real
# view), and the rows are moved by real key events through the app's own key
# dispatch. The stored selection is forgotten before a state that asserts the
# default, and kept for the persistence check.
check_settings() {
    clean
    local ctl="$WORK-control" dump="$WORK/settings.txt" script="$WORK/settings-input.txt"
    rm -rf "$ctl"; mkdir -p "$ctl"
    dump_has() { grep -qF -- "$1" "$dump" 2>/dev/null; }
    dump_line() { grep -qF -- "$1" "$dump" 2>/dev/null; }
    dump_rows() { grep -c '^row|' "$dump" 2>/dev/null || true; }
    dump_in_use() { awk -F'|' '$1=="row" && $6=="1"' "$dump" 2>/dev/null | wc -l | tr -d ' '; }
    report_value() { sed -n "s/^$1=//p" "$dump" | head -1; }
    forget_selection() { defaults delete "$DEFAULTS_SUITE" settings.selection >/dev/null 2>&1 || true; }
    state() {
        # STATE — a preview run with Settings open; the stored selection is
        # forgotten unless KEEP is set (the persistence check).
        [ -n "${APP_PID:-}" ] && stop_app
        rm -f "$dump"
        [ -n "${KEEP:-}" ] || forget_selection
        printf 'wait 2\nopensettings\nwait 2\n' > "$script"
        launch --preview "$1" --debug-control "$ctl" --debug-input-script "$script" --quit-after 120
        wait_until 25 windows_at_least 2 || { bad "SET Settings: the window never opened"; return 1; }
        sleep 1
        control settings-report "$dump" || { bad "SET report: $CONTROL_REPLY"; return 1; }
        wait_until 10 [ -s "$dump" ] || { bad "SET the window never wrote $dump"; return 1; }
    }
    # The report after a step, without relaunching.
    reread() { rm -f "$dump"; control settings-report "$dump" >/dev/null 2>&1; sleep 0.6; }
    window_title() {
        control settings-dump "$WORK/settings-geom.txt" >/dev/null 2>&1
        sed -n 's/^title=//p' "$WORK/settings-geom.txt" | head -1
    }
    # The Settings window's real frame (SettingsProbe): origin, size, and the
    # visible frame of its screen.
    geom() { control settings-dump "$WORK/settings-geom.txt" >/dev/null 2>&1; cat "$WORK/settings-geom.txt" 2>/dev/null; }
    geom_value() { geom | sed -n "s/^$1=//p" | head -1; }
    # centre_gap — |window centre − visible frame centre| per axis, in points.
    centre_gap() {
        geom | awk -F'[=,x]' '
            $1 == "origin" { x = $2; y = $3 }
            $1 == "window" { w = $2; h = $3 }
            $1 == "visible_frame" { vx = $2; vy = $3; vw = $4; vh = $5 }
            END {
                dx = (x + w / 2) - (vx + vw / 2); if (dx < 0) dx = -dx
                dy = (y + h / 2) - (vy + vh / 2); if (dy < 0) dy = -dy
                printf "%d %d\n", dx, dy
            }'
    }
    settings_open() { control settings-dump "$WORK/settings-geom.txt" >/dev/null 2>&1; }
    settings_closed() { ! settings_open; }

    # --- 0 phones: General opens, the Phones group is empty (SET-WIN-02) ----
    # SET-WIN-09 opens from a frame this profile has never placed.
    defaults delete "$DEFAULTS_SUITE" settings.windowOrigin >/dev/null 2>&1 || true
    state devices-zero || return 1
    [ "$(report_value phones)" = "0" ] && ok "SET [SET-WIN-02] no phones: the sidebar lists none" \
        || bad "SET [SET-WIN-02] phones=$(report_value phones), wanted 0"
    [ "$(report_value selection)" = "General" ] && [ "$(report_value page)" = "general" ] \
        && ok "SET [SET-WIN-02] with no phones the window opens on General" \
        || bad "SET [SET-WIN-02] selection=$(report_value selection) page=$(report_value page)"
    [ "$(window_title)" = "General" ] && ok "SET [SET-WIN-01] the window title is the open page's name (General)" \
        || bad "SET [SET-WIN-01] title='$(window_title)'"
    dump_line "empty=No phones yet." && ok "SET [SET-WIN-02] the Phones group says No phones yet." \
        || bad "SET [SET-WIN-02] no empty sentence: $(tr '\n' '|' < "$dump" 2>/dev/null)"

    # --- where the window opens, and where it comes back to (SET-WIN-09) ----
    gap="$(centre_gap)"
    gap_x="${gap%% *}"; gap_y="${gap##* }"
    [ "${gap_x:-99}" -le 2 ] && [ "${gap_y:-99}" -le 2 ] \
        && ok "SET [SET-WIN-09] a fresh profile opens the window centred on the screen's visible frame (gap $gap_x,$gap_y pt)" \
        || bad "SET [SET-WIN-09] the window opened at $(geom_value origin) on $(geom_value visible_frame), centre gap $gap_x,$gap_y pt"
    # Moved 200 pt left and 150 pt down through Accessibility (AX axes: top-left,
    # y down), the path a tiler takes. A real ⌘W closes the window; it reopens
    # through the menu item's own action (control settings-open), because a
    # quiet run's app has no key window to send ⌘, to.
    fresh="$(geom_value origin)"
    "$CGBIN" axmove --pid "$APP_PID" --dx -200 --dy 150 --title General || true
    sleep 1
    moved="$(geom_value origin)"
    [ -n "$moved" ] && [ "$moved" != "$fresh" ] \
        && ok "SET [SET-WIN-09] the window moved (AX) from $fresh to $moved" \
        || bad "SET [SET-WIN-09] the window did not move (origin='$moved')"
    control key "cmd+w" >/dev/null 2>&1
    wait_until 10 settings_closed || bad "SET [SET-WIN-09] ⌘W did not close the Settings window"
    control settings-open >/dev/null 2>&1
    wait_until 12 settings_open || { bad "SET [SET-WIN-09] Settings did not reopen: $CONTROL_REPLY"; return 1; }
    sleep 1
    [ "$(geom_value origin)" = "$moved" ] \
        && ok "SET [SET-WIN-09] closing and reopening (⌘,) brings the window back to $moved" \
        || bad "SET [SET-WIN-09] reopened at $(geom_value origin), wanted $moved"
    KEEP=1 state devices-zero || return 1
    sleep 1
    [ "$(geom_value origin)" = "$moved" ] \
        && ok "SET [SET-WIN-09] a relaunch opens the window where it was left ($moved)" \
        || bad "SET [SET-WIN-09] relaunched at $(geom_value origin), wanted $moved"

    # Add Phone… opens the Deck's one sheet and leaves the page where it was.
    control settings-add >/dev/null 2>&1
    sleep 1
    reread
    [ "$(report_value sheet)" = "addPhone" ] && ok "SET [SET-WIN-02] Add Phone… opens the add-phone sheet" \
        || bad "SET [SET-WIN-02] sheet=$(report_value sheet)"
    [ "$(report_value selection)" = "General" ] && ok "SET [SET-WIN-02] Add Phone… does not change the page" \
        || bad "SET [SET-WIN-02] Add Phone… moved the page to $(report_value selection)"

    # --- 1 phone: it opens, and the sidebar says so (SET-WIN-03) ------------
    state devices-one || return 1
    [ "$(report_value phones)" = "1" ] && [ "$(report_value selection)" = "Galaxy S25+" ] \
        && ok "SET [SET-WIN-03] one phone: the window opens on it" \
        || bad "SET [SET-WIN-03] phones=$(report_value phones) selection=$(report_value selection)"
    dump_has "row|Galaxy S25+|SM-S936B|Connected||1|0|0" \
        && ok "SET [SET-DEV-01] the row names the phone, its model and Connected, marked In Use" \
        || bad "SET [SET-DEV-01] row: $(grep '^row|' "$dump" 2>/dev/null | tr '\n' '|')"
    [ "$(dump_in_use)" = "1" ] && ok "SET [SET-DEV-02] exactly one phone carries the in-use mark" \
        || bad "SET [SET-DEV-02] $(dump_in_use) rows carry the in-use mark"
    [ "$(report_value share)" = "1" ] && ok "SET [SET-DEV-09] sharing reads on from the stored opt-in" \
        || bad "SET [SET-DEV-09] share=$(report_value share)"
    [ "$(report_value click)" = "Open on this Mac" ] && ok "SET [SET-DEV-10] the click target reads Open on this Mac" \
        || bad "SET [SET-DEV-10] click=$(report_value click)"
    [ "$(report_value mutedCount)" = "2" ] && ok "SET [SET-DEV-11] the muted row counts two apps" \
        || bad "SET [SET-DEV-11] mutedCount=$(report_value mutedCount)"
    # Add Phone… with a phone open: the sheet, the same page.
    control settings-add >/dev/null 2>&1
    sleep 1
    reread
    [ "$(report_value sheet)" = "addPhone" ] && [ "$(report_value selection)" = "Galaxy S25+" ] \
        && ok "SET [SET-WIN-02] Add Phone… opens the sheet and keeps the phone's page" \
        || bad "SET [SET-WIN-02] sheet=$(report_value sheet) selection=$(report_value selection)"

    # --- 3 phones: ↓/↑ move the page, and each page is that phone's ---------
    state devices-three || return 1
    [ "$(report_value selection)" = "Galaxy S25+" ] && [ "$(report_value header.inUse)" = "1" ] \
        && ok "SET [SET-WIN-03] three phones: the in-use phone opens" \
        || bad "SET [SET-WIN-03] selection=$(report_value selection) inUse=$(report_value header.inUse)"
    [ "$(report_value focus)" = "sidebar" ] \
        && ok "SET [SET-WIN-08] the sidebar has the keyboard when the window opens" \
        || bad "SET [SET-WIN-08] focus=$(report_value focus)"
    [ "$(report_value title)" = "Galaxy S25+" ] && [ "$(window_title)" = "Galaxy S25+" ] \
        && ok "SET [SET-WIN-06] the phone page's title is its name" \
        || bad "SET [SET-WIN-06] report title=$(report_value title) window='$(window_title)'"

    control key down >/dev/null 2>&1
    sleep 0.6
    reread
    [ "$(report_value selection)" = "Pixel 9" ] && [ "$(report_value title)" = "Pixel 9" ] \
        && ok "SET [SET-WIN-08] ↓ opens the next phone's page (Pixel 9)" \
        || bad "SET [SET-WIN-08] ↓ selection=$(report_value selection)"
    [ "$(report_value header.state)" = "Offline" ] \
        && [ "$(report_value header.lastSeen)" = "2 hours ago" ] \
        && [ "$(report_value header.inUse)" = "0" ] \
        && [ "$(report_value header.action)" = "Use This Phone" ] \
        && ok "SET [SET-WIN-06] an offline phone's header says Offline, when it was last seen, and Use This Phone" \
        || bad "SET [SET-WIN-06] header state=$(report_value header.state) lastSeen=$(report_value header.lastSeen) action=$(report_value header.action)"
    [ "$(window_title)" = "Pixel 9" ] && ok "SET [SET-WIN-06] the window title follows the page (Pixel 9)" \
        || bad "SET [SET-WIN-06] title='$(window_title)'"

    control key down >/dev/null 2>&1
    sleep 0.6
    reread
    [ "$(report_value selection)" = "Pixel 8" ] \
        && [ "$(report_value header.state)" = "Pair again" ] \
        && [ "$(report_value header.action)" = "Pair Again…" ] \
        && ok "SET [SET-WIN-06] a keyless phone's header offers Pair Again…, not Use" \
        || bad "SET [SET-WIN-06] selection=$(report_value selection) state=$(report_value header.state) action=$(report_value header.action)"
    [ "$(report_value share)" = "0" ] && [ "$(report_value mutedCount)" = "None" ] \
        && ok "SET [SET-DEV-16] the page's own stores still show (sharing off, no muted apps)" \
        || bad "SET [SET-DEV-16] share=$(report_value share) muted=$(report_value mutedCount)"

    control key up >/dev/null 2>&1
    sleep 0.6
    reread
    [ "$(report_value selection)" = "Pixel 9" ] && ok "SET [SET-WIN-08] ↑ returns to the previous row (Pixel 9)" \
        || bad "SET [SET-WIN-08] ↑ selection=$(report_value selection)"

    # --- plain section headings: the phone's name appears once (SET-WIN-06) -
    [ "$(report_value "title.phone")" = "Phone" ] \
        && [ "$(report_value "title.notifications")" = "Notifications" ] \
        && [ "$(report_value "title.applications")" = "Applications" ] \
        && [ "$(report_value "title.screen")" = "Screen" ] \
        && [ "$(report_value "title.forget")" = "Forget" ] \
        && ok "SET [SET-WIN-06] the section headings are plain: Phone, Notifications, Applications, Screen, Forget" \
        || bad "SET [SET-WIN-06] headings: $(grep '^title\.' "$dump" | tr '\n' '|')"
    if grep '^title\.' "$dump" | grep -qE 'Galaxy|Pixel| — '; then
        bad "SET [SET-WIN-06] a section heading carries the phone's name: $(grep '^title\.' "$dump" | tr '\n' '|')"
    else
        ok "SET [SET-WIN-06] no section heading carries the phone's name"
    fi

    # --- Tab leaves the sidebar for the detail (SET-WIN-08) -----------------
    control key tab >/dev/null 2>&1
    sleep 0.6
    reread
    if [ "$(report_value focus)" != "sidebar" ] && [ -n "$(report_value focus)" ]; then
        ok "SET [SET-WIN-08] Tab moves the keyboard into the detail ($(report_value focus))"
    else
        bad "SET [SET-WIN-08] Tab left focus at '$(report_value focus)'"
    fi

    # --- ⌘, reopens the last selection (SET-WIN-04) -------------------------
    # Pixel 9 was chosen above and the selection was stored; a relaunch with the
    # same staged phones keeps it. The pin is in place before this launch so
    # the Forget check below removes a pin the app actually holds.
    local support="$HOME/Library/Application Support/Contigua-$PROFILE"
    mkdir -p "$support"
    printf '[{"deviceId":"preview-2","phoneFingerprintHex":"%s","certPem":"fixture-pin"}]' \
        "$(printf 'a%.0s' $(seq 1 64))" > "$support/pins.json"
    KEEP=1 state devices-three || return 1
    [ "$(report_value selection)" = "Pixel 9" ] && ok "SET [SET-WIN-04] the window reopens the last selection (Pixel 9)" \
        || bad "SET [SET-WIN-04] selection=$(report_value selection)"

    # --- Forget the open phone: the next one takes the page (SET-WIN-05) ----
    # Pixel 9 is still the open page; its Forget button opens the confirmation.
    control settings-forget preview-2 >/dev/null 2>&1 || bad "SET settings-forget: $CONTROL_REPLY"
    sleep 0.6
    reread
    [ "$(report_value forgetDialog)" = "Pixel 9" ] \
        && ok "SET [SET-DEV-07] Forget asks first, naming the phone (Pixel 9)" \
        || bad "SET [SET-DEV-07] the confirmation names '$(report_value forgetDialog)'"
    control key esc >/dev/null 2>&1
    sleep 0.8
    reread
    [ -z "$(report_value forgetDialog)" ] && dump_has "row|Pixel 9|" \
        && ok "SET [SET-DEV-07] Esc cancels: the phone and its pairing stay" \
        || bad "SET [SET-DEV-07] Esc left the dialog ('$(report_value forgetDialog)') or removed the phone"
    grep -q 'preview-2' "$support/pins.json" 2>/dev/null \
        && ok "SET [SET-DEV-07] Esc left the pin store untouched" \
        || bad "SET [SET-DEV-07] Esc removed the pin"
    control settings-forget preview-2 >/dev/null 2>&1
    sleep 0.8
    reread
    [ "$(report_value forgetDialog)" = "Pixel 9" ] \
        && ok "SET [SET-DEV-07] the confirmation opens again for the same phone" \
        || bad "SET [SET-DEV-07] the second confirmation names '$(report_value forgetDialog)'"
    # The destructive button is not the default: Tab moves to it, Space presses
    # it, both as real key events through the dialog's own buttons.
    control key tab >/dev/null 2>&1
    control key space >/dev/null 2>&1
    sleep 1.5
    reread
    [ -z "$(report_value forgetDialog)" ] && ! dump_has "row|Pixel 9|" \
        && ok "SET [SET-DEV-07] confirming removes the phone from the list" \
        || bad "SET [SET-DEV-07] after confirm: dialog='$(report_value forgetDialog)' row=$(grep '^row|Pixel 9' "$dump" | head -1)"
    ! grep -q 'preview-2' "$support/pins.json" 2>/dev/null \
        && ok "SET [SET-DEV-07] confirming removes its pin" \
        || bad "SET [SET-DEV-07] the pin survived the confirmation"
    [ "$(report_value selection)" = "Galaxy S25+" ] \
        && ok "SET [SET-WIN-05] forgetting the open phone selects the phone in use" \
        || bad "SET [SET-WIN-05] after forgetting Pixel 9 the page is '$(report_value selection)'"
    rm -f "$support/pins.json"

    # --- muted apps: the list, its column, order and search (SET-DEV-11) ---
    state devices-muted || return 1
    [ "$(report_value mutedOpen)" = "1" ] && ok "SET [SET-DEV-11] the muted list opens" \
        || bad "SET [SET-DEV-11] the muted list stayed closed"
    dump_has "muted|System UI|com.android.systemui|1|1" \
        && ok "SET [SET-DEV-11] a system package reads System UI with its package underneath, muted and seen" \
        || bad "SET [SET-DEV-11] system row: $(grep '^muted|System UI' "$dump" | tr '\n' '|')"
    dump_has "muted|WhatsApp||1|1" && ok "SET [SET-DEV-11] a named app shows its name only, muted and seen" \
        || bad "SET [SET-DEV-11] WhatsApp row missing"
    grep -q '^muted|.*|1|1$' "$dump" && first_muted="$(grep -n '^muted|' "$dump" | head -1 | cut -d: -f1)" || first_muted=""
    first_plain="$(grep -n '^muted|.*|0$' "$dump" | head -1 | cut -d: -f1)"
    [ -n "$first_muted" ] && [ -n "$first_plain" ] && [ "$first_muted" -lt "$first_plain" ] \
        && ok "SET [SET-DEV-11] muted apps sort first" \
        || bad "SET [SET-DEV-11] mute order: first muted=$first_muted first unmuted=$first_plain"
    control key cmd+f >/dev/null 2>&1
    control key s >/dev/null 2>&1
    control key y >/dev/null 2>&1
    control key s >/dev/null 2>&1
    sleep 0.3
    reread
    [ "$(report_value query)" = "sys" ] && [ "$(report_value focused)" = "search" ] \
        && ok "SET [SET-DEV-20] ⌘F leaves the search field focused ($(report_value query))" \
        || bad "SET [SET-DEV-20] query=$(report_value query) focus=$(report_value focused)"
    control key cmd+f >/dev/null 2>&1
    sleep 0.3
    control key c >/dev/null 2>&1
    sleep 0.4
    reread
    [ "$(report_value query)" = "c" ] \
        && ok "SET [SET-DEV-20] ⌘F selects the typed text (typing replaces it)" \
        || bad "SET [SET-DEV-20] the text was not selected (query $(report_value query))"
    control key esc >/dev/null 2>&1
    sleep 0.4
    reread
    [ "$(report_value mutedOpen)" = "0" ] && ok "SET [SET-DEV-21] Esc closes the muted list" \
        || bad "SET [SET-DEV-21] Esc left the list open"

    # --- offline: settings stay editable, nothing claims they applied ------
    state devices-offline || return 1
    dump_has "row|Galaxy S25+|SM-S936B|Offline|" && ok "SET [SET-DEV-16] the in-use phone reads Offline with last seen" \
        || bad "SET [SET-DEV-16] offline row: $(grep '^row|' "$dump" | tr '\n' '|')"
    [ "$(report_value header.state)" = "Offline" ] && [ "$(report_value header.inUse)" = "1" ] \
        && ok "SET [SET-DEV-16] its page header still reads Offline and In Use" \
        || bad "SET [SET-DEV-16] header=$(report_value header.state) inUse=$(report_value header.inUse)"
    [ "$(report_value share)" = "0" ] && ok "SET [SET-DEV-16] its sharing switch still shows the stored off" \
        || bad "SET [SET-DEV-16] share=$(report_value share)"
    [ "$(report_value mutedCount)" = "None" ] && ok "SET [SET-DEV-12] no muted apps reads None" \
        || bad "SET [SET-DEV-12] mutedCount=$(report_value mutedCount)"

    # --- trust lost: row and header read Pair again (PAIR-34, SET-DEV-17/26) ---
    state devices-trust-lost || return 1
    [ "$(report_value selection)" = "Galaxy S25+" ] \
        && [ "$(report_value header.state)" = "Pair again" ] \
        && [ "$(report_value header.inUse)" = "1" ] \
        && ok "[SET-DEV-17] a trust-lost phone's page header reads Pair again and In Use" \
        || bad "[SET-DEV-17] selection=$(report_value selection) state=$(report_value header.state) inUse=$(report_value header.inUse)"
    [ "$(report_value header.action)" = "Pair Again…" ] \
        && ok "[PAIR-34] [SET-DEV-26] a trust-lost phone's header offers Pair Again… as its action" \
        || bad "[PAIR-34] [SET-DEV-26] header.action=$(report_value header.action)"
    dump_has "row|Galaxy S25+|SM-S936B|Pair again|" \
        && ok "[SET-DEV-17] its sidebar row reads Pair again" \
        || bad "[SET-DEV-17] row: $(grep '^row|' "$dump" | tr '\n' '|')"
    awk -F'|' '$1=="row" && $2=="Galaxy S25+" && $7=="1" && $8=="0" { found=1 } END { exit !found }' "$dump" \
        && ok "[SET-DEV-17] the row marks Pair again and does not pretend it can be used" \
        || bad "[SET-DEV-17] row flags: $(grep '^row|Galaxy S25+' "$dump" | head -1)"

    # --- missing listener access: the page says how to fix it --------------
    stop_app
    local device
    FAKE_ARGS="--notify-no-access" start_fake || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "SET no device id in the fakephone listening line"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    rm -f "$dump"; forget_selection
    launch --connect "127.0.0.1:$PORT" --debug-control "$ctl" --quit-after 90
    wait_until 30 events_have '"state":"auth_ok"' || wait_until 30 events_have '"state":"paired"' \
        || { bad "SET the app never authenticated"; stop_app; stop_fakephone; return 1; }
    control settings-open || bad "SET settings-open: $CONTROL_REPLY"
    wait_until 25 windows_at_least 2 || bad "SET Settings: the window never opened"
    sleep 1
    hint_shown() {
        control settings-report "$dump" >/dev/null 2>&1
        sleep 0.5
        grep -qF 'accessHint=Allow notification access on the phone.' "$dump" 2>/dev/null
    }
    wait_until 25 hint_shown || bad "SET the no-access hint never appeared"
    [ "$(report_value share)" = "1" ] && ok "SET [SET-DEV-09] the Mac asked the phone to share" \
        || bad "SET [SET-DEV-09] share=$(report_value share)"
    [ "$(report_value accessHint)" = "Allow notification access on the phone." ] \
        && ok "SET [SET-DEV-09] the page says \"Allow notification access on the phone.\" under the switch" \
        || bad "SET [SET-DEV-09] accessHint=$(report_value accessHint)"
    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    FAKE_ARGS=""
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
}

# --- Open Current App on Mac (docs/ROADMAP.md #9, docs/design/handoff.md) -----------

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
        && ok "[SHARE-10] HO the Mac sent task.continue" || bad "[SHARE-10] HO no task.continue reached the phone"
    local ho_want="$((900 * RUN_SCALE))x$((600 * RUN_SCALE))"
    wait_until 5 [ "$(rx_size task.continue)" = "$ho_want" ] \
        && ok "[WIN-5] HO the handoff window asked for its 900x600 pt stream ($ho_want)" \
        || bad "[WIN-5] HO task.continue asked for $(rx_size task.continue), not $ho_want"
    wait_until 30 events_have '"ev":"task.continue","stream":1,"mode":"moved"' \
        && ok "[SHARE-10] HO the phone moved the foreground app (started=moved)" \
        || bad "[SHARE-10] HO no moved answer: $(tail -2 "$WORK/events.jsonl" | tr '\n' ' ')"
    wait_until 30 events_have '"ev":"video","stream":1,' \
        || bad "[SHARE-10] HO no video for the continued app"
    wait_until 15 windows_at_least 2 \
        && ok "[SHARE-10] HO a window opened for the continued app ($(windows | wc -l | tr -d ' ') windows)" \
        || bad "[SHARE-10] HO no window opened"
    wait_until 15 titles_have "Settings (FakePhone)" \
        && ok "[SHARE-10] HO the window is titled \"Settings (FakePhone)\" (the app the phone reports)" \
        || bad "[SHARE-10] HO no titled window: $(window_titles "$APP_PID" | tr '\n' '|')"
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
        && ok "[SHARE-10] HO fresh: the phone answered that it relaunched the app" \
        || bad "[SHARE-10] HO fresh: no fresh answer"
    wait_until 30 events_have '"ev":"video","stream":1,' \
        && ok "[SHARE-10] HO fresh: the app still streams into its window" || bad "[SHARE-10] HO fresh: no video"
    wait_until 15 titles_have "Settings (FakePhone)" \
        && ok "[SHARE-10] HO fresh: the window is titled after the relaunched app" \
        || bad "[SHARE-10] HO fresh: no titled window"
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
        && ok "[SHARE-10] HO nothing: the command still reaches the phone" || bad "[SHARE-10] HO nothing: no task.continue"
    wait_until 30 events_have '"ev":"task.continue","stream":1,"mode":"nothing"' \
        && ok "[SHARE-10] HO nothing: the phone refused (nothing continuable in the foreground)" \
        || bad "[SHARE-10] HO nothing: the phone did not refuse"
    ! events_have '"ev":"video"' \
        && ok "[SHARE-10] HO nothing: no video, the phone opened no display" \
        || bad "[SHARE-10] HO nothing: video streamed for a refused handoff"
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
# never asks the phone to enable. Two extra posts (pd-b1 with a picture, pd-b2
# without) prove the composed attachment (NOTIFY-22).
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

    # NOTIFY-22: two extra posts (one with a picture, one without) for an app
    # whose icon the fake serves, after the Mac has cached the icon.
    FAKE_ARGS="--notify-badge" start_fake || return 1
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
        && ok "[NOTIFY-1] NOTIFY the Mac asked the phone to share (notify.enable on)" \
        || bad "[NOTIFY-1] NOTIFY the Mac never sent notify.enable on"
    wait_until 20 log_has "notify post id=pd-n1 pkg=com.android.settings" \
        && ok "[NOTIFY-3] NOTIFY pd-n1 (com.android.settings) recorded" \
        || bad "[NOTIFY-3] NOTIFY pd-n1 not recorded: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 20 log_has "notify post id=pd-n2 pkg=com.whatsapp" \
        && ok "[NOTIFY-3] NOTIFY pd-n2 (com.whatsapp) recorded" \
        || bad "[NOTIFY-3] NOTIFY pd-n2 not recorded"
    wait_until 20 log_has "notify remove id=pd-n2" \
        && ok "[NOTIFY-6] NOTIFY the removal of pd-n2 was recorded" \
        || bad "[NOTIFY-6] NOTIFY the remove was not recorded"
    log_has "thread=$device" \
        && ok "[NOTIFY-4] NOTIFY the posts are grouped under the phone ($device)" \
        || bad "[NOTIFY-4] NOTIFY the records are not grouped per phone"
    grep -qE 'titleLen=[0-9]+ bodyLen=[0-9]+' "$log" 2>/dev/null \
        && ok "[NOTIFY-14] NOTIFY the records carry field lengths, not the text" \
        || bad "[NOTIFY-14] NOTIFY the posts were recorded without lengths"
    log_has "media set playing=true" && log_has "durationMs=30000" \
        && ok "[MEDIA-1] NOTIFY media.state drove Now Playing (playing, 30 s)" \
        || bad "NOTIFY no Now Playing set: $(cat "$log" 2>/dev/null | tr '\n' '|')"

    # (c) the click opens that app's window, through the phone's window.open.
    wait_until 30 log_has "notify click id=pd-n1 pkg=com.android.settings" \
        && ok "[NOTIFY-8] NOTIFY the click recorded pd-n1 -> com.android.settings" \
        || bad "[NOTIFY-8] NOTIFY no click record: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 30 window_rx window.open "com.android.settings" \
        && ok "[NOTIFY-8] NOTIFY the click sent window.open for com.android.settings" \
        || bad "[NOTIFY-8] NOTIFY the click never reached the phone"
    wait_until 20 events_have '"ev":"video","stream":2,' \
        && ok "[NOTIFY-8] NOTIFY the Mac opened the clicked app's stream window (stream 2)" \
        || bad "[NOTIFY-8] NOTIFY no stream 2 for the clicked app"

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
        && ok "[MEDIA-2] NOTIFY the Now Playing control reached the phone (media.command play)" \
        || bad "NOTIFY no media.command play at the phone"
    log_has "media command play" \
        && ok "NOTIFY the command went through the Now Playing handler" \
        || bad "NOTIFY the command was not recorded"

    # (e) privacy: no notification text in any log.
    no_notify_text "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/events.jsonl" \
        && ok "[NOTIFY-14] NOTIFY no notification text in the app log, share log, fake log or event log" \
        || bad "[NOTIFY-14] NOTIFY notification text leaked"

    # (g) NOTIFY-22: the attachment carries the sending app's icon. The fake
    # posts pd-b1 with a picture and pd-b2 without, for com.whatsapp, whose icon
    # it serves and the Mac caches from the app list.
    wait_until 30 log_has "notify post id=pd-b1 pkg=com.whatsapp" \
        && ok "[NOTIFY-22] NOTIFY the picture post was recorded" \
        || bad "NOTIFY pd-b1 not recorded: $(tr '\n' '|' < "$log" 2>/dev/null)"
    wait_until 30 log_has "notify post id=pd-b2 pkg=com.whatsapp" \
        && ok "[NOTIFY-22] NOTIFY the icon-only post was recorded" \
        || bad "NOTIFY pd-b2 not recorded"
    grep -qE 'notify post id=pd-b1 .*composed shape=circle badge=yes side=160 class=deck' "$log" 2>/dev/null \
        && ok "[NOTIFY-22] NOTIFY the picture is a circle with the app's badge" \
        || bad "NOTIFY pd-b1 was not composed: $(grep 'id=pd-b1' "$log" 2>/dev/null | tr '\n' '|')"
    grep -qE 'notify post id=pd-b2 .*composed shape=icon badge=no side=256 class=deck' "$log" 2>/dev/null \
        && ok "[NOTIFY-22] NOTIFY no picture: the app's icon alone" \
        || bad "NOTIFY pd-b2 was not the icon alone: $(grep 'id=pd-b2' "$log" 2>/dev/null | tr '\n' '|')"
    no_notify_text "$log" \
        && ok "[NOTIFY-22] NOTIFY the composition facts carry no text" \
        || bad "[NOTIFY-22] NOTIFY the composition line leaked text"

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
        && ok "[NOTIFY-8] NOTIFY Open on Mac: notify.open target=window stream=2" \
        || bad "[NOTIFY-8] NOTIFY Open on Mac: no notify.open for the clicked window"

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
        && ok "[NOTIFY-8] NOTIFY Open on phone: notify.open target=phone" \
        || bad "[NOTIFY-8] NOTIFY Open on phone: no notify.open target=phone"
    sleep 2
    ! window_rx window.open "com.android.settings" \
        && ok "[NOTIFY-8] NOTIFY Open on phone: no Mac window for the clicked app" \
        || bad "[NOTIFY-8] NOTIFY Open on phone: the clicked app's window opened anyway"

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
        && ok "[NOTIFY-8] NOTIFY Do nothing: the click reached the routing" \
        || bad "[NOTIFY-8] NOTIFY Do nothing: the click never reached the routing"
    sleep 2
    ! notify_open_rx window "" && ! notify_open_rx phone "" \
        && ok "[NOTIFY-8] NOTIFY Do nothing: no notify.open was sent" \
        || bad "[NOTIFY-8] NOTIFY Do nothing: notify.open was sent anyway"
    ! window_rx window.open "com.android.settings" \
        && ok "[NOTIFY-8] NOTIFY Do nothing: no Mac window opened" \
        || bad "[NOTIFY-8] NOTIFY Do nothing: a window opened anyway"
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
        && ok "[NOTIFY-1] NOTIFY off: the phone was not sent notify.enable on" \
        || bad "[NOTIFY-1] NOTIFY off: notify.enable on was sent anyway"
    ! off_log_has "notify post" && ! off_log_has "notify remove" && ! off_log_has "notify click" \
        && ok "[NOTIFY-1] NOTIFY off: no post, remove or click reached the share log" \
        || bad "[NOTIFY-1] NOTIFY off: $(cat "$offlog" 2>/dev/null | tr '\n' '|')"
    no_notify_text "$WORK/app.log" "$offlog" "$WORK/fake.log" "$WORK/events.jsonl" \
        && ok "[NOTIFY-14] NOTIFY off: no notification text anywhere" \
        || bad "[NOTIFY-14] NOTIFY off: notification text leaked"
    stop_app

    # (c) macOS notifications denied: one line under the switch, with the two
    # controls that fix or recheck it (NOTIFY-4/17). The fake permission keeps
    # the person's own System Settings untouched.
    clean
    mkdir -p "$WORK-control"
    # The page's own state with a paired phone (`devices-one`), not a live
    # session: the line is about this Mac's permission, not the phone's.
    launch --preview devices-one --debug-notify-denied \
        --debug-control "$WORK-control" --quit-after 60
    wait_until 25 windows_at_least 2 || bad "NOTIFY denied: the Settings window never opened"
    sleep 1
    control settings-report "$WORK/denied.txt" >/dev/null 2>&1 || bad "NOTIFY denied: settings-report: $CONTROL_REPLY"
    grep -qF "Notifications are turned off for Contigua in System Settings." "$WORK/denied.txt" 2>/dev/null \
        && ok "[NOTIFY-4] NOTIFY a denied macOS permission shows the one line under the phone's Notifications" \
        || bad "[NOTIFY-4] NOTIFY the denied line is missing: $(grep -E 'notifications|accessHint' "$WORK/denied.txt" 2>/dev/null | tr '\n' '|')"
    grep -qF "notificationsDenied=1" "$WORK/denied.txt" 2>/dev/null \
        && ok "[NOTIFY-17] NOTIFY the page reports the denied permission" \
        || bad "[NOTIFY-17] NOTIFY the denied state is not in the report"
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
    local code_hash code_types alpha bravo removed_line child_line
    log_has() { grep -qF -- "$1" "$log" 2>/dev/null; }
    # quiet_posts — ten posts of the NOTIFY-19 key are in the share log.
    quiet_posts() {
        local n
        n="$(grep -c "notify post id=pd-q1 " "$WORK/notify-quiet.log" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge 10 ]
    }
    # hold_post — the 100 ms re-post of NOTIFY-19 has been delivered.
    hold_post() {
        local n
        n="$(grep -c "notify post id=pd-q2 " "$WORK/notify-quiet.log" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge 1 ]
    }
    # quiet_add_post — the quiet first post of NOTIFY-19 has been delivered.
    quiet_add_post() {
        local n
        n="$(grep -c "notify post id=pd-q3 " "$WORK/notify-quiet.log" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge 1 ]
    }
    # progress_posts — the six posts of the NOTIFY-19 progress series arrived.
    progress_posts() {
        local n
        n="$(grep -c "notify post id=pd-p1 " "$WORK/notify-quiet.log" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge 6 ]
    }
    # group_hash ID — the 16-hex group hash the fake phone sent for that post.
    group_hash() {
        python3 - "$WORK/events.jsonl" "$1" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "notify" and event.get("kind") == "post" and event.get("id") == sys.argv[2]:
        print(event.get("group", ""))
        break
PY
    }
    # groups_done — the three group posts and the summary's removal arrived.
    groups_done() {
        local n
        n="$(grep -c "notify post id=pd-g" "$WORK/notify-groups.log" 2>/dev/null)" || n=0
        [ "${n:-0}" -ge 3 ] && grep -q "notify remove id=pd-g3" "$WORK/notify-groups.log" 2>/dev/null
    }
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
        && ok "[NOTIFY-3] NOTIFY-ACTIONS pd-a1 (reply shape) recorded" \
        || bad "[NOTIFY-3] NOTIFY-ACTIONS pd-a1 not recorded: $(cat "$log" 2>/dev/null | tr '\n' '|')"
    log_has "actions=2 reply=1" \
        && ok "[NOTIFY-3] NOTIFY-ACTIONS the reply shape advertised 2 actions, one reply" \
        || bad "[NOTIFY-3] NOTIFY-ACTIONS the reply shape's action counts are wrong"
    log_has "code=0 ongoing=0 category=pd.n." \
        && ok "[NOTIFY-9] NOTIFY-ACTIONS the category is a shape hash" \
        || bad "[NOTIFY-9] NOTIFY-ACTIONS no category hash for pd-a1"
    wait_until 20 log_has "notify post id=pd-a4 pkg=com.whatsapp" \
        && ok "[NOTIFY-10] NOTIFY-ACTIONS pd-a4 (code shape) recorded" \
        || bad "[NOTIFY-10] NOTIFY-ACTIONS pd-a4 not recorded"
    grep -q "notify post id=pd-a4 .*code=1" "$log" 2>/dev/null \
        && ok "[NOTIFY-10] NOTIFY-ACTIONS the code was found in the notification" \
        || bad "[NOTIFY-10] NOTIFY-ACTIONS the code was not found"

    # (b) muted: com.slack's post is dropped before it is shown.
    wait_until 20 log_has "notify muted pkg=com.slack" \
        && ok "[NOTIFY-13] NOTIFY-ACTIONS the muted package was dropped" \
        || bad "[NOTIFY-13] NOTIFY-ACTIONS no muted line"
    ! log_has "notify post id=pd-a5" \
        && ok "[NOTIFY-13] NOTIFY-ACTIONS the muted package got no banner" \
        || bad "[NOTIFY-13] NOTIFY-ACTIONS the muted package was posted anyway"

    # (c) reply and button: the phone logs the right index and text length.
    wait_until 20 log_has "notify action id=pd-a1 i=1 textLen=10" \
        && ok "[NOTIFY-9] NOTIFY-ACTIONS the reply action was sent" \
        || bad "[NOTIFY-9] NOTIFY-ACTIONS no reply action in the share log"
    wait_until 20 notify_rx action pd-a1 1 10 \
        && ok "[NOTIFY-9] NOTIFY-ACTIONS the phone got the reply (i=1, length 10)" \
        || bad "[NOTIFY-9] NOTIFY-ACTIONS the phone logged no reply action"
    wait_until 20 notify_rx action pd-a1 0 0 \
        && ok "[NOTIFY-9] NOTIFY-ACTIONS the phone got the button (i=0, no text)" \
        || bad "[NOTIFY-9] NOTIFY-ACTIONS the phone logged no button action"

    # (d) dismiss: the clearable one goes out, the ongoing one does not.
    wait_until 20 notify_rx dismiss pd-a2 \
        && ok "[NOTIFY-6] NOTIFY-ACTIONS the phone got notify.dismiss for the banner" \
        || bad "[NOTIFY-6] NOTIFY-ACTIONS the phone logged no dismiss"
    log_has "notify dismiss id=pd-a3 refused=ongoing" \
        && ok "[NOTIFY-6] NOTIFY-ACTIONS the ongoing notification was refused" \
        || bad "[NOTIFY-6] NOTIFY-ACTIONS the ongoing refusal is not in the share log"
    ! notify_rx dismiss pd-a3 \
        && ok "[NOTIFY-6] NOTIFY-ACTIONS no dismiss was sent for the ongoing notification" \
        || bad "[NOTIFY-6] NOTIFY-ACTIONS the ongoing notification was dismissed anyway"

    # (e) the phone taking a notification away clears the banner (notify.remove).
    wait_until 20 log_has "notify remove id=pd-n2" \
        && ok "[NOTIFY-6] NOTIFY-ACTIONS the phone's notify.remove reached the Mac" \
        || bad "[NOTIFY-6] NOTIFY-ACTIONS notify.remove was not recorded"

    # (f) Copy code: value and length by hash, the concealed/transient types,
    # then the clipboard is cleared again. Nothing here prints the code.
    wait_until 20 log_has "notify copy id=pd-a4 len=6" \
        && ok "[NOTIFY-10] NOTIFY-ACTIONS Copy code copied a 6-char code" \
        || bad "[NOTIFY-10] NOTIFY-ACTIONS no copy line"
    if [ -n "$(pbpaste 2>/dev/null)" ]; then
        code_hash="$(pbpaste | shasum -a 256 | cut -d' ' -f1)"
        code_types="$(xcrun swift -e 'import AppKit; print((NSPasteboard.general.types ?? []).map { $0.rawValue }.joined(separator: ","))' 2>/dev/null)"
        [ "$(printf '%s' 482913 | shasum -a 256 | cut -d' ' -f1)" = "$code_hash" ] \
            && ok "[NOTIFY-10] NOTIFY-ACTIONS the pasteboard holds the code (hash match)" \
            || bad "[NOTIFY-10] NOTIFY-ACTIONS the pasteboard does not hold the code"
        case "$code_types" in
            *org.nspasteboard.ConcealedType*) ok "[NOTIFY-10] NOTIFY-ACTIONS the pasteboard item is concealed" ;;
            *) bad "[NOTIFY-10] NOTIFY-ACTIONS the pasteboard item is not concealed ($code_types)" ;;
        esac
        case "$code_types" in
            *org.nspasteboard.TransientType*) ok "[NOTIFY-10] NOTIFY-ACTIONS the pasteboard item is transient" ;;
            *) bad "[NOTIFY-10] NOTIFY-ACTIONS the pasteboard item is not transient" ;;
        esac
        pbcopy < /dev/null
    else
        bad "[NOTIFY-10] NOTIFY-ACTIONS the pasteboard is empty after Copy code"
    fi

    # (g) privacy: no notification or reply text in any log.
    ! grep -qE 'pd-notify-(title|text)-[0-9]|pd-reply-1|482913' \
        "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null \
        && ok "[NOTIFY-14] NOTIFY-ACTIONS no notification or reply text reached a log" \
        || bad "[NOTIFY-14] NOTIFY-ACTIONS notification text leaked"

    # (h) [NOTIFY-19] an update the phone did not mark alerting replaces the
    # delivered banner without presenting it: one key posted ten times, the
    # first alerting and the nine quiet (a progress bar's wire). The Mac's own
    # record carries, for each id, its post's `alert`, the banners it holds and
    # the running presented/quiet counts; the last line is the end state. A
    # share-log run: nothing reaches Notification Center.
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone
    FAKE_ARGS="--notify-quiet" start_fake '' || return 1
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    launch --connect "127.0.0.1:$PORT" --quit-after 30 --share-log "$WORK/notify-quiet.log"
    wait_until 20 quiet_posts \
        && ok "[NOTIFY-19] NOTIFY-ACTIONS the same key was posted ten times" \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS fewer than ten posts of the quiet key"
    python3 - "$WORK/notify-quiet.log" <<'PY' \
        && ok "[NOTIFY-19] NOTIFY-ACTIONS 1 presented, 9 quiet replacements, 1 delivered banner" \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS the quiet updates did not replace quietly"
import sys
lines = open(sys.argv[1]).read().splitlines()
posts = [line for line in lines if line.startswith("notify post id=pd-q1 ")]
alerting = [line for line in posts if " alert=1" in line]
quiet = [line for line in posts if " alert=0" in line]
if len(posts) != 10:
    print("posts:", len(posts)); sys.exit(1)
if len(alerting) != 1 or len(quiet) != 9:
    print("posts:", len(posts), "alerting:", len(alerting), "quiet:", len(quiet)); sys.exit(1)
last = posts[-1]
if " banners=1 presented=1 quiet=9" not in last:
    print("last post:", last); sys.exit(1)
PY
    ! grep -qE 'pd-notify-(title|text)-[0-9]' \
        "$WORK/notify-quiet.log" "$WORK/app.log" "$WORK/events.jsonl" 2>/dev/null \
        && ok "[NOTIFY-14] NOTIFY-ACTIONS the quiet posts carried no text in a log" \
        || bad "[NOTIFY-14] NOTIFY-ACTIONS the quiet posts leaked text"

    # (h2) [NOTIFY-19] the hold case: the same app re-posts 100 ms later (an
    # action or an icon) inside the Mac's 300 ms hold, with alert:false. The
    # post that supersedes one still waiting inherits its delivery state, so the
    # one banner that reaches Notification Center presents.
    wait_until 10 hold_post \
        && ok "[NOTIFY-19] NOTIFY-ACTIONS the re-posted key reached the Mac" \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS no re-post inside the hold reached the Mac"
    python3 - "$WORK/notify-quiet.log" <<'PY' \
        && ok "[NOTIFY-19] NOTIFY-ACTIONS a quiet re-post inside the hold still presents the banner" \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS the quiet re-post inside the hold presented nothing"
import sys
lines = open(sys.argv[1]).read().splitlines()
posts = [line for line in lines if line.startswith("notify post id=pd-q2 ")]
if len(posts) != 1:
    print("posts:", len(posts)); sys.exit(1)
if " alert=1 banners=1 presented=1 quiet=0" not in posts[0]:
    print("post:", posts[0]); sys.exit(1)
PY
    # (h3) [NOTIFY-19] a first post with alert:false (a LOW channel, or a
    # notification the Mac first sees mid-life) is added quietly: one banner in
    # the list, nothing presented.
    wait_until 10 quiet_add_post \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS no quiet first post reached the Mac"
    python3 - "$WORK/notify-quiet.log" <<'PY' \
        && ok "[NOTIFY-19] NOTIFY-ACTIONS a first post with alert:false is listed quietly, not presented" \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS a first post with alert:false presented a banner"
import sys
lines = open(sys.argv[1]).read().splitlines()
posts = [line for line in lines if line.startswith("notify post id=pd-q3 ")]
if len(posts) != 1:
    print("posts:", len(posts)); sys.exit(1)
if " alert=0 banners=1 presented=0 quiet=1" not in posts[0]:
    print("post:", posts[0]); sys.exit(1)
PY
    # (h4) [NOTIFY-19] row 6: the bar moving is not news. Five ticks whose text
    # changes and whose bar moves are quiet, the post that drops the bar alerts.
    wait_until 20 progress_posts \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS the progress series did not arrive"
    python3 - "$WORK/notify-quiet.log" <<'PY' \
        && ok "[NOTIFY-19] NOTIFY-ACTIONS a moving progress bar is quiet; the post that drops it alerts" \
        || bad "[NOTIFY-19] NOTIFY-ACTIONS the progress ticks did not follow the rule"
import sys
lines = open(sys.argv[1]).read().splitlines()
posts = [line for line in lines if line.startswith("notify post id=pd-p1 ")]
if len(posts) != 6:
    print("posts:", len(posts)); sys.exit(1)
alerting = [line for line in posts if " alert=1 " in line]
quiet = [line for line in posts if " alert=0 " in line]
if len(alerting) != 2 or len(quiet) != 4:
    print("alerting:", len(alerting), "quiet:", len(quiet)); sys.exit(1)
if " alert=1 " not in posts[0]:
    print("first:", posts[0]); sys.exit(1)
if " alert=1 banners=1 presented=2 quiet=4" not in posts[-1]:
    print("last:", posts[-1]); sys.exit(1)
PY
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    # (i) [NOTIFY-20] a group summary never lands on top of its child: the phone
    # sends a child, leaves its summary on the phone, forwards a lone summary,
    # then removes that summary before the child that supersedes it. Every
    # grouped post is threaded under <phoneId>.<group hash>; no group key ever
    # appears in a log.
    FAKE_ARGS="--notify-groups" start_fake '' || return 1
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    launch --connect "127.0.0.1:$PORT" --quit-after 30 --share-log "$WORK/notify-groups.log"
    wait_until 20 groups_done \
        && ok "[NOTIFY-20] NOTIFY-ACTIONS the group wire arrived (child, lone summary, removal, child)" \
        || bad "[NOTIFY-20] NOTIFY-ACTIONS the group wire did not arrive: $(tr '\n' '|' < "$WORK/notify-groups.log" 2>/dev/null)"
    alpha="$(group_hash pd-g1)"
    bravo="$(group_hash pd-g3)"
    [ -n "$alpha" ] && [ -n "$bravo" ] && [ "$alpha" != "$bravo" ] \
        && ok "[NOTIFY-20] NOTIFY-ACTIONS the phone sent a group hash, not the group key" \
        || bad "[NOTIFY-20] NOTIFY-ACTIONS no distinct group hashes in the phone's events"
    [ "$(grep -c "notify post id=pd-g1 " "$WORK/notify-groups.log" 2>/dev/null)" = "1" ] \
        && [ "$(grep -c "notify post id=pd-g" "$WORK/notify-groups.log" 2>/dev/null)" = "3" ] \
        && ok "[NOTIFY-20] NOTIFY-ACTIONS the summary of a group with a child never posted" \
        || bad "[NOTIFY-20] NOTIFY-ACTIONS a second banner landed for the child's group"
    grep -q "notify post id=pd-g1 .* thread=$device.$alpha" "$WORK/notify-groups.log" 2>/dev/null \
        && ok "[NOTIFY-20] NOTIFY-ACTIONS the child is threaded under the phone and its group" \
        || bad "[NOTIFY-20] NOTIFY-ACTIONS the child's thread carries no group hash"
    grep -q "notify post id=pd-g3 .* thread=$device.$bravo" "$WORK/notify-groups.log" 2>/dev/null \
        && ok "[NOTIFY-20] NOTIFY-ACTIONS a summary with no children banners, threaded under its group" \
        || bad "[NOTIFY-20] NOTIFY-ACTIONS the lone summary did not banner under its group"
    grep -q "notify post id=pd-g4 .* thread=$device.$bravo" "$WORK/notify-groups.log" 2>/dev/null \
        && ok "[NOTIFY-20] NOTIFY-ACTIONS the child after the summary joined its thread" \
        || bad "[NOTIFY-20] NOTIFY-ACTIONS the late child's thread is wrong"
    removed_line="$(grep -n "notify remove id=pd-g3" "$WORK/notify-groups.log" 2>/dev/null | cut -d: -f1)"
    child_line="$(grep -n "notify post id=pd-g4" "$WORK/notify-groups.log" 2>/dev/null | cut -d: -f1)"
    [ -n "$removed_line" ] && [ -n "$child_line" ] && [ "$removed_line" -lt "$child_line" ] \
        && ok "[NOTIFY-20] NOTIFY-ACTIONS the summary was removed before the child posted" \
        || bad "[NOTIFY-20] NOTIFY-ACTIONS the summary removal did not precede the child"
    ! grep -qE 'pd-group-(alpha|bravo)' \
        "$WORK/notify-groups.log" "$WORK/app.log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null \
        && ok "[NOTIFY-14] NOTIFY-ACTIONS no group key reached a log" \
        || bad "[NOTIFY-14] NOTIFY-ACTIONS a group key leaked into a log"
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

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
# carry ids, progress buckets and timestamps, and `livedump` reads the panel's
# LIVE section (one row per live item). Nothing reaches Notification Center; no
# picture bytes are logged.
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
panelopen
notifyclick pd-l1
livedump $WORK/notify-media-live-1.json
wait 3
livedump $WORK/notify-media-live-2.json
paneldump panel $WORK/notify-media-panel.json
wait 6
livedump $WORK/notify-media-live-3.json
wait 3
livedump $WORK/notify-media-live-4.json
panelclose
EOF
    # The picture and Live Update shapes arrive on notify.enable; the fake also
    # ends pd-m1 after 8 s and pd-l1 after its twenty seconds of updates.
    launch --connect "127.0.0.1:$PORT" --quit-after 70 \
        --open com.whatsapp --share-log "$log" --debug-input-script "$script"

    # (a) the picture joins its post: mime, dimensions, size and a temp file.
    wait_until 20 log_has "notify post id=pd-m1 pkg=com.whatsapp" \
        || { bad "NOTIFY-MEDIA pd-m1 not recorded: $(tr '\n' '|' < "$log" 2>/dev/null)"; stop_app; stop_fakephone; return 1; }
    grep -qE 'image=image/png w=160 h=160 size=[0-9]+ attachment=' "$log" 2>/dev/null \
        && ok "NOTIFY-MEDIA the picture joined the post (composed png 160x160)" \
        || bad "NOTIFY-MEDIA the post carries no image facts"
    path="$(sed -n 's/^notify post id=pd-m1 .*attachment=\([^ ]*\).*/\1/p' "$log" | head -1)"
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
            */Caches/Contigua-"$PROFILE"/notify/*) ok "NOTIFY-MEDIA the temp file is in the profile's caches" ;;
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
    ! grep -qE 'notify post id=pd-m2 .*image=image/jpeg w=160 h=120' "$log" 2>/dev/null \
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

    # (e) the panel's LIVE section: the rows, an advancing item, the end.
    for f in 1 2 3 4; do
        wait_until 30 [ -s "$WORK/notify-media-live-$f.json" ] \
            || { bad "NOTIFY-MEDIA no livedump $f"; break; }
    done
    wait_until 20 [ -s "$WORK/notify-media-panel.json" ] \
        || bad "NOTIFY-MEDIA no panel dump"
    python3 - "$WORK" <<'PY' && ok "NOTIFY-MEDIA the panel's LIVE section has one row per live item, no track text" \
        || bad "NOTIFY-MEDIA the panel's LIVE rows do not match"
import json, sys, os
work = sys.argv[1]
panel = json.load(open(os.path.join(work, "notify-media-panel.json")))
live = json.load(open(os.path.join(work, "notify-media-live-2.json")))["live"]
rows = [row for row in panel["items"] if row["kind"] == "live"]
if len(rows) != len(live):
    print("panel live rows:", len(rows), "live items:", len(live)); sys.exit(1)
if not panel["mapped"] and len(panel["controls"]) < 4:
    print("controls:", len(panel["controls"])); sys.exit(1)
# A live row's id is panel.live and its Dismiss is panel.liveDismiss (one
# item per row); every other row's id is unique.
ids = [row["id"] for row in panel["items"] if row["kind"] not in ("live", "liveDismiss")]
if len(ids) != len(set(ids)):
    print("duplicate ids:", ids); sys.exit(1)
PY
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
    [ -z "$(ls -A "$HOME/Library/Caches/Contigua-$PROFILE/notify" 2>/dev/null)" ] \
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
    # ring_label — the panel's Ring row label right now (the model both the
    # panel and its dump read).
    ring_label() {
        control paneldump panel "$WORK/media-panel-ring.json" >/dev/null 2>&1 || return 0
        python3 - "$WORK/media-panel-ring.json" <<'PY'
import json, sys
root = json.load(open(sys.argv[1]))
print(next((row["label"] for row in root["items"] if row["kind"] == "ring"), ""))
PY
    }

    # (a) two playing apps: the list, the state, the artwork.
    FAKE_ARGS="--media --volume 15 --foreground-pkg none" start_fake '' || return 1
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
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$PORT" --quit-after 75 --share-log "$log" \
        --open com.whatsapp --debug-input-script "$script" --debug-control "$WORK-control"

    wait_until 20 log_has "media sessions n=2 chosen=s1" \
        && ok "[MEDIA-5] MEDIA the phone listed both playing apps, the first chosen" \
        || bad "[MEDIA-5] MEDIA no media.sessions line: $(tr '\n' '|' < "$log" 2>/dev/null)"
    wait_until 20 log_has "media set playing=true" \
        && ok "[MEDIA-1] MEDIA media.state drove Now Playing" \
        || bad "[MEDIA-1] MEDIA no media.state record"
    grep -qE "media set .*canSeek=1 volume=8 volumeMax=15" "$log" 2>/dev/null \
        && ok "[MEDIA-3] MEDIA the state carries canSeek and the session volume (8/15)" \
        || bad "[MEDIA-3] MEDIA no canSeek/volume in the state record: $(grep 'media set' "$log" 2>/dev/null | head -1)"
    wait_until 20 grep -q "media art w=160 h=120 bytes=" "$log" 2>/dev/null \
        && ok "[MEDIA-4] MEDIA the artwork arrived (jpeg 160x120)" \
        || bad "[MEDIA-4] MEDIA no media art record"
    # Artwork once per change: one send for the first session so far.
    [ "$(grep -c "media art w=" "$log" 2>/dev/null)" = "1" ] \
        && [ "$(media_count art)" = "1" ] \
        && ok "[MEDIA-4] MEDIA the artwork was sent once, not once per state" \
        || bad "[MEDIA-4] MEDIA artwork sent $(grep -c 'media art w=' "$log" 2>/dev/null) times ($(media_count art) from the phone)"

    # (b) the position bar: 45 s asked, the track is 30 s, so 30 s goes out.
    wait_until 20 grep -q "media command seek positionMs=30000" "$log" 2>/dev/null \
        && ok "[MEDIA-3] MEDIA a seek past the end was clamped to the track (30000 ms)" \
        || bad "[MEDIA-3] MEDIA no clamped seek record: $(grep 'media command' "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 20 [ "$(media_count rx action=seek)" -ge 1 ] \
        && ok "[MEDIA-3] MEDIA the phone received the seek" \
        || bad "[MEDIA-3] MEDIA the phone received no seek"
    media_events rx action=seek | grep -q '"positionMs": 30000' \
        && ok "[MEDIA-3] MEDIA the seek reached the phone with the clamped value" \
        || bad "[MEDIA-3] MEDIA the seek value at the phone: $(media_events rx action=seek | tr '\n' '|')"
    # The next state confirms where the session now is (the fake answers).
    wait_until 20 grep -qE "media set .*elapsedMs=30000" "$log" 2>/dev/null \
        && ok "[MEDIA-3] MEDIA the next media.state confirmed the new position" \
        || bad "[MEDIA-3] MEDIA no state after the seek: $(grep 'media set' "$log" 2>/dev/null | tail -1)"

    # (c) volume: 99 asked, the session tops at 15.
    wait_until 20 grep -q "media command volume level=15" "$log" 2>/dev/null \
        && ok "[MEDIA-11] MEDIA the volume was clamped to the session maximum (15)" \
        || bad "[MEDIA-11] MEDIA no clamped volume record: $(grep 'media command' "$log" 2>/dev/null | tr '\n' '|')"
    media_events rx action=volume | grep -q '"level": 15' \
        && ok "[MEDIA-11] MEDIA the volume reached the phone as 15" \
        || bad "[MEDIA-11] MEDIA the volume at the phone: $(media_events rx action=volume | tr '\n' '|')"
    wait_until 20 grep -qE "media set .*volume=15 volumeMax=15" "$log" 2>/dev/null \
        && ok "[MEDIA-11] MEDIA the next media.state reflects the new volume" \
        || bad "[MEDIA-11] MEDIA the volume did not come back in a state"

    # (d) choosing: the second app takes over, its state and art follow.
    wait_until 20 seen_choose \
        && ok "[MEDIA-5] MEDIA media.choose reached the phone" \
        || bad "[MEDIA-5] MEDIA the phone saw no media.choose ($(media_events choose | tr '\n' '|'))"
    wait_until 20 log_has "media sessions n=2 chosen=s2" \
        && ok "[MEDIA-5] MEDIA the next sessions list shows the picked app" \
        || bad "[MEDIA-5] MEDIA the chosen key never moved: $(grep 'media sessions' "$log" 2>/dev/null | tr '\n' '|')"
    wait_until 20 grep -qE "media set .*key=s2" "$log" 2>/dev/null \
        && ok "[MEDIA-5] MEDIA the next media.state carries the picked session's key" \
        || bad "[MEDIA-5] MEDIA no state for the picked session"
    wait_until 20 [ "$(grep -c 'media art w=' "$log" 2>/dev/null)" = "2" ] \
        && ok "[MEDIA-4] MEDIA the picked app's artwork arrived once more" \
        || bad "[MEDIA-4] MEDIA the picked app's artwork did not arrive"
    wait_until 20 seen_second_seek \
        && ok "[MEDIA-3] MEDIA a seek on the picked session reached the phone (5000 ms)" \
        || bad "[MEDIA-3] MEDIA no second seek at the phone ($(media_events rx | tr '\n' '|'))"

    # (e) no track text or picture bytes in any log.
    ! grep -qE 'pd-media-(title|artist|album)-9|/9j/4AAQ' \
        "$WORK/app.log" "$log" "$WORK/fake.log" "$WORK/fake.err" "$WORK/events.jsonl" 2>/dev/null \
        && ok "[MEDIA-13] MEDIA no track text or artwork bytes reached a log" \
        || bad "[MEDIA-13] MEDIA track text or artwork bytes leaked"

    # (e2) the menu bar panel (docs/design/mac-redesign.md §3.8): a window
    # panel, not a menu — the volume is an inline slider and every item has its
    # own laid-out control — and the real controls reach the phone: the slider
    # drag sends the media volume, the Ring row rings and stops it.
    control panelopen || bad "MEDIA panelopen: $CONTROL_REPLY"
    control paneldump panel "$WORK/media-panel.json" || bad "MEDIA paneldump: $CONTROL_REPLY"
    python3 - "$WORK/media-panel.json" <<'PY' && ok "MEDIA the panel is the phone card: 300 pt, one control per item, the volume an inline slider" \
        || bad "MEDIA the panel's controls are not the phone card"
import json, sys
root = json.load(open(sys.argv[1]))
if root["width"] != 300:
    print("width:", root["width"]); sys.exit(1)
if not root["mapped"]:
    print("items:", len(root["items"]), "controls:", len(root["controls"])); sys.exit(1)
kinds = [row["kind"] for row in root["items"]]
# The merged phone card (PANEL-5, UX.md §3): the gear heads it and the
# Settings…/Quit rows live in the icon's own menu, not on the card.
want = ["gear", "volume", "dnd", "ringer", "ring", "screen", "sessions", "phoneScreen",
        "findApps"]
if kinds != want:
    print("items:", kinds); sys.exit(1)
enabled = [row for row in root["items"] if row["enabled"]]
volume_index = next(i for i, row in enumerate(enabled) if row["kind"] == "volume")
volume = root["controls"][volume_index]
if volume["height"] > 20 or volume["width"] < 150:
    print("volume control:", volume); sys.exit(1)
if any("Open Contigua" in row["label"] or "Phone screen" in row["label"] for row in root["items"]):
    print("a menu item survived in the panel"); sys.exit(1)
PY
    # The slider was at 1.0 (15/15); drag it to a fifth of the track: the
    # phone's own music stream gets level 3, not the media session's.
    control paneldrag panel panel.volume 0.2 || bad "MEDIA paneldrag: $CONTROL_REPLY"
    wait_until 20 events_have '"ev":"volume","level":3,"max":15' \
        && ok "MEDIA dragging the panel's slider sent the phone volume (3/15)" \
        || bad "MEDIA the panel drag reached no phone volume ($(grep '"ev":"volume"' "$WORK/events.jsonl" 2>/dev/null | tr '\n' '|'))"
    control panelclick panel panel.ring || bad "MEDIA panelclick ring: $CONTROL_REPLY"
    wait_until 20 events_have '"ev":"ring"' \
        && ok "MEDIA clicking the panel's Ring row rang the phone" \
        || bad "MEDIA the panel's Ring row sent no phone.ring"
    # The phone answered ring.state, so the row is Stop Ringing now and its own
    # click sends the stop.
    wait_until 15 [ "$(ring_label)" = "Stop Ringing" ] \
        && ok "MEDIA the row flipped to Stop Ringing while the phone rings" \
        || bad "MEDIA the ring row did not flip ($(ring_label))"
    control panelclick panel panel.ring || bad "MEDIA panelclick stop: $CONTROL_REPLY"
    wait_until 10 events_have '"ev":"ring","seconds":0' \
        && ok "MEDIA clicking Stop Ringing stopped the phone" \
        || bad "MEDIA no phone.ring.stop from the flipped row"
    control panelclose || bad "MEDIA panelclose: $CONTROL_REPLY"

    # The next fakephone start empties the shared event log; keep this phase's.
    cp "$WORK/events.jsonl" "$WORK/media-events-phase1.jsonl" 2>/dev/null
    stop_app
    stop_fakephone
    wait_until 10 no_fakephone
    sleep 2

    # (f) an older phone: today's media.state only; no sessions, no artwork,
    # no canSeek/volume, and the Mac keeps its single-session behaviour. It
    # also cannot read the music stream, so the panel's slider is off with the
    # reason line instead of guessing a level.
    FAKE_ARGS="--older-phone --volume-unsupported" start_fake '' || return 1
    cat > "$oldscript" <<'EOF'
wait 5
mediacmd play
wait 1
EOF
    launch --connect "127.0.0.1:$PORT" --quit-after 60 --share-log "$oldlog" \
        --open com.whatsapp --debug-input-script "$oldscript" --debug-control "$WORK-control"
    wait_until 20 old_log_has "media set playing=true" \
        && ok "[MEDIA-7] MEDIA the older phone's state still reaches Now Playing" \
        || bad "[MEDIA-7] MEDIA no state from the older phone: $(tr '\n' '|' < "$oldlog" 2>/dev/null)"
    grep -qE "media set .*canSeek=0 volume=-1 volumeMax=-1 key=-" "$oldlog" 2>/dev/null \
        && ok "[MEDIA-7] MEDIA the older phone's state carries none of the new fields" \
        || bad "[MEDIA-7] MEDIA unexpected older-phone record: $(grep 'media set' "$oldlog" 2>/dev/null | head -1)"
    ! grep -q "media sessions" "$oldlog" 2>/dev/null \
        && ok "[MEDIA-7] MEDIA no session list from the older phone" \
        || bad "[MEDIA-7] MEDIA the older phone produced a media.sessions line"
    ! grep -q "media art" "$oldlog" 2>/dev/null \
        && ok "[MEDIA-7] MEDIA no artwork from the older phone" \
        || bad "[MEDIA-7] MEDIA the older phone produced a media art line"
    wait_until 25 old_log_has "media command play" \
        && ok "[MEDIA-7] MEDIA a transport command still works with the older phone" \
        || bad "[MEDIA-7] MEDIA the older phone got no command"
    # The panel's slider is the phone stream: an old phone sends no
    # volume/volumeMax, so it is disabled and the reason line names why.
    control panelopen || bad "MEDIA old panelopen: $CONTROL_REPLY"
    control paneldump panel "$WORK/media-panel-old.json" || bad "MEDIA old paneldump: $CONTROL_REPLY"
    python3 - "$WORK/media-panel-old.json" <<'PY' && ok "MEDIA the older phone's panel disables the slider and says why" \
        || bad "MEDIA the older phone's panel did not disable the slider"
import json, sys
root = json.load(open(sys.argv[1]))
volume = next((row for row in root["items"] if row["kind"] == "volume"), None)
if not volume or volume["enabled"]:
    print("volume:", volume); sys.exit(1)
if "hasn't sent a volume" not in root["reason"]:
    print("reason:", root["reason"]); sys.exit(1)
PY
    control panelclose >/dev/null 2>&1

    stop_app
    stop_fakephone
    wait_until 10 no_fakephone

    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
}

# --- AX presses -------------------------------------------------------------

# panel_open — click the app's menu bar item through System Events. The extra
# is a `.window` panel now: it opens the card, not a menu (there is no `menu 1`
# to read).
panel_open() {
    # PID-targeted: the person's installed Contigua can be running too, and
    # its status item is not ours to click.
    osascript - "$APP_PID" <<'OSA' 2>/dev/null
on run argv
    set pidText to item 1 of argv
    tell application "System Events"
        set matches to every process whose unix id is (pidText as integer)
        if (count of matches) is 0 then return "noproc"
        tell item 1 of matches
            if not (exists menu bar item 1 of menu bar 2) then return "nostatus"
            click menu bar item 1 of menu bar 2
            delay 1
            return "opened"
        end tell
    end tell
end run
OSA
}

# panel_ax — the AX labels inside the app's narrow window (the panel), one per
# line: title, else description, else value. The panel is the window under
# 420 pt wide; the Deck is the wide one.
# panel_visible — our own status-item panel is on screen (a narrow window of
# this run's PID), for a PID-targeted toggle instead of a global Esc.
panel_visible() {
    osascript - "$APP_PID" <<'OSA' 2>/dev/null
on run argv
    set pidText to item 1 of argv
    tell application "System Events"
        set matches to every process whose unix id is (pidText as integer)
        if (count of matches) is 0 then return "no"
        tell item 1 of matches
            repeat with w in windows
                try
                    set s to size of w
                    if (item 1 of s) < 420 and (item 2 of s) >= 250 then return "yes"
                end try
            end repeat
        end tell
    end tell
    return "no"
end run
OSA
}

panel_ax() {
    osascript - "$APP_PID" <<'OSA' 2>/dev/null
on run argv
    set pidText to item 1 of argv
    tell application "System Events"
        set matches to every process whose unix id is (pidText as integer)
        if (count of matches) is 0 then return "noproc"
        tell item 1 of matches
            set out to {}
            with timeout of 25 seconds
                repeat with w in windows
                    try
                        set s to size of w
                        if (item 1 of s) < 420 then
                            set out to out & my labels(w)
                        end if
                    end try
                end repeat
            end timeout
            set text item delimiters to linefeed
            return out as string
        end tell
    end tell
end run

on labels(w)
    tell application "System Events"
        set out to {}
        try
            set kids to entire contents of w
        on error
            return out
        end try
        repeat with e in kids
            try
                set bits to ""
                try
                    if (title of e as string) is not "" then set bits to (title of e as string)
                end try
                if bits is "" then
                    try
                        if (description of e as string) is not "" then set bits to (description of e as string)
                    end try
                end if
                if bits is "" then
                    try
                        if (value of e as string) is not "" then set bits to (value of e as string)
                    end try
                end if
                if bits is not "" then set end of out to bits
                try
                    if (help of e as string) is not "" then set end of out to (help of e as string)
                end try
            end try
        end repeat
        return out
    end tell
end labels
OSA
}

# shot_panel_window NAME — capture the panel's own window (the narrow one: the
# Deck is 760 pt wide) into the caller's $shots; false when it is not there.
# The window's frame comes from AX and the capture is that rectangle: the panel
# lives above the normal window levels, where the CG window list does not list
# it for `screencapture -l`.
shot_panel_window() {
    local frame x y w h
    # NAME [MIN WIDTH] [MAX WIDTH]: the panel is 300 pt, the Deck's popover 326.
    frame="$(osascript - "$APP_PID" "${2:-280}" "${3:-400}" <<'OSA' 2>/dev/null
on run argv
    set pidText to item 1 of argv
    set minWidth to (item 2 of argv) as integer
    set maxWidth to (item 3 of argv) as integer
    tell application "System Events"
        set matches to every process whose unix id is (pidText as integer)
        if (count of matches) is 0 then return ""
        tell item 1 of matches
            repeat with w in windows
                try
                    set s to size of w
                    if (item 1 of s) >= minWidth and (item 1 of s) <= maxWidth and (item 2 of s) >= 300 then
                        set p to position of w
                        return ((item 1 of p) as string) & "," & ((item 2 of p) as string) & "," & ((item 1 of s) as string) & "," & ((item 2 of s) as string)
                    end if
                end try
            end repeat
        end tell
    end tell
    return ""
end run
OSA
)"
    [ -n "$frame" ] || return 1
    x="$(echo "$frame" | cut -d, -f1)"
    y="$(echo "$frame" | cut -d, -f2)"
    w="$(echo "$frame" | cut -d, -f3)"
    h="$(echo "$frame" | cut -d, -f4)"
    screencapture -x -R"$x,$y,$w,$h" "$shots/$1" >/dev/null 2>&1 || return 1
    say "shot: $shots/$1"
}

# ax_resize_all W H PATH — set every window of this run's app to WxH through
# Accessibility, the path a tiler or a script uses, then write one
# "title<TAB>WxH" line per window: the window server's answer, not the app's.
ax_resize_all() {
    build_cgevent || { say "no AX helper"; return 1; }
    "$CGBIN" axresize --pid "$APP_PID" --width "$1" --height "$2" > "$3"
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
    for proc in NotificationCenter UserNotificationCenter Contigua "Contigua Notifications"; do
        ax_press "Allow" "$proc" >/dev/null
    done
    wait_until 10 grep -q "notify authorization" "$WORK/app.log" 2>/dev/null || true
    grep -q "notify authorization granted=true" "$WORK/app.log" 2>/dev/null \
        && ok "NOTIFY-VM macOS authorized Contigua's notifications" \
        || bad "NOTIFY-VM the guest refuses Contigua's notifications (no banner can appear; reset the guest's TCC answer)"
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
    # Part 2b: the panel's LIVE section with a row that advances. Two shots a
    # few seconds apart, the panel left open in between.
    FAKE_ARGS="--notify-only pd-l1" start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --quit-after 90
    wait_until 25 events_have '"id":"pd-l1"' \
        || { bad "NOTIFY-VM the Live Update never posted"; stop_app; stop_fakephone; return 1; }
    sleep 3
    shot "live-banner.png"
    result="$(panel_open)"
    [ "$result" = "opened" ] || bad "NOTIFY-VM the status item did not open the panel ($result)"
    result="$(panel_ax)"
    case "$result" in
        *"LIVE"*) ok "NOTIFY-VM the panel has a LIVE section on screen" ;;
        *) bad "NOTIFY-VM no LIVE section in the panel ($(printf '%s' "$result" | head -c 200))" ;;
    esac
    shot_panel_window "live-menu-1.png" >/dev/null 2>&1 || shot "live-menu-1.png"
    sleep 4
    shot_panel_window "live-menu-2.png" >/dev/null 2>&1 || shot "live-menu-2.png"
    result="$(panel_ax)"
    case "$result" in
        *"com.uber"*) ok "NOTIFY-VM the Live row shows its app and progress/clock" ;;
        *) bad "NOTIFY-VM the Live row is not in the panel ($(printf '%s' "$result" | head -c 200))" ;;
    esac
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
    stop_app
    stop_fakephone
    wait_until 5 no_fakephone

    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
}


# check_menubar_vm — the menu bar panel on a real screen, the person's review
# copy (visible run only): online with two playing apps, ringing, dark, the
# Deck's popover and offline. The screenshots go to $WORK/menubar/ and are
# judged by eye; the checks assert the card is on screen and that the ring row
# and the reason line are the ones drawn.
check_menubar_vm() {
    # The real status item panel's AX windows are not exposed on the host's
    # session the way the VM's are; the host's panel proof is menubar-shots.
    if [ "${PD_E2E_IN_VM:-0}" != "1" ] || [ "${VISIBLE:-0}" != "1" ]; then
        skip "MENUBAR-VM" "the panel on a real screen, inside the VM's visible run"
        sleep 1
        return 0
    fi
    clean
    local shots="$WORK/menubar" result device wanted original_style
    original_style="$(defaults read -g AppleInterfaceStyle 2>/dev/null || true)"
    mkdir -p "$shots"
    shot() { screencapture -x "$shots/$1" >/dev/null 2>&1 || true; }
    # The window's own rectangle when AX can see the panel; a full-screen capture
    # keeps the visual record either way.
    shot_panel() {
        shot_panel_window "$1" || {
            shot "$1"
            bad "MENUBAR-VM no AX frame for the panel ($1: full-screen shot instead)"
        }
    }
    # The panel closes on Esc (a window-style extra), so every capture opens it
    # from a known closed state: clicking an open status item would close it.
    close_panel() {
        if [ "$(panel_visible)" = "yes" ]; then
            panel_open >/dev/null
            sleep 0.5
        fi
    }
    # The Settings scene's window title is the selected tab ("Devices",
    # "General", …); its identifier is stable.
    settings_open() {
        local f="$shots/windows-settings.txt"
        control panelwindows "$f" >/dev/null 2>&1 || return 1
        grep -q "com_apple_SwiftUI_Settings_window" "$f"
    }

    FAKE_ARGS="--media" start_fake || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "MENUBAR-VM no device id in the fakephone line"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1 || true
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$PORT" --quit-after 240 --debug-control "$WORK-control"
    wait_until 30 events_have '"t":"apps.list"' \
        || { bad "MENUBAR-VM the session never started"; stop_app; stop_fakephone; return 1; }
    sleep 3

    # The probe's dump/point routes need this run's controller; the real
    # status-item panel is not opened by PanelProbe.
    control panelattach >/dev/null 2>&1 || true

    # (a) online, light, two playing apps: the picker row is there.
    result="$(panel_open)"
    [ "$result" = "opened" ] \
        && ok "MENUBAR-VM the status item opened the panel" \
        || bad "MENUBAR-VM the status item did not open ($result)"
    sleep 1
    shot_panel "panel-online-light.png"
    # The status item's window is the phone card. (Its AX children are not
    # exposed to System Events, so the card is read the way the host checks read
    # it: `real` is that window.)
    if control paneldump real "$WORK/menubar/panel-online.json"; then
        if python3 "$MACOS/scripts/panel-card.py" "$WORK/menubar/panel-online.json" "sessions"; then
            ok "MENUBAR-VM the panel is the phone card: 300 pt, one control per item, the picker with two apps"
        else
            bad "MENUBAR-VM the panel's window is not the phone card"
        fi
    else
        bad "MENUBAR-VM paneldump real: $CONTROL_REPLY"
    fi

    # (a2) the real pointer (visible runs only): moving onto the DND tile
    # changes the picture, and the footer's Settings row opens Settings. A
    # quiet run cannot deliver hover to SwiftUI, so these steps live here.
    local px py
    if control panelpoint real panel.dnd "$WORK/menubar/dnd.pt" \
        && read -r px py < "$WORK/menubar/dnd.pt"; then
        shot_panel "hover-tile-before.png"
        cg_input moveat --x "$px" --y "$py"
        sleep 1
        shot_panel "hover-tile-after.png"
        if cmp -s "$shots/hover-tile-before.png" "$shots/hover-tile-after.png"; then
            bad "MENUBAR-VM moving the real pointer onto the DND tile did not change the picture"
        else
            ok "MENUBAR-VM the real pointer on the DND tile changed the picture"
        fi
    else
        bad "MENUBAR-VM panelpoint real panel.dnd: $CONTROL_REPLY"
    fi
    # A right-click with the panel open closes it first, then opens the menu.
    panel_open >/dev/null
    sleep 0.8
    if [ "$(panel_visible)" = "yes" ]; then
        "$MENUBARBIN" rclick "$APP_PID"
        sleep 1
        [ "$(panel_visible)" = "no" ] \
            && ok "MENUBAR-VM a real right-click closed the open panel first" \
            || bad "MENUBAR-VM the panel stayed open under the menu"
        osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
        sleep 0.5
    else
        bad "MENUBAR-VM the panel did not open for the right-click check"
    fi
    # The icon's menu (CONV-MAC-10): a real right-click opens Settings… ·
    # About Contigua · Quit Contigua. Down highlights the first item and
    # Return runs it, so Settings opens through the menu a person uses. Never
    # Down-Down-Return: that would quit the app.
    close_panel
    "$MENUBARBIN" rclick "$APP_PID"
    sleep 1
    if wait_for_menu shown; then
        ok "[CONV-MAC-10] a real right-click on the icon opened its menu"
    else
        bad "MENUBAR-VM a real right-click opened no menu"
    fi
    cg_input key --keycode 125
    cg_input key --keycode 36
    wait_until 15 settings_open \
        && ok "MENUBAR-VM the menu's Settings… opened Settings" \
        || bad "MENUBAR-VM the menu's Settings… did not open Settings"
        # Close Settings by its own close button, addressed to our PID: never
        # the person's installed app, and never a synthetic ⌘W to whatever is
        # frontmost.
        osascript - "$APP_PID" <<'OSA' >/dev/null 2>&1 || true
on run argv
    set pidText to item 1 of argv
    tell application "System Events"
        set matches to every process whose unix id is (pidText as integer)
        if (count of matches) is 0 then return
        tell item 1 of matches
            set closed to false
            repeat with w in windows
                try
                    if (id of w as string) is "com_apple_SwiftUI_Settings_window" then
                        click button 1 of w
                        set closed to true
                        exit repeat
                    end if
                end try
            end repeat
            if not closed then
                try
                    click button 1 of window "Devices"
                end try
            end if
        end tell
    end tell
end run
OSA
        sleep 1
    # Put the pointer away and reopen the panel from a known closed state.
    cg_input moveat --x 4 --y 4
    close_panel
    panel_open >/dev/null

    # (b) ringing: the Ring row's own click, the phone answers ring.state, and
    # the one row reads Stop Ringing.
    control panelclick real panel.ring \
        && ok "MENUBAR-VM clicked the Ring Phone row" \
        || bad "MENUBAR-VM panelclick real panel.ring: $CONTROL_REPLY"
    wait_until 20 events_have '"ev":"ring"' \
        && ok "MENUBAR-VM the phone rang" \
        || bad "MENUBAR-VM the phone did not ring"
    sleep 1
    shot_panel "panel-ringing-light.png"
    if control paneldump real "$WORK/menubar/panel-ringing.json"; then
        if python3 "$MACOS/scripts/panel-card.py" "$WORK/menubar/panel-ringing.json" "ringing"; then
            ok "MENUBAR-VM the row reads Stop Ringing while the phone rings"
        else
            bad "MENUBAR-VM the ring row did not flip"
        fi
    fi
    control panelclick real panel.ring >/dev/null 2>&1 || true
    wait_until 20 events_have '"ev":"ring","seconds":0' \
        && ok "MENUBAR-VM the phone stopped" \
        || bad "MENUBAR-VM the phone did not stop"

    # (c) dark mode.
    osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1 || true
    close_panel
    result="$(panel_open)"
    sleep 1
    shot_panel "panel-online-dark.png"
    osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1 || true
    close_panel
    sleep 1

    # (d) the Deck's popover: the same card, above the grid. Open our own
    # bundle, not the person's installed app with the same name.
    open "$E2E_BUNDLE" >/dev/null 2>&1 || true
    if control deckpanel; then
        ok "MENUBAR-VM the Deck popover opened"
    else
        bad "MENUBAR-VM deckpanel: $CONTROL_REPLY"
    fi
    sleep 2
    if shot_panel_window "deck-popover-light.png" 320 340; then
        ok "MENUBAR-VM the Deck popover is on screen"
    else
        shot "deck-popover-light.png"
        bad "MENUBAR-VM no Deck popover window (full-screen shot instead)"
    fi
    # Put the switch back where it was (the popover is left open for the shot).
    control panelclick deck panel.dnd >/dev/null 2>&1 || true
    control panelclick deck panel.dnd >/dev/null 2>&1 || true

    # (e) offline: the phone goes away; the card stays, dimmed, with one reason.
    stop_fakephone
    wait_until 10 no_fakephone
    sleep 18
    close_panel
    result="$(panel_open)"
    sleep 1
    shot_panel "panel-offline-light.png"
    result="$(panel_ax)"
    # The reason is no longer a floating line: each disabled control carries
    # the short line in its subtitle, and the full sentence is its help tag and
    # VoiceOver hint (CONV-MAC-26, CONV-MAC-21).
    case "$result" in
        *"Connect your phone to use these."*) ok "MENUBAR-VM the disabled controls' help carries the full reason" ;;
        *) bad "MENUBAR-VM no offline reason in a control's help ($(printf '%s' "$result" | head -c 200))" ;;
    esac
    case "$result" in
        *"Offline"*) ok "MENUBAR-VM the header says Offline" ;;
        *) bad "MENUBAR-VM the header does not say Offline" ;;
    esac

    stop_app
    if [ "$original_style" = "Dark" ]; then
        osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1 || true
    else
        osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1 || true
    fi
    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1
}

# --- DECK: the app grid's icon kinds ---------------------------------------
icons_kind() { grep '"ev":"icon"' "$WORK/events.jsonl" 2>/dev/null | grep -c "$1" || true; }

have_layered_icons() { [ "$(icons_kind '"layers":true')" -ge 4 ]; }
have_flat_icons() { [ "$(icons_kind '"layers":false')" -ge 5 ]; }

# The icon size the grid last drew (--debug-deck-grid's geometry line), for
# DECK-6's stored-value steps.
deck_stored_zoom() {
    python3 - "$WORK/deck-grid.jsonl" <<'PY'
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
blocks = [line for line in lines if "cap" in line]
print(blocks[-1]["zoom"] if blocks else "")
PY
}

# A fresh profile's Deck is the default, 125 % (DECK-6).
deck_at_the_default_zoom() { [ "$(deck_stored_zoom)" = "1.25" ]; }

# check_deck — the grid gets both kinds of icon the phone can send: fakephone
# answers fg/bg layers for every 3rd app and a flat PNG for the rest. The Deck
# shows both without errors and the grid is captured for the human (glass is
# judged by eye in .work/glass/; this check only asserts the wire and the
# log say both kinds arrived).
# --- The Deck as a start page (ISS-74, DECK-26…DECK-31) ---------------------
#
# The person's correction is the assertion: every section sits on All Apps'
# columns, and its header starts at the grid's leading edge, at four widths.
# The drawn frames come from the layout pass (--debug-deck-sections), not from
# the model. Pins are seeded through the Pin item's own controller call (a quiet
# run cannot click a context menu) and must survive a relaunch; the light and
# dark shots are the visual record for the reviewer.
check_deckstart() {
    clean
    local sections="$WORK/deck-sections.jsonl" shots="$SHOTS/deckstart"
    # Eight pins, none of them in the three open windows: the ⌘4 proof below
    # needs the first pin to open a new window, not raise one.
    local -a pins=(com.spotify.music com.android.camera2 com.google.android.gm com.android.dialer
                   com.google.android.apps.messaging com.google.android.apps.maps
                   com.android.vending org.telegram.messenger)
    local pinned_order
    pinned_order="$(IFS=,; echo "${pins[*]}")"
    mkdir -p "$shots" "$WORK-control"

    FAKE_ARGS="--demo-apps 40 --rail-letters" start_fake || return 1
    FAKE_ARGS=""

    deckstart_launch() {  # deckstart_launch LIGHT|DARK KINDS
        [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null && stop_app
        sleep 1
        launch --debug-control "$WORK-control" --connect "127.0.0.1:$PORT" \
            --debug-deck-sections "$sections" --appearance "$1" \
            --open com.android.settings,com.android.chrome,com.whatsapp --quit-after 600
        wait_until 30 events_have '"t":"apps.list"' || bad "DECKSTART $1 no apps.list"
        wait_until 30 python3 "$MACOS/scripts/deckstart-sections.py" "$sections" \
            kinds "$2" >/dev/null 2>&1 \
            && ok "DECKSTART $1 the page reads $2" \
            || bad "DECKSTART $1 the page's sections are not $2 ($(python3 "$MACOS/scripts/deckstart-sections.py" "$sections" kinds "$2" 2>&1))"
        sleep 2
    }
    shot_deck() {  # shot_deck NAME
        local id
        id="$(await_window '$4 >= 600')" \
            && screencapture -x -l"$id" "$shots/$1.png" >/dev/null 2>&1 \
            && say "shot: $shots/$1.png" \
            || bad "DECKSTART no Deck window for $1"
    }
    section_check() {  # section_check WIDTH
        control deck-size "$1" 700 >/dev/null || bad "DECKSTART deck-size $1: $CONTROL_REPLY"
        sleep 1.2
        if python3 "$MACOS/scripts/deckstart-sections.py" "$sections" aligned "$1"; then
            ok "[DECK-26] at $1 pt every section is on All Apps' columns, its header at the grid's edge"
        else
            bad "[DECK-26] at $1 pt the sections are not aligned ($(python3 "$MACOS/scripts/deckstart-sections.py" "$sections" aligned "$1" 2>&1))"
        fi
    }

    deckstart_launch light "open:3,all:*"
    # The Open section follows the windows, front first (DECK-27).
    if python3 "$MACOS/scripts/deckstart-sections.py" "$sections" order open \
        "com.whatsapp,com.android.chrome,com.android.settings"; then
        ok "[DECK-27] Open on this Mac lists the three windows front first"
    else
        bad "[DECK-27] Open on this Mac is not the open windows ($(python3 "$MACOS/scripts/deckstart-sections.py" "$sections" order open "com.whatsapp,com.android.chrome,com.android.settings" 2>&1))"
    fi

    local n
    for n in "${pins[@]}"; do
        control deckpin "$n" || bad "DECKSTART deckpin $n: $CONTROL_REPLY"
    done
    wait_until 10 python3 "$MACOS/scripts/deckstart-sections.py" "$sections" order pinned "$pinned_order" >/dev/null 2>&1 \
        && ok "[DECK-28] the eight pins sit in pin order" \
        || bad "[DECK-28] the Pinned row is not the pin order ($(python3 "$MACOS/scripts/deckstart-sections.py" "$sections" order pinned "$pinned_order" 2>&1))"
    # The ninth pin: the item is disabled; the action refuses it too.
    if control deckpin com.google.android.youtube; then
        bad "[DECK-28] a ninth pin was taken"
    else
        ok "[DECK-28] the ninth pin is refused ($CONTROL_REPLY)"
    fi
    wait_until 10 python3 "$MACOS/scripts/deckstart-sections.py" "$sections" order pinned "$pinned_order" >/dev/null 2>&1 \
        && ok "[DECK-28] the refused ninth pin left the eight in order" \
        || bad "[DECK-28] the refused ninth pin changed the row"

    # The windows step back so the page is the shot; they are still windows on
    # this Mac, so the row keeps its three (DECK-27).
    control open --minimize-stream 1:0 --minimize-stream 2:0 --minimize-stream 3:0 >/dev/null \
        || bad "DECKSTART minimize the open windows: $CONTROL_REPLY"
    sleep 1.5

    control deck-size 1000 700 >/dev/null || bad "DECKSTART deck-size 1000: $CONTROL_REPLY"
    sleep 1.2
    shot_deck "deckstart-1000-light"
    control deck-size 760 600 >/dev/null || bad "DECKSTART deck-size 760 (light): $CONTROL_REPLY"
    sleep 1
    shot_deck "deckstart-760-light"
    control deck-size 640 600 >/dev/null || bad "DECKSTART deck-size 640 (light): $CONTROL_REPLY"
    sleep 1
    shot_deck "deckstart-640-light"
    section_check 760
    section_check 1000
    section_check 1200
    section_check 1600
    control deck-size 1000 700 >/dev/null || bad "DECKSTART deck-size 1000 (restore): $CONTROL_REPLY"

    # A search collapses the page to its results, as today (DECK-26).
    control deckquery cam >/dev/null || bad "DECKSTART deckquery cam: $CONTROL_REPLY"
    wait_until 10 python3 "$MACOS/scripts/deckstart-sections.py" "$sections" search >/dev/null 2>&1 \
        && ok "[DECK-26] while searching the sections collapse to the results alone" \
        || bad "[DECK-26] the sections stayed while searching ($(python3 "$MACOS/scripts/deckstart-sections.py" "$sections" search 2>&1))"
    control deckquery "" >/dev/null || bad "DECKSTART deckquery clear: $CONTROL_REPLY"
    sleep 1

    # The pins are this Mac's: a relaunch reads the same eight in order (DECK-28).
    deckstart_launch dark "open:3,pinned:8,all:*"
    # The windows step back so the page is the shot (the same step the light
    # pass takes; a launch-time --minimize-stream still caught stream 1).
    control open --minimize-stream 1:0 --minimize-stream 2:0 --minimize-stream 3:0 >/dev/null \
        || bad "DECKSTART minimize the open windows (dark): $CONTROL_REPLY"
    sleep 1.5
    shot_deck "deckstart-1000-dark"
    control deck-size 760 600 >/dev/null || bad "DECKSTART deck-size 760: $CONTROL_REPLY"
    sleep 1
    shot_deck "deckstart-760-dark"

    # [DECK-29] ⌘1–⌘9 open the first nine visible tiles, sections included:
    # ⌘1 raises the first open window (no second window.open), ⌘4 opens the
    # first pin (a new window.open for it).
    control deckfocus grid >/dev/null || bad "DECKSTART deckfocus: $CONTROL_REPLY"
    local opens_before wins_before
    opens_before="$(count_events '"t":"window.open"' | head -1)"
    wins_before="$(windows | wc -l | tr -d ' ')"
    control key cmd+1 || bad "DECKSTART key cmd+1: $CONTROL_REPLY"
    # The raise brings the window back from the Dock: a minimised window is not
    # in the CGWindow list, so the count grows with no window.open sent.
    if wait_until 8 eval '[ "$(windows | wc -l | tr -d " ")" -gt '"$wins_before"' ]'; then
        ok "[DECK-29] ⌘1 raised the first open tile (its window is up again)"
    else
        bad "[DECK-29] ⌘1 raised nothing"
    fi
    [ "$(count_events '"t":"window.open"' | head -1)" = "$opens_before" ] \
        && ok "[DECK-29] the raise sent no second window.open" \
        || bad "[DECK-29] ⌘1 opened a second window"
    # The raise made the stream window key; the Deck takes the keys again.
    control deckfocus grid >/dev/null || bad "DECKSTART deckfocus (⌘4): $CONTROL_REPLY"
    control key cmd+4 || bad "DECKSTART key cmd+4: $CONTROL_REPLY"
    if wait_until 15 [ "$(count_events '"t":"window.open"' | head -1)" -gt "$opens_before" ]; then
        if grep '"t":"window.open"' "$WORK/events.jsonl" | tail -1 | grep -qF 'com.spotify.music'; then
            ok "[DECK-29] ⌘4 opened the first pinned tile"
        else
            bad "[DECK-29] ⌘4 opened $(grep '"t":"window.open"' "$WORK/events.jsonl" | tail -1)"
        fi
    else
        bad "[DECK-29] ⌘4 opened nothing"
    fi
    control open --close-stream 4:0 >/dev/null 2>&1 || true
    sleep 2

    # [DECK-31] Offline dims the whole page as one: the chip says Offline, the
    # page under it is one dimmed layer (the shot is the record).
    stop_fakephone
    control deckpanel >/dev/null || bad "DECKSTART deckpanel (offline): $CONTROL_REPLY"
    deck_offline() {
        control paneldump deck "$WORK/deckstart-panel.json" >/dev/null 2>&1 || return 1
        python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status") == "Offline" else 1)' \
            "$WORK/deckstart-panel.json"
    }
    if wait_until 60 deck_offline; then
        ok "[DECK-31] the deck says Offline when the phone is away"
        control deckpanelclose >/dev/null
        sleep 1
        shot_deck "deckstart-offline-dark"
    else
        bad "[DECK-31] the deck never said Offline ($(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status"))' "$WORK/deckstart-panel.json" 2>/dev/null))"
    fi
    stop_app
    stop_fakephone
}

# The DECK-7 rail on its own, for the VM: the deck check's setup plus the rail
# steps only (DECK-4/5/19/20 assume a screen bigger than the 1024x768 guest).
# railpress_shots — the ISS-94 visual record on the run's own (quiet, virtual)
# display: the press and the click's linger at 760 and 1000 wide, light and
# dark. PD_RAILPRESS_SHOT_TAG names the build (feat/main); PD_RAILPRESS_SHOT_MODE
# hover captures main's hover-driven emphasis instead (it has no press state).
# The shots go to $ROOT/.work/railpress/shots/ (gitignored) and are judged by eye.
railpress_shots() {
    local out="$ROOT/.work/railpress/shots"
    local tag="${PD_RAILPRESS_SHOT_TAG:-feat}"
    local mode="${PD_RAILPRESS_SHOT_MODE:-press}"
    mkdir -p "$out"
    # The shared app is still running after `stop_app` (it only resets it), and
    # a second instance would exit at once. End it and its phone, then serve
    # the shots from a fresh phone with the same state and identity.
    end_shared
    FAKE_ARGS="--demo-apps 60 --rail-letters" start_fake || return 1
    FAKE_ARGS=""
    local appearance width id grid since state
    probe_state() {
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("state", ""))' "$1"
    }
    # railshot_settle SINCE GRID — a new `picked` accent line: the pick's jump
    # reached its landing. The shot is read only after this.
    railshot_settle() {
        local tries=60
        while [ "$tries" -gt 0 ]; do
            if tail -n "+$(( $1 + 1 ))" "$2" 2>/dev/null \
                | grep -q '"railAccent".*"state":"picked"'; then
                return 0
            fi
            sleep 0.1
            tries=$((tries - 1))
        done
        return 1
    }
    shot_probe() {  # shot_probe NAME — the machine's state at the shot's moment
        control deckrailemph "$out/$1.json" \
            || { bad "RAILSHOTS $1: deckrailemph: $CONTROL_REPLY"; return 1; }
        say "RAILSHOTS $1: state $(probe_state "$out/$1.json")"
    }
    for appearance in light dark; do
        for width in 760 1000; do
            rm -rf "$WORK-control"
            mkdir -p "$WORK-control"
            grid="$WORK/rail-shots-$appearance-$width.jsonl"
            launch --connect "127.0.0.1:$PORT" --appearance "$appearance" \
                --debug-control "$WORK-control" --debug-deck-grid "$grid" \
                --debug-deck-emphasis --debug-motion full --quit-after 150
            if ! wait_until 40 events_have '"t":"apps.list"'; then
                bad "RAILSHOTS $appearance $width: no apps.list"
                stop_app
                continue
            fi
            # Wait for the phone's own rendered icons, never a placeholder or
            # a cover: the grid dump says when a cell's icon landed.
            if ! wait_until 40 grep -q '"icon":"rendered"' "$grid"; then
                bad "RAILSHOTS $appearance $width: no rendered icons"
                stop_app
                continue
            fi
            control deck-size "$width" 600 || bad "RAILSHOTS deck-size $width: $CONTROL_REPLY"
            sleep 2
            id="$(await_window "\$4 >= $((width - 1)) && \$4 <= $((width + 1))")" \
                || { bad "RAILSHOTS no Deck window at $width"; stop_app; continue; }
            if [ "$mode" = "hover" ]; then
                # Main's emphasis is hover-driven and it has no click verb:
                # scroll to C with the old `deck-rail` (the same landing the
                # branch's press reaches), then hover it.
                since="$(wc -l < "$grid" | tr -d ' ')"
                control deck-rail C || bad "RAILSHOTS deck-rail C (main): $CONTROL_REPLY"
                railshot_settle "$since" "$grid" || bad "RAILSHOTS main C jump never settled"
                control deckrailenter C || bad "RAILSHOTS enter C: $CONTROL_REPLY"
                sleep 0.8
                shot_probe "hover-$tag-$appearance-$width"
                screencapture -x -o -l"$id" "$out/hover-$tag-$appearance-$width.png" \
                    && say "shot: $out/hover-$tag-$appearance-$width.png"
                control deckrailleave
            else
                since="$(wc -l < "$grid" | tr -d ' ')"
                control deckrailpress C || bad "RAILSHOTS press C: $CONTROL_REPLY"
                railshot_settle "$since" "$grid" || bad "RAILSHOTS the C jump never settled"
                sleep 0.2
                shot_probe "pressed-$tag-$appearance-$width"
                state="$(probe_state "$out/pressed-$tag-$appearance-$width.json")"
                [ "$state" = "pressed" ] \
                    || bad "RAILSHOTS pressed-$tag-$appearance-$width: the machine is $state, not pressed"
                screencapture -x -o -l"$id" "$out/pressed-$tag-$appearance-$width.png" \
                    && say "shot: $out/pressed-$tag-$appearance-$width.png"
                control deckrailup C || bad "RAILSHOTS up C: $CONTROL_REPLY"
                sleep 0.2
                control deckrailclick C 80 || bad "RAILSHOTS click C: $CONTROL_REPLY"
                sleep 0.15
                shot_probe "linger-$tag-$appearance-$width"
                state="$(probe_state "$out/linger-$tag-$appearance-$width.json")"
                [ "$state" = "lingering" ] \
                    || bad "RAILSHOTS linger-$tag-$appearance-$width: the machine is $state, not lingering"
                screencapture -x -o -l"$id" "$out/linger-$tag-$appearance-$width.png" \
                    && say "shot: $out/linger-$tag-$appearance-$width.png"
            fi
            sleep 0.3
            stop_app
        done
    done
}

# Quiet, the positions are forced (deckrailenter / deckrailmove) and the same
# shots are what proves rail-glyph.py before the boot; visible, the real pointer
# comes onto the rail at M, sideways there, down to Z and #, and out again,
# dark and then light.
check_deckrail() {
    clean
    # The host proof of the on-screen move: start from a stored frame whose rail
    # stands past the virtual display's right edge (as the VM's restored frame
    # did). PD_DECKRAIL_NO_MOVE=1 then shows gate A failing before the move.
    if [ -n "${PD_DECKRAIL_START_FRAME:-}" ]; then
        defaults write "$DEFAULTS_SUITE" deck.windowFrame "$PD_DECKRAIL_START_FRAME"
    fi
    FAKE_ARGS="--demo-apps 60 --rail-letters" start_fake || return 1
    FAKE_ARGS=""
    # The VM guest keeps its own Reduce Motion; the test hook makes the app's
    # effective setting full so the fisheye (the proof) works here.
    launch_shared --connect "127.0.0.1:$PORT" --debug-deck-grid "$WORK/deck-grid.jsonl" \
        --debug-deck-emphasis --debug-motion full
    wait_until 30 events_have '"t":"apps.list"' \
        && ok "DECKRAIL the app list was requested" || bad "DECKRAIL no apps.list"
    wait_until 30 grep -q '"count":' "$WORK/deck-grid.jsonl" \
        && ok "DECKRAIL the grid drew its cells" || bad "DECKRAIL no grid dump"
    # A stored frame cannot put the rail off-screen (placement rejects one that
    # leaves the screen); moving the window first and then growing it can, as
    # the guest's restored small frame did. PD_DECKRAIL_NO_MOVE=1 then shows
    # gate A failing before the move is allowed.
    if [ -n "${PD_DECKRAIL_START_X:-}" ]; then
        control deck-move "$PD_DECKRAIL_START_X" 150 || bad "DECKRAIL deck-move (start): $CONTROL_REPLY"
        sleep 1
    fi
    control deck-size 1000 625 || bad "DECKRAIL deck-size 1000 625: $CONTROL_REPLY"
    sleep 1
    # The host proof that the on-screen move works: start with the window's rail
    # past the virtual display's right edge (PD_DECKRAIL_START_X), and
    # PD_DECKRAIL_NO_MOVE=1 shows gate A failing before the move.

    local railshots="$WORK/deck-rail-shots"
    mkdir -p "$railshots"
    shot_rail() {
        local id
        id="$(await_window '$4 >= 600')" \
            && screencapture -x -l"$id" "$railshots/$1" >/dev/null 2>&1 \
            && say "shot: $railshots/$1" \
            || bad "DECKRAIL no Deck window for $1"
    }
    local dx px py mcentre ncentre ax ay aw wx wy sx sy scale since settle
    local deadx glyphx jy winw edgex hitrect railhit_top railhit_bottom fx fy fw fh pitch
    if [ "$VISIBLE" = 1 ]; then
        # Park the real pointer outside the Deck before any forced step.
        cg_input moveat --x 5 --y 5
        sleep 0.5
    fi
    shot_rail rail-rest.png
    # The rest geometry: the rail's top-left (window and screen points, and the
    # backing scale) and its slots, so a visible run places the pointer on the
    # drawn slot's centre instead of guessing rows.
    if control deckrailanchor "$railshots/anchor.pt" && read -r wx wy sx sy scale < "$railshots/anchor.pt"; then
        ok "DECKRAIL the rail is at window ($wx,$wy), screen ($sx,$sy), scale $scale"
        # A restored frame can put the rail past the screen's right edge (the
        # guest is 1024 pt wide) and a real pointer cannot reach off-screen:
        # bring the window back inside, then read its place again.
        if control screens "$railshots/screens.txt"; then
            python3 - "$railshots/screens.txt" "$sx" "$sy" "$scale" > "$railshots/move.txt" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
sx, sy, scale = float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
rail_width = 26
deck = None
screens = []
for line in lines:
    match = re.match(r"deck=(-?[0-9]+),(-?[0-9]+)-([0-9]+)x([0-9]+)", line)
    if match:
        deck = tuple(float(match.group(i)) for i in range(1, 5))
    match = re.match(r"screen \d+ frame=(-?[0-9.]+),(-?[0-9.]+)-([0-9.]+)x([0-9.]+)"
                     r" visible=(-?[0-9.]+),(-?[0-9.]+)-([0-9.]+)x([0-9.]+)", line)
    if match:
        screens.append(tuple(float(match.group(i)) for i in range(1, 9)))
if not deck or not screens:
    print(0, 0); sys.exit(0)
def overlap(screen):
    x, y, w, h = screen[:4]
    return max(0, min(x + w, deck[0] + deck[2]) - max(x, deck[0])) \
        * max(0, min(y + h, deck[1] + deck[3]) - max(y, deck[1]))
vx, vy, vw, vh = max(screens, key=overlap)[4:]
# The rail's column must sit on the visible frame; move the window sideways,
# never vertically (the window's height already fits or it is the guest's).
if sx + rail_width > vx + vw - 2:
    target = vx + vw - 2 - rail_width
    print(int(round(deck[0] + (target - sx))), int(round(deck[1])))
elif sx < vx:
    print(int(round(deck[0] + (vx - sx))), int(round(deck[1])))
else:
    print(0, 0)
PY
            read -r movex movey < "$railshots/move.txt"
            if [ "${movex:-0}" != 0 ] || [ "${movey:-0}" != 0 ]; then
                if [ "${PD_DECKRAIL_NO_MOVE:-0}" = 1 ]; then
                    say "DECKRAIL not moving the window (PD_DECKRAIL_NO_MOVE=1)"
                    movex=0
                fi
            fi
            if [ "${movex:-0}" != 0 ] || [ "${movey:-0}" != 0 ]; then
                control deck-move "$movex" "$movey" || bad "DECKRAIL deck-move: $CONTROL_REPLY"
                sleep 1
                control deckrailanchor "$railshots/anchor.pt" \
                    && read -r wx wy sx sy scale < "$railshots/anchor.pt"
                ok "DECKRAIL moved the window in: the rail is now at screen ($sx,$sy)"
            fi
        fi
    else
        bad "DECKRAIL deckrailanchor: $CONTROL_REPLY"
    fi
    if control deckrailslots "$railshots/rest.json"; then
        mcentre="$(python3 - "$railshots/rest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
m = [s for s in d["slots"] if s["first"] == 12][0]
print((m["y"] + m["height"] / 2) if d["state"] == "away" else (m["glyphTop"] + m["glyphBottom"]) / 2)
PY
)"
        local railheight
        railheight="$(python3 -c "import json;print(json.load(open('$railshots/rest.json'))['railHeight'])")"
        ok "DECKRAIL the rail is $(printf '%.1f' "$railheight") pt tall, M's centre $(printf '%.1f' "$mcentre") pt down"
    else
        bad "DECKRAIL deckrailslots (rest): $CONTROL_REPLY"
    fi
    # Gate A: the rail must stand wholly inside the screen's visible frame. The
    # real pointer cannot reach a rail past the edge, and a forced position then
    # draws a tag at rest that reads as a magnified letter.
    local onscreen=1
    if control screens "$railshots/screens.txt"; then
        if ! python3 - "$railshots/screens.txt" "$sx" "$sy" "$scale" "$railheight" > "$railshots/onscreen.txt" 2>&1 <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
sx, sy, scale, railh = (float(sys.argv[i]) for i in range(2, 6))
rail_width = 26
deck = None
screens = []
for line in lines:
    match = re.match(r"deck=(-?[0-9]+),(-?[0-9]+)-([0-9]+)x([0-9]+)", line)
    if match:
        deck = tuple(float(match.group(i)) for i in range(1, 5))
    match = re.match(r"screen \d+ frame=(-?[0-9.]+),(-?[0-9.]+)-([0-9.]+)x([0-9.]+)"
                     r" visible=(-?[0-9.]+),(-?[0-9.]+)-([0-9.]+)x([0-9.]+)", line)
    if match:
        screens.append(tuple(float(match.group(i)) for i in range(1, 9)))
if not deck or not screens:
    print("no screens report"); sys.exit(1)
def overlap(screen):
    x, y, w, h = screen[:4]
    return max(0, min(x + w, deck[0] + deck[2]) - max(x, deck[0])) \
        * max(0, min(y + h, deck[1] + deck[3]) - max(y, deck[1]))
vx, vy, vw, vh = max(screens, key=overlap)[4:]
# The rail's point is in Quartz space (top-left origin of the main screen); the
# screens report is AppKit space (bottom-left). They agree only for a screen
# whose top is the main screen's top, so convert: a closed lid or a display
# arranged above or below moved the run's display and failed this gate.
main_h = next(s for s in screens if s[0] == 0 and s[1] == 0)[3]
bottom = main_h - sy - railh
inside = sx >= vx and bottom >= vy and sx + rail_width <= vx + vw and main_h - sy <= vy + vh
print("rail x %.0f..%.0f y %.0f..%.0f on the visible frame x %.0f..%.0f y %.0f..%.0f"
      % (sx, sx + rail_width, bottom, bottom + railh, vx, vx + vw, vy, vy + vh))
sys.exit(0 if inside else 1)
PY
        then
            onscreen=0
            bad "DECKRAIL gate A: the rail is not wholly on the screen ($(cat "$railshots/onscreen.txt"))"
        else
            ok "DECKRAIL gate A: the rail is wholly on the screen ($(cat "$railshots/onscreen.txt"))"
        fi
    else
        onscreen=0
        bad "DECKRAIL gate A: no screens report ($CONTROL_REPLY)"
    fi
    # Gate B: effective Reduce Motion off (its plain tint would read as a tag).
    if python3 "$MACOS/scripts/deck-rail-slots.py" "$railshots/rest.json" motion-off > "$WORK/rail-motion.txt" 2>&1; then
        ok "DECKRAIL gate B: effective Reduce Motion is off ($(cat "$WORK/rail-motion.txt"))"
    else
        onscreen=0
        bad "DECKRAIL gate B: effective Reduce Motion is on (--debug-motion full did not reach the app)"
    fi
    if [ "$onscreen" = 1 ]; then
        # Gate C: the forced enter at M gives the pure layout (equal gaps, the
        # slot under the pointer at the centre, M's tag), with the real pointer
        # parked off the window (a visible run).
        if [ "$VISIBLE" = 1 ]; then cg_input moveat --x 5 --y 5; sleep 0.5; fi
        control deckrailleave
        sleep 0.3
        control deckrailenter M || bad "DECKRAIL gate C: deckrailenter M: $CONTROL_REPLY"
        sleep 0.4
        if control deckrailslots "$WORK/rail-gate.json" \
            && python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-gate.json" gaps >/dev/null \
            && python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-gate.json" centre >/dev/null \
            && python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-gate.json" tag:M >/dev/null; then
            ok "DECKRAIL gate C: the forced enter at M gives the pure layout"
        else
            onscreen=0
            bad "DECKRAIL gate C: the forced enter at M does not match the pure layout"
        fi
        # Gate D: the forced M shot is 2.2x the rest shot's M (+/-15%).
        shot_rail rail-forced-m.png
        python3 "$MACOS/scripts/rail-glyph.py" "$railshots/rail-forced-m.png" 1000 625 "$scale" "$wx" > "$railshots/forced.txt" 2>&1
        python3 "$MACOS/scripts/rail-glyph.py" "$railshots/rail-rest.png" 1000 625 "$scale" "$wx" > "$railshots/rest-glyph.txt" 2>&1
        local forced rest_peak
        forced="$(sed -n 's/^peak //p' "$railshots/forced.txt")"
        rest_peak="$(sed -n 's/^peak //p' "$railshots/rest-glyph.txt")"
        if [ -n "$forced" ] && [ -n "$rest_peak" ] \
            && python3 -c "import sys; f=float('$forced'); r=float('$rest_peak'); sys.exit(0 if r > 0 and abs(f/r - 2.2) <= 2.2*0.15 else 1)"; then
            ok "DECKRAIL gate D: the forced M is $(python3 -c "print(round(float('$forced')/float('$rest_peak'),2))") x the rest"
        else
            onscreen=0
            bad "DECKRAIL gate D: the forced M shot is not 2.2x the rest (forced '$forced', rest '$rest_peak')"
        fi
        control deckrailleave
        sleep 0.3
    fi
    # M's, Z's and #'s drawn centres at rest: where a visible run puts the
    # pointer, and the rows a move names in a quiet one.
    local zcentre hcentre
    if control deckrailslots "$railshots/rest.json"; then
        read -r zcentre hcentre < <(python3 - "$railshots/rest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
by_index = {s["first"]: s for s in d["slots"]}
def centre(index):
    s = by_index[index]
    return (s["glyphTop"] + s["glyphBottom"]) / 2
print(centre(25), centre(26))
PY
)
    else
        bad "DECKRAIL deckrailslots (rest, centres): $CONTROL_REPLY"
    fi
    if [ "$onscreen" = 1 ]; then
        # The enter set, in order: enter at M, sideways at M (visible only: the
        # scale never depends on x), down to Z and #, out to the left. Each step
        # reads the drawn slots, so the frozen ends are checked on the way.
        # Enter at M: the real pointer moves onto the rail, or the quiet run
        # forces the same event; then the drawn state must say M. A shot is a
        # record, never the proof.
        deckrail_enter_m() {
            if [ "$VISIBLE" = 1 ]; then
                cg_input moveat --x "$(python3 -c "print(round($sx + 13))")" \
                    --y "$(python3 -c "print(round($sy + $mcentre))")"
                sleep 0.8
            else
                control deckrailenter M || bad "DECKRAIL deckrailenter M: $CONTROL_REPLY"
                sleep 0.5
            fi
        }
        deckrail_check_m() {
            local file="$1" label="$2"
            if control deckrailslots "$file"; then
                python3 "$MACOS/scripts/deck-rail-slots.py" "$file" centre \
                    && ok "[DECK-7] $label: the drawn M is under the pointer" \
                    || bad "[DECK-7] $label: the drawn M is not under the pointer"
                python3 "$MACOS/scripts/deck-rail-slots.py" "$file" tag:M \
                    && ok "[DECK-7] $label: the tag names M" \
                    || bad "[DECK-7] $label: the tag does not name M"
            else
                bad "DECKRAIL deckrailslots ($label): $CONTROL_REPLY"
            fi
        }
        if [ "$VISIBLE" = 1 ]; then
            # From outside the arc's room, straight onto the rail at M.
            cg_input moveat --x "$(python3 -c "print(round($sx - 200))")" \
                --y "$(python3 -c "print(round($sy + $mcentre))")"
            sleep 0.5
        fi
        deckrail_enter_m
        deckrail_check_m "$WORK/rail-enter.json" "the enter at M"
        if control deckrailslots "$WORK/rail-enter.json"; then
            python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-enter.json" gaps \
                && ok "[DECK-7] on the enter the gaps are equal and the rest gap's" \
                || bad "[DECK-7] the enter's gaps are not equal or not the rest gap's"
        else
            bad "DECKRAIL deckrailslots (enter): $CONTROL_REPLY"
        fi
        shot_rail rail-enter-m.png
        if [ "$VISIBLE" = 1 ]; then
            # Sideways inside the column at M: leading x, then trailing x.
            local side px
            for side in leading trailing; do
                if [ "$side" = leading ]; then
                    px="$(python3 -c "print(round($sx + 3))")"
                else
                    px="$(python3 -c "print(round($sx + 23))")"
                fi
                cg_input moveat --x "$px" --y "$(python3 -c "print(round($sy + $mcentre))")"
                sleep 0.6
                shot_rail "rail-side-$side.png"
                control deckrailslots "$WORK/rail-side-$side.json" \
                    || bad "DECKRAIL deckrailslots (side $side): $CONTROL_REPLY"
            done
            if control deckrailslots "$WORK/rail-side-trailing.json" \
                && python3 - "$WORK/rail-enter.json" "$WORK/rail-side-trailing.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
def m(d):
    return [s for s in d["slots"] if s["first"] == 12][0]["scale"]
print("M %.3f on the enter, %.3f at the column's trailing x" % (m(a), m(b)))
sys.exit(0 if abs(m(b) / m(a) - 1) <= 0.05 else 1)
PY
            then
                ok "[DECK-7] sideways at M the scale does not change (+/-5%)"
            else
                bad "[DECK-7] moving sideways at M changed the scale"
            fi
        else
            skip_visible "DECK-7 sideways at M (the scale never depends on x)"
        fi
        # Down the rail to Z, then #: A's top and #'s bottom do not move.
        local target
        for target in Z '#'; do
            if [ "$target" = Z ]; then
                py="$(python3 -c "print(round($sy + $zcentre))")"
                shot="rail-down-z.png"
                file="$WORK/rail-z.json"
            else
                py="$(python3 -c "print(round($sy + $hcentre))")"
                shot="rail-down-hash.png"
                file="$WORK/rail-hash.json"
            fi
            if [ "$VISIBLE" = 1 ]; then
                cg_input moveat --x "$(python3 -c "print(round($sx + 13))")" --y "$py"
                sleep 0.6
            else
                control deckrailmove "$target" || bad "DECKRAIL deckrailmove $target: $CONTROL_REPLY"
                sleep 0.6
            fi
            shot_rail "$shot"
            if control deckrailslots "$file"; then
                python3 "$MACOS/scripts/deck-rail-slots.py" "$file" frozen:"$WORK/rail-enter.json" \
                    && ok "[DECK-7] moving to $target leaves A's top and #'s bottom put" \
                    || bad "[DECK-7] moving to $target moved the frozen ends"
                python3 "$MACOS/scripts/deck-rail-slots.py" "$file" centre \
                    && ok "[DECK-7] the move to $target puts the drawn $target under the pointer" \
                    || bad "[DECK-7] the move to $target does not put it under the pointer"
                python3 "$MACOS/scripts/deck-rail-slots.py" "$file" tag:"$target" \
                    && ok "[DECK-7] the move to $target names it" \
                    || bad "[DECK-7] the move to $target does not name it"
                python3 "$MACOS/scripts/deck-rail-slots.py" "$file" gaps \
                    && ok "[DECK-7] the gaps stay equal and the rest gap's at $target" \
                    || bad "[DECK-7] the gaps at $target are not equal or not the rest gap's"
            else
                bad "DECKRAIL deckrailslots ($target): $CONTROL_REPLY"
            fi
        done
        # The light appearance, proved not posed: switch it, let the cross-fade
        # settle, then enter at M and require the drawn state before the shot.
        if [ "$VISIBLE" = 1 ]; then
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to false' >/dev/null 2>&1 || true
            sleep 2
            control deckrailleave
            sleep 0.3
            deckrail_enter_m
            deckrail_check_m "$WORK/rail-light.json" "the light enter at M"
            shot_rail rail-enter-m-light.png
            osascript -e 'tell application "System Events" to tell appearance preferences to set dark mode to true' >/dev/null 2>&1 || true
            sleep 1
        fi
        # Out to the left, past the arc's room: back at rest within 0.3 s.
        if [ "$VISIBLE" = 1 ]; then
            cg_input moveat --x "$(python3 -c "print(round($sx - 200))")" \
                --y "$(python3 -c "print(round($sy + $mcentre))")"
            sleep 0.3
        else
            control deckrailleave
            sleep 0.3
        fi
        if control deckrailslots "$WORK/rail-away.json"; then
            python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-away.json" rest \
                && ok "[DECK-7] the rail is a rest box at the drawn pitch 0.3 s after the pointer leaves" \
                || bad "[DECK-7] the rail is not at rest 0.3 s after the pointer left"
        else
            bad "DECKRAIL deckrailslots (away): $CONTROL_REPLY"
        fi
        shot_rail rail-away.png
        if python3 "$MACOS/scripts/rail-glyph.py" "$railshots" 1000 625 "$scale" "$wx" > "$WORK/rail-glyph.txt" 2>&1; then
            ok "DECKRAIL the letter sizes and A's top match the pure layout ($(grep -m1 '^A.s top' "$WORK/rail-glyph.txt"))"
        else
            bad "DECKRAIL the letter sizes or A's top are off: $(tr '\n' ' ' < "$WORK/rail-glyph.txt")"
        fi
        sed -n 's/^/  /p' "$WORK/rail-glyph.txt" | head -14
    else
        bad "DECKRAIL a gate failed; the real-pointer steps are skipped"
    fi
    # Nothing clipped: with the pointer on the first and the last letter, every
    # slot and every glyph is inside the content inset.
    local edge
    for edge in A '#'; do
        control deckrailleave
        sleep 0.3
        control deckrailenter "$edge" || bad "DECKRAIL deckrailenter $edge: $CONTROL_REPLY"
        if control deckrailslots "$WORK/rail-edge.json"; then
            python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-edge.json" clip \
                && ok "[DECK-7] with the pointer on $edge every slot is inside the clip" \
                || bad "[DECK-7] with the pointer on $edge a slot leaves the clip"
        else
            bad "DECKRAIL deckrailslots ($edge): $CONTROL_REPLY"
        fi
    done
    control deckrailleave
    sleep 0.3

    # The pointer never re-evaluates the grid's body: twenty moves, one runloop
    # turn each, against an idle window of the same wall time.
    local t0 dur moves idle
    control deckbodyreset
    t0="$(python3 -c 'import time;print(time.time())')"
    control deckrailsweep 20 || bad "DECKRAIL deckrailsweep 20: $CONTROL_REPLY"
    dur="$(python3 -c "import time;print(round(time.time() - $t0, 2))")"
    control deckbodycount "$WORK/body-moves.txt" \
        && moves="$(cat "$WORK/body-moves.txt")" || bad "DECKRAIL deckbodycount (moves): $CONTROL_REPLY"
    control deckbodyreset
    sleep "$dur"
    control deckbodycount "$WORK/body-idle.txt" \
        && idle="$(cat "$WORK/body-idle.txt")" || bad "DECKRAIL deckbodycount (idle): $CONTROL_REPLY"
    if [ "${moves:-999}" -le $(( ${idle:-0} + 1 )) ]; then
        ok "[DECK-7] 20 pointer moves added no grid body evaluation (moves $moves, idle $idle over ${dur} s)"
    else
        bad "[DECK-7] 20 pointer moves re-evaluated the grid $moves times (idle $idle over ${dur} s)"
    fi

    # A real click on N's drawn centre (visible), or the rail's own pick. The
    # screen points come from the rail's own geometry (deckrailpoint), the hook
    # the T click uses: the frozen span moves the letters, so the rail's own
    # resolution of a letter to its row is what a person's pointer follows.
    control deckrailleave
    sleep 0.3
    if [ "$VISIBLE" = 1 ]; then
        local mx my
        if control deckrailpoint M "$WORK/m.pt" && read -r mx my < "$WORK/m.pt"; then
            cg_input moveat --x "$mx" --y "$my"
            sleep 0.6
            control deckrailslots "$WORK/rail-n.json" \
                || bad "DECKRAIL deckrailslots (M): $CONTROL_REPLY"
            python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-n.json" tag:M \
                && ok "[DECK-7] the real pointer on M's drawn centre shows M's tag" \
                || bad "[DECK-7] the real pointer on M did not show M's tag"
        else
            bad "DECKRAIL deckrailpoint M: $CONTROL_REPLY"
        fi
        if control deckrailpoint N "$WORK/n.pt" && read -r px py < "$WORK/n.pt"; then
            cg_input moveat --x "$px" --y "$py"
            sleep 0.6
        else
            bad "DECKRAIL deckrailpoint N: $CONTROL_REPLY"
        fi
    else
        control deckrailenter M || bad "DECKRAIL deckrailenter M (N click): $CONTROL_REPLY"
        sleep 0.4
        control deckrailslots "$WORK/rail-n.json" \
            || bad "DECKRAIL deckrailslots (M): $CONTROL_REPLY"
        python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-n.json" tag:M \
            && ok "[DECK-7] the enter at M names M" \
            || bad "[DECK-7] the enter at M does not name M"
        control deckrailmove N || bad "DECKRAIL deckrailmove N: $CONTROL_REPLY"
        sleep 0.5
    fi
    if control deckrailslots "$WORK/rail-n.json"; then
        python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-n.json" tag:N \
            && ok "[DECK-7] the pointer on N shows N's tag" \
            || bad "[DECK-7] the pointer on N did not show N's tag"
        if [ "$VISIBLE" = 1 ]; then
            cg_input clickat --x "$px" --y "$py"
        else
            control deck-rail N
        fi
        sleep 1
        python3 "$MACOS/scripts/deck-rail-pick.py" "$WORK/deck-grid.jsonl" N \
            && ok "[DECK-7] the click on N landed on N's section" \
            || bad "[DECK-7] the click on N did not land on N"
    else
        bad "DECKRAIL deckrailslots (N): $CONTROL_REPLY"
    fi
    # A person who clicks a letter and then moves the pointer away gets the
    # rail back at rest. The real pointer only: a forced leave would prove
    # nothing about the click.
    if [ "$VISIBLE" = 1 ]; then
        cg_input moveat --x "$(python3 -c "print(round($sx + 13 - 200))")" \
            --y "$(python3 -c "print(round($sy + $mcentre))")"
        sleep 0.3
        if control deckrailslots "$WORK/rail-post-click.json"; then
            python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-post-click.json" rest \
                && ok "[DECK-7] after a click and a move out the rail is at rest within 0.3 s" \
                || bad "[DECK-7] after a click and a move out the rail is not at rest"
        else
            bad "DECKRAIL deckrailslots (post-click): $CONTROL_REPLY"
        fi
    else
        skip_visible "DECK-7 the rail after a click and a move out (the real pointer)"
    fi

    # The rail's overlay fills the container; a last-column cell inside it but
    # off the rail still opens its app. The pointer leaves the rail first: the
    # click is about the rest overlay, and the magnified hit area is the arc's
    # room, which reaches a few points into the cell's trailing edge.
    control deckrailleave
    sleep 0.3
    control deckquery "" || bad "DECKRAIL deckquery: $CONTROL_REPLY"
    control deck-rail A || bad "DECKRAIL deck-rail A: $CONTROL_REPLY"
    sleep 1
    local opens_before
    opens_before="$(count_events '"t":"window.open"' | head -1)"
    control deckfocus grid || bad "DECKRAIL deckfocus grid: $CONTROL_REPLY"
    control deckclick Chrome \
        && ok "[DECK-7] the last-column cell took a click through the rail's overlay" \
        || bad "DECKRAIL deckclick Chrome: $CONTROL_REPLY"
    wait_until 20 [ "$(count_events '"t":"window.open"' | head -1)" -gt "$opens_before" ] \
        && ok "[DECK-7] the click through the overlay opened the app" \
        || bad "[DECK-7] the click through the overlay opened nothing"

    # [DECK-33] A pick's accent is the clicked letter on every frame of its
    # jump, never a row the scroll passes. I's first app shares its row with J
    # (the reported flash), J's row with K, Z is the last letter, # has an app
    # (1Password) and X sits in the last screenful, whose row cannot come to
    # the top. The click is the same press the rail's own gesture runs.
    control deckrailleave
    sleep 0.3
    control deckfocus grid || bad "[DECK-33] deckfocus grid: $CONTROL_REPLY"
    for target in I J Z '#' X; do
        control deck-scroll -100000 >/dev/null
        case "$CONTROL_REPLY" in
            ok|*"already at its end"*) ;;
            *) bad "DECKRAIL deck-scroll to the top ($target): $CONTROL_REPLY" ;;
        esac
        sleep 0.5
        since="$(wc -l < "$WORK/deck-grid.jsonl" | tr -d ' ')"
        control deckrailclick "$target" 80 \
            || bad "[DECK-33] deckrailclick $target: $CONTROL_REPLY"
        if settle="$(python3 "$MACOS/scripts/deck-rail-accent.py" settle "$WORK/deck-grid.jsonl" "$since" "$target" 2>&1)"; then
            ok "[DECK-33] the $target pick lit only $target from the click to the settle ($settle)"
        else
            bad "[DECK-33] the $target pick: $settle"
        fi
    done
    control deckrailleave
    sleep 0.3

    # [DECK-34] The rail's hit column is the letters' column widened by at most
    # 4 pt each side; the strip right of the letters and the window's right
    # edge are the grid's, not the rail's. The probe reads the rail's own hit
    # rect and letters' column; the pointer verbs feed the rail's own hit test.
    control deckfocus grid || bad "[DECK-34] deckfocus grid: $CONTROL_REPLY"
    control deckrailslots "$WORK/rail-hit-rest.json" \
        || bad "[DECK-34] deckrailslots (rest): $CONTROL_REPLY"
    if hitrect="$(python3 "$MACOS/scripts/deck-rail-hit.py" rect "$WORK/rail-hit-rest.json" 2>&1)"; then
        ok "[DECK-34] the hit column is the letters' column + 4 pt each side ($hitrect)"
    else
        bad "[DECK-34] the hit column: $hitrect"
    fi
    control deckrailanchor "$WORK/rail-hit-anchor.pt" \
        && read -r wx wy sx sy scale < "$WORK/rail-hit-anchor.pt" \
        || bad "[DECK-34] deckrailanchor: $CONTROL_REPLY"
    control deck-frame "$WORK/rail-hit-frame.txt" \
        && read -r fx fy fw fh < "$WORK/rail-hit-frame.txt" \
        || bad "[DECK-34] deck-frame: $CONTROL_REPLY"
    read -r deadx glyphx jy winw railhit_top railhit_bottom pitch < <(python3 - "$WORK/rail-hit-rest.json" "$fw" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
letters, pitch, hit = d["letters"], d["pitch"], d["hit"]
print(letters["right"] + 6, (letters["left"] + letters["right"]) / 2,
      9.5 * pitch, sys.argv[2], hit["top"], hit["bottom"], pitch)
PY
)
    # A hover at the letters' right edge + 6 pt is not the rail's: no pointer
    # state, no emphasis.
    control deckrailhoverat "$deadx" "$jy"
    sleep 0.3
    control deckrailslots "$WORK/rail-hit-hover.json" \
        || bad "[DECK-34] deckrailslots (dead hover): $CONTROL_REPLY"
    python3 "$MACOS/scripts/deck-rail-hit.py" state "$WORK/rail-hit-hover.json" away \
        && ok "[DECK-34] a hover 6 pt right of the letters does not enter the rail" \
        || bad "[DECK-34] a hover 6 pt right of the letters entered the rail"
    control deckrailemph "$WORK/rail-hit-emph.json" \
        || bad "[DECK-34] deckrailemph (dead hover): $CONTROL_REPLY"
    python3 "$MACOS/scripts/deck-rail-hit.py" none "$WORK/rail-hit-emph.json" \
        && ok "[DECK-34] a hover right of the letters lights nothing" \
        || bad "[DECK-34] a hover right of the letters lit the grid"
    # A click there does nothing to the rail: no jump and no accent.
    since="$(wc -l < "$WORK/deck-grid.jsonl" | tr -d ' ')"
    control deckrailclickat "$deadx" "$jy" 80 \
        || bad "[DECK-34] deckrailclickat (dead): $CONTROL_REPLY"
    sleep 0.5
    python3 "$MACOS/scripts/deck-rail-hit.py" nopick "$WORK/deck-grid.jsonl" "$since" \
        && ok "[DECK-34] a click 6 pt right of the letters does not jump or change the accent" \
        || bad "[DECK-34] a click 6 pt right of the letters reached the rail"
    # The window's right edge, over the scroller area: the same nothing.
    edgex="$(python3 -c "print($winw - $wx - 1)")"
    control deckrailhoverat "$edgex" "$jy"
    sleep 0.3
    control deckrailslots "$WORK/rail-hit-edge.json" \
        || bad "[DECK-34] deckrailslots (edge hover): $CONTROL_REPLY"
    python3 "$MACOS/scripts/deck-rail-hit.py" state "$WORK/rail-hit-edge.json" away \
        && ok "[DECK-34] a hover at the window's right edge does not enter the rail" \
        || bad "[DECK-34] a hover at the window's right edge entered the rail"
    since="$(wc -l < "$WORK/deck-grid.jsonl" | tr -d ' ')"
    control deckrailclickat "$edgex" "$jy" 80 \
        || bad "[DECK-34] deckrailclickat (edge): $CONTROL_REPLY"
    sleep 0.5
    python3 "$MACOS/scripts/deck-rail-hit.py" nopick "$WORK/deck-grid.jsonl" "$since" \
        && ok "[DECK-34] a click at the window's right edge does not reach the rail" \
        || bad "[DECK-34] a click at the window's right edge reached the rail"
    # A click on the letter's glyph still picks it.
    control deckrailleave
    sleep 0.2
    since="$(wc -l < "$WORK/deck-grid.jsonl" | tr -d ' ')"
    control deckrailclickat "$glyphx" "$jy" 80 \
        || bad "[DECK-34] deckrailclickat (glyph): $CONTROL_REPLY"
    python3 "$MACOS/scripts/deck-rail-hit.py" picked "$WORK/deck-grid.jsonl" "$since" J \
        && ok "[DECK-34] a click on J's glyph picks J" \
        || bad "[DECK-34] a click on J's glyph did not pick J"
    # Above the first and below the last letter is dead beyond 4 pt.
    local deady
    for deady in "$(python3 -c "print($railhit_top - 2)")" "$(python3 -c "print($railhit_bottom + 2)")"; do
        control deckrailleave
        sleep 0.2
        since="$(wc -l < "$WORK/deck-grid.jsonl" | tr -d ' ')"
        control deckrailclickat "$glyphx" "$deady" 60 \
            || bad "[DECK-34] deckrailclickat (crown $deady): $CONTROL_REPLY"
        sleep 0.4
        python3 "$MACOS/scripts/deck-rail-hit.py" nopick "$WORK/deck-grid.jsonl" "$since" \
            && ok "[DECK-34] a click at $deady (past the letters' end + 4 pt) is dead" \
            || bad "[DECK-34] a click at $deady reached the rail"
    done
    # The gap between J's and K's boxes still belongs to the nearest letter.
    local gap
    for gap in "J:$(python3 -c "print(10 * $pitch - 1)")" "K:$(python3 -c "print(10 * $pitch + 1)")"; do
        control deckrailleave
        sleep 0.2
        since="$(wc -l < "$WORK/deck-grid.jsonl" | tr -d ' ')"
        control deckrailclickat "$glyphx" "${gap#*:}" 60 \
            || bad "[DECK-34] deckrailclickat (gap ${gap%%:*}): $CONTROL_REPLY"
        python3 "$MACOS/scripts/deck-rail-hit.py" picked "$WORK/deck-grid.jsonl" "$since" "${gap%%:*}" \
            && ok "[DECK-34] the gap on ${gap%%:*}'s side belongs to ${gap%%:*}" \
            || bad "[DECK-34] the gap did not belong to ${gap%%:*}"
    done
    control deckrailleave
    sleep 0.3

    # [DECK-32] The rail's letter on the tiles. Build the start page first: one
    # open window and two pinned C apps, so a pinned tile of the emphasised
    # letter proves the sections never lift, while All Apps' C tiles do.
    control deckrailleave
    sleep 0.3
    control open --open com.android.settings \
        || bad "DECKRAIL deckopen (DECK-32): $CONTROL_REPLY"
    control deckpin com.android.chrome \
        || bad "DECKRAIL deckpin chrome (DECK-32): $CONTROL_REPLY"
    control deckpin com.android.camera2 \
        || bad "DECKRAIL deckpin camera (DECK-32): $CONTROL_REPLY"
    sleep 3
    local emphasis="$WORK/rail-emphasis.json" emphasis_error
    emphasis_check() {  # emphasis_check MODE [source:POINTER] [duration:SECS]
        sleep 0.5
        if ! control deckrailemph "$emphasis"; then
            emphasis_error="deckrailemph: $CONTROL_REPLY"
            return 1
        fi
        if ! emphasis_error="$(python3 "$MACOS/scripts/deck-rail-emphasis.py" "$emphasis" "$@" 2>&1)"; then
            return 1
        fi
        return 0
    }
    # wait_rail_settle SINCE — the grid dump has a new `picked` accent line: a
    # pick's jump reached its landing. A press that starts a jump is read only
    # after this, with the button still down.
    wait_rail_settle() {
        local since="$1" tries=50
        while [ "$tries" -gt 0 ]; do
            if tail -n "+$((since + 1))" "$WORK/deck-grid.jsonl" 2>/dev/null \
                | grep -q '"railAccent".*"state":"picked"'; then
                return 0
            fi
            sleep 0.1
            tries=$((tries - 1))
        done
        return 1
    }
    # Start at the top. C's row is the top All Apps row, but its landing is
    # below the Open/Pinned sections, so a press on C starts a jump: the
    # jump's own scroll must not end the press (DECK-32's early end is the
    # person's wheel/trackpad, never our own scroll).
    control deck-scroll -100000 >/dev/null 2>&1 || true
    sleep 0.5
    # Hover alone is not a press: the rail magnifies, the grid lights nothing.
    control deckrailenter C || bad "DECKRAIL deckrailenter C (DECK-32): $CONTROL_REPLY"
    if emphasis_check none; then
        ok "[DECK-32] a hover on C lights nothing (hover is not a press)"
    else
        bad "[DECK-32] the hover lit the grid ($emphasis_error)"
    fi
    # The button down lights C; the press's jump lands, and the emphasis is
    # read while the button is still down; the drag to D cross-fades; the
    # release after a held press or a drag ends it at once.
    since="$(wc -l < "$WORK/deck-grid.jsonl" | tr -d ' ')"
    control deckrailpress C || bad "DECKRAIL deckrailpress C (DECK-32): $CONTROL_REPLY"
    if ! wait_rail_settle "$since"; then
        bad "[DECK-32] the C jump never settled"
    fi
    if emphasis_check pressed:C source:C; then
        ok "[DECK-32] a held press keeps C after its jump lands: its All Apps tiles lift (1.08, semibold) and the rest dim to 30%; the sections stay at rest ($emphasis_error)"
    else
        bad "[DECK-32] the held press lost its emphasis during the jump ($emphasis_error)"
    fi
    control deckraildragto D || bad "DECKRAIL deckraildragto D (DECK-32): $CONTROL_REPLY"
    if emphasis_check pressed:D source:D; then
        ok "[DECK-32] dragging to D cross-fades to D's tiles ($emphasis_error)"
    else
        bad "[DECK-32] the drag to D did not light D ($emphasis_error)"
    fi
    control deckrailup D || bad "DECKRAIL deckrailup D (DECK-32): $CONTROL_REPLY"
    if emphasis_check none duration:0.2; then
        ok "[DECK-32] releasing a held press ends the emphasis at once ($emphasis_error)"
    else
        bad "[DECK-32] the held release did not end the emphasis ($emphasis_error)"
    fi
    # A click (80 ms, one letter) lingers for 1000 ms, then the grid returns.
    control deckrailclick C 80 || bad "DECKRAIL deckrailclick C (DECK-32): $CONTROL_REPLY"
    if emphasis_check lingering:C source:C; then
        ok "[DECK-32] a click on C lingers with C lit ($emphasis_error)"
    else
        bad "[DECK-32] the click did not linger on C ($emphasis_error)"
    fi
    sleep 1.2
    if emphasis_check none duration:0.2; then
        ok "[DECK-32] the click's 1000 ms linger ends and the whole grid returns to rest ($emphasis_error)"
    else
        bad "[DECK-32] the linger did not end ($emphasis_error)"
    fi
    # A new press during the linger replaces the letter at once and discards
    # the old clock: this press outlives the click's own deadline.
    control deckrailclick C 80 || bad "DECKRAIL deckrailclick C (DECK-32): $CONTROL_REPLY"
    sleep 0.8
    control deckrailpress D || bad "DECKRAIL deckrailpress D (DECK-32): $CONTROL_REPLY"
    sleep 0.4
    if emphasis_check pressed:D; then
        ok "[DECK-32] a press during the linger replaces it and discards its clock ($emphasis_error)"
    else
        bad "[DECK-32] the press during the linger did not replace it ($emphasis_error)"
    fi
    control deckrailup D || bad "DECKRAIL deckrailup D (DECK-32): $CONTROL_REPLY"
    if emphasis_check none duration:0.2; then
        ok "[DECK-32] the replacing press's held release ends the emphasis ($emphasis_error)"
    else
        bad "[DECK-32] the replacing press did not end ($emphasis_error)"
    fi
    # An empty B has no apps: its jump lands on C, so the grid follows the
    # accent rather than dimming the whole page.
    control deckrailpress B || bad "DECKRAIL deckrailpress B (DECK-32): $CONTROL_REPLY"
    if emphasis_check pressed:C source:B; then
        ok "[DECK-32] the empty B lights the C its jump lands on ($emphasis_error)"
    else
        bad "[DECK-32] the empty B did not light its landing letter ($emphasis_error)"
    fi
    control deckrailup B || bad "DECKRAIL deckrailup B (DECK-32): $CONTROL_REPLY"
    sleep 0.3
    # Each early end cuts a click's linger at once: typing in search, a person's
    # scroll, and a zoom change.
    control deckrailclick C 80 || bad "DECKRAIL deckrailclick C (DECK-32): $CONTROL_REPLY"
    control deckquery "a" || bad "DECKRAIL deckquery (DECK-32): $CONTROL_REPLY"
    if emphasis_check none duration:0.2; then
        ok "[DECK-32] typing in search ends the linger at once ($emphasis_error)"
    else
        bad "[DECK-32] the search results took the rail's emphasis ($emphasis_error)"
    fi
    control deckquery "" || bad "DECKRAIL deckquery clear (DECK-32): $CONTROL_REPLY"
    sleep 0.5
    control deckrailclick C 80 || bad "DECKRAIL deckrailclick C (DECK-32): $CONTROL_REPLY"
    control deckwheel -100 || bad "DECKRAIL deckwheel (DECK-32): $CONTROL_REPLY"
    if emphasis_check none duration:0.2; then
        ok "[DECK-32] a person's wheel scroll ends the linger at once ($emphasis_error)"
    else
        bad "[DECK-32] the wheel left the emphasis up ($emphasis_error)"
    fi
    control deckrailclick C 80 || bad "DECKRAIL deckrailclick C (DECK-32): $CONTROL_REPLY"
    control deckzoom 1 || bad "DECKRAIL deckzoom (DECK-32): $CONTROL_REPLY"
    if emphasis_check none duration:0.2; then
        ok "[DECK-32] a zoom change ends the linger at once ($emphasis_error)"
    else
        bad "[DECK-32] the zoom left the emphasis up ($emphasis_error)"
    fi
    control deckzoom 1.25 || bad "DECKRAIL deckzoom restore (DECK-32): $CONTROL_REPLY"
    sleep 0.5

    stop_app
    # The ISS-94 visual record (opt-in; the functional check never takes it).
    if [ "${PD_RAILPRESS_SHOTS:-0}" = 1 ]; then
        railpress_shots
    fi
}

check_deck() {
    clean
    if [ "${PD_E2E_IN_VM:-0}" = 1 ]; then
        # The VM is a test box: the real-pointer proof needs the fisheye, which
        # Reduce Motion legitimately disables. Turn it off for this run.
        sudo -n defaults write /Library/Preferences/com.apple.universalaccess reduceMotion -bool false 2>/dev/null \
            || defaults write com.apple.universalaccess reduceMotion -bool false 2>/dev/null || true
        sleep 1
    fi
    # The grid's fixtures (v105's empty slot): one package with two launcher
    # activities, and one entry with no label at all.
    # A full grid (200 apps, more than the person's phone) like theirs: the
    # zoom cost grows with the number of cells the grid lays out.
    FAKE_ARGS="--dup-launcher --no-label-app com.spotify.music --demo-apps 200 --rail-letters --foreground-pkg none" start_fake || return 1
    FAKE_ARGS=""
    # The shared app's own launch: the checks after this one use it.
    launch_shared --connect "127.0.0.1:$PORT" --debug-deck-grid "$WORK/deck-grid.jsonl" \
        --debug-deck-zoom "$WORK/deck-zoom.json"
    wait_until 30 events_have '"t":"apps.list"' \
        && ok "[DECK-1] the app list was requested" || bad "[DECK-1] no apps.list"
    # [DECK-6] A profile with no stored choice opens at the default, 125 %, and
    # View ▸ Icon Size checks it (the person: "make less dense the default").
    # The geometry checks below publish 100 % numbers, so they pin 100 % after
    # this; a fresh Deck is the default only here.
    wait_until 20 deck_at_the_default_zoom \
        && ok "[DECK-6] a fresh profile's Deck is the default 125 %" \
        || bad "[DECK-6] a fresh profile drew at $(deck_stored_zoom), not 125 %"
    control menudump "$WORK/deck-fresh-menu.json" >/dev/null \
        || bad "DECK menudump (fresh profile): $CONTROL_REPLY"
    python3 - "$WORK/deck-fresh-menu.json" <<'PY' \
        && ok "[DECK-6] a fresh profile checks 125 % in View ▸ Icon Size" \
        || bad "[DECK-6] the View menu's Icon Size on a fresh profile is wrong"
import json, sys
root = json.load(open(sys.argv[1]))
view = next(item for item in root["items"] if item["title"] == "View")
icon = next(item for item in view["submenu"] if item["title"] == "Icon Size")
checked = [item["title"] for item in icon["submenu"]
           if not item["isSeparator"] and item["state"] == "on"]
if checked != ["125 %"]:
    print("checked:", checked); sys.exit(1)
PY
    control deckzoom 1 >/dev/null || bad "DECK deckzoom 1 (DECK-4): $CONTROL_REPLY"
    wait_until 30 have_layered_icons \
        && ok "[DECK-2] layered icon replies arrived ($(icons_kind '"layers":true'))" \
        || bad "[DECK-2] no layered icon replies"
    wait_until 5 have_flat_icons \
        && ok "[DECK-2] flat icon replies arrived ($(icons_kind '"layers":false'))" \
        || bad "[DECK-2] no flat icon replies"
    local total
    total="$(count_events '"ev":"icon"')"
    [ "$total" -ge 13 ] && ok "[DECK-2] $total icon replies in total" || bad "[DECK-2] only $total icon replies"
    ! grep -qiE "fatal|protocol error" "$WORK/app.log" 2>/dev/null \
        && ok "DECK the app logged no fatal/protocol error" \
        || bad "DECK the app log has fatal/protocol lines"
    # A flat-only reply is drawn by its own shape (docs/design/dock.md §Icons):
    # fakephone's green rounded square covers its tile and its red disc keeps a
    # white plate. The grid dump carries the colour just inside the body's
    # leading edge, where a cover shows the icon and a plate shows the plate.
    wait_until 20 grep -q 'CameraLauncher","ink"' "$WORK/deck-grid.jsonl" 2>/dev/null \
        && ok "[DECK-2] the grid reported what its tiles drew" || bad "[DECK-2] no ink in the grid dump"
    wait_until 20 grep -q 'GalleryActivity","ink"' "$WORK/deck-grid.jsonl" 2>/dev/null \
        && ok "[DECK-2] the plating app's tile was drawn" || bad "[DECK-2] the plating app never drew"
    python3 - "$WORK/deck-grid.jsonl" <<'PY' \
        && ok "[DECK-2] a flat square covers its tile and a flat disc keeps its plate" \
        || bad "[DECK-2] the flat replies did not draw as a cover and a plate"
import json, sys

lines = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
# The biggest dump is the whole grid (its last one, when every icon has
# landed); later lines are search results.
grids = [line for line in lines if "items" in line]
whole = max(line["count"] for line in grids)
grid = [line for line in grids if line["count"] == whole][-1]
ink = {}
for item in grid["items"]:
    if "ink" in item:
        ink[item["id"].split("/")[0]] = tuple(int(v) for v in item["ink"].split(","))

cover = ink.get("com.android.camera2")
plate = ink.get("com.android.gallery3d")
if cover is None or any(abs(a - b) > 6 for a, b in zip(cover, (0, 128, 96))):
    print("the covering flat icon's edge is", cover)
    sys.exit(1)
if plate is None or any(v < 248 for v in plate):
    print("the plating flat icon's edge is", plate)
    sys.exit(1)
PY
    # The cells the grid drew (--debug-deck-grid): both entries of the repeated
    # package are there with their own id and words under them, and the entry
    # the phone sent without a label still has words (the package's last part).
    # Equal ids drew neither cell — the person's empty slot.
    if wait_until 30 grep -q '"count":201' "$WORK/deck-grid.jsonl" 2>/dev/null; then
        if python3 "$MACOS/scripts/deck-grid.py" "$WORK/deck-grid.jsonl" 201; then
            ok "[DECK-3] every cell has words and its own id (2 settings cells, the label-less one falls back)"
        else
            bad "[DECK-3] the grid has an empty or repeated cell ($(tail -1 "$WORK/deck-grid.jsonl"))"
        fi
    else
        bad "DECK no grid dump (--debug-deck-grid)"
    fi

    # The Deck's double-click zoom (NSWindow.zoom, the same path the title
    # bar's double-click takes) and a scripted live drag-resize must draw their
    # frames at the NFR limit, and the grid must fit the width it is drawn at on
    # every sampled frame: a layout fed by a stored, debounced width clips the
    # edge columns while the window animates.
    if wait_until 45 [ -s "$WORK/deck-zoom.json" ]; then
        local zoom_limit drag_limit
        zoom_limit="$(nfr_limit deck_zoom_frame_p95_ms)"
        drag_limit="$(nfr_limit deck_drag_frame_p95_ms)"
        if python3 "$MACOS/scripts/deck-zoom.py" "$WORK/deck-zoom.json" "$zoom_limit" "$drag_limit" "$VISIBLE"; then
            ok "[DECK-5] zoom/unzoom keep p95 under ${zoom_limit} ms, drag under the measured limit (${drag_limit} ms quiet, two display intervals visible), and every drawn frame fits ($(python3 "$MACOS/scripts/deck-zoom.py" "$WORK/deck-zoom.json" "$zoom_limit" "$drag_limit" "$VISIBLE" 2>&1); $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("zoom p95=%s ms, unzoom p95=%s ms, drag p95=%s ms, relayouts=%s, bad frames=%s" % (d["zoom"]["p95"], d["unzoom"]["p95"], d["drag"]["p95"], d.get("relayouts"), sum(d[p].get("badFrames", 0) for p in ("zoom","unzoom","drag"))))' "$WORK/deck-zoom.json"))"
        else
            bad "[DECK-5] the zoom drags a clipped or slow grid ($(python3 "$MACOS/scripts/deck-zoom.py" "$WORK/deck-zoom.json" "$zoom_limit" "$drag_limit" "$VISIBLE" 2>&1))"
        fi
    else
        bad "DECK no zoom measurement (--debug-deck-zoom)"
    fi

    # D's block is 96 pt tiles on a fixed 16 pt pitch at every width, centred
    # and never wider than 880 pt: a resize only changes the column count, and
    # past the cap it adds margins instead of scaling a tile (DECK-4,
    # --debug-deck-grid's geometry lines). The zoom probe above owns the window
    # while it runs, so resize only after it has reported.
    local geometry
    local wide_pt wide_cols
    for size in "640 5" "760 6" "1200 8" "1500 8"; do
        read -r wide_pt wide_cols <<< "$size"
        if control deck-size "$wide_pt" 700 >/dev/null; then
            if geometry="$(python3 "$MACOS/scripts/deck-geometry.py" "$WORK/deck-grid.jsonl" "$wide_pt" "$wide_cols")"; then
                ok "[DECK-4] at $wide_pt pt the block keeps one tile size with $wide_cols columns ($geometry)"
            else
                bad "[DECK-4] at $wide_pt pt the block is not D's ($geometry)"
            fi
        else
            bad "DECK deck-size $wide_pt: $CONTROL_REPLY"
        fi
    done
    # Put the Deck back on its default size for the visual record. R1's rail
    # needs 540 pt under the toolbar, which the 600 pt default leaves.
    control deck-size 760 600 || bad "DECK deck-size 760: $CONTROL_REPLY"

    # The A–Z rail (R1): rest, the letter under the pointer magnified, and the
    # accent after a jump. A quiet run cannot move the pointer, so deckrailenter
    # enters at the letter the shot needs; the real pointer is proved in the VM.
    local railshots="$WORK/deck-rail-shots"
    mkdir -p "$railshots"
    shot_rail() {
        local id
        id="$(await_window '$4 >= 600')" \
            && screencapture -x -l"$id" "$railshots/$1" >/dev/null 2>&1 \
            && say "shot: $railshots/$1" \
            || bad "DECK no Deck window for the rail shot $1"
    }
    shot_rail rail-rest.png
    local px py wx wy sx sy scale
    # The rail's magnification for the shot. A quiet run forces the enter; the
    # real pointer's enter, sideways move, sweep to Z and #, leave and click are
    # deckrail's, in the VM.
    if [ "$VISIBLE" = 1 ]; then
        skip_visible "DECK the real pointer's rail enter and moves (VM: deckrail)"
    else
        control deckrailenter M && ok "[DECK-7] forced the rail's enter at M for the shot" \
            || bad "[DECK-7] deckrailenter M: $CONTROL_REPLY"
        sleep 1
        shot_rail rail-hover-m.png
        control deckrailleave || bad "DECK deckrailleave: $CONTROL_REPLY"
    fi

    # A letter click scrolls to that letter's first app. A quiet run cannot
    # point, so deck-rail runs the rail's own scroll; a visible VM run clicks
    # the rail with the real pointer. The cell dump is the authority for where
    # that app is, and railTop proves its row is on screen after the scroll.
    if [ "$VISIBLE" = 1 ]; then
        if control deckrailpoint T "$WORK/deck-rail-shots/t.pt" \
            && read -r px py < "$WORK/deck-rail-shots/t.pt"; then
            cg_input clickat --x "$px" --y "$py"
            if rail="$(python3 "$MACOS/scripts/deck-rail.py" "$WORK/deck-grid.jsonl" T)"; then
                ok "DECK the real pointer clicked the rail's T and landed on it ($rail)"
            else
                bad "DECK the real pointer on the rail's T: $rail"
            fi
        else
            bad "DECK deckrailpoint T: $CONTROL_REPLY"
        fi
    fi
    if control deck-rail T >/dev/null; then
        if rail="$(python3 "$MACOS/scripts/deck-rail.py" "$WORK/deck-grid.jsonl" T)"; then
            ok "[DECK-7] the rail's T click lands on its first app ($rail)"
        else
            bad "[DECK-7] the rail's T click: $rail"
        fi
    else
        bad "DECK deck-rail T: $CONTROL_REPLY"
    fi
    sleep 1
    shot_rail rail-jump-t.png

    # The deckMode transition (welcome -> grid) settles; a capture too early
    # shows both states overlapped, which is useless as the visual record.
    sleep 3
    local deck="$WORK/deck-grid.png" id
    if id="$(await_window '$4 >= 600')" && screencapture -x -l"$id" "$deck"; then
        ok "DECK grid captured: $deck"
    else
        bad "DECK no Deck window to capture"
    fi

    # A drag from A to Z on the rail picks every letter on the way and lands on
    # Z's first app (a visible VM run only: it is the real pointer).
    if [ "$VISIBLE" = 1 ]; then
        if control deckrailpoint A "$WORK/deck-rail-shots/a.pt" \
            && control deckrailpoint Z "$WORK/deck-rail-shots/z.pt"; then
            local ax ay zx zy
            read -r ax ay < "$WORK/deck-rail-shots/a.pt"
            read -r zx zy < "$WORK/deck-rail-shots/z.pt"
            cg_input dragat --x "$ax" --y "$ay" --x2 "$zx" --y2 "$zy" --steps 40
            # Z's app is in the grid's last row, which cannot reach the top;
            # the pick is the proof it landed, and the shot shows Z's apps.
            if python3 - "$WORK/deck-grid.jsonl" <<'PY'
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
picks = [line["rail"] for line in lines if "rail" in line]
if not picks or picks[-1].get("letter") != "Z":
    print("last pick:", picks[-1] if picks else None); sys.exit(1)
print("last pick Z at index %s" % picks[-1].get("index"))
PY
            then
                ok "DECK dragging the real pointer from A to Z reached Z (the shot shows its apps at the bottom)"
            else
                bad "DECK dragging the real pointer A to Z did not reach Z"
            fi
            sleep 1
            shot_rail rail-drag-z.png
        else
            bad "DECK deckrailpoint A or Z: $CONTROL_REPLY"
        fi
    else
        skip_visible "DECK a real A-to-Z rail drag"
    fi

    # A 450 pt window cannot hold 27 letters at 20 pt: the rail condenses to
    # every other letter (14 slots at 280 pt) instead of hiding. Hover T shows
    # the real letter under the pointer and its tag.
    if control deck-size 760 450 >/dev/null; then
        sleep 1
        control deckrailenter T && ok "[DECK-7] the short rail's enter at T is forced" \
            || bad "[DECK-7] deckrailenter T (short): $CONTROL_REPLY"
        sleep 1
        shot_rail rail-short.png
        control deckrailleave || bad "DECK deckrailleave (short): $CONTROL_REPLY"
    else
        bad "DECK deck-size 760 450: $CONTROL_REPLY"
    fi
    control deck-size 760 600 || bad "DECK deck-size 760 600 (restore): $CONTROL_REPLY"

    # DECK-7: the rail's magnification. A quiet run cannot move the pointer, so
    # the enter and the moves are forced; the real pointer is proved in the VM.
    # On enter the span is computed at that y and frozen: A's top and #'s bottom
    # must not move while the pointer sweeps to # and Z, the gaps stay equal and
    # the rest gap's, and the drawn letter under the pointer is the one the tag
    # names and a click picks.
    control deck-size 1000 625 || bad "DECK deck-size 1000 625 (rail): $CONTROL_REPLY"
    sleep 1
    control deckrailleave
    sleep 0.5
    shot_rail rail-rest.png
    if control deckrailanchor "$railshots/anchor.pt" \
        && read -r wx wy sx sy scale < "$railshots/anchor.pt"; then
        ok "[DECK-7] the rail is at window ($wx,$wy) at scale $scale"
    else
        bad "DECK deckrailanchor (rail): $CONTROL_REPLY"
    fi
    control deckrailenter M && ok "[DECK-7] the pointer enters the rail at M" \
        || bad "[DECK-7] deckrailenter M: $CONTROL_REPLY"
    sleep 0.6
    shot_rail rail-enter-m.png
    if control deckrailslots "$WORK/rail-m.json"; then
        python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-m.json" gaps \
            && ok "[DECK-7] on the enter every gap is equal and the rest gap's" \
            || bad "[DECK-7] the enter's gaps are not equal or not the rest gap's"
        python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-m.json" centre \
            && ok "[DECK-7] the enter at M puts the drawn M under the pointer" \
            || bad "[DECK-7] the enter at M does not put M under the pointer"
        python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-m.json" tag:M \
            && ok "[DECK-7] the tag names M when the pointer is on the rail" \
            || bad "[DECK-7] the tag at the rail does not name M"
    else
        bad "DECK deckrailslots (M): $CONTROL_REPLY"
    fi
    local target shot file
    for target in '#' Z; do
        if [ "$target" = '#' ]; then
            shot="rail-down-hash.png"; file="$WORK/rail-hash.json"
        else
            shot="rail-down-z.png"; file="$WORK/rail-z.json"
        fi
        control deckrailmove "$target" || bad "[DECK-7] deckrailmove $target: $CONTROL_REPLY"
        sleep 0.6
        shot_rail "$shot"
        if control deckrailslots "$file"; then
            python3 "$MACOS/scripts/deck-rail-slots.py" "$file" frozen:"$WORK/rail-m.json" \
                && ok "[DECK-7] moving to $target leaves A's top and #'s bottom put" \
                || bad "[DECK-7] moving to $target moved the frozen ends"
            python3 "$MACOS/scripts/deck-rail-slots.py" "$file" centre \
                && ok "[DECK-7] the move to $target puts the drawn $target under the pointer" \
                || bad "[DECK-7] the move to $target does not put it under the pointer"
            python3 "$MACOS/scripts/deck-rail-slots.py" "$file" tag:"$target" \
                && ok "[DECK-7] the tag names $target" \
                || bad "[DECK-7] the tag does not name $target"
            python3 "$MACOS/scripts/deck-rail-slots.py" "$file" gaps \
                && ok "[DECK-7] the gaps stay equal and the rest gap's at $target" \
                || bad "[DECK-7] the gaps at $target are not equal or not the rest gap's"
        else
            bad "DECK deckrailslots ($target): $CONTROL_REPLY"
        fi
    done
    # The click picks the letter under the pointer: move to N and pick, and the
    # grid lands in N's section with the tag naming N.
    control deckrailmove N || bad "[DECK-7] deckrailmove N: $CONTROL_REPLY"
    sleep 0.5
    if control deckrailslots "$WORK/rail-n.json"; then
        python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-n.json" tag:N \
            && ok "[DECK-7] the tag names N with the pointer on N" \
            || bad "[DECK-7] the tag with the pointer on N does not name N"
    else
        bad "DECK deckrailslots (N): $CONTROL_REPLY"
    fi
    control deck-rail N || bad "DECK deck-rail N: $CONTROL_REPLY"
    sleep 1
    python3 "$MACOS/scripts/deck-rail-pick.py" "$WORK/deck-grid.jsonl" N \
        && ok "[DECK-7] the click on N landed on N's section" \
        || bad "[DECK-7] the click on N did not land on N"
    # Leaving: the rail is at rest within 0.3 s.
    control deckrailleave
    sleep 0.3
    if control deckrailslots "$WORK/rail-away.json"; then
        python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-away.json" rest \
            && ok "[DECK-7] the rail is a rest box at the drawn pitch 0.3 s after the pointer leaves" \
            || bad "[DECK-7] the rail is not at rest 0.3 s after the pointer left"
    else
        bad "DECK deckrailslots (away): $CONTROL_REPLY"
    fi
    shot_rail rail-away.png
    if python3 "$MACOS/scripts/rail-glyph.py" "$railshots" 1000 625 "$scale" "$wx" > "$WORK/rail-glyph.txt" 2>&1; then
        ok "[DECK-7] the shots match the layout: $(grep -m1 '^A.s top' "$WORK/rail-glyph.txt")"
    else
        bad "[DECK-7] the shots do not match the layout: $(tr '\n' ' ' < "$WORK/rail-glyph.txt")"
    fi
    sed -n 's/^/  /p' "$WORK/rail-glyph.txt" | head -14
    # Nothing clipped: with the pointer on the first and the last letter, every
    # slot and every glyph is inside the content inset.
    local edge
    for edge in A '#'; do
        control deckrailleave
        sleep 0.3
        control deckrailenter "$edge" || bad "DECK deckrailenter $edge: $CONTROL_REPLY"
        if control deckrailslots "$WORK/rail-edge.json"; then
            python3 "$MACOS/scripts/deck-rail-slots.py" "$WORK/rail-edge.json" clip \
                && ok "[DECK-7] with the pointer on $edge every slot is inside the clip" \
                || bad "[DECK-7] with the pointer on $edge a slot leaves the clip"
        else
            bad "DECK deckrailslots ($edge): $CONTROL_REPLY"
        fi
    done
    control deckrailleave
    sleep 0.3

    # DECK-7: the pointer never re-evaluates the grid's body. Twenty moves, one
    # runloop turn each, against an idle window of the same length (the quiet
    # run flushes the window's own transaction about twice a second, so the
    # bound is the idle count plus one).
    local t0 dur moves idle
    control deckbodyreset
    t0="$(python3 -c 'import time;print(time.time())')"
    control deckrailsweep 20 || bad "DECK deckrailsweep 20: $CONTROL_REPLY"
    dur="$(python3 -c "import time;print(round(time.time() - $t0, 2))")"
    control deckbodycount "$WORK/body-moves.txt" \
        && moves="$(cat "$WORK/body-moves.txt")" || bad "DECK deckbodycount (moves): $CONTROL_REPLY"
    control deckbodyreset
    sleep "$dur"
    control deckbodycount "$WORK/body-idle.txt" \
        && idle="$(cat "$WORK/body-idle.txt")" || bad "DECK deckbodycount (idle): $CONTROL_REPLY"
    if [ "${moves:-999}" -le $(( ${idle:-0} + 1 )) ]; then
        ok "[DECK-7] 20 pointer moves added no grid body evaluation (moves $moves, idle $idle over ${dur} s)"
    else
        bad "[DECK-7] 20 pointer moves re-evaluated the grid $moves times (idle $idle over ${dur} s)"
    fi
    control deckrailleave

    # DECK-7: the letter a rail click lands on stays lit, not the letter of the
    # row it shares. The fake phone's --rail-letters fixtures put I mid-row
    # with J beside it and X beside Y in the last screenful (whose row cannot
    # come to the top). A scroll by other means hands the accent back to the
    # top row's letter; the jump's own animated scroll must not.
    control deck-scroll -100000 || bad "DECK deck-scroll to the top: $CONTROL_REPLY"
    sleep 0.5
    local railletter railjson railstart
    railjson="$WORK/deck-grid.jsonl"
    for railletter in I X; do
        control deck-rail "$railletter" >/dev/null || bad "DECK deck-rail $railletter: $CONTROL_REPLY"
        sleep 1
        python3 "$MACOS/scripts/deck-rail-accent.py" pick "$railjson" "$railletter" \
            && ok "[DECK-7] the rail's $railletter click keeps $railletter lit, not its row's letter" \
            || bad "[DECK-7] the rail's $railletter click lit another letter"
        railstart="$(wc -l < "$railjson" | tr -d ' ')"
        control deck-scroll -120 >/dev/null || bad "DECK deck-scroll after $railletter: $CONTROL_REPLY"
        sleep 0.5
        python3 "$MACOS/scripts/deck-rail-accent.py" top "$railjson" "$railstart" \
            && ok "[DECK-7] a scroll after the $railletter pick hands the accent back to the top row" \
            || bad "[DECK-7] after a scroll the accent is not the top row's letter"
    done
    control deck-scroll -100000 || bad "DECK deck-scroll to the top (restore): $CONTROL_REPLY"

    # DECK-4 on the person's wide window: at 1960 pt the tiles keep their size,
    # the block stays at the 880 pt cap with margins, and it reserves the rail's
    # 44 pt, so the letter column never sits over the last cell. The window may
    # be wider than the run's display: the layout follows the width it is given,
    # not what the screen can show.
    if control deck-size 1960 1100 >/dev/null; then
        if geometry="$(python3 "$MACOS/scripts/deck-geometry.py" "$WORK/deck-grid.jsonl" 1960 8 20)"; then
            ok "[DECK-4] at 1960 pt the tiles keep their size, the block is capped with margins and the rail keeps its room ($geometry)"
        else
            bad "[DECK-4] at 1960 pt the block is not the capped one ($geometry)"
        fi
    else
        bad "DECK deck-size 1960: $CONTROL_REPLY"
    fi
    # DECK-24: the green button's zoom (NSWindow.zoom, the same path a
    # title-bar double-click takes) is the system's standard zoom — the screen's
    # visible frame, never a width computed from the grid — and a second zoom
    # returns the frame the window came from, so the icon size never changes.
    local zx zy zw zh vw vh bx by bw bh ax ay aw ah
    control deck-frame "$WORK/deck-zoom-frame-before.txt" \
        && read -r bx by bw bh < "$WORK/deck-zoom-frame-before.txt" \
        || bad "DECK the frame before the standard zoom: $CONTROL_REPLY"
    if control deckzoomwindow; then
        sleep 2
        if control deck-frame "$WORK/deck-zoom-frame.txt" \
            && read -r zx zy zw zh < "$WORK/deck-zoom-frame.txt" \
            && control deck-screen "$WORK/deck-screen.txt" \
            && read -r vw vh < "$WORK/deck-screen.txt"; then
            if [ "$zw" -ge $(( vw - 2 )) ] && [ "$zw" -le $(( vw + 2 )) ] \
                && [ "$zh" -ge $(( vh - 2 )) ] && [ "$zh" -le $(( vh + 2 )) ]; then
                ok "[DECK-24] the standard zoom took the Deck to the screen's visible frame ${zw}x${zh}"
            else
                bad "[DECK-24] the standard zoom took the Deck to ${zw}x${zh}, not the ${vw}x${vh} visible frame"
            fi
            if control deckzoomwindow; then
                sleep 2
                if control deck-frame "$WORK/deck-zoom-frame-back.txt" \
                    && read -r ax ay aw ah < "$WORK/deck-zoom-frame-back.txt"; then
                    if [ "$ax" -ge $(( bx - 2 )) ] && [ "$ax" -le $(( bx + 2 )) ] \
                        && [ "$ay" -ge $(( by - 2 )) ] && [ "$ay" -le $(( by + 2 )) ] \
                        && [ "$aw" -ge $(( bw - 2 )) ] && [ "$aw" -le $(( bw + 2 )) ] \
                        && [ "$ah" -ge $(( bh - 2 )) ] && [ "$ah" -le $(( bh + 2 )) ]; then
                        ok "[DECK-24] a second zoom returned the frame it came from (${aw}x${ah} at ${ax},${ay})"
                    else
                        bad "[DECK-24] a second zoom returned ${aw}x${ah} at ${ax},${ay}, not the ${bw}x${bh} at ${bx},${by} it came from"
                    fi
                else
                    bad "DECK the frame after the second standard zoom: $CONTROL_REPLY"
                fi
            else
                bad "DECK the second deckzoomwindow: $CONTROL_REPLY"
            fi
        else
            bad "DECK deckzoomwindow's frame: $CONTROL_REPLY"
        fi
    else
        bad "DECK deckzoomwindow: $CONTROL_REPLY"
    fi
    # DECK-6: the icon size is an explicit, stored choice. ⌘0 returns to the
    # default, 125 %; ⌘+ steps it while the Deck is key; the same key with a
    # stream window key belongs to that window's density and must leave the
    # Deck's choice alone.
    control deckzoom 1.5 >/dev/null || bad "DECK deckzoom 1.5 (DECK-6): $CONTROL_REPLY"
    control deckfocus grid >/dev/null || bad "DECK deckfocus (DECK-6 ⌘0): $CONTROL_REPLY"
    sleep 0.3
    control key cmd+0 || bad "DECK key cmd+0 (DECK-6): $CONTROL_REPLY"
    sleep 0.6
    control deck-size 1500 900 >/dev/null || bad "DECK deck-size 1500 (DECK-6 ⌘0): $CONTROL_REPLY"
    sleep 0.6
    if [ "$(deck_stored_zoom)" = "1.25" ]; then
        ok "[DECK-6] ⌘0 returned the Deck's icon size from 150 % to the default 125 %"
    else
        bad "[DECK-6] ⌘0 left the icon size at $(deck_stored_zoom)"
    fi
    control deckzoom 1 >/dev/null || bad "DECK deckzoom 1 (DECK-6): $CONTROL_REPLY"
    sleep 0.3
    control key cmd+= || bad "DECK key cmd+= (DECK-6): $CONTROL_REPLY"
    sleep 0.6
    control deck-size 1500 900 >/dev/null || bad "DECK deck-size 1500 (DECK-6): $CONTROL_REPLY"
    sleep 0.6
    if [ "$(deck_stored_zoom)" = "1.25" ]; then
        ok "[DECK-6] ⌘+ stepped the Deck's icon size to 125%"
    else
        bad "[DECK-6] ⌘+ left the icon size at $(deck_stored_zoom)"
    fi
    # The same window the ⌘F check below opens; it carries the chrome state
    # that check waits for, and the raise there finds the file already written.
    control open --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" >/dev/null \
        || bad "DECK open settings (DECK-6): $CONTROL_REPLY"
    sleep 2
    control key cmd+= || bad "DECK key cmd+= with a stream window key (DECK-6): $CONTROL_REPLY"
    sleep 0.6
    control deck-size 1500 900 >/dev/null || bad "DECK deck-size 1500 (DECK-6 stream): $CONTROL_REPLY"
    sleep 0.6
    if [ "$(deck_stored_zoom)" = "1.25" ]; then
        ok "[DECK-6] with a stream window key ⌘+ left the Deck's 125% alone"
    else
        bad "[DECK-6] a stream window's ⌘+ changed the Deck's icon size to $(deck_stored_zoom)"
    fi
    # The stream window's own density: ⌘0 clears the override this check made.
    control key cmd+0 >/dev/null || bad "DECK key cmd+0 (stream density): $CONTROL_REPLY"
    control deckzoom 1 >/dev/null || bad "DECK deckzoom 1 (DECK-6 restore): $CONTROL_REPLY"
    control deck-size 760 600 || bad "DECK deck-size 760 600 (wide checks): $CONTROL_REPLY"

    # ⌘F is the Deck's Find (focus the search field, select its text) and the
    # phone app's find-in-page when a stream window is key: a real key event
    # through the application's own dispatch (menu equivalents, local monitors,
    # the key window's responder chain), never a shortcut that calls the action.
    # ⌘K stays the app-wide Find Apps.
    local n
    for n in typed before after help stream after-k; do rm -f "$WORK/deck-search-$n.json"; done
    deck_search() {
        control decksearch "$WORK/deck-search-$1.json" || bad "DECK decksearch $1: $CONTROL_REPLY"
    }
    # Setup: text already in the field, then the field left unfocused. The ⌘F
    # press below is the real key event under test; this only stages the text.
    control deckfocus search || bad "DECK deckfocus search: $CONTROL_REPLY"
    control deckquery set || bad "DECK deckquery: $CONTROL_REPLY"
    sleep 0.3
    deck_search typed
    python3 - "$WORK/deck-search-typed.json" <<'PY' && ok "DECK setup: the search field holds text" \
        || bad "DECK setup: the search field has no text"
import json, sys
root = json.load(open(sys.argv[1]))
if root["text"] != "set":
    print(root); sys.exit(1)
PY
    control deckfocus grid || bad "DECK deckfocus grid: $CONTROL_REPLY"
    deck_search before
    python3 - "$WORK/deck-search-before.json" <<'PY' && ok "DECK setup: the search field is not focused and still holds the text" \
        || bad "DECK setup: the search field is focused before ⌘F"
import json, sys
root = json.load(open(sys.argv[1]))
if root["focused"] or root["text"] != "set":
    print(root); sys.exit(1)
PY
    control key cmd+f || bad "DECK key cmd+f: $CONTROL_REPLY"
    sleep 0.5
    deck_search after
    python3 - "$WORK/deck-search-after.json" <<'PY' && ok "[DECK-9] ⌘F focuses the search field and selects its text" \
        || bad "[DECK-9] ⌘F did not leave the search field focused with its text selected"
import json, sys
root = json.load(open(sys.argv[1]))
if not root["focused"]:
    print("not focused:", root); sys.exit(1)
if root["text"] != "set" or root["selection"] != [0, 3]:
    print("text/selection:", root["text"], root["selection"]); sys.exit(1)
PY
    # ⌘F is deliberately not a menu item (a menu item would eat it in every
    # stream window), so the field's own help tag and AX help have to name it
    # (CONV-MAC-06, misses.md M4).
    deck_search help
    python3 - "$WORK/deck-search-help.json" <<'PY' && ok "[DECK-9] the search field's help tag and AX help name ⌘F (CONV-MAC-06)" \
        || bad "[DECK-9] the search field's help does not name ⌘F, so nothing tells a person the key"
import json, sys
root = json.load(open(sys.argv[1]))
if root["tooltip"] != "Find (⌘F)" or root["help"] != "Find (⌘F)":
    print("tooltip:", root["tooltip"], "help:", root["help"]); sys.exit(1)
PY
    # A stream window is key: the same ⌘F belongs to the phone's app.
    control open --open com.android.settings --debug-chrome-state "$WORK/chrome.txt" \
        || bad "DECK shared app: opening a stream window answered '$CONTROL_REPLY'"
    wait_until 20 grep -q "style=" "$WORK/chrome.txt" || bad "DECK no stream window for the ⌘F check"
    sleep 1
    deck_search stream
    python3 - "$WORK/deck-search-stream.json" <<'PY' && ok "[DECK-9] the stream window is key and the Deck search is not focused" \
        || bad "[DECK-9] the Deck search field took focus with a stream window key"
import json, sys
root = json.load(open(sys.argv[1]))
if root["focused"] or root["keyWindow"] != "other":
    print(root); sys.exit(1)
PY
    control key cmd+f || bad "DECK key cmd+f with a stream window: $CONTROL_REPLY"
    wait_until 10 grep -q '"kind":"key","stream":1,"action":0,"keycode":34,"meta":12288' "$WORK/events.jsonl" \
        && ok "[DECK-9] ⌘F with a stream window key reached the phone as meta+F" \
        || bad "[DECK-9] ⌘F with a stream window key did not reach the phone ($(grep '"kind":"key"' "$WORK/events.jsonl" | tail -1))"
    deck_search after-k
    python3 - "$WORK/deck-search-after-k.json" <<'PY' && ok "[DECK-9] the Deck search field stayed out of the stream window's ⌘F" \
        || bad "[DECK-9] the Deck search field took the stream window's ⌘F"
import json, sys
root = json.load(open(sys.argv[1]))
if root["focused"] or root["keyWindow"] != "other":
    print(root); sys.exit(1)
PY
    # ⌘K still brings the Deck up and focuses search from anywhere.
    control key cmd+k || bad "DECK key cmd+k: $CONTROL_REPLY"
    sleep 0.5
    deck_search after-k2
    python3 - "$WORK/deck-search-after-k2.json" <<'PY' && ok "[DECK-10] ⌘K still brings the Deck up and focuses search" \
        || bad "[DECK-10] ⌘K did not bring the Deck up with search focused"
import json, sys
root = json.load(open(sys.argv[1]))
if not root["focused"] or root["keyWindow"] != "deck":
    print(root); sys.exit(1)
PY
    control open --close-stream 1:0 --debug-chrome-state "$WORK/chrome.txt" \
        || bad "DECK shared app: closing the stream window answered '$CONTROL_REPLY'"
    # DECK-7 click-through: the rail's overlay fills the container so it can
    # clip the growing rail. A click on a last-column cell inside that frame but
    # off the rail must still reach the cell. It opens a stream, so it runs
    # after the ⌘F/⌘K steps (which expect the first stream) and before the
    # popover; the frame check at the end of the run stops the app.
    # The stream closed above tears down in its own time: resizing the Deck
    # under its teardown stalls the control channel, so settle first and do
    # not resize.
    sleep 4
    control deckquery "" || bad "DECK deckquery (click-through): $CONTROL_REPLY"
    sleep 0.5
    control deck-rail A || bad "DECK deck-rail A (click-through): $CONTROL_REPLY"
    sleep 1
    local opens_before
    opens_before="$(count_events '"t":"window.open"' | head -1)"
    control deckfocus grid || bad "DECK deckfocus grid (click-through): $CONTROL_REPLY"
    # The Deck is 760 pt wide: 6 columns, so the sixth cell of the first row is
    # in the last column, under the overlay's frame and off the rail.
    control deckclick Authenticator 5 \
        && ok "[DECK-7] the last-column cell took a click through the rail's overlay" \
        || bad "[DECK-7] deckclick Authenticator 5: $CONTROL_REPLY"
    wait_until 20 [ "$(count_events '"t":"window.open"' | head -1)" -gt "$opens_before" ] \
        && ok "[DECK-7] the click through the overlay opened the app" \
        || bad "[DECK-7] the click through the overlay opened nothing"

    # The status pill opens the same phone controls in a popover (docs/DESIGN.md
    # "Deck"): one component, P3's tiles, and no Settings/Quit footer (the Deck
    # has its own gear and the app menu has both). Its DND tile is the real
    # control — the click reaches the phone.
    control deckpanel || bad "DECK deckpanel: $CONTROL_REPLY"
    # The popover presents on the next run-loop turns and is its own window.
    rm -f "$WORK/deck-panel.json"
    local tries=20
    while [ "$tries" -gt 0 ]; do
        control paneldump deck "$WORK/deck-panel.json" >/dev/null 2>&1 && break
        tries=$((tries - 1)); sleep 0.5
    done
    if [ ! -s "$WORK/deck-panel.json" ]; then
        control panelwindows "$WORK/deck-windows.txt" >/dev/null 2>&1
        bad "DECK no panel dump from the popover ($(tr '\n' '|' < "$WORK/deck-windows.txt" 2>/dev/null))"
    fi
    python3 - "$WORK/deck-panel.json" <<'PY' && ok "[DECK-20] the popover hosts the shared panel (300 pt, the same items)" \
        || bad "[DECK-20] the popover is not the shared panel"
import json, sys
root = json.load(open(sys.argv[1]))
if root["width"] != 300:
    print("width:", root["width"]); sys.exit(1)
if not root["mapped"]:
    print("items:", len(root["items"]), "controls:", len(root["controls"])); sys.exit(1)
kinds = [row["kind"] for row in root["items"]]
want = ["volume", "dnd", "ringer", "ring", "screen", "phoneScreen", "findApps"]
if kinds != want:
    print("the Deck popover items:", kinds); sys.exit(1)
if "settings" in kinds or "quit" in kinds:
    print("the Deck popover kept the menu bar footer:", kinds); sys.exit(1)
PY
    local dnd_before dnd_after
    dnd_before="$(grep -c '"ev":"dnd"' "$WORK/events.jsonl" 2>/dev/null || echo 0)"
    control panelclick deck panel.dnd || bad "DECK the popover's DND click: $CONTROL_REPLY"
    dnd_after() { grep -c '"ev":"dnd"' "$WORK/events.jsonl" 2>/dev/null || echo 0; }
    wait_until 20 [ "$(dnd_after)" -gt "$dnd_before" ] \
        && ok "[DECK-20] clicking the popover's DND tile reached the phone ($(grep -o '"ev":"dnd"[^}]*' "$WORK/events.jsonl" 2>/dev/null | tail -1))" \
        || bad "[DECK-20] the popover's DND tile sent no new phone.dnd"

    # The visual record for DECK-4/DECK-24 (the reviewer looks before the
    # person does): the Deck at the sizes the brief names, from the run's own
    # display, light and dark. The 125 % row sets the grid's zoom the way ⌘+
    # does, and the last row is the standard zoom's own frame. Each appearance
    # is the app's own override (the person's system setting is never touched),
    # and each is a fresh launch: the shared app follows the system's
    # appearance otherwise.
    local shotdir="$WORK/deck-wide" shotlook deck_id lists_before
    mkdir -p "$shotdir"
    # The popover from DECK-20 would sit over the grid, and a reconnecting link
    # dims the whole content: the record is the connected Deck alone.
    control deckpanelclose
    sleep 0.5
    deck_linked() {
        [ "$(grep -o '"state":"[a-z_]*"' "$WORK/events.jsonl" 2>/dev/null | tail -1)" = '"state":"auth_ok"' ]
    }
    deck_shot() {
        wait_until 15 deck_linked
        deck_id="$(await_window '$4 >= 600')" \
            && screencapture -x -l"$deck_id" "$shotdir/$1.png" >/dev/null 2>&1 \
            && say "shot: $shotdir/$1.png" \
            || bad "DECK no Deck window for the shot $1"
    }
    deck_size() {  # deck_size WIDTH HEIGHT SHOT_NAME
        control deck-size "$1" "$2" >/dev/null || bad "DECK deck-size $1 $2 ($3): $CONTROL_REPLY"
        sleep 1.5
        deck_shot "$3"
    }
    deck_row() {
        shotlook="$1"
        control deckzoom 1 >/dev/null || bad "DECK deckzoom 1: $CONTROL_REPLY"
        deck_size 760 600 "wide-760x600-$shotlook"
        deck_size 1440 900 "wide-1440x900-$shotlook"
        deck_size 1500 900 "wide-1500x900-$shotlook"
        deck_size 1960 1100 "wide-1960x1100-$shotlook"
        control deckzoom 1.25 >/dev/null || bad "DECK deckzoom 1.25: $CONTROL_REPLY"
        deck_size 1000 625 "wide-1000x625-125-$shotlook"
        control deckzoom 1 >/dev/null || bad "DECK deckzoom 1: $CONTROL_REPLY"
        control deck-size 1960 1100 >/dev/null || bad "DECK deck-size 1960 1100 (zoom): $CONTROL_REPLY"
        sleep 1
        control deckzoomwindow >/dev/null || bad "DECK deckzoomwindow (shot): $CONTROL_REPLY"
        sleep 2
        deck_shot "wide-after-zoom-$shotlook"
    }
    apps_asked() { [ "$(count_events '"t":"apps.list"')" -gt "$lists_before" ]; }
    # deck_appearance light|dark: a fresh shared app in that appearance. It is
    # killed by its own pid first: stop_app only resets it, and a second
    # instance would wait for the phone's one session.
    deck_appearance() {
        kill_e2e_app
        SHARED_PID=""
        lists_before="$(count_events '"t":"apps.list"')"
        launch_shared --connect "127.0.0.1:$PORT" --appearance "$1"
        if wait_until 30 apps_asked; then
            ok "DECK the $1 Deck came up and asked for its apps"
        else
            bad "DECK the $1 Deck never asked for its apps"
        fi
        sleep 3
        control deckpanelclose >/dev/null
    }
    deck_appearance light
    deck_row light
    deck_appearance dark
    deck_row dark
    control deckzoom 1 >/dev/null
    kill_e2e_app
    SHARED_PID=""

    # DECK-19/CONV-MAC-12: does the Deck remember its frame across a launch?
    # Resize it, quit the way ⌘Q does, relaunch and read the frame again.
    stop_app
    kill_e2e_app
    wait_until 5 [ -z "$(e2e_app_pids)" ] || kill_e2e_app
    local frame_dir="$WORK/frames"
    rm -rf "$frame_dir"
    mkdir -p "$frame_dir"
    frame_control() {
        local fdir="$frame_dir" fname
        CONTROL_SEQ=$((CONTROL_SEQ + 1))
        fname="f$CONTROL_SEQ"
        printf '%s\n' "$*" > "$fdir/$fname.tmp" && mv "$fdir/$fname.tmp" "$fdir/$fname.cmd"
        if ! wait_until 10 [ -s "$fdir/$fname.done" ]; then
            CONTROL_REPLY="no answer in 10 s"
            return 1
        fi
        CONTROL_REPLY="$(cat "$fdir/$fname.done")"
        rm -f "$fdir/$fname.done"
        [ "$CONTROL_REPLY" = "ok" ]
    }
    frame_app_gone() { ! kill -0 "$APP_PID" 2>/dev/null; }
    # The Deck window is built with the app: wait for it before resizing.
    frame_wait_deck() {
        local tries=40
        while [ "$tries" -gt 0 ]; do
            frame_control deck-frame "$1" && return 0
            tries=$((tries - 1))
            sleep 0.25
        done
        return 1
    }
    launch --connect "127.0.0.1:$PORT" --debug-control "$frame_dir" --quit-after 60
    frame_wait_deck "$WORK/deck-frame-0.txt" || bad "DECK frame: the Deck gave no frame"
    frame_control deck-size 1000 700 || bad "DECK frame: deck-size 1000 700: $CONTROL_REPLY"
    frame_control deck-move 1700 300 || bad "DECK frame: deck-move 1700 300: $CONTROL_REPLY"
    sleep 1
    frame_control deck-frame "$WORK/deck-frame-1.txt" || bad "DECK frame: the resized Deck gave no frame"
    frame_control screens "$WORK/deck-screens-1.txt" || bad "DECK frame: no screen report before the quit"
    printf 'quit\n' > "$frame_dir/quit.cmd"
    wait_until 10 frame_app_gone || bad "DECK frame: the app did not quit"
    wait "$APP_PID" 2>/dev/null
    launch --connect "127.0.0.1:$PORT" --debug-control "$frame_dir" --quit-after 40
    frame_wait_deck "$WORK/deck-frame-2.txt" || bad "DECK frame: the relaunched Deck gave no frame"
    # The opening window is placed on its first render: read it once it has
    # settled rather than in the middle of that.
    sleep 1
    frame_control deck-frame "$WORK/deck-frame-2.txt" || bad "DECK frame: the relaunched Deck gave no frame"
    frame_control screens "$WORK/deck-screens-2.txt" || bad "DECK frame: no screen report after the relaunch"
    say "DECK frame before quit: $(cat "$WORK/deck-frame-1.txt" 2>/dev/null); $(tr '\n' ' ' < "$WORK/deck-screens-1.txt" 2>/dev/null)"
    say "DECK frame after relaunch: $(cat "$WORK/deck-frame-2.txt" 2>/dev/null); $(tr '\n' ' ' < "$WORK/deck-screens-2.txt" 2>/dev/null)"
    if python3 - "$WORK/deck-frame-1.txt" "$WORK/deck-frame-2.txt" <<'PY'
import sys
before = [int(v) for v in open(sys.argv[1]).read().split()]
after = [int(v) for v in open(sys.argv[2]).read().split()]
if len(before) != 4 or len(after) != 4:
    print(before, after); sys.exit(1)
if any(abs(a - b) > 2 for a, b in zip(before, after)):
    print("before:", before, "after:", after); sys.exit(1)
PY
    then
        ok "[DECK-19] the Deck came back at the frame it had (within 2 pt, $(cat "$WORK/deck-frame-2.txt"))"
    else
        bad "[DECK-19] the Deck did not remember its frame (before $(cat "$WORK/deck-frame-1.txt" 2>/dev/null), after $(cat "$WORK/deck-frame-2.txt" 2>/dev/null))"
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
    # nav_count — how many `nav back` messages the phone received (rx events).
    nav_count() {
        python3 - "$WORK/events.jsonl" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    msg = event.get("msg") if event.get("ev") == "rx" else None
    if isinstance(msg, dict) and msg.get("t") == "nav" \
            and msg.get("stream") == 1 and msg.get("action") == "back":
        n += 1
print(n)
PY
    }
    # The script's own result lines, counted by re-reading the log on every
    # poll (a $( ) inside a wait_until argument is evaluated once, at the call).
    idle_count() { grep -c '"op":"idle"' "$WORK/app.log" 2>/dev/null; }
    two_idles() { [ "$(idle_count)" -ge 2 ]; }
    FAKE_ARGS="--text-frame CONTIGUA --frame-events" start_fake || return 1
    FAKE_ARGS=""
    rm -f "$WORK/lt-copy-go" "$WORK/livetext.png"
    # The phone window's Back button and the Navigate shortcut run the same
    # controller action this check drives.
    printf '%s\n' \
        "wait-warm 180" \
        "enter 1" \
        "wait-analysis CONTIGUA" \
        "drag-check" \
        "nav back" \
        "waitfile $WORK/lt-copy-go 120" \
        "copy-image $WORK/livetext.png" \
        "exit" \
        "wait-idle" \
        "enter 1" \
        "wait-analysis" \
        "resize 1 1200 800" \
        "wait-idle" \
        "nav back" > "$WORK/livetext.txt"
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --debug-livetext "$WORK/livetext.txt" \
        --quit-after 320
    wait_until 30 events_have '"ev":"video","stream":1,"config":true' \
        || { bad "LT no video config"; stop_app; stop_fakephone; return 1; }

    # The launch warm-up finished (LiveTextWarmer): the analysis below is the
    # one a person gets minutes into a session, not a cold service's first call.
    if wait_until 200 grep -q '"op":"warm"' "$WORK/app.log"; then
        grep '"op":"warm"' "$WORK/app.log" | tail -1 | grep -q '"ok":true' \
            && ok "LT the launch warm-up finished" \
            || bad "LT the launch warm-up never finished ($(grep '"op":"warm"' "$WORK/app.log" | tail -1))"
    else
        bad "LT the warm-up never reported"
    fi

    # Enter + VisionKit: the frozen frame carries CONTIGUA.
    if wait_until 120 grep -q '"ok":true,"op":"analysis"' "$WORK/app.log"; then
        local line
        line="$(grep '"ok":true,"op":"analysis"' "$WORK/app.log" | tail -1)"
        case "$line" in
            *'"state":"shown"'*) ok "LT enter froze the frame and VisionKit finished" ;;
            *) bad "LT analysis did not reach shown ($line)" ;;
        esac
        case "$line" in
            *'"hasText":true'*) ok "LT the overlay found text" ;;
            *) bad "LT no text in the frozen frame ($line)" ;;
        esac
        case "$line" in
            *'"contains":true'*) ok "LT the analysis reads CONTIGUA" ;;
            *) bad "LT the analysis does not contain CONTIGUA ($line)" ;;
        esac
        # Entry starts with VisionKit's Live Text button on: every recognised
        # item is highlighted. (Before v103's hotfix it started off, so the
        # person saw the text but no highlights until they pressed the button.)
        case "$line" in
            *'"highlights":true'*) ok "LT the Live Text highlight button is on after the analysis" ;;
            *) bad "LT the Live Text highlight button is off after the analysis ($line)" ;;
        esac
        # The person waits in the mode for the words: the entry is done when the
        # analysis is (v105 took 8-13 s and left, or never had text at all).
        local ms
        ms="$(grep -o '"ms":[0-9]*' <<< "$line" | cut -d: -f2)"
        if [ -n "${ms:-}" ] && [ "${ms:-0}" -lt 3000 ]; then
            ok "LT the analysis read the frame ${ms} ms after entering (< 3000)"
        else
            bad "LT the analysis took ${ms:-?} ms after entering (limit 3000)"
        fi
        # The entry diagnostics: the frozen frame's size, its pixel format and
        # its mean luma, so a blank frame is visible in the log next time.
        # The three facts, not their order: the log's keys are sorted.
        if grep -q '"frameFormat":"BGRA"' <<< "$line" \
            && grep -q '"frameW":896' <<< "$line" \
            && grep -q '"frameH":592' <<< "$line"; then
            ok "LT the entry logs the frozen frame's size and format"
        else
            bad "LT the entry does not log the frame diagnostics ($line)"
        fi
        local mean
        mean="$(grep -o '"frameMean":[0-9]*' <<< "$line" | cut -d: -f2)"
        if [ -n "${mean:-}" ] && [ "${mean:-0}" -gt 20 ]; then
            ok "LT the frozen frame is not blank (mean luma $mean)"
        else
            bad "LT the frozen frame looks blank (mean luma ${mean:-?})"
        fi
    else
        bad "LT no analysis result (app log: $(tail -3 "$WORK/app.log"))"
    fi

    # The overlay takes the person's drag through the window's own hit test:
    # v104 set the highlight flag and the drag stopped reaching VisionKit.
    if wait_until 20 grep -q '"op":"drag"' "$WORK/app.log"; then
        local drag
        drag="$(grep '"op":"drag"' "$WORK/app.log" | tail -1)"
        case "$drag" in
            *'"hit":"overlay"'*)
                ok "LT a drag at a recognised word hits the analysis overlay" ;;
            *) bad "LT the drag does not hit the overlay ($drag)" ;;
        esac
        # The quiet run's app is inactive, so VisionKit never starts the
        # selection itself (it needs the person's active window); the hit route
        # above is the e2e part, and LiveTextInteractionTests pins the set.
        case "$drag" in
            *'"supplementary":true'*) ok "LT the Live Text button is still there" ;;
            *) bad "LT the supplementary Live Text button is hidden ($drag)" ;;
        esac
    else
        bad "LT no drag-check result (app log: $(tail -3 "$WORK/app.log"))"
    fi

    # VM screenshots (visible runs only): the bar over the bright text frame,
    # once in the mode (controls dimmed, "Live Text" pill) and once at rest.
    if [ "$VISIBLE" = "1" ]; then
        local shotwin
        shotwin="$(await_window '$4 > 200 && $5 > 200')" || shotwin=""
        if [ -n "$shotwin" ]; then
            screencapture -x -o -l"$shotwin" "$WORK/livetext-dimmed.png" \
                && say "screenshot: $WORK/livetext-dimmed.png"
        fi
    fi

    # The mode freezes the bar: a Back press (the bar's button and ⌘[ run this
    # one controller action) must reach no phone while the picture is frozen.
    if wait_until 15 grep -q '"op":"nav"' "$WORK/app.log"; then
        local navs_frozen
        navs_frozen="$(nav_count)"
        [ "${navs_frozen:-0}" = "0" ] \
            && ok "LT in the mode a Back press sent no nav to the phone (bar and shortcut frozen)" \
            || bad "LT a Back press reached the phone in the mode ($navs_frozen nav)"
    else
        bad "LT no nav result in the mode"
    fi

    # While frozen the phone sends no frames (the mode paused the stream).
    local frames_frozen frames_after
    frames_frozen="$(frames_n)"
    sleep 1
    frames_after="$(frames_n)"
    if [ -z "${frames_frozen:-}" ]; then
        say "LT no frame counter yet when the mode froze (the stream paused before its first count)"
    elif [ "${frames_after:-0}" = "${frames_frozen:-0}" ]; then
        ok "LT the phone stopped sending frames while frozen (n=$frames_after)"
    else
        bad "LT frames kept flowing in the mode (n ${frames_frozen:-0} -> ${frames_after:-0})"
    fi


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
    if [ "$VISIBLE" = "1" ] && [ -n "${shotwin:-}" ]; then
        screencapture -x -o -l"$shotwin" "$WORK/livetext-bar.png" \
            && say "screenshot: $WORK/livetext-bar.png"
    fi

    # A stream resize while in the mode drops back to idle.
    # The second enter runs VisionKit again; under load that alone can take
    # half a minute.
    if wait_until 220 grep -qF '"op":"resize"' "$WORK/app.log"; then
        wait_until 15 two_idles \
            && ok "LT a stream resize while in the mode dropped back to idle" \
            || bad "LT the resize did not return the mode to idle"
    else
        bad "LT the second enter/resize phase did not run"
    fi

    # VisionKit's service sometimes answers "no text" for a frame full of words
    # (v105's "analysis ready, 0 characters"); the mode asks again
    # (LiveTextView.analysisAttempts). Both analyses this run took — the second
    # enter included — must carry the text.
    local analyses textless
    analyses="$(grep -c '"op":"analysis"' "$WORK/app.log")"
    textless="$(grep '"op":"analysis"' "$WORK/app.log" | grep -c '"hasText":false')"
    if [ "${analyses:-0}" -ge 2 ] && [ "${textless:-1}" = "0" ]; then
        ok "LT both analyses read text (no empty answer kept)"
    else
        bad "LT ${textless:-?} of ${analyses:-?} analysis result(s) came back with no text"
    fi

    # Out of the mode the same press works again (the script's last Back runs
    # after the second phase's idle).
    wait_until 15 [ "$(grep -c '"op":"nav"' "$WORK/app.log")" -ge 2 ] \
        && ok "LT after the exit the Back press ran" \
        || bad "LT the second Back press did not run"
    wait_until 15 [ "$(nav_count)" -ge 1 ] \
        && ok "LT after the exit Back sends nav again ($(nav_count) nav)" \
        || bad "LT Back still sent nothing after the exit ($(nav_count) nav)"
    stop_app
    stop_fakephone
}

# check_menubar_shots — the panel's visual record on the run's own (quiet,
# virtual) display: light with two playing apps, ringing, the Deck popover, then
# offline. The VM check menubar-vm does the same in situ under the status item
# and adds dark mode; this one is the host's copy, and the only place a quiet
# run can drive the panel's rows (the status item's window is the window
# server's). The shots go to $WORK/menubar-shots/ and are judged by eye.
check_menubar_shots() {
    clean
    local shots="$WORK/menubar-shots" result device vcx vcy item_size dot_size
    local mainx mainy mainw mainh vx vy vw vh
    mkdir -p "$shots"
    shot_panel() {
        local id
        id="$(await_window '$4 >= 300 && $4 <= 340 && $5 >= 300 && $5 <= 800')" \
            || { bad "MENUBAR-SHOTS no panel window for $1"; return 1; }
        screencapture -x -l"$id" "$shots/$1" >/dev/null 2>&1 && say "shot: $shots/$1"
    }
    # shot_item NAME CENTRE_X CENTRE_Y "DISPLAY x y w h": a 300×30 pt menu bar
    # crop around the item, kept inside that display. The person's own items are
    # the neighbours: tight, and the crops stay in $WORK, never committed.
    shot_item() {
        local name="$1" cx="$2" cy="$3" x y w=300 h=30 sx sy sw sh
        read -r sx sy sw sh <<< "$4"
        x=$(( cx - w / 2 )); y=$(( cy - h / 2 ))
        [ "$x" -lt $(( sx + 4 )) ] && x=$(( sx + 4 ))
        [ $(( x + w )) -gt $(( sx + sw - 4 )) ] && x=$(( sx + sw - 4 - w ))
        [ "$y" -lt "$sy" ] && y="$sy"
        [ $(( y + h )) -gt $(( sy + sh )) ] && y=$(( sy + sh - h ))
        screencapture -x -R "${x},${y},${w},${h}" "$shots/$name" >/dev/null 2>&1 \
            && say "shot: $shots/$name rect=${x},${y},${w},${h}" \
            || bad "MENUBAR-SHOTS no $name"
    }
    # display_of main|ID — that display's "x y w h" in Quartz points.
    display_of() {
        "$MENUBARBIN" displays | awk -v want="$1" \
            '$1 == want || (want == "main" && $NF == "main=1") { print $2, $3, $4, $5; exit }'
    }
    # item_shots [PREFIX] — the item's crop on the active display and on the
    # run's own display, an inactive one: there every item is drawn dimmed,
    # ours included. The frame line says where the item is in each crop.
    item_shots() {
        local fx fy fw fh icx icy
        read -r fx fy fw fh <<< "$("$MENUBARBIN" frame "$APP_PID")" \
            || { bad "MENUBAR-SHOTS no AX frame for the status item"; return 1; }
        say "MENUBAR-SHOTS item frame=${fx},${fy},${fw}x${fh}"
        icx=$(( fx + fw / 2 )); icy=$(( fy + fh / 2 ))
        read -r mainx mainy mainw mainh <<< "$(display_of main)"
        [ -n "$mainw" ] || { bad "MENUBAR-SHOTS no main display"; return 1; }
        shot_item "${1:-menubar-item}-main.png" "$icx" "$icy" "$mainx $mainy $mainw $mainh"
        [ -n "${VDISPLAY_ID:-}" ] || return 0
        read -r vx vy vw vh <<< "$(display_of "$VDISPLAY_ID")"
        [ -n "$vw" ] || { bad "MENUBAR-SHOTS no run display $VDISPLAY_ID"; return 1; }
        # The same distance from the display's right edge, on its menu bar.
        vcx=$(( vx + vw - (mainx + mainw - icx) ))
        vcy=$(( vy + icy - mainy ))
        shot_item "${1:-menubar-item}-inactive.png" "$vcx" "$vcy" "$vx $vy $vw $vh"
    }

    FAKE_ARGS="--media" start_fake || return 1
    device="$(sed -n 's/^fakephone \([^ ]*\) listening.*/\1/p' "$WORK/fake.log" "$WORK/fake.err" | head -1)"
    [ -n "$device" ] || { bad "MENUBAR-SHOTS no device id in the fakephone line"; stop_fakephone; return 1; }
    defaults write "$DEFAULTS_SUITE" "showAppsInDock" -bool NO
    defaults write "$DEFAULTS_SUITE" "notify.$device" -bool YES
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --connect "127.0.0.1:$PORT" --quit-after 120 --debug-control "$WORK-control" \
        --open com.whatsapp
    wait_until 30 events_have '"t":"apps.list"' \
        || { bad "MENUBAR-SHOTS the session never started"; stop_app; stop_fakephone; return 1; }
    # [PANEL-25] the item is a real status item: AppKit's, sized to its own
    # template image with no foreign view over the button. A fixed length and a
    # hosting view pinned over the button were the person's padding, the
    # off-centre glyph and the icon that stayed bright on the inactive display.
    control menubaricon || true
    result="$CONTROL_REPLY"
    case "$result" in
        "length=variable image=template subviews=0 state=online dot=0 size="*)
            item_size="${result##*size=}"
            ok "MENUBAR-PANEL-25 $result" ;;
        *)
            bad "[PANEL-25] the status item is '$result' (wanted length=variable image=template subviews=0 state=online dot=0 size=WxH)" ;;
    esac
    item_shots
    control panelopen && ok "[PANEL-4] the panel host opened" \
        || bad "[PANEL-4] panelopen: $CONTROL_REPLY"
    control paneldump panel "$WORK/menubar-shots/panel.json" \
        || bad "MENUBAR-SHOTS paneldump: $CONTROL_REPLY"
    # [PANEL-28] The fake phone reports an app in front; the card asks
    # task.front when it opens and draws the handoff row only after the reply.
    local handoff=0
    for _ in $(seq 1 20); do
        if control paneldump panel "$WORK/menubar-shots/panel.json" >/dev/null 2>&1 \
            && python3 - "$WORK/menubar-shots/panel.json" <<'PY'
import json, sys
root = json.load(open(sys.argv[1]))
rows = [row for row in root["items"] if row["kind"] == "continueOnMac"]
sys.exit(0 if rows and rows[0]["label"].startswith("Open ")
         and rows[0]["label"].endswith(" on Mac") else 1)
PY
        then handoff=1; break; fi
        sleep 0.25
    done
    [ "$handoff" = 1 ] \
        && ok "[PANEL-28] the card shows the foreground app row (Open <app> on Mac)" \
        || bad "[PANEL-28] no handoff row after the foreground reply"
    sleep 1
    shot_panel "panel-online-light.png"

    # [PANEL-3] The gear's menu anchors at the gear, not under the status item
    # (ISS-75). `gearanchor` reports the frame the gear's request pops at; the
    # menu is only opened when that frame is the gear's, because a menu under
    # the item would open on the person's own screen.
    local gear_anchor gear_pt gx gy
    if control panelpoint panel panel.gear "$shots/gear.pt" && read -r gx gy < "$shots/gear.pt"; then
        # After panelpoint's settle: the card's height (and so the gear's y)
        # follows its rows, and the anchor must be read from the same frame.
        control gearanchor || true
        gear_anchor="$CONTROL_REPLY"
        case "$gear_anchor" in
            "gear "*)
                read -r mainx mainy mainw mainh <<< "$(display_of main)"
                python3 - "$gear_anchor" "$gx" "$gy" "$mainh" <<'PY' && ok "[PANEL-3] the gear's menu anchors at the gear, not under the status item" \
                    || bad "[PANEL-3] the gear's anchor is not the gear's own frame"
import sys
words = sys.argv[1].split()
x, y = int(words[1]), int(words[2])
gx, gy = int(float(sys.argv[2])), int(float(sys.argv[3]))
# The gear is 22 pt square: its bottom-left is the anchor, under the click.
# `gearanchor` is AppKit (y up); panelpoint is Quartz (y down).
quartz_y = int(sys.argv[4]) - y
if abs(x - (gx - 11)) > 4 or abs(quartz_y - (gy + 11)) > 4:
    print("anchor", x, quartz_y, "gear bottom-left", gx - 11, gy + 11); sys.exit(1)
PY
                ;;
            *)
                bad "[PANEL-3] the gear's menu still anchors at the status item ($gear_anchor)" ;;
        esac
        # The real render: the hosted card with the gear's menu held open at
        # the gear. A quiet run cannot press Escape, so `gearhold` closes it.
        if [ "${gear_anchor%% *}" = "gear" ]; then
            control gearhold 4 || bad "MENUBAR-SHOTS gearhold: $CONTROL_REPLY"
            control panelclick panel panel.gear >/dev/null 2>&1 &
            local menu_click_pid=$!
            sleep 1
            local menu_rect panel_rect region
            menu_rect="$(app_menu_rect)"
            panel_rect="$(window_rect_at "$gx" "$gy")"
            if [ -n "$menu_rect" ] && [ -n "$panel_rect" ]; then
                region="$(union_rect "$menu_rect" "$panel_rect")"
                screencapture -x -R "$region" "$shots/gear-menu.png" >/dev/null 2>&1 \
                    && say "shot: $shots/gear-menu.png (the gear's menu, $region)" \
                    || bad "MENUBAR-SHOTS no gear menu screenshot"
            else
                bad "MENUBAR-SHOTS no menu or panel window for the gear's menu ($menu_rect / $panel_rect)"
            fi
            wait "$menu_click_pid" || bad "MENUBAR-SHOTS the gear's menu did not close"
        fi
    else
        bad "MENUBAR-SHOTS panelpoint panel panel.gear: $CONTROL_REPLY"
    fi

    # The real pointer (visible runs only): moving onto the DND tile changes
    # the picture, and the footer's Settings row opens Settings. The panel host
    # is the shared PhonePanelView in a real window, so these are the control's
    # own hover and click paths, not a forced state.
    # The Settings scene's window title is the selected tab ("Devices",
    # "General", …); its identifier is stable.
    settings_open() {
        local f="$shots/windows-settings.txt"
        control panelwindows "$f" >/dev/null 2>&1 || return 1
        grep -q "com_apple_SwiftUI_Settings_window" "$f"
    }
    if [ "$VISIBLE" = 1 ]; then
        local px py
        if control panelpoint panel panel.dnd "$shots/dnd.pt" \
            && read -r px py < "$shots/dnd.pt"; then
            # Start from a known pointer-away state, or a leftover hover makes
            # the before and after shots identical.
            cg_input moveat --x 4 --y 4
            sleep 0.5
            shot_panel "hover-tile-before.png"
            cg_input moveat --x "$px" --y "$py"
            sleep 1
            shot_panel "hover-tile-after.png"
            if cmp -s "$shots/hover-tile-before.png" "$shots/hover-tile-after.png"; then
                bad "MENUBAR-SHOTS moving the real pointer onto the DND tile did not change the picture"
            else
                ok "MENUBAR-SHOTS the real pointer on the DND tile changed the picture"
            fi
        else
            bad "MENUBAR-SHOTS panelpoint panel panel.dnd: $CONTROL_REPLY"
        fi
        if control panelpoint panel panel.gear "$shots/gear.pt" \
            && read -r px py < "$shots/gear.pt"; then
            cg_input clickat --x "$px" --y "$py"
            sleep 1
            if wait_for_menu shown; then
                ok "[CONV-MAC-10] the panel's gear opened the icon's menu"
            else
                bad "MENUBAR-SHOTS the gear opened no menu"
            fi
            # What a screen reader hears on the gear (CONV-MAC-21): its name,
            # and a help tag that names the three commands behind it.
            result="$(ax_tree)"
            case "$result" in
                *"Settings and more"*) ok "MENUBAR-SHOTS the gear's VoiceOver name is Settings and more" ;;
                *) bad "MENUBAR-SHOTS the gear has no VoiceOver name ($(printf '%s' "$result" | tr '\n' '|' | cut -c1-200))" ;;
            esac
            case "$result" in
                *"Settings, About and Quit"*) ok "MENUBAR-SHOTS the gear's help tag names Settings, About and Quit" ;;
                *) bad "MENUBAR-SHOTS the gear has no help tag ($(printf '%s' "$result" | tr '\n' '|' | cut -c1-200))" ;;
            esac
            cg_input key --keycode 125
            cg_input key --keycode 36
            wait_until 15 settings_open \
                && ok "MENUBAR-SHOTS the gear's Settings… opened Settings" \
                || bad "MENUBAR-SHOTS the gear's Settings… did not open Settings"
            osascript - "$APP_PID" <<'OSA' >/dev/null 2>&1 || true
on run argv
    set pidText to item 1 of argv
    tell application "System Events"
        set matches to every process whose unix id is (pidText as integer)
        if (count of matches) is 0 then return
        tell item 1 of matches
            set closed to false
            repeat with w in windows
                try
                    if (id of w as string) is "com_apple_SwiftUI_Settings_window" then
                        click button 1 of w
                        set closed to true
                        exit repeat
                    end if
                end try
            end repeat
            if not closed then
                try
                    click button 1 of window "Devices"
                end try
            end if
        end tell
    end tell
end run
OSA
            sleep 1
        else
            bad "MENUBAR-SHOTS panelpoint panel panel.gear: $CONTROL_REPLY"
        fi
        cg_input moveat --x 4 --y 4
    else
        skip_visible "MENUBAR-SHOTS a real pointer on the panel tile and footer row"
    fi
    # Make sure the pointer is not left over the panel for the ringing shot.
    control panelhoverout >/dev/null 2>&1 || true

    # Ringing: the row's own click; the phone answers ring.state, so the same
    # row reads Stop Ringing in the shot.
    control panelclick panel panel.ring || bad "MENUBAR-SHOTS panelclick ring: $CONTROL_REPLY"
    wait_until 20 events_have '"ev":"ring"' \
        && ok "[PANEL-11] the phone is ringing for the shot" \
        || bad "[PANEL-11] the phone did not ring"
    sleep 1
    shot_panel "panel-ringing-light.png"
    control panelclick panel panel.ring >/dev/null 2>&1 || true
    wait_until 10 events_have '"ev":"ring","seconds":0' \
        || bad "MENUBAR-SHOTS the phone kept ringing"

    # The Deck's popover: the same card above the grid (its own window).
    control panelclose >/dev/null 2>&1 || true
    control deckpanel && ok "[PANEL-18] the Deck popover opened" \
        || bad "[PANEL-18] deckpanel: $CONTROL_REPLY"
    sleep 2
    local id
    id="$(await_window '$4 >= 320 && $4 <= 340 && $5 >= 300')" \
        && screencapture -x -l"$id" "$shots/deck-popover-light.png" >/dev/null 2>&1 \
        && say "shot: $shots/deck-popover-light.png" \
        || bad "MENUBAR-SHOTS no Deck popover window"

    # Offline: away, the card stays and its controls dim as one group with the
    # Sound module's one reason (PANEL-19).
    stop_fakephone
    wait_until 10 no_fakephone
    sleep 18
    control panelopen >/dev/null 2>&1 || true
    sleep 1
    shot_panel "panel-offline-light.png"
    result="$(control paneldump panel "$WORK/menubar-shots/panel-offline.json" && echo dumped)"
    [ -n "$result" ] \
        && python3 - "$WORK/menubar-shots/panel-offline.json" <<'PY' \
        && ok "[PANEL-19] the offline card carries the offline reason" \
        || bad "[PANEL-19] no reason in the offline card"
import json, sys
root = json.load(open(sys.argv[1]))
if root["reason"] != "Connect your phone to use these.":
    print("reason:", repr(root["reason"])); sys.exit(1)
PY

    stop_app
    defaults delete "$DEFAULTS_SUITE" "notify.$device" >/dev/null 2>&1
    defaults delete "$DEFAULTS_SUITE" "showAppsInDock" >/dev/null 2>&1

    # The agent dot (PANEL-1/PANEL-25): the same item with an automation client
    # connected. A socket client is what the count follows; the probe says the
    # dot is in the drawing and the crop shows the glyph with it.
    FAKE_ARGS="--media" start_fake || return 1
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    launch --mcp-enable --connect "127.0.0.1:$PORT" --quit-after 90 --debug-control "$WORK-control"
    wait_until 30 events_have '"t":"apps.list"' \
        || { bad "MENUBAR-SHOTS the dot session never started"; stop_app; stop_fakephone; return 1; }
    local sock="$HOME/Library/Application Support/Contigua-$PROFILE/mcp.sock" agent_pid dot=0
    if ! wait_until 20 test -S "$sock"; then
        bad "MENUBAR-SHOTS no automation socket for the dot"
    else
        python3 - "$sock" >/dev/null 2>&1 <<'PY' &
import socket, sys, time
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(100):
    try:
        client.connect(sys.argv[1])
        break
    except OSError:
        time.sleep(0.1)
time.sleep(60)
PY
        agent_pid=$!
        for _ in $(seq 1 100); do
            control menubaricon || true
            case "$CONTROL_REPLY" in
                *"dot=1"*) dot=1; dot_size="${CONTROL_REPLY##*size=}"; break ;;
            esac
            sleep 0.1
        done
        [ "$dot" = 1 ] \
            && ok "[PANEL-1] the item carries the agent dot while a client is connected" \
            || bad "[PANEL-1] no agent dot with a client connected ($CONTROL_REPLY)"
        # [PANEL-25] The dot is drawn in a slot the image reserves in both
        # states: the item's image size never changes when an agent connects
        # (ISS-75), so the status item never shifts.
        if [ -n "$item_size" ] && [ "$dot_size" = "$item_size" ]; then
            ok "[PANEL-25] the agent dot keeps the item's image size ($item_size with and without)"
        else
            bad "[PANEL-25] the agent dot changed the item's image size (plain=$item_size dot=$dot_size)"
        fi
        # [PANEL-7] The card opens on its first tile, never on Disconnect
        # (ISS-75): with the agent row up the opening ring is still DND. A
        # quiet run cannot press a key into a non-activating panel, so the
        # check reads where the ring landed.
        control panelopen >/dev/null 2>&1 \
            || bad "MENUBAR-SHOTS panelopen for the agent: $CONTROL_REPLY"
        control panelfocus panel || true
        case "$CONTROL_REPLY" in
            panel.dnd)
                ok "[PANEL-7] the card opens on Do Not Disturb, not Disconnect, with an agent connected" ;;
            *)
                bad "[PANEL-7] the card opens on '$CONTROL_REPLY' with an agent connected" ;;
        esac
        control panelclose >/dev/null 2>&1 || true
        # The crop is taken while the client is still connected: the dot is in
        # the drawing, not a second view over the button.
        item_shots menubar-item-dot
        kill "$agent_pid" 2>/dev/null
        wait "$agent_pid" 2>/dev/null
        # And it leaves with the client: the image follows the count both ways.
        dot=0
        for _ in $(seq 1 100); do
            control menubaricon || true
            case "$CONTROL_REPLY" in *"dot=0"*) dot=1; break ;; esac
            sleep 0.1
        done
        [ "$dot" = 1 ] \
            && ok "[PANEL-1] the dot leaves when the client disconnects" \
            || bad "[PANEL-1] the dot stayed after the client left ($CONTROL_REPLY)"
    fi
    stop_app
    stop_fakephone
    wait_until 10 no_fakephone
    shoot_panel_states
}

# shoot_panel_states — the panel's states in both appearances, for the review:
# the rest state (Sound above the modules, Turn Off Screen disabled because no
# Phone Mirror is open), the same panel with the pointer forced onto the Focus
# module, an Apps button and the gear, and with Do Not Disturb on. Each
# appearance and phone state is its own launch, so no hover or menu state
# carries over.
shoot_panel_states() {
    local shots="$WORK/menubar-shots" app id
    mkdir -p "$shots"
    shoot_state() {
        local id
        id="$(await_window '$4 >= 300 && $4 <= 340 && $5 >= 300 && $5 <= 800')" \
            || { bad "PANEL-STATES no panel window for $1"; return 1; }
        screencapture -x -l"$id" "$shots/$1" >/dev/null 2>&1 && say "shot: $shots/$1"
    }
    for app in light dark; do
        FAKE_ARGS="--media" start_fake || return 1
        rm -rf "$WORK-control"
        mkdir -p "$WORK-control"
        launch --connect "127.0.0.1:$PORT" --quit-after 120 --debug-control "$WORK-control" --appearance "$app"
        wait_until 30 events_have '"t":"apps.list"' \
            || { bad "PANEL-STATES the session never started"; stop_app; stop_fakephone; return 1; }
        control panelopen && ok "[PANEL-4] the panel host opened ($app)" \
            || bad "[PANEL-4] panelopen: $CONTROL_REPLY"
        sleep 1
        shoot_state "states-$app-rest.png"
        # Turn Off Screen is disabled here (no Phone Mirror); the rest shot is
        # also the disabled-tile record, named for the review.
        cp "$shots/states-$app-rest.png" "$shots/states-$app-screen-disabled.png"
        say "shot: $shots/states-$app-screen-disabled.png"
        for id in panel.dnd panel.findApps panel.gear; do
            control panelhover panel "$id" || bad "PANEL-STATES panelhover $id: $CONTROL_REPLY"
            sleep 1
            shoot_state "states-$app-hover-${id#panel.}.png"
            control panelhoverout || bad "PANEL-STATES panelhoverout: $CONTROL_REPLY"
        done
        stop_app
        stop_fakephone
        wait_until 10 no_fakephone
    done
    for app in light dark; do
        FAKE_ARGS="--media --dnd-person priority" start_fake || return 1
        rm -rf "$WORK-control"
        mkdir -p "$WORK-control"
        launch --connect "127.0.0.1:$PORT" --quit-after 120 --debug-control "$WORK-control" --appearance "$app"
        wait_until 30 events_have '"t":"apps.list"' \
            || { bad "PANEL-STATES the DND session never started"; stop_app; stop_fakephone; return 1; }
        control panelopen || bad "PANEL-STATES panelopen (DND): $CONTROL_REPLY"
        sleep 1
        shoot_state "states-$app-dnd-on.png"
        stop_app
        stop_fakephone
        wait_until 10 no_fakephone
    done
}

# --- NFR: the limits in docs/NFR.md, end to end -----------------------------

# now_ms — wall-clock milliseconds, the unit every person-facing limit uses.
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# wait_ms <ms> <command...> — wait_until with the millisecond clock: a limit
# of 2000 ms must not round down to one second ($SECONDS truncates, so a 2 s
# wait_until can return after 1 s and fail a step that was within its limit).
wait_ms() {
    local end=$(( $(now_ms) + $1 ))
    shift
    while :; do
        "$@" && return 0
        [ "$(now_ms)" -lt "$end" ] || return 1
        sleep 0.1
    done
}

# first_event_ms KEY [VALUE] — the first event whose KEY (a dotted path) is
# VALUE (any value when omitted), in milliseconds. Empty when it never came.
first_event_ms() {
    python3 - "$WORK/events.jsonl" "$1" "${2:-}" <<'PY'
import json, sys
source, path, wanted = sys.argv[1], sys.argv[2], sys.argv[3]
for line in open(source, errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    value = event
    for key in path.split("."):
        value = value.get(key) if isinstance(value, dict) else None
    if wanted and str(value).lower() != wanted.lower():
        continue
    if event.get("ts") is not None:
        print(int(float(event["ts"]) * 1000))
    break
PY
}

# first_event_after_ms KEY [VALUE] AFTER_MS — like first_event_ms, but only an
# event at or after AFTER_MS: the phone window's first frame is not the app
# window's, and a later window reuses a stream id only by opening again.
first_event_after_ms() {
    python3 - "$WORK/events.jsonl" "$1" "${2:-}" "$3" <<'PY'
import json, sys
source, path, wanted, after = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
for line in open(source, errors="replace"):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ts") is None or int(float(event["ts"]) * 1000) < after:
        continue
    value = event
    for key in path.split("."):
        value = value.get(key) if isinstance(value, dict) else None
    if wanted and str(value).lower() != wanted.lower():
        continue
    print(int(float(event["ts"]) * 1000))
    break
PY
}

# first_ready_ms — the session is usable at `paired` (a fresh pairing) or
# `auth_ok` (a reconnect with the stored pin); both are the moment a person
# can act.
first_ready_ms() {
    local paired auth
    paired="$(first_event_ms state paired)"
    auth="$(first_event_ms state auth_ok)"
    if [ -z "$paired" ]; then echo "$auth"; return; fi
    if [ -z "$auth" ]; then echo "$paired"; return; fi
    [ "$paired" -lt "$auth" ] && echo "$paired" || echo "$auth"
}

# nfr_limit_s <key> — a millisecond limit as whole seconds (ceil), for wait_until.
nfr_limit_s() { local ms; ms="$(nfr_limit "$1")"; echo $(( (ms + 999) / 1000 )); }

# nfr_launch [args...] — one phase's app, quiet, with the control and chrome
# state files. `launch` truncates app.log; the events log is cleared by phase.
nfr_launch() {
    rm -rf "$WORK-control"
    mkdir -p "$WORK-control"
    rm -f "$WORK/chrome.txt"
    launch --connect "127.0.0.1:$PORT" --debug-control "$WORK-control" \
        --debug-chrome-state "$WORK/chrome.txt" --quit-after 420 "$@"
}

nfr_paired() {
    events_have '"state":"paired"' || events_have '"state":"auth_ok"'
}

# nfr_wait_ready <seconds> — the session is ready for a phase.
nfr_wait_ready() { wait_until "$1" nfr_paired; }

# nfr_measure <name> <limit-key> <start-ms> <event-path> [value] — one limit,
# logged with its value whether it passes or fails.
nfr_measure() {
    local name="$1" key="$2" start="$3" path="$4" value="${5:-}" limitMs limit arrived spent
    limitMs="$(nfr_limit "$key")"
    wait_until "$(nfr_limit_s "$key")" eval '[ -n "$(first_event_after_ms "$path" "${value:-}" "$start")" ]'
    arrived="$(first_event_after_ms "$path" "$value" "$start")"
    spent=$(( arrived - start ))
    say "NFR $name: ${spent} ms (limit ${limitMs} ms)"
    [ -n "$arrived" ] && [ "$spent" -le "$limitMs" ] \
        && ok "NFR $name: ${spent} ms < ${limitMs} ms" \
        || bad "NFR $name: ${spent:-?} ms, wanted <= ${limitMs} ms"
}

# nfr_writes_unchanged <phase> <before> — a read-only flow sent no write.
nfr_writes_unchanged() {
    local phase="$1" before="$2" after
    after="$(fake_counter writes)"
    [ "$after" = "$before" ] \
        && ok "NFR read-only $phase: writes stayed $after" \
        || bad "NFR read-only $phase: writes $before -> $after (last $(fake_counter last_write))"
}

# nfr_input_unchanged <mode> <before> — a frozen mode swallowed every input.
nfr_input_unchanged() {
    local mode="$1" before="$2" after
    after="$(fake_counter input)"
    [ "$after" = "$before" ] \
        && ok "NFR frozen $mode: input stayed $after" \
        || bad "NFR frozen $mode: input $before -> $after (last $(fake_counter last_input))"
}

# check_nfr — the gate in docs/NFR.md: time limits, read-only flows, frozen
# modes, stale picture, and the real-control family (the event path a person
# uses, with the phone counting the effect). Layout, contrast, honest settings
# and icon references are K2 (`nfr.sh` runs both).
check_nfr() {
    local connect_ms first_phone app_list first_app before after t0 start
    local pair_limit="$(nfr_limit connect_ms)"
    # input_at_least <n> — the fake phone's input counter, re-read on every
    # poll (a $( ) inside a wait_until argument is evaluated once, at the call).
    input_at_least() { [ "$(fake_counter input)" -ge "$1" ]; }
    clean
    python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
root = os.path.join(work, "fsroot")
for folder in ("Documents", "Documents/notes", "DCIM/Camera", "many", "Android/data/x"):
    os.makedirs(os.path.join(root, folder), exist_ok=True)
open(os.path.join(root, "Android/data/x/y"), "wb").write(b"hidden")
open(os.path.join(root, ".hidden"), "wb").write(b"hidden")
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
    FAKE_ARGS="--fs-root $WORK/fsroot --fs-chunk-delay-ms 2" start_fake || return 1
    # A build's first launch pays for dyld, the scene, Live Text and the control
    # host. That cold launch is not the one a person judges: two whole runs in a
    # row on the same build measured 3216 ms cold and 1284 ms warm (ISS-46,
    # 2026-11-06). Warm the process up once against a closed port, so it cannot
    # pair or cache icons for the measured launch, then time that launch.
    launch --connect "127.0.0.1:1" --quit-after 30
    sleep 5
    stop_app
    sleep 1
    t0="$(now_ms)"
    nfr_launch --files-bridge-dir "$WORK/bridge"
    nfr_wait_ready 30 || { bad "NFR the app never paired"; stop_app; stop_fakephone; return 1; }
    connect_ms="$(first_ready_ms)"
    say "NFR connect: $((connect_ms - t0)) ms (limit ${pair_limit} ms)"
    [ $((connect_ms - t0)) -le "$pair_limit" ] \
        && ok "NFR connect: $((connect_ms - t0)) ms < ${pair_limit} ms" \
        || bad "NFR connect: $((connect_ms - t0)) ms, wanted <= ${pair_limit} ms"

    # The Deck's first list and its icons are read-only.
    nfr_measure "app list" app_list_ms "$connect_ms" msg.t apps.list
    # The session's own setup (a paired phone answers with the DND/ringer sync)
    # is not one of the read-only flows; the flow starts once it settles.
    sleep 1
    before="$(fake_counter writes)"
    wait_until 20 have_layered_icons || bad "NFR no app icons arrived"
    nfr_writes_unchanged "Deck browsing and icons" "$before"

    # Phone window: open (first frame), close — no writes.
    start="$(now_ms)"
    control open --open-phone || bad "NFR the phone window did not open: $CONTROL_REPLY"
    nfr_measure "phone window's first frame" first_frame_phone_ms "$start" config true
    before="$(fake_counter writes)"
    control open --close-stream 1:0.1 || bad "NFR the phone window did not close: $CONTROL_REPLY"
    sleep 1
    nfr_writes_unchanged "phone window open/close" "$before"

    # An app window: first frame, then close. Read-only too.
    start="$(now_ms)"
    control open --open com.android.settings || bad "NFR the app window did not open: $CONTROL_REPLY"
    nfr_measure "app window's first frame" first_frame_ms "$start" config true
    before="$(fake_counter writes)"
    control open --close-stream 2:0.1 || bad "NFR the app window did not close: $CONTROL_REPLY"
    sleep 1
    nfr_writes_unchanged "app window open/close" "$before"

    # The files bridge: list/stat/read/cancel through the app, no write.
    wait_until 30 file_has "files-bridge: ok" "$WORK/app.log" \
        || bad "NFR the files bridge never listened"
    before="$(fake_counter writes)"
    files_bridge_driver read
    nfr_writes_unchanged "files list/stat/read" "$before"
    stop_app
    stop_fakephone

    # Live Text in an app window: enter/exit sends no write, and the frozen
    # mode sends no input (clicks, scroll, typing, the nav shortcuts).
    : > "$WORK/events.jsonl"
    start_fake || return 1
    rm -f "$WORK/lt-go" "$WORK/lt-exit"
    printf '%s\n' "enter 1" "wait-analysis" "waitfile $WORK/lt-go 120" \
        "waitfile $WORK/lt-exit 120" "exit" "wait-idle 30" "nav back" > "$WORK/lt-app.txt"
    printf '%s\n' "waitfile $WORK/lt-go 120" "click 0.5 0.5" "scroll 120" \
        "type hello" "key cmd+shift+h" "key cmd+[" "hover 0.5 0.5" "wait 1" > "$WORK/input-lt-app.txt"
    nfr_launch --open com.android.settings --debug-livetext "$WORK/lt-app.txt" \
        --debug-input-script "$WORK/input-lt-app.txt"
    nfr_wait_ready 30 || bad "NFR the app never paired (Live Text)"
    wait_until 120 grep -q '"op":"analysis"' "$WORK/app.log" \
        || bad "NFR Live Text never finished its analysis"
    before="$(fake_counter input)"
    touch "$WORK/lt-go"
    sleep 4
    nfr_input_unchanged "Live Text (app window)" "$before"
    after="$(fake_counter writes)"
    touch "$WORK/lt-exit"
    wait_until 30 grep -q '"op":"idle"' "$WORK/app.log" || bad "NFR Live Text never left the mode"
    wait_until 20 input_at_least $((before + 1)) \
        && ok "NFR frozen Live Text: Back after the exit reached the phone (input $(fake_counter input))" \
        || bad "NFR frozen Live Text: Back after the exit sent nothing (input $(fake_counter input))"
    nfr_writes_unchanged "Live Text enter/exit" "$after"
    stop_app
    stop_fakephone

    # Live Text in the phone window (the 10-20 merge regressed it there).
    : > "$WORK/events.jsonl"
    start_fake || return 1
    rm -f "$WORK/lt-go" "$WORK/lt-exit"
    printf '%s\n' "enter 1" "wait-analysis" "waitfile $WORK/lt-go 120" \
        "waitfile $WORK/lt-exit 120" "exit" "wait-idle 30" "nav back" > "$WORK/lt-phone.txt"
    printf '%s\n' "waitfile $WORK/lt-go 120" "click 0.5 0.5" "scroll 120" \
        "type hello" "key cmd+shift+h" "key cmd+[" "hover 0.5 0.5" "wait 1" > "$WORK/input-lt-phone.txt"
    nfr_launch --open-phone --debug-livetext "$WORK/lt-phone.txt" \
        --debug-input-script "$WORK/input-lt-phone.txt"
    nfr_wait_ready 30 || bad "NFR the app never paired (phone Live Text)"
    wait_until 120 grep -q '"op":"analysis"' "$WORK/app.log" \
        || bad "NFR phone Live Text never finished its analysis"
    before="$(fake_counter input)"
    touch "$WORK/lt-go"
    sleep 4
    nfr_input_unchanged "Live Text (phone window)" "$before"
    after="$(fake_counter writes)"
    touch "$WORK/lt-exit"
    wait_until 30 grep -q '"op":"idle"' "$WORK/app.log" || bad "NFR phone Live Text never left the mode"
    wait_until 20 input_at_least $((before + 1)) \
        && ok "NFR frozen phone Live Text: Back after the exit reached the phone (input $(fake_counter input))" \
        || bad "NFR frozen phone Live Text: Back after the exit sent nothing (input $(fake_counter input))"
    nfr_writes_unchanged "phone Live Text enter/exit" "$after"
    stop_app
    stop_fakephone

    # Screen off: the cover swallows scroll, typing and the nav shortcuts. A
    # click on the cover is the Wake Screen button by design, so it is not
    # part of the frozen set here; the same click is covered in Live Text.
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--screen-off-after 6" start_fake || return 1
    rm -f "$WORK/off-go" "$WORK/off-wake"
    printf '%s\n' "waitfile $WORK/off-go 120" "scroll 120" "type hello" \
        "key cmd+shift+h" "key cmd+[" "waitfile $WORK/off-wake 120" "nav back" > "$WORK/input-off.txt"
    nfr_launch --open-phone --debug-input-script "$WORK/input-off.txt"
    nfr_wait_ready 30 || bad "NFR the app never paired (screen off)"
    wait_until 20 chrome_has "overlay=1" || bad "NFR the screen-off cover never appeared"
    before="$(fake_counter input)"
    touch "$WORK/off-go"
    sleep 3
    nfr_input_unchanged "screen off" "$before"
    control wake-phone >/dev/null 2>&1 || true
    wait_until 20 chrome_has "screen=on overlay=0" || bad "NFR the screen never came back"
    touch "$WORK/off-wake"
    wait_until 20 input_at_least $((before + 1)) \
        && ok "NFR frozen screen off: Back after the wake reached the phone (input $(fake_counter input))" \
        || bad "NFR frozen screen off: Back after the wake sent nothing (input $(fake_counter input))"
    stop_app
    stop_fakephone

    # Secure surface: the same frozen set behind the secure cover. There is no
    # Wake button there (the phone clears the cover itself), so nothing on the
    # window may reach the PIN pad.
    : > "$WORK/events.jsonl"
    FAKE_ARGS="--secure-after 6" start_fake || return 1
    rm -f "$WORK/sec-go"
    printf '%s\n' "waitfile $WORK/sec-go 120" "scroll 120" "type hello" \
        "key cmd+shift+h" "key cmd+[" "wait 1" > "$WORK/input-secure.txt"
    nfr_launch --open-phone --debug-input-script "$WORK/input-secure.txt"
    nfr_wait_ready 30 || bad "NFR the app never paired (secure)"
    wait_until 20 chrome_has "overlay=1 secure=1" || bad "NFR the secure cover never appeared"
    before="$(fake_counter input)"
    touch "$WORK/sec-go"
    sleep 3
    nfr_input_unchanged "secure cover" "$before"
    stop_app
    stop_fakephone

    # Disconnected: the phone goes away; input stays home until it is back.
    : > "$WORK/events.jsonl"
    start_fake || return 1
    rm -f "$WORK/disc-go"
    # The script ends with the outage: the reconnect wait happens outside the
    # app, so its retry timers are never inside a nested script run loop.
    printf '%s\n' "waitfile $WORK/disc-go 120" "scroll 120" "type hello" \
        "key cmd+shift+h" > "$WORK/input-disc.txt"
    nfr_launch --open-phone --debug-input-script "$WORK/input-disc.txt"
    nfr_wait_ready 30 || bad "NFR the app never paired (disconnected)"
    wait_until 20 events_have '"ev":"video"' || bad "NFR no video before the disconnect"
    stop_fakephone
    wait_until 20 events_have '"state":"closed"' || bad "NFR the link never reported the disconnect"
    sleep 1
    before="$(fake_counter input)"
    touch "$WORK/disc-go"
    sleep 3
    nfr_input_unchanged "disconnected" "$before"
    start_fake || bad "NFR the phone did not come back"
    # The reconnect backoff doubles; a 64 s wait can fall between attempts.
    wait_until 150 events_have '"state":"auth_ok"' \
        || bad "NFR the window never reconnected (app: $(tail -1 "$WORK/app.log" 2>/dev/null); fake: $(tail -1 "$WORK/fake.err" 2>/dev/null); state: $(chrome_state))"
    wait_until 20 events_have '"ev":"video"' || true
    # A reconnect can flush an input the app held while the link was down; it
    # belongs to the outage, so the baseline is read after it settles.
    sleep 2
    # The new fake starts its counters at zero; the phone is back, so one Back
    # must now move them.
    after="$(fake_counter input)"
    control nav back || bad "NFR the Navigate action did not run after the reconnect: $CONTROL_REPLY"
    wait_until 40 input_at_least $((after + 1)) \
        && ok "NFR frozen disconnected: Back after the reconnect reached the phone (input $(fake_counter input))" \
        || bad "NFR frozen disconnected: Back after the reconnect sent nothing (input $(fake_counter input))"
    stop_app
    stop_fakephone

    # Frozen picture: the phone stops sending frames with the session still up.
    # The window must say so within stale_picture_ms, and say it visibly: the
    # disconnection overlay in the view tree with the app's icon
    # (stall_overlay=1 stall_icon=1), not just the `stall=` flag (WIN-39). Both
    # window styles, and the overlay goes when frames resume. One window per
    # launch so the chrome state file is that window's.
    local kind stall_ms stale_ms
    stale_ms="$(nfr_limit stale_picture_ms)"
    for kind in immersive framed; do
        : > "$WORK/events.jsonl"
        defaults write "$DEFAULTS_SUITE" "chrome.style.com.android.settings" -string "$([ "$kind" = framed ] && echo mat || echo "$kind")"
        # --stall-for: the encoder restarts after the stall, so the state must
        # clear again (a pill that never goes away would fail the last check).
        FAKE_ARGS="--stall-after 3 --stall-for 6" start_fake || return 1
        nfr_launch --open com.android.settings
        nfr_wait_ready 30 || bad "NFR the app never paired (stall, $kind)"
        wait_until 30 events_have '"ev":"stall"' || bad "NFR the fake never stalled ($kind)"
        stall_ms="$(first_event_ms ev stall)"
        if wait_ms "$stale_ms" chrome_has "stall=1"; then
            local shown_ms=$(( $(now_ms) - stall_ms ))
            ok "NFR no stale picture ($kind): the window said the picture stopped after ${shown_ms} ms (limit ${stale_ms} ms)"
        else
            bad "NFR no stale picture ($kind): the window kept the last frame as live for ${stale_ms} ms (state: $(chrome_state))"
        fi
        if wait_until 3 chrome_has "stall_overlay=1 stall_icon=1" && chrome_has "style=$kind"; then
            ok "NFR stall is visible ($kind): the \"Not responding\" overlay with its icon is in the window (state: $(chrome_state))"
        else
            bad "NFR stall is visible ($kind): the chrome has no \"Not responding\" overlay with its icon (state: $(chrome_state))"
        fi
        say "NFR stall ($kind): frames stopped, state $(chrome_state)"
        wait_until 20 events_have '"ev":"resume"' || bad "NFR the fake never resumed frames ($kind)"
        if wait_until 10 chrome_has "stall=0 stall_overlay=0"; then
            ok "NFR stall is visible ($kind): frames resumed and the overlay went away (state: $(chrome_state))"
        else
            bad "NFR stall is visible ($kind): the overlay stayed after frames resumed (state: $(chrome_state))"
        fi
        stop_app
        stop_fakephone
    done

    # A power press with app streams up (docs/PROTOCOL.md "Phone screen",
    # `power.locked`): the phone re-lights its VD group at the edge, so the
    # window holds the last frame for a grace under stale_picture_ms — no
    # "Not responding" pill and no frozen input block — and a real stall after
    # the grace still says so. The fake stalls and reports the press together.
    : > "$WORK/events.jsonl"
    defaults write "$DEFAULTS_SUITE" "chrome.style.com.android.settings" -string mat
    FAKE_ARGS="--stall-after 3 --power-locked-after 3.1" start_fake || return 1
    nfr_launch --open com.android.settings
    nfr_wait_ready 30 || bad "NFR the app never paired (power press)"
    wait_until 30 events_have '"ev":"stall"' || bad "NFR the fake never stalled (power press)"
    wait_until 10 events_have '"ev":"power_locked"' || bad "NFR the fake never sent power.locked"
    local locked_ms
    locked_ms="$(first_event_ms ev power_locked)"
    sleep 1
    if chrome_has "stall=0 stall_overlay=0"; then
        ok "NFR power press: the window held the last frame, no \"Not responding\" overlay (state: $(chrome_state))"
    else
        bad "NFR power press: the window called the phone's own press a stall (state: $(chrome_state))"
    fi
    before="$(fake_counter input)"
    control nav back || bad "NFR power press: $CONTROL_REPLY"
    wait_until 5 input_at_least $((before + 1)) \
        && ok "NFR power press: input still reached the phone inside the grace" \
        || bad "NFR power press: input was blocked inside the grace (input $before -> $(fake_counter input))"
    # The grace is 1.7 s from the report: wait from there, not from "now", so
    # the steps above cannot close the window before the re-stall.
    while [ "$(now_ms)" -lt $(( locked_ms + 1700 )) ]; do sleep 0.1; done
    say "NFR power press: $(( $(now_ms) - locked_ms )) ms after the press, waiting for a real stall"
    if wait_ms 2500 chrome_has "stall=1 stall_overlay=1"; then
        ok "NFR power press: a real stall after the grace still says \"Not responding\" (state: $(chrome_state))"
    else
        bad "NFR power press: no stall after the grace with the frames still stopped (state: $(chrome_state))"
    fi
    stop_app
    stop_fakephone

    # Occlusion: a covered window is not a live picture. AppKit throttles an
    # occluded app, so the frames stop without the phone being at fault; the
    # watchdog must not call that a stall, and the clock restarts when the
    # window is visible again. The quiet run may not cover the window (no extra
    # windows), so the app's `occlude` debug command reports what the
    # WindowServer would have said for the first window.
    : > "$WORK/events.jsonl"
    defaults write "$DEFAULTS_SUITE" "chrome.style.com.android.settings" -string immersive
    # --stall-after 8: the caller has to be up and covered before the phone
    # stops, and under load `nfr_wait_ready` alone can take seconds; at 3 the
    # stall (and its 12 s resume) could be over before `occlude on`, leaving the
    # window live and the last two lines here unable to judge anything.
    FAKE_ARGS="--stall-after 8 --stall-for 12" start_fake || return 1
    nfr_launch --open com.android.settings
    nfr_wait_ready 30 || bad "NFR the app never paired (occlusion)"
    control occlude on || bad "NFR occlude on: $CONTROL_REPLY"
    local occlude_ms
    occlude_ms="$(now_ms)"
    # The stall must happen while the window is covered: a stale event from
    # before the cover would say nothing about the covered time.
    wait_until 30 eval '[ -n "$(first_event_after_ms ev stall "$occlude_ms")" ]' \
        || bad "NFR the fake never stalled while the window was covered (occlusion)"
    sleep 3
    if chrome_has "stall=0 stall_overlay=0"; then
        ok "NFR occlusion: a covered window did not call the stopped picture a stall"
    else
        bad "NFR occlusion: the covered window said the picture stopped (state: $(chrome_state))"
    fi
    control occlude off || bad "NFR occlude off: $CONTROL_REPLY"
    # The covered time must not count: no stall in the first second after the
    # window is visible again...
    sleep 1
    if chrome_has "stall=0"; then
        ok "NFR occlusion: uncovering did not stall the first second"
    else
        bad "NFR occlusion: the covered time counted as silence (state: $(chrome_state))"
    fi
    # ...and 1.5 s of real silence after that is a stall, with the overlay.
    if wait_ms "$stale_ms" chrome_has "stall=1 stall_overlay=1"; then
        ok "NFR occlusion: real silence after uncovering still stalls"
    else
        bad "NFR occlusion: a real silence after uncovering was not reported (state: $(chrome_state))"
    fi
    wait_until 20 events_have '"ev":"resume"' || bad "NFR the fake never resumed frames (occlusion)"
    if wait_until 10 chrome_has "stall=0 stall_overlay=0"; then
        ok "NFR occlusion: frames resumed and the stall went away"
    else
        bad "NFR occlusion: the stall stayed after frames resumed (state: $(chrome_state))"
    fi
    stop_app
    stop_fakephone
}



check_orphans() {
    end_shared
    sleep 1
    local n
    n="$(e2e_app_pids | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan Contigua processes" || bad "C9 $n orphan Contigua processes"
    n="$(pgrep -f -- "--events $WORK/events.jsonl" | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan fakephone processes" || bad "C9 $n orphan fakephone processes"
}

# hotkey_report — ControlCenter logs one "hotkeys perform:" line per press and
# per repeat of a held media key. A quiet run presses none at all; a visible run
# may press keys for real, but six of them in a row within two seconds is a key
# that is down, not being pressed — the shape of the incident where a stuck
# brightness-down key ran ControlCenter's hotkey 12 times a second for four
# hours (qol-1027b item 1).
hotkey_report() {
    local times total streak
    times="$(/usr/bin/log show --start "$RUN_START" --style compact \
        --predicate 'process == "ControlCenter" AND eventMessage CONTAINS "hotkeys perform:"' 2>/dev/null \
        | awk '$1 ~ /^[0-9][0-9][0-9][0-9]-/ { print $1 " " $2 }')"
    total="$(printf '%s' "$times" | grep -c . || true)"
    if [ "$VISIBLE" != "1" ]; then
        [ "$total" = 0 ] \
            && ok "C17 no ControlCenter hotkey in a quiet run" \
            || bad "C17 $total ControlCenter hotkey lines in a quiet run: $(printf '%s' "$times" | head -3 | tr '\n' ' ')"
        return 0
    fi
    # A held key repeats: consecutive lines are at most 2 s apart and pile up.
    streak="$(printf '%s\n' "$times" | python3 -c '
import datetime
import sys

run = 0
longest = 0
last = None
for line in sys.stdin:
    fields = line.split()
    if len(fields) < 2:
        continue
    stamp = datetime.datetime.strptime(fields[0] + " " + fields[1].split(".")[0],
                                       "%Y-%m-%d %H:%M:%S")
    if last is not None and (stamp - last).total_seconds() <= 2:
        run += 1
    else:
        run = 1
    last = stamp
    longest = max(longest, run)
print(longest)
')"
    [ "$streak" -le 5 ] \
        && ok "C17 no key repeats: longest ControlCenter hotkey run $streak in 2 s ($total presses)" \
        || bad "C17 $streak ControlCenter hotkey lines in a row within 2 s (a held key)"
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

# build_e2e_app — bundles the current tree to build/e2e/Contigua.app, once per
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
# Before the build: a killed earlier run's app copy and Share extension leave
# the person's menus with the first quiet run of this one (docs/design/e2e-rig.md).
sweep_test_registrations
pick_run
mkdir -p "$WORK"
# The run's screenshots: one directory for the whole run, so a check's shots
# outlive the phases (and the checks) that follow it.
rm -rf "$SHOTS"
mkdir -p "$SHOTS"
# The window the hotkey check (C17) reads back: from here to the end of the run.
RUN_START="$(date "+%Y-%m-%d %H:%M:%S")"
say "run: port $PORT, work $WORK, profile $PROFILE, app $E2E_BUNDLE"
[ "$which_check" = "all" ] && say "checks: ${CHECKS[*]}"
build_e2e_app || exit 1
build_cgevent || exit 1
build_menubar_item || exit 1
build_ax_dump || exit 1
build_share_driver || exit 1
build_watch || exit 1
build_vdisplay || exit 1
build_load || exit 1
init_watchdog
start_load
start_vdisplay "$(vdisplay_size_for "${CHECKS[0]}")" "$(vdisplay_scale_for "${CHECKS[0]}")" || exit 1
start_watch
for check in "${CHECKS[@]}"; do
    # PD_E2E_MARKS (scripts/e2e-cost.py --by-check): when each check started.
    [ -n "${PD_E2E_MARKS:-}" ] && echo "$(date +%s) $check" >> "$PD_E2E_MARKS"
    ensure_vdisplay "$check" || exit 1
    "check_${check//-/_}"
done
[ "$which_check" = "all" ] && check_orphans

hotkey_report
quiet_report
watchdog_report
load_report
say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" = "0" ]
