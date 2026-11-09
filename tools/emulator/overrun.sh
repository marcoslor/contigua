#!/usr/bin/env bash
# overrun — one boot measures the two overrun arms on the real shell server
# (emulator): A, an encoder whose real output is N× the target the sender
# believes on a fast link; B, the normal encoder on a 3 Mbit/s, 100 ms-each-way
# shaped link. 120 s of motion each, the Mac's own 5 s stats lines, the phone's
# own drop and bitrate lines.
#
#   bash tools/emulator/overrun.sh --check    # rehearse: no device, no boot
#   heavy.sh timeout 2700 bash tools/emulator/overrun.sh
#
# Build the APK first, in Docker only:
#   heavy.sh bash .agent/k1-docker.sh <worktree>/android :app:assembleDebug
# and the e2e Mac bundle (once per tree):
#   bash macos/scripts/bundle.sh macos/build/e2e/PocketDeck.app --variant e2e
#
# The pass bar (overrun_stats.py): over 120 s, at most one drop episode after
# the first 10 s, the Mac's shown fps at least 80 % of the source's on arm A,
# no key frame without an IDR on the Mac, and on arm B the bitrate below the
# phone's measured goodput. The largest key frame is printed against the queue
# budget on both arms.
#
# Environment: PD_OVERRUN_SECONDS (120), PD_OVERRUN_A_OVERSHOOT (3),
# PD_OVERRUN_LINK_MBIT (3), PD_OVERRUN_DELAY_MS (100).
set -uo pipefail

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "overrun.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_OVERRUN_WORK:-/tmp/pd-overrun-emu}"
OUT="${PD_OVERRUN_OUT:-$HOME/dev/pocketdeck/.agent/overrun/emu}"
BUNDLE="$ROOT/macos/build/e2e/PocketDeck.app"
APP="$BUNDLE/Contents/MacOS/PocketDeck"
SHIM="$BUNDLE/Contents/Helpers/pocketdeck-mcp"
BENCH="$ROOT/tools/stream-bench/bench.py"
POC="$ROOT/tools/emulator/poc.py"
STATS="$ROOT/tools/emulator/overrun_stats.py"
FAULT="$ROOT/tools/pdpathfault/pdpathfault.py"
BROWSER="${POCKETDECK_BROWSER:-acr.browser.lightning}"
SECONDS_RUN="${PD_OVERRUN_SECONDS:-120}"
# The emulator's software encoder and page reach far less than the phone's
# 24 Mbps at 3x, so the emulator's arm A needs a larger factor to put a key
# frame over the 256 KB budget. The phone arm uses 3.
OVERSHOOT="${PD_OVERRUN_A_OVERSHOOT:-16}"
LINK_MBIT="${PD_OVERRUN_LINK_MBIT:-3}"
DELAY_MS="${PD_OVERRUN_DELAY_MS:-100}"
PROFILE="overrun$$"
SUPPORT="$HOME/Library/Application Support/PocketDeck-$PROFILE"
E2E_LOCK=/tmp/pocketdeck-e2e.lock
HOLDS_E2E=0
DOCK_DEFAULT_SET=0
APP_PID=""
TAP_PID=""
CAT_PID=""
HTTP_PID=""
PROXY_PID=""
WATCH_PID=""
FAIL=0
PHASE=""

