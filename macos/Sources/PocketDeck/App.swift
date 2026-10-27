// Launch-option parsing (the test hooks), the app delegate and the SwiftUI
// app entry. The connection logic lives in ConnectionController.

import AppKit
import SwiftUI

// MARK: - Launch options (see macos/README.md)

struct LaunchOptions {
    var connect: (host: String, port: UInt16)?
    var openPackages: [String] = []
    var openPhone = false
    var resizes: [(stream: UInt32, size: NSSize, after: TimeInterval)] = []
    var minimizes: [(stream: UInt32, after: TimeInterval)] = []
    var deminimizes: [(stream: UInt32, after: TimeInterval)] = []
    /// `--close-stream N:SECONDS`: close that stream window like a person does (e2e).
    var closeStreams: [(stream: UInt32, after: TimeInterval)] = []
    var quitAfter: TimeInterval?
    var resetPairing = false
    var qrSheet = false
    var qrPayloadFile: String?
    var debugInputScript: String?
    /// `--debug-fs-script FILE`: read-only phone-file requests on the session
    /// (FsDebug.swift, e2e `files` check).
    var debugFsScript: String?
    /// `--debug-intent "<name> <args>"` (repeatable): run that intent's perform
    /// path and log its result (IntentsDebug.swift, e2e `intents` check).
    var debugIntents: [String] = []
    /// `--debug-focus "<on|off> [priority|alarms|none]"`: run the Focus
    /// filter's perform() path (docs/design/focus.md, e2e `focus` check).
    var debugFocus: String?
    /// `--debug-dnd on|off`: run the menu bar item's path.
    var debugDnd: String?
    /// `--debug-livetext FILE`: scripted Live Text mode steps (DebugLiveText.swift,
    /// e2e `livetext` check). Results on stderr.
    var debugLiveText: String?
    /// `--debug-control DIR`: commands from the e2e checks that share this
    /// running app (DebugControl.swift).
    var debugControl: String?
    var dumpVideoDirectory: String?
    /// `--float-windows`: stream windows stay above other apps' windows, so the
    /// checks that look at them are not defeated by whatever the person has open.
    var floatWindows = false
    /// `--debug-chrome-state FILE`: stream windows write their header state here (e2e).
    var debugChromeState: String?
    /// `--debug-banner FILE`: the deck window's banner text, one line per change (e2e).
    var debugBanner: String?
    /// `--debug-deck-grid FILE`: the app grid's drawn cells (e2e `deck`).
    var debugDeckGrid: String?
    /// `--debug-deck-zoom FILE`: the Deck's double-click zoom, measured (e2e `deck`).
    var debugDeckZoom: String?
    var audioStatsFile: String?
    var profileName = Profile.defaultName
    /// `--share-dir DIR`: where images shared from the phone are saved (default ~/Downloads/PocketDeck).
    var shareDirectory: String?
    /// `--share-log FILE`: record shared links and notifications instead of acting (e2e).
    var shareLog: String?
    /// `--preview STATE`: drive the UI with a scripted state (screenshots).
    var preview: String?
    /// `--appearance light|dark`: force the appearance (screenshots).
    var appearance: String?
    /// `--debug-proto settings=S1|S2|S3`: Settings' sidebar prototypes
    /// (branch proto/settings-sidebar; a test hook, ignored by a release build).
    var debugProto: String?
    /// (branch proto/devices; a test hook, ignored by a release build).
    /// `--dock-dir DIR`: where Dock apps are created (e2e: a temp folder).
    var dockDirectory: String?
    /// `--dock-add PKG` / `--dock-remove PKG`: create or remove that app's Dock app once
    /// the phone's app list arrives (e2e).
    var dockAdd: String?
    var dockRemove: String?
    /// `--set-nickname NAME`: rename the active phone once its app list arrives,
    /// through the same code the Settings → Devices → Rename dialog calls (e2e).
    var setNickname: String?
    /// `--continue-on-mac`: run the Move Phone App to Mac command once the session is
    /// ready (e2e, docs/design/handoff.md).
    var continueOnMac = false
    /// `--background`: the e2e run's quiet mode (BackgroundMode.swift). Only
    /// with a non-default profile; the installed app never runs this way.
    var background = false
    /// `--open-requests DIR` (background mode only): each `*.path` file put in DIR
    /// names files to open, as LaunchServices' Open With would (e2e, apk).
    var openRequests: String?
    /// `--mcp-enable` (test builds only): turn the automation server's setting
    /// on for this profile at launch (e2e `mcp`).
    var mcpEnable = false
    /// `--files-domain add|remove|list|disconnect|reconnect` — the File Provider
    /// domain (docs/design/files.md). Refused outside the e2e VM.
    var filesDomain: String?
    /// `--files-bridge-dir DIR`: put the bridge socket in DIR instead of the App
    /// Group container, so a host check can drive the bridge without any File
    /// Provider (e2e `files-bridge`).
    var filesBridgeDir: String?
    /// `--files-domain-seen DIR`: the profile's Finder domain is already added
    /// and the bridge socket lives in DIR. The host e2e's relaunch path; no
    /// File Provider is touched on this Mac (e2e `files-bridge`).
    var filesDomainSeen: String?
    /// `--controls-dir DIR`: where the Control Center snapshot and socket live,
    /// instead of the App Group container (e2e `controls` check; no extension).
    var controlsDirectory: String?

