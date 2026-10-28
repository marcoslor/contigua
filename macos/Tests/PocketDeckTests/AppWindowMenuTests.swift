// The Dock shim's and the Deck cell's menu (WIN-26, WIN-27): New <App>
// Window ⌘N, then one "App — task" row per open window with the front one
// checked; a pick raises it. The disabled reasons are the exact sentences, and
// a disabled row sends nothing.

import XCTest
@testable import PocketDeck

@MainActor
final class AppWindowMenuTests: XCTestCase {
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

    func testTheRowsAreNewThenTheWindowsFrontToBack() {
        let a = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        let rows = fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg)
        XCTAssertEqual(rows.map(\.title), ["New Chrome Window", "Chrome — Mail", "Chrome — Docs"])
        XCTAssertEqual(rows.first?.key, "n")
        XCTAssertEqual(rows.first?.action, .newWindow)
        XCTAssertEqual(rows.dropFirst().map(\.stream), [b.stream, a.stream])
        XCTAssertEqual(rows.map(\.checked), [false, true, false],
                       "the front window's row is the checked one")
        XCTAssertTrue(rows.allSatisfy(\.enabled))
    }

    /// With no window open the menu is just the New item: no rule with nothing
    /// after it.
    func testWithNoWindowTheMenuIsTheNewItemOnly() {
        let rows = fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg)
        XCTAssertEqual(rows.map(\.title), ["New Chrome Window"])
    }

    func testAnAppThatOpensOneWindowCarriesItsSentence() {
        _ = fixture.open(MultiWindowFixture.settings)
        let rows = fixture.manager.windowMenuRows(pkg: MultiWindowFixture.settings.pkg)
        let new = try? XCTUnwrap(rows.first)
        XCTAssertEqual(new?.title, "New Settings Window")
        XCTAssertEqual(new?.enabled, false)
        XCTAssertEqual(new?.help, "Settings opens one window at a time.")
        XCTAssertNil(new?.key, "a disabled item shows no shortcut")
    }

    func testAtTheCapAndWhileReconnectingTheSentenceFollows() {
        fixture.manager.setMaxWindows(1)
        _ = fixture.open(taskLabel: "Docs")
        XCTAssertEqual(fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg).first?.help,
                       "Close a Chrome window to open another.")
        fixture.manager.setMaxWindows(4)
        fixture.manager.linkLost()
        XCTAssertEqual(fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg).first?.help,
                       "Reconnecting…")
        fixture.manager.linkRestored()
        XCTAssertNil(fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg).first?.help)
    }

    /// A pick of a window row raises that window and asks the phone for
    /// nothing; a pick of a disabled New row is not a pick at all (WIN-27).
    func testAPickRaisesAndADisabledRowSendsNothing() {
        let a = fixture.open(taskLabel: "Docs")
        let b = fixture.add(taskLabel: "Mail")!
        let rows = fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg)
        let opens = fixture.openRequests.count

        let docs = try? XCTUnwrap(rows.first { $0.title == "Chrome — Docs" })
        XCTAssertEqual(docs?.action, .raise(stream: a.stream))
        XCTAssertTrue(fixture.manager.pickWindowMenuRow(docs!, pkg: MultiWindowFixture.chrome.pkg))
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).first?.stream, a.stream)
        XCTAssertEqual(fixture.openRequests.count, opens, "raising sends nothing")

        XCTAssertNil(AppWindowMenu.pick("New Settings Window",
                                        in: fixture.manager.windowMenuRows(pkg: MultiWindowFixture.settings.pkg)),
                     "a disabled row is not a pick")
        XCTAssertEqual(fixture.openRequests.count, opens)
        XCTAssertEqual(b.stream, fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).last?.stream)
    }

    func testPickingNewAddsOneWindowWithNewInstance() {
        _ = fixture.open(taskLabel: "Docs")
        let rows = fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg)
        let opens = fixture.openRequests.count
        XCTAssertTrue(fixture.manager.pickWindowMenuRow(rows[0], pkg: MultiWindowFixture.chrome.pkg))
        XCTAssertEqual(fixture.openRequests.count, opens + 1)
        XCTAssertEqual(fixture.openRequests.last?["newInstance"] as? Bool, true)
    }

    /// The row a shim is sent is the same value, so the Dock menu and the Deck
    /// cell cannot disagree (the shim renders it; this is its wire shape).
    func testTheRowSurvivesTheMessageItTravelsIn() {
        _ = fixture.open(taskLabel: "Docs")
        for row in fixture.manager.windowMenuRows(pkg: MultiWindowFixture.chrome.pkg) {
            XCTAssertEqual(AppWindowMenuRow(message: row.message), row)
        }
    }
}
