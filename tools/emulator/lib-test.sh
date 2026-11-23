#!/usr/bin/env bash
# The shared rig helpers on fixtures. No device, no boot.
#
# `start.sh` runs under `set -euo pipefail`: a parser that stops reading at its
# first match can leave the producer writing into a closed pipe, and pipefail
# then ends the boot with no message (#207). The long fixture below prints many
# matches: sed keeps writing after `head -1` is gone and dies of SIGPIPE.
set -u
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=tools/emulator/lib.sh
. tools/emulator/lib.sh

fail=0
check() { # check <want> <name> <input>
  local want="$1" name="$2" input="$3" got
  got="$(printf '%s' "$input" | shizuku_code_path)"
  if [ "$got" = "$want" ]; then
    echo "LIB-TEST OK: $name -> '$got'"
  else
    echo "LIB-TEST FAIL: $name -> '$got', wanted '$want'"
    fail=1
  fi
}

check "/data/app/one" "the first of two" 'codePath=/data/app/one
codePath=/data/app/two
'
check "/data/app/one" "a CRLF line" $'codePath=/data/app/one\r\n'
check "" "no codePath" 'Package [com.example]
  userId=10123
'

# A failed adb read stops with its status, never an empty path and no message:
# under `set -e` an `emu` that times out (124) ended start.sh silently (#207).
err="$(mktemp)"
emu() { return 124; }
if got="$(package_code_path moe.shizuku.privileged.api 2>"$err")"; then
  echo "LIB-TEST FAIL: a failed dumpsys read as '$got'"
  fail=1
elif grep -q 'status 124' "$err"; then
  echo "LIB-TEST OK: a failed dumpsys says its status"
else
  echo "LIB-TEST FAIL: a failed dumpsys said '$(cat "$err")', wanted its status"
  fail=1
fi
emu() { printf 'Packages:\r\n  codePath=/data/app/shizuku\r\n'; }
if got="$(package_code_path moe.shizuku.privileged.api 2>"$err")" && [ "$got" = "/data/app/shizuku" ]; then
  echo "LIB-TEST OK: a dumpsys read -> '$got'"
else
  echo "LIB-TEST FAIL: a dumpsys read -> '${got:-}' ($(cat "$err"))"
  fail=1
fi
# The installed versionCode read, one step earlier in start.sh, fails the same
# way: a timed-out read stops with its status, never an empty code.
emu() { return 124; }
if got="$(installed_version_code com.example 2>"$err")"; then
  echo "LIB-TEST FAIL: a failed versionCode read as '$got'"
  fail=1
elif grep -q 'status 124' "$err"; then
  echo "LIB-TEST OK: a failed versionCode read says its status"
else
  echo "LIB-TEST FAIL: a failed versionCode read said '$(cat "$err")', wanted its status"
  fail=1
fi
emu() { printf 'Packages:\r\n  versionCode=42 minSdk=29\r\n  versionCode=7\r\n'; }
if got="$(installed_version_code com.example 2>"$err")" && [ "$got" = "42" ]; then
  echo "LIB-TEST OK: a versionCode read -> '$got'"
else
  echo "LIB-TEST FAIL: a versionCode read -> '${got:-}' ($(cat "$err"))"
  fail=1
fi
rm -f "$err"

# The regression: more matches than a pipe's buffer, after the one head kept.
set -o pipefail
dumpsys_fixture() {
  printf 'codePath=/data/app/first\n'
  seq 1 50000 | sed 's|^|codePath=/data/app/filler-|'
}
if got="$(dumpsys_fixture | shizuku_code_path)"; then
  if [ "$got" = "/data/app/first" ]; then
    echo "LIB-TEST OK: a long dumpsys stays open -> '$got'"
  else
    echo "LIB-TEST FAIL: a long dumpsys -> '$got', wanted '/data/app/first'"
    fail=1
  fi
else
  status=$?
  echo "LIB-TEST FAIL: a long dumpsys killed the pipeline (status $status)"
  fail=1
fi

[ "$fail" = "0" ] && echo "LIB-TEST PASS"
exit "$fail"
