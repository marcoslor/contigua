#!/usr/bin/env bash
# strat — one boot runs every ISS-40 strategy arm on the real shell server
# (emulator) through the stream bench, and prints each arm's strategy line.
#
#   bash tools/emulator/strat.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/strat.sh
#
# Build the APK first:
#   cd <worktree>/android && ./gradlew :app:assembleDebug
# and the e2e Mac bundle (once per tree):
#   bash macos/scripts/bundle.sh <worktree>/macos/build/e2e/Contigua.app --variant e2e
#
# What it does on the one boot:
#   * boots the rig (tools/emulator/start.sh --no-build);
#   * pairs the e2e Mac app through the real phone prompt;
#   * runs the stream bench with tools/stream-bench/arms.json, 1 repeat,
#     Settings, while logcat is captured;
#   * prints the bench table and every `stream N strategy:` line, checks each
#     arm's tokens and (when refinement fired) the refined frame's size;
#   * kills the emulator with `adb -s emulator-5554 emu kill` in cleanup.
#
# The emulator's numbers decide nothing; the run proves every switch applied.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "strat.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_STRAT_WORK:-/tmp/pd-strat-emu}"
OUT="${CONTIGUA_STRAT_OUT:-$MAIN_REPO/.agent/strat/emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
BENCH="$ROOT/tools/stream-bench/bench.py"
POC="$ROOT/tools/emulator/poc.py"
ARMS="$ROOT/tools/stream-bench/arms.json"
PROFILE="strat$$"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
E2E_LOCK=/tmp/contigua-e2e.lock
HOLDS_E2E=0
DOCK_DEFAULT_SET=0
APP_PID=""
TAP_PID=""
CAT_PID=""
FAIL=0
PHASE=""

