#!/usr/bin/env bash
# mcpopen — one boot proves T6 on the real shell server (emulator): through
# the MCP, open_app of the Calculator (the Clock when the image has none)
# answers opened new, a settled settle and a tree showing its screen; a second
# open_app answers opened raised; send_link https://example.com answers its
# window, listed by list_windows with kind link (MCP-41, MCP-43).
#
#   bash tools/emulator/mcpopen.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/mcpopen.sh
#
# Build the APK and the e2e Mac app first, in their own heavy steps. Pairs
# through the real prompt as mcpact.sh does; never opens Settings, accounts
# or messages. Pass/fail and counts only: no screen text is printed. Kills the
# emulator with `adb -s emulator-5554 emu kill`.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "mcpopen.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_MCPOPEN_WORK:-/tmp/pd-mcpopen-emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="${PD_MCPOPEN_PROFILE:-mcpopen}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
APP_PID=""
TAP_PID=""
FAIL=0

ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[mcpopen] %s\n' "$*"; }

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
    cfail() { echo "MCPOPEN CHECK FAIL: $*"; CHECK_FAIL=1; }
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
    [ "$CHECK_FAIL" -eq 0 ] && { echo "MCPOPEN CHECK PASS: one boot, $SERIAL, profile $PROFILE"; exit 0; }
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/mcpopen.out") 2>&1

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

"$PYTHON" - "$ROOT/macos/scripts/mcp" "$SHIM" "$PROFILE" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
from common import MCP
shim, profile = sys.argv[2:4]
fails = 0

def report(good, text):
    global fails
    print(("PASS " if good else "FAIL ") + text)
    fails += 0 if good else 1
    sys.stdout.flush()

client = MCP(shim, profile)
try:
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "mcpopen-emu", "version": "1"}}, timeout=30)
    client.notify("notifications/initialized")
    apps, deadline = [], time.time() + 60
    while time.time() < deadline and not apps:
        reply = client.tool("list_apps")
        apps = [] if reply.get("isError") else (reply.get("structuredContent") or {}).get("apps") or []
        time.sleep(0.5 if not apps else 0)
    pick = [a for a in apps if "calculator" in a.get("package", "").lower()]
    if not pick:
        pick = [a for a in apps if "deskclock" in a.get("package", "").lower()]
        print("[mcpopen] no Calculator on this image: using the Clock")
    report(bool(pick), "the phone has the app to open (%d apps)" % len(apps))
    if not pick:
        sys.exit(1)
    package = pick[0]["package"]

    started = time.time()
    reply = client.tool("open_app", {"app": package}, timeout=60)
    took = time.time() - started
    body = reply.get("structuredContent") or {}
    settle = body.get("settle") or {}
    nodes = [r for r in (body.get("tree") or {}).get("nodes") or [] if not r.get("off")]
    labelled = [r for r in nodes if (r.get("text") or r.get("desc"))]
    report(not reply.get("isError") and body.get("opened") == "new" and body.get("openedBy") == "you",
           "[MCP-41] open_app answers opened new by you (window %s, %.1f s)" % (body.get("window"), took))
    report(settle.get("state") == "settled",
           "[MCP-41] its settle is settled (%s, waitedMs %s)" % (settle.get("state"), settle.get("waitedMs")))
    report(len(labelled) > 0 and body.get("state") == "live",
           "[MCP-41] its tree shows the app's screen (%d rows, %d labelled, state %s, size %s)"
           % (len(nodes), len(labelled), body.get("state"), body.get("size")))
    window = body.get("window")

    again = client.tool("open_app", {"app": package}, timeout=60)
    body2 = again.get("structuredContent") or {}
    report(not again.get("isError") and body2.get("opened") == "raised" and body2.get("window") == window,
           "[MCP-41] a second open_app answers opened raised on window %s" % body2.get("window"))

    link = client.tool("send_link", {"url": "https://example.com"}, timeout=60)
    body3 = link.get("structuredContent") or {}
    link_window = body3.get("window")
    rows = (client.text("list_windows").get("windows") or [])
    row = [r for r in rows if r.get("id") == link_window]
    report(not link.get("isError") and isinstance(link_window, int) and body3.get("kind") == "link"
           and bool(row) and row[0].get("kind") == "link",
           "[MCP-43] send_link answers window %s and list_windows has it with kind link (settle %s)"
           % (link_window, (body3.get("settle") or {}).get("state")))
    for w in (link_window, window):
        if isinstance(w, int):
            client.tool("close_window", {"window": w})
finally:
    client.close()
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
stop_app
[ "$FAIL" -eq 0 ] && say "MCPOPEN EMULATOR PASS" || say "MCPOPEN EMULATOR FAIL: $FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
