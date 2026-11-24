#!/usr/bin/env bash
# mcprefs — one boot proves T10 on the real shell server (emulator): a ref is
# the phone's key, a ref from one read still presses after a second read, and
# a ref whose node is gone presses nothing (MCP-71, MCP-86, MCP-108).
#
#   bash tools/emulator/mcprefs.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/mcprefs.sh
#
# Build the APK and the e2e Mac app first, in their own heavy steps.
#
# On the one boot: start.sh --no-build, pair the e2e Mac app through the real
# prompt, then over MCP: open the Clock on its Alarm tab, read the tree twice,
# tap the Timer tab by its ref from the first read (the keypad must show), take
# the keypad's 1 by ref, go back to Alarm, and tap that 1: it must fail
# stale_ref and the Alarm tab must stay (pass/fail and counts only: no screen
# text is printed). Kills the emulator with `adb -s emulator-5554 emu kill`.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "mcprefs.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_MCPREFS_WORK:-/tmp/pd-mcprefs-emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="${PD_MCPREFS_PROFILE:-mcprefs}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
APP_PID=""
TAP_PID=""
FAIL=0

ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[mcprefs] %s\n' "$*"; }

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
    cfail() { echo "MCPREFS CHECK FAIL: $*"; CHECK_FAIL=1; }
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
    [ "$CHECK_FAIL" -eq 0 ] && { echo "MCPREFS CHECK PASS: one boot, $SERIAL, profile $PROFILE"; exit 0; }
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/mcprefs.out") 2>&1

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
# #218: a fresh run starts from no remembered phone: the profile's defaults
# (its clientId, remembered phone and cached address) go with its keys.
defaults delete "app.contigua.mac.$PROFILE" >/dev/null 2>&1 || true
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

def tree_of(client, window, seconds=15, wait=None):
    deadline = time.time() + seconds
    while True:
        arguments = {"window": window}
        if wait:
            arguments["wait"] = wait
        reply = client.tool("ui_tree", arguments, timeout=30)
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

def code_of(reply):
    if not reply.get("isError"):
        return None
    try:
        return json.loads(reply["content"][0]["text"]).get("error", {}).get("code")
    except (KeyError, IndexError, ValueError):
        return "unparsed"

def keypad(tree):
    return node(tree, lambda r: label(r) == "1" and r.get("click"))

client = MCP(shim, profile)
try:
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "mcprefs-emu", "version": "1"}}, timeout=30)
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

    # Start on the Alarm tab. The first read settles the opening window, as an
    # agent would (#180: a read while it opens can time out; that is not retried).
    tree = tree_of(client, window, wait="settle")
    alarm = node(tree, lambda r: label(r).lower() == "alarm")
    if alarm:
        tree = client.text("tap", {"window": window, "ref": alarm["ref"]}).get("tree") or tree_of(client, window)

    # [MCP-71] Refs are keys, with no snapshot in them.
    first = tree_of(client, window)
    refs = [r.get("ref") for r in first.get("nodes") or [] if r.get("ref")]
    report(bool(refs) and all(re.match(r"^e\d+$", ref) for ref in refs),
           "[MCP-71] every ref is e<k> (%d refs)" % len(refs))
    timer = node(first, lambda r: label(r).lower() == "timer")
    report(timer is not None, "the Timer tab is in read 1")
    if timer is None:
        sys.exit(1)

    # [MCP-86] A ref from read 1 still presses after read 2.
    second = tree_of(client, window)
    report(second.get("snapshot", 0) > first.get("snapshot", 0),
           "read 2 is a newer snapshot (%s > %s)" % (second.get("snapshot"), first.get("snapshot")))
    answer = client.tool("tap", {"window": window, "ref": timer["ref"]}, timeout=30)
    body = answer.get("structuredContent") or {}
    tree = body.get("tree") or tree_of(client, window)
    report(not answer.get("isError") and keypad(tree) is not None,
           "[MCP-86] the Timer ref from read 1 presses after read 2 (the keypad shows)")
    did = body.get("did") or {}
    report(did.get("ref") == timer["ref"] and len(did.get("box") or []) == 4
           and (did.get("node") or {}).get("role") is not None,
           "[MCP-108] the answer names the node and box the phone pressed")

    # [MCP-86] A ref whose node is gone presses nothing.
    one = keypad(tree)
    alarm = node(tree, lambda r: label(r).lower() == "alarm")
    report(one is not None and alarm is not None, "the keypad's 1 and the Alarm tab are by ref")
    if one is None or alarm is None:
        sys.exit(1)
    tree = client.text("tap", {"window": window, "ref": alarm["ref"]}).get("tree") or tree_of(client, window)
    report(keypad(tree) is None, "the Alarm tab shows: the keypad is gone")
    refused = client.tool("tap", {"window": window, "ref": one["ref"]}, timeout=30)
    code = code_of(refused)
    after = tree_of(client, window)
    report(code == "stale_ref" and keypad(after) is None,
           "[MCP-86] the gone keypad ref fails %s and presses nothing (the Alarm tab stays)" % code)
finally:
    client.close()
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
stop_app
[ "$FAIL" -eq 0 ] && say "MCPREFS EMULATOR PASS" || say "MCPREFS EMULATOR FAIL: $FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