    /// nil when `--profile` was missing or not a usable name.
    var profile: Profile? { Profile(name: profileName) }

    /// Launch flags that exist only for the e2e harness and the screenshot
    /// runs; the value says whether the flag takes an argument. A production
    /// build (no `PD_TEST_HOOKS`) ignores them instead of acting on them
    /// (sec L-6: `--debug-control` alone can drive a live session).
    static let testHooks: [String: Bool] = [
        "--connect": true,
        "--open": true,
        "--open-phone": false,
        "--resize-stream": true,
        "--minimize-stream": true,
        "--deminimize-stream": true,
        "--close-stream": true,
        "--quit-after": true,
        "--reset-pairing": false,
        "--qr-sheet": false,
        "--qr-payload-file": true,
        "--debug-input-script": true,
        "--debug-fs-script": true,
        "--debug-intent": true,
        "--debug-focus": true,
        "--debug-dnd": true,
        "--debug-livetext": true,
        "--debug-control": true,
        "--dump-video": true,
        "--float-windows": false,
        "--debug-chrome-state": true,
        "--debug-banner": true,
        "--audio-stats": true,
        "--share-log": true,
        "--preview": true,
        "--appearance": true,
        "--debug-proto": true,
        "--dock-dir": true,
        "--dock-add": true,
        "--dock-remove": true,
        "--set-nickname": true,
        "--continue-on-mac": false,
        "--background": false,
        "--open-requests": true,
        "--mcp-enable": false,
        "--files-domain": true,
        "--files-bridge-dir": true,
        "--files-domain-seen": true,
        "--controls-dir": true,
    ]

