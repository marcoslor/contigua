#!/usr/bin/env bash
# pairloop — one boot pairs the e2e Mac app with the real shell server through
# the phone's real prompt, ends that session, and pairs again, N times (#190).
#
#   bash tools/emulator/pairloop.sh --check        # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/pairloop.sh [--rounds N]   # default 10
#
# Build the APK and the e2e Mac app first, in their own heavy steps:
#   <worktree>/android: ./gradlew :app:assembleDebug (in Docker)
#   (cd macos && bash scripts/bundle.sh build/e2e/Contigua.app --variant e2e)
#
# Every round is a fresh Mac profile (a new Mac identity, no pin), so each one
# is a first pairing: the app is launched with --connect, poc.py reads the
# phone's prompt and taps Allow, the round passes when the profile stored the
# phone's pin, and the app then quits the way a person's Quit does (the
# `--debug-control` `quit` verb, NSApp.terminate), which closes the session so
# the phone is free for the next round; a kill would leave the phone holding
# an orphaned session for PATH-6's 30 s and the next round would meet `busy`.
# A round fails
# when it did not pair, and also when its app log has the NIO line "EventLoop
# that has already shut down" (issue #190), paired or not.
#
# The work dir is this checkout's own (.work/pairloop/<pid>), never a shared
# /tmp path: two rigs must not write each other's start.log (#190).
# Only `adb -s $SERIAL`; the rig's lock state is start.sh/unlock.sh's alone.
set -uo pipefail

MODE=run
ROUNDS=10
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check; shift ;;
        --rounds) ROUNDS="${2:?--rounds needs a number}"; shift 2 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "pairloop.sh: unknown flag $1" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_PAIRLOOP_WORK:-$ROOT/.work/pairloop/run-$$}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
POC="$ROOT/tools/emulator/poc.py"
PROFILE_BASE="pairloop$$r"
EVL="EventLoop that has already shut down"
APP_PID=""
TAP_PID=""
PROFILE=""

say() { printf '[pairloop] %s\n' "$*"; }

support_of() { printf '%s/Library/Application Support/Contigua-%s' "$HOME" "$1"; }

wait_for() { # wait_for <seconds> <command...>
    local deadline=$(( $(date +%s) + $1 ))
    shift
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.25
    done
    return 1
}

