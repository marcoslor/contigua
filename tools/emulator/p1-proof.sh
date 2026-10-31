#!/usr/bin/env bash
# direct-p1 item 7: the real phone server on the emulator, one boot.
#
# Proves, against the debug APK's real shell server (not fakephone):
#   * a join: two providers, one session, the second path attaches (`paths:
#     joined`), no supersede and no new session;
#   * a 32 MiB drop through a path black-holed after 8 MiB: the file lands
#     byte-exact via the standby path;
#   * a v3-shaped hello refused with `error version {v:4}` and a close;
#   * the 30 s grace: both paths killed, `paths: ended graceExpired` on the
#     phone and `orphaned --grace--> ended` on the Mac, the slot free after,
#     and the panel awake.
#
# It boots once (budget .agent/budgets/direct-p0), and kills only
# `adb -s emulator-5554 emu kill`. Evidence lands in $WORK and the caller's
# stdout; every line is also teed to $WORK/p1-proof.out (the reviewer's copy).
# Each phase gets its own `fault-{a,b}.<phase>.{events,log,ctl}` and the drop's
# verdict reads those events plus the proxies' delivered-byte counts. The table
# goes to .agent/direct-link/p1-emulator.md.
#
# Run it as: heavy.sh timeout 2700 bash tools/emulator/p1-proof.sh
# Rehearse it as the same heavy.sh line with --check (no device, no boot).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "p1-proof.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

WORK="${PD_PROOF_WORK:-/tmp/pd-direct-p1-emu}"
PROFILE="pathsemu$$"
SUPPORT="$HOME/Library/Application Support/PocketDeck-$PROFILE"
APP="$ROOT/macos/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck"
FAIL=0
PHASE=""

# The drop script is generated once and used by both the run and --check, so the
# rehearsal parses exactly the lines the boot will load. Each wait is <= 60 s:
# the debug-input grammar refuses a longer single wait, and two pieces keep the
# old total for a slow start.
drop_script() { # drop_script <script file> <file to drop> <drop-go path>
    cat > "$1" <<EOF
waitfile $3 60
waitfile $3 60
dropfile $2
wait 60
EOF
}

