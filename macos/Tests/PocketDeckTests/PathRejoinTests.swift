// The orphan's rejoin schedule (docs/design/paths.md §6, PATH-6/E-11c):
// inside the 30 s grace a failed rejoin is redialed on the next tick, with a
// 2.0 s connect timeout on the dial itself; outside the grace — a live session
// that is a path short — the reconnect backoff (1, 2, 4, 8, 15 s) is unchanged
// and a new session after the grace keeps the controller's own schedule.

import XCTest
@testable import PocketDeck

final class PathRejoinTests: XCTestCase {
    private func tick(needed: Bool = true, orphaned: Bool = true,
                      at now: TimeInterval) -> PathRejoinEvent {
        .tick(needed: needed, orphaned: orphaned, now: now)
    }

    func testAnOrphanedRejoinDialsOnTheTickAndIsNeverDoubled() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(at: 0), now: 0), [.dial])
        XCTAssertEqual(machine.state, .inFlight(failures: 0))
        for now in stride(from: 0.25, through: 2.0, by: 0.25) {
            XCTAssertEqual(machine.handle(tick(at: now), now: now), [.ignore])
        }
        XCTAssertEqual(machine.state, .inFlight(failures: 0))
    }

    func testAFailedOrphanedRejoinIsDialedAgainOnTheNextTick() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(at: 10), now: 10), [.dial])
        XCTAssertEqual(machine.handle(.failed(orphaned: true, now: 12), now: 12), [.ignore])
        // E-11c: no waiting step inside the grace.
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(tick(at: 12), now: 12), [.dial])
        XCTAssertEqual(machine.state, .inFlight(failures: 0))
    }

    func testTheOrphanedRetriesStayBackToBackThroughTheGrace() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(at: 0), now: 0), [.dial])
        for now in stride(from: 2.0, through: 28.0, by: 2.0) {
            XCTAssertEqual(machine.handle(.failed(orphaned: true, now: now), now: now), [.ignore])
            XCTAssertEqual(machine.state, .idle)
            XCTAssertEqual(machine.handle(tick(at: now), now: now), [.dial])
            XCTAssertEqual(machine.state, .inFlight(failures: 0))
        }
    }

    /// E-11c: the grace's back-to-back retry is the only change. A live
    /// session that is a path short keeps today's 1, 2, 4, 8, 15 s.
    func testOutsideTheGraceTheBackoffIsUnchanged() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(orphaned: false, at: 10), now: 10), [.dial])
        let steps: [(failures: Int, nextAt: TimeInterval)] = [
            (1, 11), (2, 13), (3, 17), (4, 25), (5, 40), (6, 55),
        ]
        var now: TimeInterval = 10
        for step in steps {
            XCTAssertEqual(machine.handle(.failed(orphaned: false, now: now), now: now),
                           [.ignore])
            XCTAssertEqual(machine.state,
                           .waiting(until: now + ReconnectPolicy.delay(afterFailures: step.failures),
                                    failures: step.failures))
            XCTAssertEqual(machine.handle(tick(orphaned: false, at: now + 0.01), now: now + 0.01),
                           [.ignore])
            now = step.nextAt
            XCTAssertEqual(machine.handle(tick(orphaned: false, at: now), now: now), [.dial])
        }
    }

    /// E-11c: the grace overrides a wait begun while the session was still
    /// live; the first orphaned dial must not wait out the backoff step.
    func testTheGraceOverridesAWaitBegunWhileLive() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(orphaned: false, at: 0), now: 0), [.dial])
        XCTAssertEqual(machine.handle(.failed(orphaned: false, now: 0), now: 0), [.ignore])
        XCTAssertEqual(machine.state, .waiting(until: 1, failures: 1))
        XCTAssertEqual(machine.handle(tick(orphaned: true, at: 0.25), now: 0.25), [.dial])
        XCTAssertEqual(machine.state, .inFlight(failures: 1))
    }

    func testNoDialWhileNothingIsMissing() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(needed: false, at: 0), now: 0), [.ignore])
        XCTAssertEqual(machine.state, .idle)
        // A tick with nothing to do does not cancel or restart a dial in
        // flight: the dial in flight is the one that may welcome.
        XCTAssertEqual(machine.handle(tick(at: 0.5), now: 0.5), [.dial])
        XCTAssertEqual(machine.handle(tick(needed: false, at: 1), now: 1), [.ignore])
        XCTAssertEqual(machine.state, .inFlight(failures: 0))
    }

    func testAWelcomeResetsTheBackoff() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(orphaned: false, at: 0), now: 0), [.dial])
        XCTAssertEqual(machine.handle(.failed(orphaned: false, now: 0), now: 0), [.ignore])
        XCTAssertEqual(machine.handle(.welcomed, now: 1), [.ignore])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(tick(orphaned: false, at: 2), now: 2), [.dial])
        XCTAssertEqual(machine.handle(.failed(orphaned: false, now: 2), now: 2), [.ignore])
        // The step restarts at 1 s rather than continuing the old 2 s.
        XCTAssertEqual(machine.state, .waiting(until: 3, failures: 1))
    }

    func testAStopReturnsToIdleAndIgnoresStrayFailures() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(at: 0), now: 0), [.dial])
        XCTAssertEqual(machine.handle(.stop, now: 0.5), [.ignore])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.failed(orphaned: false, now: 1), now: 1), [.ignore])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(tick(at: 2), now: 2), [.dial])
    }

    /// A phone whose server is down refuses at once: inside the grace the
    /// rounds still start a second apart, so 30 s costs at most 31 dials.
    func testARefusedOrphanedRejoinIsRedialedASecondAfterItsRoundBegan() {
        var machine = PathRejoinMachine()
        XCTAssertEqual(machine.handle(tick(at: 0), now: 0), [.dial])
        XCTAssertEqual(machine.handle(.failed(orphaned: true, now: 0.05), now: 0.05), [.ignore])
        XCTAssertEqual(machine.state, .spacing(until: 1.0))
        for now in [0.25, 0.5, 0.75] {
            XCTAssertEqual(machine.handle(tick(at: now), now: now), [.ignore])
        }
        XCTAssertEqual(machine.handle(tick(at: 1.0), now: 1.0), [.dial])
        var dials = 1
        var now: TimeInterval = 1.0
        while now < 30 {
            _ = machine.handle(.failed(orphaned: true, now: now + 0.05), now: now + 0.05)
            now += 0.25
            if machine.handle(tick(at: now), now: now) == [.dial] { dials += 1 }
        }
        XCTAssertLessThanOrEqual(dials, 31)
        XCTAssertGreaterThanOrEqual(dials, 29)
    }

    /// E-11c: the orphaned rejoin reuses the probe's own 2.0 s timeout.
    func testTheConnectTimeoutIsTwoSeconds() {
        XCTAssertEqual(PathRejoinMachine.connectTimeout, 2.0)
        XCTAssertEqual(PathRejoinMachine.connectTimeout, PathProbeMachine.connectTimeout)
    }
}
