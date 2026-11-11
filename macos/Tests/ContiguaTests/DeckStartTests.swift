// The Deck as a start page (ISS-74, DECK-26…DECK-31): the sections, the one
// shared column grid, the pins this Mac keeps and the page's keyboard.

import AppKit
import XCTest
@testable import Contigua

final class DeckStartTests: XCTestCase {

    private func apps(_ labels: [String]) -> [AppInfo] {
        labels.enumerated().compactMap { index, label in
            AppInfo(json: ["pkg": "com.example.app\(index)", "label": label])
        }
    }

    private func numbered(_ count: Int) -> [AppInfo] {
        apps((1...count).map { "App \(String(format: "%02d", $0))" })
    }

    // MARK: The sections (DECK-26)

    /// The reading order is the windows, the pins, then every app; an empty
    /// section is not shown at all, and All Apps is sorted by name.
    func testSectionsAreTheWindowsThenThePinsThenEveryAppSorted() {
        let list = apps(["Camera", "Browser", "App 10", "App 2", "App 1"])
        let sections = DeckPage.sections(apps: list, query: "",
                                         openPkgs: ["com.example.app0", "com.example.app1"],
                                         pinnedPkgs: ["com.example.app3", "com.example.app2"])
        XCTAssertEqual(sections.map(\.kind), [.openWindows, .pinned, .allApps])
        XCTAssertEqual(sections[0].apps.map(\.displayLabel), ["Camera", "Browser"],
                       "the row keeps the windows' front-to-back order")
        XCTAssertEqual(sections[1].apps.map(\.displayLabel), ["App 2", "App 10"],
                       "the pinned row keeps the pin order")
        XCTAssertEqual(sections[2].apps.map(\.displayLabel),
                       ["App 1", "App 2", "App 10", "Browser", "Camera"],
                       "All Apps is sorted by name, the way macOS sorts names")
        XCTAssertEqual(sections.map(\.title), ["Open on this Mac", "Pinned", "All Apps"])
        XCTAssertTrue(sections.allSatisfy(\.showsHeader))
    }

    /// Empty sections are gone: no header, no gap. With no window open and
    /// nothing pinned the page is one All Apps section without a header —
    /// exactly the grid the Deck had before.
    func testAnEmptySectionIsNotShownAndTheBarePageIsTodaysGrid() {
        let list = numbered(12)
        let bare = DeckPage.sections(apps: list, query: "", openPkgs: [], pinnedPkgs: [])
        XCTAssertEqual(bare.map(\.kind), [.allApps])
        XCTAssertFalse(bare[0].showsHeader)
        let page = DeckPageLayout(width: 760, metrics: DeckGridSize(zoom: 1), sections: bare)
        XCTAssertEqual(page.cells[0][0].minY, DeckGridSize(zoom: 1).verticalInset,
                       "the first row keeps today's 24 pt inset")
        XCTAssertEqual(page.height, DeckGridLayout.height(for: 12, width: 760), accuracy: 0.001,
                       "the page is exactly the old grid's height")
        XCTAssertEqual(page.gridOrigin, 0, "the rail measures from today's origin")
        XCTAssertNil(page.headerFrame(bare[0]))

        let withPins = DeckPage.sections(apps: list, query: "",
                                         openPkgs: [], pinnedPkgs: [list[3].pkg])
        XCTAssertEqual(withPins.map(\.kind), [.pinned, .allApps])
        XCTAssertTrue(withPins[1].showsHeader, "All Apps names itself once a section is above it")
    }

    /// A pin for an app the phone no longer lists is dropped silently, and a
    /// pin appears once even if the list repeats it.
    func testPinsForMissingAppsAreDroppedAndRepeatsAreOne() {
        let list = apps(["Alpha", "Bravo"])
        let sections = DeckPage.sections(apps: list, query: "",
                                         openPkgs: [],
                                         pinnedPkgs: ["com.example.app1", "gone.app",
                                                      "com.example.app1", "com.example.app0"])
        XCTAssertEqual(sections[0].apps.map(\.displayLabel), ["Bravo", "Alpha"])
    }

