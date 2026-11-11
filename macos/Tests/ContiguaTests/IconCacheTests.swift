// Icons are per phone: the harness's generated icons must never show up in
// the real phone's grid just because the package name is the same.

import AppKit
import XCTest
@testable import Contigua

final class IconCacheTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func png(_ shade: UInt8) -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor(white: CGFloat(shade) / 255, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testTheSamePackageOnTwoPhonesKeepsTwoIcons() {
        let cache = IconCache(directory: directory)
        let real = png(10), fake = png(200)
        cache.store(real, pkg: "com.android.settings", deviceId: "real-phone")
        cache.store(fake, pkg: "com.android.settings", deviceId: "fakephone")

        XCTAssertEqual(cache.loadData(pkg: "com.android.settings", deviceId: "real-phone"), real)
        XCTAssertEqual(cache.loadData(pkg: "com.android.settings", deviceId: "fakephone"), fake)
        XCTAssertNil(cache.loadData(pkg: "com.android.settings", deviceId: "third-phone"))
        XCTAssertNotNil(cache.load(pkg: "com.android.settings", deviceId: "real-phone"))
    }

    func testLayersRoundTripBesideTheFlatIcon() {
        let cache = IconCache(directory: directory)
        let flat = png(10), fg = png(40), bg = png(120), mono = png(250)
        cache.store(flat, fg: fg, bg: bg, mono: mono, pkg: "com.a.b", deviceId: "d1")

        XCTAssertEqual(cache.loadData(pkg: "com.a.b", deviceId: "d1"), flat, "the flat icon is unchanged")
        XCTAssertTrue(cache.hasLayers(pkg: "com.a.b", deviceId: "d1"))
        XCTAssertEqual(cache.loadLayerData(pkg: "com.a.b", deviceId: "d1")?.fg, fg)
        XCTAssertEqual(cache.loadLayerData(pkg: "com.a.b", deviceId: "d1")?.bg, bg)
        XCTAssertEqual(cache.loadLayerData(pkg: "com.a.b", deviceId: "d1")?.mono, mono)
    }

    func testLayersWithoutMonochromeRoundTripToo() {
        let cache = IconCache(directory: directory)
        cache.store(png(10), fg: png(40), bg: png(120), mono: nil, pkg: "com.a.b", deviceId: "d1")

        let layers = cache.loadLayerData(pkg: "com.a.b", deviceId: "d1")
        XCTAssertEqual(layers?.fg, png(40))
        XCTAssertEqual(layers?.bg, png(120))
        XCTAssertNil(layers?.mono)
    }

    func testTheDeckAndDockSlotsNeverReplaceEachOther() {
        let cache = IconCache(directory: directory)
        let deckFG = png(40), deckBG = png(120), dockFG = png(41), dockBG = png(121)
        cache.store(png(10), fg: deckFG, bg: deckBG, pkg: "a.b", deviceId: "d1", px: 432)
        cache.store(png(10), fg: dockFG, bg: dockBG, pkg: "a.b", deviceId: "d1", px: 1296)

        XCTAssertEqual(cache.loadLayerData(pkg: "a.b", deviceId: "d1", sizeClass: .deck)?.fg, deckFG)
        XCTAssertEqual(cache.loadLayerData(pkg: "a.b", deviceId: "d1", sizeClass: .dock)?.fg, dockFG)

        // A later 216 px answer fills the Deck slot only: the 1296 render stays.
        cache.store(png(11), fg: png(42), bg: png(122), pkg: "a.b", deviceId: "d1", px: 216)
        XCTAssertEqual(cache.loadLayerData(pkg: "a.b", deviceId: "d1", sizeClass: .deck)?.fg, png(42))
        XCTAssertEqual(cache.loadLayerData(pkg: "a.b", deviceId: "d1", sizeClass: .dock)?.fg, dockFG)
        XCTAssertTrue(cache.hasLayers(pkg: "a.b", deviceId: "d1"))
    }

    func testAFlatAnswerClosesOnlyItsOwnSlot() {
        let cache = IconCache(directory: directory)
        cache.store(png(10), pkg: "a.b", deviceId: "d1", px: 432)
        XCTAssertTrue(cache.layersAnswered(pkg: "a.b", deviceId: "d1", sizeClass: .deck),
                      "the phone answered: no layers is an answer")
        XCTAssertFalse(cache.layersAnswered(pkg: "a.b", deviceId: "d1", sizeClass: .dock),
                       "the Dock's size class was never asked")

        cache.store(png(10), pkg: "a.b", deviceId: "d1", px: 1296)
        XCTAssertTrue(cache.layersAnswered(pkg: "a.b", deviceId: "d1", sizeClass: .dock))
        XCTAssertFalse(cache.hasLayers(pkg: "a.b", deviceId: "d1"))
    }

    func testTheRequestSizeDecidesTheSlot() {
        XCTAssertEqual(IconSizeClass.forRequest(216), .deck)
        XCTAssertEqual(IconSizeClass.forRequest(432), .deck)
        XCTAssertEqual(IconSizeClass.forRequest(1296), .dock)
        XCTAssertEqual(IconSizeClass.deck.layerPx, 432)
        XCTAssertEqual(IconSizeClass.dock.layerPx, 1296)
    }

    func testAFlatOnlyEntryStaysFlat() {
        let cache = IconCache(directory: directory)
        cache.store(png(10), pkg: "com.a.b", deviceId: "d1")

        XCTAssertFalse(cache.hasLayers(pkg: "com.a.b", deviceId: "d1"))
        XCTAssertNil(cache.loadLayerData(pkg: "com.a.b", deviceId: "d1"))
    }

    func testAFlatReplyClearsEarlierLayers() throws {
        let cache = IconCache(directory: directory)
        cache.store(png(10), fg: png(40), bg: png(120), mono: nil, pkg: "com.a.b", deviceId: "d1")
        // The same phone, now answering without layers (it predates them).
        cache.store(png(11), pkg: "com.a.b", deviceId: "d1")

        XCTAssertFalse(cache.hasLayers(pkg: "com.a.b", deviceId: "d1"))
        XCTAssertNil(cache.loadLayerData(pkg: "com.a.b", deviceId: "d1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory
            .appendingPathComponent("icons/d1", isDirectory: true)
            .appendingPathComponent("com.a.b-fg.png").path), "the layer files go with the marker")
        XCTAssertEqual(cache.loadData(pkg: "com.a.b", deviceId: "d1"), png(11))
    }

    func testLayerStoreNeedsBothLayers() {
        let cache = IconCache(directory: directory)
        cache.store(png(10), fg: png(40), bg: nil, mono: nil, pkg: "com.a.b", deviceId: "d1")

        XCTAssertFalse(cache.hasLayers(pkg: "com.a.b", deviceId: "d1"))
        XCTAssertNil(cache.loadLayerData(pkg: "com.a.b", deviceId: "d1"))
    }

    func testOldUnnamespacedFilesAreNeverRead() throws {
        try png(1).write(to: directory.appendingPathComponent("com.android.settings.png"))
        let cache = IconCache(directory: directory)

        XCTAssertNil(cache.loadData(pkg: "com.android.settings", deviceId: "real-phone"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.android.settings.png").path),
                      "the default profile's old files stay where they are")
    }

    func testIdentifiersCannotEscapeTheCacheFolder() {
        let cache = IconCache(directory: directory)
        cache.store(png(5), pkg: "../../evil", deviceId: "../x")

        XCTAssertNotNil(cache.loadData(pkg: "../../evil", deviceId: "../x"))
        let escaped = directory.deletingLastPathComponent().appendingPathComponent("evil.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
        cache.store(png(5), pkg: "", deviceId: "d")
        XCTAssertNil(cache.loadData(pkg: "", deviceId: "d"))
    }

    func testAppListsAreKeptPerPhoneToo() {
        let apps = AppsCache(directory: directory)
        let real = [AppInfo(json: ["pkg": "com.spotify.music", "label": "Spotify"])!]
        let fake = [AppInfo(json: ["pkg": "com.android.settings", "label": "Settings"])!]
        apps.store(real, deviceId: "real-phone")
        apps.store(fake, deviceId: "fakephone")

        XCTAssertEqual(apps.load(deviceId: "real-phone").map(\.pkg), ["com.spotify.music"])
        XCTAssertEqual(apps.load(deviceId: "fakephone").map(\.pkg), ["com.android.settings"])
        XCTAssertTrue(apps.load(deviceId: "other").isEmpty)
    }
}

@MainActor
final class IconLayerRefreshTests: XCTestCase {

    func testOneReRequestPerPackagePerConnection() {
        let refresh = IconLayerRefresh()

        XCTAssertTrue(refresh.allow(pkg: "com.a"))
        XCTAssertFalse(refresh.allow(pkg: "com.a"), "a package never gets asked twice in one connection")
        XCTAssertTrue(refresh.allow(pkg: "com.b"))
        // A reconnect (the same phone again) starts a new connection.
        refresh.reset()
        XCTAssertTrue(refresh.allow(pkg: "com.a"))
    }
}
