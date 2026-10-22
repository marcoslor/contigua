#!/usr/bin/env bash
# test-check-rules.sh — the proof for scripts/check-rules.sh. For every rule it
# builds a scratch git repo in a temp dir and checks one violating line (flagged
# with its rule ID; exit 1 for a failure, 0 for a REVIEW line) and one allowed
# variant (an escape comment, a comment-only mention, a changed-or-unchanged
# legacy line). Nothing here touches this checkout.
#
#   scripts/test-check-rules.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check-rules.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-rules-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SRC=macos/Sources/PocketDeck
TESTS=macos/Tests/PocketDeckTests
KT_TEST=android/app/src/test/java/x
KT_MAIN=android/app/src/main/java/x

pass=0
failed=0
OUT=""
CODE=0
REPO=""

ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() {
    failed=$((failed + 1))
    echo "FAIL $1"
    printf '%s\n' "$OUT" | sed 's/^/     | /'
}

# The UX table that check-rules.sh parses for R-KEY-1 (docs/UX.md).
UX_TABLE='# PocketDeck — UX spec

## Keyboard shortcuts

| Shortcut | Action | Where |
| --- | --- | --- |
| ⌘K | Find Apps | View |
| ⌘F | Find in the Deck | Deck |
| ⌘− | Smaller | View |

## Copy rules
'

new_repo() {
    REPO="$WORK/$1"
    mkdir -p "$REPO/docs" "$REPO/$SRC" "$REPO/$TESTS" "$REPO/macos/scripts" \
        "$REPO/tools/emulator" "$REPO/$KT_TEST" "$REPO/$KT_MAIN"
    cd "$REPO" || exit 1
    git init -q -b main
    git config user.name test
    git config user.email test@example.invalid
    git config commit.gpgsign false
    printf '%s\n' "$UX_TABLE" > docs/UX.md
    printf 'let base = 1\n' > "$SRC/Base.swift"
    printf 'let baseTest = 1\n' > "$TESTS/BaseTests.swift"
    printf 'class BaseTest\n' > "$KT_TEST/BaseTest.kt"
    printf 'echo flow\n' > tools/emulator/flow.sh
    printf 'bad "[DECK-1] old check"\nok "[DECK-2] kept check"\n' > macos/scripts/check-e2e.sh
    printf '{\n  "app_list_ms": 1500,\n  "contrast_min": 3.0\n}\n' > macos/scripts/nfr-limits.json
    printf '# NFR\n\n| Connect | `connect_ms` = 1500 ms |\n' > docs/NFR.md
    # Legacy violations, committed before any change: they must never fail.
    printf 'let legacy: AnyView? = nil\nDispatchQueue.main.async {}\nlet first = try! load()\n' \
        > "$SRC/Legacy.swift"
    git add -A
    git commit -qm base
}

run_check() {
    OUT="$(cd "$REPO" && bash "$CHECK" "$@" 2>&1)"
    CODE=$?
}

# finds PATH RULE: OUT has a finding for RULE on PATH (FAIL or REVIEW form).
finds() {
    printf '%s\n' "$OUT" | grep -F -- "$1:" | grep -Eq ": $2( |\$)"
}

# expect NAME PATH RULE EXIT: RULE is flagged on PATH and the exit status is EXIT.
expect() {
    if finds "$2" "$3" && [ "$CODE" = "$4" ]; then
        ok "$1"
    else
        bad "$1 (want $3 on $2, exit $4; got exit $CODE)"
    fi
}

# expect_at NAME ERE EXIT: OUT matches the ERE and the exit status is EXIT.
expect_at() {
    if printf '%s\n' "$OUT" | grep -Eq "$2" && [ "$CODE" = "$3" ]; then
        ok "$1"
    else
        bad "$1 (want /$2/ and exit $3; got exit $CODE)"
    fi
}

# silent NAME PATH RULE: no RULE finding on PATH, and the script actually ran
# (127 = not found, 126 = not executable: a missing script must not pass).
silent() {
    if [ "$CODE" -ge 126 ]; then
        bad "$1 (script did not run, exit $CODE)"
    elif finds "$2" "$3"; then
        bad "$1 (flagged $3 on $2)"
    else
        ok "$1"
    fi
}

