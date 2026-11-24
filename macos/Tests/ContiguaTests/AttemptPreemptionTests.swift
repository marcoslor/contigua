// PAIR-36 (#217): a due attempt (a Bonjour hint, a retry, a tick) leaves an
// in-flight pairing dial alone, the same guard a person's pairing has, and the
// test entry points' retries may still pair. Both decisions are pure, so
// runAttempt only wires them; the session's own `dialsToPair` is the same
// pin decision its dial makes.

import XCTest
@testable import Contigua

final class AttemptPreemptionTests: XCTestCase {
    private let unfinished: [SessionState] = [.idle, .connecting, .handshaking]

    func testADueAttemptLeavesAnInFlightPairingDialAlone_PAIR36() {
        for state in unfinished {
            XCTAssertEqual(AttemptPreemption.decide(state: state, dialsToPair: true), .leave, "\(state)")
        }
    }

    func testADueAttemptReplacesAnUnauthenticatedPinnedDial_PAIR36() {
        for state in unfinished {
            XCTAssertEqual(AttemptPreemption.decide(state: state, dialsToPair: false), .replace, "\(state)")
        }
    }

    func testAReadySessionIsLeftAlone_PAIR36() {
        for pairing in [true, false] {
            XCTAssertEqual(AttemptPreemption.decide(state: .ready, dialsToPair: pairing), .leave)
        }
    }

    func testAnEndedDialIsReplaced_PAIR36() {
        for state in [SessionState.failed("tls"), .closed] {
            for pairing in [true, false] {
                XCTAssertEqual(AttemptPreemption.decide(state: state, dialsToPair: pairing), .replace,
                               "\(state) pairing=\(pairing)")
            }
        }
    }

    func testNoSessionDials_PAIR36() {
        XCTAssertEqual(AttemptPreemption.decide(state: nil, dialsToPair: false), .dial)
    }

    /// `--connect` may pair (the phone's Allow is the only step) while its
    /// launch's first pairing is unresolved: a retry after `busy` or a refused
    /// first dial is still a pairing attempt, never a pin-only dial that ends
    /// in `no-pin`. The `--connect-phone` hook dials as it always has.
    func testAManualConnectRetryPairsWhileTheLaunchsPairingIsOpen_PAIR36() {
        XCTAssertEqual(DialPolicy.pairingPolicy(for: .manualConnect(launchPairing: true)), .allowed)
        XCTAssertEqual(DialPolicy.pairingPolicy(for: .testHook), .allowed)
    }

    /// After the launch's first pairing outcome a retry is pin-only: a
    /// cancelled sheet never leaves a quiet pairing dial (pairflow PF1).
    func testAManualConnectRetryAfterTheFirstOutcomeIsPinOnly_PAIR36() {
        XCTAssertEqual(DialPolicy.pairingPolicy(for: .manualConnect(launchPairing: false)), .never)
    }

    func testAnAutomaticReconnectNeverPairs_PAIR36() {
        XCTAssertEqual(DialPolicy.pairingPolicy(for: .automatic), .never)
    }

    // MARK: The session's own pin decision

    private func session(pinned: PinnedPhoneV2? = nil, store: PhonePinStoreV2? = nil,
                         policy: Session.PairingPolicy) -> Session {
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: "phone-1",
                              clientId: "test-client", pinnedPhone: pinned, pinStore: store)
        session.pairingPolicy = policy
        return session
    }

    private func record() -> PinnedPhoneV2 {
        PinnedPhoneV2(deviceId: "phone-1", phoneFingerprintHex: String(repeating: "7a", count: 32),
                      certPem: "-----BEGIN CERTIFICATE-----\nCAFE\n-----END CERTIFICATE-----")
    }

    func testASessionWithNoPinThatMayPairDialsToPair_PAIR36() {
        XCTAssertTrue(session(policy: .allowed).dialsToPair)
    }

    func testAPinnedOrPinOnlySessionDoesNotDialToPair_PAIR36() throws {
        XCTAssertFalse(session(policy: .never).dialsToPair)
        XCTAssertFalse(session(policy: .probe).dialsToPair)
        XCTAssertFalse(session(pinned: record(), policy: .allowed).dialsToPair)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attempt-preemption-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhonePinStoreV2(fileUrl: dir.appendingPathComponent("pins.json"))
        store.store(record())
        XCTAssertFalse(session(store: store, policy: .allowed).dialsToPair)
    }

    // MARK: The gap between the pin store and ready

    /// The welcome stores the pin (`storePinFor`) before the session is
    /// marked ready. A due attempt in that gap must still see the dial that
    /// is pairing, or it would close the session whose pairing the person
    /// just allowed (#241 review). The pin callback runs in exactly that gap.
    func testARetryBetweenThePinStoreAndReadyLeavesTheSessionAlone_PAIR36() throws {
        let mac = IdentityGeneratorV2.make(deviceId: "mac-\(UUID().uuidString.prefix(8))")
        let phone = IdentityGeneratorV2.make(deviceId: "phone-\(UUID().uuidString.prefix(8))",
                                             cn: "Contigua Phone").identity
        let server = try FakeServer(phoneIdentity: phone, trustingClientPem: mac.identity.certPem)
        defer { server.stop() }
        let brain = FakeV2PhoneBrain(identity: phone, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        let pins = PhonePinStoreV2()
        let seen = SessionLockedBox<(state: SessionState, decision: AttemptPreemption)?>(value: nil)
        let holder = SessionLockedBox<Session?>(value: nil)
        // A remembered phone with no pin yet: the dial pairs.
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: server.port),
                              knownDeviceId: "phone-1", clientId: "test-client",
                              identity: mac.identity, pinStore: pins,
                              onPinEstablished: { _ in
                                  guard let live = holder.get() else { return }
                                  seen.set((live.state, AttemptPreemption.decide(state: live.state,
                                                                                 dialsToPair: live.dialsToPair)))
                              })
        session.pairingPolicy = .allowed
        holder.set(session)
        defer { session.close(); holder.set(nil) }
        session.start()
        let deadline = Date().addingTimeInterval(5)
        while session.state != .ready, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTAssertEqual(session.state, .ready, "never paired")
        guard let gap = seen.get() else { XCTFail("the pin was never stored"); return }
        XCTAssertNotEqual(gap.state, .ready, "the pin callback ran after ready")
        XCTAssertEqual(gap.decision, .leave, "a retry in the gap closes the pairing session")
        XCTAssertTrue(session.dialsToPair, "the dial paired; the stored pin does not change what it did")
    }
}
