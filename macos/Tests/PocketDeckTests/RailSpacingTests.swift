// The rail's spacing while magnified (S1/S2/S3, prototype): what the drawn
// slots are, that they keep the pointer's letter under the pointer, and that
// hit-testing follows what is drawn.

import XCTest
@testable import PocketDeck

final class RailSpacingTests: XCTestCase {
    private let eps: CGFloat = 0.001
    private var pitch: CGFloat { DeckRail.pitch }
    private var restHeight: CGFloat { CGFloat(DeckRail.letters.count) * pitch }

    /// A2's scales with the pointer on M (its slot centre): M 2.2, neighbours
    /// tapering the same way the view computes them.
    private func mScales() -> [CGFloat] {
        (0..<DeckRail.letters.count).map {
            RailFisheye.scale(distance: CGFloat($0) - 12, dx: 0,
                              zone: RailApproach.zone, reduceMotion: false)
        }
    }

    private func restScales(_ count: Int = DeckRail.letters.count) -> [CGFloat] {
        Array(repeating: 1, count: count)
    }

    private func anchor(of index: Int) -> CGFloat { CGFloat(index) * pitch + pitch / 2 }

    /// The slot whose drawn box contains `y`; nil if the layout is empty.
    private func slot(containing y: CGFloat, in layout: [RailLayout.Slot]) -> Int? {
        layout.firstIndex { y >= $0.y && y < $0.y + $0.height }
    }

    func testTheReferenceLayoutIsTodaysFixedRows() {
        let layout = RailLayout.slots(scales: mScales(), available: restHeight,
                                      strategy: .reference, anchor: 250)
        XCTAssertEqual(layout.count, DeckRail.letters.count)
        for (index, slot) in layout.enumerated() {
            XCTAssertEqual(slot.y, CGFloat(index) * pitch, accuracy: eps)
            XCTAssertEqual(slot.height, pitch, accuracy: eps)
        }
    }

    /// Reduce Motion runs the rail with every scale at 1; all three strategies
    /// must then draw exactly today's rows.
    func testTheRestScalesGiveTheRestLayoutForEveryStrategy() {
        let reference = RailLayout.slots(scales: restScales(), available: restHeight,
                                         strategy: .reference, anchor: nil)
        for strategy in [RailSpacing.dock, .lens, .arc] {
            let layout = RailLayout.slots(scales: restScales(), available: restHeight,
                                          strategy: strategy, anchor: nil)
            for (index, slot) in layout.enumerated() {
                XCTAssertEqual(slot.y, reference[index].y, accuracy: eps, "\(strategy) y at \(index)")
                XCTAssertEqual(slot.height, pitch, accuracy: eps, "\(strategy) height at \(index)")
            }
        }
    }

    func testS2KeepsTheRailHeightFixed() {
        let layout = RailLayout.slots(scales: mScales(), available: restHeight,
                                      strategy: .lens, anchor: 250)
        XCTAssertEqual(layout.map(\.height).reduce(0, +), restHeight, accuracy: eps,
                       "S2's slots always sum to the rail's height")
        XCTAssertLessThan(layout[0].height, pitch, "the far letters pay: their slots shrink")
        XCTAssertGreaterThan(layout[12].height, pitch, "the letter under the pointer grows")
    }

    func testS1AndS3GrowAroundTheAnchor() {
        for strategy in [RailSpacing.dock, .arc] {
            let layout = RailLayout.slots(scales: mScales(), available: restHeight,
                                          strategy: strategy, anchor: 250)
            let total = layout.map(\.height).reduce(0, +)
            XCTAssertGreaterThan(total, restHeight + 40, "\(strategy) grows the rail")
            XCTAssertLessThan(layout[0].y, 0, "\(strategy) grows upward past the rest top")
            XCTAssertEqual(layout[1].height, layout[2].height, accuracy: eps,
                           "\(strategy) is proportional, not shrinking the far slots")
        }
    }

    func testS3DrawsS1sSlots() {
        XCTAssertEqual(RailLayout.slots(scales: mScales(), available: restHeight,
                                        strategy: .arc, anchor: 250),
                       RailLayout.slots(scales: mScales(), available: restHeight,
                                        strategy: .dock, anchor: 250),
                       "S3 is S1's proportional slots, drawn from the baseline")
    }

