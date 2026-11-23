#!/usr/bin/env bash
# mcptype — one boot proves T13 on the real shell server (emulator): the
# `type_text` tool goes through the Mac as `ui.type` and the phone types into
# a real EditText without the clipboard (MCP-92, MCP-109, MCP-110).
#
#   bash tools/emulator/mcptype.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/mcptype.sh
#
# Build the APK and the e2e Mac app first, in their own heavy steps.
#
# On the one boot: start.sh --no-build, pair the e2e Mac app through the real
# prompt, open the Phone Mirror, start Contacts' new-contact editor on display
# 0 (nothing is ever saved), then over MCP: tap its first field by ref, type
# key-map text with clear (replaced), "térmica " (set_text, inserted, the field
# keeps what was there), one key after it (keys); then Back out of the editor
# and take its Discard. Output is codes, counts and match booleans only: no
# screen text is printed. Kills the emulator with `adb -s emulator-5554 emu kill`.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "mcptype.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_MCPTYPE_WORK:-/tmp/pd-mcptype-emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="${PD_MCPTYPE_PROFILE:-mcptypetext}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
APP_PID=""
TAP_PID=""
FAIL=0

ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[mcptype] %s\n' "$*"; }

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
    cfail() { echo "MCPTYPE CHECK FAIL: $*"; CHECK_FAIL=1; }
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
    [ "$CHECK_FAIL" -eq 0 ] && { echo "MCPTYPE CHECK PASS: one boot, $SERIAL, profile $PROFILE"; exit 0; }
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/mcptype.out") 2>&1

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
    --open-phone --connect "127.0.0.1:$PORT" --quit-after 400 > "$WORK/app.log" 2>&1 &
APP_PID=$!
wait_for 60 app_connected && ok "the Mac app is connected" || { bad "no welcome"; exit 1; }

"$PYTHON" - "$ROOT/macos/scripts/mcp" "$SHIM" "$PROFILE" "$ADB" "$SERIAL" <<'PY'
import json, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from common import MCP
shim, profile, adb, serial = sys.argv[2:6]
fails = 0

def report(good, text):
    global fails
    print(("PASS " if good else "FAIL ") + text)
    fails += 0 if good else 1
    sys.stdout.flush()

def shell(*argv):
    # Only this emulator: every other serial is the person's phone.
    assert serial.startswith("emulator-")
    subprocess.run([adb, "-s", serial, "shell"] + list(argv), timeout=60,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def code_of(reply):
    if not reply.get("isError"):
        return None
    try:
        return json.loads(reply["content"][0]["text"]).get("error", {}).get("code")
    except (KeyError, IndexError, ValueError):
        return "unparsed"

def tree_of(client, window):
    reply = client.tool("ui_tree", {"window": window, "wait": "settle"}, timeout=30)
    return {} if reply.get("isError") else reply.get("structuredContent") or {}

def until(fn, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = fn()
        if value is not None:
            return value
        time.sleep(1)
    return None

def field(tree, ref=None):
    for row in tree.get("nodes") or []:
        if row.get("ref") and not row.get("off") and row.get("edit") and not row.get("pwd") \
                and (ref is None or row.get("ref") == ref):
            return row
    return None

def text_of(row):
    return "" if row is None or row.get("hint") else row.get("text") or ""

def typed(client, window, text, **flags):
    arguments = {"window": window, "text": text, "observe": "tree"}
    arguments.update(flags)
    reply = client.tool("type_text", arguments, timeout=30)
    body = reply.get("structuredContent") or {}
    return code_of(reply), body.get("did") or {}, body.get("tree") or {}

client = MCP(shim, profile)
mirror = None
try:
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "mcptype-emu", "version": "1"}}, timeout=30)
    client.notify("notifications/initialized")
    mirror = until(lambda: next((row["id"] for row in client.text("list_windows").get("windows") or []
                                 if row.get("package") is None and row.get("state") == "live"), None), 60)
    report(mirror is not None, "the Phone Mirror is live")
    if mirror is None:
        sys.exit(1)

    shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.INSERT",
          "-t", "vnd.android.cursor.dir/contact")
    edit = until(lambda: field(tree_of(client, mirror)), 25)
    report(edit is not None, "the contact editor shows a field")
    if edit is None:
        sys.exit(1)
    ref = edit["ref"]
    tap = client.tool("tap", {"window": mirror, "ref": ref}, timeout=30)
    report(code_of(tap) is None, "the field is tapped by ref (%s)" % code_of(tap))

    # [MCP-92] [MCP-109] Key-map text with clear: the field holds it alone.
    first = "garrafa 500ml"
    code, did, tree = typed(client, mirror, first, clear=True)
    report(code is None and did.get("action") == "type" and did.get("characters") == len(first)
           and did.get("clear") is True and did.get("entry") == "replaced",
           "[MCP-92] clear replaces the field (code %s, entry %s, via %s)"
           % (code, did.get("entry"), did.get("via")))
    report(text_of(field(tree, ref)) == first, "[MCP-109] the field holds the cleared text (match)")

    # [MCP-109] Text outside the key map goes whole by set text, at the end
    # (no cursor move here), and what was there stays.
    code, did, tree = typed(client, mirror, " térmica")
    report(code is None and did.get("via") == "set_text" and did.get("entry") == "inserted"
           and did.get("characters") == 8,
           "[MCP-109] \"térmica\" is set text, inserted (code %s, entry %s, via %s)"
           % (code, did.get("entry"), did.get("via")))
    report(text_of(field(tree, ref)) == first + " térmica",
           "[MCP-109] the field keeps its text and has the typed text after it (match)")

    # [MCP-109] A key typed next lands after it: the cursor moved past it.
    code, did, tree = typed(client, mirror, "x")
    report(code is None and did.get("via") == "keys" and did.get("entry") == "inserted",
           "[MCP-109] one key after it goes as keys (code %s, via %s)" % (code, did.get("via")))
    report(text_of(field(tree, ref)) == first + " térmicax", "[MCP-109] the key landed after the set text (match)")
finally:
    # Leave the editor without saving: Back (keyboard), Back (editor), Discard.
    try:
        for _ in range(2 if mirror is not None else 0):
            client.tool("press_key", {"window": mirror, "key": "back"}, timeout=30)
            tree = tree_of(client, mirror)
            discard = next((row for row in tree.get("nodes") or [] if row.get("ref") and row.get("click")
                            and (row.get("text") or "").strip().lower() == "discard"), None)
            if discard:
                client.tool("tap", {"window": mirror, "ref": discard["ref"]}, timeout=30)
                print("INFO the editor was discarded")
                break
    except Exception as error:  # noqa: BLE001 - the run's result stands
        print("INFO leaving the editor: %s" % type(error).__name__)
    client.close()
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
stop_app
[ "$FAIL" -eq 0 ] && say "MCPTYPE EMULATOR PASS" || say "MCPTYPE EMULATOR FAIL: $FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
