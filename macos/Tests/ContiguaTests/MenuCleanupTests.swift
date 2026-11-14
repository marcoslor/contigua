// The menu cleanup the e2e menus check asserts (MenuCleanup.swift): the rules
// as values, without AppKit. Only removals — no item is ever added or moved.

import XCTest
@testable import Contigua

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
        let menu = items(["Send Contigua Feedback to Apple", "—"])
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
        let menu = items(["Find Apps", "—", "Framed", "Compact"])
        XCTAssertEqual(MenuCleanup.removals(menu: "View", items: menu), [])
    }

    func testTheFeedbackTitleRuleMatchesBothWordings() {
        XCTAssertTrue(MenuCleanup.isSystemFeedback("Send Contigua Feedback to Apple"))
        XCTAssertTrue(MenuCleanup.isSystemFeedback("Send Contigua Feedback"))
        XCTAssertFalse(MenuCleanup.isSystemFeedback("Contigua on GitHub"))
    }

    func testNoFullScreenItemIsEverRemoved() {
        // AppKit's own Enter Full Screen is the design in View and its tiling
        // submenu is the system's in Window (MENU-4, MENU-7). The cleanup pass
        // must never remove either, whatever else the menu holds.
        let view = [MenuCleanup.Item(title: "Density"),
                    MenuCleanup.Item(title: "", isSeparator: true),
                    MenuCleanup.Item(title: "Enter Full Screen")]
        XCTAssertEqual(MenuCleanup.removals(menu: "View", items: view), [])

        let window = [MenuCleanup.Item(title: "Enter Full Screen"),
                      MenuCleanup.Item(title: "Full Screen Tile", children: [
                          MenuCleanup.Item(title: "Left of Screen"),
                          MenuCleanup.Item(title: "Right of Screen"),
                      ]),
                      MenuCleanup.Item(title: "Bring All to Front")]
        XCTAssertEqual(MenuCleanup.removals(menu: "Window", items: window), [])
    }
}