section() { PHASE="$1"; printf '\n== %s ==\n' "$1"; }
ok() { printf 'PASS [%s] %s\n' "$PHASE" "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$PHASE" "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[overrun] %s\n' "$*"; }

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

write_page() {
    cat > "$WORK/overrun.html" <<'HTML'
<!doctype html>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>overrun</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
canvas{display:block;width:100vw;height:100vh}
</style>
<canvas id="c"></canvas>
<script>
// A scrolling noise pattern: one patterned fill per frame, so the software
// GPU keeps a high frame rate while every pixel changes every frame (the
// bitrate arm needs motion, not detail a person would read).
const c = document.getElementById('c');
const x = c.getContext('2d');
const tile = document.createElement('canvas');
tile.width = tile.height = 128;
const tx = tile.getContext('2d');
const img = tx.createImageData(128, 128);
for (let i = 0; i < img.data.length; i += 4) {
  img.data[i] = Math.random() * 255;
  img.data[i + 1] = Math.random() * 255;
  img.data[i + 2] = Math.random() * 255;
  img.data[i + 3] = 255;
}
tx.putImageData(img, 0, 0);
let pattern = null;
let t = 0;
let frames = 0;
function fit() {
  c.width = innerWidth;
  c.height = innerHeight;
  pattern = x.createPattern(tile, 'repeat');
}
addEventListener('resize', fit);
fit();
function draw() {
  const w = c.width;
  const h = c.height;
  x.save();
  x.translate(-((t * 240) % 128), -((t * 160) % 128));
  x.fillStyle = pattern;
  x.fillRect(0, 0, w + 128, h + 128);
  x.restore();
  x.fillStyle = 'hsl(' + ((t * 90) % 360) + ',90%,50%)';
  x.fillRect((t * 300) % w, 0, 80, h);
  t += 0.016;
  frames++;
  if (frames % 60 === 0) document.title = 'overrun ' + frames;
  requestAnimationFrame(draw);
}
draw();
</script>
HTML
}

free_port() {
    "$PYTHON" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# --- --check: everything a boot would die on, without touching a device -----
if [ "$MODE" = check ]; then
    CHECK_FAIL=0
    cfail() { echo "OVERRUN CHECK FAIL: $*"; CHECK_FAIL=1; }
    [ "$SERIAL" = "emulator-5554" ] ||
        cfail "serial '$SERIAL' is not emulator-5554 (never any other serial)"
    bash "$HERE/preflight.sh" || CHECK_FAIL=1
    bash -n "$0" || cfail "bash -n $0"
    "$PYTHON" -m py_compile "$STATS" "$BENCH" "$POC" || cfail "py_compile overrun_stats/bench/poc"
    "$PYTHON" "$STATS" --self-test >/dev/null 2>&1 || cfail "overrun_stats --self-test"
    "$PYTHON" "$FAULT" --help >/dev/null 2>&1 || cfail "pdpathfault --help"
    "$PYTHON" "$BENCH" --help 2>&1 | grep -q -- "--still-seconds" ||
        cfail "bench has no --still-seconds"
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
    if [ -n "${PD_OVERRUN_MAIN_APK:-}" ]; then
        [ -f "$PD_OVERRUN_MAIN_APK" ] ||
            cfail "PD_OVERRUN_MAIN_APK=$PD_OVERRUN_MAIN_APK does not exist"
    fi
    mkdir -p "$WORK"
    write_page
    grep -q "requestAnimationFrame" "$WORK/overrun.html" || cfail "the motion page is not animated"
    "$PYTHON" - "$BROWSER" <<'PY' || cfail "the browser package is empty"
import sys
assert sys.argv[1], "no browser package"
PY
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "OVERRUN CHECK PASS: one boot, $SERIAL, APK $(apk_version_code "$APK"), profile $PROFILE"
        exit 0
    fi
    echo "OVERRUN CHECK FAIL"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
exec > >(tee "$WORK/overrun.out") 2>&1

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
    for pid in "$WATCH_PID" "$PROXY_PID" "$HTTP_PID" "$TAP_PID" "$CAT_PID"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    if [ "$DOCK_DEFAULT_SET" = "1" ]; then
        defaults delete "dev.pocketdeck.mac.$PROFILE" showAppsInDock >/dev/null 2>&1 || true
    fi
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

# The Mac app resolves `open_app` against the phone's app list; a fresh
# session can race the first `apps` reply (arm A once failed with "No phone
# app matches" while arm B, minutes later, found it). Ask for the list until
# the browser is in it, before the bench's first call.
warm_catalog() {
    "$PYTHON" - "$SHIM" "$PROFILE" "$BROWSER" "$ROOT/macos/scripts/mcp-driver.py" <<'PY'
import importlib.util, sys, time
shim, profile, browser, driver = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("pd_mcp_driver", driver)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
mcp = module.MCP(shim, profile)
try:
    for _ in range(30):
        apps = mcp.text("list_apps").get("apps", [])
        if any(app.get("package") == browser for app in apps):
            sys.exit(0)
        time.sleep(1)
    sys.exit(1)
finally:
    mcp.close()
PY
}

# Loads the animated page on the stream's own virtual display once the window
# exists: the app launch may restore a blank tab, and the display id is in the
# phone's own `stream N vd=ID` line. A new task is required: without it the
# intent is delivered to the browser instance already on display 0.
motion_watch() {
    local arm="$1" i line id
    for i in $(seq 1 90); do
        line="$(emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
            grep -o 'stream [0-9]* vd=[0-9]*' | tail -1)"
        [ -n "$line" ] && break
        sleep 1
    done
    if [ -z "$line" ]; then
        say "no virtual display line for arm $arm; the page stays on display 0"
        return 1
    fi
    id="${line##*=}"
    for i in 1 2; do
        emu shell am start --display "$id" -f 0x10000000 \
            -a android.intent.action.VIEW \
            -d "http://10.0.2.2:$HTTP_PORT/overrun.html" -p "$BROWSER" \
            >> "$WORK/motion-$arm.log" 2>&1 || true
        sleep 3
    done
    emu shell dumpsys activity activities 2>/dev/null | tr -d '\r' |
        grep -E "Display #$id|topResumedActivity" | head -8 >> "$WORK/motion-$arm.log" || true
}

run_arm() { # run_arm <a|b> <tag> <connect host:port>
    local arm="$1" tag="$2" addr="$3" rc
    section "arm $arm ($tag)"
    emu logcat -c >/dev/null 2>&1 || true
    "$APP" --profile "$PROFILE" --background --mcp-enable --connect "$addr" \
        --quit-after $((SECONDS_RUN + 240)) > "$WORK/app-$tag.log" 2>&1 &
    APP_PID=$!
    if wait_for 90 app_connected; then
        ok "the Mac app session is ready on arm $arm ($tag)"
    else
        bad "the Mac app never welcomed the phone on arm $arm ($tag)"
        stop_app
        return 1
    fi
    if warm_catalog; then
        ok "the browser is in the phone's app list"
    else
        say "the browser never appeared in the app list; the bench will say so"
    fi
    motion_watch "$tag" &
    WATCH_PID=$!
    for attempt in 1 2; do
        "$PYTHON" "$BENCH" --profile "$PROFILE" --serial "$SERIAL" --adb "$ADB" \
            --repeats 1 --out "$OUT/arm-$tag.csv" --shim "$SHIM" \
            --arms "$WORK/arm-$arm.json" --package "$BROWSER" \
            --script still --still-seconds "$SECONDS_RUN" \
            > "$WORK/bench-$tag-$attempt.log" 2>&1
        rc=$?
        [ "$rc" -eq 0 ] && break
        grep -q "No phone app matches" "$WORK/bench-$tag-$attempt.log" || break
        say "arm $arm: the app list raced the first open; retrying"
        sleep 3
        warm_catalog || true
    done
    cp "$WORK/bench-$tag-$attempt.log" "$WORK/bench-$tag.log" 2>/dev/null || true
    sleep 2
    kill "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
    /usr/bin/log show --last 12m --info --style syslog \
        --predicate "subsystem == \"dev.pocketdeck.mac\" AND processID == $APP_PID" \
        2>/dev/null | grep -E " stats (total )?stream=" > "$WORK/arm-$tag-stats.log" || true
    emu logcat -d -v brief -s PocketDeckSvc:I > "$WORK/arm-$tag-phone.log" 2>&1 || true
    cat "$WORK/bench-$tag.log"
    stop_app
    [ "$rc" -eq 0 ] && ok "the bench run completed on arm $arm ($tag)" \
        || bad "the bench run failed on arm $arm ($tag) (rc=$rc)"
    grep -q ' stats total stream=' "$WORK/arm-$tag-stats.log" \
        && ok "arm $arm ($tag) wrote its totals line" \
        || bad "arm $arm ($tag) wrote no totals line"
    [ "$rc" -eq 0 ]
}

# Installs another build of the same versionCode and restarts the shell server,
# so one boot can measure the pre-fix APK and the fixed one.
install_apk() { # install_apk <apk> <tag>
    local apk="$1" tag="$2"
    [ -f "$apk" ] || { bad "no APK at $apk"; return 1; }
    if ! emu install -r -d "$apk" > "$WORK/install-$tag.log" 2>&1; then
        tail -5 "$WORK/install-$tag.log"
        bad "install of $tag failed"
        return 1
    fi
    # The Shizuku user service keeps the deleted APK until it is killed.
    emu shell pkill -f dev.pocketdeck:pocketdeck >/dev/null 2>&1 || true
    sleep 1
    if ! restart_server > "$WORK/restart-$tag.log" 2>&1; then
        tail -10 "$WORK/restart-$tag.log"
        bad "the server did not restart on $tag"
        return 1
    fi
    ensure_forward >/dev/null || { bad "the forward did not come back on $tag"; return 1; }
    ok "installed $tag (versionCode $(apk_version_code "$apk")) and restarted the server"
}

start_proxy() { # start_proxy <tag>
    local tag="$1"
    PROXY_PORT="$(free_port)"
    "$PYTHON" "$FAULT" --listen "$PROXY_PORT" --connect "127.0.0.1:$PORT" \
        --mode delay-throttle --delay-ms "$DELAY_MS" --rate-mbit "$LINK_MBIT" \
        --events "$WORK/proxy-$tag.jsonl" > "$WORK/proxy-$tag.log" 2>&1 &
    PROXY_PID=$!
    if "$PYTHON" - "$PROXY_PORT" <<'PY'
import socket, sys, time
for _ in range(40):
    try:
        socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.5).close()
        sys.exit(0)
    except OSError:
        time.sleep(0.25)
sys.exit(1)
PY
    then
        ok "the shaper listens on 127.0.0.1:$PROXY_PORT ($DELAY_MS ms, $LINK_MBIT Mbit/s)"
        return 0
    fi
    bad "the shaper never listened"
    return 1
}

