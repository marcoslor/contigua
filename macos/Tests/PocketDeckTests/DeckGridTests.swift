// The app grid's pure pieces: tile geometry, the generated fallback icon and
// the battery glyph choice.

import XCTest
@testable import PocketDeck

final class DeckGridTests: XCTestCase {

    /// The D grid's numbers (docs/design/mac-redesign.md §3.3): 64 pt icons in
    /// 96×108 pt cells on a fixed 16 pt pitch, 24 pt above and below, an 8 pt
    /// icon-label gap and a 16 pt hover/selection corner.
    func testTheGridUsesTheDesignedMetrics() {
        XCTAssertEqual(GridMetrics.cellWidth, 96)
        XCTAssertEqual(GridMetrics.cellHeight, 108)
        XCTAssertEqual(GridMetrics.iconSide, 64)
        XCTAssertEqual(GridMetrics.columnGap, 16)
        XCTAssertEqual(GridMetrics.rowSpacing, 16)
        XCTAssertEqual(GridMetrics.verticalInset, 24)
        XCTAssertEqual(GridMetrics.iconLabelGap, 8)
        XCTAssertEqual(GridMetrics.cornerRadius, 16)
        XCTAssertEqual(GridMetrics.maxContentWidth, 880)
    }

    /// Columns are what fits the block, never fewer than one; the block stops
    /// growing at 880 pt and is centred, so a wide window has ≥ 60 pt margins.
    func testColumnCountsAndTheCentredBlockFollowTheWidth() {
        let expected: [(CGFloat, Int)] = [(400, 3), (640, 5), (1000, 8), (1400, 8), (2400, 8)]
        for (width, columns) in expected {
            XCTAssertEqual(GridMetrics.columns(forWidth: width), columns, "width \(width)")
            let gap = GridMetrics.gap(forWidth: width)
            XCTAssertEqual(gap, 16, accuracy: 0.001, "the pitch stays fixed at \(width)")
            let span = CGFloat(columns) * GridMetrics.cellWidth + CGFloat(columns - 1) * gap
            XCTAssertLessThanOrEqual(span, GridMetrics.maxContentWidth + 0.001, "width \(width)")
            let block = min(width, GridMetrics.maxContentWidth)
            if span < block {
                XCTAssertEqual(GridMetrics.originX(forWidth: width), (width - span) / 2, accuracy: 0.001,
                               "the block is centred at \(width)")
            }
            XCTAssertGreaterThanOrEqual(GridMetrics.originX(forWidth: width), 0, "width \(width)")
        }
        XCTAssertEqual(GridMetrics.originX(forWidth: 1000), 60, accuracy: 0.001,
                       "the 880 pt cap leaves 60 pt on each side at 1000")
        XCTAssertEqual(GridMetrics.originX(forWidth: 2400), 760, accuracy: 0.001,
                       "a much wider window keeps the same block")
        XCTAssertEqual(GridMetrics.columns(forWidth: 100), 1, "never fewer than one column")
    }

