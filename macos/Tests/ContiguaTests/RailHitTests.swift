// DECK-34: the rail takes the pointer only in the letters' column widened by
// at most 4 pt each side. The rail's frame is wider than its letters, so the
// strip right of the letters must belong to the grid, not the rail; the gaps
// between letters and 4 pt above and below them belong to the nearest letter.

import XCTest
@testable import Contigua

final class RailHitTests: XCTestCase {
    func testTheHitColumnIsTheLettersColumnPlusAtMostFourPoints() {
        let letters = RailHit.letters()
        XCTAssertEqual(letters.lowerBound, 7.5, accuracy: 0.001,
                       "the 11 pt letter box centred in the 26 pt rail")
        XCTAssertEqual(letters.upperBound, 18.5, accuracy: 0.001)
        XCTAssertEqual(RailHit.sidePadding, 4, "the brief's one horizontal margin")
        let column = RailHit.column()
        XCTAssertEqual(column.lowerBound, letters.lowerBound - RailHit.sidePadding, accuracy: 0.001)
        XCTAssertEqual(column.upperBound, letters.upperBound + RailHit.sidePadding, accuracy: 0.001)
        XCTAssertFalse(column.contains(letters.upperBound + 6),
                       "the strip right of the letters is not the rail's")
        XCTAssertTrue(column.contains(13), "the glyph's centre is the rail's")
    }

    func testTheMagnifiedHitAreaAlsoTakesTheArcsRoom() {
        let column = RailHit.column(magnified: 14)
        XCTAssertEqual(column.lowerBound,
                       RailHit.letters().lowerBound - RailHit.sidePadding - 14,
                       accuracy: 0.001, "the magnified letter reaches left")
        XCTAssertEqual(column.upperBound,
                       RailHit.letters().upperBound + RailHit.sidePadding,
                       accuracy: 0.001, "the right edge never grows")
    }

    func testTheVerticalBandsBelongToTheNearestLetterAndTheCrownsAreFourPoints() {
        let pitch: CGFloat = 20
        let count = 27
        let span = RailHit.vertical(count: count, pitch: pitch)
        let lettersTop = (pitch - RailLayout.letterBox) / 2
        let lettersBottom = CGFloat(count) * pitch - lettersTop
        XCTAssertEqual(span.lowerBound, lettersTop - RailHit.sidePadding, accuracy: 0.001)
        XCTAssertEqual(span.upperBound, lettersBottom + RailHit.sidePadding, accuracy: 0.001)
        XCTAssertTrue(span.contains(lettersTop + RailLayout.letterBox + 1),
                      "the gap between two letters is the nearest letter's")
        XCTAssertFalse(span.contains(lettersTop - RailHit.sidePadding - 1),
                       "above the first letter is dead beyond 4 pt")
        XCTAssertFalse(span.contains(lettersBottom + RailHit.sidePadding + 1),
                       "below the last letter is dead beyond 4 pt")
        let frozen = RailLayout.Span(top: -5, length: 550)
        XCTAssertEqual(RailHit.vertical(count: count, pitch: pitch, span: frozen),
                       frozen.top...frozen.bottom, "the frozen span's own ends while magnified")
    }

    func testContainsUsesBothBands() {
        XCTAssertTrue(RailHit.contains(x: 13, y: 100, railWidth: 26, count: 27,
                                       pitch: 20, magnified: 0))
        XCTAssertFalse(RailHit.contains(x: 24, y: 100, railWidth: 26, count: 27,
                                        pitch: 20, magnified: 0),
                       "right of the letters")
        XCTAssertFalse(RailHit.contains(x: 13, y: 0.2, railWidth: 26, count: 27,
                                        pitch: 20, magnified: 0),
                       "above the first letter")
    }
}
