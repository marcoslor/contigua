// The menu cleanup the e2e menus check asserts (MenuCleanup.swift): the rules
// as values, without AppKit. Only removals — no item is ever added or moved.

import XCTest
@testable import PocketDeck

final class MenuCleanupTests: XCTestCase {
    private func items(_ titles: [String]) -> [MenuCleanup.Item] {
        titles.map { $0 == "—" ? MenuCleanup.Item(title: "", isSeparator: true) : MenuCleanup.Item(title: $0) }
    }

    func testADoubledSeparatorLosesTheSecondEvenWhileTheMenuIsBuilding() {
        let menu = items(["Zoom", "—", "—", "Bring All to Front"])
        XCTAssertEqual(MenuCleanup.removals(menu: "Window", items: menu),
                       [MenuCleanup.Removal(path: [2])])
    }

    func testAMenuEdgeSeparatorIsLeftForSwiftUIToFinish() {
        let menu = items(["—", "Zoom", "—"])
        XCTAssertEqual(MenuCleanup.removals(menu: "Window", items: menu), [])
    }

    func testHelpLosesTheAppleFeedbackItemAndItsSeparator() {
        let menu = items(["Send PocketDeck Feedback to Apple", "—"])
        XCTAssertEqual(MenuCleanup.removals(menu: "Help", items: menu),
                       [MenuCleanup.Removal(path: [0]), MenuCleanup.Removal(path: [1])])
    }

    func testAFeedbackTitleOutsideHelpIsTheAppsOwnItem() {
        let menu = items(["Send Feedback"])
        XCTAssertEqual(MenuCleanup.removals(menu: "View", items: menu), [])
    }

    func testASubmenusRemovalsCarryTheirPath() {
        let density = MenuCleanup.Item(title: "Density", children: items(["—", "75%", "—", "—"]))
        let menu = [MenuCleanup.Item(title: "View", children: [density])]
        XCTAssertEqual(MenuCleanup.removals(menu: "", items: menu),
                       [MenuCleanup.Removal(path: [0, 0, 3])])
    }

    func testACleanMenuHasNothingToRemove() {
        let menu = items(["Find Apps", "—", "Framed", "Immersive"])
        XCTAssertEqual(MenuCleanup.removals(menu: "View", items: menu), [])
    }

    func testTheFeedbackTitleRuleMatchesBothWordings() {
        XCTAssertTrue(MenuCleanup.isSystemFeedback("Send PocketDeck Feedback to Apple"))
        XCTAssertTrue(MenuCleanup.isSystemFeedback("Send PocketDeck Feedback"))
        XCTAssertFalse(MenuCleanup.isSystemFeedback("PocketDeck on GitHub"))
    }
}
