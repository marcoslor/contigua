// Test profiles must never dial a Bonjour-discovered phone: they share the
// LAN with the architect's real phone (docs of the e2ee harness). The decision
// is one pure function so it stays testable and easy to audit.

import XCTest
@testable import PocketDeck

final class DialPolicyTests: XCTestCase {
    func testProfilesUsedByTheHarnessNeverDialDiscoveredPhones() {
        for name in ["e2ee", "e2e", "dev", "audiofollow"] {
            let profile = Profile(name: name)
            XCTAssertNotNil(profile, name)
            XCTAssertFalse(DialPolicy.mayDialDiscovered(profile!), name)
        }
    }

    func testTheUsersOwnProfileMayDialDiscoveredPhones() {
        XCTAssertTrue(DialPolicy.mayDialDiscovered(.default))
    }

    /// The gate as wired into runAttempt: a non-default profile with no
    /// `--connect` and no cached address has nothing to dial, so the planner
    /// never falls back to the service endpoint a discovery would have offered.
    func testTestProfileWithoutConnectOrCacheHasNoEndpoint() {
        let choice = EndpointPlanner().choose(discovered: false, cached: nil,
                                              lastAttemptWasService: false,
                                              lastAttemptFailed: false, sinceLaunch: 10)
        XCTAssertEqual(choice, .none)
    }
}
