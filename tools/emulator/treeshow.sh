#!/usr/bin/env bash
# treeshow — one boot proves B6 on the real shell server (emulator): the tree
# says what it does not show (MCP-104, MCP-105, MCP-106, and MCP-86's label).
#
#   bash tools/emulator/treeshow.sh --check    # rehearse: no device, no boot
#   timeout 2700 bash tools/emulator/treeshow.sh
#
# Build the APK and the e2e Mac app first, in their own heavy steps.
#
# On the one boot: start.sh --no-build, pair the e2e Mac app through the real
# prompt, open the phone mirror (display 0: an app window never shows a soft
# keyboard, WIN-51), then over MCP on the mirror's tree:
#  1. Contacts (started on display 0 by `am start`), its search tapped by ref:
#     the empty search field is `hint: true` with no `text` (MCP-104); with the
#     keyboard up the IME layer is not `active` and the one `focus` row is the
#     app's field, in the active layer (MCP-105).
#  2. Contacts' new-contact editor (a long scrolling form; nothing is saved):
#     a scrollable carries `hidden`, the reply's `omitted` equals the hidden
#     rows, no `off` row is sent (MCP-106); a tap by ref on one of its rows
#     still presses, and the phone logged `expect=yes` (MCP-86).
# Pass/fail and counts only: no screen text is printed. Never unlocks: a
# keyguard showing fails the run. Kills the emulator with
# `adb -s emulator-5554 emu kill`.
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "treeshow.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_TREESHOW_WORK:-/tmp/pd-treeshow-emu}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
POC="$ROOT/tools/emulator/poc.py"
PROFILE="${PD_TREESHOW_PROFILE:-treeshow}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
APP_PID=""
TAP_PID=""
LOGCAT_PID=""
FAIL=0

