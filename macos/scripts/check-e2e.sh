#!/usr/bin/env bash
# End-to-end checks C3-C13 for the macOS client against tools/fakephone.
#
#   ./scripts/check-e2e.sh [qr|pair|render|resize|input|input-global|pause|direct|nav|spotlight|pinch|all]
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
# The app runs under its own profile (`--profile e2e`) from its own bundle,
# build/e2e/PocketDeck.app, rebuilt from the current tree on every run. The
# default profile (the user's pairings, cached phones and defaults) and the
# user's build/PocketDeck.app are never read, rebuilt or killed here.
set -uo pipefail

MACOS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
FAKEPHONE="$ROOT/tools/fakephone/fakephone.py"
PROFILE="e2e"
E2E_BUNDLE="$MACOS/build/e2e/PocketDeck.app"
APP="$E2E_BUNDLE/Contents/MacOS/PocketDeck"
CGINPUT="$MACOS/scripts/cgevent-input.swift"
TOOLS="/tmp/pocketdeck-e2e-tools"
CGBIN="$TOOLS/cgevent"
LOCK_DIR="/tmp/pocketdeck-e2e.lock"
KEYCHAIN_SERVICE="dev.pocketdeck.mac.$PROFILE"
DEFAULTS_SUITE="dev.pocketdeck.mac.$PROFILE"

PASS=0
FAIL=0

# macOS removes app windows from the on-screen window list (and breaks
# `screencapture -l`) while the display is asleep, so keep it awake for the run.
caffeinate -d -u -t 900 &
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
    fi
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
    defaults delete "$DEFAULTS_SUITE" >/dev/null 2>&1
    return 0
}

clean() {
    kill_e2e_app
    stop_fakephone
    sleep 1
    rm -rf "$WORK"
    mkdir -p "$WORK"
    clear_profile_state
}

# start_fake [state-file] — same port every time, never mDNS.
start_fake() {
    local state="${1:-$WORK/state.json}"
    python3 "$FAKEPHONE" --port "$PORT" --no-mdns --auto-allow \
        --code-file "$WORK/pd.code" --events "$WORK/events.jsonl" \
        --state "$state" > "$WORK/fake.log" 2>&1 &
    FAKE_PID=$!
    for _ in $(seq 1 40); do
        grep -q "listening" "$WORK/fake.log" && return 0
        sleep 0.25
    done
    say "fakephone did not start:"; cat "$WORK/fake.log"; return 1
}