stop_proxy() {
    kill "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
}

run_shaped_arm() { # run_shaped_arm <tag>
    local tag="$1"
    start_proxy "$tag" || return 1
    run_arm b "$tag" "127.0.0.1:$PROXY_PORT" || true
    stop_proxy
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

bash "$HERE/unlock.sh" >/dev/null 2>&1 || true
acquire_e2e_lock || bad "no e2e lock: the Mac window is exposed to another agent's input"

# --- pair once, directly ----------------------------------------------------
section pair
rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
defaults write "dev.pocketdeck.mac.$PROFILE" showAppsInDock -bool NO || bad "could not turn the Dock identity off"
DOCK_DEFAULT_SET=1
PAIRED=0
for attempt in 1 2; do
    if pair_mac_once "$attempt"; then PAIRED=1; break; fi
    say "Mac app pair attempt $attempt failed"
    stop_app
    sleep 3
done
if [ "$PAIRED" = 1 ]; then
    ok "the e2e Mac app paired and stored the phone pin"
else
    bad "the Mac app did not pair/store a pin"
    exit 1
fi
# The phone's report is a ~1800x1200 app window; the Mac's default 900x600
# is too small to put a key frame near the queue's 256 KB budget. The window
# frame is remembered per app in the profile's defaults.
defaults write "dev.pocketdeck.mac.$PROFILE" streamFrames \
    -dict "app.$BROWSER" "{{20, 20}, {1600, 1260}}" \
    && say "the app window will open at 1600x1260" \
    || bad "could not seed the app window frame"

# --- the motion source: a local page the emulator's browser can reach --------
section motion
write_page
HTTP_PORT="$(free_port)"
"$PYTHON" -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$WORK" \
    > "$WORK/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:$HTTP_PORT/overrun.html" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -fsS "http://127.0.0.1:$HTTP_PORT/overrun.html" >/dev/null 2>&1 \
    && ok "the motion page is served on 127.0.0.1:$HTTP_PORT" \
    || bad "the motion page did not serve"
# Warm the browser's first run, then leave the page as its current tab.
emu shell am force-stop "$BROWSER" >/dev/null 2>&1 || true
emu shell am start -a android.intent.action.VIEW \
    -d "http://10.0.2.2:$HTTP_PORT/overrun.html" -p "$BROWSER" >/dev/null 2>&1 || true
sleep 6
emu shell input keyevent 4 >/dev/null 2>&1 || true
sleep 1
emu shell am start -a android.intent.action.VIEW \
    -d "http://10.0.2.2:$HTTP_PORT/overrun.html" -p "$BROWSER" >/dev/null 2>&1 || true
sleep 8
TOP="$(emu shell dumpsys activity activities 2>/dev/null | tr -d '\r' |
    grep -m1 -E 'topResumedActivity|ResumedActivity' || true)"