    /// One line on stderr (the harness captures stderr into app.log); the
    /// flag's value is never logged.
    private static func noteIgnoredDebugFlag(_ flag: String) {
        FileHandle.standardError.write(Data("ignored debug flag \(flag) in a release build\n".utf8))
    }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            let argument = arguments[index]
            #if !PD_TEST_HOOKS
            if let takesValue = Self.testHooks[argument] {
                Self.noteIgnoredDebugFlag(argument)
                index += takesValue ? 2 : 1
                continue
            }
            #endif
            switch argument {
            case "--connect":
                if let value = next(), let colon = value.lastIndex(of: ":"),
                   let port = UInt16(value[value.index(after: colon)...]) {
                    options.connect = (String(value[..<colon]), port)
                }
            case "--open":
                if let value = next() {
                    options.openPackages += value.split(separator: ",").map(String.init)
                }
            case "--open-phone":
                options.openPhone = true
            case "--resize-stream":
                if let value = next() { options.resizes.append(Self.parseResize(value, defaultDelay: 2)) }
            case "--minimize-stream":
                if let value = next() { options.minimizes.append(Self.parseTimedStream(value)) }
            case "--deminimize-stream":
                if let value = next() { options.deminimizes.append(Self.parseTimedStream(value)) }
            case "--close-stream":
                if let value = next() { options.closeStreams.append(Self.parseTimedStream(value)) }
            case "--quit-after":
                if let value = next(), let seconds = Double(value) { options.quitAfter = seconds }
            case "--reset-pairing":
                options.resetPairing = true
            case "--qr-sheet":
                options.qrSheet = true
            case "--qr-payload-file":
                options.qrPayloadFile = next()
            case "--debug-input-script":
                options.debugInputScript = next()
            case "--debug-fs-script":
                options.debugFsScript = next()
            case "--debug-intent":
                if let value = next() { options.debugIntents.append(value) }
            case "--debug-focus":
                options.debugFocus = next()
            case "--debug-dnd":
                options.debugDnd = next()
            case "--debug-livetext":
                options.debugLiveText = next()
            case "--debug-control":
                options.debugControl = next()
            case "--dump-video":
                options.dumpVideoDirectory = next()
            case "--float-windows":
                options.floatWindows = true
            case "--debug-chrome-state":
                options.debugChromeState = next()
            case "--debug-banner":
                options.debugBanner = next()
            case "--debug-deck-grid":
                options.debugDeckGrid = next()
            case "--debug-deck-zoom":
                options.debugDeckZoom = next()
            case "--audio-stats":
                options.audioStatsFile = next()
            case "--profile":
                options.profileName = next() ?? ""
            case "--share-dir":
                options.shareDirectory = next()
            case "--share-log":
                options.shareLog = next()
            case "--preview":
                options.preview = next()
            case "--appearance":
                options.appearance = next()
            case "--debug-proto":
                options.debugProto = next()
            case "--dock-dir":
                options.dockDirectory = next()
            case "--dock-add":
                options.dockAdd = next()
            case "--dock-remove":
                options.dockRemove = next()
            case "--set-nickname":
                options.setNickname = next()
            case "--continue-on-mac":
                options.continueOnMac = true
            case "--background":
                options.background = true
            case "--open-requests":
                options.openRequests = next()
            case "--mcp-enable":
                options.mcpEnable = true
            case "--files-domain":
                options.filesDomain = next()
            case "--files-bridge-dir":
                options.filesBridgeDir = next()
            case "--files-domain-seen":
                options.filesDomainSeen = next()
            case "--controls-dir":
                options.controlsDirectory = next()
            default:
                break
            }
            index += 1
        }
        return options
    }

    /// Why the app must not start with these options, or nil. The default
    /// profile holds the user's pairings: dev and test builds (and bare
    /// binaries) must name their own profile, previews touch no data, and
    /// background mode is never the user's app.
    func launchRefusal(releaseBuild: Bool) -> String? {
        guard let profile else { return "--profile \(profileName): use 1-32 of a-z, 0-9 and -" }
        guard profile.isDefault else { return nil }
        if filesDomain != nil { return "--files-domain needs --profile NAME (never the default profile)" }
        if background { return "--background needs --profile NAME (never the default profile)" }
        if preview == nil, !releaseBuild { return "this build needs --profile NAME (the default profile is for the installed app)" }
        return nil
    }

    /// `N:WxH-pt` — the `-pt` suffix is optional.
    private static func parseResize(_ value: String, defaultDelay: TimeInterval) -> (UInt32, NSSize, TimeInterval) {
        var value = value
        var delay = defaultDelay
        // `@SECONDS` after the size schedules one step of a scripted drag:
        // `1:640x480-pt@0.03`.
        if let at = value.lastIndex(of: "@"), let seconds = Double(value[value.index(after: at)...]) {
            delay = seconds
            value = String(value[..<at])
        }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let stream = UInt32(parts.first ?? "") ?? 0
        var rest = parts.count > 1 ? parts[1] : ""
        if rest.hasSuffix("-pt") { rest = String(rest.dropLast(3)) }
        let dims = rest.lowercased().split(separator: "x").map(String.init)
        let width = Double(dims.first ?? "") ?? 0
        let height = dims.count > 1 ? (Double(dims[1]) ?? 0) : 0
        return (stream, NSSize(width: width, height: height), delay)
    }

    /// `N:SECONDS`.
    private static func parseTimedStream(_ value: String) -> (UInt32, TimeInterval) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        return (UInt32(parts.first ?? "") ?? 0, parts.count > 1 ? (Double(parts[1]) ?? 0) : 0)
    }
}

