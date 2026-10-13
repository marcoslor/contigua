// Launch-option parsing (the test hooks), the app delegate and the SwiftUI
// app entry. The connection logic lives in ConnectionController.

import AppKit
import SwiftUI

// MARK: - Launch options (see macos/README.md)

struct LaunchOptions {
    var connect: (host: String, port: UInt16)?
    var pairCodeFile: String?
    var openPackages: [String] = []
    var openPhone = false
    var resizes: [(stream: UInt32, size: NSSize, after: TimeInterval)] = []
    var minimizes: [(stream: UInt32, after: TimeInterval)] = []
    var deminimizes: [(stream: UInt32, after: TimeInterval)] = []
    var quitAfter: TimeInterval?
    var resetPairing = false
    var qrSheet = false
    var qrPayloadFile: String?
    var debugInputScript: String?
    var profileName = Profile.defaultName
    /// `--preview STATE`: drive the UI with a scripted state (screenshots).
    var preview: String?
    /// `--appearance light|dark`: force the appearance (screenshots).
    var appearance: String?

    /// nil when `--profile` was missing or not a usable name.
    var profile: Profile? { Profile(name: profileName) }

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 1
        func next() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--connect":
                if let value = next(), let colon = value.lastIndex(of: ":"),
                   let port = UInt16(value[value.index(after: colon)...]) {
                    options.connect = (String(value[..<colon]), port)
                }
            case "--pair-code-file":
                options.pairCodeFile = next()
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
            case "--profile":
                options.profileName = next() ?? ""
            case "--preview":
                options.preview = next()
            case "--appearance":
                options.appearance = next()
            default:
                break
            }
            index += 1
        }
        return options
    }

    /// `N:WxH-pt` — the `-pt` suffix is optional.
    private static func parseResize(_ value: String, defaultDelay: TimeInterval) -> (UInt32, NSSize, TimeInterval) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        let stream = UInt32(parts.first ?? "") ?? 0
        var rest = parts.count > 1 ? parts[1] : ""
        if rest.hasSuffix("-pt") { rest = String(rest.dropLast(3)) }
        let dims = rest.lowercased().split(separator: "x").map(String.init)
        let width = Double(dims.first ?? "") ?? 0
        let height = dims.count > 1 ? (Double(dims[1]) ?? 0) : 0
        return (stream, NSSize(width: width, height: height), defaultDelay)
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
        guard let profile = options.profile else {
            FileHandle.standardError.write(Data("--profile \(options.profileName): use 1-32 of a-z, 0-9 and -\n".utf8))
            exit(2)
        }
        Profile.active = profile
        Log.app.notice("profile \(profile.name, privacy: .public): keychain \(profile.keychainService, privacy: .public), defaults \(profile.defaultsSuiteName ?? "standard", privacy: .public)")
        if options.resetPairing {
            profile.keychain.deleteAll()
            PairKeyStore(profile: profile).lastDeviceId = nil
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
    /// Started from a shell (the test harness) there is no LaunchServices to
    /// make the process a regular app; do it explicitly so it gets windows and a Dock icon.
    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.shared
        switch environment.options.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        NSApp.activate(ignoringOtherApps: true)
        environment.controller.start()
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
        AppEnvironment.shared.controller.shutdown()
    }
}

/// The Deck is a SwiftUI `Window` scene; AppKit code reaches it by its identifier.
enum DeckWindow {
    static let id = "deck"

    @MainActor
    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
    }

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Scenes

@main
struct PocketDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = AppEnvironment.shared.controller
    @AppStorage("showMenuBar", store: AppEnvironment.shared.profile.defaults) private var showMenuBar = true

    init() {
        // Window state saved by an older build (or by a copy started without a
        // window) must never leave the app without its Deck. Registered, not
        // written: nothing lands in the user's defaults.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true,
                                                  "NSQuitAlwaysKeepsWindows": false])
    }

    var body: some Scene {
        Window("PocketDeck", id: DeckWindow.id) {
            DeckRoot()
                .environment(controller)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
        // A saved state from an older build (or none) must never leave the app without its window.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands { AppCommands(controller: controller) }

        Settings {
            SettingsView()
                .environment(controller)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
                .environment(controller)
        } label: {
            MenuBarIcon()
                .environment(controller)
        }
        .menuBarExtraStyle(.menu)
    }
}