# exit_is NAME EXIT
exit_is() {
    if [ "$CODE" = "$2" ]; then ok "$1"; else bad "$1 (exit $CODE, want $2)"; fi
}

# --- Swift rules, on a tracked file that gains one line ---------------------

new_repo swift1
printf 'let g = GeometryReader { _ in EmptyView() }\n' >> "$SRC/Base.swift"
run_check
expect "R-SWIFT-1 flags a new GeometryReader" "$SRC/Base.swift" R-SWIFT-1 1
silent "legacy AnyView line is not flagged" "$SRC/Legacy.swift" R-SWIFT-2
silent "legacy GCD line is not flagged" "$SRC/Legacy.swift" R-SWIFT-3
silent "legacy try! line is not flagged" "$SRC/Legacy.swift" R-SWIFT-4
expect_at "summary says FAIL" "^check-rules: FAIL" 1

new_repo swift2
printf 'func view() -> AnyView { AnyView(EmptyView()) }\n' >> "$SRC/Base.swift"
run_check
expect "R-SWIFT-2 flags a new AnyView" "$SRC/Base.swift" R-SWIFT-2 1

new_repo swift2c
printf '// AnyView was removed; GeometryReader is gone\n' >> "$SRC/Base.swift"
run_check
silent "a comment that names AnyView is not code" "$SRC/Base.swift" R-SWIFT-2
silent "a comment that names GeometryReader is not code" "$SRC/Base.swift" R-SWIFT-1
exit_is "comment-only change passes" 0

new_repo swift3
printf 'DispatchQueue.main.async {}\n' >> "$SRC/Base.swift"
run_check
expect "R-SWIFT-3 flags a new DispatchQueue" "$SRC/Base.swift" R-SWIFT-3 1

new_repo swift3ok
printf 'DispatchQueue.main.async {} // gcd: AppKit callback arrives on the main queue\n' >> "$SRC/Base.swift"
run_check
silent "R-SWIFT-3 allowed with // gcd: reason" "$SRC/Base.swift" R-SWIFT-3
exit_is "gcd-allowed change passes" 0

new_repo swift4
printf 'let n = try! decode()\n' >> "$SRC/Base.swift"
run_check
expect "R-SWIFT-4 flags a new try!" "$SRC/Base.swift" R-SWIFT-4 1

new_repo swift4ok
printf 'let n = try! decode() // unrecoverable: the bundled JSON is checked at build time\n' >> "$SRC/Base.swift"
run_check
silent "R-SWIFT-4 allowed with // unrecoverable: reason" "$SRC/Base.swift" R-SWIFT-4
exit_is "unrecoverable-allowed change passes" 0

new_repo swift4f
printf 'fatalError("unreachable")\n' >> "$SRC/Base.swift"
run_check
expect "R-SWIFT-4 flags a new fatalError" "$SRC/Base.swift" R-SWIFT-4 1

new_repo swift5
printf '@Published var count = 0\n' >> "$SRC/Base.swift"
run_check
expect "R-SWIFT-5 flags a new @Published" "$SRC/Base.swift" R-SWIFT-5 1

# --- R-TEST-1: wall-clock sleeps in tests ----------------------------------

new_repo test1
printf 'try await Task.sleep(nanoseconds: 1_000)\n' >> "$TESTS/BaseTests.swift"
run_check
expect "R-TEST-1 flags Task.sleep in a Swift test" "$TESTS/BaseTests.swift" R-TEST-1 1

new_repo test1ok
printf 'try await Task.sleep(nanoseconds: 1_000) // real-time: the pointer needs a frame to settle\n' \
    >> "$TESTS/BaseTests.swift"
run_check
silent "R-TEST-1 allowed with // real-time: reason" "$TESTS/BaseTests.swift" R-TEST-1

new_repo test1kt
printf 'Thread.sleep(50)\n' > "$KT_TEST/Waits.kt"
run_check
expect "R-TEST-1 flags Thread.sleep in a Kotlin test" "$KT_TEST/Waits.kt" R-TEST-1 1

