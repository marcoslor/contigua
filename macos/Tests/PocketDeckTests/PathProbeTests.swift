// The single-path silence probe (docs/design/paths.md §6.1, PATH-24/E-11):
// one path, a live stream and 2 s without an inbound frame start one join
// beside it, with a 2.0 s connect timeout and no backoff after a failure;
// nothing else may start one.

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
        XCTAssertEqual(probe.state, .inFlight)
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
        XCTAssertEqual(probe.state, .inFlight)
    }

    /// E-11b: a failed probe is followed by the next one at once — no backoff
    /// while the silence holds — and never with two in flight.
    func testAFailureIsFollowedByTheNextProbeAtOnce() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 0), [.dial])
        XCTAssertEqual(probe.handle(.failed, now: 2), [.ignore])
        // No waiting step: the very next tick may dial again.
        XCTAssertEqual(probe.handle(tick(), now: 2), [.dial])
    }

    /// E-11b: no backoff — each failure is followed by the next dial on the
    /// next tick, back-to-back while the silence holds.
    func testAFailedProbeIsDialedAgainBackToBackWhileTheSilenceHolds() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 10), [.dial])
        for now in stride(from: 12.0, through: 22.0, by: 2.0) {
            XCTAssertEqual(probe.handle(.failed, now: now), [.ignore])
            XCTAssertEqual(probe.state, .idle)
            XCTAssertEqual(probe.handle(tick(), now: now), [.dial])
            XCTAssertEqual(probe.state, .inFlight)
        }
    }

    func testTheTriggerGoneAfterAFailureStopsTheRetries() {
        var probe = PathProbeMachine()
        XCTAssertEqual(probe.handle(tick(), now: 0), [.dial])
        XCTAssertEqual(probe.handle(.failed, now: 2), [.ignore])
        // A frame arrives: the silence ended, so no retry is due.
        XCTAssertEqual(probe.handle(tick(silent: 0), now: 2), [.ignore])
        XCTAssertEqual(probe.state, .idle)
        // The next silence starts a fresh probe.
        XCTAssertEqual(probe.handle(tick(), now: 5), [.dial])
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

    /// E-11b: the probe's own connect timeout is 2.0 s; the session's first
    /// connect keeps its own timeout.
    func testTheProbesConnectTimeoutIsTwoSeconds() {
        XCTAssertEqual(PathProbeMachine.connectTimeout, 2.0)
    }
}
