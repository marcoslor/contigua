// The rail's emphasis (DECK-32): the button's press, drag, release and click
// linger, with the one transition function's durations; hover alone lights
// nothing, an empty letter forwards to the letter its jump lands on, the
// sections never take it, and Reduce Motion takes neither a scale nor an
// animation (the linger still applies). Every transition is tested here,
// ignored events included.

import XCTest
@testable import Contigua

@MainActor
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

    /// DECK-32: hover is not a state and not an event. A drag or a release
    /// without a press (the container's hover crossing the rail) lights
    /// nothing.
    func testHoverAloneLightsNothing() {
        for event in [RailEmphasis.Event.drag(pointer: "C", landed: "C", at: 10),
                      .release(at: 10),
                      .expire(at: 10),
                      .end] {
            let (state, actions) = reduce(.none, event)
            XCTAssertEqual(state, .none, "\(event) lit the grid")
            XCTAssertTrue(actions.isEmpty)
        }
    }

    func testAPressLightsTheLetterAndEasesIn() {
        let (state, actions) = reduce(.none, .press(pointer: "C", landed: "C", at: 10))
        XCTAssertEqual(state, .pressed(letter: "C", pointer: "C", since: 10, moved: false))
        XCTAssertEqual(state.letter, "C")
        XCTAssertEqual(state.pointer, "C")
        XCTAssertEqual(actions, [.animateIn(duration: RailEmphasis.enterDuration)])
        XCTAssertEqual(RailEmphasis.enterDuration, 0.12)
        XCTAssertEqual(RailEmphasis.clickThreshold, 0.3)
        XCTAssertEqual(RailEmphasis.lingerDuration, 1.0)
    }

    func testASecondPressIsNotANewPress() {
        let first = RailEmphasis.pressed(letter: "C", pointer: "C", since: 10, moved: false)
        let (same, actions) = reduce(first, .press(pointer: "C", landed: "C", at: 11))
        XCTAssertEqual(same, first, "the press's clock and moved flag stay")
        XCTAssertTrue(actions.isEmpty)
        // Another letter cross-fades, still without restarting the clock.
        let (other, cross) = reduce(first, .press(pointer: "D", landed: "D", at: 11))
        XCTAssertEqual(other, .pressed(letter: "D", pointer: "D", since: 10, moved: true))
        XCTAssertEqual(cross, [.animateIn(duration: RailEmphasis.enterDuration)])
    }

    func testADragToAnotherLetterCrossFadesAndMarksMoved() {
        let pressed = RailEmphasis.pressed(letter: "C", pointer: "C", since: 10, moved: false)
        let (state, actions) = reduce(pressed, .drag(pointer: "D", landed: "D", at: 10.05))
        XCTAssertEqual(state, .pressed(letter: "D", pointer: "D", since: 10, moved: true),
                       "the letters cross-fade, never through rest, and the press stays")
        XCTAssertEqual(actions, [.animateIn(duration: RailEmphasis.enterDuration)])
        // Moving inside one letter changes nothing.
        let (same, none) = reduce(state, .drag(pointer: "D", landed: "D", at: 10.06))
        XCTAssertEqual(same, state)
        XCTAssertTrue(none.isEmpty)
    }

    /// An empty pointer (B) and its landing letter (C) share one lit letter;
    /// crossing to C is still a drag, so the release must not linger.
    func testADragToTheSameLandedLetterStillMarksMoved() {
        let pressed = RailEmphasis.pressed(letter: "C", pointer: "B", since: 10, moved: false)
        let (state, actions) = reduce(pressed, .drag(pointer: "C", landed: "C", at: 10.05))
        XCTAssertEqual(state, .pressed(letter: "C", pointer: "C", since: 10, moved: true))
        XCTAssertTrue(actions.isEmpty, "the lit letter did not change, so nothing fades")
        let (released, out) = reduce(state, .release(at: 10.1))
        XCTAssertEqual(released, .none, "a drag ends at once, even under 300 ms")
        XCTAssertEqual(out, [.animateOut(duration: RailEmphasis.leaveDuration)])
    }

    func testAClickLingersWithoutAnAnimation() {
        let pressed = RailEmphasis.pressed(letter: "C", pointer: "C", since: 10, moved: false)
        let (state, actions) = reduce(pressed, .release(at: 10.299))
        XCTAssertEqual(state, .lingering(letter: "C", until: 11.299))
        XCTAssertEqual(state.letter, "C")
        XCTAssertEqual(state.until, 11.299)
        XCTAssertTrue(actions.isEmpty, "the click's emphasis stays; nothing fades")
    }

    func testAHoldOf300msEndsAtOnce() {
        let pressed = RailEmphasis.pressed(letter: "C", pointer: "C", since: 10, moved: false)
        let (state, actions) = reduce(pressed, .release(at: 10.3))
        XCTAssertEqual(state, .none)
        XCTAssertEqual(actions, [.animateOut(duration: RailEmphasis.leaveDuration)])
        XCTAssertEqual(RailEmphasis.leaveDuration, 0.2)
    }

    func testTheLingerExpiresAtItsUntilOnly() {
        let lingering = RailEmphasis.lingering(letter: "C", until: 11)
        let (early, none) = reduce(lingering, .expire(at: 10.999))
        XCTAssertEqual(early, lingering)
        XCTAssertTrue(none.isEmpty)
        let (ended, actions) = reduce(lingering, .expire(at: 11))
        XCTAssertEqual(ended, .none)
        XCTAssertEqual(actions, [.animateOut(duration: RailEmphasis.leaveDuration)])
        // An expiry outside the linger is ignored.
        let (pressed, ignored) = reduce(
            .pressed(letter: "C", pointer: "C", since: 10, moved: false), .expire(at: 20))
        XCTAssertEqual(pressed, .pressed(letter: "C", pointer: "C", since: 10, moved: false))
        XCTAssertTrue(ignored.isEmpty)
    }

    func testANewPressDuringTheLingerReplacesItAndDiscardsTheClock() {
        let lingering = RailEmphasis.lingering(letter: "C", until: 11)
        let (state, actions) = reduce(lingering, .press(pointer: "D", landed: "D", at: 10.5))
        XCTAssertEqual(state, .pressed(letter: "D", pointer: "D", since: 10.5, moved: false))
        XCTAssertEqual(actions, [.animateIn(duration: RailEmphasis.enterDuration)])
        // The old linger's deadline no longer exists: the new press outlives it.
        let (still, ignored) = reduce(state, .expire(at: 11))
        XCTAssertEqual(still, state)
        XCTAssertTrue(ignored.isEmpty)
        // The same letter during its own linger is a fresh press too.
        let (same, cross) = reduce(.lingering(letter: "C", until: 11),
                                   .press(pointer: "C", landed: "C", at: 10.5))
        XCTAssertEqual(same, .pressed(letter: "C", pointer: "C", since: 10.5, moved: false))
        XCTAssertEqual(cross, [.animateIn(duration: RailEmphasis.enterDuration)])
    }

    func testEveryEarlyEndEndsAPressAndALinger() {
        for state in [RailEmphasis.pressed(letter: "C", pointer: "C", since: 10, moved: false),
                      .lingering(letter: "C", until: 11)] {
            let (ended, actions) = reduce(state, .end)
            XCTAssertEqual(ended, .none, "\(state) did not end")
            XCTAssertEqual(actions, [.animateOut(duration: RailEmphasis.leaveDuration)])
        }
        let (rest, none) = reduce(.none, .end)
        XCTAssertEqual(rest, .none)
        XCTAssertTrue(none.isEmpty)
    }

    func testReduceMotionTakesNoScaleOrAnimationButStillLingers() {
        let (entered, enterActions) = reduce(.none, .press(pointer: "C", landed: "C", at: 10),
                                             reduceMotion: true)
        XCTAssertEqual(entered, .pressed(letter: "C", pointer: "C", since: 10, moved: false))
        XCTAssertEqual(enterActions, [.animateIn(duration: 0)])
        let (next, moved) = reduce(entered, .drag(pointer: "D", landed: "D", at: 10.05),
                                   reduceMotion: true)
        XCTAssertEqual(next, .pressed(letter: "D", pointer: "D", since: 10, moved: true))
        XCTAssertEqual(moved, [.animateIn(duration: 0)])
        let (held, heldActions) = reduce(next, .release(at: 10.4), reduceMotion: true)
        XCTAssertEqual(held, .none)
        XCTAssertEqual(heldActions, [.animateOut(duration: 0)])
        // A click still lingers for its 1000 ms under Reduce Motion.
        let (clicked, clickActions) = reduce(entered, .release(at: 10.1), reduceMotion: true)
        XCTAssertEqual(clicked, .lingering(letter: "C", until: 11.1))
        XCTAssertTrue(clickActions.isEmpty)
        let (expired, exitActions) = reduce(clicked, .expire(at: 11.1), reduceMotion: true)
        XCTAssertEqual(expired, .none)
        XCTAssertEqual(exitActions, [.animateOut(duration: 0)])
    }

    // MARK: The model's one clock and timer

    func testTheModelOwnsTheClockAndTheLingerEndsOnIt() {
        let model = RailEmphasisModel()
        var now: TimeInterval = 100
        model.now = { now }
        model.press(pointer: "C", landed: "C", reduceMotion: false)
        XCTAssertEqual(model.state, .pressed(letter: "C", pointer: "C", since: 100, moved: false))
        now += 0.08
        model.release(reduceMotion: false)
        XCTAssertEqual(model.state, .lingering(letter: "C", until: 101.08))
        XCTAssertEqual(model.duration, RailEmphasis.enterDuration,
                       "a click's linger keeps the entry's duration; nothing fades")
        // The old clock cannot end a new press.
        model.press(pointer: "D", landed: "D", reduceMotion: false)
        now += 1.0
        model.expire()
        XCTAssertEqual(model.state, .pressed(letter: "D", pointer: "D", since: 100.08, moved: false),
                       "the press replaced the linger and discarded its clock")
        model.end(reduceMotion: false)
        XCTAssertEqual(model.state, .none)
        XCTAssertEqual(model.duration, RailEmphasis.leaveDuration)
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

    func testTheDimIsThirtyPercentAndTheLiftIsATransform() {
        XCTAssertEqual(DeckCellEmphasis.lift.opacity, 1)
        XCTAssertEqual(DeckCellEmphasis.lift.scale(reduceMotion: false), 1.08)
        XCTAssertEqual(DeckCellEmphasis.lift.scale(reduceMotion: true), 1,
                       "Reduce Motion draws no scale")
        XCTAssertEqual(DeckCellEmphasis.lift.labelWeight, .semibold)
        XCTAssertEqual(DeckCellEmphasis.dim.opacity, 0.3)
        XCTAssertEqual(DeckCellEmphasis.dim.scale(reduceMotion: false), 1)
        XCTAssertEqual(DeckCellEmphasis.dim.labelWeight, .regular)
        XCTAssertEqual(DeckCellEmphasis.rest.opacity, 1)
        XCTAssertEqual(DeckCellEmphasis.rest.scale(reduceMotion: false), 1)
    }
}
