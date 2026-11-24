#!/usr/bin/env bash
# idrcheck — one boot proves ISS-40's drop recovery and key-frame counts on the
# real shell server (emulator).
#
#   bash tools/emulator/idrcheck.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/idrcheck.sh
#
# Build the APK and the e2e Mac app first, in their own heavy steps:
#   cd <worktree>/android && ./gradlew :app:assembleDebug
#   (cd macos && bash scripts/bundle.sh build/e2e/Contigua.app --variant e2e)
#
# What it does on the one boot:
#   * boots the rig (tools/emulator/start.sh --no-build) and unlocks it;
#   * pairs the e2e Mac app through the real prompt;
#   * runs the bench arms `stall` and `stall-ir60`, one repeat each, through
#     the app's own MCP tools;
#   * prints the table, every `key nal=` and `drop:` line,
#     both sides' totals/`stats total` lines and the strategy line (`ir=`);
#   * kills the emulator with `adb -s emulator-5554 emu kill` in cleanup.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "idrcheck.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_IDRCHECK_WORK:-/tmp/pd-idrcheck-emu}"
OUT="${CONTIGUA_IDRCHECK_OUT:-$ROOT/.work/idrcheck/emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
BENCH="$ROOT/tools/stream-bench/bench.py"
ARMS="$ROOT/tools/stream-bench/arms.json"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="idrcheckemu$$"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
E2E_LOCK=/tmp/contigua-e2e.lock
HOLDS_E2E=0
APP_PID=""
TAP_PID=""
CAT_PID=""
FAIL=0
PHASE=""