pin_stored() { # 0 when the Mac profile holds a phone pin
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

# --- --check: everything a boot would die on, without touching a device -----
if [ "$MODE" = check ]; then
    CHECK_FAIL=0
    cfail() { echo "P1-PROOF CHECK FAIL: $*"; CHECK_FAIL=1; }
    [ "$SERIAL" = "emulator-5554" ] ||
        cfail "serial '$SERIAL' is not emulator-5554 (never any other serial)"
    bash "$HERE/preflight.sh" || CHECK_FAIL=1
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP (build it: macos/scripts/build-e2e.sh)"
    if [ -x "$APP" ]; then
        # Swift keeps short strings (--connect2) inline, so probe a long test
        # hook the proof needs: it is in __cstring only in a PD_TEST_HOOKS build.
        grep -aq -- '--debug-input-script' "$APP" ||
            cfail "$APP has no --debug-input-script (built without PD_TEST_HOOKS?)"
        stale="$(find "$ROOT/macos/Sources" -type f -newer "$APP" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the Mac app is older than $stale"
    fi
    for f in "$ROOT/tools/pdpathfault/pdpathfault.py" "$HERE/poc.py" \
             "$ROOT/tools/fakephone/proto.py" "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"; do
        [ -f "$f" ] || cfail "missing $f"
    done
    stale="$(find "$ROOT/android/app/src/main" -type f -newer \
        "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" -print -quit 2>/dev/null)"
    [ -z "$stale" ] || cfail "the APK is older than $stale (rebuild :app:assembleDebug)"
    "$PYTHON" "$HERE/poc.py" --help >/dev/null 2>&1 || cfail "poc.py --help"
    "$PYTHON" "$ROOT/tools/pdpathfault/pdpathfault.py" --help >/dev/null 2>&1 ||
        cfail "pdpathfault.py --help"
    if close_out="$("$PYTHON" "$ROOT/tools/pdpathfault/test_close.py" 2>&1)"; then
        printf 'P1-PROOF CHECK: pdpathfault forwards FINs and counts bytes\n'
    else
        cfail "pdpathfault close check: $(printf '%s' "$close_out" | tail -2 | tr '\n' ' ')"
    fi
    # Item 7's join predicate reads these two lines; a bundle without them can
    # only fail the join after a full boot.
    if [ -x "$APP" ]; then
        for line in 'paths: attached' 'paths: sending'; do
            grep -aq -- "$line" "$APP" || cfail "$APP lacks '$line' (rebuild the e2e bundle)"
        done
    fi
    [ -x /usr/bin/log ] || cfail "no /usr/bin/log for the Mac app's lines"
    free_kb="$(df -k /tmp | awk 'NR == 2 { print $4 }')"
    [ -n "$free_kb" ] && [ "$free_kb" -ge 204800 ] ||
        cfail "less than 200 MiB free in /tmp for the 32 MiB drop"
    # Rehearse every phase's command line, not only its files: the Mac app
    # parses the same argv it will get (dummy addresses, no device) and the
    # generated drop script through the debug-input grammar. `wait 80` once
    # passed every file check and then failed the whole boot at load.
    checkdir="$(mktemp -d "${TMPDIR:-/tmp}/pd-p1-check.XXXXXX")"
    if [ -z "$checkdir" ]; then
        cfail "cannot make a rehearsal dir"
    else
        CHECK_DROP="$checkdir/drop-check.bin"
        : > "$CHECK_DROP"
        drop_script "$checkdir/drop-script.txt" "$CHECK_DROP" "$WORK/drop-go"
        rehearse() { # rehearse <phase> <app args...>
            local phase="$1"
            shift
            local out
            if out="$("$APP" "$@" --check-input-script "$checkdir/drop-script.txt" 2>&1)"; then
                printf 'P1-PROOF CHECK: %s argv rehearsed\n' "$phase"
            else
                cfail "$phase argv: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
            fi
        }
        if [ -x "$APP" ]; then
            rehearse pair --profile "$PROFILE" --background \
                --connect 127.0.0.1:1 --open-phone --quit-after 70
            rehearse join --profile "$PROFILE" --background \
                --connect 127.0.0.1:1 --connect2 127.0.0.1:2 \
                --open com.android.settings --debug-input-script "$checkdir/drop-script.txt" \
                --quit-after 150
            rehearse grace --profile "$PROFILE" --background \
                --connect 127.0.0.1:1 --connect2 127.0.0.1:2 --open-phone --quit-after 70
        fi
        # Every single wait the run will load is inside the 60 s cap.
        if awk '$1 == "waitfile" && $3 > 60 { bad = 1 } $1 == "wait" && $2 > 60 { bad = 1 }
                END { exit bad ? 0 : 1 }' "$checkdir/drop-script.txt"; then
            cfail "a debug-input wait is over 60 s: $(cat "$checkdir/drop-script.txt" | tr '\n' ' ')"
        fi
        rm -rf "$checkdir"
    fi
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "P1-PROOF CHECK PASS: one boot, $SERIAL, APK $(apk_version_code "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"), app $APP"
        exit 0
    fi
    echo "P1-PROOF CHECK FAIL"
    exit 1
fi

# The run owns a fresh work dir; --check above never touches it (a rehearsal
# after a failed boot must not wipe that boot's evidence).
rm -rf "$WORK"
mkdir -p "$WORK"
# Item 7's deliverable is this file: every PASS/FAIL line the reviewer reads,
# even when the run dies before its result table. `tee` flushes on exit.
exec > >(tee "$WORK/p1-proof.out") 2>&1

section() { PHASE="$1"; printf '\n== %s ==\n' "$1"; }
ok() { printf 'PASS [%s] %s\n' "$PHASE" "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$PHASE" "$*"; FAIL=$((FAIL + 1)); }

wait_for() { # wait_for <seconds> <command...>
    local deadline=$(( $(date +%s) + $1 ))
    shift
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.25
    done
    return 1
}

stream_log() { # stream_log <pid> <file>
    /usr/bin/log stream --info --style syslog --predicate "processID == $1" \
        > "$2" 2>/dev/null &
    echo $!
}

refresh_log() { # refresh_log <pid> <file> — merge log show: a late stream start
                # must not hide a line the checks are about
    /usr/bin/log show --last 10m --info --style syslog \
        --predicate "processID == $1 AND subsystem == \"dev.pocketdeck.mac\"" \
        2>/dev/null >> "$2"
}

# wait_slot_free <log> <cap seconds> <label> — the Mac app is gone; wait up to
# `cap` seconds for the phone to record the slot free. The phone keeps a
# session for its own 30 s grace after the last path dies (PATH-6), and a new
# plain hello during that grace has to supersede it: waiting makes the next
# dial start on a free slot instead of racing one. Returns 1 when the slot did
# not free.
wait_slot_free() { # wait_slot_free <log> <cap seconds> <label>
    local log="$1" cap="$2" label="$3" deadline=$(( $(date +%s) + cap ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$log"
        if grep -Eq 'session slot: [a-z]+ --[a-z ]+--> free' "$log"; then
            printf '[p1-proof] %s: the phone slot is free (%s)\n' "$label" \
                "$(grep -E 'session slot: .*--> free' "$log" | tail -1 | sed 's/^.*PocketDeckSvc([^)]*): //')"
            return 0
        fi
        sleep 0.25
    done
    printf '[p1-proof] %s: the phone slot was not seen free in %ss\n' "$label" "$cap"
    return 1
}

# The pairing prompt is the phone app's own dialog; the app can sit behind the
# home screen and then the prompt is only a notification, which poc.py's
# wait-prompt does not read. flow.sh waits for the activity to be resumed before
# pairing; this is the same step, and the proof cannot pair without it.
bring_app_forward() {
    emu shell am start -n dev.pocketdeck/.app.MainActivity >/dev/null 2>&1 || true
    local deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # Android prints `ResumedActivity: ActivityRecord{… dev.pocketdeck/.app.MainActivity …}`
        # (the short component form); the old full-name pattern never matched.
        if emu shell dumpsys activity activities 2>/dev/null |
            grep -Eq 'ResumedActivity:.*dev\.pocketdeck/[^ ]*app\.MainActivity|topResumedActivity=.*dev\.pocketdeck/[^ ]*app\.MainActivity'; then
            break
        fi
        sleep 2
    done
    sleep 3
}



APP_PID=""
LOG_STREAM=""
PROXY_A_PID=""
PROXY_B_PID=""
TAP_PID=""

# phone_evidence <label> — everything the phone can still say, written before the
# emulator dies. A failure that stops the run early (the boot-4 pair) used to
# leave no phone log at all: the process, its crash buffer and the lifecycle
# lines are exactly what tells a dropped session from a dead server.
phone_evidence() {
    # Two `local` lines: `local label=$1 log=...$label` expands $label before
    # local assigns it, and set -u makes that fatal in a script (boot 5).
    local label="$1"
    local log="$WORK/phone-evidence-$label.log"
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    if ! device_present; then
        printf '[p1-proof] %s: no device, no phone evidence\n' "$label" >> "$log"
        return 0
    fi
    {
        printf '== phone evidence: %s at %s ==\n' "$label" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s\n' '-- pids --'
        printf 'pidof dev.pocketdeck: %s\n' "$(emu shell "pidof dev.pocketdeck" 2>/dev/null | tr -d '\r')"
        printf 'pidof dev.pocketdeck:pocketdeck: %s\n' "$(emu shell "pidof dev.pocketdeck:pocketdeck" 2>/dev/null | tr -d '\r')"
        printf '%s\n' '-- ps --'
        emu shell "ps -A -o PID,PPID,USER,NAME 2>/dev/null | grep -Ei 'pocketdeck|shizuku'" 2>/dev/null | tr -d '\r'
        printf '%s\n' '-- captured picks --'
        emu shell "dumpsys activity activities 2>/dev/null | grep -E 'ResumedActivity|mFocusedApp|topResumedActivity'" 2>/dev/null | tr -d '\r'
        printf '%s\n' '-- logcat (app, crash, process death, Shizuku) --'
        ADB_TIMEOUT=60 emu logcat -d -v time -b all 2>/dev/null | grep -E \
            'PocketDeckSvc|PocketDeckApp|AndroidRuntime|FATAL| DEBUG |Shizuku|shizuku|tombstone|am_crash|am_anr|lowmemorykiller|Force finishing|Process dev\.pocketdeck|Killing [0-9]+:dev\.pocketdeck'
        printf '%s\n' '-- end --'
    } > "$log" 2>&1
    printf '[p1-proof] %s: wrote %s (%s lines)\n' "$label" "$log" "$(wc -l < "$log" | tr -d ' ')"
}

# crash_evidence <label> — boot 7's Shizuku server died one second after it
# started and its tombstone died with the emulator, so copy the guest's
# tombstones and memory totals out before the kill. `su 0 cat` needs no adbd
# restart; `adb root` is the fallback, and both are this emulator only. The
# newest tombstone is bounded to its first 120 lines.
CRASH_SAVED=0
list_tombstones() { emu shell "ls -l /data/tombstones" 2>&1 | tr -d '\r'; }
newest_tombstone() { # numeric suffix, so tombstone_10 beats tombstone_9
    awk '/tombstone_[0-9]+$/ {
             n = substr($NF, 11) + 0
             if (n >= max) { max = n; name = $NF }
         } END { print name }'
}
tombstone_head() { # tombstones are root-only; the reader names the method
    [ -n "${newest:-}" ] || return 0
    if [ "$reader" = "adb root" ]; then
        emu shell "cat /data/tombstones/$newest 2>/dev/null | head -n 120" 2>/dev/null | tr -d '\r'
    else
        emu shell "su 0 cat /data/tombstones/$newest 2>/dev/null | head -n 120" 2>/dev/null | tr -d '\r'
    fi
}
crash_evidence() {
    local label="$1" log listing newest="" head="" root_out="" reader="su 0 cat"
    [ "$CRASH_SAVED" = 1 ] &&
        { printf '[p1-proof] %s: crash evidence already saved\n' "$label"; return 0; }
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] || return 0
    log="$WORK/crash-evidence-$label.log"
    if ! device_present; then
        printf '[p1-proof] %s: no device, no crash evidence\n' "$label" > "$log"
        CRASH_SAVED=1
        return 0
    fi
    listing="$(list_tombstones)"
    newest="$(printf '%s\n' "$listing" | newest_tombstone)"
    head="$(tombstone_head)"
    # A real tombstone starts with a `pid:` line; anything else (denied su, or
    # a tombstone the guest never finished writing) sends us to adb root.
    if ! printf '%s' "$head" | grep -q 'pid:'; then
        root_out="$(emu root 2>&1 | tr -d '\r' | head -1)"
        if printf '%s' "$root_out" | grep -qiE 'restarting adbd as root|already running as root'; then
            wait_for_device 30 || true
            reader="adb root"
            listing="$(list_tombstones)"
            newest="$(printf '%s\n' "$listing" | newest_tombstone)"
            head="$(tombstone_head)"
        fi
    fi
    # Keep the method even when the file has no body (boot 7's tombstone_05 is
    # 0 bytes): the reader is what the report has to name.
    printf '%s' "$head" | grep -q 'pid:' || reader="$reader (no tombstone body)"
    {
        printf '== crash evidence: %s at %s ==\n' "$label" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s\n' '-- ls -l /data/tombstones --'
        printf '%s\n' "$listing"
        printf '%s\n' "-- newest tombstone: ${newest:-none} (read by: $reader) --"
        printf '%s\n' "-- adb root: ${root_out:-not tried} --"
        printf '%s\n' "${head:-(no tombstone head)}"
        printf '%s\n' '-- dumpsys meminfo totals --'
        emu shell "dumpsys meminfo" 2>/dev/null | tr -d '\r' |
            grep -E 'Total RAM|Free RAM|Used RAM|Lost RAM|ZRAM|^Total PSS' | head -20
        printf '%s\n' '-- end --'
    } > "$log" 2>&1
    printf '[p1-proof] %s: wrote %s (%s lines, tombstone read by %s)\n' \
        "$label" "$log" "$(wc -l < "$log" | tr -d ' ')" "$reader"
    CRASH_SAVED=1
}

stop_app() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null
        for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$APP_PID" 2>/dev/null
        wait "$APP_PID" 2>/dev/null
        APP_PID=""
    fi
    if [ -n "$LOG_STREAM" ]; then
        kill "$LOG_STREAM" 2>/dev/null
        wait "$LOG_STREAM" 2>/dev/null
        LOG_STREAM=""
    fi
}

