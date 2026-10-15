// What the user reads for a failed connection, and when the Mac keeps trying.

import XCTest
@testable import PocketDeck

final class ConnectionFailureTests: XCTestCase {

    func testPhoneErrorCodesReadAsTheirMeaning() {
        XCTAssertEqual(ConnectionFailure.message(for: "no-pin"),
                       "Pairing was removed on the phone, pair again")
        XCTAssertEqual(ConnectionFailure.message(for: "bad_pin"),
                       "This phone's identity changed. Pair again.")
        XCTAssertEqual(ConnectionFailure.message(for: "pin-mismatch"),
                       "This phone's identity changed. Pair again.")
        XCTAssertEqual(ConnectionFailure.message(for: "busy"), "Another Mac is connected")
        XCTAssertEqual(ConnectionFailure.message(for: "pair_denied"), "Pairing was denied")
        XCTAssertEqual(ConnectionFailure.message(for: "version"),
                       "This phone runs an incompatible version of PocketDeck")
        XCTAssertEqual(ConnectionFailure.message(for: "protocol"), "The phone rejected a message from this Mac")
        XCTAssertEqual(ConnectionFailure.message(for: "no_stream"), "That window is no longer open on the phone")
        XCTAssertEqual(ConnectionFailure.message(for: "launch_failed"),
                       "The app could not be started on the phone")
    }

    func testEveryPhoneErrorCodeInTheProtocolHasAMessage() {
        for code in ["busy", "bad_pin", "pair_denied", "pair_timeout", "version", "protocol", "no_stream", "launch_failed"] {
            XCTAssertNotNil(ConnectionFailure.message(for: code), code)
        }
    }

    func testPairingTimeoutSaysWhatHappened() {
        XCTAssertEqual(ConnectionFailure.message(for: "pair_timeout"),
                       "Nobody tapped Allow on the phone in time. Try again.")
    }

    func testIdentityMismatchExplainsTheRememberedAddress() {
        XCTAssertEqual(ConnectionFailure.message(for: ConnectionFailure.identityMismatch),
                       "Another phone is using the remembered address.")
    }

    func testTransientCloseHasNoMessageSoTheUIShowsReconnecting() {
        for reason in ["closed-by-peer", "timeout", "receive", "failed", "cancelled", "framing", "closed"] {
            XCTAssertNil(ConnectionFailure.message(for: reason), reason)
        }
        XCTAssertNil(ConnectionFailure.message(for: "some_future_code"))
    }

    func testTransientFailuresRetry() {
        for reason in ["closed-by-peer", "timeout", "receive", "failed", "busy", "tls", "no-pin"] {
            XCTAssertTrue(ConnectionFailure.retriesAutomatically(reason), reason)
        }
    }

    func testPairingFailuresDoNotRetryBecauseEveryRetryPromptsThePhone() {
        XCTAssertFalse(ConnectionFailure.retriesAutomatically("pair_denied"))
        XCTAssertFalse(ConnectionFailure.retriesAutomatically("pair_timeout"))
        XCTAssertFalse(ConnectionFailure.retriesAutomatically("version"))
        XCTAssertFalse(ConnectionFailure.retriesAutomatically("pin-mismatch"))
        XCTAssertFalse(ConnectionFailure.retriesAutomatically("bad_pin"))
        XCTAssertFalse(ConnectionFailure.retriesAutomatically(ConnectionFailure.identityMismatch))
    }
}
