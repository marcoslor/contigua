// Dock and Launchpad apps (docs/design/dock.md): one small shim bundle per phone
// app gives it a Dock icon, a Launchpad/Spotlight entry and a ⌘-Tab entry.
// Building the bundle and deciding what to clean up are pure (unit-tested); the
// `DockApps` object does the file system, LaunchServices and the shim messages.

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Why a shim exists (docs/design/dock.md §Shortcuts)

/// The reasons one app's shim exists. The bundle stays while the set is
/// non-empty, and removing one origin removes only that origin — so Save all,
/// the Dock item and Add to Applications cannot silently delete each other's
/// shim (docs/design/dock.md §Shortcuts).
enum DockOrigin: String, CaseIterable, Equatable {
    /// "Add to Dock" (today's pinned identity).
    case dock
    /// "Add to Applications": the person asked for this one app's shortcut.
    case manual
    /// The phone's "Save all apps as shortcuts" switch.
    case all
    /// The automatic identity of an open app window (today's unpinned shim).
    case window
}

struct DockOriginSet: OptionSet, Equatable {
    let rawValue: Int

    static let dock = DockOriginSet(rawValue: 1 << 0)
    static let manual = DockOriginSet(rawValue: 1 << 1)
    static let all = DockOriginSet(rawValue: 1 << 2)
    static let window = DockOriginSet(rawValue: 1 << 3)

    /// Every origin, in the order the plist writes them.
    static let every: [DockOrigin] = [.dock, .manual, .all, .window]

    init(rawValue: Int) { self.rawValue = rawValue }

    init(_ origin: DockOrigin) {
        switch origin {
        case .dock: self = .dock
        case .manual: self = .manual
        case .all: self = .all
        case .window: self = .window
        }
    }

    /// Reads PDOrigins. A bundle from before the set existed migrates its
    /// `pinned` marker: pinned (or missing, which the old default was) = dock,
    /// unpinned = window.
    static func migrated(names: [String]?, pinned: Bool) -> DockOriginSet {
        guard let names else { return pinned ? .dock : .window }
        return parse(names)
    }

    static func parse(_ names: [String]) -> DockOriginSet {
        names.reduce(into: DockOriginSet()) { set, name in
            guard let origin = DockOrigin(rawValue: name) else { return }
            set.insert(DockOriginSet(origin))
        }
    }

    /// The stored form, in a stable order.
    var names: [String] {
        Self.every.filter { contains(DockOriginSet($0)) }.map(\.rawValue)
    }
}

/// What one event does to one app's shim. Actions are returned, never performed,
/// so every transition is a pure, exhaustive function (AGENTS.md, CONV-PD-08).
enum DockShimEvent: Equatable {
    case add(DockOrigin)
    case remove(DockOrigin)
    /// An app list from the phone says whether the app is installed and whether
    /// the phone's Save all switch is on.
    case reconcile(saveAll: Bool, installed: Bool)
    case forget
}

enum DockShimAction: Equatable {
    /// Create the bundle, or rewrite it with the new origins.
    case write
    case remove
    case none
}

struct DockShimDecision: Equatable {
    var origins: DockOriginSet
    var action: DockShimAction
}

enum DockOrigins {
    /// The one transition function: every event in every state.
    static func applying(_ event: DockShimEvent, to origins: DockOriginSet) -> DockShimDecision {
        switch event {
        case .add(let origin):
            var next = origins
            next.insert(DockOriginSet(origin))
            return DockShimDecision(origins: next, action: next == origins ? .none : .write)

        case .remove(let origin):
            var next = origins
            next.remove(DockOriginSet(origin))
            guard next != origins else { return DockShimDecision(origins: origins, action: .none) }
            return DockShimDecision(origins: next, action: next.isEmpty ? .remove : .write)

        case .reconcile(let saveAll, let installed):
            var next = origins
            if installed {
                if saveAll { next.insert(.all) } else { next.remove(.all) }
            } else {
                // An uninstalled app keeps only what the person or an open
                // window still asks for.
                next.subtract([.all, .manual])
            }
            guard next != origins else { return DockShimDecision(origins: origins, action: .none) }
            return DockShimDecision(origins: next, action: next.isEmpty ? .remove : .write)

        case .forget:
            return DockShimDecision(origins: [], action: origins.isEmpty ? .none : .remove)
        }
    }
}

// MARK: - Automatic Dock identity (docs/design/dock.md §Lifecycle)

/// The decision for one open app window whose Dock identity is not bound yet:
/// the identity appears with the window, waits for the app's real icon, or is
/// skipped when the person turned the setting off or nothing can act.
enum DockFollow: Equatable {
    /// Whether the phone's icon package state is known.
    enum IconState: Equatable { case cached, reportedMissing, unknown }

    /// The setting is off (menu "Add to Dock" still works), this build cannot
    /// make shims, or an instance already represents the app.
    case skip
    /// The shim is on disk and idle: launch it for the window.
    case launchExisting
    /// Build the bundle and launch it.
    case createAndLaunch
    /// The icon is not cached yet: wait for it (or the phone saying there is
    /// none) instead of putting a blank tile in the Dock.
    case wait

