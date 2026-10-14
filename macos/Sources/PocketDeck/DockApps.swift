// Dock and Launchpad apps (docs/design/dock.md): one small shim bundle per phone
// app gives it a Dock icon, a Launchpad/Spotlight entry and a ⌘-Tab entry.
// Building the bundle and deciding what to clean up are pure (unit-tested); the
// `DockApps` object does the file system, LaunchServices and the shim messages.

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Everything a shim bundle is made from.
struct DockShimSpec: Equatable {
    var deviceId: String
    var pkg: String
    var label: String
    var phoneName: String
    var profile: Profile
    /// The PocketDeck.app the shim launches when it is not running.
    var hostPath: String

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
        ]
    }
}

/// A shim found on disk.
struct DockShimRecord: Equatable {
    var url: URL
    var deviceId: String
    var pkg: String
    var profile: String
    var name: String
}

enum DockShimBuilder {
    /// Writes the bundle into `folder` (replacing one for the same app) and returns its URL.
    /// Signing and LaunchServices registration are the caller's.
    static func build(_ spec: DockShimSpec, in folder: URL, shimBinary: URL, iconPNG: Data?) throws -> URL {
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
        let plist = try PropertyListSerialization.data(fromPropertyList: spec.infoPlist, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if let png = iconPNG, let icns = icns(fromPNG: png) {
            try icns.write(to: resources.appendingPathComponent("AppIcon.icns"))
        }
        return app
    }

    static let icnsSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// An .icns with every standard size, scaled from the phone's PNG icon.
    static func icns(fromPNG png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.icns.identifier as CFString,
                                                                 icnsSizes.count, nil) else { return nil }
        for size in icnsSizes {
            guard let scaled = scale(image, to: size) else { return nil }
            CGImageDestinationAddImage(destination, scaled, nil)
        }
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
                                  name: plist["CFBundleName"] as? String ?? "")
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

    /// Shim pid → the stream of the window it stands for.
    private(set) var bindings: [Int: UInt32] = [:]
    private let center = DistributedNotificationCenter.default()

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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
    }

    func records() -> [DockShimRecord] { DockShimBuilder.records(in: folder, profile: profile) }

    func hasShim(deviceId: String, pkg: String) -> Bool {
        records().contains { $0.deviceId == deviceId && $0.pkg == pkg }
    }

    @discardableResult
    func add(deviceId: String, pkg: String, label: String, phoneName: String, launch: Bool) -> URL? {
        guard let binary = Self.shimBinary else {
            Log.app.error("dock: no shim executable in this build")
            return nil
        }
        // A rename leaves the old bundle under its old file name.
        for record in records() where record.deviceId == deviceId && record.pkg == pkg { remove(record.url) }
        let spec = DockShimSpec(deviceId: deviceId, pkg: pkg, label: label, phoneName: phoneName,
                                profile: profile, hostPath: Bundle.main.bundleURL.path)
        do {
            let url = try DockShimBuilder.build(spec, in: folder, shimBinary: binary,
                                                iconPNG: IconCache.shared.loadData(pkg: pkg, deviceId: deviceId))
            Self.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
            LSRegisterURL(url as CFURL, true)
            Log.app.notice("dock: created \(url.path, privacy: .public)")
            if launch {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            }
            return url
        } catch {
            Log.app.error("dock: could not create \(spec.fileName, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
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
        Log.app.notice("dock: removed \(url.path, privacy: .public)")
    }

    func reconcile(deviceId: String, apps: [AppInfo], phoneName: String) {
        for decision in DockCleanup.plan(records: records(), deviceId: deviceId, apps: apps, phoneName: phoneName) {
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
            add(deviceId: record.deviceId, pkg: record.pkg, label: label, phoneName: phoneName, launch: false)
        }
    }

    private func bundleId(of url: URL) -> String? { Bundle(url: url)?.bundleIdentifier }

    // MARK: Shim messages

    func bind(pid: Int, stream: UInt32) {
        bindings[pid] = stream
        post(DockMessage.opened, pid: pid)
    }

    func stream(forPid pid: Int) -> UInt32? { bindings[pid] }

    /// A window closed: its shim exits.
    func streamClosed(_ stream: UInt32) {
        for (pid, bound) in bindings where bound == stream {
            bindings.removeValue(forKey: pid)
            post(DockMessage.closed, pid: pid)
        }
    }

    /// Received, but no window can open yet (phone connecting): stop the shim's retries.
    func acknowledge(pid: Int) { post(DockMessage.opened, pid: pid) }

    private func post(_ name: Notification.Name, pid: Int) {
        center.postNotificationName(name, object: profile.name, userInfo: [DockMessage.pidKey: pid],
                                    deliverImmediately: true)
    }

    @objc private func openRequested(_ notification: Notification) {
        guard let info = notification.userInfo,
              let deviceId = info[DockMessage.deviceIdKey] as? String,
              let pkg = info[DockMessage.pkgKey] as? String,
              let pid = info[DockMessage.pidKey] as? Int else { return }
        Log.app.notice("dock: open \(pkg, privacy: .public) on \(deviceId, privacy: .public) for shim \(pid, privacy: .public)")
        MainActor.assumeIsolated { onOpen?(deviceId, pkg, pid) }
    }

    @objc private func quitRequested(_ notification: Notification) {
        guard let pid = notification.userInfo?[DockMessage.pidKey] as? Int else { return }
        shimGone(pid)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        shimGone(Int(app.processIdentifier))
    }

    private func shimGone(_ pid: Int) {
        guard let stream = bindings.removeValue(forKey: pid) else { return }
        Log.app.notice("dock: shim \(pid, privacy: .public) quit; closing stream \(stream, privacy: .public)")
        onShimQuit?(stream)
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