    func testThePointerLetterStaysUnderThePointer() {
        for strategy in [RailSpacing.dock, .lens, .arc] {
            for index in [0, 2, 12, 26] {
                let pointer = anchor(of: index)
                let layout = RailLayout.slots(scales: mScales(), available: restHeight,
                                              strategy: strategy, anchor: pointer)
                XCTAssertEqual(slot(containing: pointer, in: layout), index,
                               "\(strategy): the pointer on \(DeckRail.letters[index]) stays in its slot")
                let within = (pointer - layout[index].y) / layout[index].height
                XCTAssertEqual(within, 0.5, accuracy: 0.01,
                               "\(strategy): the pointer keeps its place inside the slot")
            }
        }
    }

    func testTheMappingIsMonotonic() {
        for strategy in [RailSpacing.dock, .lens, .arc] {
            let layout = RailLayout.slots(scales: mScales(), available: restHeight,
                                          strategy: strategy, anchor: 250)
            for index in 1..<layout.count {
                XCTAssertGreaterThan(layout[index].y, layout[index - 1].y, "\(strategy) y grows")
                XCTAssertGreaterThan(layout[index].height, 0, "\(strategy) slots are never empty")
            }
        }
    }

    /// S2 makes the far letters pay for the peak: the space between them and
    /// the letter under the pointer shrinks.
    func testS2PullsTheFarLettersTowardThePointer() {
        let reference = RailLayout.slots(scales: mScales(), available: restHeight,
                                         strategy: .reference, anchor: 250)
        let lens = RailLayout.slots(scales: mScales(), available: restHeight,
                                    strategy: .lens, anchor: 250)
        let restAbove = reference[12].y - (reference[0].y + reference[0].height)
        let lensAbove = lens[12].y - (lens[0].y + lens[0].height)
        XCTAssertLessThan(lensAbove, restAbove, "the letters above M come closer")
        let restBelow = reference[26].y - (reference[12].y + reference[12].height)
        let lensBelow = lens[26].y - (lens[12].y + lens[12].height)
        XCTAssertLessThan(lensBelow, restBelow, "the letters below M come closer")
        XCTAssertGreaterThan(abs(lens[0].y - reference[0].y) + abs(lens[26].y - reference[26].y),
                             1, "the far letters really move")
    }

    func testHitTestingFollowsTheDrawnSlots() {
        let layout = RailLayout.slots(scales: mScales(), available: restHeight,
                                      strategy: .dock, anchor: 250)
        let slots = DeckRail.slots(forHeight: DeckRail.minimumHeight) ?? []
        for (index, slot) in layout.enumerated() {
            let y = slot.y + slot.height / 2
            XCTAssertEqual(RailLayout.letter(atY: y, in: layout, slots: slots),
                           DeckRail.letters[slots[index].first],
                           "the centre of slot \(index) picks its letter")
        }
    }

    func testHitTestingSplitsACondensedSlotTheSameWay() {
        let slots = DeckRail.slots(forHeight: DeckRail.compactTwoHeight) ?? []
        XCTAssertEqual(slots.count, 14)
        let layout = RailLayout.slots(scales: restScales(14), available: 280,
                                      strategy: .dock, anchor: nil)
        // A to Z every other letter: the first slot holds A and B.
        XCTAssertEqual(RailLayout.letter(atY: layout[0].y + 1, in: layout, slots: slots), "A")
        XCTAssertEqual(RailLayout.letter(atY: layout[0].y + pitch - 1, in: layout, slots: slots), "B")
        XCTAssertEqual(RailLayout.letter(atY: layout[3].y + 1, in: layout, slots: slots), "G")
    }

    func testTheSpacingFlagParsesOnlyItsOwnKey() {
        XCTAssertEqual(RailSpacing.parse("railspace=S1"), .dock)
        XCTAssertEqual(RailSpacing.parse("railspace=S2"), .lens)
        XCTAssertEqual(RailSpacing.parse("railspace=S3"), .arc)
        XCTAssertNil(RailSpacing.parse("railspace=S4"))
        XCTAssertNil(RailSpacing.parse("railzone=A2"), "the approach flag is gone")
        XCTAssertNil(RailSpacing.parse("S2"))
        XCTAssertTrue(RailSpacing.arc.isEdgeAnchored)
        XCTAssertFalse(RailSpacing.dock.isEdgeAnchored)
        XCTAssertFalse(RailSpacing.lens.isEdgeAnchored)
    }
}