    static func decide(settingOn: Bool, shimBinary: Bool, phoneKnown: Bool,
                       shimExists: Bool, shimRunning: Bool, shimHasIcon: Bool,
                       shimIconVersion: Int = PhoneAppIcon.version, shimIconLayers: Bool = true,
                       hasLayers: Bool = true, icon: IconState) -> DockFollow {
        guard settingOn, shimBinary, phoneKnown else { return .skip }
        if shimRunning { return .skip }
        // A bundle without its icon is rebuilt (or built) once the icon is known;
        // an unknown icon waits, so the Dock never shows a blank tile.
        if shimExists, shimHasIcon {
            // An icon from an older renderer, or a plate drawn while the phone
            // had no layers yet, is stale: rebuild it (docs/design/dock.md §Icons).
            let current = shimIconVersion >= PhoneAppIcon.version && (!hasLayers || shimIconLayers)
            if current || icon == .reportedMissing { return .launchExisting }
            return icon == .unknown ? .wait : .createAndLaunch
        }
        if shimExists, icon == .reportedMissing { return .launchExisting }
        return icon == .unknown ? .wait : .createAndLaunch
    }
}

/// The Settings → General switch for the automatic Dock identity
/// (docs/design/dock.md §Lifecycle). On unless the person turned it off.
enum DockAutoSetting {
    static let key = "showAppsInDock"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// The phone page's "Save all apps as shortcuts", per phone id in the profile's
/// defaults like the other per-phone choices (docs/design/dock.md §Shortcuts).
/// Off by default: a shortcut for every app is a lot of files, so the person
/// asks for it.
enum SaveAllShortcutsSetting {
    static let key = "saveAllAppsAsShortcuts"

    static func read(from defaults: UserDefaults, deviceId: String) -> Bool {
        guard !deviceId.isEmpty else { return false }
        return (defaults.dictionary(forKey: key) as? [String: Bool])?[deviceId] ?? false
    }

    static func write(_ on: Bool, for deviceId: String, to defaults: UserDefaults) {
        guard !deviceId.isEmpty else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        if on { all[deviceId] = true } else { all.removeValue(forKey: deviceId) }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }
}

/// The running identities "Show phone apps in the Dock" stops when it turns
/// off: every shim the person did not add by hand. Pinned ones follow the
/// existing rule and keep running (docs/design/dock.md §Lifecycle).
enum DockQuit {
    static func plan(records: [DockShimRecord]) -> [DockShimRecord] {
        records.filter { !$0.pinned }
    }
}

/// What to do with an automatic shim once its launch finishes: bind it to the
/// window it was started for, or stop it. A launch can finish after that window
/// closed; binding it then leaves a Dock icon nothing will ever close again
/// (docs/design/dock.md §Lifecycle).
enum DockLaunchLanding: Equatable {
    /// No shim was started (the build or the launch failed).
    case nothing
    /// The window is still open: the pid is its identity now.
    case bind
    /// The window closed meanwhile: the shim must quit and must never be bound.
    case quitWindowClosed
    /// The setting turned off while it launched and it was not added by hand.
    case quitSettingOff
    /// PocketDeck is quitting: an unbound automatic launch is stopped.
    case quitShuttingDown
}

enum DockLaunch {
    static func landing(pid: Int?, windowOpen: Bool, settingOn: Bool, pinned: Bool,
                        quitting: Bool = false) -> DockLaunchLanding {
        guard pid != nil else { return .nothing }
        // PocketDeck quitting: an automatic launch that has not been bound yet
        // has no window to follow, so it is stopped with the app.
        if quitting { return .quitShuttingDown }
        // The window closed while the bundle was built or the shim launched.
        if !windowOpen { return .quitWindowClosed }
        return settingOn || pinned ? .bind : .quitSettingOff
    }
}

/// Everything a shim bundle is made from.
struct DockShimSpec: Equatable {
    var deviceId: String
    var pkg: String
    var label: String
    var phoneName: String
    var profile: Profile
    /// The PocketDeck.app the shim launches when it is not running.
    var hostPath: String
    /// Background mode's shims are agents (LSUIElement): no Dock tile, no ⌘-Tab entry.
    var agent = BackgroundMode.isOn
    /// Why this bundle exists (docs/design/dock.md §Shortcuts): Add to Dock,
    /// Add to Applications, Save all, or an open window. The plist carries the
    /// whole set, so a rebuild for one origin keeps the others.
    var origins: DockOriginSet = .window
    /// The per-bundle token the shim carries in its Info.plist and echoes in
    /// every message (sec L-8). A new bundle gets a fresh one.
    var token = DockToken.make()
    /// The renderer version the icon was drawn with, and whether it came from
    /// the phone's adaptive layers (docs/design/dock.md §Icons).
    var iconVersion = PhoneAppIcon.version
    var iconLayers = false

