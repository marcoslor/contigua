#!/usr/bin/env bash
# Builds PocketDeck.app from the SwiftPM package and ad-hoc codesigns it.
#
#   ./scripts/bundle.sh [APP] [--variant NAME]
#
# APP defaults to build/PocketDeck.app; only that path is ever replaced.
# The app carries the "Open on Phone" Share extension (Contents/PlugIns/Share.appex)
# and the Dock app executable (Contents/MacOS/PocketDeckShim).
# Only `--variant release` (install.sh) gets the real extension id; every other
# bundle (default `dev`, check-e2e's `e2e`) gets `dev.pocketdeck.mac.share-NAME` and
# a "(NAME)" title, so a test copy never competes with the installed app's extension.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/PocketDeck.app"
VARIANT="dev"
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="${2:?--variant needs a name}"; shift 2 ;;
        *) APP="$1"; shift ;;
    esac
done
case "$VARIANT" in
    release) SHARE_ID="dev.pocketdeck.mac.share"; SHARE_TITLE="Open on Phone" ;;
    *[!a-z0-9]*|"") echo "bundle.sh: --variant must be a-z0-9" >&2; exit 2 ;;
    *) SHARE_ID="dev.pocketdeck.mac.share-$VARIANT"; SHARE_TITLE="Open on Phone ($VARIANT)" ;;
esac

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PocketDeck"

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
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>dev.pocketdeck.mac.open</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>pocketdeck</string>
			</array>
		</dict>
	</array>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Open on Phone</string>
			</dict>
			<key>NSMessage</key>
			<string>openOnPhone</string>
			<key>NSPortName</key>
			<string>PocketDeck</string>
			<key>NSSendTypes</key>
			<array>
				<string>public.url</string>
				<string>public.utf8-plain-text</string>
			</array>
			<key>NSRequiredContext</key>
			<dict/>
		</dict>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>Install on Phone</string>
			</dict>
			<key>NSMessage</key>
			<string>installOnPhone</string>
			<key>NSPortName</key>
			<string>PocketDeck</string>
			<key>NSSendFileTypes</key>
			<array>
				<string>com.android.package-archive</string>
				<string>dev.pocketdeck.apks</string>
				<string>dev.pocketdeck.xapk</string>
			</array>
			<key>NSRequiredContext</key>
			<dict/>
		</dict>
	</array>
	<key>UTImportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>com.android.package-archive</string>
			<key>UTTypeDescription</key>
			<string>Android app</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
				<string>public.zip-archive</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>apk</string>
				</array>
				<key>public.mime-type</key>
				<string>application/vnd.android.package-archive</string>
			</dict>
		</dict>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>dev.pocketdeck.apks</string>
			<key>UTTypeDescription</key>
			<string>Android app bundle (split APKs)</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
				<string>public.zip-archive</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>apks</string>
				</array>
			</dict>
		</dict>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>dev.pocketdeck.xapk</string>
			<key>UTTypeDescription</key>
			<string>Android app bundle (XAPK)</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
				<string>public.zip-archive</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>xapk</string>
				</array>
			</dict>
		</dict>
	</array>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Android app</string>
			<key>CFBundleTypeRole</key>
			<string>Viewer</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.android.package-archive</string>
				<string>dev.pocketdeck.apks</string>
				<string>dev.pocketdeck.xapk</string>
			</array>
		</dict>
	</array>
	<key>NSBonjourServices</key>
	<array>
		<string>_pocketdeck._tcp</string>
	</array>
</dict>
</plist>
PLIST
# Read at launch: only the release build may use the default profile.
plutil -insert PDBuildVariant -string "$VARIANT" "$APP/Contents/Info.plist"

# Share extension: swiftc, because SwiftPM cannot link an app extension's entry point.
APPEX="$APP/Contents/PlugIns/Share.appex"
mkdir -p "$APPEX/Contents/MacOS"
swiftc -O -application-extension -module-name Share -target "$(uname -m)-apple-macos26.0" \
    -swift-version 5 Extensions/Share/ShareViewController.swift Sources/PocketDeck/LinkShare.swift \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$APPEX/Contents/MacOS/Share"
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>Share</string>
	<key>CFBundleIdentifier</key>
	<string>$SHARE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$SHARE_TITLE</string>
	<key>CFBundleDisplayName</key>
	<string>$SHARE_TITLE</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.share-services</string>
		<key>NSExtensionPrincipalClass</key>
		<string>ShareViewController</string>
		<key>NSExtensionAttributes</key>
		<dict>
			<key>NSExtensionActivationRule</key>
			<dict>
				<key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
				<integer>1</integer>
				<key>NSExtensionActivationSupportsText</key>
				<true/>
			</dict>
		</dict>
	</dict>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements Extensions/Share/Share.entitlements "$APPEX"

# Dock app executable (docs/design/dock.md): copied into each per-app shim bundle.
swiftc -O -module-name PocketDeckShim -target "$(uname -m)-apple-macos26.0" -swift-version 5 \
    Shim/main.swift Sources/PocketDeck/DockMessages.swift -o "$APP/Contents/MacOS/PocketDeckShim"
codesign --force --sign - "$APP"
echo "built $APP"