say "top activity: ${TOP:-unknown}"

# --- the arms ---------------------------------------------------------------
cat > "$WORK/arm-a.json" <<JSON
{"arms": [{"name": "overrun-a", "phone": {"overshoot": "$OVERSHOOT"}, "mac": {}}]}
JSON
cat > "$WORK/arm-b.json" <<JSON
{"arms": [{"name": "overrun-b", "phone": {}, "mac": {}}]}
JSON

# One boot measures the pre-fix APK first (its arm A must fail the bar: the
# repro), then installs the worktree's fixed APK and runs the same arms.
MAIN_APK="${PD_OVERRUN_MAIN_APK:-}"
if [ -n "$MAIN_APK" ] && [ -f "$MAIN_APK" ]; then
    section "main phase (pre-fix APK)"
    install_apk "$MAIN_APK" main || exit 1
    run_arm a a-main "127.0.0.1:$PORT" || true
    run_shaped_arm b-main
    section "main phase numbers"
    "$PYTHON" "$STATS" --arm a --stats "$WORK/arm-a-main-stats.log" \
        --logcat "$WORK/arm-a-main-phone.log" --seconds "$SECONDS_RUN" \
        > "$WORK/check-a-main.log" 2>&1
    cat "$WORK/check-a-main.log"
    "$PYTHON" "$STATS" --arm b --stats "$WORK/arm-b-main-stats.log" \
        --logcat "$WORK/arm-b-main-phone.log" --proxy "$WORK/proxy-b-main.jsonl" \
        --seconds "$SECONDS_RUN" --link-mbit "$LINK_MBIT" \
        > "$WORK/check-b-main.log" 2>&1
    cat "$WORK/check-b-main.log"
    grep -q "^FAIL arm-a" "$WORK/check-a-main.log" \
        && ok "the pre-fix arm A fails the bar (the repro)" \
        || bad "the pre-fix arm A did not reproduce the spiral"
    section "fixed phase (worktree APK)"
    install_apk "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" fixed || exit 1
