#!/usr/bin/env bash
# Shared helpers for the PocketDeck emulator rig. Sourced, never executed.
#
# Every rig script is run as `bash tools/emulator/<script>.sh`: a fresh clone or
# an unpacked archive can arrive without the exec bit, and a script that dies on
# "Permission denied" after the emulator is already booting wastes the boot.
# Scripts call each other through `bash` too, never through their own path.
#
# Every adb call goes through `emu`/`emu_long`, which pin one serial: a physical
# phone may be attached to this Mac and must never be touched by the rig.

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"

EMU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$EMU_DIR/../.." && pwd)"
CACHE_DIR="$EMU_DIR/.cache"
# Downloaded fixtures (Shizuku, the F-Droid test apps) are shared by every
# checkout: a fresh worktree's empty .cache used to fetch them again after the
# boot and lose it to GitHub's rate limit (403). Run state stays in CACHE_DIR.
FIXTURE_DIR="${POCKETDECK_FIXTURES:-$HOME/.cache/pocketdeck-emulator}"
ADB="$ANDROID_HOME/platform-tools/adb"
# shellcheck disable=SC2034 # library value: start.sh boots $AVD_NAME
EMULATOR="$ANDROID_HOME/emulator/emulator"
AAPT2="$ANDROID_HOME/build-tools/36.0.0/aapt2"
# shellcheck disable=SC2034 # library value: start.sh boots this AVD
AVD_NAME="${POCKETDECK_AVD:-pocketdeck-api36}"
SERIAL="${POCKETDECK_SERIAL:-emulator-5554}"
PORT="${POCKETDECK_PORT:-47811}"
AGENT_DIR="${POCKETDECK_AGENT_DIR:-$REPO_ROOT/.agent/emu}"

CACHE_DIR="$CACHE_DIR"
AGENT_DIR="$AGENT_DIR"
mkdir -p "$CACHE_DIR" "$AGENT_DIR" "$FIXTURE_DIR/apks"

# The v2 handshake is TLS 1.3, which the macOS system Python (3.9 + LibreSSL)
# cannot do. Prefer an interpreter whose ssl can enforce it; POCKETDECK_PYTHON
# overrides. Falls back to plain python3 so the error names the real cause.
pick_python() {
  local cand
  for cand in "${POCKETDECK_PYTHON:-}" /opt/homebrew/bin/python3 python3; do
    [ -n "$cand" ] || continue
    command -v "$cand" >/dev/null 2>&1 || continue
    "$cand" -c 'import ssl; c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); c.minimum_version = ssl.TLSVersion.TLSv1_3' \
      >/dev/null 2>&1 && { echo "$cand"; return 0; }
  done
  command -v python3
}
# shellcheck disable=SC2034 # library value: every rig script calls "$PYTHON"
PYTHON="$(pick_python)"

emu() { timeout "${ADB_TIMEOUT:-20}" "$ADB" -s "$SERIAL" "$@"; }
emu_long() { timeout "${ADB_LONG_TIMEOUT:-600}" "$ADB" -s "$SERIAL" "$@"; }

# Human-readable step logging, same shape in every script.
step() { printf '[%s] %s\n' "$(basename "$0")" "$*"; }
die() {
  printf '[%s] error: %s\n' "$(basename "$0")" "$*" >&2
  exit 1
}

device_present() {
  emu devices 2>/dev/null | awk -v s="$SERIAL" '$1 == s && $2 == "device" { found = 1 } END { exit !found }'
}