# --- --check: everything a boot would die on, without touching a device -----
if [ "$MODE" = check ]; then
    CHECK_FAIL=0
    cfail() { echo "PAIRLOOP CHECK FAIL: $*"; CHECK_FAIL=1; }
    case "$SERIAL" in emulator-[0-9]*) : ;; *) cfail "serial '$SERIAL' is not an emulator serial" ;; esac
    case "$ROUNDS" in ''|*[!0-9]*|0) cfail "--rounds '$ROUNDS' is not a positive number" ;; esac
    bash "$HERE/preflight.sh" || CHECK_FAIL=1
    bash -n "$0" || cfail "bash -n $0"
    "$PYTHON" -m py_compile "$POC" || cfail "py_compile poc.py"
    "$PYTHON" "$POC" --help 2>/dev/null | grep -q "wait-prompt" || cfail "poc.py has no wait-prompt"
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP"
    if [ -x "$APP" ]; then
        stale="$(find "$ROOT/macos/Sources" -type f -newer "$APP" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the Mac app is older than $stale"
    fi
    APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$APK" ] || cfail "no debug APK at $APK (build it first)"
    if [ -f "$APK" ]; then
        stale="$(find "$ROOT/android/app/src/main" -type f -newer "$APK" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the APK is older than $stale (rebuild :app:assembleDebug)"
    fi
    case "$WORK" in /tmp/*|/private/tmp/*) cfail "work dir $WORK is a shared /tmp path" ;; esac
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "PAIRLOOP CHECK PASS: one boot, $SERIAL, $ROUNDS rounds, work $WORK"
        exit 0
    fi
    echo "PAIRLOOP CHECK FAIL"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/pairloop.out") 2>&1

quit_app() { # quit_app <control dir>: a person's quit, then stop_app as a fallback
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        printf 'quit\n' > "$1/quit.tmp" && mv "$1/quit.tmp" "$1/quit.cmd"
        for _ in $(seq 1 100); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$APP_PID" 2>/dev/null; then
            # NSApp.terminate can be deferred (shutdownAndExit's comment): the
            # kill below leaves the phone an orphaned session, which it holds
            # for PATH-6's 30 s grace, so the next round waits it out.
            say "the app did not quit in 10 s; stopping it and waiting out the phone's 30 s grace"
            stop_app
            sleep 35
            return
        fi
    fi
    stop_app
}

stop_app() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        for _ in $(seq 1 30); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
    if [ -n "$TAP_PID" ]; then
        kill "$TAP_PID" 2>/dev/null || true
        wait "$TAP_PID" 2>/dev/null || true
        TAP_PID=""
    fi
}

drop_profile() { # the run's own profiles only
    [ -n "$1" ] || return 0
    rm -rf "$(support_of "$1")"
    defaults delete "app.contigua.mac.$1" >/dev/null 2>&1 || true
}

cleanup() {
    local rc=$?
    stop_app
    drop_profile "$PROFILE"
    "$ADB" -s "$SERIAL" forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
    # The only allowed kill: this emulator's own console.
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# The phone's app must be the resumed activity for the pairing prompt.
bring_app_forward() {
    emu shell am start -n app.contigua/.app.MainActivity >/dev/null 2>&1 || true
    local start relaunched=0
    start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt 60 ]; do
        if emu shell dumpsys activity activities 2>/dev/null |
            grep -Eq 'ResumedActivity:.*contigua/[^ ]*app\.MainActivity|topResumedActivity=.*contigua/[^ ]*app\.MainActivity'; then
            sleep 2
            return 0
        fi
        if [ "$relaunched" -eq 0 ] && [ $(( $(date +%s) - start )) -ge 10 ]; then
            emu shell am start -n app.contigua/.app.MainActivity >/dev/null 2>&1 || true
            relaunched=1
        fi
        sleep 1
    done
    say "the app is not the resumed activity after 60 s"
    return 1
}

pin_stored() {
    local pins
    pins="$(support_of "$PROFILE")/pins.json"
    [ -s "$pins" ] || return 1
    "$PYTHON" - "$pins" <<'PY'
import json, re, sys
try:
    records = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if any(re.fullmatch(r"[0-9a-fA-F]{64}", r.get("phoneFingerprintHex") or "")
                 for r in records) else 1)
PY
}

# --- boot -------------------------------------------------------------------
say "boot: start.sh --no-build (log $WORK/start.log)"
if ! bash "$HERE/start.sh" --no-build > "$WORK/start.log" 2>&1; then
    tail -30 "$WORK/start.log"
    echo "FAIL pairloop: start.sh --no-build failed"
    exit 1
fi
ADDR="$(sed -n 's/^CONTIGUA_ADDR=//p' "$WORK/start.log" | tail -1)"
[ -n "$ADDR" ] || { tail -20 "$WORK/start.log"; echo "FAIL pairloop: no address"; exit 1; }
say "booted, real server at $ADDR"
bash "$HERE/unlock.sh" >/dev/null 2>&1 || true

# --- rounds -----------------------------------------------------------------
PAIRED=0
WITH_EVL=0
FAILED=0
for round in $(seq 1 "$ROUNDS"); do
    PROFILE="$PROFILE_BASE$round"
    drop_profile "$PROFILE"
    mkdir -p "$(support_of "$PROFILE")"
    log="$WORK/app-pair-$round.log"
    ctl="$WORK/control-$round"
    mkdir -p "$ctl"
    bring_app_forward || true
    "$PYTHON" "$POC" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" \
        wait-prompt --timeout 90 --stale none --evidence "$WORK/pair-$round" \
        > "$WORK/mac-prompt-$round.log" 2>&1 &
    TAP_PID=$!
    "$APP" --profile "$PROFILE" --background --connect "127.0.0.1:$PORT" \
        --debug-control "$ctl" --open-phone --quit-after 100 > "$log" 2>&1 &
    APP_PID=$!
    paired=0
    wait_for 100 pin_stored && paired=1
    sleep 1
    quit_app "$ctl"   # ends this round's session
    evl="$(grep -c "$EVL" "$log" 2>/dev/null || true)"
    evl="${evl:-0}"
    [ "$paired" = 1 ] && PAIRED=$((PAIRED + 1))
    [ "$evl" -gt 0 ] && WITH_EVL=$((WITH_EVL + 1))
    if [ "$paired" = 1 ] && [ "$evl" -eq 0 ]; then
        echo "PASS round $round: paired, eventloop_errors=0"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL round $round: paired=$paired eventloop_errors=$evl"
        tail -3 "$WORK/mac-prompt-$round.log" | sed 's/^/    prompt: /'
    fi
    drop_profile "$PROFILE"
    PROFILE=""
    sleep 3   # the phone frees its one session before the next round
done

echo "pairloop: rounds=$ROUNDS paired=$PAIRED with_eventloop_error=$WITH_EVL failed=$FAILED"
[ "$FAILED" -eq 0 ]
