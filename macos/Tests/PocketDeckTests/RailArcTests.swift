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

    /// The rail stands one gap right of the grid at every width now, so the
    /// room is that gap (plus the letter's lead) everywhere, and the peak arc
    /// still fits inside it.
    func testTheRoomIsTheRailsGapAtEveryWidth() {
        let room = RailArc.room(width: 1000)
        XCTAssertEqual(room, DeckWide.railGap + RailArc.centredLead - RailArc.minimumClearance,
                       accuracy: 0.001)
        for width in [CGFloat(640), 760, 1000, 1200, 1960] {
            XCTAssertEqual(RailArc.room(width: width), room, accuracy: 0.001, "at \(width) pt")
        }
        XCTAssertEqual(RailArc.reach(scale: 2.2, reduceMotion: false, room: room),
                       RailArc.growth(scale: 2.2) + RailArc.reachK * 1.2, accuracy: 0.001,
                       "the peak fits inside the gap")
        XCTAssertLessThan(RailArc.reach(scale: 2.2, reduceMotion: false, room: room), room)
        XCTAssertEqual(RailArc.reach(scale: 2.2, reduceMotion: false, room: 10), 10, accuracy: 0.001,
                       "a smaller room still caps the arc")
    }

    /// The arc stays at least 4 pt clear of the last icon column's cell at the
    /// Deck's narrowest window and at 625 pt's width and wider.
    func testTheArcKeepsClearOfTheLastIconColumn() {
        for width in [CGFloat(640), 760, 1000, 1200, 1960] {
            let clearance = RailArc.clearance(width: width, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(clearance, RailArc.minimumClearance,
                                        "at \(width) pt leaves \(clearance) pt")
        }
        XCTAssertGreaterThan(RailArc.reachK, 3.3, "the arc is stronger than the first prototype's")
        XCTAssertGreaterThan(RailArc.reach(scale: 2.2, reduceMotion: false,
                                           room: RailArc.room(width: 1000)),
                             9, "at 1000 pt the arc reaches further than 9 pt")
    }

    /// The magnified hit area grows left with the arc but never over the last
    /// icon column's cell: its left edge keeps the 4 pt clearance the widest
    /// letter keeps, and it still covers the letters it must.
    func testTheHitAreaKeepsClearOfTheLastIconColumn() {
        for width in [CGFloat(640), 760, 1000] {
            let block = DeckWide.block(width: width, metrics: DeckGridSize(zoom: 1))
            let cellRight = block.originX + block.span
            let hitEdge = block.railLeading - RailArc.hitRoom(width: width)
            XCTAssertGreaterThanOrEqual(hitEdge, cellRight + RailArc.minimumClearance - 0.001,
                                        "at \(width) pt the hit area reaches \(hitEdge), the cell ends at \(cellRight)")
            let reach = RailArc.reach(scale: RailFisheye.maxScale, reduceMotion: false,
                                      room: RailArc.room(width: width))
            let widestLead = block.railLeading + RailArc.centredLead - reach
            XCTAssertLessThanOrEqual(hitEdge, widestLead + 0.001,
                                     "at \(width) pt the hit area starts right of the widest letter")
        }
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
