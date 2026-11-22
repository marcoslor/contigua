#!/usr/bin/env bash
# install.sh's shell checks: the default carries the Finder files extension,
# --without-files is an explicit opt-out that says what is missing, and a stage
# without the extension never replaces a working installed copy. No build, no
# /Applications, no LaunchServices or PlugInKit registration.
#
#   bash macos/scripts/install_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/contigua-install-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAILS=0
pass() { echo "PASS $*"; }
fail() { FAILS=$((FAILS + 1)); echo "FAIL $*"; }
expect_contains() { # expect_contains <text> <needle> <name>
    case "$1" in
        *"$2"*) pass "$3" ;;
        *) fail "$3: missing '$2' in: $(printf '%s' "$1" | tr '\n' ' ')" ;;
    esac
}

bash -n scripts/install.sh && pass "bash -n scripts/install.sh" || fail "bash -n"

set +e
out="$(bash scripts/install.sh --dry-run 2>&1)"
code=$?
set -e
[ "$code" = 0 ] && pass "the dry run exits 0" || fail "dry run exit $code: $out"
expect_contains "$out" "--with-files" "the default dry run builds the Files extension"
expect_contains "$out" "would require Contents/PlugIns/Files.appex" "the default requires the extension"

set +e
out="$(bash scripts/install.sh --dry-run --without-files 2>&1)"
code=$?
set -e
[ "$code" = 0 ] && pass "--without-files dry run exits 0" || fail "without-files dry run exit $code: $out"
expect_contains "$out" "no Finder files extension" "--without-files warns"
expect_contains "$out" "not required" "--without-files does not require the extension"

set +e
bash scripts/install.sh --dry-run --with-files --without-files >/dev/null 2>&1
code=$?
set -e
[ "$code" = 2 ] && pass "both flags exit 2" || fail "both flags exit $code, want 2"

# A stage without the extension must not replace a working installed copy.
mkdir -p "$TMP/stage-bad/Contents/PlugIns"
mkdir -p "$TMP/dest/Contigua.app"
echo keep > "$TMP/dest/Contigua.app/marker"
set +e
out="$(CONTIGUA_INSTALL_DIR="$TMP/dest" CONTIGUA_INSTALL_STAGE="$TMP/stage-bad" \
    CONTIGUA_INSTALL_NO_BUILD=1 CONTIGUA_E2E_LOCK="$TMP/no-e2e-lock" \
    bash scripts/install.sh 2>&1)"
code=$?
set -e
[ "$code" = 1 ] && pass "a stage without Files.appex is refused" || fail "exit $code, want 1"
expect_contains "$out" "has no Contents/PlugIns/Files.appex" "the refusal names the extension"
[ -f "$TMP/dest/Contigua.app/marker" ] \
    && pass "the installed copy is untouched" || fail "the installed copy was replaced"

# --without-files installs the same stage, with the warning.
set +e
out="$(CONTIGUA_INSTALL_DIR="$TMP/dest2" CONTIGUA_INSTALL_STAGE="$TMP/stage-bad" \
    CONTIGUA_INSTALL_NO_BUILD=1 CONTIGUA_E2E_LOCK="$TMP/no-e2e-lock" \
    bash scripts/install.sh --without-files 2>&1)"
code=$?
set -e
[ "$code" = 0 ] && pass "--without-files installs the stage" || fail "--without-files exit $code: $out"
[ -d "$TMP/dest2/Contigua.app" ] && pass "the destination exists" || fail "no destination"
expect_contains "$out" "without Finder files" "the install warns what is missing"

echo
if [ "$FAILS" -eq 0 ]; then
    echo "install_test: PASS"
    exit 0
fi
echo "install_test: FAIL ($FAILS check(s))"
exit 1
