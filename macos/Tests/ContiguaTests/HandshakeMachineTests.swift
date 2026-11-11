// Tests for the dial's handshake outcome machine and its promise gate
// (PATH-50, ISS-82): every ending moves `pending` to its one terminal state and
// every later event is ignored, so the connector's promise can be neither
// completed twice nor left uncompleted.

import NIO
import XCTest
@testable import Contigua

final class HandshakeMachineTests: XCTestCase {
    private let endings: [HandshakeEvent] = [
        .handshakeCompleted, .handshakeFailed, .channelInactive, .deadlineFired, .dialFailed,
    ]

    /// Every ending is accepted while pending and lands on its own state.
    func testEveryEndingIsAcceptedWhilePending() {
        let expected: [(HandshakeEvent, HandshakePhase)] = [
            (.handshakeCompleted, .succeeded),
            (.handshakeFailed, .failed(.handler)),
            (.channelInactive, .failed(.inactive)),
            (.deadlineFired, .failed(.timeout)),
            (.dialFailed, .failed(.dial)),
        ]
        for (event, phase) in expected {
            var machine = HandshakeMachine()
            XCTAssertEqual(machine.phase, .pending, "\(event.token) must start from pending")
            XCTAssertEqual(machine.handle(event), .complete, "\(event.token) must decide a pending attempt")
            XCTAssertEqual(machine.phase, phase, "\(event.token) must land on \(phase.token)")
        }
    }

    /// No second event moves a decided attempt, in any combination: the promise
    /// completion that follows can happen exactly once.
    func testEveryLaterEventIsIgnoredInEveryDecidedState() {
        for first in endings {
            for second in endings {
                var machine = HandshakeMachine()
                XCTAssertEqual(machine.handle(first), .complete)
                let decided = machine.phase
                XCTAssertEqual(machine.handle(second), .ignore,
                               "\(first.token) then \(second.token) must be ignored")
                XCTAssertEqual(machine.phase, decided,
                               "\(first.token) then \(second.token) must not move the state")
            }
        }
    }

    /// The phase and event tokens are a closed set; the transition line carries
    /// no error text, address or key material (R-PRIV-1).
    func testTokensAreTheClosedSet() {
        XCTAssertEqual(HandshakePhase.pending.token, "pending")
        XCTAssertEqual(HandshakePhase.succeeded.token, "succeeded")
        XCTAssertEqual(HandshakePhase.failed(.handler).token, "failed(handler)")
        XCTAssertEqual(HandshakePhase.failed(.inactive).token, "failed(inactive)")
        XCTAssertEqual(HandshakePhase.failed(.timeout).token, "failed(timeout)")
        XCTAssertEqual(HandshakePhase.failed(.dial).token, "failed(dial)")
        XCTAssertEqual(endings.map(\.token),
                       ["completed", "error", "inactive", "deadline", "dial-failed"])
    }
}

final class HandshakeGateTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var lines: NSLockedBox<[String]>!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        lines = NSLockedBox(value: [])
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        super.tearDown()
    }

    private func makeGate() -> (HandshakeGate, EventLoopPromise<Void>) {
        let promise = group.next().makePromise(of: Void.self)
        let sink = lines!
        return (HandshakeGate(promise: promise) { line in sink.set(sink.get() + [line]) }, promise)
    }

    func testASuccessfulOfferCompletesThePromise() throws {
        let (gate, promise) = makeGate()
        XCTAssertTrue(gate.offer(.handshakeCompleted, completingWith: .success(())))
        XCTAssertNoThrow(try promise.futureResult.wait())
        XCTAssertEqual(lines.get(), ["handshake: pending --completed--> succeeded"])
    }

    func testEachFailedEndingCompletesThePromiseWithItsError() throws {
        let endings: [(HandshakeEvent, String)] = [
            (.handshakeFailed, "failed(handler)"),
            (.channelInactive, "failed(inactive)"),
            (.deadlineFired, "failed(timeout)"),
            (.dialFailed, "failed(dial)"),
        ]
        for (event, phase) in endings {
            lines.set([])
            let (gate, promise) = makeGate()
            XCTAssertTrue(gate.offer(event, completingWith: .failure(TlsV2Error.dialFailed("test ending"))))
            XCTAssertThrowsError(try promise.futureResult.wait()) { error in
                XCTAssertTrue(String(describing: error).contains("test ending"),
                              "\(event.token) must fail the promise with its error, got \(String(describing: error))")
            }
            XCTAssertEqual(lines.get(), ["handshake: pending --\(event.token)--> \(phase)"])
        }
    }

    func testAnOfferAfterTheOutcomeChangesNothing() throws {
        let (gate, promise) = makeGate()
        XCTAssertTrue(gate.offer(.deadlineFired, completingWith: .failure(TlsV2Error.handshakeTimeout)))
        XCTAssertFalse(gate.offer(.handshakeCompleted, completingWith: .success(())))
        XCTAssertFalse(gate.offer(.dialFailed, completingWith: .failure(TlsV2Error.dialFailed("late"))))
        XCTAssertThrowsError(try promise.futureResult.wait()) { error in
            XCTAssertTrue(String(describing: error).contains("handshake timed out"),
                          "the first outcome must stand, got \(String(describing: error))")
        }
        XCTAssertEqual(lines.get(), [
            "handshake: pending --deadline--> failed(timeout)",
            "handshake: failed(timeout) --completed--> failed(timeout)",
            "handshake: failed(timeout) --dial-failed--> failed(timeout)",
        ])
    }
}
