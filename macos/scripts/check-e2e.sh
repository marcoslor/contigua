#!/usr/bin/env bash
# End-to-end checks C4-C8 for the macOS client against tools/fakephone.
#
#   ./scripts/check-e2e.sh [pair|render|resize|input|pause|direct|nav|spotlight|all]
#
# Every check starts from a clean slate: no PocketDeck/fakephone processes, a
# fresh fakephone state file and no pairing key in the Keychain (a key created
# by a *different* build would make macOS prompt for Keychain access, which is
# why C4 asks for the key to be deleted first).
set -uo pipefail

MACOS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
FAKEPHONE="$ROOT/tools/fakephone/fakephone.py"
APP="$MACOS/build/PocketDeck.app/Contents/MacOS/PocketDeck"
CGINPUT="$MACOS/scripts/cgevent-input.swift"
WORK="/tmp/pocketdeck-e2e"
PORT=47000
KEYCHAIN_SERVICE="dev.pocketdeck.mac"

PASS=0
FAIL=0

# macOS removes app windows from the on-screen window list (and breaks
# `screencapture -l`) while the display is asleep, so keep it awake for the run.
caffeinate -d -u -t 900 &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" >/dev/null 2>&1' EXIT
caffeinate -u -t 1

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf 'PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

clean() {
    pkill -f "PocketDeck.app/Contents/MacOS/PocketDeck" >/dev/null 2>&1
    pkill -f fakephone.py >/dev/null 2>&1
    sleep 1
    rm -rf "$WORK"
    mkdir -p "$WORK"
    security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1
    defaults delete dev.pocketdeck.mac cachedAddresses >/dev/null 2>&1
    defaults delete dev.pocketdeck.mac cachedDeviceNames >/dev/null 2>&1
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
    "$APP" "$@" > "$WORK/app.log" 2>&1 &
    APP_PID=$!
}

wait_app() {
    wait "$APP_PID" 2>/dev/null
}

windows() { swift "$CGINPUT" list; }

# screenshot <width> <file> — capture the app's window of that point width.
screenshot() {
    local width="$1" file="$2"
    local id
    id="$(windows | awk -v w="$width" '$4 == w {print $1; exit}')"
    [ -n "$id" ] || { say "no window of width $width"; return 1; }
    screencapture -x -l"$id" "$file"
}

# screenshot_portrait <file> — capture the phone (portrait) window.
screenshot_portrait() {
    local file="$1" id
    id="$(windows | awk '$5 > $4 {print $1; exit}')"
    [ -n "$id" ] || { say "no portrait window"; return 1; }
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
    [ "$(windows | wc -l | tr -d ' ')" -ge 2 ] \
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
    pkill -f fakephone.py >/dev/null 2>&1
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
    pkill -f fakephone.py >/dev/null 2>&1
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
    pkill -f fakephone.py >/dev/null 2>&1
}

# --- C5: rendering --------------------------------------------------------

check_render() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --open-phone --quit-after 20
    sleep 9
    local app_shot="$WORK/render-app.png" phone_shot="$WORK/render-phone.png"
    if screenshot 900 "$app_shot"; then
        local stats; stats="$(brightness "$app_shot")"
        say "app window $stats"
        local ymin ymax
        ymin="$(echo "$stats" | grep -oE 'YMIN=[0-9]+' | cut -d= -f2)"
        ymax="$(echo "$stats" | grep -oE 'YMAX=[0-9]+' | cut -d= -f2)"
        [ $((ymax - ymin)) -gt 60 ] && ok "C5 app window not black ($stats)" || bad "C5 app window black ($stats)"
    else
        bad "C5 could not screenshot the app window"
    fi
    if screenshot_portrait "$phone_shot"; then
        local stats; stats="$(brightness "$phone_shot")"
        local ymin ymax
        ymin="$(echo "$stats" | grep -oE 'YMIN=[0-9]+' | cut -d= -f2)"
        ymax="$(echo "$stats" | grep -oE 'YMAX=[0-9]+' | cut -d= -f2)"
        [ $((ymax - ymin)) -gt 60 ] && ok "C5 phone window not black ($stats)" || bad "C5 phone window black ($stats)"
    else
        bad "C5 could not screenshot the phone window"
    fi
    say "screenshots: $app_shot $phone_shot"
    wait_app
    pkill -f fakephone.py >/dev/null 2>&1
}

# --- C6: resize -----------------------------------------------------------

