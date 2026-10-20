#!/usr/bin/env bash
# nfr.sh — the non-functional gate (docs/NFR.md): the NFR K2 tests and the host
# e2e check `nfr`, one after the other. Every step takes the machine-wide lock
# (heavy.sh) and gives it back before the next; nothing runs beside a build,
# an e2e run or another agent's heavy step.
#
#   macos/scripts/nfr.sh
#
# Environment: PD_E2E_PORT (default 47980) and PD_E2E_PROFILE (default nfr1);
# POCKETDECK_NFR_LIMITS overrides the limits file for both tiers.

set -uo pipefail

MACOS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
# .agent is not part of a checkout's git tree; the lock lives in the main one.
HEAVY="${POCKETDECK_HEAVY:-$HOME/dev/pocketdeck/.agent/heavy.sh}"
[ -x "$HEAVY" ] || HEAVY="$ROOT/.agent/heavy.sh"
if [ ! -x "$HEAVY" ]; then
    echo "nfr: no heavy.sh at $HEAVY (set POCKETDECK_HEAVY)" >&2
    exit 3
fi
PORT="${PD_E2E_PORT:-47980}"
PROFILE="${PD_E2E_PROFILE:-nfr1}"

# The tests that own an NFR requirement in docs/NFR.md.
K2_FILTER="NFRTestLimits|BarContrastTests|SettingsLayoutTests|LayoutTests|HangingPeerTests|HonestSettingsTests|IconReferenceTests|ControlsRealPathTests"

fail=0
echo "== nfr: K2 ($K2_FILTER)"
if ! "$HEAVY" bash -c "cd '$MACOS' && swift test --filter '$K2_FILTER'"; then
    fail=1
fi

echo "== nfr: e2e ($PROFILE on port $PORT)"
if ! "$HEAVY" bash -c "cd '$MACOS' && PD_E2E_PORT='$PORT' PD_E2E_PROFILE='$PROFILE' ./scripts/check-e2e.sh nfr"; then
    fail=1
fi

if [ "$fail" = "0" ]; then
    echo "nfr: PASS"
else
    echo "nfr: FAIL (docs/NFR.md names each requirement and its check)"
fi
exit "$fail"
