import XCTest
@testable import Contigua

// The Show Touches default (TrackpadPresence.swift): on where the Mac has a
// trackpad, off otherwise — until the person toggles it themselves.

final class ShowTouchesDefaultTests: XCTestCase {
    func testATrackpadTurnsShowTouchesOnByDefault() {
        XCTAssertTrue(ShowTouchesDefault.resolve(hasTrackpad: true, stored: nil))
    }

    func testWithoutATrackpadItStaysOffByDefault() {
        XCTAssertFalse(ShowTouchesDefault.resolve(hasTrackpad: false, stored: nil))
    }

    func testAStoredChoiceAlwaysWins() {
        XCTAssertFalse(ShowTouchesDefault.resolve(hasTrackpad: true, stored: false))
        XCTAssertTrue(ShowTouchesDefault.resolve(hasTrackpad: false, stored: true))
    }
}
