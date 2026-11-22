#!/usr/bin/env bash
# The preflight's boot-budget parser on a fixture ledger. The real ledger's
# fields are <date> <time> <worktree> <kind> <pid>; reading the name and kind
# from the wrong fields made a spent budget look free. Rig-only: no device.
set -u
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

tmp="$(mktemp "${TMPDIR:-/tmp}/pd-ledger.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'LEDGER'
10-20 03:48 files-s4 emulator 68519
10-20 04:37 nfr-checks emulator 97645
10-20 05:00 nfr-checks vm 1234
10-20 05:10 files-s5 emulator 4728
10-20 05:20 nfr-checks-2 emulator 999
10-20 05:30 nfr-checks emulator 4321
LEDGER

fail=0
check() {
  local want="$1" name="$2" got
  got="$(ledger_boots "$tmp" "$name")"
  if [ "$got" = "$want" ]; then
    echo "PREFLIGHT-TEST OK: $name -> $got"
  else
    echo "PREFLIGHT-TEST FAIL: $name -> $got, wanted $want"
    fail=1
  fi
}
check 2 nfr-checks
check 1 files-s4
check 1 files-s5
check 1 nfr-checks-2
check 0 nobody
check 0 ""

[ "$(ledger_boots /nonexistent nfr-checks)" = "0" ] \
  && echo "PREFLIGHT-TEST OK: missing ledger -> 0" \
  || { echo "PREFLIGHT-TEST FAIL: missing ledger"; fail=1; }

[ "$fail" = "0" ] && echo "PREFLIGHT-TEST PASS"
exit "$fail"
