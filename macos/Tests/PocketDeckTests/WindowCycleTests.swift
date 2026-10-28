// Window ▸ Next Window ⌘` (WIN-29, WIN-30): the key app's windows front to
// back, wrapping, and nothing to the phone. With one window it does nothing.

import XCTest
@testable import PocketDeck

@MainActor
final class WindowCycleTests: XCTestCase {
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

    private func frontStream() -> UInt32? {
        fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).first?.stream
    }

    func testThreeWindowsCycleInFrontToBackOrderAndWrap() {
        let a = fixture.open(taskLabel: "A")
        let b = fixture.add(taskLabel: "B")!
        let c = fixture.add(taskLabel: "C")!
        // Each new window is the front one: C, B, A.
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).map(\.stream),
                       [c.stream, b.stream, a.stream])

        XCTAssertEqual(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg)?.stream, b.stream)
        XCTAssertEqual(frontStream(), b.stream)
        XCTAssertEqual(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg)?.stream, a.stream)
        XCTAssertEqual(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg)?.stream, c.stream,
                       "the cycle wraps at the end")
        XCTAssertEqual(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg)?.stream, b.stream)
    }

    func testOneWindowDoesNothing() {
        fixture.open(taskLabel: "Docs")
        let before = fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).count
        XCTAssertNil(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg))
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).count, before)
        XCTAssertFalse(fixture.manager.canCycleWindows, "⌘` stays disabled with one window")
    }

    /// The cycle is the Mac's: no `window.open`, no `window.resize`, no input
    /// reaches the phone (WIN-30).
    func testItSendsNothingToThePhone() {
        _ = fixture.open(taskLabel: "A")
        _ = fixture.add(taskLabel: "B")
        let sent = ["window.open", "window.close", "window.resize", "window.pause", "window.resume"]
            .map { ($0, fixture.session.sent($0).count) }
        for _ in 0..<4 { fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg) }
        for (type, count) in sent {
            XCTAssertEqual(fixture.session.sent(type).count, count, "the cycle sent a \(type)")
        }
    }

    /// The cycle is scoped to the key app: another app's windows keep their
    /// place (WIN-35's rule, one phone).
    func testAnotherAppsWindowsAreNotCycled() {
        let a = fixture.open(taskLabel: "Docs")
        _ = fixture.add(taskLabel: "Mail")
        let settings = fixture.open(MultiWindowFixture.settings)
        // The front one is the newer Chrome window; ⌘` goes to the older one.
        XCTAssertEqual(fixture.manager.cycleWindows(pkg: MultiWindowFixture.chrome.pkg)?.stream, a.stream)
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.settings.pkg).map(\.stream),
                       [settings.stream], "the other app's window did not move")
    }
}
