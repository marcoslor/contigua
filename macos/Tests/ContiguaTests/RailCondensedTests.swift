// The condensed rail's skipped-letter dots (DECK-7): a slot that covers
// several letters draws only one, so each gap whose drawn letters leave
// letters between them carries one small vertical dot, centred in the column
// and riding the same arc as the letters. Never beside a letter, never
// accent-tinted, and never drawn where the gap skips nothing.

import XCTest
@testable import Contigua

final class RailCondensedTests: XCTestCase {
    private let pitch: CGFloat = DeckRail.pitch

    private func slots(_ count: Int) -> [DeckRail.Slot] {
        DeckRail.slots(forHeight: CGFloat(count) * pitch) ?? []
    }

    private func restLayout(_ count: Int) -> [RailLayout.Slot] {
        RailLayout.slots(scales: Array(repeating: 1, count: count), pitch: pitch, anchor: nil)
    }

    private func restScales(_ count: Int) -> [CGFloat] {
        Array(repeating: 1, count: count)
    }

    /// One entry per letter, with an app on the letters in `withApps`.
    private func entries(withApps apps: Set<String> = []) -> [DeckRail.Entry] {
        DeckRail.letters.map { DeckRail.Entry(letter: $0, index: apps.contains($0) ? 0 : nil) }
    }

    private func dots(_ count: Int, entries: [DeckRail.Entry]? = nil,
                      hovered: (slot: Int, letterIndex: Int)? = nil,
                      currentIndex: Int? = nil, reduceMotion: Bool = false,
                      arcRoom: CGFloat = 0) -> [RailCondensed.Dot] {
        RailCondensed.dots(slots: slots(count), layout: restLayout(count),
                            scales: restScales(count),
                            entries: entries ?? self.entries(),
                            hovered: hovered, currentIndex: currentIndex,
                            reduceMotion: reduceMotion, arcRoom: arcRoom)
    }

    // MARK: The full rail

    func testFullRailDrawsNoCondensedDots() {
        XCTAssertTrue(dots(27).isEmpty, "one letter per slot skips nothing")
        XCTAssertTrue(dots(27, currentIndex: 13).isEmpty)
        XCTAssertTrue(dots(27, hovered: (slot: 13, letterIndex: 13)).isEmpty)
    }

    // MARK: Every other letter

    func testEveryOtherLetterDrawsCenteredVerticalDotsBetweenSlots() {
        let count = 14
        let layout = restLayout(count)
        let drawn = dots(count)
        XCTAssertEqual(drawn.count, 13, "every gap between the 14 slots, but none after #")
        XCTAssertFalse(drawn.contains { $0.afterSlot == 13 }, "the last slot is # and skips nothing")
        for dot in drawn {
            XCTAssertEqual(dot.xOffset, 0, accuracy: 0.001,
                           "a rest dot sits in the letters' column")
            XCTAssertEqual(dot.y, layout[dot.afterSlot].y + layout[dot.afterSlot].height,
                           accuracy: 0.001,
                           "the dot is centred in the gap after slot \(dot.afterSlot)")
        }
    }

    /// Hovering the band that names B inside A's slot leaves nothing between B
    /// and C; hovering A itself keeps the dot that stands for B.
    func testHoveringBRemovesDotBetweenBAndCWhileHoveringAKeepsIt() {
        XCTAssertTrue(dots(14).contains { $0.afterSlot == 0 },
                      "at rest the gap after A skips B")
        XCTAssertFalse(dots(14, hovered: (slot: 0, letterIndex: 1)).contains { $0.afterSlot == 0 },
                       "with B drawn in A's slot the gap skips nothing")
        XCTAssertTrue(dots(14, hovered: (slot: 0, letterIndex: 0)).contains { $0.afterSlot == 0 })
    }

    /// N is the second letter of the M–N slot: the gap from K to N keeps its
    /// dot, the gap from N to O skips nothing.
    func testCurrentLetterInSecondHalfAdjustsAdjacentDots() {
        let n = DeckRail.letters.firstIndex(of: "N")!
        let drawn = dots(14, currentIndex: n)
        XCTAssertEqual(drawn.count, 12)
        XCTAssertTrue(drawn.contains { $0.afterSlot == 5 }, "K to N still skips L and M")
        XCTAssertFalse(drawn.contains { $0.afterSlot == 6 }, "N to O skips nothing")
    }

    // MARK: Every third letter