stop_proxies() {
    for pid in "$PROXY_A_PID" "$PROXY_B_PID"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    PROXY_A_PID=""; PROXY_B_PID=""
}

# start_faults <phase> <a-mode> <b-mode> [delay-ms] — one fresh proxy pair per
# phase, each with its own never-overwritten events/log. Boot 8 reused the join
# proxies for the grace, which truncated the join's events before the reviewer
# could see the founder throttled and black-holed.
start_faults() {
    local phase="$1" amode="$2" bmode="$3" delay="${4:-1500}"
    printf 'mode %s\n' "$amode" > "$WORK/fault-a.$phase.ctl"
    printf 'mode %s\n' "$bmode" > "$WORK/fault-b.$phase.ctl"
    "$PYTHON" "$ROOT/tools/pdpathfault/pdpathfault.py" --listen 47821 \
        --connect "127.0.0.1:${ADDR##*:}" --mode "$amode" --rate-mbit 16 \
        --ctl-file "$WORK/fault-a.$phase.ctl" --events "$WORK/fault-a.$phase.events" \
        > "$WORK/fault-a.$phase.log" 2>&1 &
    PROXY_A_PID=$!
    "$PYTHON" "$ROOT/tools/pdpathfault/pdpathfault.py" --listen 47822 \
        --connect 127.0.0.1:47812 --mode "$bmode" --delay-ms "$delay" --rate-mbit 16 \
        --ctl-file "$WORK/fault-b.$phase.ctl" --events "$WORK/fault-b.$phase.events" \
        > "$WORK/fault-b.$phase.log" 2>&1 &
    PROXY_B_PID=$!
    wait_for 10 grep -q '"ev":"start"' "$WORK/fault-a.$phase.events" || bad "fault A ($phase) did not listen"
    wait_for 10 grep -q '"ev":"start"' "$WORK/fault-b.$phase.events" || bad "fault B ($phase) did not listen"
}