    /// Zoom scales the cell, icon, gaps and the 880 pt cap together, so the
    /// design keeps its proportions at every step.
    func testZoomScalesTheWholeGridTogether() {
        for zoom in DeckZoom.options {
            let metrics = DeckGridSize(zoom: zoom)
            XCTAssertEqual(metrics.cellWidth, 96 * zoom, accuracy: 0.001)
            XCTAssertEqual(metrics.cellHeight, 108 * zoom, accuracy: 0.001)
            XCTAssertEqual(metrics.iconSide, 64 * zoom, accuracy: 0.001)
            XCTAssertEqual(metrics.columnGap, 16 * zoom, accuracy: 0.001)
            XCTAssertEqual(metrics.rowSpacing, 16 * zoom, accuracy: 0.001)
            XCTAssertEqual(metrics.maxContentWidth, 880 * zoom, accuracy: 0.001)
            XCTAssertEqual(metrics.iconLabelGap, 8 * zoom, accuracy: 0.001)
            XCTAssertEqual(metrics.cornerRadius, 16 * zoom, accuracy: 0.001)
            for width in [CGFloat(400), 640, 1000, 1400, 2400] {
                let span = metrics.span(forWidth: width)
                XCTAssertLessThanOrEqual(span, metrics.maxContentWidth + 0.001, "zoom \(zoom) at \(width)")
                XCTAssertGreaterThanOrEqual(metrics.originX(forWidth: width), 0,
                                            "zoom \(zoom) at \(width)")
                XCTAssertEqual(metrics.originX(forWidth: width),
                               (width - span) / 2, accuracy: 0.001,
                               "zoom \(zoom) at \(width) is centred")
            }
        }
        XCTAssertEqual(DeckZoom.stepped(from: 1, by: DeckZoom.step), 1.25)
        XCTAssertEqual(DeckZoom.stepped(from: 1.5, by: DeckZoom.step), 1.5, "clamped")
        XCTAssertEqual(DeckZoom.stepped(from: 0.75, by: -DeckZoom.step), 0.75, "clamped")
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

    // MARK: the drawn layout comes from the width it is given (the zoom bug)

    /// The layout places the columns the width asks for in the same pass: the
    /// block is centred, the first tile starts at the block's edge, and no
    /// frame is outside the width it was given.
    func testTheDrawnLayoutFollowsTheWidthItIsGiven() {
        for width in stride(from: CGFloat(400), through: 1600, by: 37) {
            let columns = GridMetrics.columns(forWidth: width)
            for index in 0..<(columns * 3) {
                let frame = DeckGridLayout.frame(of: index, in: width)
                XCTAssertEqual(frame.width, GridMetrics.cellWidth)
                XCTAssertEqual(frame.height, GridMetrics.cellHeight)
                XCTAssertGreaterThanOrEqual(frame.minX, GridMetrics.originX(forWidth: width) - 0.001,
                                            "width \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, width - GridMetrics.originX(forWidth: width) + 0.001,
                                         "width \(width)")
            }
            let span = GridMetrics.span(forWidth: width)
            XCTAssertEqual(DeckGridLayout.frame(of: 0, in: width).minX,
                           (width - span) / 2, accuracy: 0.001,
                           "the first column starts at the centred block's edge at \(width)")
            XCTAssertEqual(DeckGridLayout.frame(of: columns - 1, in: width).minY,
                           DeckGridLayout.frame(of: 0, in: width).minY,
                           "the first row's cells share one row")
        }
    }

    /// A narrower window re-flows in the same pass: fewer columns, never the
    /// old width's placement.
    func testNarrowerWidthReflowsInTheSamePass() {
        let wide = (0..<12).map { DeckGridLayout.frame(of: $0, in: 1200) }
        let narrow = (0..<12).map { DeckGridLayout.frame(of: $0, in: 760) }
        XCTAssertNotEqual(wide, narrow)
        XCTAssertEqual(Set(narrow.map { $0.minX }).count, GridMetrics.columns(forWidth: 760))
    }

    /// The grid is tall enough for every row and its vertical inset.
    func testTheHeightCoversEveryRow() {
        let width: CGFloat = 760
        let columns = GridMetrics.columns(forWidth: width)
        let rows = 6
        let height = DeckGridLayout.height(for: 6 * columns, width: width)
        let expected = 2 * GridMetrics.verticalInset + CGFloat(rows) * GridMetrics.cellHeight
            + CGFloat(rows - 1) * GridMetrics.rowSpacing
        XCTAssertEqual(height, expected, accuracy: 0.001)
        XCTAssertEqual(DeckGridLayout.height(for: 0, width: width), 2 * GridMetrics.verticalInset)
    }

    // MARK: the drawn frame fits its width (e2e `deck`, the person's clipped edges)

    /// The cell origins a layout at `width` draws, with the design's inset,
    /// 96 pt tiles and the gap the width asks for.
    private func cells(atWidth width: CGFloat, count: Int) -> [CGRect] {
        let columns = GridMetrics.columns(forWidth: width)
        let gap = GridMetrics.gap(forWidth: width)
        let pitch = GridMetrics.cellWidth + gap
        return (0..<count).map { index in
            CGRect(x: GridMetrics.originX(forWidth: width) + CGFloat(index % columns) * pitch,
                   y: GridMetrics.verticalInset + CGFloat(index / columns) * (GridMetrics.cellHeight + GridMetrics.rowSpacing),
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
        XCTAssertEqual(fit.leftInset, GridMetrics.originX(forWidth: 760), accuracy: 0.5)
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