    /// "WhatsApp (Pixel)", like the Spotlight titles.
    var displayName: String { SpotlightIndexer.title(label: label, phoneName: phoneName) }

    /// `dev.pocketdeck.dock.[<profile>.]<deviceId>.<pkg>`; every piece reduced to `[A-Za-z0-9-]`.
    var bundleIdentifier: String {
        let profilePart = profile.isDefault ? "" : "\(DockShimSpec.idPart(profile.name))."
        return "dev.pocketdeck.dock.\(profilePart)\(DockShimSpec.idPart(deviceId)).\(DockShimSpec.idPart(pkg))"
    }

    /// The bundle's file name: no path separators, no hidden file, bounded length.
    var fileName: String {
        var name = displayName.map { $0 == "/" || $0 == ":" ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = DockShimSpec.idPart(pkg) }
        return String(name.prefix(200)) + ".app"
    }

    /// A bundle-id component: letters, digits and `-` only (`.` would add levels,
    /// anything else is invalid); never empty.
    static func idPart(_ value: String) -> String {
        let mapped = String(value.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-") ? Character(scalar) : "-"
        })
        return mapped.isEmpty ? "x" : mapped
    }

    var infoPlist: [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": DockMessage.shimExecutable,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleIconFile": "AppIcon",
            "LSMinimumSystemVersion": "26.0",
            "LSApplicationCategoryType": "public.app-category.utilities",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            DockMessage.plistDeviceId: deviceId,
            DockMessage.plistPackage: pkg,
            DockMessage.plistProfile: profile.name,
            DockMessage.plistHostPath: hostPath,
            DockMessage.plistLabel: label,
            DockMessage.plistOrigins: origins.names,
            DockMessage.plistToken: token,
            DockMessage.plistIconVersion: iconVersion,
            DockMessage.plistIconLayers: iconLayers,
        ].merging(agent ? ["LSUIElement": true] : [:]) { current, _ in current }
    }
}

/// A shim found on disk.
struct DockShimRecord: Equatable {
    var url: URL
    var deviceId: String
    var pkg: String
    var profile: String
    var name: String
    /// Why the bundle exists (docs/design/dock.md §Shortcuts). A bundle from
    /// before the set existed migrates its `pinned` marker (dock or window).
    var origins: DockOriginSet
    /// The app's raw label (PDLabel); empty in bundles from before it existed.
    var label = ""
    /// The bundle's token (sec L-8); empty in bundles written before it existed,
    /// which the next refresh rebuilds.
    var token = ""
    /// The renderer version its AppIcon.icns was made with (0 when it has none).
    var iconVersion = 0
    /// Whether that icon was drawn from the phone's adaptive layers.
    var iconLayers = false

    /// Added by hand to the Dock ("Add to Dock"): the Show-phone-apps setting
    /// never stops these.
    var pinned: Bool { origins.contains(.dock) }
}

enum DockShimBuilder {
    /// Writes the bundle into `folder` (replacing one for the same app) and returns its URL.
    /// Signing and LaunchServices registration are the caller's.
    static func build(_ spec: DockShimSpec, in folder: URL, shimBinary: URL, icon: CGImage?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent(spec.fileName, isDirectory: true)
        try? fm.removeItem(at: app)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.copyItem(at: shimBinary, to: macOS.appendingPathComponent(DockMessage.shimExecutable))
        var used = spec
        used.iconVersion = PhoneAppIcon.version
        used.iconLayers = icon != nil && spec.iconLayers
        let plist = try PropertyListSerialization.data(fromPropertyList: used.infoPlist, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if let icon, let icns = icns(from: icon) {
            try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
        }
        return app
    }

    static let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// ICNS chunk types, including the 1024 px `ic10` that ImageIO's writer
    /// drops (it stops at 512). PNG data is accepted for all of them.
    private static let icnsTypes: [(type: String, size: Int)] = [
        ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
        ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ]

    /// An .icns with every standard size up to 1024, all scaled from one
    /// 1024 px render (docs/design/dock.md §Icons).
    static func icns(from image: CGImage) -> Data? {
        var body = Data()
        for entry in icnsTypes {
            guard let scaled = scale(image, to: entry.size), let png = png(scaled) else { return nil }
            body.append(entry.type.data(using: .ascii)!)
            body.appendBigEndian(UInt32(png.count + 8))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.appendBigEndian(UInt32(body.count + 8))
        file.append(body)
        return file
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func scale(_ image: CGImage, to size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }

    /// The shims in `folder` made for `profile`; anything else there is ignored.
    static func records(in folder: URL, profile: Profile) -> [DockShimRecord] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" }.compactMap { url in
            let plistURL = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let deviceId = plist[DockMessage.plistDeviceId] as? String,
                  let pkg = plist[DockMessage.plistPackage] as? String,
                  let owner = plist[DockMessage.plistProfile] as? String, owner == profile.name
            else { return nil }
            return DockShimRecord(url: url, deviceId: deviceId, pkg: pkg, profile: owner,
                                  name: plist["CFBundleName"] as? String ?? "",
                                  origins: DockOriginSet.migrated(names: plist[DockMessage.plistOrigins] as? [String],
                                                                 pinned: plist[DockMessage.plistPinned] as? Bool ?? true),
                                  label: plist[DockMessage.plistLabel] as? String ?? "",
                                  token: plist[DockMessage.plistToken] as? String ?? "",
                                  iconVersion: plist[DockMessage.plistIconVersion] as? Int ?? 0,
                                  iconLayers: plist[DockMessage.plistIconLayers] as? Bool ?? false)
        }.sorted { $0.url.path < $1.url.path }
    }
}

enum DockCleanup: Equatable {
    case remove(URL)
    /// The name shown no longer matches, or the origins changed (an app list
    /// without the app, Save all on/off): rebuild with this label and set.
    case rebuild(DockShimRecord, label: String, origins: DockOriginSet)