section() { PHASE="$1"; printf '\n== %s ==\n' "$1"; }
ok() { printf 'PASS [%s] %s\n' "$PHASE" "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$PHASE" "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[idrcheck] %s\n' "$*"; }

wait_for() { # wait_for <seconds> <command...>
    local deadline=$(( $(date +%s) + $1 ))
    shift
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.25
    done
    return 1
}

app_alive() { [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; }

# --- --check: everything a boot would die on, without touching a device -----
if [ "$MODE" = check ]; then
    CHECK_FAIL=0
    cfail() { echo "IDRCHECK CHECK FAIL: $*"; CHECK_FAIL=1; }
    [ "$SERIAL" = "emulator-5554" ] ||
        cfail "serial '$SERIAL' is not emulator-5554 (never any other serial)"
    bash "$HERE/preflight.sh" || CHECK_FAIL=1
    bash -n "$0" || cfail "bash -n $0"
    "$PYTHON" -m py_compile "$BENCH" "$ROOT/tools/stream-bench/test_bench.py" ||
        cfail "py_compile bench and its tests"
    "$PYTHON" "$ROOT/tools/stream-bench/test_bench.py" >/dev/null 2>&1 ||
        cfail "stream-bench test_bench"
    "$PYTHON" - "$ARMS" <<'PY' || cfail "arms.json lacks stall or stall-ir60"
import json, sys
data = json.load(open(sys.argv[1]))
arms = {arm["name"]: arm for arm in data["arms"]}
assert {"stall", "stall-ir60"} <= set(arms), sorted(arms)
PY
    "$PYTHON" "$BENCH" --profile x --serial emulator-5554 --out /dev/null \
        --repeats 1 --arms "$ARMS" --arms-filter stall --dry-run >/dev/null 2>&1 ||
        cfail "bench --dry-run"
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP"
    [ -x "$SHIM" ] || cfail "no MCP shim at $SHIM"
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
    [ -d "$ROOT/tools/emulator/.cache" ] || cfail "no emulator cache at tools/emulator/.cache"
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "IDRCHECK CHECK PASS: one boot, $SERIAL, APK $(apk_version_code "$APK"), profile $PROFILE"
        exit 0
    fi
    echo "IDRCHECK CHECK FAIL"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
exec > >(tee "$WORK/idrcheck.out") 2>&1

stop_app() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
}

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
    if [ "$HOLDS_E2E" = "1" ] && [ "$(cat "$E2E_LOCK/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$E2E_LOCK"
    fi
    HOLDS_E2E=0
}

cleanup() {
    local trap_rc=$?
    stop_app
    [ -n "$TAP_PID" ] && kill "$TAP_PID" 2>/dev/null || true
    [ -n "$CAT_PID" ] && kill "$CAT_PID" 2>/dev/null || true
    release_e2e_lock
    "$ADB" -s "$SERIAL" forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
    # The only allowed kill: this emulator's own console.
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    exit "$trap_rc"
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
            grep -Eq 'ResumedActivity:.*dev\.contigua/[^ ]*app\.MainActivity|topResumedActivity=.*dev\.contigua/[^ ]*app\.MainActivity'; then
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
    local pins="$SUPPORT/pins.json"
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

pair_mac_once() { # pair_mac_once <attempt>
    local attempt="$1"
    local prompt="$WORK/mac-prompt-$attempt.log"
    bring_app_forward || return 1
    "$PYTHON" "$POC" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" \
        wait-prompt --timeout 90 --stale none --evidence "$WORK/pair-$attempt" \
        > "$prompt" 2>&1 &
    TAP_PID=$!
    "$APP" --profile "$PROFILE" --background --connect "127.0.0.1:$PORT" \
        --open-phone --quit-after 100 > "$WORK/app-pair-$attempt.log" 2>&1 &
    APP_PID=$!
    wait_for 100 pin_stored || true
    local paired=0
    pin_stored && paired=1
    sleep 1
    stop_app
    wait "$TAP_PID" 2>/dev/null || true
    TAP_PID=""
    [ "$paired" = 1 ]
}

app_connected() {
    /usr/bin/log show --last 3m --info --style syslog \
        --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null |
        grep -q "hello --welcome--> welcomed"
}

# --- boot -------------------------------------------------------------------
section boot
bash "$HERE/start.sh" --no-build > "$WORK/start.log" 2>&1
if [ $? -ne 0 ]; then
    tail -40 "$WORK/start.log"
    bad "start.sh --no-build failed"
    exit 1
fi
ADDR="$(sed -n 's/^CONTIGUA_ADDR=//p' "$WORK/start.log" | tail -1)"
DEVPORT="$(sed -n 's/^CONTIGUA_DEVICE_PORT=//p' "$WORK/start.log" | tail -1)"
[ -n "$ADDR" ] && [ -n "$DEVPORT" ] || { tail -20 "$WORK/start.log"; bad "no address/port"; exit 1; }
ok "booted, real server at $ADDR (device $DEVPORT)"
emu logcat -c >/dev/null 2>&1 || true
emu logcat -v brief -s ContiguaSvc:I > "$WORK/logcat.txt" 2>&1 &
CAT_PID=$!

python3 - "$ARMS" "$WORK/arms.json" <<'PY' || { bad "could not build the two-arm list"; exit 1; }
import json, sys
data = json.load(open(sys.argv[1]))
want = {"stall", "stall-ir60"}
arms = [arm for arm in data["arms"] if arm["name"] in want]
assert {arm["name"] for arm in arms} == want
json.dump({"arms": arms}, open(sys.argv[2], "w"))
PY

bash "$HERE/unlock.sh" >/dev/null 2>&1 || true
acquire_e2e_lock || bad "no e2e lock: the Mac window is exposed to another agent's input"

# --- Mac app: pair and bench ------------------------------------------------
section bench
rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
PAIRED_MAC=0
for attempt in 1 2; do
    if pair_mac_once "$attempt"; then PAIRED_MAC=1; break; fi
    say "Mac app pair attempt $attempt failed"
    stop_app
    sleep 3
done
if [ "$PAIRED_MAC" = 1 ]; then
    ok "the e2e Mac app paired and stored the phone pin"
else
    bad "the Mac app did not pair/store a pin"
    exit 1
fi

"$APP" --profile "$PROFILE" --background --mcp-enable --mcp-dev-tools \
    --connect "127.0.0.1:$PORT" --quit-after 300 > "$WORK/app-bench.log" 2>&1 &
APP_PID=$!
if wait_for 60 app_connected; then
    ok "the Mac app session is ready for MCP"
else
    bad "the Mac app never welcomed the phone"
    exit 1
fi

CSV="$OUT/bench-idrcheck.csv"
"$PYTHON" "$BENCH" --profile "$PROFILE" --serial "$SERIAL" --adb "$ADB" \
    --repeats 1 --out "$CSV" --shim "$SHIM" --arms "$WORK/arms.json" \
    --package com.android.settings > "$WORK/bench.log" 2>&1
BENCH_RC=$?
sleep 2
# The live capture can lose its last buffer block when killed; the device's
# ring buffer is the authority for the phone's own lines.
emu logcat -d -v brief -s ContiguaSvc:I > "$WORK/logcat-dump.txt" 2>&1 || true
[ -s "$WORK/logcat-dump.txt" ] && cp "$WORK/logcat-dump.txt" "$WORK/logcat.txt"
cat "$WORK/bench.log"
[ "$BENCH_RC" = 0 ] && ok "the bench run completed" || bad "the bench run failed (rc=$BENCH_RC)"
rows="$(($(wc -l < "$CSV" 2>/dev/null || echo 1) - 1))"
[ "$rows" -eq 2 ] && ok "the bench CSV has one run per arm (2)" \
    || bad "the bench CSV has $rows runs, expected 2"
for arm in stall stall-ir60; do
    grep -Eq "^$arm( |\(|$)" "$WORK/bench.log" \
        && ok "the bench table has its $arm row" \
        || bad "no $arm row in the bench table"
done

# --- the evidence ------------------------------------------------------------
section lines
/usr/bin/log show --last 30m --info --style syslog \
    --predicate "subsystem == \"app.contigua.mac\" AND processID == $APP_PID" 2>/dev/null \
    > "$WORK/mac.log" || true
grep -E " stats (total )?stream=" "$WORK/mac.log" > "$WORK/mac-stats.txt" || true
MAC_LINES="$(grep -c . "$WORK/mac-stats.txt" 2>/dev/null || true)"
[ "${MAC_LINES:-0}" -ge 2 ] && ok "the Mac wrote $MAC_LINES stats lines" \
    || bad "the Mac wrote ${MAC_LINES:-0} stats lines"
MAC_TOTALS="$(grep -c " stats total stream=" "$WORK/mac-stats.txt" 2>/dev/null || true)"
[ "${MAC_TOTALS:-0}" -eq 2 ] && ok "both runs closed with a stats total line" \
    || bad "the Mac wrote ${MAC_TOTALS:-0} stats total lines, expected 2"

printf '\nMac totals:\n'
grep " stats total stream=" "$WORK/mac-stats.txt" || true
printf '\nMac 5 s lines (tail):\n'
grep " stats stream=" "$WORK/mac-stats.txt" | tail -6 || true
printf '\nMac key/drop lines:\n'
grep -E " stream [0-9]+ key nal=" "$WORK/mac.log" || true
printf '\nPhone drop/key totals:\n'
grep -E "stream [0-9]+ (drop: |key nal=|totals: |strategy: )" "$WORK/logcat.txt" || true

MAC_KEY="$(grep -cE " stream [0-9]+ key nal=" "$WORK/mac.log" 2>/dev/null || true)"
PHONE_KEY="$(grep -cE "stream [0-9]+ key nal=" "$WORK/logcat.txt" 2>/dev/null || true)"
PHONE_DROP="$(grep -cE "stream [0-9]+ drop: " "$WORK/logcat.txt" 2>/dev/null || true)"
PHONE_TOTALS="$(grep -cE "stream [0-9]+ totals: " "$WORK/logcat.txt" 2>/dev/null || true)"
say "key nal lines: Mac=$MAC_KEY phone=$PHONE_KEY; phone drop lines=$PHONE_DROP; phone totals=$PHONE_TOTALS"
[ "${PHONE_TOTALS:-0}" -ge 2 ] && ok "both runs wrote a phone totals line" \
    || bad "the phone wrote ${PHONE_TOTALS:-0} totals lines, expected 2"
grep -q "strategy:.*ir=60" "$WORK/logcat.txt" \
    && ok "the intra-refresh arm asked for ir=60" \
    || bad "no stream strategy line with ir=60"
if grep -q "strategy:.*ir=60 unsupported" "$WORK/logcat.txt"; then
    say "the emulator's encoder reports ir=60 unsupported; the phone's key_idr/key_not_idr counts still say what it sent"
fi
grep " stats total stream=" "$WORK/mac-stats.txt" | grep -q "max_gap_ms=[0-9]" \
    && ok "the totals line carries max_gap_ms" \
    || bad "no totals line with max_gap_ms"
grep " stats total stream=" "$WORK/mac-stats.txt" | grep -q "key_not_idr=" \
    && ok "the totals line carries key_not_idr" \
    || bad "no totals line with key_not_idr"
grep " stats total stream=" "$WORK/mac-stats.txt" | grep -q "ph_key_not_idr=" \
    && ok "the totals line carries the phone's ph_key_not_idr" \
    || bad "no totals line with ph_key_not_idr"

stop_app
say "artifacts: $WORK, $CSV"

if [ "$FAIL" -eq 0 ]; then
    say "IDRCHECK EMULATOR PASS"
else
    say "IDRCHECK EMULATOR FAIL: $FAIL"
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