section() { PHASE="$1"; printf '\n== %s ==\n' "$1"; }
ok() { printf 'PASS [%s] %s\n' "$PHASE" "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$PHASE" "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[strat] %s\n' "$*"; }

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
    cfail() { echo "STRAT CHECK FAIL: $*"; CHECK_FAIL=1; }
    [ "$SERIAL" = "emulator-5554" ] ||
        cfail "serial '$SERIAL' is not emulator-5554 (never any other serial)"
    bash "$HERE/preflight.sh" || CHECK_FAIL=1
    bash -n "$0" || cfail "bash -n $0"
    "$PYTHON" -m py_compile "$BENCH" || cfail "py_compile bench"
    "$PYTHON" "$ROOT/tools/stream-bench/test_bench.py" >/dev/null 2>&1 ||
        cfail "bench arm handling test"
    "$PYTHON" "$POC" --help >/dev/null 2>&1 || cfail "poc.py --help"
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP"
    [ -x "$SHIM" ] || cfail "no MCP shim at $SHIM"
    if [ -x "$APP" ]; then
        stale="$(find "$ROOT/macos/Sources" -type f -newer "$APP" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the Mac app is older than $stale"
    fi
    "$PYTHON" - "$ARMS" <<'PY' || cfail "arms.json does not have the strategy arms"
import json, sys
data = json.load(open(sys.argv[1]))
arms = {arm["name"]: arm for arm in data["arms"]}
want = {"baseline", "q1-suspend", "q1q2-100", "r1-cbr", "r2-16", "r2-25",
        "r4-ir60", "t1-refine", "n1-af41", "combo-a"}
missing = want - set(arms)
extra = set(arms) - want
assert not missing and not extra, "missing=%s extra=%s" % (sorted(missing), sorted(extra))
assert list(arms)[0] == "baseline", "baseline must be first"
assert not any(arm["mac"] for arm in arms.values()), "arms are phone-only"
assert arms["combo-a"]["phone"] == {"overflow": "suspend", "queue_ms": "100",
                                    "rc": "cbr", "cap_kbps": "16000",
                                    "ir": "60", "refine": "on", "tos": "136"}
PY
    APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$APK" ] || cfail "no debug APK at $APK (build it first)"
    if [ -f "$APK" ]; then
        stale="$(find "$ROOT/android/app/src/main" -type f -newer "$APK" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the APK is older than $stale (rebuild :app:assembleDebug)"
    fi
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "STRAT CHECK PASS: one boot, $SERIAL, APK $(apk_version_code "$APK"), profile $PROFILE"
        exit 0
    fi
    echo "STRAT CHECK FAIL"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
exec > >(tee "$WORK/strat.out") 2>&1

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
    if [ "$DOCK_DEFAULT_SET" = "1" ]; then
        defaults delete "app.contigua.mac.$PROFILE" showAppsInDock >/dev/null 2>&1 || true
    fi
    # A bundle this run launched must not stay registered in the person's menus.
    if [ -d "$BUNDLE/Contents/PlugIns/Share.appex" ]; then
        pluginkit -r "$BUNDLE/Contents/PlugIns/Share.appex" >/dev/null 2>&1 || true
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BUNDLE" >/dev/null 2>&1 || true
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

bash "$HERE/unlock.sh" >/dev/null 2>&1 || true
acquire_e2e_lock || bad "no e2e lock: the Mac window is exposed to another agent's input"

# --- Mac app: pair, then bench ---------------------------------------------
section pair
rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
defaults write "app.contigua.mac.$PROFILE" showAppsInDock -bool NO || bad "could not turn the Dock identity off"
DOCK_DEFAULT_SET=1
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

"$APP" --profile "$PROFILE" --background --mcp-enable \
    --connect "127.0.0.1:$PORT" --quit-after 600 > "$WORK/app-bench.log" 2>&1 &
APP_PID=$!
if wait_for 60 app_connected; then
    ok "the Mac app session is ready for MCP"
else
    bad "the Mac app never welcomed the phone"
    exit 1
fi

# --- bench, with the phone's own strategy lines -----------------------------
section bench
# Only the bench's own configure lines: the pair phase above opened a mirror.
emu logcat -c >/dev/null 2>&1 || true
emu logcat -v brief -s ContiguaSvc:I > "$WORK/logcat.txt" 2>&1 &
CAT_PID=$!

"$PYTHON" "$BENCH" --profile "$PROFILE" --serial "$SERIAL" --adb "$ADB" \
    --repeats 1 --out "$OUT/bench-emulator.csv" --shim "$SHIM" \
    --package com.android.settings > "$WORK/bench.log" 2>&1
BENCH_RC=$?
sleep 2
# The live capture can lose its last buffer block when killed; the device's
# ring buffer is the authority for the strategy lines.
emu logcat -d -v brief -s ContiguaSvc:I > "$WORK/logcat-dump.txt" 2>&1 || true
cp "$WORK/logcat.txt" "$WORK/logcat-live.txt" 2>/dev/null || true
[ -s "$WORK/logcat-dump.txt" ] && cp "$WORK/logcat-dump.txt" "$WORK/logcat.txt"
cat "$WORK/bench.log"
[ "$BENCH_RC" = 0 ] && ok "the bench run completed" || bad "the bench run failed (rc=$BENCH_RC)"

rows=0
[ -f "$OUT/bench-emulator.csv" ] && rows="$(($(wc -l < "$OUT/bench-emulator.csv") - 1))"
[ "$rows" -eq 10 ] && ok "the bench CSV has one run per arm (10)" \
    || bad "the bench CSV has $rows runs, expected 10"
for arm in baseline q1-suspend q1q2-100 r1-cbr r2-16 r2-25 r4-ir60 t1-refine n1-af41 combo-a; do
    grep -Eq "^$arm[[:space:]]" "$WORK/bench.log" \
        && ok "the bench table has the $arm row" \
        || bad "no $arm row in the bench table"
done

# One configure line per window; consecutive identical lines are a rebuild.
say "raw strategy lines: $(grep -c 'strategy:' "$WORK/logcat.txt" 2>/dev/null || echo 0)"
RAW=()
while IFS= read -r line; do
    [ -n "$line" ] && RAW+=("$line")
done < <(grep -o 'stream [0-9]* strategy: .*' "$WORK/logcat.txt" 2>/dev/null || true)
UNIQUE=()
for line in "${RAW[@]}"; do
    body="${line#*strategy: }"
    last=""
    [ ${#UNIQUE[@]} -gt 0 ] && last="${UNIQUE[$((${#UNIQUE[@]} - 1))]}"
    [ "$body" = "$last" ] && continue
    UNIQUE+=("$body")
done
echo
echo "strategy lines (in run order):"
index=0
for body in "${UNIQUE[@]}"; do
    index=$((index + 1))
    printf '  %2d. %s\n' "$index" "$body"
done
[ ${#UNIQUE[@]} -ge 10 ] && ok "one strategy line per arm (${#UNIQUE[@]})" \
    || bad "only ${#UNIQUE[@]} strategy lines for 10 arms"

describe_arm() { # describe_arm <arm> <token...>
    local arm="$1"; shift
    local body=""
    # The strategy lines are in arms.json order; find the arm's index.
    local order=(baseline q1-suspend q1q2-100 r1-cbr r2-16 r2-25 r4-ir60 t1-refine n1-af41 combo-a)
    local i
    for i in "${!order[@]}"; do
        if [ "${order[$i]}" = "$arm" ]; then
            body="${UNIQUE[$i]:-}"
            break
        fi
    done
    local token
    for token in "$@"; do
        if printf '%s' "$body" | grep -qF -- "$token"; then
            ok "$arm strategy has $token"
        else
            bad "$arm strategy lacks $token (line: ${body:-missing})"
        fi
    done
}

describe_arm baseline "default"
describe_arm q1-suspend "overflow=suspend"
describe_arm q1q2-100 "queue_ms=100" "overflow=suspend"
describe_arm r1-cbr "rc=cbr"
describe_arm r2-16 "cap_kbps=16000"
describe_arm r2-25 "cap_kbps=25000"
describe_arm r4-ir60 "ir=60"
describe_arm t1-refine "refine=on"
describe_arm n1-af41 "tos=0x88"
describe_arm combo-a "rc=cbr" "cap_kbps=16000" "ir=60" "queue_ms=100" \
    "overflow=suspend" "refine=on" "tos=0x88"

echo
REFINE_LINE="$(grep -o 'stream [0-9]* refine: frame [0-9]* bytes (previous [0-9-]*)' "$WORK/logcat.txt" | head -1)"
if [ -n "$REFINE_LINE" ]; then
    ok "a refined frame was sent: $REFINE_LINE"
else
    say "no refined-frame line: the emulator encoder repeated nothing (see refine_n)"
fi
grep -o 'stream [0-9]* refine: [a-z]* --[a-z]*--> [a-z]*' "$WORK/logcat.txt" | head -12

stop_app
say "artifacts: $WORK, $OUT/bench-emulator.csv"

if [ "$FAIL" -eq 0 ]; then
    say "STRAT EMULATOR PASS"
else
    say "STRAT EMULATOR FAIL: $FAIL"
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