    /// What to do with one phone's shims once its app list arrives
    /// (docs/design/dock.md §Shortcuts): an uninstalled app loses `all` and
    /// `manual`; a renamed app or phone is rebuilt; Save all adds or removes
    /// `all`; the rest stay untouched.
    static func plan(records: [DockShimRecord], deviceId: String, apps: [AppInfo], phoneName: String,
                     saveAll: Bool = false) -> [DockCleanup] {
        let labels = Dictionary(apps.map { ($0.pkg, $0.label) }, uniquingKeysWith: { first, _ in first })
        return records.filter { $0.deviceId == deviceId }.compactMap { record in
            let installed = labels[record.pkg] != nil
            let decision = DockOrigins.applying(.reconcile(saveAll: saveAll, installed: installed),
                                                to: record.origins)
            switch decision.action {
            case .remove:
                return .remove(record.url)
            case .write:
                let label = labels[record.pkg] ?? record.label
                return .rebuild(record, label: label, origins: decision.origins)
            case .none:
                // A shim kept by the Dock or a window after its app left the
                // phone keeps its name until the app comes back.
                guard installed, let label = labels[record.pkg] else { return nil }
                // A bundle from before tokens existed is rebuilt once, by the
                // refresh the host already does on every apps list (sec L-8).
                if record.token.isEmpty { return .rebuild(record, label: label, origins: record.origins) }
                let wanted = SpotlightIndexer.title(label: label, phoneName: phoneName)
                return record.name == wanted ? nil : .rebuild(record, label: label, origins: record.origins)
            }
        }
    }

    /// The phone was forgotten: all of its shims go, whatever their origins.
    static func planForget(records: [DockShimRecord], deviceId: String) -> [DockCleanup] {
        records.filter { $0.deviceId == deviceId }.map { .remove($0.url) }
    }
}

/// One app's Save all work: the origins the shim should end with, and whether
/// to write or remove it. Built from the same transitions as everything else,
/// so Save all cannot invent a second rule (docs/design/dock.md §Shortcuts).
struct DockSaveAllStep: Equatable {
    var pkg: String
    var label: String
    var origins: DockOriginSet
    var action: DockShimAction
}

enum DockSaveAll {
    /// On: every app of the phone gains `all`. Off: every shim of the phone
    /// loses only `all`; one kept by another origin stays (rewritten), the rest
    /// are removed. `apps` may be the cached list for an offline phone.
    static func plan(apps: [AppInfo], records: [DockShimRecord], deviceId: String, on: Bool) -> [DockSaveAllStep] {
        let mine = records.filter { $0.deviceId == deviceId }
        if !on {
            return mine.compactMap { record in
                let decision = DockOrigins.applying(.reconcile(saveAll: false, installed: true), to: record.origins)
                guard decision.action != .none else { return nil }
                return DockSaveAllStep(pkg: record.pkg, label: record.label, origins: decision.origins,
                                       action: decision.action)
            }
        }
        let byPkg = Dictionary(mine.map { ($0.pkg, $0) }, uniquingKeysWith: { first, _ in first })
        return apps.map { app in
            let origins = byPkg[app.pkg]?.origins ?? []
            let decision = DockOrigins.applying(.reconcile(saveAll: true, installed: true), to: origins)
            return DockSaveAllStep(pkg: app.pkg, label: app.label, origins: decision.origins, action: decision.action)
        }.filter { $0.action != .none }
    }
}

// MARK: - Runtime

final class DockApps: NSObject {
    let folder: URL
    let profile: Profile
    /// Open (or focus) the window for a shim: deviceId, pkg, shim pid.
    var onOpen: ((String, String, Int) -> Void)?
    /// Close the window bound to a shim that quit.
    var onShimQuit: ((UInt32) -> Void)?

    /// The window a running shim stands for: stream + the package that named it.
    struct Binding: Equatable {
        var stream: UInt32
        var pkg: String
    }