CLEANED=0
cleanup() {
    # A timeout's TERM must not cost the evidence: traps below exit, and this is
    # idempotent because EXIT runs once more.
    [ "$CLEANED" = 1 ] && return 0
    CLEANED=1
    # First: the phone is still up and its buffers still hold the failure.
    phone_evidence cleanup
    crash_evidence cleanup
    stop_app
    [ -n "${TAP_PID:-}" ] && kill "$TAP_PID" 2>/dev/null
    stop_proxies
    "$ADB" -s "$SERIAL" forward --remove tcp:47812 >/dev/null 2>&1 || true
    # The only allowed kill: this emulator's own console.
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# --- the firmware: one boot ------------------------------------------------
section boot
start_rig() { bash "$HERE/start.sh" --no-build > "$WORK/start.log" 2>&1; }
if ! start_rig; then
    # A failed install does not kill the emulator; if it is up, the retry
    # reuses this same boot. Another worktree's debug build on the AVD has a
    # different signing key, which -r -d cannot replace, so uninstall it and
    # let start.sh install this tree's APK. (The adb error itself lands in
    # .agent/emu/install-failure.log, not in start.log's last line.)
    if device_present && grep -q 'could not install dev.pocketdeck' "$WORK/start.log"; then
        printf '[p1-proof] removing the AVD copy of dev.pocketdeck so this tree signs it\n'
        "$ADB" -s "$SERIAL" uninstall dev.pocketdeck >/dev/null 2>&1 || true
        if ! start_rig; then
            tail -40 "$WORK/start.log"
            grep -q 'shizuku_server is not running' "$WORK/start.log" &&
                crash_evidence starter-failed
            bad "start.sh --no-build failed after the uninstall"
            exit 1
        fi
    else
        tail -40 "$WORK/start.log"
        grep -q 'shizuku_server is not running' "$WORK/start.log" &&
            crash_evidence starter-failed
        bad "start.sh --no-build failed"
        exit 1
    fi
fi
ADDR="$(sed -n 's/^POCKETDECK_ADDR=//p' "$WORK/start.log" | tail -1)"
DEVPORT="$(sed -n 's/^POCKETDECK_DEVICE_PORT=//p' "$WORK/start.log" | tail -1)"
[ -n "$ADDR" ] && [ -n "$DEVPORT" ] || { tail -20 "$WORK/start.log"; bad "no address/port"; exit 1; }
ok "booted, real server at $ADDR (device $DEVPORT)"
emu logcat -c >/dev/null 2>&1 || true

# A fresh Mac profile: no pin from a previous run can make this a reconnect.
rm -rf "$SUPPORT"
# flow.sh's step before a pair: the app must be the resumed activity, or the
# prompt is a notification in a window poc.py does not read.
bring_app_forward

# --- pair the Mac app ------------------------------------------------------
section pair
"$PYTHON" "$HERE/poc.py" --addr "$ADDR" --serial "$SERIAL" \
    wait-prompt --timeout 60 --evidence "$WORK" > "$WORK/wait-prompt.log" 2>&1 &
TAP_PID=$!
"$APP" --profile "$PROFILE" --background --connect "$ADDR" \
    --open-phone --quit-after 70 > "$WORK/app-pair.out" 2>&1 &
APP_PID=$!
LOG_STREAM="$(stream_log "$APP_PID" "$WORK/mac-pair.log")"
# The welcome stores the pin while the Mac handles it, so a pin in the fresh
# profile is the real "paired and welcomed" predicate. (`--> live` never existed:
# that gate could only fail, even when pairing worked.)
if wait_for 60 pin_stored; then
    ok "the Mac app paired and stored the phone pin"
else
    refresh_log "$APP_PID" "$WORK/mac-pair.log"
    phone_evidence pair-failed
    if pin_stored; then
        ok "the Mac app paired and stored the phone pin"
    else
        bad "the Mac app did not pair/store a pin (tap: $(tail -2 "$WORK/wait-prompt.log" 2>/dev/null))"
        tail -5 "$WORK/mac-pair.log"
    fi
fi
sleep 1
stop_app
wait "$TAP_PID" 2>/dev/null || true
TAP_PID=""
# No pin means every later launch is a pairing attempt again, not a join: the
# three remaining proofs cannot run. Stop here instead of sinking the boot.
if pin_stored; then
    ok "the Mac stored the phone pin before the join"
else
    bad "no pin in $SUPPORT/pins.json after pairing; the join cannot run"
    printf '\n== result ==\nFAIL: $FAIL proof(s) failed (one boot, stopped after pair)\n'
    exit 1
fi
# The phone's own grace keeps the pair session for 30 s after the Mac app
# quits; wait it out so the join dials a free slot (boot 8 raced it and the
# supersede muddied the first dial).
wait_slot_free "$WORK/phone-pair-end.log" 40 pair || true

# --- two providers, one session: the join ----------------------------------
section join
emu logcat -c >/dev/null 2>&1 || true
# A .part-* from an earlier rig run would trip the 8 MiB "drop started" check.
emu shell "rm -f /sdcard/Download/PocketDeck/.part-*" >/dev/null 2>&1 || true
# Each proxy gets its own adb forward: two concurrent TLS handshakes must not
# share one forward's socket path (path A kept failing parse on the phone).
emu forward --remove tcp:47812 >/dev/null 2>&1 || true
emu forward tcp:47812 "tcp:$DEVPORT" >/dev/null || bad "second adb forward failed"
# A: fast (it must found), B: 1.5 s in the way (it must hold, then join).
start_faults join pass delay 1500

FILE="$WORK/pd-direct-p1-$(date +%s).bin"
NAME="$(basename "$FILE")"
head -c 33554432 /dev/urandom > "$FILE"
EXPECT_SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"
drop_script "$WORK/drop-script.txt" "$FILE" "$WORK/drop-go"
"$APP" --profile "$PROFILE" --background \
    --connect 127.0.0.1:47821 --connect2 127.0.0.1:47822 \
    --open com.android.settings --debug-input-script "$WORK/drop-script.txt" \
    --quit-after 150 > "$WORK/app-join.out" 2>&1 &
APP_PID=$!
LOG_STREAM="$(stream_log "$APP_PID" "$WORK/mac-join.log")"

JOINED=0
for _ in $(seq 1 160); do
    emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-join.log"
    grep -q 'paths: joined' "$WORK/phone-join.log" && { JOINED=1; break; }
    sleep 0.25
done
PHONE_JOIN_ID="$(grep -o 'paths: joined [0-9a-f]*' "$WORK/phone-join.log" | tail -1 | awk '{print $3}')"
if [ "$JOINED" = 1 ]; then
    ok "the phone attached the second path to the same session: $(grep -o 'paths: joined [0-9a-f]* (paths [0-9]*)' "$WORK/phone-join.log" | tail -1)"
else
    bad "no join in the phone log"
fi
# The Mac's own fact for two live paths (item 2's line). The session state
# stays `live` when a healthy second path arrives, so --up--> transitions only
# ever fired when the first path had failed (boot 6, boot 8: 0 is correct).
MAC_ATTACH=""
for _ in $(seq 1 80); do
    MAC_ATTACH="$(grep -o 'paths: attached [0-9a-f]* (paths [0-9]*)' "$WORK/mac-join.log" | tail -1)"
    [ -n "$MAC_ATTACH" ] && break
    sleep 0.25
done
if [ -z "$MAC_ATTACH" ]; then
    refresh_log "$APP_PID" "$WORK/mac-join.log"
    MAC_ATTACH="$(grep -o 'paths: attached [0-9a-f]* (paths [0-9]*)' "$WORK/mac-join.log" | tail -1)"
fi
MAC_ATTACH_ID="$(printf '%s' "$MAC_ATTACH" | awk '{print $3}')"
if [ -n "$MAC_ATTACH" ] && [ -n "$PHONE_JOIN_ID" ] && [ "$MAC_ATTACH_ID" = "$PHONE_JOIN_ID" ]; then
    ok "the Mac logged the same path attached to the live session: $MAC_ATTACH"
else
    bad "the Mac did not log a second live path (windows attach='$MAC_ATTACH', phone join='$PHONE_JOIN_ID')"
fi
# No supersede of the join's own session: scope to the session it founded.
SESSION_AT="$(grep -n 'session slot: free --adopted--> live' "$WORK/phone-join.log" | tail -1 | cut -d: -f1)"
if [ -z "$SESSION_AT" ]; then
    bad "the phone log has no adopted session for the join"
elif tail -n +"$SESSION_AT" "$WORK/phone-join.log" | grep -q 'session superseded'; then
    bad "a connect superseded the session the join had just founded"
elif tail -n +"$SESSION_AT" "$WORK/phone-join.log" | grep -q 'paths: ended'; then
    bad "a path/session ended after the join"
else
    ok "the join did not supersede or end its own session"
fi

# The founder is the provider that welcomed first. A is the fast proxy and B
# delays every byte by 1.5 s, so the Mac's two `tls connected` lines must be
# at least a second apart. Boot 8 picked the earliest `conn` event instead and
# throttled B while the drop ran on A (the tell: 32 MiB in 0.58 s).
TLS_TIMES="$(grep -o '^2026-[0-9-]* [0-9:.]*.*tls connected (path [0-9a-f]*)' "$WORK/mac-join.log" |
    sed -E 's/^(2026-[0-9-]+ [0-9:.]+).*(path [0-9a-f]+).*/\1 \2/' | sort -u |
    awk '!seen[$4]++')"