// MARK: - Environment shared by the scenes and the delegate

@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let options: LaunchOptions
    let profile: Profile
    let controller: ConnectionController

    private init() {
        let options = LaunchOptions.parse(CommandLine.arguments)
        // A profile name that does not parse must not fall back to the default
        // profile: a test run would then use the user's data.
        let release = Bundle.main.object(forInfoDictionaryKey: "PDBuildVariant") as? String == "release"
        if let refusal = options.launchRefusal(releaseBuild: release) {
            FileHandle.standardError.write(Data((refusal + "\n").utf8))
            exit(2)
        }
        if let raw = options.filesDomain {
            guard FilesDomainAction(rawValue: raw) != nil else {
                FileHandle.standardError.write(Data("--files-domain \(raw): use add|remove|list|disconnect|reconnect\n".utf8))
                exit(2)
            }
            // Never on this Mac: adding the domain puts a location in the
            // person's Finder. Only the e2e VM (vm-e2e.sh exports this) runs it.
            guard ProcessInfo.processInfo.environment["PD_E2E_IN_VM"] == "1" else {
                FileHandle.standardError.write(Data("--files-domain refuses to run outside the e2e VM (PD_E2E_IN_VM=1)\n".utf8))
                exit(2)
            }
        }
        let profile = options.profile!
        BackgroundMode.isOn = options.background
        Profile.active = profile
        Log.app.notice("profile \(profile.name, privacy: .public): identity \(IdentityFileV2.fileUrl(in: profile).path, privacy: .public), defaults \(profile.defaultsSuiteName ?? "standard", privacy: .public)")
        if let value = options.debugProto {
            ProtoSettings.select(value)
            ProtoSettingsRender.installActiveStandIn()
        }
        if options.resetPairing {
            // v2: pairing state = the pins + identity.json's §3 mirror; the
            // identity itself (this Mac's key) stays.
            DeviceIdentityV2Reset.resetPairingState(profile: profile)
            CachedDeviceStore(profile: profile).removeAll()
            RememberedPhones(profile: profile).removeAll()
        }
        self.options = options
        self.profile = profile
        controller = ConnectionController(options: options, profile: profile)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openRequestInbox: OpenRequestInbox?
    private var debugBanner: DebugBanner?
    private var controlsHost: ControlsHost?
    private var menuBar: MenuBarController?

    /// Started from a shell (the test harness) there is no LaunchServices to
    /// make the process a regular app; do it explicitly so it gets windows and a Dock icon.
    /// In background mode it stays out of the Dock and ⌘-Tab instead.
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppEnvironment.shared.options.background {
            BackgroundMode.start()
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
        if let raw = environment.options.filesDomain, let action = FilesDomainAction(rawValue: raw) {
            FilesDomainHooks.run(action)
            // `add` started the bridge and must stay up for the extension;
            // every other action is a one-shot the check waits on.
            if action != .add { exit(0) }
        }
        if let directory = environment.options.filesBridgeDir {
            // The e2e hook: the socket in a test directory, so a host check can
            // speak the bridge with no File Provider on this Mac.
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(FilesSocket.fileName(profile: environment.profile)).path
            let result = FilesBridge.shared.start(path: path)
            FileHandle.standardError.write(Data("files-bridge: \(result)\n".utf8))
        }
        // SwiftUI makes the app regular while it launches; background mode stays an accessory.
        if environment.options.background { NSApp.setActivationPolicy(.accessory) }
        switch environment.options.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        BackgroundMode.activateApp()
        if let inbox = OpenRequestInbox(options: environment.options) {
            inbox.start { [weak self] urls in self?.application(NSApp, open: urls) }
            openRequestInbox = inbox
        }
        NSApp.servicesProvider = LinkService.shared
        MenuCleanup.start()
        MenuMarks.start()
        FullScreenMenu.start()
        // VisionKit's analyser service is slow and unreliable on its first
        // call (LiveTextWarmer): pay that while the app starts, not when the
        // person presses Live Text.
        LiveTextWarmer.start()
        if let path = environment.options.debugDeckZoom {
            DeckZoomProbe.start(path: path)
        }
        if let path = environment.options.debugBanner {
            let probe = DebugBanner(path: path) { [controller = environment.controller] in
                controller.banner?.text
            }
            probe.start()
            debugBanner = probe
        }
        // "Show phone files in Finder" is off by default; when the profile's
        // setting says otherwise its domain comes up with the app.
        environment.controller.filesDomain.start()
        menuBar = MenuBarController(controller: environment.controller,
                                    defaults: environment.profile.defaults)
        environment.controller.start()
        // The Control Center snapshot and socket (docs/design/controls.md): a
        // release bundle only has one when it carries the extension's group,
        // so the absence of the group simply leaves the controls at rest.
        if let directory = ControlsHost.directory(options: environment.options) {
            let host = ControlsHost(controller: environment.controller, directory: directory)
            host?.start()
            controlsHost = host
        }
        #if !PD_TEST_HOOKS
        // The system does not call perform() for a Focus that has no PocketDeck
        // filter: read what is actually active once at launch so a Focus that
        // ended while the app was closed is "not wanted" (docs/design/focus.md).
        Task { await FocusBridge.refreshFromSystem() }
        #endif
    }

    /// `pocketdeck://open?url=…` (docs/design/links.md).
    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                AppEnvironment.shared.controller.installApk(url)
                continue
            }
            guard let request = OpenLinkRequest.parse(schemeURL: url) else {
                Log.app.notice("ignored an unsupported or invalid pocketdeck URL")
                continue
            }
            AppEnvironment.shared.controller.openLink(request)
        }
    }

    /// Spotlight results for indexed phone apps arrive as an NSUserActivity.
    @MainActor
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        let controller = AppEnvironment.shared.controller
        guard let request = controller.spotlight.continuationRequest(from: userActivity) else { return false }
        controller.openFromSpotlight(request)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock click with no window open brings the Deck back.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { DeckWindow.show() }
        return true
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        controlsHost?.stop()
        AppEnvironment.shared.controller.shutdown()
    }
}