    /// Shim pid → the window (stream, pkg) it stands for.
    private(set) var bindings: [Int: Binding] = [:]
    /// Automatic shims this app launched that no window is bound to yet: a quit
    /// can land between the launch and the bind (docs/design/dock.md §Lifecycle).
    private var unboundLaunches: Set<Int> = []
    private let launchLock = NSLock()
    /// Shim pid → a watch on its exit. NSWorkspace does not report every app's
    /// end (agent shims in background mode), and a killed shim never posts its
    /// quit message; whichever notices first closes the window, once.
    private var exitWatches: [Int: DispatchSourceProcess] = [:]
    private let center = DistributedNotificationCenter.default()
    /// The file system and LaunchServices work of the automatic path runs here:
    /// creating a shim for the first time must never slow the window it stands for.
    private let workQueue = DispatchQueue(label: "dev.pocketdeck.dock", qos: .utility)
    /// e2e race hook: hold the automatic launch's pid callback back, the way a
    /// slow launch would. Zero outside the harness.
    private let bindDelay: TimeInterval

    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// `--dock-dir`, else ~/Applications/PocketDeck Apps for the user's own app, else the
    /// profile's Application Support folder (a test profile never touches ~/Applications).
    static func defaultFolder(profile: Profile, override: String?) -> URL {
        if let override { return URL(fileURLWithPath: override, isDirectory: true) }
        let fm = FileManager.default
        if profile.isDefault {
            return fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/PocketDeck Apps", isDirectory: true)
        }
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("Dock Apps", isDirectory: true)
    }

    /// The shim executable bundled next to ours; nil when not running from a bundle.
    static var shimBinary: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: DockMessage.shimExecutable),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    init(folder: URL, profile: Profile, bindDelay: TimeInterval = 0) {
        self.folder = folder
        self.profile = profile
        self.bindDelay = bindDelay
        super.init()
    }

    var isAvailable: Bool { Self.shimBinary != nil }

