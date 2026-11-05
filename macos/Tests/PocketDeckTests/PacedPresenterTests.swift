// M1's paced presenter (ISS-40), as a pure state machine driven by fake ticks.

import XCTest
@testable import PocketDeck

final class PacedPresenterTests: XCTestCase {
    private typealias Machine = PacedPresenter<Int>
    private typealias Action = PacedPresenter<Int>.Action

    private func shown(_ actions: [Action]) -> [Int] {
        actions.compactMap {
            if case .show(let sample) = $0 { return sample }
            return nil
        }
    }

    /// Frames handed over without their own refresh (a catch-up). Never a
    /// decode drop: every encoded frame reaches the layer, so the chain holds.
    private func caughtUp(_ actions: [Action]) -> Int {
        actions.reduce(0) { total, action in
            if case .caughtUp(let skipped) = action { return total + skipped }
            return total
        }
    }

    private func startsLink(_ actions: [Action]) -> Bool {
        actions.contains(.startLink)
    }

    private func stopsLink(_ actions: [Action]) -> Bool {
        actions.contains(.stopLink)
    }

    func testAnEvenArrivalIsShownOneTickLater() {
        var machine = Machine()
        XCTAssertEqual(machine.phase, .idle)

        let arrival = machine.handle(.arrive(1, isKeyframe: false))
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.waitingSamples, [1])
        XCTAssertTrue(startsLink(arrival))
        XCTAssertTrue(shown(arrival).isEmpty, "not shown on arrival")

        let tick = machine.handle(.tick)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(shown(tick), [1])
        XCTAssertTrue(machine.waitingSamples.isEmpty)
    }

    /// The samples are encoded frames: dropping one would break the reference
    /// chain until a keyframe (a request, a big frame, more pressure). A backlog
    /// the refresh can't clear is handed over at once, in order; the layer
    /// decodes them all and the newest is what the next refresh shows.
    func testABacklogIsHandedOverAtOnceInOrderAndNothingIsDropped() {
        var machine = Machine()
        let first = machine.handle(.arrive(1, isKeyframe: false))
        let second = machine.handle(.arrive(2, isKeyframe: false))
        XCTAssertTrue(shown(first + second).isEmpty, "two may wait for their refresh")
        let third = machine.handle(.arrive(3, isKeyframe: false))
        XCTAssertEqual(shown(third), [1, 2, 3], "every frame reaches the layer, in order")
        XCTAssertEqual(caughtUp(third), 2, "two were shown without their own refresh")
        XCTAssertTrue(machine.waitingSamples.isEmpty)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(shown(machine.handle(.tick)).isEmpty, "the backlog is spent")
    }

    func testAKeyframeAndItsDeltasAllReachTheLayerOnABacklog() {
        var machine = Machine()
        _ = machine.handle(.arrive(1, isKeyframe: true))
        _ = machine.handle(.arrive(2, isKeyframe: false))
        let third = machine.handle(.arrive(3, isKeyframe: false))
        XCTAssertEqual(shown(third), [1, 2, 3], "no delta after the keyframe is lost")
    }

    func testAnEvenStreamNeverCatchesUp() {
        var machine = Machine()
        var total = 0
        for sample in 1...120 {
            total += caughtUp(machine.handle(.arrive(sample, isKeyframe: sample == 1)))
            XCTAssertEqual(shown(machine.handle(.tick)), [sample])
        }
        XCTAssertEqual(total, 0, "one arrival per refresh is shown one refresh later, every time")
    }

    func testAGapShowsNothingAndDoesNoWork() {
        var machine = Machine()
        XCTAssertTrue(machine.handle(.tick).isEmpty)
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.handle(.arrive(1, isKeyframe: false))
        _ = machine.handle(.tick)
        // The next refresh has nothing waiting: no sample, no action.
        XCTAssertTrue(machine.handle(.tick).isEmpty)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testAPauseStopsTheLinkAndDropsTheWaiters() {
        var machine = Machine()
        _ = machine.handle(.arrive(1, isKeyframe: false))
        _ = machine.handle(.arrive(2, isKeyframe: false))
        XCTAssertEqual(machine.phase, .waiting)

        let paused = machine.handle(.pause)
        XCTAssertTrue(stopsLink(paused))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.waitingSamples.isEmpty)
        XCTAssertTrue(machine.handle(.tick).isEmpty, "no picture after a pause")
    }

    func testACloseStopsTheLink() {
        var machine = Machine()
        _ = machine.handle(.arrive(1, isKeyframe: false))
        let closed = machine.handle(.close)
        XCTAssertTrue(stopsLink(closed))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.waitingSamples.isEmpty)
    }

    func testAFlushDropsTheWaitersAndKeepsTheLink() {
        var machine = Machine()
        _ = machine.handle(.arrive(1, isKeyframe: false))
        let flushed = machine.handle(.flush)
        XCTAssertTrue(flushed.isEmpty, "the caller flushes the layer; the machine just forgets")
        XCTAssertFalse(stopsLink(flushed), "a flush is not a pause: the link stays up")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.waitingSamples.isEmpty)

        // The next arrival starts the link again if it is not running; the
        // view's start is idempotent.
        let next = machine.handle(.arrive(2, isKeyframe: false))
        XCTAssertTrue(startsLink(next))
        XCTAssertEqual(machine.waitingSamples, [2])
    }

    func testAnArrivalWhilePresentingWaitsForTheNextTick() {
        var machine = Machine()
        _ = machine.handle(.arrive(1, isKeyframe: false))
        _ = machine.handle(.arrive(2, isKeyframe: false))
        _ = machine.handle(.tick) // shows 1, one still waits
        XCTAssertEqual(machine.phase, .presenting)

        _ = machine.handle(.arrive(3, isKeyframe: false))
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.waitingSamples, [2, 3])
        XCTAssertEqual(shown(machine.handle(.tick)), [2])
    }
}