    func testEveryThirdLetterDrawsOneDotPerGapAndTrailingDotInsideSpan() {
        let count = 9
        let layout = restLayout(count)
        let span = RailLayout.Span(top: 0, length: CGFloat(count) * pitch)
        let drawn = dots(count)
        XCTAssertEqual(drawn.count, 9, "eight gaps plus the tail after Y")
        for dot in drawn {
            XCTAssertGreaterThanOrEqual(dot.y - RailCondensed.dotDiameter / 2, span.top - 0.001)
            XCTAssertLessThanOrEqual(dot.y + RailCondensed.dotDiameter / 2, span.bottom + 0.001,
                                     "the tail dot stays inside the span")
            XCTAssertEqual(dot.xOffset, 0, accuracy: 0.001)
        }
        XCTAssertEqual(drawn.last?.afterSlot, 8, "the tail dot follows the last slot")
        XCTAssertEqual(drawn.last?.y ?? 0,
                       layout[8].y + layout[8].height - RailCondensed.dotDiameter / 2,
                       accuracy: 0.001)

        let hoveredHash = DeckRail.letters.firstIndex(of: "#")!
        XCTAssertEqual(dots(count, hovered: (slot: 8, letterIndex: hoveredHash)).count, 8,
                       "hovering # draws no tail dot")
    }

    // MARK: Apps and dimming

    func testDotOpacityFollowsWhetherSkippedLettersHaveApps() {
        let drawn = dots(14, entries: entries(withApps: ["D"]))
        let afterA = drawn.first { $0.afterSlot == 0 }
        let afterC = drawn.first { $0.afterSlot == 1 }
        XCTAssertEqual(afterA?.hasApps, false, "the dot after A stands for B alone")
        XCTAssertEqual(afterC?.hasApps, true, "the dot after C stands for D, which has an app")
    }

    // MARK: The arc

    func testDotsFollowMagnifiedArcAndStayWithinFrozenSpan() {
        let count = 14
        let span = RailLayout.span(count: count, pitch: pitch, anchor: 3.2 * pitch)
        let centre = RailLayout.frozenCentre(atY: 3.2 * pitch, span: span, count: count)
        let scales = RailLayout.scales(count: count, centre: centre, reduceMotion: false)
        let layout = RailLayout.frozenSlots(scales: scales, span: span)

        let magnified = RailCondensed.dots(slots: slots(count), layout: layout, scales: scales,
                                           entries: entries(), hovered: nil, currentIndex: nil,
                                           reduceMotion: false, arcRoom: 100)
        XCTAssertFalse(magnified.isEmpty)
        XCTAssertTrue(magnified.contains { $0.xOffset < 0 },
                      "a dot between two magnified slots follows the arc")
        for dot in magnified {
            XCTAssertGreaterThanOrEqual(dot.y - RailCondensed.dotDiameter / 2, span.top - 0.001,
                                        "dot \(dot.afterSlot) above the frozen top")
            XCTAssertLessThanOrEqual(dot.y + RailCondensed.dotDiameter / 2, span.bottom + 0.001,
                                     "dot \(dot.afterSlot) below the frozen bottom")
        }

        let still = RailCondensed.dots(slots: slots(count), layout: layout, scales: scales,
                                       entries: entries(), hovered: nil, currentIndex: nil,
                                       reduceMotion: true, arcRoom: 100)
        XCTAssertEqual(still.count, magnified.count)
        for dot in still {
            XCTAssertEqual(dot.xOffset, 0, accuracy: 0.001, "Reduce Motion has no arc")
        }
    }

    // MARK: Mismatched input

    func testMismatchedListsDrawNothing() {
        XCTAssertTrue(RailCondensed.dots(slots: [], layout: [], scales: [], entries: entries(),
                                        hovered: nil, currentIndex: nil,
                                        reduceMotion: false, arcRoom: 0).isEmpty)
        XCTAssertTrue(RailCondensed.dots(slots: slots(14), layout: restLayout(9),
                                        scales: restScales(14), entries: entries(),
                                        hovered: nil, currentIndex: nil,
                                        reduceMotion: false, arcRoom: 0).isEmpty)
        XCTAssertTrue(RailCondensed.dots(slots: slots(14), layout: restLayout(14),
                                        scales: restScales(9), entries: entries(),
                                        hovered: nil, currentIndex: nil,
                                        reduceMotion: false, arcRoom: 0).isEmpty)
    }
}
