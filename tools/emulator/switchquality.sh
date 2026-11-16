#!/usr/bin/env bash
# switchquality — S3 on the emulator: the phone's own QualityAdaptation and
# EncoderCorrection under a link that steps 20 -> 3 -> 20 Mbit/s with motion on
# screen, then the AWDL stall pattern at 20 Mbit/s (PATH-46).
#
#   bash tools/emulator/switchquality.sh --check     # rehearse: no device, no boot
#   bash -c 'CONTIGUA_SERIAL=emulator-5584 bash tools/emulator/switchquality.sh'
#
# One boot runs both arms. The red arm sets
# `debug.contigua.stream.quality=off` (the debug switch in StreamStrategy /
# QualityAdaptation) and must show the broken build: the target never falls,
# the 3 Mbit/s step repeats its drop cycle. The green arm sets it back on and
# must pass every PATH-46 bound. The forwarded leg is shaped by pdpathfault:
# the emulator console's `network speed` shapes the guest's NIC, not the adb
# forward the Mac reaches, so `netshape.sh show` only proves the console is
# unshaped (measured 2026-11-09).
#
# Build the APK first:
#   cd <worktree>/android && ./gradlew :app:assembleDebug
# and the e2e Mac bundle once per tree:
#   bash macos/scripts/bundle.sh macos/build/e2e/Contigua.app --variant e2e
set -uo pipefail

export CONTIGUA_SERIAL="${CONTIGUA_SERIAL:-emulator-5584}"

MODE=run
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "switchquality.sh: unknown flag $arg" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib.sh"

WORK="${PD_SWITCHQUALITY_WORK:-/tmp/pd-switch-quality}"
OUT="${PD_SWITCHQUALITY_OUT:-$MAIN_REPO/.work/switch/quality}"
BUNDLE="$ROOT/macos/build/e2e/Contigua.app"
APP="$BUNDLE/Contents/MacOS/Contigua"
SHIM="$BUNDLE/Contents/Helpers/contigua-mcp"
FAULT="$ROOT/tools/pdpathfault/pdpathfault.py"
STATS="$HERE/switchquality_stats.py"
POC="$HERE/poc.py"
NETSHAPE="$HERE/netshape.sh"
BROWSER="${CONTIGUA_BROWSER:-acr.browser.lightning}"
PROFILE="${PD_SWITCHQUALITY_PROFILE:-switchq$$}"
SUPPORT="$HOME/Library/Application Support/Contigua-$PROFILE"
E2E_LOCK=/tmp/contigua-e2e.lock
BASELINE_SECONDS="${PD_SWITCHQUALITY_BASELINE:-15}"
STEP_SECONDS="${PD_SWITCHQUALITY_STEP:-60}"
RECOVERY_MAX="${PD_SWITCHQUALITY_RECOVERY_MAX:-300}"
BACK_SECONDS="${PD_SWITCHQUALITY_BACK:-10}"
STALL_SECONDS="${PD_SWITCHQUALITY_STALL:-10}"
LOW_MBIT=3
HIGH_MBIT=20
HOLDS_E2E=0
DOCK_DEFAULT_SET=0
APP_PID=""
TAP_PID=""
HTTP_PID=""
PROXY_PID=""
MACLOG_PID=""
PHONELOG_PID=""
FAIL=0
PHASE=""

section() { PHASE="$1"; printf '\n== %s ==\n' "$1"; }
ok() { printf 'PASS [%s] %s\n' "$PHASE" "$*"; }
bad() { printf 'FAIL [%s] %s\n' "$PHASE" "$*"; FAIL=$((FAIL + 1)); }
say() { printf '[switchquality] %s\n' "$*"; }

wait_for() { # wait_for <seconds> <command...>
    local deadline=$(( $(date +%s) + $1 ))
    shift
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.25
    done
    return 1
}

qnow() { "$PYTHON" -c 'import time; print("%.3f" % time.time())'; }

