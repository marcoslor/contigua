#!/usr/bin/env bash
# vm-e2e.sh — run the macOS e2e suite inside the headless pd-e2e VM, so its
# windows, displays and focus changes never touch the user's session.
#
#   macos/scripts/vm-e2e.sh <check|all>
#
# The app bundle is built on the host (the guest never runs swift build) and
# pushed in along with the tree and tools/fakephone; the guest compiles only
# the small swiftc helpers check-e2e.sh needs. PD_E2E_VISIBLE=1 by default:
# inside the VM nobody is typing, so the real-input checks run too. Set
# PD_VM_VISIBLE=0 for a quiet run.
#
# Boot, run and stop happen inside the machine-wide heavy lock (RULES.md 14),
# after the memory gate. The run's output is copied back to
# macos/build/vm-e2e/<check>/run.log, the guest's work dir to work/ next to it.
# Exit code is the check's.
set -uo pipefail
MACOS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
# shellcheck source=vm-common.sh
. "$MACOS/scripts/vm-common.sh"

usage="usage: vm-e2e.sh [qr|pair|tls|render|resize|input|mouseback|input-global|pause|direct|nav|mirror|spotlight|pinch|chrome|trackpad|clip|sharein|links|share|apk|drop|dock|nickname|notify|audio|handoff|deck|all]"
which_check="${1:-}"
case "$which_check" in
    qr|pair|tls|render|resize|input|mouseback|input-global|pause|direct|nav|mirror|spotlight|pinch|chrome|trackpad|clip|sharein|links|share|apk|drop|dock|nickname|notify|audio|handoff|deck|all) ;;
    *) say "$usage"; exit 2 ;;
esac

vm_exists || { say "no VM '$VM'; run macos/scripts/vm-prepare.sh first"; exit 3; }
[ -f "$VM_KEY" ] || { say "no ssh key at $VM_KEY; run macos/scripts/vm-prepare.sh first"; exit 3; }

VISIBLE="${PD_VM_VISIBLE:-1}"
OUT="$MACOS/build/vm-e2e/$which_check"
rm -rf "$OUT"
mkdir -p "$OUT"

heavy_lock
trap 'vm_stop; heavy_unlock' EXIT
memory_gate || exit 3

if vm_running; then
    say "$VM was left running; stopping it"
    vm_stop
fi

say "building build/e2e/PocketDeck.app on the host"
if ! "$MACOS/scripts/bundle.sh" "$MACOS/build/e2e/PocketDeck.app" --variant e2e > "$OUT/host-build.log" 2>&1; then
    say "host build failed; see $OUT/host-build.log"; tail -5 "$OUT/host-build.log"; exit 3
fi

VM_LOG="$OUT/tart-run.log"
vm_boot || exit 3

say "copying the tree into the guest ($VM_ROOT)"
rsync_to_guest "$MACOS/" "$VM_ROOT/macos/" --exclude '/build/' --exclude '/.build/' || { say "tree copy failed"; exit 3; }
rsync_to_guest "$MACOS/build/e2e/" "$VM_ROOT/macos/build/e2e/" || { say "app copy failed"; exit 3; }
rsync_to_guest "$ROOT/tools/fakephone/" "$VM_ROOT/tools/fakephone/" || { say "fakephone copy failed"; exit 3; }

say "running '$which_check' in the guest (visible=$VISIBLE, port $VM_PORT)"
# PATH: Homebrew's python3/ffmpeg first; the guest's sshd gives no login PATH.
run_cmd="cd $VM_ROOT/macos && env PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
PD_E2E_PORT=$VM_PORT PD_E2E_VISIBLE=$VISIBLE \
PD_E2E_PREBUILT=$VM_ROOT/macos/build/e2e/PocketDeck.app \
PD_FAKE_TLS_PYTHON=/opt/homebrew/bin/python3 \
bash scripts/check-e2e.sh $which_check"
ssh_guest "$run_cmd" 2>&1 | tee "$OUT/run.log"
rc=${PIPESTATUS[0]}

work_guest="/tmp/pocketdeck-e2e-$VM_PORT"
if ssh_guest "test -d $work_guest" 2>/dev/null; then
    say "copying the run's work dir back"
    rsync_from_guest "$work_guest/" "$OUT/work/" || say "work dir copy failed"
fi

vm_stop
say ""
say "vm-e2e: $which_check exit=$rc (visible=$VISIBLE); log $OUT/run.log"
printf '%s\n' "-- summary lines --"
grep -E 'passed=|^QUIET|^LOAD|^SKIP' "$OUT/run.log" | tail -n 40
exit "$rc"
