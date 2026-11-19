#!/usr/bin/env bash
# mcpshape — one boot proves T12 on the real shell server (emulator): an app
# an agent opens through the MCP (the Clock, else Files) with no `shape` gets a
# portrait `window.open` (the phone's own display list has a portrait virtual
# display at the answer's size) and a portrait tree root `size` (MCP-100).
# The `shape: "window"` half is `suite_shape.py`'s fake-phone test, so this
# proof does not need the close-and-reopen path (#183).
#
#   bash tools/emulator/mcpshape.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/mcpshape.sh
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
        *) echo "mcpshape.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_MCPSHAPE_WORK:-/tmp/pd-mcpshape-emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="${PD_MCPSHAPE_PROFILE:-mcpshape}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
APP_PID=""
TAP_PID=""
FAIL=0

ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[mcpshape] %s\n' "$*"; }

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
    cfail() { echo "MCPSHAPE CHECK FAIL: $*"; CHECK_FAIL=1; }
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
    [ "$CHECK_FAIL" -eq 0 ] && { echo "MCPSHAPE CHECK PASS: one boot, $SERIAL, profile $PROFILE"; exit 0; }
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/mcpshape.out") 2>&1

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

"$PYTHON" - "$ROOT/macos/scripts/mcp" "$SHIM" "$PROFILE" "$WORK/sizes" "$ADB" "$SERIAL" <<'PY'
import re, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from common import MCP
shim, profile, sizes, adb, serial = sys.argv[2:7]
assert serial.startswith("emulator-"), serial
fails = 0

def report(good, text):
    global fails
    print(("PASS " if good else "FAIL ") + text)
    fails += 0 if good else 1
    sys.stdout.flush()

client = MCP(shim, profile)
try:
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "mcpshape-emu", "version": "1"}}, timeout=30)
    client.notify("notifications/initialized")
    apps, deadline = [], time.time() + 60
    while time.time() < deadline and not apps:
        reply = client.tool("list_apps")
        apps = [] if reply.get("isError") else (reply.get("structuredContent") or {}).get("apps") or []
        time.sleep(0.5 if not apps else 0)
    pick = [a for a in apps if "deskclock" in a.get("package", "").lower()]
    if not pick:
        pick = [a for a in apps if "documentsui" in a.get("package", "").lower()
                or a.get("package", "").endswith(".files")]
        print("[mcpshape] no Clock on this image: using Files")
    report(bool(pick), "the phone has the app to open (%d apps)" % len(apps))
    if not pick:
        sys.exit(1)
    package = pick[0]["package"]

    reply = client.tool("open_app", {"app": package}, timeout=60)
    body = reply.get("structuredContent") or {}
    size = body.get("size") or [0, 0]
    window = body.get("window")
    tree = body.get("tree") or {}
    if not tree.get("size") and isinstance(window, int):
        # The first read of a freshly opened window can spend the open's whole
        # bound (#180), and the open answers treeError. The acceptance here is
        # the tree's root size, so read once more instead of treating the
        # first read's deadline as the shape's verdict.
        time.sleep(1)
        again = client.tool("ui_tree", {"window": window}, timeout=30)
        tree = again.get("structuredContent") or {}
    root = tree.get("size") or [0, 0]
    report(not reply.get("isError") and body.get("opened") == "new"
           and size[1] > size[0] > 0 and max(size) <= 1280,
           "[MCP-100] open_app with no shape answers a portrait stream at most 1280 px (size %s)" % size)
    report(root[1] > root[0] > 0,
           "[MCP-100] its tree root size is portrait (%s, treeError %r)"
           % (root, body.get("treeError")))
    with open(sizes, "w") as handle:
        handle.write("phone %d %d\n" % tuple(size))
    if isinstance(window, int):
        # The phone side: a virtual display the Mac's window.open asked for.
        # Sizes only; no display name is printed.
        listing = subprocess.run([adb, "-s", serial, "shell", "dumpsys", "display"],
                                 capture_output=True, text=True, timeout=30).stdout
        found = set((int(a), int(b)) for a, b in re.findall(r"(\d+) x (\d+)", listing))
        report((size[0], size[1]) in found,
               "[MCP-100] the phone has a portrait virtual display at %dx%d (window.open's size)"
               % (size[0], size[1]))
        client.tool("close_window", {"window": window})
finally:
    client.close()
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
stop_app
[ "$FAIL" -eq 0 ] && say "MCPSHAPE EMULATOR PASS" || say "MCPSHAPE EMULATOR FAIL: $FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
