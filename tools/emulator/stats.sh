#!/usr/bin/env bash
# stats — one boot proves ISS-40 against the real shell server (emulator).
#
#   bash tools/emulator/stats.sh --check    # rehearse: no device, no boot
#   PD_STATS_ARMS="baseline c1-hevc" bash tools/emulator/stats.sh --check
#   heavy.sh timeout 2700 bash tools/emulator/stats.sh
#
# Build the APK first, in Docker only:
#   heavy.sh bash .agent/k1-docker.sh <worktree>/android :app:assembleDebug
#
# What it does on the one boot:
#   * boots the rig (tools/emulator/start.sh --no-build);
#   * pairs the deckctl client, opens a Settings window, turns `stream.stats`
#     on, reads 12 real messages from a ~30 s window and matches them against
#     the phone's own `stream N stats sent=<n>` lines, plus `pong`s whose `now`
#     must advance with elapsed time (the phone's CLOCK_MONOTONIC microseconds);
#   * pairs the e2e Mac app and runs the stream bench once (PD_STATS_ARMS,
#     default `baseline q1q2-100`, one repeat, Settings) through the app's own
#     MCP tools, and requires every 5 s line's `phone_n` to be at least 2;
#   * prints the messages, the send counts, the pong lines, the per-line
#     `phone_n`, the bench table and the phone's `stream N qp sample:` line;
#   * prints one 5 s line and the closing totals line with tcp_srtt/tcp_ooo_kb
#     and ph_retrans/ph_rto/ph_lost, and says when /proc/net was unreadable;
#   * kills the emulator with `adb -s emulator-5554 emu kill` in cleanup.
#
# QP may read `-`: the emulator's encoder need not report encoding statistics.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "stats.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_STATS_WORK:-/tmp/pd-stats-emu}"
OUT="${POCKETDECK_STATS_OUT:-$HOME/dev/pocketdeck/.agent/stats/emu}"
BUNDLE="$ROOT/macos/build/e2e/PocketDeck.app"
APP="$BUNDLE/Contents/MacOS/PocketDeck"
SHIM="$BUNDLE/Contents/Helpers/pocketdeck-mcp"
CLIENT="$ROOT/tools/fakephone/deckctl.py"
BENCH="$ROOT/tools/stream-bench/bench.py"
ARMS="$ROOT/tools/stream-bench/arms.json"
POC="$ROOT/tools/emulator/poc.py"
STATE="$CACHE_DIR/deckctl-state-stats-$$.json"
PROFILE="statsemu$$"
SUPPORT="$HOME/Library/Application Support/PocketDeck-$PROFILE"
E2E_LOCK=/tmp/pocketdeck-e2e.lock
HOLDS_E2E=0
DOCK_DEFAULT_SET=0
APP_PID=""
TAP_PID=""
CAT_PID=""
FAIL=0
PHASE=""
# The two arms a run compares; C1's proof uses `baseline c1-hevc`.
WANT_ARMS="${PD_STATS_ARMS:-baseline q1q2-100}"
export PD_STATS_ARMS="$WANT_ARMS"
read -r -a ARM_LIST <<< "$WANT_ARMS"

