// File ▸ New <App> Window (MENU-2, WIN-25, WIN-27, WIN-32, WIN-34): the title
// follows the key app, and the enabled/disabled matrix is one rule over the
// phone's answer, the window count, an opening window and the link.

import XCTest
@testable import Contigua

@MainActor
final class NewWindowTests: XCTestCase {
    private var fixture: MultiWindowFixture!

    override func setUp() {
        super.setUp()
        fixture = MultiWindowFixture()
    }

    override func tearDown() {
        fixture.closeAll()
        fixture = nil
        super.tearDown()
    }

    // MARK: Titles

    func testTheTitleNamesTheKeyApp() {
        XCTAssertEqual(NewWindowItem.make(app: "Chrome", windowCount: 1, multi: true, opening: false,
                                          cap: 4, link: .up).title,
                       "New Chrome Window")
        XCTAssertEqual(NewWindowItem.make(app: "Settings", windowCount: 1, multi: false, opening: false,
                                          cap: 4, link: .up).title,
                       "New Settings Window")
    }

    /// With no app window key the item reads "New Window" and is disabled
    /// (MENU-2); there is nothing to name.
    func testWithoutAKeyAppItReadsNewWindowAndIsDisabled() {
        let item = NewWindowItem.make(app: nil, windowCount: 0, multi: true, opening: false,
                                      cap: 4, link: .up)
        XCTAssertEqual(item.title, "New Window")
        XCTAssertFalse(item.enabled)
        XCTAssertNil(item.help, "there is no sentence: the item is off because nothing is key")
    }

    // MARK: The enabled matrix

    func testAnAppThatOpensSeveralWindowsMayAddOne() {
        fixture.open(taskLabel: "Docs")
        let item = fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg)
        XCTAssertTrue(item.enabled)
        XCTAssertNil(item.help)
    }

    func testAnAppThatOpensOneWindowIsDisabledWithItsSentence() {
        fixture.open(MultiWindowFixture.settings)
        let item = fixture.manager.newWindowItem(for: MultiWindowFixture.settings.pkg)
        XCTAssertFalse(item.enabled)
        XCTAssertEqual(item.help, "Settings opens one window at a time.")
        let opens = fixture.openRequests.count
        XCTAssertNil(fixture.manager.openAdditional(pkg: MultiWindowFixture.settings.pkg))
        XCTAssertEqual(fixture.openRequests.count, opens, "a disabled item sends nothing")
    }

    func testAtTheCapItReadsTheCapSentence() {
        fixture.manager.setMaxWindows(2)
        fixture.open(taskLabel: "Docs")
        fixture.add(taskLabel: "Mail")
        let item = fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg)
        XCTAssertFalse(item.enabled)
        XCTAssertEqual(item.help, "Close a Chrome window to open another.")
        let opens = fixture.openRequests.count
        XCTAssertNil(fixture.manager.openAdditional(pkg: MultiWindowFixture.chrome.pkg))
        XCTAssertEqual(fixture.openRequests.count, opens, "past the cap the Mac sends nothing")
    }

    /// A phone that reports no cap is treated as 4 (WIN-32).
    func testAPhoneThatReportsNoCapIsFour() {
        XCTAssertEqual(fixture.manager.maxWindows, WindowManager.defaultMaxWindows)
        XCTAssertEqual(WindowManager.defaultMaxWindows, 4)
        fixture.manager.setMaxWindows(nil)
        XCTAssertEqual(fixture.manager.maxWindows, 4)
        fixture.manager.setMaxWindows(6)
        XCTAssertEqual(fixture.manager.maxWindows, 6, "the cap follows the phone's number")
    }

    func testAWindowStillOpeningIsDisabledWithItsSentence() {
        fixture.open(taskLabel: "Docs", firstFrame: false)
        let item = fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg)
        XCTAssertFalse(item.enabled)
        XCTAssertEqual(item.help, "Opening on your phone…")
        let opens = fixture.openRequests.count
        XCTAssertNil(fixture.manager.openAdditional(pkg: MultiWindowFixture.chrome.pkg))
        XCTAssertEqual(fixture.openRequests.count, opens)
    }

    func testWhileTheLinkIsDownItReadsReconnectingThenOffline() {
        fixture.open(taskLabel: "Docs")
        let clock = LinkPhaseClock()
        _ = clock
        fixture.manager.linkLost()
        XCTAssertEqual(fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg).help, "Reconnecting…")
        let opens = fixture.openRequests.count
        XCTAssertNil(fixture.manager.openAdditional(pkg: MultiWindowFixture.chrome.pkg))
        XCTAssertEqual(fixture.openRequests.count, opens, "no window.open while the link is down")

        // 15 s later the same item says the phone is away (WIN-34); the phase
        // machine is pure, so the rule is tested here rather than by waiting.
        var phaseClock = LinkPhaseClock()
        _ = phaseClock.linkLost(at: 100)
        XCTAssertEqual(phaseClock.tick(at: 100 + LinkPhaseClock.offlineAfter - 0.1), .reconnecting)
        XCTAssertEqual(phaseClock.tick(at: 100 + LinkPhaseClock.offlineAfter), .offline)

        fixture.manager.linkRestored()
        XCTAssertEqual(fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg).help, nil)
    }

    /// The permanent reason beats the temporary ones: an app that cannot open
    /// a second window says so even while its window is still opening.
    func testTheSingleWindowSentenceIsToldWhileItsWindowIsOpening() {
        fixture.open(MultiWindowFixture.settings, firstFrame: false)
        let item = fixture.manager.newWindowItem(for: MultiWindowFixture.settings.pkg)
        XCTAssertEqual(item.help, "Settings opens one window at a time.")
    }
}
