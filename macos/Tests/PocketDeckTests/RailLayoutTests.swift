// The rail's spacing (DECK-7): proportional slots with the rail's height fixed
// (S2), the rest pitch giving way so the magnified overshoot fits, the drawn
// letter under the pointer being the fisheye's centre, nothing clipped at any
// window height, and no slot edge jumping.

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

    private func scales(_ y: CGFloat, pitch: CGFloat, count: Int, dx: CGFloat = 0) -> [CGFloat] {
        (0..<count).map {
            RailFisheye.scale(distance: y / pitch - (CGFloat($0) + 0.5),
                              dx: dx, zone: RailApproach.zone, reduceMotion: false)
        }
    }

    private func layout(_ y: CGFloat, pitch: CGFloat, count: Int, dx: CGFloat = 0) -> [RailLayout.Slot] {
        RailLayout.slots(scales: scales(y, pitch: pitch, count: count, dx: dx),
                         available: CGFloat(count) * pitch, pitch: pitch, anchor: y)
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
            XCTAssertLessThanOrEqual(27 * p + 2 * RailLayout.overshoot(count: 27, pitch: p),
                                     content + 0.001, "the pitch must leave room for the overshoot at \(content)")
            if p < 20 {
                XCTAssertGreaterThan(27 * (p + 0.5) + 2 * RailLayout.overshoot(count: 27, pitch: p + 0.5),
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

    /// DECK-7: no glyph is ever clipped, at any pointer y, at any window height
    /// from the minimum to 900 pt.
    func testNothingIsClippedAtAnyPointerYOrWindowHeight() {
        for content in stride(from: contentMinimum, through: 848, by: 5) {
            let (count, pitch) = fit(content)
            let total = CGFloat(count) * pitch
            let slack = (content - total) / 2
            XCTAssertGreaterThanOrEqual(slack, 0, "the rail fits its content at \(content)")
            var y: CGFloat = 0
            while y <= total {
                let layout = layout(y, pitch: pitch, count: count)
                for (index, box) in layout.enumerated() {
                    let glyph = 9 * RailFisheye.scale(distance: y / pitch - (CGFloat(index) + 0.5),
                                                     dx: 0, zone: RailApproach.zone, reduceMotion: false)
                    let top = box.y + (box.height - glyph) / 2
                    XCTAssertGreaterThanOrEqual(top, -slack - 0.001,
                                                "\(count) slots at \(content): glyph \(index) above the clip at y \(y)")
                    XCTAssertLessThanOrEqual(top + glyph, total + slack + 0.001,
                                             "\(count) slots at \(content): glyph \(index) below the clip at y \(y)")
                }
                y += 0.5
            }
        }
    }

    /// DECK-7: the drawn letter under the pointer is the fisheye's centre, so it
    /// is also the one the tag names and a click picks.
    func testTheDrawnLetterIsTheFisheyeCentreAtEveryPointerY() {
        for content in [content625, contentMinimum, 848] {
            let (count, pitch) = fit(content)
            let total = CGFloat(count) * pitch
            let slots = slots(count)
            for dx in [CGFloat(64), 24, 0] {
                var y: CGFloat = 0
                while y < total {
                    let s = scales(y, pitch: pitch, count: count, dx: dx)
                    let layout = RailLayout.slots(scales: s, available: total, pitch: pitch, anchor: y)
                    guard let drawn = RailLayout.slotIndex(atY: y, in: layout) else {
                        XCTFail("no slot at y \(y)"); return
                    }
                    let anchor = min(count - 1, Int(y / pitch))
                    XCTAssertEqual(drawn, anchor, "\(content) dx \(dx): the pointer at \(y) is in its own slot")
                    XCTAssertEqual(s[drawn], s.max() ?? 0, accuracy: 0.0001,
                                   "\(content) dx \(dx): the slot under the pointer is the fisheye's centre")
                    let box = layout[drawn]
                    let within = min(max((y - box.y) / box.height, 0), 0.999_999)
                    let band = min(slots[drawn].count - 1, max(0, Int(within * CGFloat(slots[drawn].count))))
                    XCTAssertEqual(RailLayout.letter(atY: y, in: layout, slots: slots),
                                   DeckRail.letters[slots[drawn].first + band],
                                   "\(content) dx \(dx): the tag and the click name the drawn letter")
                    y += 0.5
                }
            }
        }
    }

    /// DECK-7: no slot edge moves more than 2 pt per 0.5 pt of pointer travel.
    func testNoSlotEdgeJumpsAsThePointerMovesDown() {
        for content in [content625, contentMinimum, 848] {
            let (count, pitch) = fit(content)
            let total = CGFloat(count) * pitch
            var previous: [CGFloat]?
            var y: CGFloat = 0
            while y <= total {
                let current = edges(layout(y, pitch: pitch, count: count))
                if let previous {
                    let step = zip(previous, current).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertLessThanOrEqual(step, 2, "\(content): a slot edge jumped \(step) pt at y \(y)")
                }
                previous = current
                y += 0.5
            }
        }
    }

    /// DECK-7: and no edge moves more than 2 pt per 1 pt of approach closing at M.
    func testNoSlotEdgeJumpsAsTheApproachCloses() {
        for content in [content625, contentMinimum, 848] {
            let (count, pitch) = fit(content)
            let total = CGFloat(count) * pitch
            let slots = slots(count)
            let m = slots.firstIndex { $0.first <= 12 && 12 < $0.first + $0.count } ?? 0
            let y = CGFloat(m) * pitch + pitch / 2
            var previous: [CGFloat]?
            for dx in stride(from: CGFloat(64), through: 0, by: -1) {
                let current = edges(layout(y, pitch: pitch, count: count, dx: dx))
                if let previous {
                    let step = zip(previous, current).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertLessThanOrEqual(step, 2, "\(content): a slot edge jumped \(step) pt at dx \(dx)")
                }
                previous = current
            }
        }
    }

    // MARK: S2 itself

    func testTheSlotsAreProportionalAndFillTheRail() {
        let (count, pitch) = fit(content625)
        let layout = layout(246, pitch: pitch, count: count)
        XCTAssertEqual(layout.map(\.height).reduce(0, +), CGFloat(count) * pitch, accuracy: 0.001)
        for (index, slot) in layout.enumerated() {
            XCTAssertEqual(slot.height / scales(246, pitch: pitch, count: count)[index],
                           CGFloat(count) * pitch / scales(246, pitch: pitch, count: count).reduce(0, +),
                           accuracy: 0.001, "slot \(index) is proportional to its scale")
        }
        XCTAssertLessThan(layout[0].height, pitch, "the far letters pay")
        XCTAssertGreaterThan(layout[12].height, pitch, "the letter under the pointer grows")
    }

    func testTheRestScalesGiveUniformRowsAtTheDrawnPitch() {
        let pitch: CGFloat = 19.7
        let rest = RailLayout.slots(scales: Array(repeating: 1, count: 27),
                                    available: 27 * pitch, pitch: pitch, anchor: nil)
        for (index, slot) in rest.enumerated() {
            XCTAssertEqual(slot.y, CGFloat(index) * pitch, accuracy: 0.001)
            XCTAssertEqual(slot.height, pitch, accuracy: 0.001)
        }
    }

    func testTheFarLettersPayForTheMagnifiedOne() {
        let (count, pitch) = fit(content625)
        let y: CGFloat = 12.5 * pitch
        let rest = RailLayout.slots(scales: Array(repeating: 1, count: count),
                                    available: CGFloat(count) * pitch, pitch: pitch, anchor: y)
        let lens = layout(y, pitch: pitch, count: count)
        let restAbove = rest[12].y - (rest[0].y + rest[0].height)
        let lensAbove = lens[12].y - (lens[0].y + lens[0].height)
        XCTAssertLessThan(lensAbove, restAbove)
        let restBelow = rest[26].y - (rest[12].y + rest[12].height)
        let lensBelow = lens[26].y - (lens[12].y + lens[12].height)
        XCTAssertLessThan(lensBelow, restBelow)
    }

    func testHitTestingSplitsACondensedSlotTheSameWay() {
        let slots = DeckRail.slots(forHeight: DeckRail.compactTwoHeight) ?? []
        XCTAssertEqual(slots.count, 14)
        let pitch = RailLayout.maximumPitch
        let layout = RailLayout.slots(scales: Array(repeating: 1, count: 14),
                                      available: DeckRail.compactTwoHeight, pitch: pitch, anchor: nil)
        XCTAssertEqual(RailLayout.letter(atY: layout[0].y + 1, in: layout, slots: slots), "A")
        XCTAssertEqual(RailLayout.letter(atY: layout[0].y + pitch - 1, in: layout, slots: slots), "B")
        XCTAssertEqual(RailLayout.letter(atY: layout[3].y + 1, in: layout, slots: slots), "G")
    }
}
