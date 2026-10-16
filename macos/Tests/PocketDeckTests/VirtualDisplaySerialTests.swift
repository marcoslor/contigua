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
}
