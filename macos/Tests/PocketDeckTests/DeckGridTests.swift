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

    // MARK: the A–Z rail

    private func railApps(_ labels: [String]) -> [AppInfo] {
        labels.enumerated().compactMap { index, label in
            AppInfo(json: ["pkg": "com.example.app\(index)", "label": label])
        }
    }

    func testRailLettersAndTheFirstIndexForEach() {
        let apps = railApps(["1Password", "99", "Airbnb", "amazon", "Bixby", "Éclair", "£notes"])
        let entries = DeckRail.entries(for: apps)
        let letters = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]
        XCTAssertEqual(entries.map(\.letter), letters)
        XCTAssertEqual(entries.first { $0.letter == "#" }?.index, 0)
        XCTAssertEqual(entries.first { $0.letter == "A" }?.index, 2)
        XCTAssertEqual(entries.first { $0.letter == "B" }?.index, 4)
        XCTAssertEqual(entries.first { $0.letter == "E" }?.index, 5,
                       "an accented letter files under its letter")
        XCTAssertNil(entries.first { $0.letter == "C" }?.index,
                     "a letter with no apps stays in the rail, dimmed")
    }

    func testRailSortsDigitsAndSymbolsUnderHash() {
        XCTAssertEqual(DeckRail.letter(for: "Airbnb"), "A")
        XCTAssertEqual(DeckRail.letter(for: "amazon"), "A")
        XCTAssertEqual(DeckRail.letter(for: "Éclair"), "E")
        XCTAssertEqual(DeckRail.letter(for: "99"), "#")
        XCTAssertEqual(DeckRail.letter(for: "£notes"), "#")
        XCTAssertEqual(DeckRail.letter(for: "  spaced"), "S", "leading spaces are trimmed")
        XCTAssertEqual(DeckRail.letter(for: ""), "#")
    }

    func testRailClickSkipsForwardToTheNextLetterWithApps() {
        let entries = DeckRail.entries(for: railApps(["Alpha", "Bixby", "Delta"]))
        XCTAssertEqual(DeckRail.target(for: "A", in: entries), 0)
        XCTAssertEqual(DeckRail.target(for: "C", in: entries), 2,
                       "C has no apps, so the click lands on Delta")
        XCTAssertNil(DeckRail.target(for: "Z", in: entries),
                     "nothing after the last app to skip to")
        let symbols = DeckRail.entries(for: railApps(["Alpha", "1Password"]))
        XCTAssertEqual(DeckRail.target(for: "#", in: symbols), 1)
    }

    func testRailCurrentLetterFollowsTheScrollOffset() {
        let labels = ["1Password"]
            + (1...4).map { "Alpha \($0)" }
            + (5...9).map { "Bravo \($0)" }
            + (10...14).map { "Charlie \($0)" }
        let apps = railApps(labels)
        let metrics = DeckGridSize(zoom: 1)
        func current(_ offset: CGFloat, width: CGFloat = 640) -> String? {
            DeckRail.currentLetter(offset: offset, apps: apps, metrics: metrics, width: width)
        }
        // Round 2: the current letter is the LAST section start in the top
        // row; this width fits five apps. Row 1 is #, A, A, A, A, so A starts
        // inside it; row 2 is all Bravo; row 3 is all Charlie.
        XCTAssertEqual(current(0), "A")
        XCTAssertEqual(current(24), "A", "the top of the block is still the first row")
        XCTAssertEqual(current(148), "B", "row 2 is all Bravo")
        XCTAssertEqual(current(140), "B", "the gap above a row belongs to the row below it")
        XCTAssertEqual(current(272), "C", "row 3 is all Charlie")
        XCTAssertEqual(current(10_000), "C", "past the end it stays on the last app")
        XCTAssertEqual(current(148, width: 1200), "C",
                       "a wider window's row 2 flows from Bravo into Charlie")
        XCTAssertNil(DeckRail.currentLetter(offset: 0, apps: [], metrics: metrics, width: 640))
    }

    /// The rail's current letter is the LAST section start in the top visible
    /// row; with no section start there it is the row's first tile.
    func testRailCurrentLetterIsTheLastSectionStartInTheTopRow() {
        let apps = railApps((1...5).map { "Slack \($0)" } + ["Telegram"]
                            + (1...5).map { "Tuner \($0)" })
        let metrics = DeckGridSize(zoom: 1)
        let width: CGFloat = 700
        XCTAssertEqual(metrics.columns(forWidth: width), 6)
        XCTAssertEqual(DeckRail.currentLetter(offset: 0, apps: apps, metrics: metrics, width: width),
                       "T", "T's section starts in the top row, after five Slack tiles")
        let oneSection = railApps((1...6).map { "Slack \($0)" })
        XCTAssertEqual(DeckRail.currentLetter(offset: 0, apps: oneSection, metrics: metrics, width: width),
                       "S", "no section starts in the row, so the first tile's letter")
    }

    /// A short window condenses the rail rather than losing it: every other
    /// letter at 280 pt, every third at 180 pt, and nothing below 8 slots.
    /// Each slot still maps a y to a real letter, so a click lands correctly.
    func testRailCondensesItsSlotsWhenTheWindowIsShort() {
        let full = DeckRail.slots(forHeight: 540) ?? []
        XCTAssertEqual(full.count, 27)
        XCTAssertEqual(full.first, DeckRail.Slot(first: 0, count: 1))
        XCTAssertEqual(full.last, DeckRail.Slot(first: 26, count: 1))

        let two = DeckRail.slots(forHeight: DeckRail.compactTwoHeight) ?? []
        XCTAssertEqual(two.count, 14)
        XCTAssertEqual(two.first, DeckRail.Slot(first: 0, count: 2), "A covers A and B")
        XCTAssertEqual(two.last, DeckRail.Slot(first: 26, count: 1), "# stands alone")
        XCTAssertEqual(DeckRail.letter(atY: 0, slots: two), "A")
        XCTAssertEqual(DeckRail.letter(atY: 19.9, slots: two), "B",
                       "the slot's two letters split its 20 pt row")
        XCTAssertEqual(DeckRail.letter(atY: 20, slots: two), "C")
        XCTAssertEqual(DeckRail.letter(atY: 13 * 20 + 5, slots: two), "#")

        let three = DeckRail.slots(forHeight: DeckRail.compactThreeHeight) ?? []
        XCTAssertEqual(three.count, 9)
        XCTAssertEqual(three.first, DeckRail.Slot(first: 0, count: 3))
        XCTAssertEqual(three.last, DeckRail.Slot(first: 24, count: 3), "Y, Z and #")
        XCTAssertEqual(DeckRail.letter(atY: 0, slots: three), "A")
        XCTAssertEqual(DeckRail.letter(atY: 10, slots: three), "B")
        XCTAssertEqual(DeckRail.letter(atY: 19.9, slots: three), "C")

        XCTAssertNil(DeckRail.slots(forHeight: 179), "fewer than 8 slots: hide the rail")
        XCTAssertEqual(DeckRail.slots(forHeight: 180)?.count, 9, "180 still holds 9 slots")
        XCTAssertNil(DeckRail.letter(atY: 0, slots: []))
    }

    func testRailHidesWhileSearchingAndBelowThirtyApps() {
        XCTAssertFalse(DeckRail.shows(count: 29, query: ""))
        XCTAssertTrue(DeckRail.shows(count: 30, query: ""))
        XCTAssertFalse(DeckRail.shows(count: 30, query: "ca"),
                       "a search query hides the rail")
        XCTAssertFalse(DeckRail.shows(count: 0, query: ""))
    }

    func testRailLetterAtAPointOnTheColumn() {
        let entries = DeckRail.entries(for: railApps(["Alpha", "Bixby"]))
        XCTAssertEqual(DeckRail.letter(atY: 0, height: 270, entries: entries), "A")
        XCTAssertEqual(DeckRail.letter(atY: 269, height: 270, entries: entries), "#")
        XCTAssertEqual(DeckRail.letter(atY: 10.5, height: 270, entries: entries),
                       entries[1].letter,
                       "the column's letters are evenly spaced")
        XCTAssertEqual(DeckRail.letter(atY: 45, height: 270, entries: entries),
                       entries[4].letter)
        XCTAssertNil(DeckRail.letter(atY: 0, height: 0, entries: entries))
    }

    /// R1: every letter owns a 20 pt hit target (AGENTS: at least 20 pt), and
    /// the rail hides rather than shrink them when the window is too short.
    func testRailLettersAreTwentyPointTargetsAndHideWhenTooShort() {
        XCTAssertGreaterThanOrEqual(DeckRail.pitch, 20)
        XCTAssertEqual(DeckRail.minimumHeight, 27 * DeckRail.pitch)
        XCTAssertEqual(DeckRail.minimumHeight, 540,
                       "27 letters at 20 pt; the rail's ViewThatFits hides it below this")
    }

    /// R1: the letter under the pointer is about 2× and its neighbours taper
    /// to 1×; Reduce Motion drops the magnification for a plain highlight.
    func testRailFisheyeMagnifiesTheLetterUnderThePointer() {
        let peak = RailFisheye.scale(distance: 0, reduceMotion: false)
        XCTAssertGreaterThanOrEqual(peak, 2)
        XCTAssertEqual(RailFisheye.scale(distance: 1, reduceMotion: false),
                       RailFisheye.scale(distance: -1, reduceMotion: false),
                       "the taper is symmetrical")
        XCTAssertGreaterThan(peak, RailFisheye.scale(distance: 1, reduceMotion: false))
        XCTAssertGreaterThan(RailFisheye.scale(distance: 1, reduceMotion: false),
                             RailFisheye.scale(distance: 2, reduceMotion: false))
        XCTAssertEqual(RailFisheye.scale(distance: RailFisheye.reach, reduceMotion: false), 1)
        XCTAssertEqual(RailFisheye.scale(distance: 0, reduceMotion: true), 1,
                       "Reduce Motion keeps the letters at their rest size")
    }

    /// A rail pick lands on its letter's first app, or forward over an empty
    /// letter; the accent is that letter, not the row it shares.
    func testRailPickIsTheLandedLetter() {
        let letters = railApps(["Alpha", "Bixby", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"])
        XCTAssertEqual(DeckRail.pick("A", in: letters), DeckRail.Pick(letter: "A", index: 0))
        XCTAssertEqual(DeckRail.pick("C", in: letters), DeckRail.Pick(letter: "D", index: 2),
                       "an empty letter skips forward to the next one with apps")
        XCTAssertEqual(DeckRail.pick("H", in: letters), DeckRail.Pick(letter: "H", index: 6),
                       "H's first app is mid-row in the second row")
        XCTAssertNil(DeckRail.pick("Z", in: letters))
        XCTAssertNil(DeckRail.pick("A", in: []))
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
        XCTAssertEqual(GlassIcon.variant(rendered: nil, isMissing: false), .placeholder)
        XCTAssertEqual(GlassIcon.variant(rendered: nil, isMissing: true), .fallback)
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

    // MARK: the tile (docs/DESIGN.md "The app grid")

    func testGlassTileGeometry() {
        XCTAssertEqual(GlassIcon.tileSide, 56, "56 pt tile as today")
        XCTAssertEqual(GlassIcon.cornerRadius, 12.6, accuracy: 0.01, "22.5 % of the side")
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
        let rendered = NSImage(size: NSSize(width: 224, height: 224))

        XCTAssertEqual(GlassIcon.variant(rendered: rendered, isMissing: false),
                       .rendered(rendered), "the shared renderer's image")
        XCTAssertEqual(GlassIcon.variant(rendered: rendered, isMissing: true),
                       .rendered(rendered), "a missing icon that answered is still an image")
        XCTAssertNil(AppIconLayers(fg: nil, bg: NSImage(size: NSSize(width: 216, height: 216)), mono: nil),
                     "half an answer is no layers")
        XCTAssertEqual(GlassIcon.variant(rendered: nil, isMissing: false),
                       .placeholder, "no render yet: the placeholder, never the bare flat image")
        XCTAssertEqual(GlassIcon.variant(rendered: nil, isMissing: true),
                       .fallback, "the phone said there is no icon")
    }
}
