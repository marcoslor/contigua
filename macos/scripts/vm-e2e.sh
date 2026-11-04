#!/usr/bin/env bash
# vm-e2e.sh — run the macOS e2e suite inside the headless pd-e2e VM, so its
# windows, displays and focus changes never touch the user's session.
#
#   macos/scripts/vm-e2e.sh <check>
#   macos/scripts/vm-e2e.sh <check>[,<check>...]
#   macos/scripts/vm-e2e.sh all
#   macos/scripts/vm-e2e.sh --check <check>[,<check>...]   (rehearse, no boot)
#
# A comma list runs those checks one after another in ONE boot, each with its
# own log, PASS/FAIL and `passed=`/`failed=` lines: a boot is the expensive
# part, and the checks are independent processes either way (the host runs
# them the same way).
#
# The app bundle is built on the host (the guest never runs swift build) and
# pushed in along with the tree and tools/fakephone; the guest compiles only
# the small swiftc helpers check-e2e.sh needs. PD_E2E_VISIBLE=1 by default:
# inside the VM nobody is typing, so the real-input checks run too. Set
# PD_VM_VISIBLE=0 for a quiet run.
#
# Boot, run and stop happen inside the machine-wide heavy lock (RULES.md 14),
# after the memory gate. The run's output is copied back to
# macos/build/vm-e2e/<list>/ (run.log, work/ for a single check; checks/<name>/
# run.log + work/ for a list). Exit code is the check's, or the number of
# failed checks for a list (0 when all passed).
#
# A visible run's review shots (work/shots/*.png and their .json reports) are
# copied out to PD_VM_SHOT_DIR/<appearance>/ while the heavy lock is still
# held, before the next boot's `rm -rf` of the output dir: a lost work dir must
# never lose the shots again. PD_VM_SHOT_DIR defaults to
# $ROOT/.agent/mw-mac/shots/r5b; the destination is merged into, never
# removed, so no boot deletes an earlier boot's copy.
set -uo pipefail
MACOS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
# shellcheck source=vm-common.sh
. "$MACOS/scripts/vm-common.sh"
# shellcheck source=e2e-checks.sh
. "$MACOS/scripts/e2e-checks.sh"

usage="usage: vm-e2e.sh <check>[,<check>...]|all   (checks: $(check_list))"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=1
    shift
fi
raw="${1:-}"
[ -n "$raw" ] || { say "$usage"; exit 2; }

# Split on commas (read -a: the host's bash 3.2 has no readarray).
CHECKS=()
IFS=, read -r -a CHECKS <<< "$raw"
for c in "${CHECKS[@]}"; do
    [ -n "$c" ] || { say "empty check in '$raw'"; say "$usage"; exit 2; }
    if [ "$c" = all ]; then
        [ "$raw" = all ] || { say "'all' cannot be combined with other checks"; exit 2; }
    elif ! valid_check "$c"; then
        say "unknown check '$c'"; say "$usage"; exit 2
    fi
done
[ "${#CHECKS[@]}" -gt 0 ] || { say "$usage"; exit 2; }

# One appearance per boot: a mid-run appearance flip made round 3's shots come
# out with the previous look, and a boot is the expensive part.
case "${PD_E2E_SHOT_APPEARANCE:-dark}" in
    dark|light) SHOT_APPEARANCE="${PD_E2E_SHOT_APPEARANCE:-dark}" ;;
    *) say "PD_E2E_SHOT_APPEARANCE must be dark or light (got '${PD_E2E_SHOT_APPEARANCE:-}')"; exit 2 ;;
esac

vm_exists || { say "no VM '$VM'; run macos/scripts/vm-prepare.sh first"; exit 3; }
[ -f "$VM_KEY" ] || { say "no ssh key at $VM_KEY; run macos/scripts/vm-prepare.sh first"; exit 3; }
if [ "$CHECK_ONLY" = 1 ]; then
    # Rehearsal: the same arguments and paths a boot would use, without
    # taking the lock or starting the VM (a boot is budgeted).
    say "rehearsal ok: $raw (profile ${PD_E2E_PROFILE:-e2e}, visible ${PD_VM_VISIBLE:-1}, appearance ${PD_E2E_SHOT_APPEARANCE:-dark}, port $VM_PORT)"
    exit 0
fi

VISIBLE="${PD_VM_VISIBLE:-1}"
slug="${raw//,/+}"
OUT="$MACOS/build/vm-e2e/$slug"
rm -rf "$OUT"
mkdir -p "$OUT"

memory_gate || exit 3

