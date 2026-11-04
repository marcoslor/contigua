import XCTest
@testable import PocketDeck

final class VirtualDisplaySerialTests: XCTestCase {
    func testSameProfileGetsTheSameSerialEveryLaunch() {
        XCTAssertEqual(VirtualDisplay.serialNumber(profile: "quiet"), VirtualDisplay.serialNumber(profile: "quiet"))
    }

    func testProfilesGetDifferentSerials() {
        XCTAssertNotEqual(VirtualDisplay.serialNumber(profile: "quiet"), VirtualDisplay.serialNumber(profile: "e2ee"))
    }

    func testSerialIsNeverZero() {
        XCTAssertNotEqual(VirtualDisplay.serialNumber(profile: ""), 0)
    }

    /// ISS-28: every test run draws on the one test identity, whatever
    /// `PD_E2E_PROFILE` says, so a run leaves no new display behind.
    func testATestRunUsesOneDisplaySerialForEveryProfile() {
        var a = LaunchOptions()
        a.profileName = "a"
        a.background = true
        var b = LaunchOptions()
        b.profileName = "b"
        b.background = true
        XCTAssertEqual(VirtualDisplay.displaySerialNumber(for: a), VirtualDisplay.displaySerialNumber(for: b))
        XCTAssertEqual(VirtualDisplay.displaySerialNumber(for: a), VirtualDisplay.serialNumber(profile: "e2e"))
    }

    /// The person's own launch (no test flag) keeps the per-profile identity.
    func testAPersonLaunchKeepsItsProfileSerial() {
        var options = LaunchOptions()
        options.profileName = "quiet"
        XCTAssertEqual(VirtualDisplay.displaySerialNumber(for: options), VirtualDisplay.serialNumber(profile: "quiet"))
        XCTAssertNotEqual(VirtualDisplay.displaySerialNumber(for: options), VirtualDisplay.serialNumber(profile: "e2e"))
    }
}