section() { PHASE="$1"; printf '\n== %s ==\n' "$1"; }
ok() { printf 'PASS [%s] %s\n' "$PHASE" "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$PHASE" "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[stats] %s\n' "$*"; }

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
    cfail() { echo "STATS CHECK FAIL: $*"; CHECK_FAIL=1; }
    [ "$SERIAL" = "emulator-5554" ] ||
        cfail "serial '$SERIAL' is not emulator-5554 (never any other serial)"
    bash "$HERE/preflight.sh" || CHECK_FAIL=1
    bash -n "$0" || cfail "bash -n $0"
    "$PYTHON" -m py_compile "$CLIENT" "$BENCH" || cfail "py_compile deckctl/bench"
    "$PYTHON" "$ROOT/tools/stream-bench/test_bench.py" >/dev/null 2>&1 ||
        cfail "stream-bench test_bench"
    "$PYTHON" - "$ARMS" <<'PY' || cfail "arms.json lacks the requested arms"
import json, os, sys
data = json.load(open(sys.argv[1]))
arms = {arm["name"]: arm for arm in data["arms"]}
want = set(os.environ["PD_STATS_ARMS"].split())
assert "baseline" in want, want
missing = want - set(arms)
assert not missing, "missing=%s" % sorted(missing)
assert not any(arms[name].get("restart") for name in want), "a restart arm cannot run interleaved"
PY
    "$PYTHON" - "$CLIENT" <<'PY' || cfail "deckctl has no stats command"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("deckctl", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert hasattr(module, "cmd_stats"), "deckctl has no cmd_stats"
assert "stats" in module.COMMANDS, "deckctl does not dispatch stats"
PY
    "$PYTHON" "$CLIENT" --host 127.0.0.1 --port 1 stats --help >/dev/null 2>&1 ||
        cfail "deckctl stats --help"
    "$PYTHON" "$POC" --help >/dev/null 2>&1 || cfail "poc.py --help"
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP"
    [ -x "$SHIM" ] || cfail "no MCP shim at $SHIM"
    if [ -x "$APP" ]; then
        stale="$(find "$ROOT/macos/Sources" -type f -newer "$APP" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the Mac app is older than $stale"
    fi
    APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$APK" ] || cfail "no debug APK at $APK (build it in Docker)"
    if [ -f "$APK" ]; then
        stale="$(find "$ROOT/android/app/src/main" -type f -newer "$APK" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the APK is older than $stale (rebuild :app:assembleDebug)"
    fi
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "STATS CHECK PASS: one boot, $SERIAL, APK $(apk_version_code "$APK"), profile $PROFILE"
        exit 0
    fi
    echo "STATS CHECK FAIL"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
exec > >(tee "$WORK/stats.out") 2>&1

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
        defaults delete "dev.pocketdeck.mac.$PROFILE" showAppsInDock >/dev/null 2>&1 || true
    fi
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
    emu shell am start -n dev.pocketdeck/.app.MainActivity >/dev/null 2>&1 || true
    local start relaunched=0
    start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt 60 ]; do
        if emu shell dumpsys activity activities 2>/dev/null |
            grep -Eq 'ResumedActivity:.*dev\.pocketdeck/[^ ]*app\.MainActivity|topResumedActivity=.*dev\.pocketdeck/[^ ]*app\.MainActivity'; then
            sleep 2
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
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null |
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
ADDR="$(sed -n 's/^POCKETDECK_ADDR=//p' "$WORK/start.log" | tail -1)"
DEVPORT="$(sed -n 's/^POCKETDECK_DEVICE_PORT=//p' "$WORK/start.log" | tail -1)"
[ -n "$ADDR" ] && [ -n "$DEVPORT" ] || { tail -20 "$WORK/start.log"; bad "no address/port"; exit 1; }
ok "booted, real server at $ADDR (device $DEVPORT)"
emu logcat -c >/dev/null 2>&1 || true
# The phone's own lines for the whole run: the QP sample is a logcat line the
# reviewer reads on the real phone.
emu logcat -v brief -s PocketDeckSvc:I > "$WORK/logcat.txt" 2>&1 &
CAT_PID=$!

# C1 asks what the AVD's own MediaCodecList offers. A device without an HEVC
# encoder must show the phone's fallback line instead, never a silent AVC run.
section codec
emu shell dumpsys media.codec 2>/dev/null | tr -d '\r' > "$WORK/media-codec.txt" || true
HEVC_ENCODERS="$(grep -oE '[A-Za-z0-9._-]*hevc[A-Za-z0-9._-]*encoder' "$WORK/media-codec.txt" \
    | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ -n "$HEVC_ENCODERS" ]; then
    ok "MediaCodecList names HEVC encoders: $HEVC_ENCODERS"
else
    # This image's `dumpsys media.codec` prints nothing (the service output is
    # empty), so the phone's own createEncoderByType probe is the authority.
    say "dumpsys media.codec returned no list; the phone's codec probe decides below"
fi
grep -iE 'hevc' "$WORK/media-codec.txt" | head -10

python3 - "$ARMS" "$WORK/arms.json" <<'PY' || { bad "could not build the arm list"; exit 1; }
import json, os, sys
data = json.load(open(sys.argv[1]))
want = set(os.environ["PD_STATS_ARMS"].split())
arms = [arm for arm in data["arms"] if arm["name"] in want]
assert {arm["name"] for arm in arms} == want
json.dump({"arms": arms}, open(sys.argv[2], "w"))
PY

bash "$HERE/unlock.sh" >/dev/null 2>&1 || true
acquire_e2e_lock || bad "no e2e lock: the Mac window is exposed to another agent's input"

# --- deckctl: stream.stats and pong.now -------------------------------------
section stats
rm -f "$STATE"
PAIRED=0
for attempt in 1 2 3; do
    bring_app_forward || true
    if "$PYTHON" "$POC" --state "$STATE" --addr "127.0.0.1:$PORT" \
            --serial "$SERIAL" --adb "$ADB" pair; then
        PAIRED=1
        break
    fi
    say "deckctl pair attempt $attempt failed"
    sleep 3
done
if [ "$PAIRED" = 1 ]; then
    ok "the deckctl client paired"
else
    bad "deckctl could not pair with the rig"
    exit 1
fi
sleep 2

STATS_OK=0
for attempt in 1 2 3; do
    if "$PYTHON" "$CLIENT" --host 127.0.0.1 --port "$PORT" --state "$STATE" \
            --wait-for-free 20 stats --pkg com.android.settings --w 900 --h 600 \
            --dpi 160 --messages 12 --seconds 30 > "$WORK/deckctl-stats.log" 2>&1; then
        STATS_OK=1
        break
    fi
    say "deckctl stats attempt $attempt failed: $(tail -2 "$WORK/deckctl-stats.log" | tr '\n' ' ')"
    sleep 3
done
cat "$WORK/deckctl-stats.log"
messages="$(grep -c '^stream.stats ' "$WORK/deckctl-stats.log" || true)"
pongs="$(grep -c '^pong ' "$WORK/deckctl-stats.log" || true)"
# The live capture is a pipe; read the device's ring buffer so the lines the
# phone wrote during this phase are surely in (a live `logcat` can lag).
emu logcat -d -v brief -s PocketDeckSvc:I > "$WORK/logcat-deckctl.txt" 2>&1 || true
SENT_LINES="$(grep -o 'stream [0-9]* stats sent=[0-9]*' "$WORK/logcat-deckctl.txt" 2>/dev/null || true)"
[ -n "$SENT_LINES" ] && printf 'phone: %s\n' "$(printf '%s\n' "$SENT_LINES" | sort -u | tr '\n' ' ')"
[ "$STATS_OK" = 1 ] && ok "deckctl stats completed" || bad "deckctl stats did not complete"
[ "${messages:-0}" -ge 12 ] \
    && ok "read $messages real stream.stats messages (a 30 s window)" \
    || bad "only ${messages:-0} stream.stats messages, expected 12"
printf '%s\n' "$SENT_LINES" | grep -q 'stats sent=10' \
    && ok "the phone logged its tenth message (stream N stats sent=10)" \
    || bad "no 'stream N stats sent=10' line on the phone"
[ "${pongs:-0}" -ge 2 ] \
    && ok "read $pongs pongs, each with a positive now" \
    || bad "only ${pongs:-0} pongs"
grep -q 'STATS OK' "$WORK/deckctl-stats.log" \
    && ok "pong.now advanced with elapsed time (CLOCK_MONOTONIC microseconds)" \
    || bad "pong.now is missing or not monotonic-microseconds"

# The deckctl session must be gone before the Mac app pairs.
sleep 3

# --- Mac app: pair and bench ------------------------------------------------
section bench
rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
defaults write "dev.pocketdeck.mac.$PROFILE" showAppsInDock -bool NO || bad "could not turn the Dock identity off"
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
    --connect "127.0.0.1:$PORT" --quit-after 300 > "$WORK/app-bench.log" 2>&1 &
APP_PID=$!
if wait_for 60 app_connected; then
    ok "the Mac app session is ready for MCP"
else
    bad "the Mac app never welcomed the phone"
    exit 1
fi

"$PYTHON" "$BENCH" --profile "$PROFILE" --serial "$SERIAL" --adb "$ADB" \
    --repeats 1 --out "$OUT/bench-emulator.csv" --shim "$SHIM" \
    --arms "$WORK/arms.json" \
    --package com.android.settings > "$WORK/bench.log" 2>&1
BENCH_RC=$?
sleep 2
# The live capture can lose its last buffer block when killed; the device's
# ring buffer is the authority for the phone's own lines.
emu logcat -d -v brief -s PocketDeckSvc:I > "$WORK/logcat-dump.txt" 2>&1 || true
[ -s "$WORK/logcat-dump.txt" ] && cp "$WORK/logcat-dump.txt" "$WORK/logcat.txt"
cat "$WORK/bench.log"
[ "$BENCH_RC" = 0 ] && ok "the bench run completed" || bad "the bench run failed (rc=$BENCH_RC)"
# The 5 s lines are the source for phone_n now: the bench's own log line
# carries only its table fields.
bench_stats_lines() {
    /usr/bin/log show --last 20m --info --style syslog \
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null \
        | grep -E " stats stream="
}
PHONE_N="$(bench_stats_lines | grep -o 'phone_n=[0-9]*' | cut -d= -f2 | tr '\n' ',' | sed 's/,$//')"
SENT_LINES="$(grep -o 'stream [0-9]* stats sent=[0-9]*' "$WORK/logcat.txt" 2>/dev/null || true)"
[ -n "$PHONE_N" ] && say "Mac per-line phone_n: $PHONE_N"
[ -n "$SENT_LINES" ] && printf 'phone: %s\n' "$(printf '%s\n' "$SENT_LINES" | sort -u | tr '\n' ' ')"
if [ -z "$PHONE_N" ]; then
    bad "no phone_n on the bench's lines"
elif printf '%s\n' "$PHONE_N" | tr ',' '\n' | awk '$1 < 2 { exit 1 }'; then
    ok "every bench line folded in at least two phone messages (phone_n=$PHONE_N)"
else
    bad "a bench line carried fewer than two phone messages (phone_n=$PHONE_N)"
fi
rows="$(($(wc -l < "$OUT/bench-emulator.csv" 2>/dev/null || echo 1) - 1))"
[ "$rows" -eq "${#ARM_LIST[@]}" ] && ok "the bench CSV has one run per arm (${#ARM_LIST[@]})" \
    || bad "the bench CSV has $rows runs, expected ${#ARM_LIST[@]}"
for arm in "${ARM_LIST[@]}"; do
    grep -Eq "^$arm( |\(|$)" "$WORK/bench.log" \
        && ok "the bench table has its $arm row" \
        || bad "no $arm row in the bench table"
done

# X0: one steady 5 s line and the closing totals line, both with the new
# fields. A phone whose shell cannot read /proc/net reports '-' for its three
# counters; K1's fixture holds the parser's proof.
section tcp
/usr/bin/log show --last 20m --info --style syslog \
    --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" 2>/dev/null \
    | grep -E " stats (total )?stream=" > "$WORK/stats-lines.txt" || true
TCP_LINE="$(grep -E ' stats stream=' "$WORK/stats-lines.txt" | grep -E 'tcp_srtt=[0-9]' | tail -1)"
TCP_TOTAL="$(grep -E ' stats total stream=' "$WORK/stats-lines.txt" | tail -1)"
if [ -n "$TCP_LINE" ]; then
    say "5 s line: $(printf '%s\n' "$TCP_LINE" | sed 's/^.*stats stream=/stats stream=/')"
    case "$TCP_LINE" in
        *tcp_srtt=*tcp_rttvar=*tcp_ooo_kb=*ph_retrans=*ph_rto=*ph_lost=*)
            ok "the 5 s line carries the socket's TCP state and the phone's resend counters" ;;
        *) bad "the 5 s line is missing one of the new TCP fields" ;;
    esac
    case "$TCP_LINE" in
        *codec=*qp_avg=*)
            ok "the 5 s line carries codec and qp_avg: $(printf '%s\n' "$TCP_LINE" | grep -o 'codec=[^ ]* qp_avg=[^ ]*')" ;;
        *) bad "the 5 s line is missing codec/qp_avg" ;;
    esac
    case "$TCP_LINE" in
        *ph_retrans=-*)
            say "the phone's /proc/net files were unreadable to the shell; K1's fixtures carry the parser" ;;
        *) ok "the phone reported its /proc/net TCP counters" ;;
    esac
