// The single-path silence probe (docs/design/paths.md §6.1, PATH-24/E-11):
// one path, a live stream and 2 s without an inbound frame start one join
// beside it, on a 1, 2, 4 s backoff; nothing else may start one.

import XCTest
@testable import PocketDeck

final class PathProbeTests: XCTestCase {
    private func tick(paths: Int = 1, stream: Bool = true,
                      silent: TimeInterval = PathProbeMachine.silence) -> PathProbeEvent {
        .tick(pathCount: paths, streamLive: stream, silentFor: silent)
    }

    func testTwoSecondsOfSilenceOnTheOnlyPathWithAStreamStartsOneProbe() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(silent: 1.99), now: 0), [.ignore])
        XCTAssertEqual(probe.state, .idle)
        XCTAssertEqual(probe.handle(tick(silent: 2.0), now: 1), [.dial])
        XCTAssertEqual(probe.state, .inFlight(failures: 0))
    }

    func testNoProbeWithoutALiveStream() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(stream: false), now: 0), [.ignore])
        XCTAssertEqual(probe.state, .idle)
    }

    func testNoProbeWithTwoPaths() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(paths: 2), now: 0), [.ignore])
        XCTAssertEqual(probe.state, .idle)
    }

    func testNoProbeWithoutAPath() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(paths: 0), now: 0), [.ignore])
        XCTAssertEqual(probe.state, .idle)
    }

    func testOneProbeInFlightIsNeverDoubled() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 0), [.dial])
        for now in stride(from: 0.25, through: 4.0, by: 0.25) {
            XCTAssertEqual(probe.handle(tick(), now: now), [.ignore])
        }
        XCTAssertEqual(probe.state, .inFlight(failures: 0))
    }

    func testTheRetriesBackOffOneTwoFourAndStayAtFour() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 10), [.dial])
        XCTAssertEqual(probe.handle(.failed, now: 10), [.ignore])
        XCTAssertEqual(probe.state, .waiting(nextAt: 11, failures: 1))
        XCTAssertEqual(probe.handle(tick(), now: 10.99), [.ignore])
        XCTAssertEqual(probe.handle(tick(), now: 11), [.dial])

        XCTAssertEqual(probe.handle(.failed, now: 11), [.ignore])
        XCTAssertEqual(probe.state, .waiting(nextAt: 13, failures: 2))
        XCTAssertEqual(probe.handle(tick(), now: 12.99), [.ignore])
        XCTAssertEqual(probe.handle(tick(), now: 13), [.dial])

        XCTAssertEqual(probe.handle(.failed, now: 13), [.ignore])
        XCTAssertEqual(probe.state, .waiting(nextAt: 17, failures: 3))
        XCTAssertEqual(probe.handle(tick(), now: 16.99), [.ignore])
        XCTAssertEqual(probe.handle(tick(), now: 17), [.dial])

        XCTAssertEqual(probe.handle(.failed, now: 17), [.ignore])
        XCTAssertEqual(probe.state, .waiting(nextAt: 21, failures: 4))
        XCTAssertEqual(probe.handle(tick(), now: 20.99), [.ignore])
        XCTAssertEqual(probe.handle(tick(), now: 21), [.dial])
    }

    func testTheBackoffWaitsWhileTheTriggerDoesNotHold() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 0), [.dial])
        XCTAssertEqual(probe.handle(.failed, now: 0), [.ignore])
        // A frame arrives: the silence ended, so no retry is due.
        XCTAssertEqual(probe.handle(tick(silent: 0), now: 0.5), [.ignore])
        XCTAssertEqual(probe.state, .idle)
        // The next silence starts over at the first step.
        XCTAssertEqual(probe.handle(tick(), now: 3), [.dial])
    }

    func testInboundFramesCancelAnInFlightProbe() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 0), [.dial])
        XCTAssertEqual(probe.handle(.inbound, now: 0.3), [.cancel])
        XCTAssertEqual(probe.state, .idle)
    }

    func testAClosedStreamStopsTheProbe() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 0), [.dial])
        XCTAssertEqual(probe.handle(.stop, now: 0.3), [.cancel])
        XCTAssertEqual(probe.state, .idle)
    }

    func testAWelcomeEndsTheProbeAndTwoPathsStopFurtherTicks() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 0), [.dial])
        XCTAssertEqual(probe.handle(.welcomed, now: 0.4), [.ignore])
        XCTAssertEqual(probe.state, .idle)
        XCTAssertEqual(probe.handle(tick(paths: 2, silent: 30), now: 0.5), [.ignore])
        XCTAssertEqual(probe.state, .idle)
    }

    func testTheSilenceConstantIsTwoSeconds() {
        XCTAssertEqual(PathProbeMachine.silence, 2.0)
    }
}