# launch <args...> — starts the app as a direct child so `wait` works.
launch() {
    "$APP" --profile "$PROFILE" "$@" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
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
stop_fakephone() { pkill -f -- "--events $WORK/events.jsonl" >/dev/null 2>&1; }

# The CGEvent helper is compiled once: `swift file.swift` re-interprets the
# source on every call, which is seconds per window lookup.
build_cgevent() {
    if [ ! -x "$CGBIN" ] || [ "$CGINPUT" -nt "$CGBIN" ]; then
        mkdir -p "$TOOLS"
        swiftc -O "$CGINPUT" -o "$CGBIN" >/dev/null 2>&1 || { say "could not build $CGINPUT"; return 1; }
    fi
}

windows() { "$CGBIN" list; }

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
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings,com.whatsapp --open-phone --quit-after 18
    wait_app
    grep -q '"state":"paired"' "$WORK/events.jsonl" \
        && ok "C4 first launch paired" || bad "C4 first launch did not pair"
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
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --open-phone --quit-after 40
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
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --resize-stream 1:800x600-pt --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":1600,"h":1200' \
        && ok "C6 new video config 1600x1200" || bad "C6 no new config"
    events_have '"t":"window.resize"' \
        && ok "C6 window.resize sent" || bad "C6 no window.resize"
    screenshot 800 "$WORK/resize.png" && say "screenshot: $WORK/resize.png"
    stop_app

    # Non-16:9 shapes: tall, then ultra-wide (capped at 2560 px, aspect kept).
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --resize-stream 1:600x1000-pt --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":1200,"h":2000' \
        && ok "C6 tall shape resized to 1200x2000" || bad "C6 no tall config"
    screenshot 600 "$WORK/resize-tall.png" && say "screenshot: $WORK/resize-tall.png"
    stop_app

    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --resize-stream 1:1600x500-pt --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,"config":true,"w":2560,"h":800' \
        && ok "C6 ultra-wide capped to 2560x800 (aspect kept)" || bad "C6 no capped config"
    events_have '"dpi":256' \
        && ok "C6 capped size lowers the dpi to 256" || bad "C6 dpi did not follow the cap"
    screenshot 1600 "$WORK/resize-wide.png" || screenshot_widest "$WORK/resize-wide.png" \
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
    printf '%s\n' "click 0.5 0.5" "drag 0.5 0.5 0.7 0.5" "scroll 3" "type hi" \
        "rightclick 0.5 0.5" > "$WORK/input.txt"
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
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
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --quit-after 60
    wait_until 30 events_have '"ev":"video","stream":1,' || bad "C7 no video config"
    local win
    win="$(await_window '$4 == 900')" || { bad "C7 no app window"; stop_app; return 1; }
    "$CGBIN" click --window "$win" >/dev/null
    "$CGBIN" drag --window "$win" --dx 200 --dy 0 --steps 20 >/dev/null
    "$CGBIN" scroll --window "$win" --dy 3 >/dev/null
    "$CGBIN" type --text hi >/dev/null
    "$CGBIN" rclick --window "$win" >/dev/null
    wait_until 15 events_have '"action":"back"'
    assert_input
    stop_app
    stop_fakephone
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
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
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

# --- C8: pause/resume -----------------------------------------------------

check_pause() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --minimize-stream 1:6 --deminimize-stream 1:11 --quit-after 16
    wait_app
    [ "$(count_events '"t":"window.pause"')" = "1" ] \
        && ok "C8 exactly one window.pause" || bad "C8 pause count $(count_events '"t":"window.pause"')"
    [ "$(count_events '"t":"window.resume"')" = "1" ] \
        && ok "C8 exactly one window.resume" || bad "C8 resume count $(count_events '"t":"window.resume"')"
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
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" --quit-after 16
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
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
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
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" --quit-after 18
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

# --- C9: no leftovers -----------------------------------------------------

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
    if ! "$MACOS/scripts/bundle.sh" "$E2E_BUNDLE" > "$WORK/bundle.log" 2>&1; then
        say "could not bundle $E2E_BUNDLE:"; tail -20 "$WORK/bundle.log"; return 1
    fi
}

which_check="${1:-all}"
case "$which_check" in
    qr|pair|render|resize|input|input-global|pause|direct|nav|spotlight|pinch|all) ;;
    *) say "usage: check-e2e.sh [qr|pair|render|resize|input|input-global|pause|direct|nav|spotlight|pinch|all]"; exit 2 ;;
esac
acquire_lock
wait_for_other_runs
pick_run
mkdir -p "$WORK"
say "run: port $PORT, work $WORK, profile $PROFILE, app $E2E_BUNDLE"
build_e2e_app || exit 1
build_cgevent || exit 1
case "$which_check" in
    qr)       check_qr ;;
    pair)     check_pair ;;
    render)   check_render ;;
    resize)   check_resize ;;
    input)    check_input ;;
    input-global) check_input_global ;;
    pinch)    check_pinch ;;
    pause)    check_pause ;;
    direct)   check_direct ;;
    nav)      check_nav ;;
    spotlight) check_spotlight ;;
    all)      check_qr; check_pair; check_render; check_resize; check_input; check_pinch
              check_pause; check_direct; check_nav; check_spotlight; check_orphans ;;
esac

say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" = "0" ]