new_repo test1delay
printf 'fun w() = runBlocking {\n    delay(50)\n}\n' > "$KT_TEST/Waits.kt"
run_check
expect_at "R-TEST-1 flags delay() outside runTest, on its line" "Waits\.kt:2: R-TEST-1 " 1

new_repo test1virtual
printf 'class W {\n    @Test fun a() = runTest {\n        delay(50)\n    }\n}\n' > "$KT_TEST/Waits.kt"
run_check
silent "delay() inside runTest is virtual time" "$KT_TEST/Waits.kt" R-TEST-1
exit_is "runTest-only file passes" 0

# --- R-KEY-1: shortcuts must be in the docs/UX.md table ---------------------

new_repo key1
printf 'Button("Go") {}.keyboardShortcut("j", modifiers: [.command, .option])\n' > "$SRC/Panel2.swift"
run_check
expect "R-KEY-1 flags a shortcut missing from the table" "$SRC/Panel2.swift" R-KEY-1 1

new_repo key1ok
printf 'Button("Find") {}.keyboardShortcut("k")\n' > "$SRC/Panel2.swift"
run_check
silent "a shortcut listed in the table passes (⌘K)" "$SRC/Panel2.swift" R-KEY-1
exit_is "listed shortcut passes" 0

new_repo keymenu
printf 'Button("Go") {}.keyboardShortcut("j", modifiers: [.command, .option])\n' > "$SRC/MenuBar.swift"
run_check
silent "MenuBar.swift is exempt from R-KEY-1" "$SRC/MenuBar.swift" R-KEY-1

new_repo keymon
printf 'if keyCode == 38, flags.contains(.command) {\n    return nil\n}\n' > "$SRC/Panel2.swift"
run_check
expect "R-KEY-1 flags a key-monitor ⌘J missing from the table" "$SRC/Panel2.swift" R-KEY-1 1

new_repo keymonok
printf 'if keyCode == 3, flags.intersection([.command, .control, .option, .shift]) == .command {\n    return nil\n}\n' \
    > "$SRC/Panel2.swift"
run_check
silent "key monitor ⌘F (table row) passes" "$SRC/Panel2.swift" R-KEY-1

new_repo keyenclose
printf 'if flags.contains(.command) {\n    if keyCode == 38 {\n        return nil\n    }\n}\n' > "$SRC/Panel2.swift"
run_check
expect "R-KEY-1 reads ⌘ from the enclosing if" "$SRC/Panel2.swift" R-KEY-1 1

new_repo keynotable
printf '# UX\n' > docs/UX.md
printf 'Button("Find") {}.keyboardShortcut("k")\n' > "$SRC/Panel2.swift"
run_check
expect "R-KEY-1 flags a shortcut when docs/UX.md has no table" "$SRC/Panel2.swift" R-KEY-1 1

# --- R-PRIV-1: no personal values in log lines -------------------------------

new_repo priv1
printf 'logger.info("opened \\(fileName)")\n' > "$SRC/Log2.swift"
run_check
expect "R-PRIV-1 flags a Swift log of fileName" "$SRC/Log2.swift" R-PRIV-1 1

new_repo privprivate
printf 'logger.info("opened \\(fileName, privacy: .private)")\n' > "$SRC/Log2.swift"
run_check
silent "privacy: .private allowed" "$SRC/Log2.swift" R-PRIV-1

new_repo privlogok
printf 'logger.info("opened \\(fileName)") // log-ok: fixture name, not a person'"'"'s file\n' > "$SRC/Log2.swift"
run_check
silent "// log-ok: reason allowed" "$SRC/Log2.swift" R-PRIV-1

new_repo privcount
printf 'logger.info("sent \\(messageCount) items")\n' > "$SRC/Log2.swift"
run_check
silent "a count named messageCount is not personal" "$SRC/Log2.swift" R-PRIV-1

new_repo privkt
printf 'Log.d("PD", "playing $title")\n' > "$KT_MAIN/Log2.kt"
run_check
expect "R-PRIV-1 flags a Kotlin Log of title" "$KT_MAIN/Log2.kt" R-PRIV-1 1