free_port() {
    "$PYTHON" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

write_page() {
    cat > "$WORK/quality.html" <<'HTML'
<!doctype html>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>switchquality</title>
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
canvas{display:block;width:100vw;height:100vh}
</style>
<canvas id="c"></canvas>
<script>
// The motion source: one random-pixel fill per frame, scrolled, so the
// software encoder sees both high frame rate and sustained bitrate.
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
function fit() {
  c.width = innerWidth;
  c.height = innerHeight;
  pattern = x.createPattern(tile, 'repeat');
}
addEventListener('resize', fit);
fit();
function draw() {
  x.save();
  x.translate(-((t * 240) % 128), -((t * 160) % 128));
  x.fillStyle = pattern;
  x.fillRect(0, 0, c.width + 128, c.height + 128);
  x.restore();
  x.fillStyle = 'hsl(' + ((t * 90) % 360) + ',90%,50%)';
  x.fillRect((t * 300) % c.width, 0, 80, c.height);
  t += 0.016;
  requestAnimationFrame(draw);
}
draw();
// PATH-46 also bounds audio underrun. A WebAudio tone gives the phone's
// audio capture something to carry; a page that starts its context without a
// gesture simply reports `audio` state, and the stats judge says when no
// frames ran.
try {
  const ac = new (window.AudioContext || window.webkitAudioContext)();
  const osc = ac.createOscillator();
  const gain = ac.createGain();
  gain.gain.value = 0.04;
  osc.frequency.value = 440;
  osc.connect(gain).connect(ac.destination);
  osc.start();
  document.title = 'switchquality audio ' + ac.state;
} catch (e) {}
</script>
HTML
}

# --- --check: everything a boot would die on, without touching a device -----
if [ "$MODE" = check ]; then
    CHECK_FAIL=0
    cfail() { echo "SWITCHQUALITY CHECK FAIL: $*"; CHECK_FAIL=1; }
    # Any emulator port is a rig; the default 5584 only keeps the original
    # worker off 5554. A worker with a fixed serial (ratectl: 5588) must pass.
    case "$SERIAL" in
        emulator-[0-9]*) ;;
        *) cfail "serial '$SERIAL' is not an emulator-<port> serial (never the real phone)" ;;
    esac
    bash -n "$0" || cfail "bash -n $0"
    bash -n "$HERE/start.sh" || cfail "bash -n tools/emulator/start.sh"
    bash -n "$NETSHAPE" || cfail "bash -n tools/emulator/netshape.sh"
    "$PYTHON" -m py_compile "$STATS" "$FAULT" "$POC" ||
        cfail "py_compile switchquality_stats/pdpathfault/poc"
    "$PYTHON" "$STATS" --self-test >/dev/null 2>&1 ||
        cfail "switchquality_stats --self-test"
    "$PYTHON" "$FAULT" --help >/dev/null 2>&1 || cfail "pdpathfault --help"
    bash "$NETSHAPE" --check show >/dev/null 2>&1 ||
        cfail "netshape --check show"
    [ -x "$APP" ] || cfail "no e2e Mac app at $APP"
    [ -x "$SHIM" ] || cfail "no MCP shim at $SHIM"
    if [ -x "$APP" ]; then
        stale="$(find "$ROOT/macos/Sources" -type f -newer "$APP" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the Mac app is older than $stale"
    fi
    APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
    [ -f "$APK" ] || cfail "no debug APK at $APK (build it first)"
    if [ -f "$APK" ]; then
        stale="$(find "$ROOT/android/app/src/main" -type f -newer "$APK" -print -quit 2>/dev/null)"
        [ -z "$stale" ] || cfail "the APK is older than $stale (rebuild :app:assembleDebug)"
    fi
    mkdir -p "$WORK"
    write_page
    grep -q "requestAnimationFrame" "$WORK/quality.html" ||
        cfail "the motion page is not animated"
    if [ "$CHECK_FAIL" -eq 0 ]; then
        echo "SWITCHQUALITY CHECK PASS: one boot, $SERIAL, APK $(apk_version_code "$APK"), profile $PROFILE"
        exit 0
    fi
    echo "SWITCHQUALITY CHECK FAIL"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"