/// The Deck is a SwiftUI `Window` scene; AppKit code reaches it by its identifier.
enum DeckWindow {
    static let id = "deck"

    /// SwiftUI's openWindow action, kept from the Deck's content: the AppKit
    /// menu bar panel is not in a scene, so it cannot ask SwiftUI itself to
    /// show the Deck again after the window was closed.
    @MainActor static var openAction: (() -> Void)?

    @MainActor
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
    }

    /// Bring the Deck front, creating it if it was closed.
    @MainActor
    static func open() {
        if window == nil { openAction?() }
        show()
    }

    @MainActor
    static func show() {
        BackgroundMode.activateApp()
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Scenes

/// The app's entry point: the defaults AppKit and SwiftUI read while they build
/// the first window and the menu bar are registered here, before either runs.
@main
enum PocketDeckMain {
    static func main() {
        // Window state saved by an older build (or by a copy started without a
        // window) must never leave the app without its Deck. Registered, not
        // written: nothing lands in the user's defaults.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true,
                                                  "NSQuitAlwaysKeepsWindows": false])
        // AppKit's own Enter Full Screen in any menu titled View would duplicate
        // the Window menu's item (MenuBar.swift). AppKit reads this while the
        // bar is built, so it is registered before NSApplicationMain, not in
        // applicationDidFinishLaunching (there the bar is already built and the
        // item stays). Registered, not set: the person's defaults stay untouched.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
        PocketDeckApp.main()
    }
}

struct PocketDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = AppEnvironment.shared.controller

    var body: some Scene {
        Window("PocketDeck", id: DeckWindow.id) {
            DeckRoot()
                .environment(controller)
        }
        // R1's 27 letters need 540 pt under the toolbar; 600 gives them room at
        // launch. A shorter window hides the rail rather than shrink its 20 pt
        // targets (DeckIndexRail's ViewThatFits).
        .defaultSize(width: 760, height: 600)
        .windowResizability(.contentMinSize)
        // A saved state from an older build (or none) must never leave the app without its window.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { AppCommands(controller: controller) }

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}
