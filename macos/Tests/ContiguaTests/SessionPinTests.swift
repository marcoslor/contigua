// The session's own pin (docs/specs/transport.md PATH-52): a pairing session
// adopts the record pairing established, only after the phone's pair.ok and
// the founding welcome, and only a record TLS can verify. Every other event
// is ignored, never guessed at (ISS-95).

import XCTest
@testable import Contigua

final class SessionPinTests: XCTestCase {
    private let record = PinnedPhoneV2(deviceId: "phone-1",
                                       phoneFingerprintHex: "aa",
                                       certPem: "cert")

    func testPairOKVerifiesAPairingSession() {
        var state = SessionPinState.pairing(verified: false)
        XCTAssertTrue(state.handle(.phoneAllowed))
        XCTAssertEqual(state, .pairing(verified: true))
        XCTAssertFalse(state.isPinned)
        XCTAssertNil(state.record)
    }

    func testAClaimedPairOKIsTheOnlyVerification() {
        var state = SessionPinState.pairing(verified: false)
        // The founding welcome alone never proves the handshake.
        XCTAssertFalse(state.handle(.founded(record: record)))
        XCTAssertEqual(state, .pairing(verified: false))
    }

    func testAVerifiedPairingAdoptsACompleteRecordAtTheWelcome() {
        var state = SessionPinState.pairing(verified: true)
        XCTAssertTrue(state.handle(.founded(record: record)))
        XCTAssertEqual(state, .pinned(record))
        XCTAssertTrue(state.isPinned)
        XCTAssertEqual(state.record, record)
    }

    func testAVerifiedPairingWithoutAUsableRecordStaysUnpinned() {
        var state = SessionPinState.pairing(verified: true)
        XCTAssertFalse(state.handle(.founded(record: nil)))
        XCTAssertEqual(state, .pairing(verified: true))
    }

    func testTheAdoptionHappensOnceAndAPinnedSessionNeverMoves() {
        var state = SessionPinState.pinned(record)
        XCTAssertFalse(state.handle(.phoneAllowed))
        XCTAssertFalse(state.handle(.founded(record: record)))
        XCTAssertFalse(state.handle(.founded(record: nil)))
        XCTAssertEqual(state, .pinned(record))

        var adopted = SessionPinState.pairing(verified: true)
        XCTAssertTrue(adopted.handle(.founded(record: record)))
        XCTAssertFalse(adopted.handle(.founded(record: record)))
        XCTAssertFalse(adopted.handle(.phoneAllowed))
        XCTAssertEqual(adopted, .pinned(record))
    }

    func testARepeatedPairOKChangesNothing() {
        var state = SessionPinState.pairing(verified: true)
        XCTAssertFalse(state.handle(.phoneAllowed))
        XCTAssertEqual(state, .pairing(verified: true))
    }

    /// The transition log carries closed tokens only: no fingerprint, no id.
    func testTheTokensCarryNoIdentityOrKeyMaterial() {
        XCTAssertEqual(SessionPinState.pairing(verified: false).token, "pairing")
        XCTAssertEqual(SessionPinState.pairing(verified: true).token, "pairing-verified")
        XCTAssertEqual(SessionPinState.pinned(record).token, "pinned")
        XCTAssertEqual(SessionPinEvent.phoneAllowed.token, "pair.ok")
        XCTAssertEqual(SessionPinEvent.founded(record: record).token, "welcome")
        XCTAssertEqual(SessionPinEvent.founded(record: nil).token, "welcome-no-record")
        for token in [SessionPinState.pinned(record).token,
                      SessionPinEvent.founded(record: record).token] {
            XCTAssertFalse(token.contains("aa"))
            XCTAssertFalse(token.contains("phone-1"))
        }
    }
}