exec > >(tee "$WORK/switchquality.out") 2>&1

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
    for pid in "$MACLOG_PID" "$PHONELOG_PID" "$PROXY_PID" "$HTTP_PID" "$TAP_PID"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    emu shell setprop debug.contigua.stream.quality "" >/dev/null 2>&1 || true
    if [ "$DOCK_DEFAULT_SET" = "1" ]; then
        defaults delete "app.contigua.mac.$PROFILE" showAppsInDock >/dev/null 2>&1 || true
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

# The Mac app resolves `open_app` against the phone's app list; a fresh session
# can race the first `apps` reply. Ask for the list until the browser is in it.
warm_catalog() {
    "$PYTHON" - "$SHIM" "$PROFILE" "$BROWSER" "$ROOT/macos/scripts/mcp/driver.py" <<'PY'
import importlib.util, json, sys, time
shim, profile, browser, driver = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("pd_mcp_driver", driver)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
mcp = module.MCP(shim, profile)
try:
    for _ in range(30):
        # MCP-33: before the app list arrives, list_apps fails not_ready
        # instead of answering an empty list; keep waiting either way.
        result = mcp.tool("list_apps")
        apps = [] if result.get("isError") else json.loads(result["content"][0]["text"]).get("apps", [])
        if any(app.get("package") == browser for app in apps):
            sys.exit(0)
        time.sleep(1)
    sys.exit(1)
finally:
    mcp.close()
PY
}

# open_window — one MCP call, then the client closes; the window stays open.
open_window() {
    "$PYTHON" - "$SHIM" "$PROFILE" "$BROWSER" "$ROOT/macos/scripts/mcp/driver.py" <<'PY'
import importlib.util, json, sys
shim, profile, browser, driver = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("pd_mcp_driver", driver)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
mcp = module.MCP(shim, profile)
try:
    print(json.dumps(mcp.text("open_app", {"app": browser})))
finally:
    mcp.close()
PY
}

close_window() { # close_window <window>
    "$PYTHON" - "$SHIM" "$PROFILE" "$1" "$ROOT/macos/scripts/mcp/driver.py" <<'PY'
import importlib.util, json, sys
shim, profile, window, driver = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("pd_mcp_driver", driver)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
mcp = module.MCP(shim, profile)
try:
    mcp.text("close_window", {"window": int(window)})
finally:
    mcp.close()
PY
}

# Loads the animated page on the stream's own virtual display: the app launch
# may restore a blank tab, and the display id is in the phone's own
# `stream N vd=ID` line. A new task is required.
motion_watch() {
    local i line id
    for i in $(seq 1 60); do
        line="$(emu logcat -d -s ContiguaSvc:I 2>/dev/null |
            grep -o 'stream [0-9]* vd=[0-9]*' | tail -1)"
        [ -n "$line" ] && break
        sleep 1
    done
    if [ -z "$line" ]; then
        say "no virtual display line; the page stays on display 0"
        return 1
    fi
    id="${line##*=}"
    for i in 1 2; do
        emu shell am start --display "$id" -f 0x10000000 \
            -a android.intent.action.VIEW \
            -d "http://10.0.2.2:$HTTP_PORT/quality.html" -p "$BROWSER" \
            >> "$WORK/motion.log" 2>&1 || true
        sleep 3
    done
}

# quality_target FILE — the last numeric target_kbps in the Mac stats stream.
quality_target() {
    "$PYTHON" - "$1" <<'PY'
import re, sys
target = None
try:
    handle = open(sys.argv[1], errors="replace")
except OSError:
    sys.exit(0)
with handle:
    for line in handle:
        if "stats stream=" not in line:
            continue
        match = re.search(r"target_kbps=(\d+)", line)
        if match:
            target = int(match.group(1))
print(target if target is not None else "")
PY
}

quality_ctl() { # quality_ctl <line>
    printf '%s\n' "$1" > "$CTL"
}