heavy_lock
trap 'vm_stop; heavy_unlock' EXIT

if vm_running; then
    say "$VM was left running; stopping it"
    vm_stop
fi

say "building build/e2e/PocketDeck.app on the host"
# The File Provider extension is opt-in: only the bundle for a files-domain
# run carries it (a host run must have nothing to register).
files_flag=()
controls_flag=()
for c in "${CHECKS[@]}"; do
    case "$c" in
        files-domain|files-thumbs) files_flag=(--with-files) ;;
        controls) controls_flag=(--with-controls) ;;
    esac
done
if ! "$MACOS/scripts/bundle.sh" "$MACOS/build/e2e/PocketDeck.app" --variant e2e \
        ${files_flag[@]+"${files_flag[@]}"} ${controls_flag[@]+"${controls_flag[@]}"} > "$OUT/host-build.log" 2>&1; then
    say "host build failed; see $OUT/host-build.log"; tail -5 "$OUT/host-build.log"; exit 3
fi

VM_LOG="$OUT/tart-run.log"
vm_boot || exit 3

say "copying the tree into the guest ($VM_ROOT)"
rsync_to_guest "$MACOS/" "$VM_ROOT/macos/" --exclude '/build/' --exclude '/.build/' || { say "tree copy failed"; exit 3; }
rsync_to_guest "$MACOS/build/e2e/" "$VM_ROOT/macos/build/e2e/" || { say "app copy failed"; exit 3; }
rsync_to_guest "$ROOT/tools/fakephone/" "$VM_ROOT/tools/fakephone/" || { say "fakephone copy failed"; exit 3; }

say "running ${CHECKS[*]} in the guest (visible=$VISIBLE, port $VM_PORT)"
# check-e2e.sh must run as the logged-in admin inside the console (Aqua)
# session: `windows`, screencapture -l and the app's windows only exist there.
# ssh lands in its own session, so launchctl asuser moves the run into the
# GUI session. PATH: Homebrew first (sshd gives no login PATH).
cat > "$OUT/run-check.sh" <<'EOS'
#!/bin/bash
# Generated by vm-e2e.sh; runs inside the guest. $1 visible, $2 port,
# $3 profile, $4... checks. Each check gets its own log and work dir under
# /tmp/pd-e2e-artifacts.
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")/macos" || exit 3
# The guest's display must stay awake for the whole run: a sleeping display
# makes screencapture fail and can hold an NSMenu tracking loop (round 3's
# wedge). caffeinate runs in this GUI session and is stopped with the script.
caffeinate -dimsu &
caffeinate_pid=$!
trap 'kill "$caffeinate_pid" 2>/dev/null' EXIT INT TERM
visible="$1"
port="$2"
profile="$3"
shift 3
export PD_E2E_PORT="$port"
export PD_E2E_PROFILE="$profile"
export PD_E2E_VISIBLE="$visible"
# PD_E2E_IN_VM: the checks that need something this guest lacks (XCTest) can
# skip instead of failing; a host run never sets it.
export PD_E2E_IN_VM=1
export PD_E2E_PREBUILT="$(dirname "$0")/macos/build/e2e/PocketDeck.app"
export PD_FAKE_TLS_PYTHON=/opt/homebrew/bin/python3
# PD_VM_FAKE_DEBUG=1 makes the guest's fakephone print its session diagnostics
# to fake.err (the shared phone keeps them for the whole run), for diagnosing a
# session that ends on its own.
[ "${PD_VM_FAKE_DEBUG:-0}" = 1 ] && export FAKE_DEBUG=1
art="/tmp/pd-e2e-artifacts-$port"
rm -rf "$art"
# The guest boots headless (`tart run --no-graphics`) at the resolution it
# last had: tart's --display hint sizes a host window a headless run never
# opens. The checks are written for a 2x screen, so pd-screens picks the
# tallest 2x mode the guest offers (and reports the screen); when none is tall
# enough for C6's tall window, PD_E2E_TALL_SCREEN=0 makes that one step skip
# with the reason instead of failing.
if swiftc -O scripts/pd-screens.swift -o /tmp/pd-screens 2>/tmp/pd-screens-build.log; then
    if /tmp/pd-screens --min-visible-height 960 --scale 2; then
        export PD_E2E_TALL_SCREEN=1
    else
        export PD_E2E_TALL_SCREEN=0
    fi
else
    echo "pd-screens did not build:"; tail -3 /tmp/pd-screens-build.log
    export PD_E2E_TALL_SCREEN=0