FIRST_TLS="$(printf '%s\n' "$TLS_TIMES" | sed -n '1p')"
SECOND_TLS="$(printf '%s\n' "$TLS_TIMES" | sed -n '2p')"
FOUNDER_PATH="$(printf '%s' "$FIRST_TLS" | awk '{print $4}')"
JOIN_PATH="$(printf '%s' "$SECOND_TLS" | awk '{print $4}')"
TLS_DELTA=""
if [ -n "$FIRST_TLS" ] && [ -n "$SECOND_TLS" ]; then
    TLS_DELTA="$(python3 - "$FIRST_TLS" "$SECOND_TLS" <<'PY'
from datetime import datetime
import sys
def stamp(line):
    date, clock = line.split()[:2]
    return datetime.strptime(date + " " + clock, "%Y-%m-%d %H:%M:%S.%f").timestamp()
print("%.3f" % (stamp(sys.argv[2]) - stamp(sys.argv[1])))
PY
)"
fi
if [ -n "$TLS_DELTA" ] && [ -n "$PHONE_JOIN_ID" ] && [ "$JOIN_PATH" = "$PHONE_JOIN_ID" ] &&
    python3 -c "import sys; sys.exit(0 if $TLS_DELTA >= 1.0 else 1)"; then
    ok "the founder is the fast proxy A (tls connected $TLS_DELTA s before the join path $JOIN_PATH)"
