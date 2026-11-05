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

    private func drops(_ actions: [Action]) -> Int {
        actions.filter { $0 == .dropOldest }.count
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

        let arrival = machine.handle(.arrive(1))
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.waiting, [1])
        XCTAssertTrue(startsLink(arrival))
        XCTAssertTrue(shown(arrival).isEmpty, "not shown on arrival")

        let tick = machine.handle(.tick)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(shown(tick), [1])
        XCTAssertTrue(machine.waiting.isEmpty)
    }

    func testABurstOfThreeSpreadsOverThreeTicksWithOneDropAtMost() {
        var machine = Machine()
        let first = machine.handle(.arrive(1))
        _ = machine.handle(.arrive(2))
        let third = machine.handle(.arrive(3))
        XCTAssertEqual(drops(first) + drops(third), 1, "the oldest waiting sample is the one drop")
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.waiting, [2, 3], "at most two wait")

        XCTAssertEqual(shown(machine.handle(.tick)), [2])
        XCTAssertEqual(shown(machine.handle(.tick)), [3])
        XCTAssertTrue(shown(machine.handle(.tick)).isEmpty, "the burst is spent")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.waiting.count, 0)
    }

    func testAGapShowsNothingAndDoesNoWork() {
        var machine = Machine()
        XCTAssertTrue(machine.handle(.tick).isEmpty)
        XCTAssertEqual(machine.phase, .idle)

        _ = machine.handle(.arrive(1))
        _ = machine.handle(.tick)
        // The next refresh has nothing waiting: no sample, no action.
        XCTAssertTrue(machine.handle(.tick).isEmpty)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testAPauseStopsTheLinkAndDropsTheWaiters() {
        var machine = Machine()
        _ = machine.handle(.arrive(1))
        _ = machine.handle(.arrive(2))
        XCTAssertEqual(machine.phase, .waiting)

        let paused = machine.handle(.pause)
        XCTAssertTrue(stopsLink(paused))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.waiting.isEmpty)
        XCTAssertTrue(machine.handle(.tick).isEmpty, "no picture after a pause")
    }

    func testACloseStopsTheLink() {
        var machine = Machine()
        _ = machine.handle(.arrive(1))
        let closed = machine.handle(.close)
        XCTAssertTrue(stopsLink(closed))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.waiting.isEmpty)
    }

    func testAFlushDropsTheWaitersAndKeepsTheLink() {
        var machine = Machine()
        _ = machine.handle(.arrive(1))
        let flushed = machine.handle(.flush)
        XCTAssertTrue(flushed.isEmpty, "the caller flushes the layer; the machine just forgets")
        XCTAssertFalse(stopsLink(flushed), "a flush is not a pause: the link stays up")
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertTrue(machine.waiting.isEmpty)

        // The next arrival starts the link again if it is not running; the
        // view's start is idempotent.
        let next = machine.handle(.arrive(2))
        XCTAssertTrue(startsLink(next))
        XCTAssertEqual(machine.waiting, [2])
    }

    func testAnArrivalWhilePresentingWaitsForTheNextTick() {
        var machine = Machine()
        _ = machine.handle(.arrive(1))
        _ = machine.handle(.arrive(2))
        _ = machine.handle(.tick) // shows 1, one still waits
        XCTAssertEqual(machine.phase, .presenting)

        _ = machine.handle(.arrive(3))
        XCTAssertEqual(machine.phase, .waiting)
        XCTAssertEqual(machine.waiting, [2, 3])
        XCTAssertEqual(shown(machine.handle(.tick)), [2])
    }
}