ok() { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[treeshow] %s\n' "$*"; }

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
    cfail() { echo "TREESHOW CHECK FAIL: $*"; CHECK_FAIL=1; }
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
    [ "$CHECK_FAIL" -eq 0 ] && { echo "TREESHOW CHECK PASS: one boot, $SERIAL, profile $PROFILE"; exit 0; }
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
exec > >(tee "$WORK/treeshow.out") 2>&1

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
    # The phone's ui.* lines (codes, counts and durations only), kept before
    # the emulator goes: a failed call is explained by its settle and read times.
    if [ -n "$LOGCAT_PID" ]; then
        kill "$LOGCAT_PID" 2>/dev/null || true
        grep -E "ContiguaSvc: ui\.(tree|settle|press)" "$WORK/phone.log" > "$WORK/phone-ui.log" 2>/dev/null || true
        say "phone ui.* lines (also in $WORK/phone-ui.log):"
        sed -E 's/^ *([0-9.]+) .*ContiguaSvc: /  \1 /' "$WORK/phone-ui.log" | tail -20
    fi
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
    --connect "127.0.0.1:$PORT" --open-phone --quit-after 500 > "$WORK/app.log" 2>&1 &
APP_PID=$!
wait_for 60 app_connected && ok "the Mac app is connected" || { bad "no welcome"; exit 1; }

# Never unlock: a keyguard showing ends the run here.
if emu shell dumpsys window 2>/dev/null | grep -Eq 'mDreamingLockscreen=true|isKeyguardShowing=true|mShowingLockscreen=true'; then
    bad "the emulator shows a keyguard; this run never unlocks it"; exit 1
fi
# The pairing's prompt taps read the screen with `uiautomator dump`; one that
# outlived its adb call still holds the platform's one UiAutomation, and the
# phone's own connect then fails (ui.tree no_a11y). Wait for it to exit.
uiautomator_gone() { ! emu shell ps -A -o ARGS 2>/dev/null | grep -q '[u]iautomator'; }
if ! uiautomator_gone; then
    say "a uiautomator dump is still running; waiting for it to exit"
    wait_for 60 uiautomator_gone || { bad "a uiautomator dump still holds the accessibility connection"; exit 1; }
fi
emu logcat -c >/dev/null 2>&1 || true
"$ADB" -s "$SERIAL" logcat -v monotonic -s ContiguaSvc:I > "$WORK/phone.log" 2>&1 &
LOGCAT_PID=$!

"$PYTHON" - "$ROOT/macos/scripts/mcp" "$SHIM" "$PROFILE" "$WORK" "$ADB" "$SERIAL" <<'PY'
import json, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from common import MCP
shim, profile, work, adb, serial = sys.argv[2:7]
fails = 0

def report(good, text):
    global fails
    print(("PASS " if good else "FAIL ") + text)
    fails += 0 if good else 1
    sys.stdout.flush()

def shell(*args):
    """adb on this emulator only (`-s`), never another serial."""
    return subprocess.run([adb, "-s", serial, "shell"] + list(args), capture_output=True,
                          text=True, timeout=30).stdout

def label(row):
    return (row.get("text") or row.get("desc") or "").strip()

def rows(tree):
    return (tree or {}).get("nodes") or []

def tree_of(client, window, wait=None, seconds=20):
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

def until(client, window, test, seconds=10):
    deadline = time.time() + seconds
    tree = tree_of(client, window)
    while not test(tree) and time.time() < deadline:
        time.sleep(0.5)
        tree = tree_of(client, window)
    return tree

def resumed():
    """The resumed activity's package on display 0 (a package name, never screen text)."""
    for line in shell("dumpsys", "activity", "activities").splitlines():
        if "ResumedActivity" in line and "/" in line:
            return line.split("/")[0].split()[-1]
    return "?"

def evidence(name, tree):
    """Each row's shape for the evidence folder: role, id, flags, label length; no text."""
    with open("%s/%s.jsonl" % (work, name), "w") as out:
        for r in rows(tree):
            out.write(json.dumps({k: r.get(k) for k in ("i", "p", "l", "role", "id", "click", "edit",
                                                        "scroll", "hint", "focus", "hidden", "off")}
                                 | {"label": len(label(r))}) + "\n")
        out.write(json.dumps({"layers": tree.get("layers"), "omitted": tree.get("omitted")}) + "\n")

def search_of(tree):
    return next((r for r in rows(tree) if r.get("ref") and r.get("at") and not r.get("edit")
                 and ("search" in label(r).lower() or "search" in (r.get("id") or "").lower())), None)

client = MCP(shim, profile)
try:
    client.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "treeshow-emu", "version": "1"}}, timeout=30)
    client.notify("notifications/initialized")
    mirror, deadline = None, time.time() + 60
    while mirror is None and time.time() < deadline:
        reply = client.tool("list_windows")
        windows = [] if reply.get("isError") else (reply.get("structuredContent") or {}).get("windows") or []
        # The phone mirror is the window with no package.
        mirror = next((w["id"] for w in windows if w.get("package") is None), None)
        time.sleep(0.5 if mirror is None else 0)
    report(mirror is not None, "the phone mirror is open (%d windows)" % len(windows))
    if mirror is None:
        sys.exit(1)

    # 1. Contacts on display 0, its search field.
    shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.MAIN",
          "-c", "android.intent.category.APP_CONTACTS")
    tree = tree_of(client, mirror, wait="settle")
    evidence("contacts", tree)
    search = search_of(tree)
    print("  contacts: resumed %s, %d rows, search %s" % (resumed(), len(rows(tree)), search is not None))
    if search is None:
        # The Files picker's search, when Contacts shows none (a first-run screen
        # is left alone: never an account step).
        shell("input", "keyevent", "KEYCODE_BACK")
        shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.OPEN_DOCUMENT",
              "-c", "android.intent.category.OPENABLE", "-t", "*/*")
        tree = tree_of(client, mirror, wait="settle")
        evidence("files", tree)
        search = search_of(tree)
        print("  files: resumed %s, %d rows, search %s" % (resumed(), len(rows(tree)), search is not None))
    report(search is not None, "a search control is on screen (%d rows)" % len(rows(tree)))
    if search is not None:
        client.tool("tap", {"window": mirror, "ref": search["ref"], "wait": "settle", "observe": "none"}, timeout=30)
        field = lambda t: next((r for r in rows(t) if r.get("edit")), None)
        tree = until(client, mirror, lambda t: field(t) is not None)
        evidence("search", tree)
        shown = field(tree)
        report(bool(shown) and shown.get("hint") is True and bool(shown.get("hintText")) and "text" not in shown,
               "[MCP-104] the empty search field is hint: true with hintText and no text (hint chars %d)"
               % len((shown or {}).get("hintText") or ""))

        # The keyboard: wait for the IME layer.
        ime = lambda t: next((l for l in (t.get("layers") or []) if l.get("type") == "ime"), None)
        tree = until(client, mirror, lambda t: ime(t) is not None, seconds=10)
        evidence("keyboard", tree)
        layers = tree.get("layers") or []
        active = [l for l in layers if l.get("active")]
        focus = [r for r in rows(tree) if r.get("focus")]
        shown_ime = "mInputShown=true" in shell("dumpsys", "input_method")
        report(ime(tree) is not None, "the keyboard is a layer of the tree (mInputShown %s, layers %s)"
               % (shown_ime, [l.get("type") for l in layers]))
        report(ime(tree) is not None and not ime(tree).get("active") and all("focused" not in l for l in layers),
               "[MCP-105] the IME layer is not active; no layer carries focused")
        layer_of = lambda r: r.get("l", 0)
        report(len(active) == 1 and active[0].get("type") == "app" and len(focus) == 1
               and focus[0].get("edit") is True and layer_of(focus[0]) == active[0].get("i"),
               "[MCP-105] one active app layer, and the one focus row is its field (focus rows %d)" % len(focus))
        shell("input", "keyevent", "KEYCODE_BACK")
        shell("input", "keyevent", "KEYCODE_BACK")

    # 2. A long form: the new-contact editor. Nothing is typed or saved.
    shell("am", "start", "-W", "--display", "0", "-a", "android.intent.action.INSERT",
          "-t", "vnd.android.cursor.dir/contact")
    tree = tree_of(client, mirror, wait="settle")
    evidence("editor", tree)
    print("  editor: resumed %s, %d rows, omitted %s" % (resumed(), len(rows(tree)), tree.get("omitted")))
    by_i = {r["i"]: r for r in rows(tree)}
    def has_hidden_ancestor(r):
        p = r.get("p")
        while p is not None:
            if by_i[p].get("hidden"):
                return True
            p = by_i[p].get("p")
        return False
    lists = [r for r in rows(tree) if r.get("hidden") and not has_hidden_ancestor(r)]
    hidden = sum(sum(r["hidden"]) for r in lists)
    report(bool(lists) and all(r.get("scroll") for r in lists),
           "[MCP-106] a scrollable carries hidden (%s)" % [r["hidden"] for r in lists])
    report(bool(lists) and tree.get("omitted") == hidden and not any(r.get("off") for r in rows(tree)),
           "[MCP-106] omitted %s equals the hidden rows %d, and no off row is sent" % (tree.get("omitted"), hidden))

    # MCP-86: a tap by ref on a row of that list presses, with expect sent.
    def under(r, top):
        p = r.get("p")
        while p is not None:
            if p == top:
                return True
            p = by_i[p].get("p")
        return False
    target = next((r for r in rows(tree) if lists and under(r, lists[0]["i"]) and r.get("ref")
                   and r.get("at") and not r.get("covered") and (r.get("edit") or label(r))
                   and (r.get("click") or r.get("edit"))), None)
    report(target is not None, "a labelled row of the list is tappable by ref")
    if target is not None:
        answer = client.tool("tap", {"window": mirror, "ref": target["ref"], "wait": "none",
                                     "observe": "none"}, timeout=30)
        did = (answer.get("structuredContent") or {}).get("did") or {}
        time.sleep(1)
        log = subprocess.run([adb, "-s", serial, "logcat", "-d", "-s", "ContiguaSvc:I"],
                             capture_output=True, text=True, timeout=30).stdout
        presses = [l for l in log.splitlines() if "ui.press stream=" in l]
        report(not answer.get("isError") and did.get("ref") == target["ref"]
               and bool(presses) and "pressed expect=yes" in presses[-1],
               "[MCP-86] a tap by ref on a list row presses, expect sent (phone: %s)"
               % (presses[-1].split("ui.press ")[-1] if presses else "no line"))
    shell("input", "keyevent", "KEYCODE_BACK")
    shell("input", "keyevent", "KEYCODE_BACK")
finally:
    client.close()
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))
stop_app
[ "$FAIL" -eq 0 ] && say "TREESHOW EMULATOR PASS" || say "TREESHOW EMULATOR FAIL: $FAIL"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
