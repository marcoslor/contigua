// DECK-8 and DECK-3: what the Deck's grid says when it has nothing to draw, and
// the help tag a truncated app name gets. Both are pure, so the copy and the
// placeholder count are pinned without a window.

import AppKit
import XCTest
@testable import Contigua

final class DeckEmptyStateTests: XCTestCase {
    /// The skeleton is one quiet line and twelve silent grey cells, never a
    /// cell per "Loading".
    func testTheSkeletonIsOneLineAndSilentCells() {
        XCTAssertEqual(DeckGridEmpty.loadingLine, "Loading apps…")
        XCTAssertEqual(DeckGridEmpty.placeholderCells, 12)
        XCTAssertEqual(DeckGridEmpty.content(query: "", appsLoaded: false, phoneHasApps: false),
                       .placeholders)
        XCTAssertEqual(DeckGridEmpty.content(query: "", appsLoaded: false, phoneHasApps: true),
                       .placeholders)
    }

    /// A phone with no launchable apps says so, with or without a query; a
    /// phone with apps keeps the search's own message.
    func testZeroAppsSaysNoAppsOnThisPhone() {
        XCTAssertEqual(DeckGridEmpty.content(query: "", appsLoaded: true, phoneHasApps: false),
                       .noApps)
        XCTAssertEqual(DeckGridEmpty.content(query: "ca", appsLoaded: true, phoneHasApps: false),
                       .noApps)
        XCTAssertEqual(DeckGridEmpty.noAppsText, "No apps on this phone.")
        XCTAssertEqual(DeckGridEmpty.content(query: "zzz", appsLoaded: true, phoneHasApps: true),
                       .noMatches("zzz"))
    }

    /// The cell's help tag carries the full name only while the drawn line
    /// truncates it at the cell's own size.
    func testATruncatedNameGetsItsFullNameAsAHelpTag() {
        let base = DeckGridSize(zoom: 1).cellWidth
        XCTAssertNil(DeckLabel.truncationHelp("Maps", cellWidth: base))
        XCTAssertNil(DeckLabel.truncationHelp("Files by Google", cellWidth: base))
        XCTAssertEqual(DeckLabel.truncationHelp("Google Play Services", cellWidth: base),
                       "Google Play Services")
        XCTAssertNil(DeckLabel.truncationHelp("Google Play Services",
                                              cellWidth: DeckGridSize(zoom: 1.5).cellWidth),
                     "a bigger icon size gives the name room, so no tag")
    }

    /// The placeholder cell draws no words of its own (the one line is above
    /// the grid), so no cell can be left saying "Loading".
    func testThePlaceholderCellSaysNothing() throws {
        let source = try String(contentsOf: sourceFile("DeckViews.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Text(\"Loading"),
                       "a placeholder cell still says Loading")
        XCTAssertTrue(source.contains("Text(DeckGridEmpty.loadingLine)"),
                      "the one loading line comes from the model")
    }

    private func sourceFile(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Contigua", isDirectory: true)
            .appendingPathComponent(name)
    }
}
