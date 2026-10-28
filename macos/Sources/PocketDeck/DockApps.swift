// Dock and Launchpad apps (docs/design/dock.md): one small shim bundle per phone
// app gives it a Dock icon, a Launchpad/Spotlight entry and a ⌘-Tab entry.
// Building the bundle and deciding what to clean up are pure (unit-tested); the
// `DockApps` object does the file system, LaunchServices and the shim messages.

import AppKit
import ImageIO
import UniformTypeIdentifiers

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

/// The running identities "Show phone apps in the Dock" stops when it turns
/// off: every shim the person did not add by hand. Pinned ones follow the
/// existing rule and keep running (docs/design/dock.md §Lifecycle).
enum DockQuit {
    static func plan(records: [DockShimRecord]) -> [DockShimRecord] {
        records.filter { !$0.pinned }
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
    /// True for the "Add to Dock" path: the person added this identity by hand,
    /// so the Show-phone-apps setting never stops it.
    var pinned = false
    /// The per-bundle token the shim carries in its Info.plist and echoes in
    /// every message (sec L-8). A new bundle gets a fresh one.
    var token = DockToken.make()
    /// The renderer version the icon was drawn with, and whether it came from
    /// the phone's adaptive layers (docs/design/dock.md §Icons).
    var iconVersion = PhoneAppIcon.version
    var iconLayers = false
    /// e2e only: a directory this shim writes its built Dock menu to and reads
    /// a press from (`--debug-control`'s, so a quiet run can read the menu the
    /// Dock would show and press one of its items).
    var menuDebugDir: String?

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
            DockMessage.plistPinned: pinned,
            DockMessage.plistToken: token,
            DockMessage.plistIconVersion: iconVersion,
            DockMessage.plistIconLayers: iconLayers,
        ].merging(agent ? ["LSUIElement": true] : [:]) { current, _ in current }
            .merging(menuDebugDir.map { [DockMessage.plistMenuDebugDir: $0] } ?? [:]) { current, _ in current }
    }
}

/// A shim found on disk.
struct DockShimRecord: Equatable {
    var url: URL
    var deviceId: String
    var pkg: String
    var profile: String
    var name: String
    /// Added by hand ("Add to Dock"); absent in bundles from before the
    /// automatic path existed, which were all added by hand, so it defaults
    /// to true there. Automatic ones write false.
    var pinned = true
    /// The bundle's token (sec L-8); empty in bundles written before it existed,
    /// which the next refresh rebuilds.
    var token = ""
    /// The renderer version its AppIcon.icns was made with (0 when it has none).
    var iconVersion = 0
    /// Whether that icon was drawn from the phone's adaptive layers.
    var iconLayers = false
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
                                  pinned: plist[DockMessage.plistPinned] as? Bool ?? true,
                                  token: plist[DockMessage.plistToken] as? String ?? "",
                                  iconVersion: plist[DockMessage.plistIconVersion] as? Int ?? 0,
                                  iconLayers: plist[DockMessage.plistIconLayers] as? Bool ?? false)
        }.sorted { $0.url.path < $1.url.path }
    }
}

enum DockCleanup: Equatable {
    case remove(URL)
    /// The name shown no longer matches (phone renamed, app relabelled): rebuild with this label.
    case rebuild(DockShimRecord, label: String)

    /// What to do with one phone's shims once its app list arrives.
    static func plan(records: [DockShimRecord], deviceId: String, apps: [AppInfo], phoneName: String) -> [DockCleanup] {
        let labels = Dictionary(apps.map { ($0.pkg, $0.label) }, uniquingKeysWith: { first, _ in first })
        return records.filter { $0.deviceId == deviceId }.compactMap { record in
            guard let label = labels[record.pkg] else { return .remove(record.url) }
            // A bundle from before tokens existed is rebuilt once, by the
            // refresh the host already does on every apps list (sec L-8).
            if record.token.isEmpty { return .rebuild(record, label: label) }
            let wanted = SpotlightIndexer.title(label: label, phoneName: phoneName)
            return record.name == wanted ? nil : .rebuild(record, label: label)
        }
    }

