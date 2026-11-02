#!/usr/bin/env bash
# probe-join item 4: the single-path silence probe on the real phone server,
# one boot (PATH-24/E-11).
#
# Proves, against the emulator's real shell server (not fakephone):
#   * one path, one app window, and no probe dial while the path is healthy;
#   * the radio dies for 8 s (one pdpathfault proxy, `mode blackhole`); E-11's
#     2 s of silence dials one probe join, which the proxy accepts;
#   * the lift (`mode pass-new`) lets the probe's retry through while the old
#     socket stays dead, as a socket in TCP's retransmission backoff behaves;
#   * the probe welcomes into the SAME session (`paths: joined` on the phone,
#     one `welcome`), the Mac switches to it at once (`live --probe--> live`),
#     and the first frame over the new path arrives within `blip_recovery_ms`
#     (macOS-*-limits.json) of the lift;
#   * the new path stays up for 30 s after the switch: its proxy connection is
#     still open, frames keep arriving on it, and the phone logs no
#     `frame length too large`;
#   * no Reconnecting and no `path down` before the switch.
#
# Run it as: heavy.sh timeout 2700 bash tools/emulator/probe-join.sh
# Rehearse it as the same heavy.sh line with --check (no device, no boot).
#
# The one boot is killed only with `adb -s emulator-5554 emu kill`, in the
# script's own cleanup, so boot, checks and kill stay inside one heavy call.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "probe-join.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

WORK="${PD_PROBE_WORK:-/tmp/pd-probe-join-emu}"
PROFILE="probejoinemu$$"
SUPPORT="$HOME/Library/Application Support/PocketDeck-$PROFILE"
APP="$ROOT/macos/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck"
LIMITS="$ROOT/macos/scripts/nfr-limits.json"
LISTEN=47821
FAIL=0
PHASE=""

section() { PHASE="$1"; printf '\n== %s ==\n' "$1"; }
ok() { printf 'PASS [%s] %s\n' "$PHASE" "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$PHASE" "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[probe-join] %s\n' "$*"; }

wait_for() { # wait_for <seconds> <command...>
    local deadline=$(( $(date +%s) + $1 ))
    shift
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.25
    done
    return 1
}

wait_for_epoch() { # wait_for_epoch <epoch seconds>
    while :; do
        "$PYTHON" -c "import sys, time; sys.exit(0 if time.time() >= float('$1') else 1)" && return 0
        sleep 0.1
    done
}

blip_recovery_ms() {
    "$PYTHON" -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["blip_recovery_ms"]))' "$LIMITS"
}

# --- --check: everything a boot would die on, without touching a device -----
if [ "$MODE" = check ]; then
    CHECK_FAIL=0
    cfail() { echo "PROBE-JOIN CHECK FAIL: $*"; CHECK_FAIL=1; }
    [ "$SERIAL" = "emulator-5554" ] ||
        cfail "serial '$SERIAL' is not emulator-5554 (never any other serial)"
    bash "$HERE/preflight.sh" || CHECK_FAIL=1
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP (build it: macos/scripts/check-e2e.sh pathblip)"
    if [ -x "$APP" ]; then
        for line in '--debug-frame-log' '--debug-chrome-state' 'paths: attached' 'paths: probe'; do
            grep -aq -- "$line" "$APP" || cfail "$APP lacks '$line' (rebuild the e2e bundle)"
        done
        stale="$(find "$ROOT/macos/Sources" -type f -newer "$APP" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the Mac app is older than $stale"
    fi
    for f in "$ROOT/tools/pdpathfault/pdpathfault.py" "$HERE/poc.py" \
             "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"; do
        [ -f "$f" ] || cfail "missing $f"
    done
    stale="$(find "$ROOT/android/app/src/main" -type f -newer \
        "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" -print -quit 2>/dev/null)"
    [ -z "$stale" ] || cfail "the APK is older than $stale (rebuild :app:assembleDebug)"
    "$PYTHON" "$HERE/poc.py" --help >/dev/null 2>&1 || cfail "poc.py --help"
    "$PYTHON" "$ROOT/tools/pdpathfault/pdpathfault.py" --help >/dev/null 2>&1 ||
        cfail "pdpathfault.py --help"
    "$PYTHON" "$ROOT/tools/pdpathfault/test_close.py" >/dev/null 2>&1 ||
        cfail "pdpathfault close check"
    value="$(blip_recovery_ms 2>/dev/null || true)"
    [ "${value:-0}" -gt 0 ] || cfail "blip_recovery_ms is missing from $LIMITS"
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "PROBE-JOIN CHECK PASS: one boot, $SERIAL, APK $(apk_version_code "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"), blip_recovery_ms $value"
        exit 0
    fi
    echo "PROBE-JOIN CHECK FAIL"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/probe-join.out") 2>&1

