#!/usr/bin/env bash
# Builds a release PocketDeck.app from this tree and installs it to
# /Applications/PocketDeck.app. The build happens first, so a failed build
# leaves the installed copy alone; a running copy of *that bundle* is quit
# gracefully, never killed, and no other copy is touched.
#
# Extra arguments are forwarded to bundle.sh, so the release build can carry the
# opt-in extensions:
#
#   ./scripts/install.sh --with-files
#
# After installing a bundle that carries the Files File Provider extension
# (Contents/PlugIns/Files.appex), the installed copy and its extension are
# registered (lsregister -f, pluginkit -a): Finder's location needs the
# extension the Mac is running, not the one in this checkout's build folder.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="${POCKETDECK_INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/PocketDeck.app"
STAGE="build/install/PocketDeck.app"
E2E_LOCK="/tmp/pocketdeck-e2e.lock"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Matched by executable path, so a test copy or another checkout's build never counts.
is_running() {
    pgrep -f "^$DEST/Contents/MacOS/PocketDeck" >/dev/null 2>&1
}

if [ -d "$E2E_LOCK" ] && kill -0 "$(cat "$E2E_LOCK/pid" 2>/dev/null)" 2>/dev/null; then
    echo "a check-e2e run is in progress; install when it finishes" >&2
    exit 1
fi

./scripts/bundle.sh "$STAGE" --variant release "$@"

if is_running; then
    echo "quitting the running PocketDeck at $DEST"
    osascript -e "tell application \"$DEST\" to quit" >/dev/null
    for _ in $(seq 1 30); do
        is_running || break
        sleep 0.5
    done
    if is_running; then
        echo "PocketDeck is still running (it may be showing a dialog); quit it and run this again" >&2
        exit 1
    fi
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
echo "installed $DEST"

# The installed bundle replaces the one launch services and pluginkit knew; a
# File Provider extension has to be registered from the path the app now runs
# from. A bundle without the extension is left alone.
if [ -d "$DEST/Contents/PlugIns/Files.appex" ]; then
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
    pluginkit -a "$DEST/Contents/PlugIns/Files.appex" >/dev/null 2>&1 || true
    echo "registered $DEST and its Files extension"
fi
