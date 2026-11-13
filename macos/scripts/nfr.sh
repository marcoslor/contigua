#!/usr/bin/env bash
# nfr.sh — the non-functional gate (docs/NFR.md): the NFR K2 tests and the host
# e2e check `nfr`, one after the other. Every step takes the machine-wide lock
# (.work/heavy.sh, when the checkout has one) and gives it back before the next; nothing runs beside a build,
# an e2e run or another agent's heavy step.
#
#   macos/scripts/nfr.sh
#
# Environment: PD_E2E_PORT (default 47980) and PD_E2E_PROFILE (default nfr1);
# CONTIGUA_NFR_LIMITS overrides the limits file for both tiers.

set -uo pipefail

MACOS="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$MACOS/.." && pwd)"
# .work is gitignored, so a clone has no heavy.sh: then the steps run directly.
# Elsewhere it lives in the main checkout (CONTIGUA_HEAVY overrides).
_common="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _common=""
MAIN="$ROOT"
[ -n "$_common" ] && MAIN="$(cd "$_common/.." 2>/dev/null && pwd)"
[ -n "$MAIN" ] || MAIN="$ROOT"
HEAVY="${CONTIGUA_HEAVY:-$MAIN/.work/heavy.sh}"
[ -x "$HEAVY" ] || HEAVY="$ROOT/.work/heavy.sh"
[ -x "$HEAVY" ] || HEAVY=""
PORT="${PD_E2E_PORT:-47980}"
PROFILE="${PD_E2E_PROFILE:-nfr1}"

# The tests that own an NFR requirement in docs/NFR.md.
K2_FILTER="NFRTestLimits|BarContrastTests|BarTitleTests|SettingsLayoutTests|LayoutTests|HangingPeerTests|HonestSettingsTests|IconReferenceTests|ControlsRealPathTests"

fail=0
echo "== nfr: check-rules (changed lines, no build)"
if ! bash "$ROOT/scripts/check-rules.sh"; then
    fail=1
fi

echo "== nfr: K2 ($K2_FILTER)"
if ! ${HEAVY:+"$HEAVY"} bash -c "cd '$MACOS' && swift test --filter '$K2_FILTER'"; then
    fail=1
fi

echo "== nfr: e2e ($PROFILE on port $PORT)"
if ! ${HEAVY:+"$HEAVY"} bash -c "cd '$MACOS' && PD_E2E_PORT='$PORT' PD_E2E_PROFILE='$PROFILE' bash scripts/check-e2e.sh nfr"; then
    fail=1
fi

if [ "$fail" = "0" ]; then
    echo "nfr: PASS"
else
    echo "nfr: FAIL (docs/NFR.md names each requirement and its check)"
fi
exit "$fail"
