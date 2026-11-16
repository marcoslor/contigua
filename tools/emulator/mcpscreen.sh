#!/usr/bin/env bash
# mcpscreen — one boot proves MCP-60 on the real shell server (emulator): a
# covered window's screenshot is a frame from after the call.
#
#   bash tools/emulator/mcpscreen.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/mcpscreen.sh
#
# Build the APK and the e2e Mac app first, in their own heavy steps.
#
# On the one boot: start.sh --no-build, pair the e2e Mac app through the real
# prompt, then over MCP: open Calculator (else the Clock's Timer keypad), open Settings over it, wait out the
# agent hold (the covered window pauses), tap 7 by ref and screenshot. The
# decoded frame is checked with Vision text recognition for a 7 in the
# display's upper part (pass/fail and counts only: no text is printed), and
# `frame.ageMs < 1000`. Kills the emulator with `adb -s emulator-5554 emu kill`.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "mcpscreen.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_MCPSCREEN_WORK:-/tmp/pd-mcpscreen-emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="${PD_MCPSCREEN_PROFILE:-mcpscreen}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
APP_PID=""
TAP_PID=""
FAIL=0

ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[mcpscreen] %s\n' "$*"; }

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
    cfail() { echo "MCPSCREEN CHECK FAIL: $*"; CHECK_FAIL=1; }
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
    command -v swift >/dev/null || cfail "no swift for the text check"
    [ "$CHECK_FAIL" -eq 0 ] && { echo "MCPSCREEN CHECK PASS: one boot, $SERIAL, profile $PROFILE"; exit 0; }
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/mcpscreen.out") 2>&1

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

# The decoded-frame check: Vision text recognition on the PNG. Prints counts
# only: observations, and those holding a 7 in the image's upper 40 %.
cat > "$WORK/sevens.swift" <<'SWIFT'
import Foundation
import Vision
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(url: url).perform([request])
let observations = request.results ?? []
var upper = 0
for observation in observations {
    guard let best = observation.topCandidates(1).first, best.string.contains("7") else { continue }
    // Vision's origin is bottom-left: the upper 40 % is midY > 0.6.
    if observation.boundingBox.midY > 0.6 { upper += 1 }
}
print("observations=\(observations.count) sevens_upper=\(upper)")
SWIFT

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
import base64, json, os, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from common import MCP
shim, profile, work = sys.argv[2:5]
fails = 0

def report(good, text):
    global fails
    print(("PASS " if good else "FAIL ") + text)
    fails += 0 if good else 1
    sys.stdout.flush()

def shot(client, window, name, ref=None):
    args = {"window": window}
    if ref:
        args["ref"] = ref
    for _ in range(20):
        reply = client.tool("screenshot", args, timeout=30)
        if not reply.get("isError"):
            path = os.path.join(work, name + ".png")
            with open(path, "wb") as handle:
                handle.write(base64.b64decode(reply["content"][0]["data"]))
            return reply.get("structuredContent") or {}, path
        code = json.loads(reply["content"][0]["text"]).get("code")
        print("[mcpscreen] screenshot %s: %s" % (name, code))
        time.sleep(0.5)
    raise RuntimeError("no screenshot for " + name)

def sevens(path):
    out = subprocess.run(["swift", os.path.join(work, "sevens.swift"), path],
                         capture_output=True, text=True, timeout=300).stdout.strip()
    print("[mcpscreen] text check %s: %s" % (os.path.basename(path), out))
    for part in out.split():
        if part.startswith("sevens_upper="):
            return int(part.split("=")[1])
    return -1

def node(tree, want):
    for row in tree.get("nodes") or []:
        if row.get("ref") and not row.get("off") and want(row):
            return row
    return None

def tree_of(client, window, seconds=15):
    """ui_tree, waiting out not_ready (a display with nothing to read yet, MCP-70)."""
    deadline = time.time() + seconds
    while True:
        reply = client.tool("ui_tree", {"window": window}, timeout=30)
        if not reply.get("isError"):
            return reply.get("structuredContent") or {}
        code = json.loads(reply["content"][0]["text"]).get("error", {}).get("code")
        if code != "not_ready" or time.time() > deadline:
            raise RuntimeError("ui_tree: %s" % code)
        print("[mcpscreen] ui_tree: not_ready, again")
        time.sleep(1)

