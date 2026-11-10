// The rail's emphasis (DECK-32): while the pointer rests on a letter, that
// letter's All Apps tiles lift and the rest dim, with the one transition
// function's durations; an empty letter forwards to the letter its jump lands
// on, the sections never take it, and Reduce Motion takes neither a scale nor
// an animation. Every transition is tested here, ignored events included.

import XCTest
@testable import PocketDeck

final class RailEmphasisTests: XCTestCase {
    private func apps(_ labels: [String]) -> [AppInfo] {
        labels.enumerated().compactMap { index, label in
            AppInfo(json: ["pkg": "com.example.app\(index)", "label": label])
        }
    }

    private func reduce(_ state: RailEmphasis, _ event: RailEmphasis.Event,
                        reduceMotion: Bool = false)
        -> (RailEmphasis, [RailEmphasis.Action]) {
        RailEmphasis.reduce(state, event: event, reduceMotion: reduceMotion)
    }

    // MARK: The machine

    func testEnteringTheRailLightsTheLetterAndEasesIn() {
        let (state, actions) = reduce(.none, .point("C"))
        XCTAssertEqual(state, .letter("C"))
        XCTAssertEqual(state.letter, "C")
        XCTAssertEqual(actions, [.animateIn(duration: RailEmphasis.enterDuration)])
        XCTAssertEqual(RailEmphasis.enterDuration, 0.12)
    }

    func testStayingInsideOneLetterChangesNothing() {
        let (state, actions) = reduce(.letter("C"), .point("C"))
        XCTAssertEqual(state, .letter("C"))
        XCTAssertTrue(actions.isEmpty, "a pointer moving inside one letter crosses no boundary")
    }

    func testAnotherLetterCrossFadesInWithoutPassingThroughRest() {
        let (state, actions) = reduce(.letter("C"), .point("D"))
        XCTAssertEqual(state, .letter("D"), "the state goes straight from one letter to the next")
        XCTAssertEqual(actions, [.animateIn(duration: RailEmphasis.enterDuration)],
                       "the new letter enters over the 0.12 s entry, never a flash of rest")
    }

    func testLeavingTheRailReturnsToRestOverTheExitDuration() {
        let (state, actions) = reduce(.letter("C"), .leave)
        XCTAssertEqual(state, .none)
        XCTAssertNil(state.letter)
        XCTAssertEqual(actions, [.animateOut(duration: RailEmphasis.leaveDuration)])
        XCTAssertEqual(RailEmphasis.leaveDuration, 0.2)
    }

    func testLeavingWhileAlreadyAtRestIsIgnored() {
        let (state, actions) = reduce(.none, .leave)
        XCTAssertEqual(state, .none)
        XCTAssertTrue(actions.isEmpty)
    }

    func testReduceMotionTakesNoScaleOrAnimation() {
        let (entered, enterActions) = reduce(.none, .point("C"), reduceMotion: true)
        XCTAssertEqual(entered, .letter("C"))
        XCTAssertEqual(enterActions, [.animateIn(duration: 0)])
        let (next, moved) = reduce(entered, .point("D"), reduceMotion: true)
        XCTAssertEqual(next, .letter("D"))
        XCTAssertEqual(moved, [.animateIn(duration: 0)])
        let (left, exitActions) = reduce(next, .leave, reduceMotion: true)
        XCTAssertEqual(left, .none)
        XCTAssertEqual(exitActions, [.animateOut(duration: 0)])
    }

    // MARK: The empty letter's landing

    func testAnEmptyLetterLightsTheLetterItsJumpLandsOn() {
        let entries = DeckRail.entries(for: apps(["Alpha", "Charlie", "Charlie 2", "Delta"]))
        XCTAssertEqual(DeckRail.landedLetter(for: "B", in: entries), "C",
                       "B has no apps: its jump skips forward to C")
        XCTAssertEqual(DeckRail.landedLetter(for: "C", in: entries), "C")
        XCTAssertEqual(DeckRail.landedLetter(for: "D", in: entries), "D")
    }

    func testAnEmptyTailLightsNothing() {
        let entries = DeckRail.entries(for: apps(["Alpha"]))
        XCTAssertNil(DeckRail.landedLetter(for: "B", in: entries),
                     "no letter from B on has an app, so there is no landing letter")
        XCTAssertEqual(DeckRail.landedLetter(for: "1Password", in: []), nil)
    }

    // MARK: What a tile draws

    func testTheLettersTilesLiftAndTheRestDim() {
        XCTAssertEqual(DeckCellEmphasis.tile(label: "Calculator", letter: "C", interactive: true),
                       .lift)
        XCTAssertEqual(DeckCellEmphasis.tile(label: "Maps", letter: "C", interactive: true),
                       .dim)
        XCTAssertEqual(DeckCellEmphasis.tile(label: "1Password", letter: "#", interactive: true),
                       .lift, "# is the rail's non-letter letter")
    }

    func testTheSectionsAndANonInteractivePageStayAtRest() {
        XCTAssertEqual(DeckCellEmphasis.tile(label: nil, letter: "C", interactive: true),
                       .rest, "Open on this Mac and Pinned never dim or lift")
        XCTAssertEqual(DeckCellEmphasis.tile(label: "Calculator", letter: "C", interactive: false),
                       .rest, "the offline page is dimmed as one, with no emphasis on top")
        XCTAssertEqual(DeckCellEmphasis.tile(label: "Calculator", letter: nil, interactive: true),
                       .rest, "no rail letter, no emphasis")
    }

    func testTheDimIsHalfAndTheLiftIsATransform() {
        XCTAssertEqual(DeckCellEmphasis.lift.opacity, 1)
        XCTAssertEqual(DeckCellEmphasis.lift.scale(reduceMotion: false), 1.08)
        XCTAssertEqual(DeckCellEmphasis.lift.scale(reduceMotion: true), 1,
                       "Reduce Motion draws no scale")
        XCTAssertEqual(DeckCellEmphasis.lift.labelWeight, .semibold)
        XCTAssertEqual(DeckCellEmphasis.dim.opacity, 0.5)
        XCTAssertEqual(DeckCellEmphasis.dim.scale(reduceMotion: false), 1)
        XCTAssertEqual(DeckCellEmphasis.dim.labelWeight, .regular)
        XCTAssertEqual(DeckCellEmphasis.rest.opacity, 1)
        XCTAssertEqual(DeckCellEmphasis.rest.scale(reduceMotion: false), 1)
    }
}