    /// While searching the sections collapse to the results alone (today's
    /// behaviour): one All Apps section, no headers, sorted.
    func testSearchingCollapsesTheSectionsToTheResults() {
        let list = apps(["Camera", "Calendar", "Maps", "Camera 2"])
        let sections = DeckPage.sections(apps: list, query: "cam",
                                         openPkgs: ["com.example.app0"],
                                         pinnedPkgs: ["com.example.app2"])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].kind, .allApps)
        XCTAssertFalse(sections[0].showsHeader)
        XCTAssertEqual(sections[0].apps.map(\.displayLabel), ["Camera", "Camera 2"])
    }

    // MARK: The shared column grid (DECK-26, the person's correction)

    /// Every section sits on All Apps' columns at the brief's widths: one cell
    /// size, the same x origin for the same column, a header at the grid's
    /// leading edge, and no row wider than the grid.
    func testEverySectionSharesTheAllAppsColumnsAndHeaderEdge() {
        let list = numbered(40)
        let sections = DeckPage.sections(apps: list, query: "",
                                         openPkgs: list.prefix(3).map(\.pkg),
                                         pinnedPkgs: list.dropFirst(5).prefix(8).map(\.pkg))
        XCTAssertEqual(sections.map(\.kind), [.openWindows, .pinned, .allApps])
        for width in [CGFloat(760), 1000, 1200, 1600] {
            let metrics = DeckGridSize(zoom: 1)
            let block = DeckWide.block(width: width, metrics: metrics)
            let page = DeckPageLayout(width: width, metrics: metrics, sections: sections)
            let allApps = page.cells[2]
            XCTAssertGreaterThanOrEqual(allApps.count, block.columns, "width \(width)")
            for (sectionIndex, section) in sections.enumerated() {
                let what = "\(section.kind.rawValue) at \(width)"
                XCTAssertEqual(page.headerFrame(section)?.minX ?? -1, block.originX,
                               accuracy: 0.001, "\(what): the header starts at the grid's edge")
                for (index, frame) in page.cells[sectionIndex].enumerated() {
                    let column = index % block.columns
                    XCTAssertEqual(frame.minX, allApps[column].minX, accuracy: 0.001,
                                   "\(what): column \(column) is All Apps' column")
                    XCTAssertEqual(frame.width, allApps[column].width, accuracy: 0.001,
                                   "\(what): one cell width")
                    XCTAssertEqual(frame.width, metrics.cellWidth, accuracy: 0.001, what)
                    XCTAssertEqual(frame.height, metrics.cellHeight, accuracy: 0.001, what)
                    XCTAssertGreaterThanOrEqual(frame.minX, block.originX - 0.001, what)
                    XCTAssertLessThanOrEqual(frame.maxX, block.originX + block.span + 0.001, what)
                }
                let rows = Dictionary(grouping: page.cells[sectionIndex], by: { $0.minY })
                XCTAssertTrue(rows.values.allSatisfy { $0.count <= block.columns },
                              "\(what): a row never holds more tiles than the grid has columns")
            }
            XCTAssertEqual(page.allAppsTop,
                           page.headerFrame(sections[2]).map { $0.maxY + DeckPageLayout.headerGap } ?? -1,
                           "the All Apps cells start under their header")
        }
    }

    /// The same alignment at every icon-size step, and with the wrapper: a
    /// section above All Apps never moves a column.
    func testTheAlignmentHoldsAtEveryZoom() {
        let list = numbered(20)
        let sections = DeckPage.sections(apps: list, query: "",
                                         openPkgs: list.prefix(2).map(\.pkg),
                                         pinnedPkgs: list.prefix(4).map(\.pkg))
        for zoom in DeckZoom.options {
            let metrics = DeckGridSize(zoom: zoom)
            let page = DeckPageLayout(width: 1000, metrics: metrics, sections: sections)
            let allApps = page.cells[2]
            for cell in page.cells[0] + page.cells[1] {
                XCTAssertEqual(cell.width, metrics.cellWidth, accuracy: 0.001)
                XCTAssertTrue(allApps.contains { abs($0.minX - cell.minX) < 0.001 },
                              "zoom \(zoom): every x is a grid column")
            }
        }
    }

    /// More windows than columns wrap to a second row, on the same pitch; a
    /// section never runs into the one below it.
    func testASectionWithMoreTilesThanColumnsWraps() {
        let list = numbered(20)
        let open = Array(list.prefix(10))
        let sections = DeckPage.sections(apps: list, query: "",
                                         openPkgs: open.map(\.pkg), pinnedPkgs: [])
        let page = DeckPageLayout(width: 760, metrics: DeckGridSize(zoom: 1), sections: sections)
        let columns = page.block.columns
        XCTAssertEqual(columns, 6)
        let frames = page.cells[0]
        XCTAssertEqual(frames.count, 10)
        XCTAssertEqual(Set(frames.prefix(columns).map(\.minY)).count, 1, "the first row shares one y")
        XCTAssertEqual(frames[columns].minY,
                       frames[0].minY + 108 + 16, accuracy: 0.001,
                       "the wrap starts a row on the grid's pitch")
        XCTAssertEqual(Set(frames.dropFirst(columns).map(\.minY)).count, 1)
        XCTAssertLessThan(frames.last!.maxY, page.allAppsTop,
                          "the All Apps header is below the last open row")
    }

    // MARK: The pins (DECK-28)

    func testPinsKeepTheOrderAndTheNinthIsRefused() {
        var pins = DeckPins()
        for index in 1...9 {
            pins = pins.pinning("com.example.app\(index)")
        }
        XCTAssertEqual(pins.pkgs, (1...8).map { "com.example.app\($0)" })
        XCTAssertTrue(pins.isFull)
        XCTAssertEqual(pins.pinning("com.example.app9"), pins,
                       "a full list takes no ninth pin")
        XCTAssertEqual(pins.pinning("com.example.app1"), pins, "a pin appears once")
        let unpinned = pins.unpinning("com.example.app3")
        XCTAssertEqual(unpinned.pkgs,
                       ["com.example.app1", "com.example.app2", "com.example.app4",
                        "com.example.app5", "com.example.app6", "com.example.app7",
                        "com.example.app8"])
        XCTAssertEqual(DeckPins(["a", "a", "b"]).pkgs, ["a", "b"])
        XCTAssertEqual(DeckPins((1...10).map { "app\($0)" }).pkgs.count, 8,
                       "a stored list longer than eight keeps the first eight")
    }

    func testAPinDisappearsWhenThePhoneNoLongerListsTheApp() {
        let pins = DeckPins(["a", "gone", "b"])
        XCTAssertEqual(pins.pruning(["a", "b"]).pkgs, ["a", "b"])
        XCTAssertEqual(pins.pruning(["a", "b"]), DeckPins(["a", "b"]),
                       "nothing to drop is not a change the Deck re-reads")
    }

    /// The pins survive a relaunch (they are defaults) and belong to one phone.
    func testPinsSurviveARelaunchAndArePerPhone() throws {
        let suite = "app.contigua.tests.deckpins"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        DeckPinStore.save(DeckPins(["a", "b"]), deviceId: "phone-a", to: defaults)
        XCTAssertEqual(DeckPinStore.load(deviceId: "phone-a", from: defaults).pkgs, ["a", "b"],
                       "a new launch reads the same list")
        XCTAssertEqual(DeckPinStore.load(deviceId: "phone-b", from: defaults).pkgs, [],
                       "another phone has its own list")
        XCTAssertEqual(DeckPinStore.load(deviceId: "", from: defaults).pkgs, [])
        DeckPinStore.save(DeckPins(["c"]), deviceId: "", to: defaults)
        XCTAssertNil(defaults.object(forKey: DeckPinStore.key(deviceId: "")),
                     "no phone writes no list")
    }

    // MARK: The keyboard (DECK-29)

    /// The arrow keys move across the sections as one page: down from the open
    /// row goes to the pinned row, then to All Apps; left and right cross a
    /// section's edge; a short row keeps today's rule.
    func testArrowsMoveAcrossSectionsAsOnePage() {
        let list = numbered(20)
        let sections = DeckPage.sections(apps: list, query: "",
                                         openPkgs: list.prefix(3).map(\.pkg),
                                         pinnedPkgs: list.dropFirst(3).prefix(2).map(\.pkg))
        let cells = DeckPage.cells(sections)
        let rows = DeckPage.rows(sections, columns: 6)
        XCTAssertEqual(rows.map(\.count), [3, 2, 6, 6, 6, 2])
        func move(_ selection: String?, _ direction: GridDirection) -> String? {
            DeckPage.move(selection: selection, cells: cells, rows: rows, direction)
        }
        XCTAssertEqual(move(nil, .down), cells[0].id, "the first arrow selects the first cell")
        XCTAssertEqual(move(cells[0].id, .down), cells[3].id, "into the pinned row")
        XCTAssertEqual(move(cells[3].id, .down), cells[5].id, "into All Apps")
        XCTAssertEqual(move(cells[5].id, .down), cells[11].id, "down one All Apps row")
        XCTAssertEqual(move(cells[5].id, .up), cells[3].id, "back up into Pinned")
        XCTAssertEqual(move(cells[3].id, .left), cells[2].id, "left crosses into Open")
        XCTAssertEqual(move(cells[2].id, .right), cells[3].id, "right crosses into Pinned")
        XCTAssertEqual(move(cells[4].id, .down), cells[6].id, "the pinned row's column 1 is All Apps' column 1")
        XCTAssertEqual(move(cells[22].id, .down), cells[22].id,
                       "a short last row has no column 5: today's rule stays")
        XCTAssertEqual(move(cells[cells.count - 1].id, .right), cells[cells.count - 1].id)
        XCTAssertEqual(move(cells[0].id, .up), cells[0].id)
        XCTAssertNil(DeckPage.move(selection: nil, cells: [], rows: [], .down))
    }

    /// ⌘1–⌘9 name the first nine visible tiles in reading order, sections
    /// included.
    func testCommandDigitsNameTheFirstNineTilesInReadingOrder() {
        let list = numbered(20)
        let sections = DeckPage.sections(apps: list, query: "",
                                         openPkgs: list.prefix(3).map(\.pkg),
                                         pinnedPkgs: list.dropFirst(3).prefix(2).map(\.pkg))
        let cells = DeckPage.cells(sections)
        XCTAssertEqual(Array(cells.prefix(9).map(\.section)),
                       [.openWindows, .openWindows, .openWindows,
                        .pinned, .pinned, .allApps, .allApps, .allApps, .allApps])
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 18), 1)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 19), 2)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 20), 3)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 21), 4)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 23), 5)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 22), 6)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 26), 7)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 28), 8)
        XCTAssertEqual(DeckKeyOpen.digit(keyCode: 25), 9)
        XCTAssertNil(DeckKeyOpen.digit(keyCode: 29), "⌘0 is the zoom, not a tile")
        XCTAssertNil(DeckKeyOpen.digit(keyCode: 36), "Return is not a digit")
    }

    // MARK: The title (DECK-31)

    func testTheTitleIsAPhoneMenuOnlyWithTwoPhones() {
        XCTAssertFalse(DeckTitle.isMenu(phoneCount: 0))
        XCTAssertFalse(DeckTitle.isMenu(phoneCount: 1))
        XCTAssertTrue(DeckTitle.isMenu(phoneCount: 2))
        let rows = DeckTitle.rows([(id: "a", name: "Pixel 9"), (id: "b", name: "Galaxy S25+")],
                                  inUse: "b")
        XCTAssertEqual(rows, [DeckTitle.Row(id: "a", name: "Pixel 9", checked: false),
                              DeckTitle.Row(id: "b", name: "Galaxy S25+", checked: true)])
    }
}
