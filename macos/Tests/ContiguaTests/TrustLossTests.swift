// Trust lost (docs/specs/pairing.md PAIR-31/33): which pin mismatch is the
// same phone, what the menu-bar panel shows, and the one write point's rules.

import XCTest
@testable import Contigua

final class TrustLossTests: XCTestCase {
    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")

    func testADiscoveryRecordDialIsTheSameDevice() {
        XCTAssertTrue(TrustLoss.sameDevice(dialedService: true, advertised: false))
    }

    func testAnAdvertisedIdIsTheSameDevice() {
        XCTAssertTrue(TrustLoss.sameDevice(dialedService: false, advertised: true))
    }

    func testAnUnadvertisedCachedAddressIsForeign() {
        XCTAssertFalse(TrustLoss.sameDevice(dialedService: false, advertised: false))
    }

    func testTheInferredKindIsTheOneThatKeepsRechecking() {
        XCTAssertTrue(TrustLossKind.inferred.keepsRechecking)
        XCTAssertFalse(TrustLossKind.told.keepsRechecking)
    }

    // MARK: The menu-bar panel's banner (PAIR-33/35)

    func testThePanelShowsTrustLostWithPairAgain() {
        let link = Link.needsPairing(phone)
        let notice = PhonePanelNotice.banner(for: link)
        XCTAssertEqual(notice?.text, "Pixel 9 no longer trusts this Mac.")
        XCTAssertEqual(notice?.action, .pairAgain)
    }

    func testThePanelShowsTheConnectionsOffHint() {
        let notice = PhonePanelNotice.banner(for: .offline(phone, .connectionsOff))
        XCTAssertEqual(notice?.text, "Connections are turned off on Pixel 9.")
        XCTAssertEqual(notice?.detail, "Turn on Allow connections in Contigua on your phone.")
        XCTAssertNil(notice?.action)
    }

    func testThePanelShowsNotFound() {
        let notice = PhonePanelNotice.banner(for: .offline(phone, .notFound))
        XCTAssertEqual(notice?.text, "Can't find Pixel 9 on this network.")
        XCTAssertEqual(notice?.detail,
                       "Check that the phone is on the same Wi-Fi and Contigua is running.")
    }

    func testThePanelShowsNoTransientProblem() {
        XCTAssertNil(PhonePanelNotice.banner(for: .online(phone)))
        XCTAssertNil(PhonePanelNotice.banner(for: .connecting(phone)))
        XCTAssertNil(PhonePanelNotice.banner(for: .offline(phone, .unreachable)))
        XCTAssertNil(PhonePanelNotice.banner(for: .offline(phone, .busy)))
    }
}
