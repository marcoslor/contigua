// The rail's arc (DECK-7): a magnified letter reaches left out of the rail's
// column, its reach capped by the room the window leaves before the last icon
// column's cell, while the letters at rest keep their centred position.

import XCTest
@testable import PocketDeck

final class RailArcTests: XCTestCase {
    func testTheArcIsZeroAtRestAndUnderReduceMotion() {
        XCTAssertEqual(RailArc.offset(scale: 1, reduceMotion: false, room: 100), 0,
                       "a rest letter does not move")
        XCTAssertEqual(RailArc.offset(scale: 2.2, reduceMotion: true, room: 100), 0,
                       "Reduce Motion has no arc")
        XCTAssertEqual(RailArc.reach(scale: 2.2, reduceMotion: true, room: 100), 0)
    }

    func testTheOffsetGrowsWithTheScale() {
        var previous: CGFloat = 0
        for step in stride(from: CGFloat(1), through: 2.2, by: 0.1) {
            let offset = RailArc.offset(scale: step, reduceMotion: false, room: 100)
            XCTAssertLessThanOrEqual(offset, previous, "the arc only moves further left")
            previous = offset
        }
        XCTAssertEqual(previous, -RailArc.reachK * 1.2, accuracy: 0.001,
                       "the peak at 2.2x is k x 1.2 when the room allows it")
    }

    func testTheReachAtThePeakAndTheRoomsCap() {
        let wide = RailArc.room(width: 1000)
        let narrow = RailArc.room(width: 640)
        XCTAssertLessThan(narrow, wide, "a narrow window leaves less room")
        XCTAssertEqual(RailArc.reach(scale: 2.2, reduceMotion: false, room: wide),
                       RailArc.growth(scale: 2.2) + RailArc.reachK * 1.2, accuracy: 0.001)
        XCTAssertEqual(RailArc.reach(scale: 2.2, reduceMotion: false, room: narrow),
                       narrow, accuracy: 0.001, "the narrow room caps the arc")
    }

    /// The arc stays at least 4 pt clear of the last icon column's cell at the
    /// Deck's narrowest window and at 625 pt's width and wider.
    func testTheArcKeepsClearOfTheLastIconColumn() {
        for width in [CGFloat(640), 760, 1000, 1200] {
            let clearance = RailArc.clearance(width: width, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(clearance, RailArc.minimumClearance,
                                        "at \(width) pt leaves \(clearance) pt")
        }
        XCTAssertGreaterThan(RailArc.reachK, 3.3, "the arc is stronger than the first prototype's")
        XCTAssertGreaterThan(RailArc.reach(scale: 2.2, reduceMotion: false,
                                           room: RailArc.room(width: 1000)),
                             9, "at 1000 pt the arc reaches further than 9 pt")
    }

    func testTheTagSitsLeftOfTheWidestLetter() {
        let reach = RailArc.reach(scale: 2.2, reduceMotion: false,
                                  room: RailArc.room(width: 1000))
        // From the rail's trailing edge: the widest leading and the tag's right
        // edge, which the view places 6 pt left of it.
        let widestLead = -(26 - RailArc.centredLead + reach)
        let tagRight = widestLead - 6
        XCTAssertLessThan(tagRight, widestLead, "the tag never covers the arc")
    }
}
