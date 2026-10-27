#!/bin/bash
# menubar-toggle.sh — the menu bar icon's click, end to end, with real input.
#
# The person's report (2026-10-22): the first click opens the panel, and a
# second click never closes it. The bug lives in the click itself, so the check
# is a real CGEvent click at the item's frame, found by the app's process id.
# The 2026-10-27 change moved Settings…/Quit to a secondary click, so the same
# real click is used with the right button: it must open the menu, not toggle
# the panel (CONV-MAC-10).
#
# Real input moves the pointer, so this script never runs inside check-e2e's
# quiet mode: it takes the e2e lock itself and is run by hand (or from a
# visible run), one run at a time:
#
#   macos/scripts/bundle.sh macos/build/e2e/PocketDeck.app --variant e2e
#   ~/dev/pocketdeck/.agent/heavy.sh macos/scripts/menubar-toggle.sh
#
# It prints one line per step, check-e2e style, and exits non-zero on a FAIL.
# Never touches /Applications/PocketDeck.app or the person's own item: the app
# it clicks is the e2e bundle, and its item is the one AXExtrasMenuBar reports
# for that process.
set -u
MACOS="$(cd "$(dirname "$0")/.." && pwd)"
APP="${PD_E2E_APP:-$MACOS/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck}"
PROFILE="${PD_E2E_PROFILE:-mirrorsingle}"
LOCK=/tmp/pocketdeck-e2e.lock
WORK="${PD_E2E_WORK:-${TMPDIR:-/tmp}}/pocketdeck-menubar-toggle"
PASS=0
FAIL=0

say() { echo "$*"; }
ok() { say "ok: $*"; PASS=$((PASS + 1)); }
bad() { say "FAIL: $*"; FAIL=$((FAIL + 1)); }

[ -x "$APP" ] || { say "no e2e app at $APP (bundle it first)"; exit 2; }
mkdir -p "$WORK"

# The lock is a directory with the holder's pid, as check-e2e leaves it.
waited=0
while ! mkdir "$LOCK" 2>/dev/null; do
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    sleep 2
    waited=$((waited + 2))
    [ "$waited" -gt 300 ] && { say "the e2e lock was busy for 5 minutes"; exit 3; }
done
echo $$ > "$LOCK/pid"

APP_PID=""
cleanup() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null
        wait "$APP_PID" 2>/dev/null
    fi
    rm -rf "$LOCK"
}
trap cleanup EXIT

HELPER="$WORK/menubar-item"
if [ ! -x "$HELPER" ] || [ "$MACOS/scripts/menubar-item.swift" -nt "$HELPER" ]; then
    swiftc -O "$MACOS/scripts/menubar-item.swift" -o "$HELPER" > "$WORK/helper.log" 2>&1 \
        || { say "could not build menubar-item.swift:"; tail -5 "$WORK/helper.log"; exit 2; }
fi

"$APP" --profile "$PROFILE" --background > "$WORK/app.log" 2>&1 &
APP_PID=$!

# The item is inserted once the run loop is up; the Deck may still be opening.
frame=""
for _ in $(seq 1 30); do
    frame="$("$HELPER" frame "$APP_PID" 2>/dev/null)" && [ -n "$frame" ] && break
    sleep 0.5
done
[ -n "$frame" ] || { say "no menu bar item for pid $APP_PID"; exit 1; }
say "item: $frame (pid $APP_PID, profile $PROFILE)"

# wait_for <panel|menu> <shown|gone> — the window settles within a click's
# animation.
wait_for() {
    local what="$1" want="$2" seen=""
    for _ in $(seq 1 40); do
        seen="$("$HELPER" "$what" "$APP_PID")"
        [ "$seen" = "$want" ] && return 0
        sleep 0.05
    done
    return 1
}
wait_panel() { wait_for panel "$1"; }

"$HELPER" panel "$APP_PID" | grep -qx gone \
    && ok "the panel starts closed" \
    || bad "a panel was on screen before the first click"

"$HELPER" click "$APP_PID" 90
if wait_panel shown; then ok "click 1 opens the panel"; else bad "click 1 did not open the panel"; fi

"$HELPER" click "$APP_PID" 90
if wait_panel gone; then ok "click 2 closes the panel"; else bad "click 2 left the panel open"; fi

"$HELPER" click "$APP_PID" 90
if wait_panel shown; then ok "click 3 opens it again"; else bad "click 3 did not reopen the panel"; fi

# The panel closes the same way whatever opened it; the last one is left open
# on purpose so a person watching sees the result, and the app exits with it.
say ""
say "passed=$PASS failed=$FAIL"
[ "$FAIL" = "0" ]
