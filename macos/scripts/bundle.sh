#!/usr/bin/env bash
# Builds PocketDeck.app from the SwiftPM package and ad-hoc codesigns it.
#
#   ./scripts/bundle.sh [APP] [--variant NAME] [--with-files] [--with-controls]
#
# APP defaults to build/PocketDeck.app; only that path is ever replaced.
# The app carries the "Open on Phone" Share extension (Contents/PlugIns/Share.appex)
# and the Dock app executable (Contents/MacOS/PocketDeckShim). --with-files adds
# the "Phone files in Finder" File Provider extension (Contents/PlugIns/Files.appex)
# and the App Group the app shares with it; only the vm-e2e files-domain bundle
# uses it.
# --with-controls adds the Control Center extension (Contents/PlugIns/Controls.appex)
# and its App Group; only the VM controls bundle uses it, because a host run
# must have nothing to register.
# Only `--variant release` (install.sh) gets the real extension id; every other
# bundle (default `dev`, check-e2e's `e2e`) gets `dev.pocketdeck.mac.share-NAME` and
# a "(NAME)" title, so a test copy never competes with the installed app's extension.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/PocketDeck.app"
VARIANT="dev"
WITH_FILES=0
WITH_CONTROLS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="${2:?--variant needs a name}"; shift 2 ;;
        --with-files) WITH_FILES=1; shift ;;
        --with-controls) WITH_CONTROLS=1; shift ;;
        *) APP="$1"; shift ;;
    esac
done
case "$VARIANT" in
    release) SHARE_ID="dev.pocketdeck.mac.share"; SHARE_TITLE="Open on Phone"; FILES_ID="dev.pocketdeck.mac.files"; FILES_TITLE="PocketDeck Files"
             FILES_GROUP="group.dev.pocketdeck.mac.files"
             CONTROLS_ID="dev.pocketdeck.mac.controls"; CONTROLS_TITLE="PocketDeck Controls" ;;
    *[!a-z0-9]*|"") echo "bundle.sh: --variant must be a-z0-9" >&2; exit 2 ;;
    *) SHARE_ID="dev.pocketdeck.mac.share-$VARIANT"; SHARE_TITLE="Open on Phone ($VARIANT)"
       FILES_ID="dev.pocketdeck.mac.files-$VARIANT"; FILES_TITLE="PocketDeck Files ($VARIANT)"
       FILES_GROUP="group.dev.pocketdeck.mac.files-$VARIANT"
       CONTROLS_ID="dev.pocketdeck.mac.controls-$VARIANT"; CONTROLS_TITLE="PocketDeck Controls ($VARIANT)" ;;
esac

# The e2e/debug launch hooks are compiled in only for non-release bundles:
# install.sh's `--variant release` build ignores them (sec L-6). The flag is
# passed here so `build_e2e_app` and vm-e2e.sh's host build both get it.
BUILD_FLAGS=()
[ "$VARIANT" = "release" ] || BUILD_FLAGS=(-Xswiftc -DPD_TEST_HOOKS)

# App Intents metadata (docs/design/intents.md). Xcode's
# ExtractAppIntentsMetadata phase is two halves, and SwiftPM runs neither:
# `-emit-const-values` makes swiftc write one `<file>.swiftconstvalues` per
# source, and appintentsmetadataprocessor turns those into the bundle's
# `Contents/Resources/Metadata.appintents`. Without that folder the system
# knows none of the app's intents: no Siri, no Shortcuts, no Spotlight actions.
# The protocol list is the one Xcode hands swiftc; it is a constant of the
# toolchain rather than of this project, so it lives in a file here.
APPINTENTS_TOOLCHAIN="${APPINTENTS_TOOLCHAIN:-$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain}"
APPINTENTS_TOOL="$APPINTENTS_TOOLCHAIN/usr/bin/appintentsmetadataprocessor"
APPINTENTS_PROTOCOLS="$PWD/scripts/appintents-protocols.json"
if [ -x "$APPINTENTS_TOOL" ]; then
    BUILD_FLAGS+=(-Xswiftc -emit-const-values -Xswiftc -const-gather-protocols-list -Xswiftc "$APPINTENTS_PROTOCOLS")
else
    echo "bundle.sh: warning: no appintentsmetadataprocessor in $APPINTENTS_TOOLCHAIN; the bundle will carry no App Intents metadata" >&2
fi

