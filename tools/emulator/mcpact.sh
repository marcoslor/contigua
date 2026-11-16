#!/usr/bin/env bash
# mcpact — one boot proves MCP-81 on the real shell server (emulator, plan
# T5): digits tapped by ref with default arguments settle and observe, so no
# ui_tree call is needed between taps.
#
#   bash tools/emulator/mcpact.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/mcpact.sh
#
# Build the APK and the e2e Mac app first, in their own heavy steps.
#
# On the one boot: start.sh --no-build, pair the e2e Mac app through the real
# prompt, then over MCP: open the Clock (the pocketdeck-api36 image has no
# Calculator), reset a Stopwatch an earlier run left running, open the Timer
# keypad, read its tree once, then tap 1, 2, 3 by ref, each ref from the last
# tap's answer. Every answer must be `settled` and its tree's timer display must
# show the digits typed (pass/fail and counts only: no screen text is
# printed). Then delete the digits back to zero. Kills the emulator with
# `adb -s emulator-5554 emu kill`.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "mcpact.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_MCPACT_WORK:-/tmp/pd-mcpact-emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="${PD_MCPACT_PROFILE:-mcpact}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
APP_PID=""
TAP_PID=""
FAIL=0

ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[mcpact] %s\n' "$*"; }

wait_for() { # wait_for <seconds> <command...>
    local deadline=$(( $(date +%s) + $1 ))
    shift
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.25
    done
    return 1
}

if [ "$MODE" = check ]; then
    CHECK_FAIL=0
    cfail() { echo "MCPACT CHECK FAIL: $*"; CHECK_FAIL=1; }
    [ "$SERIAL" = "emulator-5554" ] || cfail "serial '$SERIAL' is not emulator-5554"
    bash -n "$0" || cfail "bash -n $0"
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP"
    [ -x "$SHIM" ] || cfail "no MCP shim at $SHIM"
    if [ -x "$APP" ]; then
        stale="$(find "$ROOT/macos/Sources" -type f -newer "$APP" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the Mac app is older than $stale"
    fi
    APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$APK" ] || cfail "no debug APK at $APK (build it first)"
    [ "$CHECK_FAIL" -eq 0 ] && { echo "MCPACT CHECK PASS: one boot, $SERIAL, profile $PROFILE"; exit 0; }
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/mcpact.out") 2>&1

stop_app() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
        kill -9 "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
}

cleanup() {
    local trap_rc=$?
    stop_app
    [ -n "$TAP_PID" ] && kill "$TAP_PID" 2>/dev/null || true
    "$ADB" -s "$SERIAL" forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
    # The only allowed kill: this emulator's own console.
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1 || true
    exit "$trap_rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

bring_app_forward() {
    emu shell am start -n app.contigua/.app.MainActivity >/dev/null 2>&1 || true
    local start
    start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt 60 ]; do
        if emu shell dumpsys activity activities 2>/dev/null |
            grep -Eq 'ResumedActivity:.*contigua/[^ ]*app\.MainActivity'; then
            sleep 2
            return 0
        fi
        sleep 1
    done
    return 1
}

pin_stored() {
    local pins="$SUPPORT/pins.json"
    [ -s "$pins" ] && grep -Eq '"phoneFingerprintHex" *: *"[0-9a-fA-F]{64}"' "$pins"
}

