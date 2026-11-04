#!/bin/bash
# sweep-test-registrations.sh — remove the test copies of PocketDeck that
# LaunchServices and PlugInKit remember, so a run leaves nothing of its own in
# the person's Share menu, `pocketdeck://` handlers or LaunchServices database.
#
# A test copy can claim `pocketdeck://`, and a test build's Share extension can
# appear in the person's Share menu; the check's own unregister only runs on a
# clean exit, so a killed run leaks it. check-e2e.sh therefore runs this at the
# start and on the exit of every run (while it holds the run lock), and the
# prototype shooter runs it the same way.
#
# The allow-list, never a deny-list: a registration is ours only when its path
# is under one of
#   ~/dev/pd-wt/                      other agents' worktrees
#   ~/dev/pocketdeck/                 the main checkout's test builds
#   /private/tmp/ and /tmp/           temp builds
#   ~/.t3/                            harness scratch checkouts
#   ~/Library/Application Support/PocketDeck-<profile>/   for a non-empty
#                                     profile suffix (test profiles' Dock Apps)
# The person's /Applications/PocketDeck.app, the default profile's folder
# (PocketDeck/, no hyphen) and every other app are outside the list.
#
# An app's PlugIns' appexes are removed with `pluginkit -r` first, then the app
# with `lsregister -u`; an appex found by itself goes to `pluginkit -r`. Then
# `lsregister -gc` compacts the database.
#
#   scripts/sweep-test-registrations.sh [--dry-run]
#
# Prints exactly one line, `sweep: lsregister N, pluginkit M`, counts only:
# never a path of the person's. Exits 0 even when a removal fails; this is a
# cleanup path and must not turn a run's result into a failure.

set -uo pipefail

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DRY_RUN=0

case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;;
esac

[ -x "$LSREGISTER" ] || { echo "sweep: lsregister 0, pluginkit 0"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pd-sweep.XXXXXX")" || { echo "sweep: lsregister 0, pluginkit 0"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

HOME_DIR="${HOME:-/Users/$(id -un)}"

# is_test_path PATH — the allow-list above.
is_test_path() {
    case "$1" in
        "$HOME_DIR"/dev/pd-wt/*|"$HOME_DIR"/dev/pocketdeck/*|/private/tmp/*|/tmp/*|"$HOME_DIR"/.t3/*)
            return 0 ;;
        "$HOME_DIR"/Library/Application\ Support/PocketDeck-*)
            local rest="${1#"$HOME_DIR"/Library/Application Support/PocketDeck-}"
            # A non-empty profile suffix and no slash straight after the hyphen:
            # ~/Library/Application Support/PocketDeck/ (the person's) never matches.
            [ -n "$rest" ] && [ "${rest#/}" = "$rest" ] && return 0 ;;
    esac
    return 1
}

is_pocketdeck_path() {
    case "$1" in
        *PocketDeck*|*pocketdeck*) return 0 ;;
    esac
    return 1
}

# The registrations: LaunchServices' path lines (the trailing record address is
# not part of the path) and PlugInKit's last tab-separated field.
"$LSREGISTER" -dump 2>/dev/null \
    | sed -n 's/^path:[[:space:]]*//p' \
    | sed 's/ (0x[0-9a-fA-F]*)$//' > "$WORK/ls-paths"
pluginkit -m -A -v 2>/dev/null | awk -F'\t' 'NF >= 4 { print $NF }' > "$WORK/pk-paths"

: > "$WORK/apps"
: > "$WORK/appexes"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_test_path "$path" || continue
    is_pocketdeck_path "$path" || continue
    case "$path" in
        *.app) printf '%s\n' "$path" >> "$WORK/apps" ;;
        *.appex) printf '%s\n' "$path" >> "$WORK/appexes" ;;
    esac
done < <(cat "$WORK/ls-paths" "$WORK/pk-paths")

# An app that is still on disk names its extensions; a deleted one does not,
# and its appexes are already listed by PlugInKit when they are registered.
while IFS= read -r app; do
    for appex in "$app"/Contents/PlugIns/*.appex; do
        [ -d "$appex" ] && printf '%s\n' "$appex" >> "$WORK/appexes"
    done
done < "$WORK/apps"
sort -u -o "$WORK/apps" "$WORK/apps"
sort -u -o "$WORK/appexes" "$WORK/appexes"

pk_count=0
while IFS= read -r appex; do
    [ -n "$appex" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
        pk_count=$((pk_count + 1))
    elif pluginkit -r "$appex" >/dev/null 2>&1; then
        pk_count=$((pk_count + 1))
    fi
done < "$WORK/appexes"

# After the extensions: unregistering an app can take its appexes with it, so
# this order keeps the two counts honest (an appex removed as a side effect
# would make `pluginkit -r` fail and go uncounted).
ls_count=0
while IFS= read -r app; do
    [ -n "$app" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
        ls_count=$((ls_count + 1))
    elif "$LSREGISTER" -u "$app" >/dev/null 2>&1; then
        ls_count=$((ls_count + 1))
    fi
done < "$WORK/apps"

[ "$DRY_RUN" = 1 ] || "$LSREGISTER" -gc >/dev/null 2>&1

echo "sweep: lsregister $ls_count, pluginkit $pk_count"
exit 0