client = MCP(shim, profile)
try:
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "mcpscreen-emu", "version": "1"}}, timeout=30)
    client.notify("notifications/initialized")
    apps = []
    deadline = time.time() + 60
    while time.time() < deadline and not apps:
        reply = client.tool("list_apps")
        apps = [] if reply.get("isError") else (reply.get("structuredContent") or {}).get("apps") or []
        time.sleep(0.5 if not apps else 0)
    # A keypad whose 7 shows near the top of the window: the Calculator, else
    # the Clock's Timer (its display reads 00h 00m 07s after a 7). The
    # pocketdeck-api36 image ships no Calculator.
    calc = [a for a in apps if "calculator" in a.get("package", "").lower()]
    clock = [a for a in apps if "deskclock" in a.get("package", "").lower()]
    target = calc or clock
    report(bool(target), "the phone has a Calculator or a Clock (%d apps: calculator %d, clock %d)"
           % (len(apps), len(calc), len(clock)))
    if not target:
        sys.exit(1)
    calc_window = client.text("open_app", {"app": target[0]["package"]}, timeout=60)["window"]
    if not calc:
        time.sleep(2)
        tree = tree_of(client, calc_window)
        tab = node(tree, lambda r: (r.get("text") or r.get("desc") or "").strip().lower() == "timer")
        report(tab is not None, "the Clock's Timer tab is in the tree by ref")
        if tab is None:
            sys.exit(1)
        client.text("tap", {"window": calc_window, "ref": tab["ref"]})
        time.sleep(1.5)
    print("[mcpscreen] keypad app: %s" % ("calculator" if calc else "clock timer"))
    first, path0 = shot(client, calc_window, "before")
    before = sevens(path0)
    tree = tree_of(client, calc_window)
    clear = node(tree, lambda r: (r.get("desc") or r.get("text") or "").lower() in ("clear", "ac", "c", "delete"))
    if before > 0 and clear:
        for _ in range(8):
            client.text("tap", {"window": calc_window, "ref": clear["ref"]})
        time.sleep(0.5)
    client.text("open_app", {"app": "com.android.settings"}, timeout=60)
    # The agent hold keeps a window live for 15 s after a call; outwait it so
    # the covered window pauses by WIN's rule.
    time.sleep(17)
    rows = [w for w in client.text("list_windows")["windows"] if w["id"] == calc_window]
    covered_state = rows[0]["state"] if rows else None
    print("[mcpscreen] Calculator window before the tap: state=%s" % covered_state)
    tree = tree_of(client, calc_window)
    seven = node(tree, lambda r: (r.get("text") or r.get("desc") or "").strip() == "7")
    report(seven is not None, "ui_tree names the 7 key by ref (%d rows)" % len(tree.get("nodes") or []))
    if seven is None:
        sys.exit(1)
    tapped = client.text("tap", {"window": calc_window, "ref": seven["ref"]})
    # MCP-80: the act envelope has no `ok`; `did` names the press, `state` the window.
    report("ok" not in tapped and "did" in tapped and "state" in tapped,
           "the tap by ref answers the act envelope with state=%s settle=%s"
           % (tapped.get("state"), (tapped.get("settle") or {}).get("state")))
    time.sleep(0.7)
    after, path1 = shot(client, calc_window, "after")
    frame = after.get("frame") or {}
    print("[mcpscreen] screenshot after: state=%s seq=%s ageMs=%s image=%s size=%s blank=%s"
          % (after.get("state"), frame.get("seq"), frame.get("ageMs"), after.get("image"),
             after.get("size"), after.get("blank", False)))
    report(isinstance(frame.get("seq"), int) and frame["seq"] > (first.get("frame") or {}).get("seq", 0),
           "the second screenshot is a later frame")
    report(isinstance(frame.get("ageMs"), int) and frame["ageMs"] < 1000,
           "[MCP-60] frame.ageMs < 1000 (%s)" % frame.get("ageMs"))
    now = sevens(path1)
    report(now > 0 and (before == 0 or clear is not None),
           "[MCP-60] decoded-frame check: the covered window's screenshot shows the 7 the tap typed "
           "(sevens in the display: before=%d after=%d)" % (before, now))
finally:
    client.close()
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
stop_app
[ "$FAIL" -eq 0 ] && say "MCPSCREEN EMULATOR PASS" || say "MCPSCREEN EMULATOR FAIL: $FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
