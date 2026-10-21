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

    // MARK: grid identity (the person's empty slot)

    /// A package with two launcher activities is two cells, each with its own
    /// id: equal ids made SwiftUI draw neither cell (the empty slot the person
    /// photographed).
    func testTwoLaunchActivitiesOfOnePackageAreTwoCells() throws {
        let main = try XCTUnwrap(AppInfo(json: ["pkg": "com.example.chat", "label": "Chat",
                                                "activity": "com.example.chat/.Main"]))
        let dual = try XCTUnwrap(AppInfo(json: ["pkg": "com.example.chat", "label": "Chat (dual)",
                                                "activity": "com.example.chat/.Dual"]))
        let entries = AppGrid.entries([main, dual])
        XCTAssertEqual(entries.count, 2, "both launcher entries are launchable and must be drawn")
        XCTAssertEqual(Set(entries.map(\.id)).count, 2, "the cells' ids are distinct")
        XCTAssertEqual(entries.map(\.label), ["Chat", "Chat (dual)"])
    }

    /// The same entry sent twice is one cell, not two with the same id.
    func testARepeatedEntryIsOneCell() throws {
        let app = try XCTUnwrap(AppInfo(json: ["pkg": "com.example.app", "label": "App",
                                               "activity": "com.example.app/.Main"]))
        XCTAssertEqual(AppGrid.entries([app, app]).count, 1)
    }

    /// A phone that sends no label still gets words under the tile: an empty
    /// label would leave the slot looking empty.
    func testAnEntryWithoutALabelFallsBackToThePackage() throws {
        let bare = try XCTUnwrap(AppInfo(json: ["pkg": "com.t3code.nightly"]))
        XCTAssertEqual(bare.displayLabel, "nightly")
        let blank = try XCTUnwrap(AppInfo(json: ["pkg": "com.example.notes", "label": "   ",
                                                 "activity": "com.example.notes/.Main"]))
        XCTAssertEqual(blank.displayLabel, "notes")
        XCTAssertNotEqual(FallbackIcon.initial(label: bare.displayLabel, pkg: bare.pkg), "?",
                          "the icon has a letter to draw")
    }

    /// A package without an icon and without an answer yet: the tile draws the
    /// placeholder (never nothing), and a phone that said "no icon" draws the
    /// generated one.
    func testAMissingIconStillDrawsATile() {
        XCTAssertEqual(GlassIcon.variant(rendered: nil, image: nil, isMissing: false, glassOn: true),
                       .placeholder)
        XCTAssertEqual(GlassIcon.variant(rendered: nil, image: nil, isMissing: true, glassOn: true),
                       .fallback)
    }

    // MARK: the zoom's layout rate (NFR deck_zoom_frame_p95_ms)

    /// The width a zoom or a live resize delivers every frame is coalesced: the
    /// grid re-lays itself out a few times instead of once per display frame
    /// (the person's zoom stutter, worst on the way back). The last width is
    /// never dropped, so the settled layout is exact.
    @MainActor
    func testTheWidthIsCoalescedAndTheLastOneWins() {
        let debouncer = WidthDebouncer()
        var applied: [CGFloat] = []
        for width in stride(from: CGFloat(600), through: 900, by: 10) {
            debouncer.schedule(width, update: { _ in }) { applied.append($0) }
        }
        XCTAssertLessThan(applied.count, 31, "one state write per frame is the stutter")
        XCTAssertEqual(applied.first, 600, "the first width lands at once")

        // The trailing update arrives on the run loop (the animation's last
        // width), and it is the last one scheduled.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertEqual(applied.last, 900, "the settled width is the last one the window sent")
    }

    // MARK: the drawn frame fits its width (e2e `deck`, the person's clipped edges)

    /// The cell origins a layout at `width` draws, with the design's inset,
    /// 96 pt tiles and the gap the width asks for.
    private func cells(atWidth width: CGFloat, count: Int) -> [CGRect] {
        let columns = GridMetrics.columns(forWidth: width)
        let gap = GridMetrics.gap(forWidth: width)
        let pitch = GridMetrics.cellWidth + gap
        return (0..<count).map { index in
            CGRect(x: GridMetrics.inset + CGFloat(index % columns) * pitch,
                   y: 16 + CGFloat(index / columns) * 108,
                   width: GridMetrics.cellWidth, height: GridMetrics.cellHeight)
        }
    }

    /// A frame laid out for the width it is drawn at fits: even insets, no
    /// cell outside, the right number of columns.
    func testAFrameDrawnAtItsWidthFits() {
        let fit = DeckFrameFit.measure(width: 760,
                                       visible: CGRect(x: 0, y: 0, width: 760, height: 600),
                                       cells: cells(atWidth: 760, count: 41))
        XCTAssertTrue(fit.ok, fit.summary)
        XCTAssertEqual(fit.columns, GridMetrics.columns(forWidth: 760))
        XCTAssertEqual(fit.leftInset, GridMetrics.inset, accuracy: 0.5)
        XCTAssertEqual(fit.clipped, 0)
    }

    /// The reported bug: the window shrank but the grid kept the wider width's
    /// columns, so the edge tiles hang outside the visible bounds.
    func testAStaleWiderLayoutIsClippedInAShownNarrowerFrame() {
        let fit = DeckFrameFit.measure(width: 600,
                                       visible: CGRect(x: 0, y: 0, width: 600, height: 600),
                                       cells: cells(atWidth: 760, count: 41))
        XCTAssertFalse(fit.ok)
        XCTAssertGreaterThan(fit.clipped, 0, "the cells past the edge are cut in half")
        XCTAssertNotEqual(fit.columns, fit.expectedColumns)
        XCTAssertGreaterThan(abs(fit.leftInset - fit.rightInset), 1)
    }

    /// The other direction: too few columns for the wider window leaves the
    /// row short of the right edge (the grid "slides" as the count catches up).
    func testAStaleNarrowerLayoutLeavesTheRightInsetTooWide() {
        let fit = DeckFrameFit.measure(width: 900,
                                       visible: CGRect(x: 0, y: 0, width: 900, height: 600),
                                       cells: cells(atWidth: 760, count: 41))
        XCTAssertFalse(fit.ok)
        XCTAssertEqual(fit.clipped, 0)
        XCTAssertGreaterThan(fit.rightInset - fit.leftInset, 1)
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
        let rendered = NSImage(size: NSSize(width: 224, height: 224))

        XCTAssertEqual(GlassIcon.variant(rendered: rendered, image: image, isMissing: false, glassOn: true),
                       .rendered(rendered), "setting on: the shared renderer's image")
        XCTAssertEqual(GlassIcon.variant(rendered: nil, image: image, isMissing: false, glassOn: true),
                       .bare(image), "no render yet: the flat image, never a blank tile")
        XCTAssertEqual(GlassIcon.variant(rendered: rendered, image: image, isMissing: false, glassOn: false),
                       .bare(image), "setting off: today's look")
        XCTAssertEqual(GlassIcon.variant(rendered: rendered, image: image, isMissing: true, glassOn: true),
                       .rendered(rendered), "a missing icon that answered is still an image")
        XCTAssertNil(AppIconLayers(fg: nil, bg: NSImage(size: NSSize(width: 216, height: 216)), mono: nil),
                     "half an answer is no layers")
        XCTAssertEqual(GlassIcon.variant(rendered: nil, image: nil, isMissing: false, glassOn: true),
                       .placeholder, "waiting for the phone")
        XCTAssertEqual(GlassIcon.variant(rendered: nil, image: nil, isMissing: true, glassOn: true),
                       .fallback, "the phone said there is no icon")
    }
}
