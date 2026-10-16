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

    /// A flat icon plus, when the phone sent them (`icon` message), the
    /// adaptive layers. The layers sit beside the flat PNG (
    /// `<device>/<pkg>-fg.png`, `-bg.png`, `-mono.png`) and a zero-byte
    /// `<pkg>.layers` marker says the entry has them: a flat-only entry from
    /// a phone that predates layers writes none and removes the marker.
    func store(_ data: Data, fg: Data? = nil, bg: Data? = nil, mono: Data? = nil, pkg: String, deviceId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId) else { return }
        try? FileManager.default.createDirectory(at: side.png.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: side.png)
        if let fg, let bg {
            try? fg.write(to: side.fg)
            try? bg.write(to: side.bg)
            if let mono { try? mono.write(to: side.mono) } else { try? FileManager.default.removeItem(at: side.mono) }
            try? Data().write(to: side.marker)
        } else {
            for url in [side.fg, side.bg, side.mono, side.marker] { try? FileManager.default.removeItem(at: url) }
        }
    }

    func load(pkg: String, deviceId: String) -> NSImage? {
        guard let data = loadData(pkg: pkg, deviceId: deviceId) else { return nil }
        return NSImage(data: data)
    }

    /// Raw PNG (Spotlight thumbnails want the bytes, not an NSImage).
    func loadData(pkg: String, deviceId: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId) else { return nil }
        return try? Data(contentsOf: side.png)
    }

    func hasLayers(pkg: String, deviceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId) else { return false }
        return FileManager.default.fileExists(atPath: side.marker.path)
    }

    /// The stored adaptive layers, or nil for a flat-only entry.
    func loadLayerData(pkg: String, deviceId: String) -> (fg: Data, bg: Data, mono: Data?)? {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId),
              FileManager.default.fileExists(atPath: side.marker.path) else { return nil }
        guard let fg = try? Data(contentsOf: side.fg), let bg = try? Data(contentsOf: side.bg) else { return nil }
        let mono = try? Data(contentsOf: side.mono)
        return (fg, bg, mono)
    }

    private struct Sides {
        let png: URL, fg: URL, bg: URL, mono: URL, marker: URL
    }

    private func sides(pkg: String, deviceId: String) -> Sides? {
        let device = Self.safe(deviceId), name = Self.safe(pkg)
        guard !device.isEmpty, !name.isEmpty else { return nil }
        let base = directory.appendingPathComponent(device, isDirectory: true)
        return Sides(png: base.appendingPathComponent("\(name).png"),
                     fg: base.appendingPathComponent("\(name)-fg.png"),
                     bg: base.appendingPathComponent("\(name)-bg.png"),
                     mono: base.appendingPathComponent("\(name)-mono.png"),
                     marker: base.appendingPathComponent("\(name).layers"))
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

/// A cached flat icon might predate the layers: the Mac asks the phone for
/// such an icon once per connection, so an old phone never gets re-requested
/// in a loop and a new phone's answer arrives once. Reset when the connection
/// is up; the controller owns the life cycle.
@MainActor
final class IconLayerRefresh {
    private var asked: Set<String> = []

    /// True when this package may still be re-requested this connection.
    func allow(pkg: String) -> Bool { asked.insert(pkg).inserted }

    func reset() { asked.removeAll() }
}