else
    bad "no steady 5 s line with a numeric tcp_srtt"
fi
if [ -n "$TCP_TOTAL" ]; then
    say "totals: $(printf '%s\n' "$TCP_TOTAL" | sed 's/^.*stats total/stats total/')"
    case "$TCP_TOTAL" in
        *tcp_ooo_kb=*tcp_srtt_max=*ph_retrans=*ph_rto=*ph_lost=*)
            ok "the totals line carries the new TCP fields" ;;
        *) bad "the totals line is missing one of the new TCP fields" ;;
    esac
    total_cq_missing=""
    for field in codec qp_avg rx_kbps; do
        case "$TCP_TOTAL" in *"$field="*) ;; *) total_cq_missing="$total_cq_missing $field" ;; esac
    done
    if [ -z "$total_cq_missing" ]; then
        ok "the totals line carries codec, qp_avg and rx_kbps: $(printf '%s\n' "$TCP_TOTAL" | grep -oE '(codec|qp_avg|rx_kbps)=[^ ]+' | tr '\n' ' ')"
    else
        bad "the totals line is missing:$total_cq_missing"
    fi
else
    bad "no closing totals line with the new TCP fields"
fi

# C1: the codec the phone actually ran, and its own lifetime line. A device
# without a usable HEVC encoder must show the one fallback line; the reviewer
# reads which condition failed.
section c1
STRATEGY_LINES="$(grep -o 'stream [0-9]* strategy: .*' "$WORK/logcat.txt" 2>/dev/null | sort -u || true)"
[ -n "$STRATEGY_LINES" ] && printf 'phone strategy: %s\n' "$(printf '%s\n' "$STRATEGY_LINES" | tr '\n' ';')"
FALLBACK_LINES="$(grep -o 'stream [0-9]* codec=hevc unsupported: [a-z]*' "$WORK/logcat.txt" 2>/dev/null | sort -u || true)"
[ -n "$FALLBACK_LINES" ] && printf 'phone fallback: %s\n' "$(printf '%s\n' "$FALLBACK_LINES" | tr '\n' ';')"
if printf '%s ' "${ARM_LIST[@]}" | grep -qw c1-hevc; then
    if printf '%s\n' "$STRATEGY_LINES" | grep -q 'codec=hevc'; then
        ok "an arm stream ran codec=hevc"
    elif [ -n "$FALLBACK_LINES" ]; then
        # WIN-59's allowed outcome: the phone names the first failing condition
        # (`encoder` here means the AVD offers no usable HEVC encoder).
        ok "no HEVC stream; the phone named its fallback: $(printf '%s\n' "$FALLBACK_LINES" | tr '\n' ';')"
    else
        bad "c1-hevc ran neither HEVC nor a fallback line"
    fi
