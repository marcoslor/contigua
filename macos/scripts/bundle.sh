#!/usr/bin/env bash
# Builds PocketDeck.app from the SwiftPM package and ad-hoc codesigns it.
#
#   ./scripts/bundle.sh [APP]     APP defaults to build/PocketDeck.app; only that
#                                 path is ever replaced.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PocketDeck"

APP="${1:-build/PocketDeck.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PocketDeck"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>PocketDeck</string>
	<key>CFBundleIdentifier</key>
	<string>dev.pocketdeck.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>PocketDeck</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>PocketDeck connects to Android phones on your local network to run their apps in Mac windows.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_pocketdeck._tcp</string>
	</array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