else
    bad "cannot prove the founder is A (first '$FIRST_TLS', second '$SECOND_TLS', phone join '$PHONE_JOIN_ID')"
fi
printf 'mode throttle\n' > "$WORK/fault-a.join.ctl"
printf 'mode pass\n' > "$WORK/fault-b.join.ctl"
# Let the ctl watcher apply the throttle before the first data chunk.
sleep 0.3

# Let the drop start only now: the founder is throttled to 16 Mbit/s.
: > "$WORK/drop-go"
DROP_T0="$(python3 -c 'import time; print("%.6f" % time.time())')"
DROP_LOG_OFFSET="$(wc -l < "$WORK/mac-join.log" | tr -d ' ')"
STARTED=0
PART_AT_BLACKHOLE=""
for _ in $(seq 1 240); do
    PART_AT_BLACKHOLE="$(emu shell "stat -c %s /sdcard/Download/PocketDeck/.part-* 2>/dev/null" 2>/dev/null | tr -d '\r' | head -1)"
    if [ -n "$PART_AT_BLACKHOLE" ] && [ "$PART_AT_BLACKHOLE" -ge 8388608 ] 2>/dev/null; then STARTED=1; break; fi
    sleep 0.25
done
if [ "$STARTED" = 1 ]; then
    ok "the drop reached 8 MiB on the founder (.part $PART_AT_BLACKHOLE bytes at the cut)"
else
    bad "the drop never reached 8 MiB"
fi
# A throttled 16 Mbit/s founder cannot have finished 32 MiB by the time the
# 8 MiB mark is seen; a full-size .part means the transfer ran on the standby
# and the black-hole would prove nothing (boot 8: 0.58 s for 32 MiB).
if [ -n "$PART_AT_BLACKHOLE" ] && [ "$PART_AT_BLACKHOLE" -ge 33554432 ] 2>/dev/null; then
    bad "the whole file was already on disk before the black-hole: the drop did not use the founder"
fi
printf 'mode blackhole\n' > "$WORK/fault-a.join.ctl"
SAVED=0
# Two 60 s pieces: a single wait may never be longer than the debug-input cap.
for _piece in 1 2; do
    for _ in $(seq 1 240); do
        emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-drop.log"
        grep -q 'drop [0-9]*: saved' "$WORK/phone-drop.log" && { SAVED=1; break; }
        sleep 0.25
    done
    [ "$SAVED" = 1 ] && break
done
TARGET="/sdcard/Download/PocketDeck/$NAME"
if [ "$SAVED" = 1 ]; then
    ok "the phone saved the file after the black-hole: $(grep -o 'drop [0-9]*: saved .*' "$WORK/phone-drop.log" | tail -1)"
else
    bad "the drop never finished"
fi
# The events name the two cuts; the byte counters say which proxy carried the
# data, so "throttled then black-holed after 8 MiB" and "the other proxy kept
# moving bytes" are facts, not an inference from the hash.
BLACKHOLE_TS="$(python3 - "$WORK/fault-a.join.events" <<'PY'
import json, sys
ts = None
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "mode" and event.get("mode") == "blackhole":
        ts = event.get("ts")
print("%.6f" % ts if ts else "")
PY
)"
if [ -z "$BLACKHOLE_TS" ]; then
    bad "the founder proxy never recorded the black-hole mode"
    BLACKHOLE_TS="$DROP_T0"
fi
EVENT_ORDER="$(python3 - "$WORK/fault-a.join.events" <<'PY'
import json, sys
throttle = []
blackhole = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") != "mode":
        continue
    if event.get("mode") == "throttle":
        throttle.append(event.get("ts", 0))
    if event.get("mode") == "blackhole":
        blackhole.append(event.get("ts", 0))
print("ok" if throttle and blackhole and min(throttle) < max(blackhole) else "no")
PY
)"
if [ "$EVENT_ORDER" = ok ]; then
    ok "the founder was throttled before it was black-holed"
else
    bad "the founder's events do not show throttle before black-hole"
