// The rail's vertical layout (DECK-7): 11 pt boxes with equal gaps, the rest
// pitch giving way so the magnified ends fit, and the span frozen on enter so
// A's top and #'s bottom do not move while the pointer sweeps. Nothing clipped,
// the drawn slot under the pointer is the fisheye's centre, and no slot edge
// jumps.

import XCTest
@testable import PocketDeck

final class RailLayoutTests: XCTestCase {
    /// The content area above the rail: 573 pt at a 625 pt window, 368 pt at the
    /// Deck's minimum 420 pt (measured from the real render).
    private let content625: CGFloat = 573
    private let contentMinimum: CGFloat = 368

    private func fit(_ content: CGFloat) -> (count: Int, pitch: CGFloat) {
        guard let fit = RailLayout.fit(content: content) else {
            XCTFail("no rail fit for \(content) pt"); return (0, 0)
        }
        return fit
    }

    private func slots(_ count: Int) -> [DeckRail.Slot] {
        DeckRail.slots(forHeight: CGFloat(count) * DeckRail.pitch) ?? []
    }

    private func rest(_ count: Int, pitch: CGFloat) -> [RailLayout.Slot] {
        RailLayout.slots(scales: Array(repeating: 1, count: count), pitch: pitch, anchor: nil)
    }

    /// The drawn slots at `y` after entering at `anchor`: the centre solved
    /// inside the frozen span, exactly as the rail draws it.
    private func drawn(at y: CGFloat, from anchor: CGFloat, pitch: CGFloat, count: Int)
        -> (layout: [RailLayout.Slot], scales: [CGFloat]) {
        let span = RailLayout.span(count: count, pitch: pitch, anchor: anchor)
        let centre = RailLayout.frozenCentre(atY: y, span: span, count: count)
        let scales = RailLayout.scales(count: count, centre: centre, reduceMotion: false)
        return (RailLayout.frozenSlots(scales: scales, span: span), scales)
    }

    private func edges(_ layout: [RailLayout.Slot]) -> [CGFloat] {
        layout.map(\.y) + layout.map { $0.y + $0.height }
    }

    // MARK: The rest pitch

    func testRestPitchIsTwentyWhenThereIsRoom() {
        XCTAssertEqual(RailLayout.restPitch(count: 27, content: 848), 20, accuracy: 0.001)
        XCTAssertEqual(RailLayout.maximumPitch, 20)
        XCTAssertEqual(RailLayout.minimumPitch, 18)
    }

    func testRestPitchGivesWayOnlyAsFarAsItMust() {
        // At 625 pt the 27-letter rail cannot keep 20 pt: it needs about 19.7.
        let pitch = RailLayout.restPitch(count: 27, content: content625)
        XCTAssertEqual(pitch, 19.7, accuracy: 0.15,
                       "the review's measure: about 19.7 pt at 625")
        XCTAssertLessThan(pitch, 20)
        XCTAssertGreaterThanOrEqual(pitch, 18)

        var previous: CGFloat = 0
        for content in stride(from: contentMinimum, through: 848, by: 5) {
            let p = RailLayout.restPitch(count: 27, content: content)
            XCTAssertLessThanOrEqual(p, 20)
            XCTAssertGreaterThanOrEqual(p, previous, "a taller window never narrows the pitch")
            previous = p
            guard p >= 18 else { continue }
            XCTAssertLessThanOrEqual(27 * p + 2 * RailLayout.endExtension(count: 27),
                                     content + 0.001, "the pitch must leave room at \(content)")
            if p < 20 {
                XCTAssertGreaterThan(27 * (p + 0.5) + 2 * RailLayout.endExtension(count: 27),
                                     content, "half a point more would not fit at \(content)")
            }
        }
    }