# --- R-SUPP-1 and R-CHECK-1 are REVIEW lines: exit 0 -------------------------

new_repo supp
printf '// swiftlint:disable:next force_cast\n' >> "$SRC/Base.swift"
run_check
expect_at "R-SUPP-1 prints a REVIEW line" "Base\.swift:[0-9]+: R-SUPP-1 REVIEW " 0
expect_at "summary asks for the reviewer's sign-off" "sign-off" 0

new_repo checkremoved
printf 'ok "[DECK-2] kept check"\n' > macos/scripts/check-e2e.sh
run_check
expect_at "R-CHECK-1 REVIEW for a removed bad/ok line" "check-e2e\.sh:[0-9]+: R-CHECK-1 REVIEW .*DECK-1" 0

new_repo checkskip
printf 'echo "SKIP: no device"\n' >> tools/emulator/flow.sh
run_check
expect_at "R-CHECK-1 REVIEW for a new SKIP" "flow\.sh:[0-9]+: R-CHECK-1 REVIEW " 0

new_repo checkskipcomment
printf '# a quiet launch is not one, so the step prints SKIP here\n' >> macos/scripts/check-e2e.sh
run_check
silent "a comment that mentions SKIP is not a new skip" macos/scripts/check-e2e.sh R-CHECK-1
exit_is "comment-only SKIP mention passes" 0

new_repo checklimit
printf '{\n  "app_list_ms": 3000,\n  "contrast_min": 3.0\n}\n' > macos/scripts/nfr-limits.json
run_check
expect_at "R-CHECK-1 REVIEW for a raised limit" "nfr-limits\.json:[0-9]+: R-CHECK-1 REVIEW .*app_list_ms" 0

new_repo checknfr
printf '# NFR\n\n| Connect | `connect_ms` = 3000 ms |\n' > docs/NFR.md
run_check
expect_at "R-CHECK-1 REVIEW for a changed NFR number" "NFR\.md:[0-9]+: R-CHECK-1 REVIEW " 0

# --- Legacy: only changed lines are checked ----------------------------------

new_repo legacy
printf 'let legacy: AnyView? = nil\nDispatchQueue.main.async {}\nlet first = try! load()\nlet extra = 2\n' \
    > "$SRC/Legacy.swift"
run_check
silent "unchanged legacy AnyView not flagged after an unrelated edit" "$SRC/Legacy.swift" R-SWIFT-2
silent "unchanged legacy try! not flagged after an unrelated edit" "$SRC/Legacy.swift" R-SWIFT-4
exit_is "unrelated edit to legacy file passes" 0

new_repo legacychanged
printf 'let legacy: AnyView? = .none\n' > "$SRC/Legacy.swift.new"
mv "$SRC/Legacy.swift.new" "$SRC/Legacy.swift"
printf 'DispatchQueue.main.async {}\nlet first = try! load()\n' >> "$SRC/Legacy.swift"
run_check
expect "a changed legacy line is flagged" "$SRC/Legacy.swift" R-SWIFT-2 1

# --- Modes ------------------------------------------------------------------

new_repo allmode
run_check --all
exit_is "--all never fails on legacy code" 0
expect_at "--all counts R-SWIFT-2 legacy lines" "^ *R-SWIFT-2 +1$" 0

new_repo clean
printf 'let ok = 1\n' >> "$SRC/Base.swift"
run_check
expect_at "clean change prints PASS" "^check-rules: PASS" 0

new_repo baseflag
printf 'let g = GeometryReader { _ in EmptyView() }\n' >> "$SRC/Base.swift"
(cd "$REPO" && git add -A && git commit -qm change)
run_check
silent "committed change is not flagged against main" "$SRC/Base.swift" R-SWIFT-1
run_check --base HEAD~1
expect "--base REF checks against that ref" "$SRC/Base.swift" R-SWIFT-1 1

echo
if [ "$failed" -gt 0 ]; then
    echo "test-check-rules: FAIL ($failed of $((pass + failed)) checks failed)"
    exit 1
fi
echo "test-check-rules: PASS ($pass checks)"
