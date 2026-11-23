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
}