APP_PID=""
LOG_STREAM=""
PROXY_PID=""
TAP_PID=""
CHROME_PID=""
CLOCK_PID=""
E2E_LOCK=/tmp/pocketdeck-e2e.lock
HOLDS_E2E=0
DOCK_DEFAULT_SET=0

acquire_e2e_lock() {
    local waited=0 holder
    until mkdir "$E2E_LOCK" 2>/dev/null; do
        holder="$(cat "$E2E_LOCK/pid" 2>/dev/null || true)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$E2E_LOCK"
            continue
        fi
        if [ "$waited" -ge 600 ]; then
            say "the e2e lock is still held by pid ${holder:-unknown} after 10 minutes"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo $$ > "$E2E_LOCK/pid"
    HOLDS_E2E=1
}

release_e2e_lock() {
    if [ "$HOLDS_E2E" = 1 ] && [ "$(cat "$E2E_LOCK/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$E2E_LOCK"
    fi
    HOLDS_E2E=0
}

disable_dock_auto() {
    defaults write "dev.pocketdeck.mac.$PROFILE" showAppsInDock -bool NO || return 1
    DOCK_DEFAULT_SET=1
    [ "$(defaults read "dev.pocketdeck.mac.$PROFILE" showAppsInDock 2>/dev/null)" = "0" ]
}

stop_app() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
    if [ -n "$LOG_STREAM" ]; then
        kill "$LOG_STREAM" 2>/dev/null || true
        wait "$LOG_STREAM" 2>/dev/null || true
        LOG_STREAM=""
    fi
}

stop_proxy() {
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null && wait "$PROXY_PID" 2>/dev/null
    PROXY_PID=""
}

mac_app() { # mac_app <out file> <app args...>
    local out="$1"
    shift
    exec "$APP" "$@" > "$out" 2>&1
}

poc() { "$PYTHON" "$HERE/poc.py" "$@"; }

stream_log() { # stream_log <pid> <file>
    /usr/bin/log stream --info --style syslog --predicate "processID == $1" \
        > "$2" 2>/dev/null &
    echo $!
}

refresh_log() { # refresh_log <pid> <file>
    /usr/bin/log show --last 10m --info --style syslog \
        --predicate "processID == $1 AND subsystem == \"dev.pocketdeck.mac\"" \
        2>/dev/null >> "$2"
}

bring_app_forward() {
    emu shell am start -n dev.pocketdeck/.app.MainActivity >/dev/null 2>&1 || true
    local start relaunched=0
    start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt 60 ]; do
        if emu shell dumpsys activity activities 2>/dev/null |
            grep -Eq 'ResumedActivity:.*dev\.pocketdeck/[^ ]*app\.MainActivity|topResumedActivity=.*dev\.pocketdeck/[^ ]*app\.MainActivity'; then
            sleep 3
            return 0
        fi
        if [ "$relaunched" -eq 0 ] && [ $(( $(date +%s) - start )) -ge 10 ]; then
            emu shell am start -n dev.pocketdeck/.app.MainActivity >/dev/null 2>&1 || true
            relaunched=1
        fi
        sleep 1
    done
    say "the app is not the resumed activity after 60 s"
    return 1
}