fi

# --- arm A: the encoder overshoots on a fast link ---------------------------
run_arm a a "127.0.0.1:$PORT" || true

# --- arm B: the normal encoder on a 3 Mbit/s, 100 ms shaped link ------------
run_shaped_arm b

# --- the pass bar -----------------------------------------------------------
section pass
"$PYTHON" "$STATS" --arm a --stats "$WORK/arm-a-stats.log" \
    --logcat "$WORK/arm-a-phone.log" --seconds "$SECONDS_RUN" > "$WORK/check-a.log" 2>&1
A_RC=$?
cat "$WORK/check-a.log"
[ "$A_RC" -eq 0 ] && ok "arm A passes the bar" || bad "arm A fails the bar"
"$PYTHON" "$STATS" --arm b --stats "$WORK/arm-b-stats.log" \
    --logcat "$WORK/arm-b-phone.log" --proxy "$WORK/proxy-b.jsonl" \
    --seconds "$SECONDS_RUN" --link-mbit "$LINK_MBIT" > "$WORK/check-b.log" 2>&1
B_RC=$?
cat "$WORK/check-b.log"
[ "$B_RC" -eq 0 ] && ok "arm B passes the bar" || bad "arm B fails the bar"

say "artifacts: $WORK, $OUT"
if [ "$FAIL" -eq 0 ]; then
    say "OVERRUN EMULATOR PASS"
else
    say "OVERRUN EMULATOR FAIL: $FAIL"
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
