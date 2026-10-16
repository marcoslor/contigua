// The app grid's pure pieces: tile geometry, the generated fallback icon and
// the battery glyph choice.

import XCTest
@testable import PocketDeck

final class DeckGridTests: XCTestCase {

    func testInsetsAreEvenAtEveryWidth() {
        for width in stride(from: CGFloat(640), through: 1600, by: 7) {
            let count = GridMetrics.columns(forWidth: width)
            let gap = GridMetrics.gap(forWidth: width)
            let used = CGFloat(count) * GridMetrics.cellWidth + CGFloat(count - 1) * gap
            XCTAssertEqual(width - 2 * GridMetrics.inset - used, 0, accuracy: 0.001, "width \(width)")
            XCTAssertGreaterThanOrEqual(gap, GridMetrics.minGap)
        }
    }

    func testColumnCountsFollowTheWidth() {
        XCTAssertEqual(GridMetrics.columns(forWidth: 640), 5)
        XCTAssertEqual(GridMetrics.columns(forWidth: 760), 7)
        XCTAssertEqual(GridMetrics.columns(forWidth: 100), 1)
    }

    func testFallbackInitialSkipsPunctuationAndFallsBackToThePackage() {
        XCTAssertEqual(FallbackIcon.initial(label: "spotify", pkg: "com.spotify.music"), "S")
        XCTAssertEqual(FallbackIcon.initial(label: "  ¡Hola", pkg: "x.y"), "H")
        XCTAssertEqual(FallbackIcon.initial(label: "★★", pkg: "org.telegram.messenger"), "M")
        XCTAssertEqual(FallbackIcon.initial(label: "", pkg: ""), "?")
    }

    func testFallbackHueIsStableAndSpreadsOut() {
        XCTAssertEqual(FallbackIcon.hue(for: "com.spotify.music"), FallbackIcon.hue(for: "com.spotify.music"))
        let hues = Set((0..<40).map { FallbackIcon.hue(for: "com.example.app\($0)") })
        XCTAssertGreaterThan(hues.count, 25)
        XCTAssertTrue(hues.allSatisfy { (0..<1).contains($0) })
    }

    func testBatteryGlyphMatchesTheLevel() {
        XCTAssertEqual(BatterySymbol.name(level: 5, charging: false), "battery.0percent")
        XCTAssertEqual(BatterySymbol.name(level: 24, charging: false), "battery.25percent")
        XCTAssertEqual(BatterySymbol.name(level: 50, charging: false), "battery.50percent")
        XCTAssertEqual(BatterySymbol.name(level: 75, charging: false), "battery.75percent")
        XCTAssertEqual(BatterySymbol.name(level: 100, charging: false), "battery.100percent")
        XCTAssertEqual(BatterySymbol.name(level: 24, charging: true), "battery.100percent.bolt")
        XCTAssertTrue(BatterySymbol.isLow(level: 5, charging: false))
        XCTAssertFalse(BatterySymbol.isLow(level: 5, charging: true))
        XCTAssertFalse(BatterySymbol.isLow(level: 24, charging: false))
    }

    // MARK: glass tile (docs/DESIGN.md "The app grid")

    func testGlassTileGeometry() {
        XCTAssertEqual(GlassIcon.tileSide, 56, "56 pt tile as today")
        XCTAssertEqual(GlassIcon.cornerRadius, 12.6, accuracy: 0.01, "22.5 % of the side")
        XCTAssertEqual(GlassIcon.flatSide, 43.68, accuracy: 0.01, "a flat icon sits at 78 % of the tile")
    }

    func testCropRectIsTheCentralTwoThirdsOfTheCanvas() {
        XCTAssertEqual(GlassIcon.cropRect(canvas: 216),
                       CGRect(x: 36, y: 36, width: 144, height: 144),
                       "the 72 dp visible area of the 216 px (108 dp) canvas")
        XCTAssertEqual(GlassIcon.cropRect(canvas: 108),
                       CGRect(x: 18, y: 18, width: 72, height: 72))
    }

    @MainActor
    func testWhichVariantAnEntryPicks() {
        let image = NSImage(size: NSSize(width: 96, height: 96))
        let layers = AppIconLayers(
            fg: NSImage(size: NSSize(width: 216, height: 216)),
            bg: NSImage(size: NSSize(width: 216, height: 216)),
            mono: nil)!

        XCTAssertEqual(GlassIcon.variant(layers: layers, image: image, isMissing: false, glassOn: true),
                       .adaptiveTile(layers))
        XCTAssertEqual(GlassIcon.variant(layers: nil, image: image, isMissing: false, glassOn: true),
                       .flatTile(image), "a flat icon sits centred on the glass tile")
        XCTAssertEqual(GlassIcon.variant(layers: layers, image: image, isMissing: false, glassOn: false),
                       .bare(image), "setting off: today's look")
        XCTAssertEqual(GlassIcon.variant(layers: layers, image: image, isMissing: true, glassOn: false),
                       .bare(image), "a missing icon that answered is still an image")
        XCTAssertNil(AppIconLayers(fg: nil, bg: NSImage(size: NSSize(width: 216, height: 216)), mono: nil),
                     "half an answer is no layers")
        XCTAssertEqual(GlassIcon.variant(layers: nil, image: nil, isMissing: false, glassOn: true),
                       .placeholder, "waiting for the phone")
        XCTAssertEqual(GlassIcon.variant(layers: nil, image: nil, isMissing: true, glassOn: true),
                       .fallback, "the phone said there is no icon")
        // Layers without the flat image cannot render: the flat image always
        // rode along, so take today's flat branch.
        XCTAssertEqual(GlassIcon.variant(layers: layers, image: nil, isMissing: false, glassOn: true),
                       .placeholder)
    }
}