swift build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN="$(swift build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)/PocketDeck"

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
# The e2e app starts as an agent, so a quiet (--background) run never has a Dock
# icon, not even while it launches; a visible run makes itself a regular app.
[ "$VARIANT" = "e2e" ] && plutil -insert LSUIElement -bool true "$APP/Contents/Info.plist"

# ExtractAppIntentsMetadata, second half: the const-values files the compiler
# wrote above (PocketDeck's own, not the dependencies') become
# Resources/Metadata.appintents. Same arguments Xcode's phase passes, bar the
# per-source dependency files it only uses to decide whether to re-run.
if [ -x "$APPINTENTS_TOOL" ]; then
    CONST_LIST="$(find .build/out/Intermediates.noindex/PocketDeck.build -path "*/Release/*" \
        -name "PocketDeck.SwiftFileList" 2>/dev/null | head -1)"
    CONST_DIR="$(dirname "${CONST_LIST:-.}")"
    CONST_VALUES="$(mktemp -t pocketdeck-constvals)"
    trap 'rm -f "$CONST_VALUES"' EXIT
    if [ -f "$CONST_LIST" ]; then
        find "$CONST_DIR" -maxdepth 1 -name "*.swiftconstvalues" > "$CONST_VALUES"
        "$APPINTENTS_TOOL" \
            --toolchain-dir "$APPINTENTS_TOOLCHAIN" \
            --module-name PocketDeck \
            --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
            --xcode-version "$(xcodebuild -version | tail -1)" \
            --platform-family macOS \
            --deployment-target 26.0 \
            --bundle-identifier dev.pocketdeck.mac \
            --output "$APP/Contents/Resources" \
            --target-triple "$(uname -m)-apple-macos26.0" \
            --binary-file "$APP/Contents/MacOS/PocketDeck" \
            --source-file-list "$CONST_LIST" \
            --swift-const-vals-list "$CONST_VALUES" \
            --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization
    else
        echo "bundle.sh: warning: no Release SwiftFileList under .build; App Intents metadata not extracted" >&2
    fi
    rm -f "$CONST_VALUES"
    trap - EXIT
fi

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

# File Provider extension (docs/design/files.md §1): the same swiftc shape as
# Share, because SwiftPM cannot link an app extension's entry point. It is a
# replicated provider, so it needs an App Group (the app's side is
# FilesBridge.swift) and no portal capability. Opt-in (--with-files) because the
# extension only belongs in the bundle that shows phone files in Finder: a host
# e2e run must not have a File Provider extension to register.
if [ "$WITH_FILES" = 1 ]; then
    # The group is per bundle: production keeps the plain id, every test copy
    # its own, so one copy's domain and socket never meet another's.
    /usr/libexec/PlistBuddy -c "Add :PDFilesGroup string $FILES_GROUP" "$APP/Contents/Info.plist"
    FILES_ENTITLEMENTS="build/Files-$VARIANT.entitlements"
    APP_ENTITLEMENTS="build/PocketDeckFiles-$VARIANT.entitlements"
    sed -e "s/__FILES_GROUP__/$FILES_GROUP/" Extensions/Files/Files.entitlements > "$FILES_ENTITLEMENTS"
    sed -e "s/__FILES_GROUP__/$FILES_GROUP/" Extensions/Files/PocketDeckFiles.entitlements > "$APP_ENTITLEMENTS"
    FILES_APPEX="$APP/Contents/PlugIns/Files.appex"
    mkdir -p "$FILES_APPEX/Contents/MacOS"
    swiftc -O -application-extension -module-name Files -target "$(uname -m)-apple-macos26.0" \
        -swift-version 5 Extensions/Files/Files.swift Sources/PocketDeck/FilesCore.swift \
        -Xlinker -e -Xlinker _NSExtensionMain -o "$FILES_APPEX/Contents/MacOS/Files"
    sed -e "s/__FILES_ID__/$FILES_ID/" -e "s/__FILES_TITLE__/$FILES_TITLE/" \
        -e "s/__FILES_GROUP__/$FILES_GROUP/" \
        Extensions/Files/Info.plist > "$FILES_APPEX/Contents/Info.plist"
    codesign --force --sign - --entitlements "$FILES_ENTITLEMENTS" "$FILES_APPEX"
fi

# Control Center extension (docs/design/controls.md): the same swiftc shape as
# Share. It is a widget extension, so it has its own @main (WidgetBundle) and is
# compiled as a library entry point; ControlsCore.swift is shared with the app.
# Opt-in (--with-controls) because a host e2e run must have no control extension
# to register, and the brief forbids registering one on this Mac.
if [ "$WITH_CONTROLS" = 1 ]; then
    case "$APP" in /*) CONTROLS_APPEX="$APP/Contents/PlugIns/Controls.appex" ;; *) CONTROLS_APPEX="$PWD/$APP/Contents/PlugIns/Controls.appex" ;; esac
    mkdir -p "$CONTROLS_APPEX/Contents/MacOS" "$CONTROLS_APPEX/Contents/Resources"
    # Compile to objects first so the const-values files exist: the extension's
    # control actions are App Intents, and the system learns them only from
    # Resources/Metadata.appintents (the same processor the app uses).
    CONTROLS_SRC=("$PWD/Extensions/Controls/Controls.swift" "$PWD/Sources/PocketDeck/ControlsCore.swift")
    CONTROLS_OBJ="$(mktemp -d -t pocketdeck-controls)"
    (
        cd "$CONTROLS_OBJ"
        swiftc -c -O -parse-as-library -application-extension -module-name Controls \
            -target "$(uname -m)-apple-macos26.0" -swift-version 5 \
            -emit-const-values -const-gather-protocols-list "$APPINTENTS_PROTOCOLS" \
            ${CONTROLS_SRC[@]+"${CONTROLS_SRC[@]}"}
        swiftc -O -o "$CONTROLS_APPEX/Contents/MacOS/Controls" *.o
    )
    if [ -x "$APPINTENTS_TOOL" ]; then
        printf '%s\n' "${CONTROLS_SRC[@]}" > "$CONTROLS_OBJ/sources.txt"
        find "$CONTROLS_OBJ" -maxdepth 1 -name "*.swiftconstvalues" > "$CONTROLS_OBJ/const.txt"
        "$APPINTENTS_TOOL" \
            --toolchain-dir "$APPINTENTS_TOOLCHAIN" \
            --module-name Controls \
            --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
            --xcode-version "$(xcodebuild -version | tail -1)" \
            --platform-family macOS \
            --deployment-target 26.0 \
            --bundle-identifier "$CONTROLS_ID" \
            --output "$CONTROLS_APPEX/Contents/Resources" \
            --target-triple "$(uname -m)-apple-macos26.0" \
            --binary-file "$CONTROLS_APPEX/Contents/MacOS/Controls" \
            --source-file-list "$CONTROLS_OBJ/sources.txt" \
            --swift-const-vals-list "$CONTROLS_OBJ/const.txt" \
            --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization
    else
        echo "bundle.sh: warning: no appintentsmetadataprocessor; the controls extension carries no action metadata" >&2
    fi
    rm -rf "$CONTROLS_OBJ"
    sed -e "s/__CONTROLS_ID__/$CONTROLS_ID/" -e "s/__CONTROLS_TITLE__/$CONTROLS_TITLE/" \
        Extensions/Controls/Info.plist > "$CONTROLS_APPEX/Contents/Info.plist"
    codesign --force --sign - --entitlements Extensions/Controls/Controls.entitlements "$CONTROLS_APPEX"
fi

# Dock app executable (docs/design/dock.md): copied into each per-app shim bundle.
swiftc -O -module-name PocketDeckShim -target "$(uname -m)-apple-macos26.0" -swift-version 5 \
    Shim/main.swift Sources/PocketDeck/DockMessages.swift -o "$APP/Contents/MacOS/PocketDeckShim"

# MCP stdio shim (docs/design/mcp.md): MCP clients launch this, and it relays to
# the app's private socket. It is signed before the bundle so signing the app
# seals its nested code.
mkdir -p "$APP/Contents/Helpers"
swiftc -O -module-name PocketDeckMCP -target "$(uname -m)-apple-macos26.0" -swift-version 5 \
    Shim/mcp.swift -o "$APP/Contents/Helpers/pocketdeck-mcp"
codesign --force --sign - "$APP/Contents/Helpers/pocketdeck-mcp"

if [ "$WITH_CONTROLS" = 1 ]; then
    # The app carries the App Group the controls extension shares with it (an
    # unsandboxed app may hold an app group, docs/design/files.md §1).
    codesign --force --sign - --entitlements Extensions/Controls/PocketDeckControls.entitlements "$APP"
elif [ "$WITH_FILES" = 1 ]; then
    # The app carries the App Group the Files extension shares with it (an
    # unsandboxed app may hold an app group, docs/design/files.md §1).
    codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "built $APP"
