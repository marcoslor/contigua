// DECK-7's accent: after a rail click or drag the rail lights the letter the
// jump landed on — the clicked letter, or the letter an empty click skips
// forward to — until the grid scrolls by other means; then the top row's
// letter is back. The machine's every event is tested here.

import XCTest
@testable import PocketDeck

final class RailAccentTests: XCTestCase {
    private func apps(_ labels: [String]) -> [AppInfo] {
        labels.enumerated().compactMap { index, label in
            AppInfo(json: ["pkg": "com.example.app\(index)", "label": label])
        }
    }

    private func scroll(_ top: Int, _ offset: CGFloat, columns: Int = 6,
                        maxOffset: CGFloat = 5000) -> RailAccent.Event {
        .scroll(top: top, offset: offset, columns: columns, maxOffset: maxOffset)
    }

    /// The person's report: a pick on I lights another letter. I's first app
    /// is mid-row and J starts in the same row, so the row's letter is J; the
    /// rail must light I.
    func testThePickLightsTheLandedLetterNotTheRowsLetter() {
        let list = apps(["Foxtrot 1", "Foxtrot 2", "Golf", "Harbor", "Invoices", "Journal",
                         "Kilo", "Lima", "Mike", "November", "Oscar", "Papa"])
        XCTAssertEqual(DeckRail.pick("I", in: list), DeckRail.Pick(letter: "I", index: 4))
        XCTAssertEqual(DeckRail.rowLetter(rowStart: 0, apps: list, columns: 6), "J",
                       "the row holding I's first app is lettered by its later section")

        let jumped = RailAccent.reduce(.topRow, .pick(letter: "I", target: 4, fromTop: 0))
        XCTAssertEqual(jumped, .jumping(letter: "I", target: 4, fromTop: 0))
        XCTAssertEqual(jumped.letter(topRow: "J"), "I", "the click lights I at once, not J")

        let landed = RailAccent.reduce(jumped, scroll(0, 40))
        XCTAssertEqual(landed, .picked(letter: "I", landingOffset: 40))
        XCTAssertEqual(landed.letter(topRow: "J"), "I")
    }

    /// The jump's own animated scroll walks the top row toward the target and
    /// must not count as the person's scroll: the pick stays lit until the
    /// target's row is the top one.
    func testTheJumpsOwnScrollKeepsThePick() {
        let list = apps((0..<72).map { "Alpha \($0)" })
        XCTAssertEqual(DeckRail.pick("A", in: list)?.index, 0)
        var state = RailAccent.reduce(.topRow, .pick(letter: "A", target: 30, fromTop: 0))
        // 30 is row 5 at six columns.
        for (top, offset) in [(0, CGFloat(0)), (6, 130), (12, 254), (24, 502), (30, 626)] {
            state = RailAccent.reduce(state, scroll(top, offset))
            XCTAssertEqual(state.letter(topRow: "A"), "A", "the jump's own scroll at top \(top)")
        }
        XCTAssertEqual(state, .picked(letter: "A", landingOffset: 626))
        XCTAssertEqual(RailAccent.reduce(state, scroll(30, 626.5)),
                       .picked(letter: "A", landingOffset: 626),
                       "the animation's last frames stay within the tolerance")
    }

    /// X, Y and Z sit in the grid's last screenful: the jump cannot bring their
    /// row to the top and lands at the grid's end. The picked letter stays lit,
    /// and the top row's letter is still something else.
    func testAPickInTheLastScreenfulKeepsThePickedLetter() {
        let labels = (0..<54).map { "Alphabet \($0)" } + ["Xylophone", "Yoga"]
        let list = apps(labels)
        XCTAssertEqual(DeckRail.pick("X", in: list), DeckRail.Pick(letter: "X", index: 54))
        XCTAssertEqual(DeckRail.rowLetter(rowStart: 54, apps: list, columns: 6), "Y",
                       "X shares its last row with Y")

        let jumped = RailAccent.reduce(.topRow, .pick(letter: "X", target: 54, fromTop: 0))
        var state = RailAccent.reduce(jumped, scroll(48, 900, maxOffset: 900))
        XCTAssertEqual(state, .picked(letter: "X", landingOffset: 900),
                       "the grid reached its end with X's row still below")
        XCTAssertEqual(state.letter(topRow: "W"), "X")

        state = RailAccent.reduce(state, scroll(48, 901, maxOffset: 900))
        XCTAssertEqual(state.letter(topRow: "W"), "X",
                       "the end's own last frame is not the person's scroll")
    }