    /// The phone was forgotten: all of its shims go.
    static func planForget(records: [DockShimRecord], deviceId: String) -> [DockCleanup] {
        records.filter { $0.deviceId == deviceId }.map { .remove($0.url) }
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
    /// The app's window menu for a shim (WIN-26): the host builds one list and
    /// every shim of that app renders it.
    var windowMenu: ((String, String) -> [AppWindowMenuRow])?
    /// A row of that menu was picked: deviceId, pkg, the row.
    var onPick: ((String, String, AppWindowMenuRow) -> Void)?
    /// e2e only (`--debug-control`): the directory a new shim is told to dump
    /// its built menu into and read a press from.
    var menuDebugDir: String?

    /// The window a running shim stands for: stream, the phone, and the package
    /// that named it.
    struct Binding: Equatable {
        var stream: UInt32
        var pkg: String
        var deviceId: String = ""
    }

    /// Shim pid → the window (stream, pkg) it stands for.
    private(set) var bindings: [Int: Binding] = [:]
    /// Shim pid → a watch on its exit. NSWorkspace does not report every app's
    /// end (agent shims in background mode), and a killed shim never posts its
    /// quit message; whichever notices first closes the window, once.
    private var exitWatches: [Int: DispatchSourceProcess] = [:]
    private let center = DistributedNotificationCenter.default()
    /// The file system and LaunchServices work of the automatic path runs here:
    /// creating a shim for the first time must never slow the window it stands for.
    private let workQueue = DispatchQueue(label: "dev.pocketdeck.dock", qos: .utility)

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

    init(folder: URL, profile: Profile) {
        self.folder = folder
        self.profile = profile
        super.init()
    }

    var isAvailable: Bool { Self.shimBinary != nil }

    func start() {
        center.addObserver(self, selector: #selector(openRequested(_:)), name: DockMessage.open,
                           object: profile.name, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(quitRequested(_:)), name: DockMessage.quit,
                           object: profile.name, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(pickRequested(_:)), name: DockMessage.pick,
                           object: profile.name, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
    }

    // MARK: Window menus (WIN-26)

    /// Pushes every running shim its app's window menu. The rows are the same
    /// value the Deck cell renders, so the two menus cannot disagree.
    func refreshWindowMenus() {
        guard let windowMenu else { return }
        for record in records() {
            guard let app = runningApp(of: record.url) else { continue }
            send(rows: windowMenu(record.deviceId, record.pkg),
                 pid: Int(app.processIdentifier), record: record)
        }
    }

    /// One shim's menu, when its window opened (it may not have been running
    /// for the last refresh).
    func sendWindowMenu(pid: Int) {
        guard let windowMenu, let bound = bindings[pid],
              let record = records().first(where: { $0.deviceId == bound.deviceId && $0.pkg == bound.pkg })
        else { return }
        send(rows: windowMenu(record.deviceId, record.pkg), pid: pid, record: record)
    }

    private func send(rows: [AppWindowMenuRow], pid: Int, record: DockShimRecord) {
        let messages = rows.map(\.message)
        center.postNotificationName(DockMessage.menu, object: profile.name,
                                    userInfo: [DockMessage.pidKey: pid,
                                               DockMessage.rowsKey: messages],
                                    deliverImmediately: true)
    }

    func records() -> [DockShimRecord] { DockShimBuilder.records(in: folder, profile: profile) }

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
                DispatchQueue.main.async { launched(nil) }
                return
            }
            open(url) { pid in DispatchQueue.main.async { launched(pid) } }
        }
    }

    /// The shim was built before (kept from "Add to Dock") but is idle: launch the
    /// existing bundle for `stream`'s window and bind them.
    func relaunch(deviceId: String, pkg: String, bind stream: UInt32, launched: @escaping (Int?) -> Void) {
        workQueue.async { [self] in
            guard let record = records().first(where: { $0.deviceId == deviceId && $0.pkg == pkg }) else {
                DispatchQueue.main.async { launched(nil) }
                return
            }
            open(record.url) { pid in DispatchQueue.main.async { launched(pid) } }
        }
    }

    /// The synchronous bundle build and registration, shared by the "Add to Dock"
    /// path and the automatic one. Runs on the caller's thread.
    private func make(_ spec: DockShimSpec, shellBinary: URL) -> URL? {
        do {
            var spec = spec
            spec.menuDebugDir = menuDebugDir
            // The icon: the Dock's own 1296 px layers when the phone answered
            // that request, else the Deck's layers upscaled, else the flat icon
            // on the plate. One 1024 px render feeds every .icns size.
            let dockLayers = IconCache.shared.loadLayerData(pkg: spec.pkg, deviceId: spec.deviceId,
                                                            sizeClass: .dock)
            let layers = dockLayers ?? IconCache.shared.loadLayerData(pkg: spec.pkg, deviceId: spec.deviceId)
            let flat = IconCache.shared.loadData(pkg: spec.pkg, deviceId: spec.deviceId)
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

    private func open(_ url: URL, launched: @escaping (Int?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !BackgroundMode.isOn
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            launched(app.map { Int($0.processIdentifier) })
        }
    }

    @discardableResult
    func add(deviceId: String, pkg: String, label: String, phoneName: String, launch: Bool,
             pinned: Bool) -> URL? {
        guard let binary = Self.shimBinary else {
            Log.app.error("dock: no shim executable in this build")
            return nil
        }
        // A rename leaves the old bundle under its old file name.
        for record in records() where record.deviceId == deviceId && record.pkg == pkg { remove(record.url) }
        let spec = DockShimSpec(deviceId: deviceId, pkg: pkg, label: label, phoneName: phoneName,
                                profile: profile, hostPath: Bundle.main.bundleURL.path, pinned: pinned)
        guard let url = make(spec, shellBinary: binary) else { return nil }
        if launch { open(url) { _ in } }
        return url
    }

    func remove(deviceId: String, pkg: String) {
        for record in records() where record.deviceId == deviceId && record.pkg == pkg { remove(record.url) }
    }

    /// Unregister first: LaunchServices keeps a deleted bundle's entry otherwise.
    func remove(_ url: URL) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId(of: url) ?? "")
        where app.bundleURL?.standardizedFileURL == url.standardizedFileURL {
            app.terminate()
        }
        Self.run(Self.lsregister, ["-u", url.path])
        try? FileManager.default.removeItem(at: url)
        Log.app.notice("dock: removed \(url.path, privacy: .private)")
    }

    /// Decisions for a phone's shims. `keep`: packages of open windows — a shim
    /// is neither removed nor rebuilt while it stands for one (its label and
    /// clean-up follow when the window is gone).
    func reconcile(deviceId: String, apps: [AppInfo], phoneName: String, keep: Set<String> = []) {
        let mine = records().filter { $0.deviceId == deviceId && !keep.contains($0.pkg) }
        for decision in DockCleanup.plan(records: mine, deviceId: deviceId, apps: apps, phoneName: phoneName) {
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
        case .rebuild(let record, let label):
            add(deviceId: record.deviceId, pkg: record.pkg, label: label, phoneName: phoneName, launch: false,
                pinned: record.pinned)
        }
    }

    private func bundleId(of url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

    // MARK: Shim messages

    /// The shim is up and its pid now stands for the window of `stream`.
    func bind(pid: Int, stream: UInt32, pkg: String, deviceId: String = "") {
        bindings[pid] = Binding(stream: stream, pkg: pkg, deviceId: deviceId)
        watchExit(of: pid)
        post(DockMessage.opened, pid: pid)
        sendWindowMenu(pid: pid)
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
        for (pid, bound) in bindings where bound.stream == stream {
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

    /// A shim's window menu was picked (WIN-26): the New row opens another
    /// window, a window row raises that one. A message without the shim's token
    /// is ignored, like every other shim message (sec L-8).
    @objc private func pickRequested(_ notification: Notification) {
        guard let info = notification.userInfo,
              let deviceId = info[DockMessage.deviceIdKey] as? String,
              let pkg = info[DockMessage.pkgKey] as? String,
              let pid = info[DockMessage.pidKey] as? Int,
              let messages = info[DockMessage.rowsKey] as? [[String: Any]],
              let row = messages.compactMap(AppWindowMenuRow.init(message:)).first,
              DockToken.matches(message: info[DockMessage.tokenKey] as? String,
                                stored: shimToken(deviceId: deviceId, pkg: pkg)) else { return }
        Log.app.notice("dock: menu pick for \(pkg, privacy: .public) pid \(pid, privacy: .public) — \(row.action == .newWindow ? "new" : "window", privacy: .public)")
        MainActor.assumeIsolated { onPick?(deviceId, pkg, row) }
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
