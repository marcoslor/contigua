#!/usr/bin/env bash
# Builds a release PocketDeck.app from this tree and installs it to
# /Applications/PocketDeck.app. The build happens first, so a failed build
# leaves the installed copy alone; a running copy of *that bundle* is quit
# gracefully, never killed, and no other copy is touched.
#
# The installed copy carries the Finder files extension
# (Contents/PlugIns/Files.appex) by default: a manager install without it left
# the person's copy saying "This copy of PocketDeck was built without Finder
# files" (ISS-61). A copy without Finder files needs an explicit opt-out and
# says what it will miss:
#
#   ./scripts/install.sh                   # release + the Files extension
#   ./scripts/install.sh --without-files   # no Finder files; prints a warning
#   ./scripts/install.sh --dry-run         # print the plan; nothing is built
#
# Every other argument is forwarded to bundle.sh (e.g. --with-controls).
#
# After installing a bundle that carries the Files File Provider extension
# (Contents/PlugIns/Files.appex), the installed copy and its extension are
# registered (lsregister -f, pluginkit -a): Finder's location needs the
# extension the Mac is running, not the one in this checkout's build folder.
#
# Test hooks, never used by a person: POCKETDECK_INSTALL_DIR (destination,
# default /Applications), POCKETDECK_INSTALL_STAGE (the staged bundle, default
# build/install/PocketDeck.app) and POCKETDECK_INSTALL_NO_BUILD=1 (install the
# stage as it is) let a shell test exercise the checks against a fake bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST_DIR="${POCKETDECK_INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/PocketDeck.app"
STAGE="${POCKETDECK_INSTALL_STAGE:-build/install/PocketDeck.app}"
E2E_LOCK="${POCKETDECK_E2E_LOCK:-/tmp/pocketdeck-e2e.lock}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
FILES_EXT="Contents/PlugIns/Files.appex"
FILES_MISSING_TEXT="This copy of PocketDeck was built without Finder files"

# Forward bundle.sh's arguments as a string: bash 3.2 refuses an empty array
# under `set -u`.
BUNDLE_ARGS=""
add_bundle_arg() { BUNDLE_ARGS="${BUNDLE_ARGS:+$BUNDLE_ARGS }$1"; }

WITH_FILES=1
SAW_WITH=0
SAW_WITHOUT=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --without-files) SAW_WITHOUT=1 ;;
        --with-files) SAW_WITH=1 ;;
        --dry-run) DRY_RUN=1 ;;
        *) add_bundle_arg "$arg" ;;
    esac
done
if [ "$SAW_WITH" = 1 ] && [ "$SAW_WITHOUT" = 1 ]; then
    echo "install.sh: --with-files and --without-files contradict each other" >&2
    exit 2
fi
[ "$SAW_WITHOUT" = 1 ] && WITH_FILES=0
if [ "$WITH_FILES" = 1 ]; then
    add_bundle_arg --with-files
else
    echo "warning: --without-files: this copy has no Finder files extension" >&2
    echo "warning: ($FILES_EXT); Finder's PocketDeck location will say \"$FILES_MISSING_TEXT.\"" >&2
fi

if [ "$DRY_RUN" = 1 ]; then
    echo "dry run: ./scripts/bundle.sh \"$STAGE\" --variant release $BUNDLE_ARGS"
    echo "dry run: would install $STAGE to $DEST"
    if [ "$WITH_FILES" = 1 ]; then
        echo "dry run: would require $FILES_EXT in the stage and in $DEST"
    else
        echo "dry run: $FILES_EXT is not required (--without-files)"
    fi
    exit 0
fi

# Matched by executable path, so a test copy or another checkout's build never counts.
is_running() {
    pgrep -f "^$DEST/Contents/MacOS/PocketDeck" >/dev/null 2>&1
}

if [ -d "$E2E_LOCK" ] && kill -0 "$(cat "$E2E_LOCK/pid" 2>/dev/null)" 2>/dev/null; then
    echo "a check-e2e run is in progress; install when it finishes" >&2
    exit 1
fi

if [ "${POCKETDECK_INSTALL_NO_BUILD:-0}" = 1 ]; then
    [ -d "$STAGE" ] || { echo "install.sh: no staged bundle at $STAGE" >&2; exit 1; }
else
    # shellcheck disable=SC2086  # flags, never paths
    ./scripts/bundle.sh "$STAGE" --variant release $BUNDLE_ARGS
fi

# The bundle must carry the Files extension *before* it replaces a working
# installed copy: the person's Settings must never say the copy was built
# without Finder files while their folders are gone.
if [ "$WITH_FILES" = 1 ] && [ ! -d "$STAGE/$FILES_EXT" ]; then
    echo "install.sh: error: $STAGE has no $FILES_EXT; refusing to replace $DEST." >&2
    echo "install.sh: keep $DEST as it is; fix the build, or pass --without-files for a copy without Finder files." >&2
    exit 1
fi

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

if [ "$WITH_FILES" = 1 ]; then
    if [ ! -d "$DEST/$FILES_EXT" ]; then
        echo "install.sh: error: $DEST has no $FILES_EXT after the install; Finder files will be missing." >&2
        exit 1
    fi
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
    pluginkit -a "$DEST/$FILES_EXT" >/dev/null 2>&1 || true
    echo "registered $DEST and its Files extension"
else
    echo "warning: installed $DEST without Finder files ($FILES_EXT); $FILES_MISSING_TEXT."
fi
