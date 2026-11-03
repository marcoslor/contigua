#!/usr/bin/env bash
# Builds the direct-link helper and the app that carries its test hook
# (docs/design/direct-link.md §1.1). This is the only script that passes
# POCKETDECK_DIRECT; `swift build`, `swift test` and bundle.sh compile the
# stub, so the public build has none of it.
#
#   bash macos/scripts/direct/build.sh [--out DIR] [--variant NAME] [--helper-only]
#
# --out defaults to macos/build/direct and receives PocketDeck.app and
# pocketdeck-directd. --helper-only skips the app bundle (a quick helper
# rebuild). The helper is ad-hoc signed without entitlements, so the feth VM
# (AMFI on) can launch it; the installed helper gets the Wi-Fi Aware
# entitlement from P4's installer, and §7.4 shows the codesign line for a
# hand-built proof binary.
set -euo pipefail
cd "$(dirname "$0")/../.."   # macos/

OUT="build/direct"
VARIANT="direct"
HELPER_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
        --variant) VARIANT="${2:?--variant needs a name}"; shift 2 ;;
        --helper-only) HELPER_ONLY=1; shift ;;
        *) echo "direct/build.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

FLAGS=(-c release -Xswiftc -DPOCKETDECK_DIRECT)

mkdir -p "$OUT"
if [ "$HELPER_ONLY" = 0 ]; then
    bash scripts/bundle.sh "$OUT/PocketDeck.app" --variant "$VARIANT" --define POCKETDECK_DIRECT
fi

swift build "${FLAGS[@]}" --product pocketdeck-directd
BIN="$(swift build "${FLAGS[@]}" --product pocketdeck-directd --show-bin-path)/pocketdeck-directd"
cp "$BIN" "$OUT/pocketdeck-directd"
codesign --force --sign - --identifier dev.pocketdeck.directd "$OUT/pocketdeck-directd"
echo "direct/build.sh: built $OUT/pocketdeck-directd and $OUT/PocketDeck.app"
