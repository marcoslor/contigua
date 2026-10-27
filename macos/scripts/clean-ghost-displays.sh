#!/bin/bash
# clean-ghost-displays.sh — remove the ColorSync display profiles macOS wrote
# for e2e displays that no longer exist.
#
# Every display macOS sees gets a per-display profile in
# /Library/ColorSync/Profiles/Displays, named "<name>-<display UUID>.icc". The
# e2e rig adds a virtual display per run and macOS names its profile
# "PocketDeck e2e-<UUID>.icc" (older runs: "PD test-<UUID>.icc"); the file
# outlives the display and nothing removes it, so they pile up one per run.
#
# A file is a ghost only when it carries one of those prefixes AND its UUID is
# not a display that is online now. Every other profile is left alone, whatever
# it is called. Dry run by default; --apply deletes.
#
#   scripts/clean-ghost-displays.sh           print the ghosts
#   scripts/clean-ghost-displays.sh --apply   delete them (needs admin: the
#                                             folder is root-owned)
#
# Exit 0 when everything it found it removed (or none), 1 when a delete failed
# (the message says which need an administrator), 2 on a usage error.

set -uo pipefail

DIR="${PD_COLORSYNC_DIR:-/Library/ColorSync/Profiles/Displays}"
PREFIXES=("PocketDeck e2e-" "PD test-")
APPLY=0

case "${1:-}" in
    "") ;;
    --apply) APPLY=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: $(basename "$0") [--apply]" >&2; exit 2 ;;
esac

[ -d "$DIR" ] || { echo "no such folder: $DIR" >&2; exit 2; }

# online_display_uuids — the UUID macOS uses in a profile's name, for every
# display that is online now (CoreGraphics gives the same UUID).
online_display_uuids() {
    swift - <<'SWIFT'
import ColorSync
import CoreGraphics
import Foundation

var count: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetOnlineDisplayList(count, &ids, &count)
for id in ids.prefix(Int(count)) {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
    print((CFUUIDCreateString(nil, uuid) as String).uppercased())
}
SWIFT
}

ONLINE="$(online_display_uuids)"
[ -n "$ONLINE" ] || { echo "could not read the online displays' UUIDs" >&2; exit 2; }

is_online() {
    printf '%s\n' "$ONLINE" | grep -qxF -- "$1"
}

ghosts=()
kept=0
while IFS= read -r name; do
    prefix=""
    for candidate in "${PREFIXES[@]}"; do
        case "$name" in
            "$candidate"*) prefix="$candidate" ;;
        esac
    done
    [ -n "$prefix" ] || continue
    uuid="${name#"$prefix"}"
    uuid="${uuid%.icc}"
    if is_online "$(printf '%s' "$uuid" | tr '[:lower:]' '[:upper:]')"; then
        kept=$((kept + 1))
        continue
    fi
    ghosts+=("$name")
done < <(ls -1 "$DIR" 2>/dev/null)

if [ "${#ghosts[@]}" = 0 ]; then
    echo "no ghost display profiles in $DIR"
    exit 0
fi

if [ "$APPLY" = 0 ]; then
    for name in "${ghosts[@]}"; do
        echo "would delete: $name"
    done
    echo "${#ghosts[@]} ghost display profiles (${kept} kept: their display is online); run with --apply"
    exit 0
fi

removed=0
failed=0
for name in "${ghosts[@]}"; do
    if [ -w "$DIR" ]; then
        rm -f -- "$DIR/$name" && removed=$((removed + 1)) || failed=$((failed + 1))
    elif sudo -n true 2>/dev/null && sudo -n rm -f -- "$DIR/$name"; then
        removed=$((removed + 1))
    else
        failed=$((failed + 1))
        [ "$failed" = 1 ] && echo "$DIR is not writable and sudo needs a password"
    fi
done

echo "deleted $removed of ${#ghosts[@]} ghost display profiles in $DIR (${kept} kept: their display is online)"
[ "$failed" = 0 ] || { echo "$failed need an administrator: sudo $(basename "$0") --apply"; exit 1; }