    func start() {
        center.addObserver(self, selector: #selector(openRequested(_:)), name: DockMessage.open,
                           object: profile.name, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(quitRequested(_:)), name: DockMessage.quit,
                           object: profile.name, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
    }

    func records() -> [DockShimRecord] { DockShimBuilder.records(in: folder, profile: profile) }

    /// Every package of this phone that has a shortcut bundle: those are not
    /// indexed into CoreSpotlight a second time (docs/design/dock.md §Shortcuts).
    func shimPackages(deviceId: String) -> Set<String> {
        Set(records().filter { $0.deviceId == deviceId }.map(\.pkg))
    }

    /// Why this app's shim exists right now (empty when it has none).
    func origins(deviceId: String, pkg: String) -> DockOriginSet {
        records().first { $0.deviceId == deviceId && $0.pkg == pkg }?.origins ?? []
    }

    func hasShim(deviceId: String, pkg: String) -> Bool {
        records().contains { $0.deviceId == deviceId && $0.pkg == pkg }
    }

    /// A running instance made from this profile's shim bundle for the app.
    func isRunning(deviceId: String, pkg: String) -> Bool {
        records().contains { record in
            record.deviceId == deviceId && record.pkg == pkg && isRunning(record.url)
        }
    }

    /// Whether the app's shim was added by hand ("Add to Dock"); such an
    /// identity follows the existing rule and never stops with the setting.
    func isPinned(deviceId: String, pkg: String) -> Bool {
        records().first { $0.deviceId == deviceId && $0.pkg == pkg }?.pinned ?? false
    }

    private func isRunning(_ url: URL) -> Bool { runningApp(of: url) != nil }

    /// The running instance of a shim bundle, if any.
    private func runningApp(of url: URL) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId(of: url) ?? "").first {
            $0.bundleURL?.standardizedFileURL == url.standardizedFileURL
        }
    }

    /// Whether the shim bundle carries the phone's icon (docs/design/dock.md: no blank tiles).
    func shimHasIcon(deviceId: String, pkg: String) -> Bool {
        records().contains { record in
            record.deviceId == deviceId && record.pkg == pkg
                && FileManager.default.fileExists(atPath: record.url
                    .appendingPathComponent("Contents/Resources/AppIcon.icns").path)
        }
    }

    /// What the shim's icon was drawn with: the renderer version and whether
    /// adaptive layers were used (docs/design/dock.md §Icons).
    func shimIconInfo(deviceId: String, pkg: String) -> (version: Int, layers: Bool)? {
        records().first { $0.deviceId == deviceId && $0.pkg == pkg }
            .map { ($0.iconVersion, $0.iconLayers) }
    }

    // MARK: Automatic identity (docs/design/dock.md §Lifecycle)

    /// The setting turned off: stop the running identities the person did not
    /// add by hand. Each stops without closing its window — the shim was only
    /// the Dock identity — and the bundle stays on disk.
    func quitUnpinnedShims() {
        for record in DockQuit.plan(records: records()) {
            guard let app = runningApp(of: record.url) else { continue }
            quit(pid: Int(app.processIdentifier))
        }
    }

    /// Ask a shim to quit without treating it as the person quitting it: its
    /// binding goes first, so its window is not closed with it.
    func quit(pid: Int) {
        launchLock.lock()
        unboundLaunches.remove(pid)
        launchLock.unlock()
        exitWatches.removeValue(forKey: pid)?.cancel()
        bindings.removeValue(forKey: pid)
        NSRunningApplication(processIdentifier: pid_t(pid))?.terminate()
    }

    /// Builds the shim for a phone app whose window opened and launches it, bound
    /// to `stream`'s window. The file work runs off the main thread: the window
    /// never waits for the build; `launched` reports the shim pid once it is up.
    func buildAndLaunch(_ spec: DockShimSpec, bind stream: UInt32, launched: @escaping (Int?) -> Void) {
        workQueue.async { [self] in
            guard let binary = Self.shimBinary, let url = make(spec, shellBinary: binary) else {
                DispatchQueue.main.async { launched(nil) }  // gcd: one main hop from the work queue
                return
            }
            open(url, arguments: DockApps.automaticArguments, delayedLaunch: true, automatic: true) { pid in
                DispatchQueue.main.async { launched(pid) }  // gcd: one main hop from the work queue
            }
        }
    }

    /// The shim was built before (kept from "Add to Dock" or a shortcut) but is
    /// idle: launch the existing bundle for `stream`'s window and bind them. The
    /// bundle records the window as one more reason it exists, so Save all can
    /// be turned off without deleting the identity of an open window.
    func relaunch(deviceId: String, pkg: String, label: String, phoneName: String,
                  bind stream: UInt32, launched: @escaping (Int?) -> Void) {
        workQueue.async { [self] in
            guard let record = records().first(where: { $0.deviceId == deviceId && $0.pkg == pkg }) else {
                DispatchQueue.main.async { launched(nil) }  // gcd: one main hop from the work queue
                return
            }
            var url = record.url
            let origins = record.origins.union(.window)
            if origins != record.origins,
               let rebuilt = add(deviceId: deviceId, pkg: pkg, label: label, phoneName: phoneName,
                                 launch: false, origins: origins) {
                url = rebuilt
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                DispatchQueue.main.async { launched(nil) }  // gcd: one main hop from the work queue
                return
            }
            open(url, arguments: DockApps.automaticArguments, delayedLaunch: true, automatic: true) { pid in
                DispatchQueue.main.async { launched(pid) }  // gcd: one main hop from the work queue
            }
        }
    }

    /// Automatic launches stand for a window that is already open, so their
    /// shim must not ask the host to open one: the host binds it or stops it.
    /// A manual launch (Dock click, Launchpad) keeps its open request.
    static let automaticArguments = ["--no-open"]

    /// The synchronous bundle build and registration, shared by the "Add to Dock"
    /// path and the automatic one. Runs on the caller's thread.
    private func make(_ spec: DockShimSpec, shellBinary: URL) -> URL? {
        do {
            // The icon: the Dock's own 1296 px reply when the phone answered
            // that request, else the Deck's layers upscaled. The flat follows
            // the same rule: its 864 px copy in the Dock's slot, not the Deck's
            // 288 px one (docs/design/dock.md §Icons). One 1024 px render feeds
            // every .icns size.
            let dockLayers = IconCache.shared.loadLayerData(pkg: spec.pkg, deviceId: spec.deviceId,
                                                            sizeClass: .dock)
            let layers = dockLayers ?? IconCache.shared.loadLayerData(pkg: spec.pkg, deviceId: spec.deviceId)
            let flat = IconCache.shared.loadData(pkg: spec.pkg, deviceId: spec.deviceId, sizeClass: .dock)
                ?? IconCache.shared.loadData(pkg: spec.pkg, deviceId: spec.deviceId)
            let icon = PhoneAppIcon.render(fg: layers?.fg, bg: layers?.bg, flat: flat, px: 1024)
            var withIcon = spec
            withIcon.iconLayers = layers != nil
            let url = try DockShimBuilder.build(withIcon, in: folder, shimBinary: shellBinary, icon: icon)
            Self.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
            LSRegisterURL(url as CFURL, true)
            // A rebuilt bundle replaces its icon in place: LaunchServices must
            // re-read it or the Dock keeps showing the old one.
            Self.run(Self.lsregister, ["-f", url.path])
            Log.app.notice("dock: created \(url.path, privacy: .private)")
            return url
        } catch {
            Log.app.error("dock: could not create \(spec.fileName, privacy: .private): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func open(_ url: URL, arguments: [String] = [], delayedLaunch: Bool = false,
                      automatic: Bool = false, launched: @escaping (Int?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !BackgroundMode.isOn
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, _ in
            let pid = app.map { Int($0.processIdentifier) }
            // Recorded before the callback is (possibly) held back: a quit must
            // still find a shim whose launch has not been bound yet.
            if automatic, let pid = pid { self?.noteUnboundLaunch(pid) }
            let deliver = { launched(pid) }
            guard delayedLaunch, let delay = self?.bindDelay, delay > 0 else {
                DispatchQueue.main.async(execute: deliver)  // gcd: one main hop from the open callback
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: deliver)  // gcd: e2e hold of that hop
        }
    }

    private func noteUnboundLaunch(_ pid: Int) {
        launchLock.lock()
        unboundLaunches.insert(pid)
        launchLock.unlock()
    }

    /// Stops every automatic shim a launch handed us that no window owns. The
    /// app's quit path calls this after it has waited for in-flight launches.
    func quitUnboundLaunches() {
        launchLock.lock()
        let pids = unboundLaunches
        unboundLaunches.removeAll()
        launchLock.unlock()
        for pid in pids { quit(pid: pid) }
    }

    @discardableResult
    func add(deviceId: String, pkg: String, label: String, phoneName: String, launch: Bool,
             origins: DockOriginSet) -> URL? {
        guard let binary = Self.shimBinary else {
            Log.app.error("dock: no shim executable in this build")
            return nil
        }
        // A rebuild for a name or an origin change keeps the bundle's token and
        // its running identity: the person's window stays open and the shim's
        // messages still match (sec L-8); a brand-new bundle gets a fresh one.
        let existing = records().first { $0.deviceId == deviceId && $0.pkg == pkg }
        // A rename leaves the old bundle under its old file name.
        for record in records() where record.deviceId == deviceId && record.pkg == pkg {
            remove(record.url, terminating: false)
        }
        var spec = DockShimSpec(deviceId: deviceId, pkg: pkg, label: label, phoneName: phoneName,
                                profile: profile, hostPath: Bundle.main.bundleURL.path, origins: origins)
        if let token = existing?.token, !token.isEmpty { spec.token = token }
        guard let url = make(spec, shellBinary: binary) else { return nil }
        if launch { open(url) { _ in } }
        return url
    }

    /// Save all may build ~230 bundles: the file work stays off the main
    /// thread, one app at a time, and `done` reports on main.
    func addInBackground(deviceId: String, pkg: String, label: String, phoneName: String,
                         origins: DockOriginSet, done: @escaping (Bool) -> Void) {
        workQueue.async { [self] in // gcd: the file work runs on DockApps' serial utility queue
            let url = add(deviceId: deviceId, pkg: pkg, label: label, phoneName: phoneName,
                          launch: false, origins: origins)
            DispatchQueue.main.async { done(url != nil) } // gcd: the caller reads main-actor state
        }
    }

    /// Save all off removes bundles off the main thread too.
    func removeInBackground(deviceId: String, pkg: String, done: @escaping () -> Void) {
        workQueue.async { [self] in // gcd: the file work runs on DockApps' serial utility queue
            remove(deviceId: deviceId, pkg: pkg)
            DispatchQueue.main.async { done() } // gcd: the caller reads main-actor state
        }
    }

    func remove(deviceId: String, pkg: String) {
        for record in records() where record.deviceId == deviceId && record.pkg == pkg { remove(record.url) }
    }

    /// Unregister first: LaunchServices keeps a deleted bundle's entry otherwise.
    /// `terminating` false rebuilds the bundle in place (an origin or a name
    /// changed) without closing the window its running shim stands for.
    func remove(_ url: URL, terminating: Bool = true) {
        if terminating {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId(of: url) ?? "")
            where app.bundleURL?.standardizedFileURL == url.standardizedFileURL {
                app.terminate()
            }
        }
        Self.run(Self.lsregister, ["-u", url.path])
        try? FileManager.default.removeItem(at: url)
        Log.app.notice("dock: removed \(url.path, privacy: .private)")
    }

    /// Decisions for a phone's shims. `keep`: packages of open windows — a shim
    /// is neither removed nor rebuilt while it stands for one (its label and
    /// clean-up follow when the window is gone). `saveAll` is the phone's
    /// switch, so the same refresh also adds or drops `all`.
    func reconcile(deviceId: String, apps: [AppInfo], phoneName: String, keep: Set<String> = [],
                   saveAll: Bool = false) {
        let mine = records().filter { $0.deviceId == deviceId && !keep.contains($0.pkg) }
        for decision in DockCleanup.plan(records: mine, deviceId: deviceId, apps: apps,
                                         phoneName: phoneName, saveAll: saveAll) {
            apply(decision, phoneName: phoneName)
        }
    }

    func forget(deviceId: String) {
        for decision in DockCleanup.planForget(records: records(), deviceId: deviceId) {
            apply(decision, phoneName: "")
        }
    }

    private func apply(_ decision: DockCleanup, phoneName: String) {
        switch decision {
        case .remove(let url):
            remove(url)
        case .rebuild(let record, let label, let origins):
            add(deviceId: record.deviceId, pkg: record.pkg, label: label, phoneName: phoneName, launch: false,
                origins: origins)
        }
    }

    /// The person removed the Dock origin: a shim another origin keeps stays on
    /// disk, but a running one that is not standing for a window stops, as
    /// removing the whole bundle used to.
    func quitIfUnbound(deviceId: String, pkg: String) {
        guard let record = records().first(where: { $0.deviceId == deviceId && $0.pkg == pkg }),
              let app = runningApp(of: record.url) else { return }
        let pid = Int(app.processIdentifier)
        guard bindings[pid] == nil else { return }
        quit(pid: pid)
    }

    private func bundleId(of url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

    // MARK: Shim messages

    /// The shim is up and its pid now stands for the window of `stream`.
    func bind(pid: Int, stream: UInt32, pkg: String) {
        launchLock.lock()
        unboundLaunches.remove(pid)
        launchLock.unlock()
        bindings[pid] = Binding(stream: stream, pkg: pkg)
        watchExit(of: pid)
        post(DockMessage.opened, pid: pid)
    }

    private func watchExit(of pid: Int) {
        guard exitWatches[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.shimExited(pid) }
        exitWatches[pid] = source
        source.resume()
        // Gone before the watch started: the source would never fire.
        if kill(pid_t(pid), 0) != 0, errno == ESRCH { shimExited(pid) }
    }

    func stream(forPid pid: Int) -> UInt32? { bindings[pid]?.stream }

    /// The shim standing for `stream`, if any.
    func binding(stream: UInt32) -> (pid: Int, pkg: String)? {
        bindings.first { $0.value.stream == stream }.map { ($0.key, $0.value.pkg) }
    }

    var boundStreams: Set<UInt32> { Set(bindings.values.map(\.stream)) }

    /// The identity moves to another window of the same app instead of leaving.
    func rebind(pid: Int, to stream: UInt32) {
        guard var binding = bindings[pid] else { return }
        binding.stream = stream
        bindings[pid] = binding
    }

    /// A window closed: its shim exits.
    func streamClosed(_ stream: UInt32) {
        let pids = bindings.filter { $0.value.stream == stream }.map(\.key)
        if pids.isEmpty {
            Log.app.notice("dock: stream \(stream, privacy: .public) closed; no shim bound")
        } else {
            Log.app.notice("dock: stream \(stream, privacy: .public) closed; stopping \(pids.count, privacy: .public) shim(s)")
        }
        for (pid, binding) in bindings where binding.stream == stream {
            bindings.removeValue(forKey: pid)
            exitWatches.removeValue(forKey: pid)?.cancel()
            post(DockMessage.closed, pid: pid)
        }
    }

    /// Received, but no window can open yet (phone connecting): stop the shim's retries.
    func acknowledge(pid: Int) { post(DockMessage.opened, pid: pid) }

    private func post(_ name: Notification.Name, pid: Int) {
        center.postNotificationName(name, object: profile.name, userInfo: [DockMessage.pidKey: pid],
                                    deliverImmediately: true)
    }

    /// The token stored in the bundle for this app, if there is one.
    private func shimToken(deviceId: String, pkg: String) -> String? {
        records().first { $0.deviceId == deviceId && $0.pkg == pkg && !$0.token.isEmpty }?.token
    }

    @objc private func openRequested(_ notification: Notification) {
        guard let info = notification.userInfo,
              let deviceId = info[DockMessage.deviceIdKey] as? String,
              let pkg = info[DockMessage.pkgKey] as? String,
              let pid = info[DockMessage.pidKey] as? Int else { return }
        // sec L-8: DistributedNotificationCenter is open to every local process;
        // only a message carrying the token stored in that shim's Info.plist
        // may open a window. The token itself is never logged.
        guard DockToken.matches(message: info[DockMessage.tokenKey] as? String,
                                stored: shimToken(deviceId: deviceId, pkg: pkg)) else {
            Log.app.notice("dock: ignored open for \(pkg, privacy: .public) on \(deviceId, privacy: .public): no matching shim token")
            return
        }
        Log.app.notice("dock: open \(pkg, privacy: .public) on \(deviceId, privacy: .public) for shim \(pid, privacy: .public)")
        MainActor.assumeIsolated { onOpen?(deviceId, pkg, pid) }
    }

    @objc private func quitRequested(_ notification: Notification) {
        guard let info = notification.userInfo,
              let pid = info[DockMessage.pidKey] as? Int,
              let deviceId = info[DockMessage.deviceIdKey] as? String,
              let pkg = info[DockMessage.pkgKey] as? String else { return }
        // The exit watch covers a shim whose quit is rejected; a forged quit
        // must not be able to close a window.
        guard DockToken.matches(message: info[DockMessage.tokenKey] as? String,
                                stored: shimToken(deviceId: deviceId, pkg: pkg)) else {
            Log.app.notice("dock: ignored quit for \(pkg, privacy: .public): no matching shim token")
            return
        }
        shimExited(pid)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        shimExited(Int(app.processIdentifier))
    }

    /// The shim quit (its message, NSWorkspace or the exit watch): its window
    /// closes. Safe to call more than once for the same pid.
    func shimExited(_ pid: Int) {
        exitWatches.removeValue(forKey: pid)?.cancel()
        guard let bound = bindings.removeValue(forKey: pid) else { return }
        Log.app.notice("dock: shim \(pid, privacy: .public) quit; closing stream \(bound.stream, privacy: .public)")
        onShimQuit?(bound.stream)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private extension Data {
    /// The four-byte big-endian length an ICNS chunk starts with.
    mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
