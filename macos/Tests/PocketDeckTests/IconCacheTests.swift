// Icons are per phone: the harness's generated icons must never show up in
// the real phone's grid just because the package name is the same.

import AppKit
import XCTest
@testable import PocketDeck

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

    func testOldUnnamespacedFilesAreNeverRead() throws {
        try png(1).write(to: directory.appendingPathComponent("com.android.settings.png"))
        let cache = IconCache(directory: directory)

        XCTAssertNil(cache.loadData(pkg: "com.android.settings", deviceId: "real-phone"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.android.settings.png").path),
                      "the default profile's old files stay where they are")
    }

    func testNonDefaultProfilesDeleteTheOldFilesButNotTheNewOnes() throws {
        let legacy = directory.appendingPathComponent("com.android.settings.png")
        try png(1).write(to: legacy)
        let kept = directory.appendingPathComponent("apps-abc.json")
        try Data("[]".utf8).write(to: kept)

        let first = IconCache(directory: directory)
        first.store(png(9), pkg: "a.b", deviceId: "d1")
        let cache = IconCache(directory: directory, removingLegacyFiles: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertNotNil(cache.loadData(pkg: "a.b", deviceId: "d1"))
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
