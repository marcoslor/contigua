// With 2+ phones (WIN-35), the New items, the open-window list and ⌘` act on
// the phone in use only, and the cap is that phone's own. Phase 2 has one
// phone; every window function is keyed by device id so a second one is a
// value, not a rewrite.

import XCTest
@testable import Contigua

@MainActor
final class MultiWindowPhoneTests: XCTestCase {
    private var fixture: MultiWindowFixture!
    private let other = "phone-2"

    override func setUp() {
        super.setUp()
        fixture = MultiWindowFixture()
    }

    override func tearDown() {
        fixture.closeAll()
        fixture = nil
        super.tearDown()
    }

    func testAnAppsWindowsAreKeyedByPhone() {
        let mine = fixture.open(taskLabel: "Docs")
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).map(\.stream),
                       [mine.stream])
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg,
                                                  deviceId: other).count, 0,
                       "another phone's windows are not this phone's")
        XCTAssertEqual(mine.deviceId, MultiWindowFixture.deviceId)
    }

    /// The window list a menu shows is the phone in use's: another phone's
    /// windows are not listed, and a pick cannot raise them.
    func testTheMenuListsOnlyThePhoneInUse() {
        _ = fixture.open(taskLabel: "Docs")
        let rows = fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg)
        XCTAssertEqual(rows.count, 2, "New plus the one window")
        XCTAssertEqual(fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg,
                                                      deviceId: other).map(\.title),
                       ["New Chrome Window"], "no windows on the other phone")
    }

    /// ⌘` cycles the phone in use's windows only.
    func testTheCycleIsPerPhone() {
        let a = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        XCTAssertEqual(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg,
                                                    deviceId: other), nil,
                       "the other phone has no window to cycle")
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).map(\.stream),
                       [b.stream, a.stream], "the first phone's order is untouched")
        XCTAssertEqual(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg)?.stream, a.stream)
    }

    /// The cap is the phone's own number (WIN-32, WIN-35): a window on another
    /// phone does not count against this one.
    func testTheCapCountsOnlyThePhoneInUse() {
        fixture.manager.setMaxWindows(2)
        _ = fixture.open(taskLabel: "Docs")
        _ = fixture.add(taskLabel: "Mail")
        XCTAssertEqual(fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg,
                                                     deviceId: other).enabled, true,
                       "the other phone is under its own cap")
        XCTAssertEqual(fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg,
                                                     deviceId: MultiWindowFixture.deviceId).enabled, false)
    }
}
