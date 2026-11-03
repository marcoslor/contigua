// PATH-3/20: one attempt's lifecycle is one enum with one transition function
// (R-14). Every transition and every ignored event is pinned here.

import XCTest
@testable import PocketDeck

final class AttemptMachineTests: XCTestCase {
    func testDialingToReadyToHelloToWelcomed() {
        var machine = AttemptMachine()
        XCTAssertEqual(.dialing, machine.phase)
        XCTAssertEqual([], machine.handle(.tlsReady))
        XCTAssertEqual(.ready, machine.phase)
        XCTAssertEqual([], machine.handle(.sentHello(join: nil)))
        XCTAssertEqual(.hello(join: nil), machine.phase)
        XCTAssertNil(machine.phase.joinSession)
        XCTAssertEqual([], machine.handle(.welcomed(session: "s")))
        XCTAssertEqual(.welcomed(session: "s"), machine.phase)
        XCTAssertTrue(machine.phase.isWelcomed)
    }

    func testAJoinRemembersTheSessionItAskedFor() {
        var machine = AttemptMachine()
        _ = machine.handle(.tlsReady)
        _ = machine.handle(.sentHello(join: "0123456789abcdef0123456789abcdef"))
        XCTAssertEqual("0123456789abcdef0123456789abcdef", machine.phase.joinSession)
        XCTAssertEqual("hello-join", machine.phase.token)
    }

    func testFailureIsRecordedFromEveryUnfinishedPhase() {
        for setup in [AttemptPhase.dialing, .ready, .hello(join: nil),
                      .hello(join: "s"), .welcomed(session: "s")] {
            var machine = AttemptMachine()
            feed(setup, into: &machine)
            XCTAssertEqual([], machine.handle(.failed(reason: "timeout")),
                           "\(setup) must accept a failure")
            XCTAssertEqual(.failed(reason: "timeout"), machine.phase)
        }
    }

    func testCloseFromEveryPhase() {
        for setup in [AttemptPhase.dialing, .ready, .hello(join: nil),
                      .failed(reason: "tls"), .welcomed(session: "s")] {
            var machine = AttemptMachine()
            feed(setup, into: &machine)
            XCTAssertEqual([], machine.handle(.closed), "\(setup) must close")
            XCTAssertEqual(.closed, machine.phase)
        }
    }

    func testEventsThatCannotHappenAreIgnored() {
        let cases: [(AttemptPhase, AttemptEvent)] = [
            (.dialing, .sentHello(join: nil)),
            (.dialing, .welcomed(session: "s")),
            (.ready, .tlsReady),
            (.ready, .welcomed(session: "s")),
            (.hello(join: nil), .tlsReady),
            (.hello(join: nil), .sentHello(join: nil)),
            (.welcomed(session: "s"), .tlsReady),
            (.welcomed(session: "s"), .sentHello(join: nil)),
            (.welcomed(session: "s"), .welcomed(session: "s")),
            (.failed(reason: "tls"), .tlsReady),
            (.failed(reason: "tls"), .sentHello(join: nil)),
            (.failed(reason: "tls"), .welcomed(session: "s")),
            (.failed(reason: "tls"), .failed(reason: "other")),
            (.closed, .tlsReady),
            (.closed, .sentHello(join: nil)),
            (.closed, .welcomed(session: "s")),
            (.closed, .failed(reason: "tls")),
            (.closed, .closed),
        ]
        for (phase, event) in cases {
            var machine = AttemptMachine()
            feed(phase, into: &machine)
            XCTAssertEqual([.ignore], machine.handle(event),
                           "\(phase) must ignore \(event)")
            XCTAssertEqual(phase, machine.phase, "\(event) must not move \(phase)")
        }
    }

    func testTokensAreClosedWordsNeverWireValues() {
        XCTAssertEqual("dialing", AttemptPhase.dialing.token)
        XCTAssertEqual("ready", AttemptPhase.ready.token)
        XCTAssertEqual("hello", AttemptPhase.hello(join: nil).token)
        XCTAssertEqual("hello-join", AttemptPhase.hello(join: "s").token)
        XCTAssertEqual("welcomed", AttemptPhase.welcomed(session: "s").token)
        XCTAssertEqual("failed", AttemptPhase.failed(reason: "tls").token)
        XCTAssertEqual("closed", AttemptPhase.closed.token)
        XCTAssertEqual("tls", AttemptEvent.tlsReady.token)
        XCTAssertEqual("hello", AttemptEvent.sentHello(join: nil).token)
        XCTAssertEqual("join", AttemptEvent.sentHello(join: "s").token)
        XCTAssertEqual("welcome", AttemptEvent.welcomed(session: "s").token)
        XCTAssertEqual("fail", AttemptEvent.failed(reason: "tls").token)
        XCTAssertEqual("close", AttemptEvent.closed.token)
    }

    /// Drives a fresh machine to a phase through the legal transitions only.
    private func feed(_ phase: AttemptPhase, into machine: inout AttemptMachine) {
        switch phase {
        case .dialing:
            break
        case .ready:
            _ = machine.handle(.tlsReady)
        case .hello(let join):
            _ = machine.handle(.tlsReady)
            _ = machine.handle(.sentHello(join: join))
        case .welcomed(let session):
            _ = machine.handle(.tlsReady)
            _ = machine.handle(.sentHello(join: nil))
            _ = machine.handle(.welcomed(session: session))
        case .failed(let reason):
            _ = machine.handle(.failed(reason: reason))
        case .closed:
            _ = machine.handle(.closed)
        }
        XCTAssertEqual(phase, machine.phase)
    }
}
