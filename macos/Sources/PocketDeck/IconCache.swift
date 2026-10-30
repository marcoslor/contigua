// App icons on disk, one folder per phone: a package name means a different
// icon on every phone (and on the test phones the harness runs), so icons are
// keyed by device id + package. Files from before that (`<pkg>.png` straight
// in the profile's folder) are never read again; non-default profiles delete
// them, the default profile leaves the user's files alone.
//
// The adaptive layers have one slot per size class (docs/design/dock.md
// §Icons): the Deck's 432 px render and the Dock shim's 1296 px render never
// replace each other. A phone that predates `apps.icon`'s `px` answers 216 px
// layers; those fill the Deck slot (the historical file names) and the Dock
// upscales them.

import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The two sizes layers are cached at. The Deck draws a 56 pt tile, the Dock
/// shim a 1024 px icon.
enum IconSizeClass: String, CaseIterable {
    case deck
    case dock

    /// The `px` the Mac asks the phone for.
    var layerPx: Int { self == .deck ? 432 : 1296 }

    /// The slot a reply belongs to. Replies do not echo `px`; the controller
    /// remembers what it asked.
    static func forRequest(_ px: Int) -> IconSizeClass { px >= 1024 ? .dock : .deck }
}

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
    /// adaptive layers. The layers sit beside the flat PNG and a zero-byte
    /// marker says the entry answered: `<pkg>.layers` for the Deck's slot
    /// (the historical names) and `<pkg>-dock.layers` for the Dock's, so a
    /// 1296 render is never replaced by a 216 one. `px` is the size the Mac
    /// asked for; it decides the slot.
    func store(_ data: Data, fg: Data? = nil, bg: Data? = nil, mono: Data? = nil, pkg: String,
               deviceId: String, px: Int = 216) {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId, sizeClass: IconSizeClass.forRequest(px)) else { return }
        try? FileManager.default.createDirectory(at: side.png.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: side.png)
        if let fg, let bg {
            try? fg.write(to: side.fg)
            try? bg.write(to: side.bg)
            if let mono { try? mono.write(to: side.mono) } else { try? FileManager.default.removeItem(at: side.mono) }
        } else {
            for url in [side.fg, side.bg, side.mono] { try? FileManager.default.removeItem(at: url) }
        }
        try? Data().write(to: side.marker)
    }

    func load(pkg: String, deviceId: String) -> NSImage? {
        guard let data = loadData(pkg: pkg, deviceId: deviceId) else { return nil }
        return NSImage(data: data)
    }

    /// Raw PNG (Spotlight thumbnails want the bytes, not an NSImage). The Dock
    /// shim reads its own size class: its flat is 864 px there, and a covered
    /// flat icon needs it (docs/design/dock.md §Icons).
    func loadData(pkg: String, deviceId: String, sizeClass: IconSizeClass = .deck) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId, sizeClass: sizeClass) else { return nil }
        return try? Data(contentsOf: side.png)
    }

    /// Whether any size class has adaptive layers for the app.
    func hasLayers(pkg: String, deviceId: String) -> Bool {
        IconSizeClass.allCases.contains { loadLayerData(pkg: pkg, deviceId: deviceId, sizeClass: $0) != nil }
    }

    /// Whether this slot was answered at all: with layers, or by a flat icon
    /// (a phone that has no adaptive layers must not be asked forever).
    func layersAnswered(pkg: String, deviceId: String, sizeClass: IconSizeClass) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId, sizeClass: sizeClass) else { return false }
        return FileManager.default.fileExists(atPath: side.marker.path)
    }

    /// The stored adaptive layers of one size class, or nil for a flat-only entry.
    func loadLayerData(pkg: String, deviceId: String,
                       sizeClass: IconSizeClass = .deck) -> (fg: Data, bg: Data, mono: Data?)? {
        lock.lock(); defer { lock.unlock() }
        guard let side = sides(pkg: pkg, deviceId: deviceId, sizeClass: sizeClass),
              FileManager.default.fileExists(atPath: side.marker.path) else { return nil }
        guard let fg = try? Data(contentsOf: side.fg), let bg = try? Data(contentsOf: side.bg) else { return nil }
        let mono = try? Data(contentsOf: side.mono)
        return (fg, bg, mono)
    }

    /// The rendered icon for the shim (.icns source) and other places that want
    /// pixels rather than the flat PNG.
    func renderedCGImage(pkg: String, deviceId: String, sizeClass: IconSizeClass, px: Int) -> CGImage? {
        let flat = loadData(pkg: pkg, deviceId: deviceId, sizeClass: sizeClass)
        let layers = loadLayerData(pkg: pkg, deviceId: deviceId, sizeClass: sizeClass)
        return PhoneAppIcon.render(fg: layers?.fg, bg: layers?.bg, flat: flat, px: px)
    }

    /// The rendered icon as PNG (Spotlight thumbnails).
    func renderedPNG(pkg: String, deviceId: String, px: Int) -> Data? {
        guard let image = renderedCGImage(pkg: pkg, deviceId: deviceId, sizeClass: .deck, px: px) else { return nil }
        return Self.png(image)
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private struct Sides {
        let png: URL, fg: URL, bg: URL, mono: URL, marker: URL
    }

    private func sides(pkg: String, deviceId: String, sizeClass: IconSizeClass) -> Sides? {
        let device = Self.safe(deviceId), name = Self.safe(pkg)
        guard !device.isEmpty, !name.isEmpty else { return nil }
        let base = directory.appendingPathComponent(device, isDirectory: true)
        let suffix = sizeClass == .deck ? "" : "-\(sizeClass.rawValue)"
        return Sides(png: base.appendingPathComponent("\(name).png"),
                     fg: base.appendingPathComponent("\(name)\(suffix)-fg.png"),
                     bg: base.appendingPathComponent("\(name)\(suffix)-bg.png"),
                     mono: base.appendingPathComponent("\(name)\(suffix)-mono.png"),
                     marker: base.appendingPathComponent("\(name)\(suffix).layers"))
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