fi
failed=0
last=0
for check in "$@"; do
    echo "===== $check ====="
    mkdir -p "$art/$check"
    # /bin/bash, like the host: the guest's bash 3.2 is the same one a run on
    # the Mac uses, so the VM reproduces the host's behaviour, not its own.
    # A check that hangs still ends here (PD_VM_CHECK_SECS, default 40 min), so
    # its work dir comes back to the host instead of dying with the session.
    perl -e 'alarm shift; exec @ARGV' "${PD_VM_CHECK_SECS:-2400}" \
        /bin/bash scripts/check-e2e.sh "$check" 2>&1 | tee "$art/$check/run.log"
    last=${PIPESTATUS[0]}
    [ "$last" = 0 ] || failed=$((failed + 1))
    work="/tmp/pocketdeck-e2e-$port"
    [ -d "$work" ] && cp -R "$work" "$art/$check/work"
    echo "vm-check $check exit=$last"
done
# The guest's session log for the run, for a post-mortem: state changes,
# transport errors and watchdog lines only (no clipboard or notification
# text). The checks' own logs are already in $art.
log show --last 45m --style compact --predicate 'subsystem == "dev.pocketdeck.mac"' 2>/dev/null \
    | grep -E 'session|tls|watchdog|connect' | grep -vE 'clip|notif' > "$art/session.log" || true
if [ "$#" = 1 ]; then exit "$last"; fi
exit "$failed"
EOS

rsync_to_guest "$OUT/run-check.sh" "$VM_ROOT/run-check.sh" || { say "run-check copy failed"; exit 3; }
run_cmd="sudo launchctl asuser \$(id -u) sudo -u admin env PD_VM_CHECK_SECS=${PD_VM_CHECK_SECS:-2400} PD_E2E_SHOT_APPEARANCE=${PD_E2E_SHOT_APPEARANCE:-dark} bash $VM_ROOT/run-check.sh $VISIBLE $VM_PORT ${PD_E2E_PROFILE:-e2e} ${CHECKS[*]}"
ssh_guest "$run_cmd" 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}

art_guest="/tmp/pd-e2e-artifacts-$VM_PORT"
if ssh_guest "test -d $art_guest" 2>/dev/null; then
    say "copying the run's work dir back"
    if [ "${#CHECKS[@]}" = 1 ]; then
        if ssh_guest "test -d $art_guest/${CHECKS[0]}/work" 2>/dev/null; then
            rsync_from_guest "$art_guest/${CHECKS[0]}/work/" "$OUT/work/" || say "work dir copy failed"
        fi
    else
        rsync_from_guest "$art_guest/" "$OUT/checks/" || say "work dir copy failed"
    fi
fi
# The guest's session log is one file for the whole run (an `all` is one
# process, so its work dir is the last check's): keep it next to the log.
if ssh_guest "test -f $art_guest/session.log" 2>/dev/null; then
    rsync_from_guest "$art_guest/session.log" "$OUT/session.log" || say "session log copy failed"
fi

# The review shots and their sidecar reports leave the work dir here, still
# inside the heavy lock: this is the last moment before the next boot's
# `rm -rf "$OUT"` can lose them (round 5). One folder per appearance, and the
# helper merges instead of replacing, so boot 9 cannot delete boot 8's set.
shot_root="${PD_VM_SHOT_DIR:-$ROOT/.agent/mw-mac/shots/r5b}"
shot_dest="$shot_root/$SHOT_APPEARANCE"
shot_rc=0
if [ "${#CHECKS[@]}" = 1 ]; then
    vm_copy_shots "$OUT/work/shots" "$shot_dest" || shot_rc=1
else
    for c in "${CHECKS[@]}"; do
        vm_copy_shots "$OUT/checks/$c/work/shots" "$shot_dest/$c" || shot_rc=1
    done
fi
[ "$shot_rc" = 0 ] || { say "FAIL the review shots did not leave the work dir"; [ "$rc" = 0 ] && rc=3; }

vm_stop
say ""
say "vm-e2e: ${CHECKS[*]} exit=$rc (visible=$VISIBLE); log $OUT/run.log"
for c in "${CHECKS[@]}"; do
    log="$OUT/run.log"
    [ "${#CHECKS[@]}" = 1 ] || log="$OUT/checks/$c/run.log"
    printf '%s\n' "-- summary: $c --"
    if [ -f "$log" ]; then
        grep -E 'passed=|^QUIET|^LOAD' "$log" | tail -n 5
        grep -E '^FAIL' "$log" | tail -n 20
    else
        say "no log for $c"
    fi
done
exit "$rc"