check_resize() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --resize-stream 1:800x600-pt --quit-after 16
    sleep 10
    grep -q '"t":"window.resize"' "$WORK/events.jsonl" \
        && ok "C6 window.resize sent" || bad "C6 no window.resize"
    grep '"ev":"video"' "$WORK/events.jsonl" | grep -q '"w":1600,"h":1200' \
        && ok "C6 new video config 1600x1200" || bad "C6 no new config"
    screenshot 800 "$WORK/resize.png" && say "screenshot: $WORK/resize.png"
    wait_app

    # Non-16:9 shapes: tall, then ultra-wide (capped at 2560 px, aspect kept).
    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --resize-stream 1:600x1000-pt --quit-after 16
    sleep 10
    grep '"ev":"video"' "$WORK/events.jsonl" | grep -q '"w":1200,"h":2000' \
        && ok "C6 tall shape resized to 1200x2000" || bad "C6 no tall config"
    screenshot 600 "$WORK/resize-tall.png" && say "screenshot: $WORK/resize-tall.png"
    wait_app

    launch --connect "127.0.0.1:$PORT" --open com.android.settings \
        --resize-stream 1:1600x500-pt --quit-after 16
    sleep 10
    grep '"ev":"video"' "$WORK/events.jsonl" | grep -q '"w":2560,"h":800' \
        && ok "C6 ultra-wide capped to 2560x800 (aspect kept)" || bad "C6 no capped config"
    grep -q '"dpi":256' "$WORK/events.jsonl" \
        && ok "C6 capped size lowers the dpi to 256" || bad "C6 dpi did not follow the cap"
    screenshot 1600 "$WORK/resize-wide.png" || screenshot_widest "$WORK/resize-wide.png" \
        && say "screenshot: $WORK/resize-wide.png"
    wait_app
    pkill -f fakephone.py >/dev/null 2>&1
}

# --- C7: input ------------------------------------------------------------

check_input() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --quit-after 26
    sleep 8
    local win
    win="$(windows | awk '$4 == 900 {print $1; exit}')"
    [ -n "$win" ] || { bad "C7 no app window"; wait_app; return 1; }
    swift "$CGINPUT" click --window "$win" >/dev/null
    sleep 1
    swift "$CGINPUT" drag --window "$win" --dx 200 --dy 0 --steps 20 >/dev/null
    sleep 1
    swift "$CGINPUT" scroll --window "$win" --dy 3 >/dev/null
    sleep 1
    swift "$CGINPUT" type --text hi >/dev/null
    sleep 1
    swift "$CGINPUT" rclick --window "$win" >/dev/null
    sleep 1

    local down moves up
    down="$(grep -c '"kind":"touch","stream":1,"action":0' "$WORK/events.jsonl" || true)"
    moves="$(grep -c '"kind":"touch","stream":1,"action":2' "$WORK/events.jsonl" || true)"
    up="$(grep -c '"kind":"touch","stream":1,"action":1' "$WORK/events.jsonl" || true)"
    [ "${down:-0}" -ge 1 ] && ok "C7 touch down ($down)" || bad "C7 no touch down"
    [ "${moves:-0}" -ge 5 ] && ok "C7 drag moves ($moves)" || bad "C7 only $moves move events"
    [ "${up:-0}" -ge 1 ] && ok "C7 touch up ($up)" || bad "C7 no touch up"

    local first
    first="$(grep '"kind":"touch","stream":1,"action":0' "$WORK/events.jsonl" | head -1)"
    local nx ny
    nx="$(echo "$first" | grep -oE '"nx":[-0-9.]+' | cut -d: -f2)"
    ny="$(echo "$first" | grep -oE '"ny":[-0-9.]+' | cut -d: -f2)"
    python3 - "$nx" "$ny" <<'PY' && ok "C7 down at center (nx=$nx ny=$ny)" || bad "C7 down not centered (nx=$nx ny=$ny)"
import sys
nx, ny = float(sys.argv[1]), float(sys.argv[2])
sys.exit(0 if abs(nx - 0.5) <= 0.03 and abs(ny - 0.5) <= 0.03 else 1)
PY

    [ "$(grep -c '"kind":"scroll","stream":1' "$WORK/events.jsonl")" -ge 1 ] \
        && ok "C7 scroll event" || bad "C7 no scroll event"
    grep -q '"t":"text"' "$WORK/events.jsonl" \
        && ok "C7 typed text" || bad "C7 no text event"
    grep -q '"t":"nav"' "$WORK/events.jsonl" && grep -q '"action":"back"' "$WORK/events.jsonl" \
        && ok "C7 right click -> nav back" || bad "C7 no nav back"
    wait_app
    pkill -f fakephone.py >/dev/null 2>&1
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
    pkill -f fakephone.py >/dev/null 2>&1
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
    cached="$(defaults read dev.pocketdeck.mac cachedAddresses 2>/dev/null || true)"
    case "$cached" in
        *127.0.0.1:$PORT*) ok "C10a cached address stored ($cached)" ;;
        *) bad "C10a no cached address: $cached" ;;
    esac
    pkill -f fakephone.py >/dev/null 2>&1
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
    pkill -f fakephone.py >/dev/null 2>&1
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
    cached="$(defaults read dev.pocketdeck.mac cachedAddresses 2>/dev/null || true)"
    case "$cached" in
        *127.0.0.1:$PORT*) bad "C10c cached address kept after the mismatch" ;;
        *) ok "C10c cached address dropped after the mismatch" ;;
    esac
    pkill -f fakephone.py >/dev/null 2>&1
}

# --- C11: navigation shortcuts --------------------------------------------