wait_slot_free() { # wait_slot_free <log> <cap seconds> <label>
    local log="$1" cap="$2" label="$3"
    local deadline=$(( $(date +%s) + cap ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$log"
        if grep -Eq 'session slot: [a-z]+ --[a-z ]+--> free' "$log"; then
            say "$label: the phone slot is free"
            return 0
        fi
        sleep 0.25
    done
    say "$label: the phone slot was not seen free in ${cap}s"
    return 1
}

pin_stored() {
    local pins="$SUPPORT/pins.json"
    [ -s "$pins" ] || return 1
    "$PYTHON" - "$pins" <<'PY'
import json, re, sys
try:
    records = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if any(re.fullmatch(r"[0-9a-fA-F]{64}", r.get("phoneFingerprintHex") or "") for r in records) else 1)
PY
}

pair_once() { # pair_once <attempt>
    local attempt="$1"
    local log="$WORK/mac-pair-$attempt.log"
    local prompt="$WORK/wait-prompt-$attempt.log"
    bring_app_forward || return 1
    poc --addr "$ADDR" --serial "$SERIAL" \
        wait-prompt --timeout 60 --stale none --evidence "$WORK/pair-$attempt" \
        > "$prompt" 2>&1 &
    TAP_PID=$!
    mac_app "$WORK/app-pair-$attempt.out" --profile "$PROFILE" --background --connect "$ADDR" \
        --open-phone --quit-after 70 &
    APP_PID=$!
    LOG_STREAM="$(stream_log "$APP_PID" "$log")"
    wait_for 60 pin_stored || refresh_log "$APP_PID" "$log"
    local paired=0
    pin_stored && paired=1
    sleep 1
    stop_app
    wait "$TAP_PID" 2>/dev/null || true
    TAP_PID=""
    [ "$paired" = 1 ]
}

conn_count() { # conn_count <proxy events file>
    "$PYTHON" - "$1" <<'PY'
import json, sys
count = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "conn":
        count += 1
print(count)
PY
}

first_other_frame_ms() { # first_other_frame_ms <frames tsv> <since> <founder>
    "$PYTHON" - "$1" "$2" "$3" <<'PY'
import sys
lift, founder = float(sys.argv[2]), sys.argv[3]
first = None
for line in open(sys.argv[1]):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    try:
        ts = float(parts[0])
    except ValueError:
        continue
    if ts >= lift and parts[2] != founder:
        first = ts
        break
print("none" if first is None else "%.0f" % ((first - lift) * 1000.0))
PY
}

has_other_frame() { # has_other_frame <frames tsv> <since> <founder>
    [ "$(first_other_frame_ms "$@")" != "none" ]
}

conn_id_since() { # conn_id_since <events file> <epoch>: the first conn at/after it
    "$PYTHON" - "$1" "$2" <<'PY'
import json, sys
since = float(sys.argv[2])
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "conn" and float(event.get("ts", 0)) >= since:
        print(event["id"])
        break
PY
}

conn_alive() { # conn_alive <events file> <id>: no eof/close for it yet
    "$PYTHON" - "$1" "$2" <<'PY'
import json, sys
conn = int(sys.argv[2])
closed = False
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") in ("eof", "close") and event.get("id") == conn:
        closed = True
print("closed" if closed else "open")
PY
}

CLEANED=0
cleanup() {
    local trap_rc=$?
    if [ "$CLEANED" = 1 ]; then return 0; fi
    CLEANED=1
    # Evidence first, while the phone is still up.
    emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-final.log" || true
    [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true
    [ -n "$CLOCK_PID" ] && kill "$CLOCK_PID" 2>/dev/null || true
    stop_app
    [ -n "$TAP_PID" ] && kill "$TAP_PID" 2>/dev/null || true
    stop_proxy
    if [ "$DOCK_DEFAULT_SET" = 1 ]; then
        defaults delete "dev.pocketdeck.mac.$PROFILE" showAppsInDock >/dev/null 2>&1 || true
        DOCK_DEFAULT_SET=0
    fi
    release_e2e_lock
    "$ADB" -s "$SERIAL" forward --remove "tcp:$LISTEN" >/dev/null 2>&1 || true
    # The only allowed kill: this emulator's own console.
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    exit "$trap_rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# --- boot ------------------------------------------------------------------
section boot
bash "$HERE/start.sh" --no-build > "$WORK/start.log" 2>&1
if [ $? -ne 0 ]; then
    tail -40 "$WORK/start.log"
    bad "start.sh --no-build failed"
    exit 1
fi
ADDR="$(sed -n 's/^POCKETDECK_ADDR=//p' "$WORK/start.log" | tail -1)"
DEVPORT="$(sed -n 's/^POCKETDECK_DEVICE_PORT=//p' "$WORK/start.log" | tail -1)"
[ -n "$ADDR" ] && [ -n "$DEVPORT" ] || { tail -20 "$WORK/start.log"; bad "no address/port"; exit 1; }
ok "booted, real server at $ADDR (device $DEVPORT)"
emu logcat -c >/dev/null 2>&1 || true

# A fresh Mac profile: no pin from an earlier run can make this a reconnect.
rm -rf "$SUPPORT"
disable_dock_auto || bad "could not turn the automatic Dock identity off for $PROFILE"
acquire_e2e_lock || bad "no e2e lock: the Mac window is exposed to another agent's input"

# --- pair ------------------------------------------------------------------
section pair
PAIRED=0
for attempt in 1 2; do
    if pair_once "$attempt"; then PAIRED=1; break; fi
    say "pair attempt $attempt failed"
    stop_app
    wait_slot_free "$WORK/phone-pair-$attempt-end.log" 40 pair || true
done
if [ "$PAIRED" = 1 ]; then
    ok "the Mac app paired and stored the phone pin"
else
    bad "the Mac app did not pair/store a pin"
    exit 1
fi
wait_slot_free "$WORK/phone-pair-end.log" 40 pair || true
sleep 3

# --- one path, one window, a radio that dies -------------------------------
section blip
emu logcat -c >/dev/null 2>&1 || true
ctl="$WORK/fault.ctl"
: > "$ctl"
printf 'mode pass\n' > "$ctl"
"$PYTHON" "$ROOT/tools/pdpathfault/pdpathfault.py" --listen "$LISTEN" \
    --connect "127.0.0.1:${ADDR##*:}" --mode pass --rate-mbit 16 \
    --ctl-file "$ctl" --events "$WORK/fault.events" \
    > "$WORK/fault.log" 2>&1 &
PROXY_PID=$!
wait_for 10 grep -q '"ev":"start"' "$WORK/fault.events" || bad "the fault proxy did not listen"
rm -f "$WORK/frames.tsv" "$WORK/chrome.txt" "$WORK/chrome-ticks.txt" "$WORK/blip-stop"
mac_app "$WORK/app-blip.out" --profile "$PROFILE" --background \
    --connect "127.0.0.1:$LISTEN" --open com.android.settings \
    --debug-frame-log "$WORK/frames.tsv" --debug-chrome-state "$WORK/chrome.txt" \
    --quit-after 80 &
APP_PID=$!
LOG_STREAM="$(stream_log "$APP_PID" "$WORK/mac-blip.log")"
(
    while [ ! -e "$WORK/blip-stop" ]; do
        [ -s "$WORK/chrome.txt" ] && cat "$WORK/chrome.txt" 2>/dev/null
        sleep 0.1
    done
) > "$WORK/chrome-ticks.txt" &
CHROME_PID=$!
wait_for 20 grep -q 'hello --welcome--> welcomed' "$WORK/mac-blip.log" 2>/dev/null ||
    bad "the session never founded"
wait_for 20 test -s "$WORK/frames.tsv" ||
    bad "no app-window video"
if [ -s "$WORK/frames.tsv" ]; then
    ok "one-path session is live with a moving window"
else
    exit 1
fi
sleep 4
founder="$(awk '$1 >= 0 { p = $3 } END { print p }' "$WORK/frames.tsv")"
[ -n "$founder" ] || bad "the frame log names no path"
# The phone's first blip attempt can close at its hello (the pair session's
# tail supersedes it); count probes from the founded session, not from launch.
conns_founded="$(conn_count "$WORK/fault.events")"
[ "${conns_founded:-0}" -ge 1 ] || bad "no connection reached the proxy"
conns="$(conn_count "$WORK/fault.events")"
[ "${conns:-0}" -eq "${conns_founded:-0}" ] \
    && ok "no probe was dialed while the path was healthy ($conns connection(s), all from startup)" \
    || bad "$((conns - conns_founded)) probe connection(s) before the fault"
t_fault="$("$PYTHON" -c 'import time; print("%.6f" % time.time())')"
printf 'mode blackhole\n' > "$ctl"
# E-11's 2 s of silence must dial one join; the proxy accepts its TCP
# connection even though the TLS hello is dropped.
wait_for_epoch "$("$PYTHON" -c "print(float('$t_fault') + 3.5)")"
conns="$(conn_count "$WORK/fault.events")"
[ "${conns:-0}" -ge $((conns_founded + 1)) ] \
    && ok "the Mac dialed one probe join during the silence" \
    || bad "no probe join was dialed during the silence ($conns connection(s))"
wait_for_epoch "$("$PYTHON" -c "print(float('$t_fault') + 8.0)")"
t_lift="$("$PYTHON" -c 'import time; print("%.6f" % time.time())')"
printf 'mode pass-new\n' > "$ctl"
say "fault at $t_fault, lift at $t_lift"
wait_for 10 grep -q 'paths: attached .* (paths 2)' "$WORK/mac-blip.log" 2>/dev/null ||
    bad "the probe never attached a second path"
wait_for 10 grep -q -- 'live --probe--> live' "$WORK/mac-blip.log" 2>/dev/null ||
    bad "the Mac did not switch to the probe"
t_switch="$("$PYTHON" -c 'import time; print("%.6f" % time.time())')"
new_conn="$(conn_id_since "$WORK/fault.events" "$t_lift")"
[ -n "$new_conn" ] || bad "no proxy connection was accepted after the lift"
# One founder and one join welcome on the Mac: a second founder would mean a
# new session instead of the same one.
founders="$(grep -c 'attempt: hello --welcome--> welcomed' "$WORK/mac-blip.log" 2>/dev/null || true)"
joined="$(grep -c 'attempt: hello-join --welcome--> welcomed' "$WORK/mac-blip.log" 2>/dev/null || true)"
[ "${founders:-0}" -eq 1 ] && [ "${joined:-0}" -eq 1 ] \
    && ok "same session: one founder welcome and one join welcome (founders=${founders} joins=${joined})" \
    || bad "wrong welcome accounting (founders=${founders:-0} joins=${joined:-0})"
blip_ms="$(blip_recovery_ms)"
wait_for 5 has_other_frame "$WORK/frames.tsv" "$t_lift" "$founder" || true
delta="$(first_other_frame_ms "$WORK/frames.tsv" "$t_lift" "$founder")"
if [ "$delta" = "none" ]; then
    bad "no frame arrived over the new path after the lift"
elif "$PYTHON" -c "import sys; sys.exit(0 if float('$delta') <= $blip_ms else 1)"; then
    ok "first frame over the new path ${delta} ms after the lift (blip_recovery_ms $blip_ms)"
else
    bad "first frame over the new path took ${delta} ms (blip_recovery_ms $blip_ms)"
fi
# The switch happened while the old path was still attached; after it a
# demote or the path's own socket error is allowed (PATH-21/E-11).
"$PYTHON" - "$WORK/mac-blip.log" <<'PY'
import sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
switch = None
for index, line in enumerate(lines):
    if "live --probe--> live" in line:
        switch = index
        break
if switch is None:
    sys.exit(1)
for line in lines[:switch]:
    if "paths: path down" in line:
        sys.exit(1)
sys.exit(0)
PY
[ $? -eq 0 ] \
    && ok "the Mac switched to the probe while the old path was still live" \
    || bad "no probe switch, or the old path was down before it: $(grep 'paths:' "$WORK/mac-blip.log" | tail -3 | tr '\n' ' ')"
# E-11 after the switch: the new path is the sending one and must stay up for
# 30 s. The old socket may die meanwhile; only the new path's connection, its
# frames and the phone's reader-fault signature are checked.
say "switch at $t_switch; holding the new path for 30 s"
wait_for_epoch "$("$PYTHON" -c "print(float('$t_switch') + 30.0)")"
emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-blip.log"
joins="$(grep -c 'paths: joined [0-9a-f]* (paths 2)' "$WORK/phone-blip.log" 2>/dev/null || true)"
[ "${joins:-0}" -eq 1 ] \
    && ok "the phone handled exactly one join" \
    || bad "the phone logged ${joins:-0} joins, expected 1"
since="$("$PYTHON" -c "print(float('$t_switch') + 28.0)")"
recent="$(awk -v since="$since" -v founder="$founder" \
    '$1 >= since && $3 != founder { n++ } END { print n + 0 }' "$WORK/frames.tsv")"
[ "${recent:-0}" -gt 0 ] \
    && ok "frames still land on the new path 30 s after the switch ($recent in the last 2 s)" \
    || bad "no frame landed on the new path in the last 2 s of the 30 s hold"
alive="$(conn_alive "$WORK/fault.events" "$new_conn")"
[ "$alive" = "open" ] \
    && ok "the new path's connection stayed open for 30 s (conn $new_conn)" \
    || bad "the new path's connection closed during the 30 s hold (conn $new_conn)"
grep -q 'frame length too large' "$WORK/phone-blip.log" \
    && bad "the phone logged the reader-race signature" \
    || ok "the phone logged no frame length too large"
grep -q "paths: path down $new_conn" "$WORK/mac-blip.log" \
    && bad "the Mac marked the new path down" \
    || ok "the Mac kept the new path up"
kill -0 "$APP_PID" 2>/dev/null || bad "the Mac app exited during the 30 s hold"
grep -q 'bar_offline=1' "$WORK/chrome-ticks.txt" \
    && bad "the window said Reconnecting during the blip" \
    || ok "the window never said Reconnecting"
grep -qF "session failed" "$WORK/app-blip.out" \
    && bad "the session ended instead of moving to the probe" \
    || ok "the session stayed live"
: > "$WORK/blip-stop"
[ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null || true

printf '\n== result ==\n'
if [ "$FAIL" = 0 ]; then
    echo "PROBE-JOIN PASS: one boot; probe ${t_fault} fault / ${t_lift} lift; first frame ${delta} ms (limit ${blip_ms}); conn ${new_conn} up 30 s"
else
    echo "PROBE-JOIN FAIL: $FAIL proof(s) failed"
fi
exit $(( FAIL == 0 ? 0 : 1 ))