wait_for_device() { # wait_for_device [timeout_s]
  local deadline=$(( $(date +%s) + ${1:-120} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if emu wait-for-device 2>/dev/null && device_present; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Deterministic download with a cache: `fetch <url> <dst>` skips when dst exists.
fetch() {
  local url="$1" dst="$2"
  if [ -s "$dst" ]; then
    return 0
  fi
  step "downloading $(basename "$dst")"
  curl -fsSL --retry 3 --max-time 600 -o "$dst.part" "$url" || {
    rm -f "$dst.part"
    return 1
  }
  mv "$dst.part" "$dst"
}

# `latest_github_release_asset <repo> <regex>` -> download url of the newest
# release asset matching the regex (Shizuku ships one APK per release).
github_release_asset() {
  local repo="$1" pattern="$2"
  curl -fsSL --max-time 60 "https://api.github.com/repos/$repo/releases/latest" |
    python3 -c '
import json, re, sys
pat = re.compile(sys.argv[1])
rel = json.load(sys.stdin)
for asset in rel.get("assets", []):
    if pat.search(asset["name"]):
        print(asset["browser_download_url"])
        break
' "$pattern"
}

# F-Droid serves <pkg>_<versionCode>.apk; ask the index for the current code.
fdroid_latest_url() { # fdroid_latest_url <package>
  local pkg="$1" code
  code="$(curl -fsSL --max-time 60 "https://f-droid.org/api/v1/packages/$pkg" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["suggestedVersionCode"])')" || return 1
  [ -n "$code" ] || return 1
  echo "https://f-droid.org/repo/${pkg}_${code}.apk"
}

# The PocketDeck server binds an ephemeral port and logs it (Server.kt).
server_port_from_logcat() {
  emu logcat -d -s PocketDeckSvc:I 2>/dev/null |
    sed -n 's/.*listening on 0\.0\.0\.0:\([0-9][0-9]*\).*/\1/p' | tail -1
}

# The shell-UID user service process(es) that host the server.
server_pids() {
  # grep exits 1 when there is no daemon; the rig runs under `set -euo pipefail`.
  emu shell "ps -A -o PID,NAME 2>/dev/null | grep 'dev.pocketdeck:'" 2>/dev/null |
    awk '{print $1}' | tr -d '\r' | tr '\n' ' ' || true
}

server_pid() {
  server_pids | awk '{print $1}'
}

# The server binds an ephemeral port. The logcat line is the newest truth (the
# rig clears logcat before launching the app); `ss` says which process is really
# listening, and also serves as the "a shell-UID process owns the port" evidence.
device_port() {
  local pid port
  port="$(server_port_from_logcat)"
  if [ -n "$port" ] && emu shell "ss -ltn 2>/dev/null | grep -q \":$port \"" 2>/dev/null; then
    echo "$port"
    return 0
  fi
  for pid in $(server_pids); do
    # `ss -ltnp` line: LISTEN 0 0 *:45913 *:* users:(("main",pid=5288,fd=64))
    port="$(emu shell "ss -ltnp 2>/dev/null | grep \"pid=$pid,\"" 2>/dev/null |
      awk 'NR == 1 { split($4, a, ":"); print a[2] }' | tr -d '\r')"
    if [ -n "$port" ]; then
      echo "$port"
      return 0
    fi
  done
  return 1
}

# adb forward rules die with the adb server (e.g. when a wireless device
# reconnects), so both start.sh and flow.sh re-assert it before use.
ensure_forward() {
  local devport
  devport="$(device_port)"
  [ -n "$devport" ] || return 1
  emu forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
  emu forward "tcp:$PORT" "tcp:$devport" >/dev/null || return 1
  echo "$devport"
}

# The APK's versionCode as the build wrote it. aapt2 keeps the historical
# `versionCode='102'` shape; some outputs drop the quotes.
# ledger_boots <ledger> <worktree> — how many emulator boots the boot guard
# recorded for one worktree. The ledger's fields are:
#   <date> <time> <worktree> <emulator|vm> <pid>
# so the name is $3 and the kind $4 (a first version compared $2/$3 and read
# every boot as 0 after a real one).
ledger_boots() {
  [ -f "$1" ] || { echo 0; return; }
  awk -v n="$2" '$3 == n && $4 == "emulator" { c++ } END { print c + 0 }' "$1"
}

apk_version_code() { # apk_version_code <apk>
  "$AAPT2" dump badging "$1" 2>/dev/null |
    sed -n "s/.*versionCode='\{0,1\}\([0-9][0-9]*\)'\{0,1\}.*/\1/p" | head -1
}

# The versionCode the device reports for an installed package.
installed_version_code() { # installed_version_code <pkg>
  emu shell dumpsys package "$1" 2>/dev/null |
    sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -1 | tr -d '\r'
}

# The rig's debug receivers are exported to explicit intents only in practice:
# an implicit broadcast from adb is dropped while the app sits in the background
# (Android 8+ manifest-receiver rule), which cost a whole boot once. Every rig
# broadcast therefore names its component.
debug_component() { # debug_component <action>
  case "$1" in
    dev.pocketdeck.DEBUG_MEDIA) echo "dev.pocketdeck/dev.pocketdeck.app.MediaDebugTrigger" ;;
    dev.pocketdeck.DEBUG_NOTIFY) echo "dev.pocketdeck/dev.pocketdeck.app.NotifyDebugPoster" ;;
    *) return 1 ;;
  esac
}

debug_broadcast() { # debug_broadcast <action> [am extras...]
  local action="$1" comp
  shift
  comp="$(debug_component "$action")" ||
    { echo "[${0##*/}] error: no debug component for $action" >&2; return 2; }
  # The explicit component beats the background-receiver rule; the action is
  # what the receiver checks first, so it must be on the intent too.
  emu shell am broadcast -n "$comp" -a "$action" "$@" 2>&1
}

# Waits for the server to log and listen on a port. Prints the port, returns 1
# on timeout. device_port returns 1 until the server is up, so the caller under
# `set -e` needs `|| true`.
wait_server_port() { # wait_server_port <timeout_s>
  local deadline=$(( $(date +%s) + $1 )) port
  while [ "$(date +%s)" -lt "$deadline" ]; do
    port="$(device_port || true)"
    [ -n "$port" ] && { echo "$port"; return 0; }
    sleep 1
  done
  return 1
}

# Restarts the app and with it its shell user service, the way start.sh starts
# it (force-stop, launch, wait for a listening port). The prefs - enabled,
# pairing - survive, so the new server answers the same key. True on success.
restart_server() {
  local pkg=dev.pocketdeck deadline
  step "restarting $pkg (the shell service is gone)"
  emu shell am force-stop "$pkg" >/dev/null 2>&1 || true
  for _ in $(seq 1 10); do
    emu shell am start -n "$pkg/.app.MainActivity" >/dev/null 2>&1 || true
    sleep 2
    [ -n "$(emu shell "pidof $pkg" 2>/dev/null | tr -d '\r')" ] && break
  done
  deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    device_port >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# Evidence for a service that died: the crash buffer and the app's own lines,
# bounded, under $AGENT_DIR. The .agent tree is ignored by git: this is never
# committed.
capture_crash() { # capture_crash <tag>
  local tag="$1"
  emu logcat -b crash -d > "$AGENT_DIR/crash-$tag.log" 2>/dev/null || true
  emu logcat -d -t 6000 2>/dev/null |
    grep -E 'PocketDeck|dev\.pocketdeck|AndroidRuntime|FATAL|MediaScanner|MediaProvider|am_crash' |
    tail -1000 > "$AGENT_DIR/logcat-$tag.log" || true
  step "wrote $AGENT_DIR/crash-$tag.log and $AGENT_DIR/logcat-$tag.log"
}