# check_nav — ⌘[ and Esc in an app window are `nav back`; ⇧⌘H and ⌘↑ in the
# phone window are `nav home` / `nav recents` (fakephone logs them as rx "nav").
# Two launches: with both windows open they overlap, and a click aimed at one
# can land on the other in front.
check_nav() {
    clean
    local attempts="${PD_NAV_ATTEMPTS:-3}"

    nav_counts() {
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

    # The runner (a terminal or an IDE) can steal activation at any moment, so
    # re-activate and retry a dropped key press instead of failing on focus.
    press_nav() {
        local stream="$1" action="$2" keycode="$3" extra="${4:-}"
        local before after attempt
        for ((attempt = 1; attempt <= attempts; attempt++)); do
            before="$(nav_counts "$stream" "$action")"
            osascript -e 'tell application "System Events" to tell process "PocketDeck" to set frontmost to true' >/dev/null 2>&1
            sleep 0.3
            swift "$CGINPUT" key --keycode "$keycode" $extra >/dev/null
            sleep 1
            after="$(nav_counts "$stream" "$action")"
            [ "$after" -gt "$before" ] && return 0
        done
        return 1
    }

    # Phase A: an app window -> ⌘[ and Esc are `nav back` on stream 1.
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" \
        --open com.android.settings --quit-after 60
    sleep 9
    local app_win
    app_win="$(windows | awk '$4 == 900 {print $1; exit}')"
    if [ -z "$app_win" ]; then
        bad "C11 no app window: $(windows | tr '\n' ' ')"
    else
        swift "$CGINPUT" click --window "$app_win" --dx 200 >/dev/null; sleep 1
        press_nav 1 back 33 --cmd \
            && ok "C11 ⌘[ in an app window -> nav back" || bad "C11 no nav back after ⌘["
        press_nav 1 back 53 \
            && ok "C11 Esc in an app window -> nav back" || bad "C11 no second nav back after Esc"
    fi
    wait_app
    cp "$WORK/events.jsonl" "$WORK/events-nav-app.jsonl"
    pkill -f fakephone.py >/dev/null 2>&1
    sleep 1

    # Phase B: a phone-mode window -> ⇧⌘H home, ⌘↑ recents (both stream 1).
    : > "$WORK/events.jsonl"
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --open-phone --quit-after 60
    sleep 9
    local phone_win
    phone_win="$(windows | awk '$5 > $4 {print $1; exit}')"
    if [ -z "$phone_win" ]; then
        bad "C11 no phone window: $(windows | tr '\n' ' ')"
    else
        swift "$CGINPUT" click --window "$phone_win" >/dev/null; sleep 1
        press_nav 1 home 4 "--cmd --shift" \
            && ok "C11 ⇧⌘H in the phone window -> nav home" || bad "C11 no nav home"
        press_nav 1 recents 126 --cmd \
            && ok "C11 ⌘↑ in the phone window -> nav recents" || bad "C11 no nav recents"
    fi
    wait_app
    pkill -f fakephone.py >/dev/null 2>&1
}

# --- C12: Spotlight for phone apps ----------------------------------------

# check_spotlight — after an app list arrives the apps are indexed. mdfind is
# tried first; an unsigned dev bundle may not be able to write the Spotlight
# index, in which case the unit tests (item builder + throttle) and the app's
# own index log line are the evidence.
check_spotlight() {
    clean
    start_fake || return 1
    launch --connect "127.0.0.1:$PORT" --pair-code-file "$WORK/pd.code" --quit-after 18
    wait_app
    local hit
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
        if log show --last 4m --info \
            --predicate 'subsystem == "dev.pocketdeck.mac" AND process == "PocketDeck"' 2>/dev/null \
            | grep -q "spotlight: indexing"; then
            ok "C12 the app logged the index attempt ($(log show --last 4m --info --predicate 'subsystem == "dev.pocketdeck.mac" AND process == "PocketDeck"' 2>/dev/null | grep -o 'spotlight: indexing [0-9]* apps' | tail -1))"
        else
            bad "C12 no spotlight log line from the app (indexing never attempted)"
        fi
    fi
    pkill -f fakephone.py >/dev/null 2>&1
}

# --- C9: no leftovers -----------------------------------------------------

check_orphans() {
    sleep 1
    local n
    n="$(pgrep -f "PocketDeck.app/Contents/MacOS/PocketDeck" | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan PocketDeck processes" || bad "C9 $n orphan PocketDeck processes"
    n="$(pgrep -f fakephone.py | wc -l | tr -d ' ')"
    [ "$n" = "0" ] && ok "C9 no orphan fakephone processes" || bad "C9 $n orphan fakephone processes"
}

which_check="${1:-all}"
case "$which_check" in
    qr)       check_qr ;;
    pair)     check_pair ;;
    render)   check_render ;;
    resize)   check_resize ;;
    input)    check_input ;;
    pause)    check_pause ;;
    direct)   check_direct ;;
    nav)      check_nav ;;
    spotlight) check_spotlight ;;
    all)      check_qr; check_pair; check_render; check_resize; check_input; check_pause
              check_direct; check_nav; check_spotlight; check_orphans ;;
    *)        say "usage: check-e2e.sh [qr|pair|render|resize|input|pause|direct|nav|spotlight|all]"; exit 2 ;;
esac

say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" = "0" ]