    /// An empty letter skips forward: the accent is the letter it skipped to,
    /// not the empty one clicked.
    func testAnEmptyLetterPicksTheLetterItSkipsTo() {
        let list = apps(["Alpha 1", "Alpha 2", "Delta", "Echo", "Foxtrot", "Golf"])
        XCTAssertEqual(DeckRail.pick("C", in: list), DeckRail.Pick(letter: "D", index: 2))
        XCTAssertNil(DeckRail.pick("Z", in: list), "nothing after the last app to skip to")

        let state = RailAccent.reduce(.topRow, .pick(letter: "D", target: 2, fromTop: 0))
        XCTAssertEqual(state.letter(topRow: "A"), "D")
    }

    /// A scroll by other means (the wheel, the trackpad, the scroll bar, the
    /// keys) moves the grid off the landing: the top row's letter is back.
    func testAScrollByOtherMeansHandsTheAccentBackToTheTopRow() {
        let landed = RailAccent.reduce(.topRow, .pick(letter: "I", target: 30, fromTop: 0))
        let held = RailAccent.reduce(landed, scroll(30, 626))
        XCTAssertEqual(held.letter(topRow: "H"), "I")

        let scrolled = RailAccent.reduce(held, scroll(36, 750))
        XCTAssertEqual(scrolled, .topRow)
        XCTAssertEqual(scrolled.letter(topRow: "J"), "J")
        // A small move still counts: the person's scroll is any move off the
        // landing the jump left.
        XCTAssertEqual(RailAccent.reduce(held, scroll(30, 640)), .topRow)
    }

    /// A scroll while the accent is the top row's letter changes nothing, and
    /// another pick replaces the held one.
    func testAScrollAtRestKeepsTheRowAndANewPickReplacesTheOld() {
        XCTAssertEqual(RailAccent.reduce(.topRow, scroll(12, 200)), .topRow)
        XCTAssertEqual(RailAccent.reduce(.topRow, scroll(12, 200)).letter(topRow: "K"), "K")

        let held = RailAccent.reduce(.picked(letter: "I", landingOffset: 626), .pick(letter: "O", target: 97, fromTop: 6))
        XCTAssertEqual(held, .jumping(letter: "O", target: 97, fromTop: 6))
        XCTAssertEqual(held.letter(topRow: "N"), "O")
    }

    /// A grid that fits its viewport cannot scroll at all: any pick lands at
    /// offset 0 and stays lit. A zero end reported before the grid has a size
    /// is not a landing.
    func testAPickOnAShortGridSettlesAtOnce() {
        let state = RailAccent.reduce(.topRow, .pick(letter: "H", target: 2, fromTop: 0))
        let landed = RailAccent.reduce(state, scroll(0, 0, maxOffset: 0))
        XCTAssertEqual(landed, .picked(letter: "H", landingOffset: 0))
        XCTAssertEqual(landed.letter(topRow: "G"), "H")

        let jump = RailAccent.reduce(.topRow, .pick(letter: "X", target: 54, fromTop: 0))
        XCTAssertEqual(RailAccent.reduce(jump, scroll(0, 0, maxOffset: 0)), jump,
                       "a zero end before layout is not the grid's end")
    }

    /// A jump up from the grid's end must not take the end it starts on for
    /// its landing: the pick holds through the animation and settles at the
    /// top.
    func testAnUpwardJumpFromTheGridsEndKeepsThePick() {
        var state = RailAccent.reduce(.topRow, .pick(letter: "A", target: 0, fromTop: 48))
        XCTAssertEqual(state, .jumping(letter: "A", target: 0, fromTop: 48))
        state = RailAccent.reduce(state, scroll(48, 900, maxOffset: 900))
        XCTAssertEqual(state.letter(topRow: "X"), "A", "the bottom it starts on is not its landing")
        for top in [36, 24, 12] {
            state = RailAccent.reduce(state, scroll(top, CGFloat(top) * 13 + 40, maxOffset: 900))
            XCTAssertEqual(state.letter(topRow: "Q"), "A", "the jump's own scroll at top \(top)")
        }
        state = RailAccent.reduce(state, scroll(0, 40, maxOffset: 900))
        XCTAssertEqual(state, .picked(letter: "A", landingOffset: 40))
    }

    /// A scroll that leaves the jump's path while it runs is the person's, not
    /// the jump's: the top row's letter is back.
    func testAScrollOffTheJumpPathDropsThePick() {
        let down = RailAccent.reduce(.topRow, .pick(letter: "I", target: 30, fromTop: 12))
        // Above where the jump started.
        XCTAssertEqual(RailAccent.reduce(down, scroll(6, 160)), .topRow)
        // Past the target's row.
        XCTAssertEqual(RailAccent.reduce(down, scroll(36, 700)), .topRow)

        let up = RailAccent.reduce(.topRow, .pick(letter: "C", target: 12, fromTop: 30))
        XCTAssertEqual(RailAccent.reduce(up, scroll(36, 700)), .topRow, "below the start")
        XCTAssertEqual(RailAccent.reduce(up, scroll(6, 80)), .topRow, "above the target's row")
    }
}
