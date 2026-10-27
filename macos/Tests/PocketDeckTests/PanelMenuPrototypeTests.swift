// The menu bar panel's secondary-click prototype (PanelMenuPrototype.swift):
// what the one flag value may say, and which of the three renders moves what.

import XCTest
@testable import PocketDeck

final class PanelMenuPrototypeTests: XCTestCase {
    /// The flag carries its own key: another key's value, a fourth option or a
    /// bare value all leave the panel alone rather than guessing.
    func testTheFlagReadsOnlyPanelmenuAndOnlyItsThreeOptions() {
        XCTAssertEqual(PanelMenuPrototype.parse("panelmenu=M1"), .m1)
        XCTAssertEqual(PanelMenuPrototype.parse("panelmenu=M2"), .m2)
        XCTAssertEqual(PanelMenuPrototype.parse("panelmenu=M3"), .m3)
        XCTAssertNil(PanelMenuPrototype.parse(nil))
        XCTAssertNil(PanelMenuPrototype.parse(""))
        XCTAssertNil(PanelMenuPrototype.parse("M1"))
        XCTAssertNil(PanelMenuPrototype.parse("panelmenu=M4"))
        XCTAssertNil(PanelMenuPrototype.parse("other=M1"))
        XCTAssertNil(PanelMenuPrototype.parse("panelmenu=m1"), "the value is the review's capital letter")
    }

    /// M1 moves Settings…/Quit out of the panel, M2 adds the gear, and M3 keeps
    /// today's footer: the three options the person is choosing between.
    func testEachOptionMovesWhatItSays() {
        XCTAssertFalse(PanelMenuPrototype.m1.showsFooter)
        XCTAssertFalse(PanelMenuPrototype.m1.showsGear)

        XCTAssertFalse(PanelMenuPrototype.m2.showsFooter)
        XCTAssertTrue(PanelMenuPrototype.m2.showsGear)

        XCTAssertTrue(PanelMenuPrototype.m3.showsFooter)
        XCTAssertFalse(PanelMenuPrototype.m3.showsGear)

        XCTAssertEqual(Set(PanelMenuPrototype.allCases.map(\.rawValue)), ["M1", "M2", "M3"])
    }
}
