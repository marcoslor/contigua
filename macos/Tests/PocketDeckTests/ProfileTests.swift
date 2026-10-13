// Profiles: every piece of persistent state is namespaced by the profile, and
// the default profile keeps the storage of earlier builds. Nothing here writes
// to the standard defaults or to the Keychain: the checks are on the names.

import CoreSpotlight
import XCTest
@testable import PocketDeck

final class ProfileTests: XCTestCase {
    private let testName = "unit-profile-test"

    override func tearDown() {
        if let profile = Profile(name: testName), let suite = profile.defaultsSuiteName {
            profile.defaults.removePersistentDomain(forName: suite)
        }
        super.tearDown()
    }

    // MARK: Default profile is unchanged

    func testDefaultProfileKeepsTodaysStorage() {
        let profile = Profile.default
        XCTAssertEqual(profile.name, "default")
        XCTAssertTrue(profile.isDefault)
        XCTAssertEqual(profile.keychainService, "dev.pocketdeck.mac")
        XCTAssertNil(profile.defaultsSuiteName)
        XCTAssertTrue(profile.defaults === UserDefaults.standard)
        XCTAssertEqual(profile.spotlightDomainPrefix, "")
        XCTAssertEqual(profile.supportDirectoryName, "PocketDeck")
    }

    // MARK: Named profiles are namespaced

    func testNamedProfileNamespacesKeychainService() {
        let profile = Profile(name: "e2e")!
        XCTAssertFalse(profile.isDefault)
        XCTAssertEqual(profile.keychainService, "dev.pocketdeck.mac.e2e")
        XCTAssertNotEqual(profile.keychainService, Profile.default.keychainService)
        XCTAssertEqual(profile.keychain.service, "dev.pocketdeck.mac.e2e")
    }

    func testNamedProfileUsesItsOwnDefaultsSuite() {
        let profile = Profile(name: "e2e")!
        XCTAssertEqual(profile.defaultsSuiteName, "dev.pocketdeck.mac.e2e")
        XCTAssertFalse(profile.defaults === UserDefaults.standard)
        XCTAssertNotEqual(profile.defaultsSuiteName, Profile.default.defaultsSuiteName)
    }

    func testNamedProfileDefaultsDoNotLeakIntoStandardDefaults() throws {
        let profile = try XCTUnwrap(Profile(name: testName))
        let key = "profileTestMarker"
        profile.defaults.set("written", forKey: key)
        XCTAssertEqual(profile.defaults.string(forKey: key), "written")
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    func testNamedProfileSpotlightPrefixAndFolders() {
        let profile = Profile(name: "e2e")!
        XCTAssertEqual(profile.spotlightDomainPrefix, "e2e.")
        XCTAssertEqual(profile.supportDirectoryName, "PocketDeck-e2e")
    }

    func testClientIdIsStablePerProfile() throws {
        let profile = try XCTUnwrap(Profile(name: testName))
        profile.defaults.removeObject(forKey: "clientId")
        let first = ClientIdentity.clientId(in: profile)
        XCTAssertEqual(ClientIdentity.clientId(in: profile), first)
        XCTAssertEqual(profile.defaults.string(forKey: "clientId"), first)
    }

    func testSpotlightIdentifiersCarryThePrefix() {
        let apps = [AppInfo(json: ["pkg": "com.android.settings", "label": "Settings"])!]
        let items = SpotlightIndexer.items(apps: apps, deviceId: "a1b2c3", phoneName: "FakePhone",
                                           domainPrefix: "e2e.", iconData: { _ in nil })
        XCTAssertEqual(items.map(\.uniqueIdentifier), ["e2e.a1b2c3/com.android.settings"])
        XCTAssertEqual(items.map(\.domainIdentifier), ["e2e.a1b2c3"])
    }

    func testSpotlightParseOnlyAcceptsOwnPrefix() {
        XCTAssertEqual(SpotlightIndexer.parse(identifier: "e2e.a1b2c3/com.android.settings", domainPrefix: "e2e."),
                       SpotlightOpenRequest(deviceId: "a1b2c3", pkg: "com.android.settings"))
        XCTAssertNil(SpotlightIndexer.parse(identifier: "a1b2c3/com.android.settings", domainPrefix: "e2e."))
        XCTAssertNil(SpotlightIndexer.parse(identifier: "e2e./com.android.settings", domainPrefix: "e2e."))
    }

    func testDefaultSpotlightIdentifiersAreUnchanged() {
        XCTAssertEqual(SpotlightIndexer.uniqueIdentifier(deviceId: "a1b2c3", pkg: "com.x"), "a1b2c3/com.x")
        XCTAssertEqual(SpotlightIndexer.parse(identifier: "a1b2c3/com.x"),
                       SpotlightOpenRequest(deviceId: "a1b2c3", pkg: "com.x"))
    }

    // MARK: Names

    func testProfileNameValidation() {
        for valid in ["default", "e2e", "e2e-12345", String(repeating: "a", count: 32)] {
            XCTAssertNotNil(Profile(name: valid), valid)
        }
        for invalid in ["", "E2E", "../x", "a/b", "a b", "a.b", "a_b", String(repeating: "a", count: 33)] {
            XCTAssertNil(Profile(name: invalid), invalid)
        }
    }
}