    func testFitCondensesBelowEighteenAndHidesWhenNothingFits() {
        XCTAssertEqual(fit(content625).count, 27)
        XCTAssertEqual(fit(contentMinimum).count, 14, "at the minimum window the rail condenses to every other letter")
        XCTAssertEqual(fit(240).count, 9)
        XCTAssertNil(RailLayout.fit(content: 80), "nothing fits in 80 pt")
        for content in stride(from: contentMinimum, through: 848, by: 5) {
            let (count, pitch) = fit(content)
            XCTAssertGreaterThanOrEqual(pitch, 18, "the fit never returns a pitch below the condense floor")
            XCTAssertGreaterThanOrEqual(count, 8)
        }
    }

    // MARK: The three properties

    /// DECK-7: no glyph is ever clipped, at any pointer y and any window height
    /// from the minimum to 900 pt. Entering at any y freezes a span that holds
    /// every slot and every glyph, so the drawn rail cannot leave the inset.
    func testNothingIsClippedAtAnyPointerYOrWindowHeight() {
        for content in stride(from: contentMinimum, through: 848, by: 10) {
            let (count, pitch) = fit(content)
            let total = CGFloat(count) * pitch
            let slack = (content - total) / 2
            XCTAssertGreaterThanOrEqual(slack, 0, "the rail fits its content at \(content)")
            // The span is the open layout's own ends, so the worst enter y is
            // the one whose ends reach furthest; sample every 4 pt and the ends.
            var anchor: CGFloat = 0
            while anchor <= total {
                let span = RailLayout.span(count: count, pitch: pitch, anchor: anchor)
                XCTAssertGreaterThanOrEqual(span.top, -slack - 0.001,
                                            "\(count) slots at \(content): the span's top at enter \(anchor)")
                XCTAssertLessThanOrEqual(span.bottom, total + slack + 0.001,
                                         "\(count) slots at \(content): the span's bottom at enter \(anchor)")
                for fraction in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                    let y = span.top + span.length * fraction
                    let layout = drawn(at: y, from: anchor, pitch: pitch, count: count).layout
                    for (index, box) in layout.enumerated() {
                        XCTAssertGreaterThanOrEqual(box.y, span.top - 0.001,
                                                    "\(content): slot \(index) above the frozen span")
                        XCTAssertLessThanOrEqual(box.y + box.height, span.bottom + 0.001,
                                                 "\(content): slot \(index) below the frozen span")
                    }
                }
                anchor += 4
            }
        }
    }

    /// DECK-7: the drawn letter under the pointer is the fisheye's centre, so it
    /// is also the one the tag names and a click picks.
    func testTheDrawnLetterIsTheFisheyeCentreAtEveryPointerY() {
        for content in [content625, contentMinimum, 848] {
            let (count, pitch) = fit(content)
            let total = CGFloat(count) * pitch
            let railSlots = slots(count)
            for anchor in [12.5 * pitch, 0] {
                let frozenSpan = RailLayout.span(count: count, pitch: pitch, anchor: anchor)
                var y = frozenSpan.top
                while y < frozenSpan.bottom {
                    let (layout, scales) = drawn(at: y, from: anchor, pitch: pitch, count: count)
                    guard let drawnSlot = RailLayout.slotIndex(atY: y, in: layout) else {
                        XCTFail("no slot at y \(y)"); return
                    }
                    XCTAssertEqual(scales[drawnSlot], scales.max() ?? 0, accuracy: 0.0001,
                                   "\(content): the slot under \(y) is the fisheye's centre")
                    let box = layout[drawnSlot]
                    let within = min(max((y - box.y) / box.height, 0), 0.999_999)
                    let band = min(railSlots[drawnSlot].count - 1,
                                   max(0, Int(within * CGFloat(railSlots[drawnSlot].count))))
                    XCTAssertEqual(RailLayout.letter(atY: y, in: layout, slots: railSlots),
                                   DeckRail.letters[railSlots[drawnSlot].first + band],
                                   "\(content): the tag and the click name the drawn letter")
                    y += 1
                }
            }
        }
    }

    /// DECK-7: no slot edge moves more than 2 pt per 0.5 pt of pointer travel.
    func testNoSlotEdgeJumpsAsThePointerMovesDown() {
        for content in [content625, contentMinimum, 848] {
            let (count, pitch) = fit(content)
            let total = CGFloat(count) * pitch
            for anchor in [12.5 * pitch, total - 0.5] {
                let span = RailLayout.span(count: count, pitch: pitch, anchor: anchor)
                var previous: [CGFloat]?
                var y = span.top
                while y <= span.bottom {
                    let current = edges(drawn(at: y, from: anchor, pitch: pitch, count: count).layout)
                    if let previous {
                        let step = zip(previous, current).map { abs($0 - $1) }.max() ?? 0
                        XCTAssertLessThanOrEqual(step, 2, "\(content): a slot edge jumped \(step) pt at y \(y)")
                    }
                    previous = current
                    y += 0.5
                }
            }
        }
    }

    // MARK: The frozen span

    /// K2: enter at M, A, C, Y and #, then sweep the pointer: A's top and #'s
    /// bottom stay exactly where they were on enter (±0.01 pt).
    func testTheFrozenSpanKeepsTheEndsFixed() {
        let (count, pitch) = fit(content625)
        let total = CGFloat(count) * pitch
        for enterIndex in [12, 0, 2, 24, 26] {
            let anchor = (CGFloat(enterIndex) + 0.5) * pitch
            let span = RailLayout.span(count: count, pitch: pitch, anchor: anchor)
            let first = drawn(at: anchor, from: anchor, pitch: pitch, count: count).layout
            let top = first[0].y
            let bottom = first[count - 1].y + first[count - 1].height
            XCTAssertEqual(top, span.top, accuracy: 0.01)
            XCTAssertEqual(bottom, span.bottom, accuracy: 0.01)
            var y: CGFloat = 0
            while y <= total {
                let layout = drawn(at: y, from: anchor, pitch: pitch, count: count).layout
                XCTAssertEqual(layout[0].y, top, accuracy: 0.01,
                               "A's top moved at y \(y), entered at index \(enterIndex)")
                XCTAssertEqual(layout[count - 1].y + layout[count - 1].height, bottom, accuracy: 0.01,
                               "# 's bottom moved at y \(y), entered at index \(enterIndex)")
                y += 1
            }
        }
    }

    /// K2: entering does not jump. At the entry y the frozen span draws exactly
    /// the layout the rail drew before the enter (±0.01 pt).
    func testTheFrozenLayoutEqualsTheEnterLayout() {
        let (count, pitch) = fit(content625)
        for enterIndex in [12, 0, 2, 24, 26] {
            let anchor = (CGFloat(enterIndex) + 0.5) * pitch
            let frozen = drawn(at: anchor, from: anchor, pitch: pitch, count: count).layout
            let open = RailLayout.slots(
                scales: RailLayout.scales(count: count, centre: anchor / pitch, reduceMotion: false),
                pitch: pitch, anchor: anchor)
            XCTAssertEqual(frozen.count, open.count)
            for index in 0..<count {
                XCTAssertEqual(frozen[index].y, open[index].y, accuracy: 0.01,
                               "slot \(index) differs on enter at index \(enterIndex)")
                XCTAssertEqual(frozen[index].height, open[index].height, accuracy: 0.01)
            }
        }
    }

    /// K2: every gap inside the frozen span is equal to every other, and equal
    /// to the rest gap at the entry y.
    func testTheFrozenGapsAreEqual() {
        let (count, pitch) = fit(content625)
        let restGap = pitch - RailLayout.letterBox
        for enterIndex in [12, 0] {
            let anchor = (CGFloat(enterIndex) + 0.5) * pitch
            let span = RailLayout.span(count: count, pitch: pitch, anchor: anchor)
            let entered = drawn(at: anchor, from: anchor, pitch: pitch, count: count)
            XCTAssertEqual(RailLayout.frozenGap(scales: entered.scales, span: span), restGap,
                           accuracy: 0.01, "the gap on enter is not the rest gap")
            var y = span.top
            while y <= span.bottom {
                let (layout, scales) = drawn(at: y, from: anchor, pitch: pitch, count: count)
                var previous: CGFloat?
                for index in 0..<count {
                    let gap = layout[index].height - RailLayout.letterBox * scales[index]
                    XCTAssertLessThanOrEqual(abs(gap - restGap), 1,
                                             "the gap at \(y) moved \(gap - restGap) pt from rest")
                    if let previous {
                        XCTAssertEqual(gap, previous, accuracy: 0.01,
                                       "gaps differ at index \(index), y \(y)")
                    }
                    previous = gap
                }
                y += 2
            }
        }
    }

    /// K2: Y(u) strictly increases over [0, count], and the bisection inverts it
    /// to 0.01 pt.
    func testTheCentreMappingIsStrictlyIncreasing() {
        let (count, pitch) = fit(content625)
        let span = RailLayout.span(count: count, pitch: pitch, anchor: 12.5 * pitch)
        var previous = RailLayout.frozenCentreY(0, span: span, count: count)
        for step in 1...count * 100 {
            let u = CGFloat(step) / 100
            let y = RailLayout.frozenCentreY(u, span: span, count: count)
            XCTAssertGreaterThan(y, previous, "Y(u) does not increase at u \(u)")
            previous = y
            let solved = RailLayout.frozenCentre(atY: y, span: span, count: count)
            XCTAssertEqual(RailLayout.frozenCentreY(solved, span: span, count: count), y,
                           accuracy: 0.01, "Y(u) = \(y) does not invert at u \(u)")
        }
    }

    // MARK: The rest layout

    func testTheRestScalesGiveUniformRowsAtTheDrawnPitch() {
        let pitch: CGFloat = 19.7
        for (index, slot) in rest(27, pitch: pitch).enumerated() {
            XCTAssertEqual(slot.y, CGFloat(index) * pitch, accuracy: 0.001)
            XCTAssertEqual(slot.height, pitch, accuracy: 0.001)
        }
    }

    /// The boxes are `letterBox x scale` and the gaps never grow: the growth
    /// above the pointer pushes the top end up, the one below the bottom down.
    func testTheMagnifiedBoxesKeepTheirGapsAndExtendTheEnds() {
        let pitch: CGFloat = 19.7
        let total = 27 * pitch
        let gap = pitch - RailLayout.letterBox
        let anchor = 13.5 * pitch
        let scales = RailLayout.scales(count: 27, centre: anchor / pitch, reduceMotion: false)
        let layout = RailLayout.slots(scales: scales, pitch: pitch, anchor: anchor)
        XCTAssertLessThan(layout[0].y, -1, "the top end grows up")
        XCTAssertGreaterThan(layout[26].y + layout[26].height, total + 1, "the bottom end grows down")
        for index in 0..<26 {
            let boxBottom = layout[index].y + RailLayout.letterBox * scales[index]
            XCTAssertEqual(layout[index + 1].y - boxBottom, gap, accuracy: 0.01,
                           "the gap after slot \(index) stays \(gap) pt")
        }
    }

    func testHitTestingSplitsACondensedSlotTheSameWay() {
        let railSlots = DeckRail.slots(forHeight: DeckRail.compactTwoHeight) ?? []
        XCTAssertEqual(railSlots.count, 14)
        let pitch = RailLayout.maximumPitch
        let layout = rest(14, pitch: pitch)
        XCTAssertEqual(RailLayout.letter(atY: layout[0].y + 1, in: layout, slots: railSlots), "A")
        XCTAssertEqual(RailLayout.letter(atY: layout[0].y + pitch - 1, in: layout, slots: railSlots), "B")
        XCTAssertEqual(RailLayout.letter(atY: layout[3].y + 1, in: layout, slots: railSlots), "G")
    }
}