pair_mac_once() { # pair_mac_once <attempt>
    local attempt="$1"
    bring_app_forward || return 1
    "$PYTHON" "$POC" --addr "127.0.0.1:$PORT" --serial "$SERIAL" --adb "$ADB" \
        wait-prompt --timeout 90 --stale none --evidence "$WORK/pair-$attempt" \
        > "$WORK/mac-prompt-$attempt.log" 2>&1 &
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
bash "$HERE/start.sh" --no-build > "$WORK/start.log" 2>&1
if [ $? -ne 0 ]; then tail -30 "$WORK/start.log"; bad "start.sh --no-build failed"; exit 1; fi
ok "booted the real server"

rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
PAIRED=0
for attempt in 1 2; do
    if pair_mac_once "$attempt"; then PAIRED=1; break; fi
    say "pair attempt $attempt failed"
    stop_app
    sleep 3
done
[ "$PAIRED" = 1 ] && ok "the Mac app paired" || { bad "the Mac app did not pair"; exit 1; }

"$APP" --profile "$PROFILE" --background --mcp-enable \
    --connect "127.0.0.1:$PORT" --quit-after 400 > "$WORK/app.log" 2>&1 &
APP_PID=$!
wait_for 60 app_connected && ok "the Mac app is connected" || { bad "no welcome"; exit 1; }

"$PYTHON" - "$ROOT/macos/scripts/mcp" "$SHIM" "$PROFILE" "$WORK" <<'PY'
import json, re, sys, time
sys.path.insert(0, sys.argv[1])
from common import MCP
shim, profile, work = sys.argv[2:5]
fails = 0

def report(good, text):
    global fails
    print(("PASS " if good else "FAIL ") + text)
    fails += 0 if good else 1
    sys.stdout.flush()

def label(row):
    return (row.get("text") or row.get("desc") or "").strip()

def node(tree, want):
    for row in (tree or {}).get("nodes") or []:
        if row.get("ref") and not row.get("off") and want(row):
            return row
    return None

def tree_of(client, window, seconds=15):
    deadline = time.time() + seconds
    while True:
        reply = client.tool("ui_tree", {"window": window}, timeout=30)
        if not reply.get("isError"):
            return reply.get("structuredContent") or {}
        code = json.loads(reply["content"][0]["text"]).get("error", {}).get("code")
        if code != "not_ready" or time.time() > deadline:
            raise RuntimeError("ui_tree: %s" % code)
        time.sleep(1)

def display_digits(tree):
    """The digits the timer display shows, from the row that is not a key
    (a key is one digit); None when there is no such row."""
    best = None
    for row in (tree or {}).get("nodes") or []:
        text = label(row)
        digits = re.sub(r"\D", "", text)
        if len(text) <= 1 or not digits or row.get("click"):
            continue
        if re.search(r"\d+\s*h", text) or re.search(r"\d+\s*m", text):
            best = digits.lstrip("0")
            break
    return best

client = MCP(shim, profile)
try:
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "mcpact-emu", "version": "1"}}, timeout=30)
    client.notify("notifications/initialized")
    apps, deadline = [], time.time() + 60
    while time.time() < deadline and not apps:
        reply = client.tool("list_apps")
        apps = [] if reply.get("isError") else (reply.get("structuredContent") or {}).get("apps") or []
        time.sleep(0.5 if not apps else 0)
    clock = [a for a in apps if "deskclock" in a.get("package", "").lower()]
    report(bool(clock), "the phone has a Clock (%d apps)" % len(apps))
    if not clock:
        sys.exit(1)
    window = client.text("open_app", {"app": clock[0]["package"]}, timeout=60)["window"]
    time.sleep(2)
    tree = tree_of(client, window)

    # A Stopwatch an earlier run left running never settles: pause and reset it.
    tab = node(tree, lambda r: label(r).lower() == "stopwatch")
    if tab:
        tree = client.text("tap", {"window": window, "ref": tab["ref"]}).get("tree") or tree_of(client, window)
        pause = node(tree, lambda r: label(r).lower() == "pause")
        if pause:
            tree = client.text("tap", {"window": window, "ref": pause["ref"]}).get("tree") or tree_of(client, window)
        reset = node(tree, lambda r: label(r).lower() == "reset")
        if reset:
            tree = client.text("tap", {"window": window, "ref": reset["ref"]}).get("tree") or tree_of(client, window)
        print("[mcpact] stopwatch: pause=%s reset=%s" % (pause is not None, reset is not None))

    timer = node(tree, lambda r: label(r).lower() == "timer")
    report(timer is not None, "the Clock's Timer tab is in the tree by ref")
    if timer is None:
        sys.exit(1)
    answer = client.text("tap", {"window": window, "ref": timer["ref"]})
    tree = answer.get("tree") or tree_of(client, window)
    shown = display_digits(tree)
    print("[mcpact] timer display before: %s digits" % (len(shown) if shown is not None else "no"))
    digits = [(label(r), bool(r.get("click")), bool(r.get("ref")), bool(r.get("off")), r.get("role"))
              for r in (tree.get("nodes") or []) if label(r) in list("0123456789")]
    print("[mcpact] timer tap: settle=%s rows=%d tree_from_answer=%s digit_rows=%s"
          % (json.dumps(answer.get("settle")), len(tree.get("nodes") or []), "tree" in answer, digits))

    # [MCP-81] Digits by ref, default arguments, no ui_tree between taps.
    typed = ""
    reads_before = None
    for digit in "123":
        key = node(tree, lambda r: label(r) == digit and r.get("click"))
        report(key is not None, "[MCP-81] the %s key is in the last answer's tree (no ui_tree call)" % digit)
        if key is None:
            break
        started = time.time()
        answer = client.text("tap", {"window": window, "ref": key["ref"]}, timeout=30)
        elapsed = time.time() - started
        typed += digit
        settle = answer.get("settle") or {}
        tree = answer.get("tree")
        shown = display_digits(tree)
        report("ok" not in answer and settle.get("state") == "settled",
               "[MCP-81] tap %s by ref settles: %s in %.2f s" % (digit, json.dumps(settle), elapsed))
        report(tree is not None and shown is not None and shown.endswith(typed),
               "[MCP-82] tap %s's tree shows the digits typed (display matches: %s)"
               % (digit, shown is not None and shown.endswith(typed)))
        report((answer.get("did") or {}).get("node", {}).get("text") == digit,
               "[MCP-108] tap %s names the node it pressed" % digit)

    # Clear the timer: delete back to zero.
    for _ in range(len(typed) + 2):
        delete = node(tree, lambda r: label(r).lower() in ("delete", "backspace", "del"))
        if delete is None:
            break
        tree = client.text("tap", {"window": window, "ref": delete["ref"]}).get("tree") or tree_of(client, window)
    shown = display_digits(tree)
    report(not shown, "the timer is cleared back to zero (%s)" % ("zero" if not shown else "digits left"))
finally:
    client.close()
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
stop_app
[ "$FAIL" -eq 0 ] && say "MCPACT EMULATOR PASS" || say "MCPACT EMULATOR FAIL: $FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