start_proxy() { # start_proxy <tag>
    local tag="$1"
    PROXY_PORT="$(free_port)"
    CTL="$WORK/ctl-$tag"
    : > "$CTL"
    "$PYTHON" "$FAULT" --listen "$PROXY_PORT" --connect "127.0.0.1:$PORT" \
        --mode throttle --rate-mbit "$HIGH_MBIT" \
        --stall-ms 100 --stall-every-ms 1000 \
        --ctl-file "$CTL" --events "$WORK/proxy-$tag.jsonl" \
        > "$WORK/proxy-$tag.log" 2>&1 &
    PROXY_PID=$!
    for _ in $(seq 1 40); do
        if "$PYTHON" - "$PROXY_PORT" <<'PY'
import socket, sys
try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.5).close()
    sys.exit(0)
except OSError:
    sys.exit(1)
PY
        then
            ok "the shaper listens on 127.0.0.1:$PROXY_PORT ($HIGH_MBIT Mbit/s, no delay)"
            return 0
        fi
        sleep 0.25
    done
    bad "the shaper never listened"
    return 1
}

stop_proxy() {
    kill "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
}

run_arm() { # run_arm <tag> <on|off>
    local tag="$1" quality="$2" red=0
    [ "$quality" = "off" ] && red=1
    section "arm $tag (quality=$quality)"
    emu shell setprop debug.contigua.stream.quality "$quality" >/dev/null 2>&1 || true
    say "debug.contigua.stream.quality=$(emu shell getprop debug.contigua.stream.quality | tr -d '\r')"
    if ! restart_server > "$WORK/restart-$tag.log" 2>&1; then
        tail -10 "$WORK/restart-$tag.log"
        bad "the phone server did not restart"
        return 1
    fi
    if ! ensure_forward >/dev/null; then
        bad "the forward did not come back"
        return 1
    fi
    emu logcat -c >/dev/null 2>&1 || true
    : > "$WORK/phases-$tag.txt"
    start_proxy "$tag" || return 1

    "$APP" --profile "$PROFILE" --background --mcp-enable \
        --connect "127.0.0.1:$PROXY_PORT" --quit-after 900 \
        --audio-stats "$WORK/audio-$tag.json" > "$WORK/app-$tag.log" 2>&1 &
    APP_PID=$!
    /usr/bin/log stream --info --style syslog --predicate "processID == $APP_PID" \
        > "$WORK/mac-$tag.log" 2>&1 &
    MACLOG_PID=$!
    "$ADB" -s "$SERIAL" logcat -v epoch -s ContiguaSvc:I > "$WORK/phone-$tag.log" 2>&1 &
    PHONELOG_PID=$!

    if wait_for 120 app_connected; then
        ok "the Mac app welcomed the phone"
    else
        bad "the Mac app never welcomed the phone"
        return 1
    fi
    if warm_catalog; then
        ok "the browser is in the phone's app list"
    else
        bad "the browser never appeared in the app list"
        return 1
    fi
    local opened window
    opened="$(open_window)" || { bad "open_app failed"; return 1; }
    window="$("$PYTHON" -c "import json,sys; print(json.loads(sys.argv[1]).get('window',''))" "$opened" 2>/dev/null)"
    [ -n "$window" ] || { bad "open_app returned no window: $opened"; return 1; }
    say "window $window open"
    motion_watch || say "the page may already be the window's current tab"
    local first_deadline=$(( $(date +%s) + 90 )) base_target=""
    while [ "$(date +%s)" -lt "$first_deadline" ]; do
        base_target="$(quality_target "$WORK/mac-$tag.log")"
        [ -n "$base_target" ] && break
        sleep 1
    done
    if [ -z "$base_target" ]; then
        bad "no Mac stats line with a phone target arrived"
        stop_app
        return 1
    fi
    ok "the first stats line reports a ${base_target} kbps target"

    # The stream opens at its cap, takes a startup drop and climbs back 10%
    # per 5 s. Wait for the pre-step plateau before marking the baseline, or
    # the step would start in the middle of the ramp and "climb back" would be
    # measured against a transient value.
    local first_target settle_deadline target
    first_target="$base_target"
    settle_deadline=$(( $(date +%s) + 120 ))
    while [ "$(date +%s)" -lt "$settle_deadline" ]; do
        target="$(quality_target "$WORK/mac-$tag.log")"
        if [ -n "$target" ] && [ -n "$first_target" ] &&
            "$PYTHON" -c "import sys; sys.exit(0 if int(sys.argv[1]) >= 0.95 * int(sys.argv[2]) else 1)" "$target" "$first_target"; then
            break
        fi
        sleep 5
    done
    base_target="$(quality_target "$WORK/mac-$tag.log")"
    ok "the pre-step target settled at ${base_target} kbps (first ${first_target})"
    local t_base_start t_base_end t_step_start t_step_end t_back_start t_back_end t_stall_start t_stall_end
    t_base_start="$(qnow)"
    cp "$WORK/audio-$tag.json" "$WORK/audio-$tag-base.json" 2>/dev/null || true
    sleep "$BASELINE_SECONDS"
    base_target="$(quality_target "$WORK/mac-$tag.log")"
    t_base_end="$(qnow)"
    t_step_start="$t_base_end"
    printf 'arm=%s\nbase_start=%s\nbase_end=%s\nstep_start=%s\n' "$tag" "$t_base_start" "$t_base_end" "$t_step_start" \
        > "$WORK/phases-$tag.txt"
    quality_ctl "mode throttle"
    sleep 0.2
    quality_ctl "rate $LOW_MBIT"
    say "link 3 Mbit/s; step for ${STEP_SECONDS} s"
    sleep "$STEP_SECONDS"
    t_step_end="$(qnow)"
    printf 'step_end=%s\nback_start=%s\n' "$t_step_end" "$t_step_end" >> "$WORK/phases-$tag.txt"
    quality_ctl "rate $HIGH_MBIT"
    say "link back to ${HIGH_MBIT} Mbit/s at $t_step_end"
    t_back_start="$(qnow)"
    local recovered="" deadline=$(( $(date +%s) + RECOVERY_MAX )) target=""
    if [ "$red" = "0" ]; then
        local want
        want="$("$PYTHON" -c "print(int(0.9 * $base_target))")"
        while [ "$(date +%s)" -lt "$deadline" ]; do
            target="$(quality_target "$WORK/mac-$tag.log")"
            if [ -n "$target" ] && [ "$target" -ge "$want" ]; then
                recovered="$(qnow)"
                ok "the target climbed back to ${target} kbps after $("$PYTHON" -c "print(round($recovered - $t_step_end, 1))") s (wanted ≥ ${want})"
                break
            fi
            sleep 2
        done
        if [ -z "$recovered" ]; then
            bad "the target did not climb back to ${want} kbps within ${RECOVERY_MAX} s (last ${target:-?})"
        else
            printf 'recovered=%s\n' "$recovered" >> "$WORK/phases-$tag.txt"
            sleep "$BACK_SECONDS"
        fi
    fi
    t_back_end="$(qnow)"
    printf 'back_end=%s\n' "$t_back_end" >> "$WORK/phases-$tag.txt"
    cp "$WORK/audio-$tag.json" "$WORK/audio-$tag-end.json" 2>/dev/null || true

    if [ "$red" = "0" ]; then
        t_stall_start="$(qnow)"
        quality_ctl "mode stall"
        say "the AWDL stall pattern (100 ms off per second) for ${STALL_SECONDS} s"
        sleep "$STALL_SECONDS"
        t_stall_end="$(qnow)"
        printf 'stall_start=%s\nstall_end=%s\n' "$t_stall_start" "$t_stall_end" >> "$WORK/phases-$tag.txt"
    fi

    close_window "$window" >/dev/null 2>&1 || true
    sleep 2
    stop_app
    kill "$MACLOG_PID" "$PHONELOG_PID" 2>/dev/null || true
    wait "$MACLOG_PID" "$PHONELOG_PID" 2>/dev/null || true
    MACLOG_PID=""
    PHONELOG_PID=""
    stop_proxy
    printf 'mac_path=%s\n' "$WORK/mac-$tag.log" >> "$WORK/phases-$tag.txt"
    cp "$WORK/phone-$tag.log" "$WORK/mac-$tag.log" "$WORK/audio-$tag.json" \
        "$WORK/proxy-$tag.jsonl" "$OUT/" 2>/dev/null || true
    return 0
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
ok "booted on $SERIAL, real server at $ADDR (device $DEVPORT)"

bash "$HERE/unlock.sh" >/dev/null 2>&1 || true
acquire_e2e_lock || bad "no e2e lock: the Mac window is exposed to another agent's input"

section "console shaper"
if bash "$NETSHAPE" show > "$WORK/netshape.txt" 2>&1; then
    cat "$WORK/netshape.txt"
    if grep -Eq 'download speed: +0 bits/s' "$WORK/netshape.txt" &&
        grep -Eq 'upload speed: +0 bits/s' "$WORK/netshape.txt" &&
        grep -Eq 'minimum latency: +0 ms' "$WORK/netshape.txt" &&
        grep -Eq 'maximum latency: +0 ms' "$WORK/netshape.txt"; then
        ok "the emulator console is unshaped (0 bits/s, 0 ms; the forwarded leg is shaped by pdpathfault)"
    else
        bad "the emulator console is not at full speed/none delay"
    fi
else
    bad "netshape.sh show failed"
fi

# --- pair once, directly ----------------------------------------------------
section pair
rm -rf "$SUPPORT"
mkdir -p "$SUPPORT"
defaults write "app.contigua.mac.$PROFILE" showAppsInDock -bool NO || bad "could not turn the Dock identity off"
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
defaults write "app.contigua.mac.$PROFILE" streamFrames \
    "{ 'app.$BROWSER' = '{{20, 20}, {1600, 1260}}'; }" \
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
    curl -fsS "http://127.0.0.1:$HTTP_PORT/quality.html" >/dev/null 2>&1 && break
    sleep 0.5
done
curl -fsS "http://127.0.0.1:$HTTP_PORT/quality.html" >/dev/null 2>&1 \
    && ok "the motion page is served on 127.0.0.1:$HTTP_PORT" \
    || bad "the motion page did not serve"
emu shell am force-stop "$BROWSER" >/dev/null 2>&1 || true
emu shell am start -a android.intent.action.VIEW \
    -d "http://10.0.2.2:$HTTP_PORT/quality.html" -p "$BROWSER" >/dev/null 2>&1 || true
sleep 6
emu shell input keyevent 4 >/dev/null 2>&1 || true
sleep 1
emu shell am start -a android.intent.action.VIEW \
    -d "http://10.0.2.2:$HTTP_PORT/quality.html" -p "$BROWSER" >/dev/null 2>&1 || true
sleep 8

# --- the arms ---------------------------------------------------------------
section "red arm (quality off)"
red_done=0
run_arm red off && red_done=1
section "green arm (quality on)"
green_done=0
run_arm green on && green_done=1

# --- the bounds -------------------------------------------------------------
section pass
if [ "$red_done" = "1" ]; then
    red_rc=0
    "$PYTHON" "$STATS" --arm red --mac "$WORK/mac-red.log" \
        --phone "$WORK/phone-red.log" --phases "$WORK/phases-red.txt" || red_rc=$?
    [ "$red_rc" -eq 0 ] && ok "the broken build is red (no down-step, repeated drop cycle)" \
        || bad "the broken build did not reproduce (the red arm adapted)"
else
    bad "the red arm did not finish"
fi
if [ "$green_done" = "1" ]; then
    green_rc=0
    "$PYTHON" "$STATS" --arm green --mac "$WORK/mac-green.log" \
        --phone "$WORK/phone-green.log" --phases "$WORK/phases-green.txt" \
        --audio-a "$WORK/audio-green-base.json" --audio-b "$WORK/audio-green-end.json" \
        || green_rc=$?
    [ "$green_rc" -eq 0 ] && ok "the green arm passes every PATH-46 bound" \
        || bad "the green arm missed a PATH-46 bound"
else
    bad "the green arm did not finish"
fi

say "artifacts: $WORK, $OUT"
if [ "$FAIL" -eq 0 ]; then
    say "SWITCHQUALITY PASS"
else
    say "SWITCHQUALITY FAIL: $FAIL"
fi
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