else
    ok "no c1-hevc arm in this run"
fi
PHONE_TOTALS="$(grep -o 'stream [0-9]* totals: .*' "$WORK/logcat.txt" 2>/dev/null | sort -u || true)"
if [ -n "$PHONE_TOTALS" ]; then
    ok "the phone logged its own totals line(s)"
    printf '%s\n' "$PHONE_TOTALS" | head -4
    while IFS= read -r line; do
        case "$line" in
            *codec=*qp_avg=*) : ;;
            *) bad "a phone totals line is missing codec/qp_avg: $line" ;;
        esac
    done <<< "$PHONE_TOTALS"
else
    bad "no 'stream N totals:' line in logcat"
fi

# ISS-40's QP sample: one line per stream after its 30th output buffer. The
# emulator's encoder may report no QP; the line's presence is the proof, and
# `values=-` says the codec gave none.
QP_LINES="$(grep -o 'stream [0-9]* qp sample: .*' "$WORK/logcat.txt" 2>/dev/null || true)"
if [ -n "$QP_LINES" ]; then
    ok "the phone logged the QP sample"
    printf '%s\n' "$QP_LINES" | sort -u | head -5
    if printf '%s\n' "$QP_LINES" | grep -q 'values=[0-9]'; then
        ok "the AVD's encoder reports QP values"
    else
        say "the AVD's encoder reports no QP (values=-); the real phone is the reviewer's"
    fi
else
    bad "no 'stream N qp sample:' line in logcat"
fi

stop_app
say "artifacts: $WORK, $OUT/bench-emulator.csv"

if [ "$FAIL" -eq 0 ]; then
    say "STATS EMULATOR PASS"
else
    say "STATS EMULATOR FAIL: $FAIL"
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