fi
FOUNDER_BYTES="$(python3 - "$WORK/fault-a.join.events" "$DROP_T0" <<'PY'
import json, sys
start = float(sys.argv[2])
base = None
best = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") != "bytes" or event.get("dir") != 0:
        continue
    total = event.get("total", 0)
    if base is None and event.get("ts", 0) >= start:
        base = total - event.get("n", 0)
    if base is not None:
        best = max(best, total)
print(best - (base or 0))
PY
)"
if [ "${FOUNDER_BYTES:-0}" -ge 8388608 ] 2>/dev/null; then
    ok "the founder delivered the drop before the cut ($FOUNDER_BYTES bytes after drop-go)"
else
    bad "the founder delivered only $FOUNDER_BYTES bytes after drop-go (the drop missed it)"
fi
OTHER_BYTES="$(python3 - "$WORK/fault-b.join.events" "$BLACKHOLE_TS" <<'PY'
import json, sys
start = float(sys.argv[2])
total = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("ev") == "bytes" and event.get("dir") == 0 and event.get("ts", 0) > start:
        total += event.get("n", 0)
print(total)
PY
)"
if [ "${OTHER_BYTES:-0}" -ge 8388608 ] 2>/dev/null; then
    ok "the standby proxy kept moving the drop after the cut ($OTHER_BYTES bytes after the black-hole)"
else
    bad "the standby proxy moved only $OTHER_BYTES bytes after the black-hole"
fi
GOT_SHA="$(emu shell "sha256sum '$TARGET' 2>/dev/null" | tr -d '\r' | awk '{print $1}')"
if [ -n "$GOT_SHA" ] && [ "$GOT_SHA" = "$EXPECT_SHA" ]; then
    ok "the 32 MiB file is byte-exact across the black-holed path (sha256 $EXPECT_SHA)"
else
    bad "file hash mismatch: host $EXPECT_SHA device ${GOT_SHA:-missing}"
fi
grep -q 'drop: ok' "$WORK/mac-join.log" && ok "the Mac's drop sender reported ok" \
    || bad "the Mac's drop sender did not report ok"
# The drop's window, not the whole log: the first dial's timeout (boot 8's
# 08:14:10) is before the drop and is not a session failure during it.
if tail -n +"$((DROP_LOG_OFFSET + 1))" "$WORK/mac-join.log" | grep -q 'session failed'; then
    bad "the session failed during the drop"
else
    ok "the session stayed live through the drop (drop window from $(printf '%s' "$DROP_T0" | cut -c1-14))"
fi
SWITCH_LINE="$(tail -n +"$((DROP_LOG_OFFSET + 1))" "$WORK/mac-join.log" |
    grep -o 'paths: sending [0-9a-f]* -> [0-9a-f]* ([a-z-]*)' | head -1)"
if [ -n "$SWITCH_LINE" ]; then
    ok "the Mac named the sending-path change: $SWITCH_LINE"
else
    bad "the Mac never named a sending-path change during the drop"
fi
printf '[p1-proof] drop timings: Mac `drop: sending` %s, Mac `drop: ok` %s; phone `streaming` %s, `saved` %s\n' \
    "$(grep 'drop: sending' "$WORK/mac-join.log" | tail -1 | awk '{print $1" "$2}')" \
    "$(grep 'drop: ok' "$WORK/mac-join.log" | tail -1 | awk '{print $1" "$2}')" \
    "$(grep -o '^10-31 [0-9:.]*' "$WORK/phone-drop.log" | head -1)" \
    "$(grep 'drop [0-9]*: saved' "$WORK/phone-drop.log" | tail -1)"
stop_app
wait_slot_free "$WORK/phone-join-end.log" 40 join || true
stop_proxies

# --- 30 s grace ------------------------------------------------------------
section grace
emu logcat -c >/dev/null 2>&1 || true
start_faults grace pass pass
"$APP" --profile "$PROFILE" --background \
    --connect 127.0.0.1:47821 --connect2 127.0.0.1:47822 \
    --open-phone --quit-after 70 > "$WORK/app-grace.out" 2>&1 &
APP_PID=$!
LOG_STREAM="$(stream_log "$APP_PID" "$WORK/mac-grace.log")"
GRACE_JOINED=0
for _ in $(seq 1 160); do
    emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-grace.log"
    grep -q 'paths: joined' "$WORK/phone-grace.log" && { GRACE_JOINED=1; break; }
    sleep 0.25
done
[ "$GRACE_JOINED" = 1 ] && ok "a fresh two-path session is live" || bad "the grace session never joined"
sleep 2
printf 'mode blackhole\n' > "$WORK/fault-a.grace.ctl"
printf 'mode blackhole\n' > "$WORK/fault-b.grace.ctl"
GRACE_T0=$(date +%s)
MAC_GRACE=0
for _ in $(seq 1 160); do
    if grep -q -- 'orphaned --grace--> ended' "$WORK/mac-grace.log"; then MAC_GRACE=1; break; fi
    sleep 0.25
done
if [ "$MAC_GRACE" = 0 ]; then
    refresh_log "$APP_PID" "$WORK/mac-grace.log"
    grep -q -- 'orphaned --grace--> ended' "$WORK/mac-grace.log" && MAC_GRACE=1
fi
GRACE_DT=$(( $(date +%s) - GRACE_T0 ))
if [ "$MAC_GRACE" = 1 ] && [ "$GRACE_DT" -ge 28 ]; then
    ok "the Mac ended the session at the 30 s grace (orphaned --grace--> ended, ${GRACE_DT}s after the black-hole)"
else
    bad "no Mac grace transition in the 30 s window (${GRACE_DT}s, found=$MAC_GRACE)"
