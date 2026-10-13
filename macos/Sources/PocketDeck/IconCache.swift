// App icons on disk, one folder per phone: a package name means a different
// icon on every phone (and on the test phones the harness runs), so icons are
// keyed by device id + package. Files from before that (`<pkg>.png` straight
// in the profile's folder) are never read again; non-default profiles delete
// them, the default profile leaves the user's files alone.

import AppKit

final class IconCache {
    static let shared = IconCache(profile: .active)
    private let directory: URL
    private let lock = NSLock()

    /// `directory` is the profile's folder under ~/Library/Caches.
    init(directory: URL, removingLegacyFiles: Bool = false) {
        self.directory = directory.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if removingLegacyFiles { Self.removeLegacyFiles(in: directory) }
    }

    convenience init(profile: Profile) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        self.init(directory: base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true),
                  removingLegacyFiles: !profile.isDefault)
    }

    func store(_ data: Data, pkg: String, deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let url = url(pkg: pkg, deviceId: deviceId) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    func load(pkg: String, deviceId: String) -> NSImage? {
        guard let data = loadData(pkg: pkg, deviceId: deviceId) else { return nil }
        return NSImage(data: data)
    }

    /// Raw PNG (Spotlight thumbnails want the bytes, not an NSImage).
    func loadData(pkg: String, deviceId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let url = url(pkg: pkg, deviceId: deviceId) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func url(pkg: String, deviceId: String) -> URL? {
        let device = Self.safe(deviceId), name = Self.safe(pkg)
        guard !device.isEmpty, !name.isEmpty else { return nil }
        return directory.appendingPathComponent(device, isDirectory: true).appendingPathComponent("\(name).png")
    }

    /// Package names and device ids are plain identifiers; anything else
    /// (a path separator from a hostile phone) is dropped.
    private static func safe(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private static func removeLegacyFiles(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "png" { try? FileManager.default.removeItem(at: file) }
    }
}