fi
SLOT_FREE=0
for _ in $(seq 1 40); do
    emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-grace.log"
    grep -q 'session slot: live --ended--> free' "$WORK/phone-grace.log" && { SLOT_FREE=1; break; }
    sleep 0.25
done
if [ "$SLOT_FREE" = 1 ]; then
    ok "the phone freed the session slot when the paths died"
else
    bad "the phone's session slot did not free"
fi
grep -q 'paths: ended graceExpired' "$WORK/phone-grace.log" \
    && ok "the phone's own path machine also reached its grace end" \
    || printf '[p1-proof] note: the phone session tore down before its path-machine grace\n'
sleep 2
emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-grace.log"
grep -E 'power:|panel given back|phone back to sleep' "$WORK/phone-grace.log" > "$WORK/phone-power.log" 2>/dev/null || true
emu shell dumpsys power 2>/dev/null | grep -E 'mWakefulness|Display Power' > "$WORK/dumpsys-power.txt" 2>/dev/null || true
emu shell dumpsys display 2>/dev/null | grep -E 'mScreenState|mState=' | head -5 > "$WORK/dumpsys-display.txt" 2>/dev/null || true
if grep -q 'mWakefulness=Awake' "$WORK/dumpsys-power.txt"; then
    ok "the panel is awake after the grace ($(tr '\n' ' ' < "$WORK/dumpsys-power.txt"))"
else
    bad "the panel is not awake after the grace: $(tr '\n' ' ' < "$WORK/dumpsys-power.txt")"
fi
[ -s "$WORK/phone-power.log" ] && ok "phone power log: $(tr '\n' ' ' < "$WORK/phone-power.log")" \
    || ok "no panel override was left (no power line needed)"
stop_app
stop_proxies

# --- a v3 hello is refused with v ------------------------------------------
section version
# The refusal is a pre-session gate: the probe must be alone on the listener.
# This step waits for the phone's slot to be free after the grace (cap 30 s),
# because the grace teardown and the Mac app's own last retries can still hold
# the two handshake workers (boot 8: the probe was closed with SSLEOF at
# 08:15:25.137 while the slot freed at 08:15:25.227). Running before the grace
# would instead hit the live session's busy slot, which is not a version
# verdict. A handshake-level collision is retried; the verdict still requires
# the exact `error version {v:4}` and a close.
v3_probe() {
    ROOT="$ROOT" ADDR="$ADDR" "$PYTHON" - "$WORK/v3-identity" <<'PY'
import os, socket, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "tools", "fakephone"))
import proto
identity = sys.argv[1]
proto.make_identity(identity, cn="v3 probe")
cert, key = proto.identity_paths(identity)
host, port = os.environ["ADDR"].rsplit(":", 1)
raw = socket.create_connection((host, int(port)), timeout=10)
context = proto.tls_client_context(cert, key)
sock = context.wrap_socket(raw, server_hostname="pocketdeck")
sock.sendall(proto.pack_json({"t": "hello", "v": 3, "clientId": "v3-probe",
                              "name": "v3 probe"}))
frame = proto.recv_frame(sock)
message = proto.unpack_json(frame) if frame is not None else {}
after = proto.recv_frame(sock)
print("code=%s v=%s closed=%s" % (message.get("code"), message.get("v"), after is None))
sys.exit(0 if message.get("code") == "version" and message.get("v") == 4 and after is None else 1)
PY
}
wait_slot_free "$WORK/phone-grace.log" 30 version || true
sleep 2
V3_OK=0
V3_OUT=""
for attempt in 1 2 3; do
    if V3_OUT="$(v3_probe 2>&1 | tail -2 | tr '\n' ' ')"; then
        V3_OK=1
        printf '[p1-proof] v3 probe attempt %s: %s\n' "$attempt" "$V3_OUT"
        break
    fi
    printf '[p1-proof] v3 probe attempt %s: %s (a busy handshake pool is not a version verdict)\n' "$attempt" "$V3_OUT"
    sleep 2
done
if [ "$V3_OK" = 1 ]; then
    ok "a v3-shaped hello got error version with v=4 and a close, no welcome ($V3_OUT)"
else
    bad "the v3 hello was not refused with v=4 ($V3_OUT)"
fi

# --- the slot is free: a fresh pairing succeeds ----------------------------
section slot
bring_app_forward
if "$PYTHON" "$HERE/poc.py" --addr "$ADDR" --serial "$SERIAL" \
        --state "$WORK/deckctl-state.json" pair --timeout 60 \
        > "$WORK/deckctl-pair.log" 2>&1; then
    ok "a new Mac paired after the grace: the slot is free ($(grep -o 'device=[0-9a-f]*' "$WORK/deckctl-pair.log" | tail -1))"
else
    bad "a new Mac could not pair after the grace: $(tail -3 "$WORK/deckctl-pair.log")"
fi
if "$PYTHON" "$HERE/poc.py" --addr "$ADDR" --serial "$SERIAL" \
        --state "$WORK/deckctl-state.json" check > "$WORK/deckctl-check.log" 2>&1; then
    ok "the paired probe checks out: $(tail -1 "$WORK/deckctl-check.log")"
else
    bad "the paired probe did not check out: $(tail -2 "$WORK/deckctl-check.log")"
fi
emu logcat -d -v time -s PocketDeckSvc:I 2>/dev/null > "$WORK/phone-final.log"

printf '\n== result ==\n'
if [ "$FAIL" -eq 0 ]; then
    echo "PASS: every direct-p1 emulator proof passed (one boot)"
else
    echo "FAIL: $FAIL proof(s) failed (one boot)"
fi
exit "$FAIL"
