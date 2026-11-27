// MCP-50…53, MCP-102: the windows ledger — who opened each window, relative
// to the asker, and why and by whom it closed (plan T7).

import XCTest
@testable import Contigua

final class MCPWindowLedgerTests: XCTestCase {
    private let c1 = MCPClientID(1)
    private let c2 = MCPClientID(2)
    private let c3 = MCPClientID(3)

    // [MCP-51]
    func testOpenedByIsRelativeToTheAsker() {
        var ledger = MCPWindowLedger()
        ledger.opened(3, kind: .app, package: "com.a", by: .client(c1), now: 0)
        ledger.opened(4, kind: .app, package: "com.b", by: .person, now: 1)
        XCTAssertEqual(ledger.openedBy(3, asker: c1), "you")
        XCTAssertEqual(ledger.openedBy(4, asker: c1), "person")
        XCTAssertEqual(ledger.openedBy(3, asker: c2), "another_agent")
        ledger.opened(5, kind: .app, package: "com.c", by: .app, now: 2)
        XCTAssertEqual(ledger.openedBy(5, asker: c1), "app")
    }

    // [MCP-51]
    func testARaiseKeepsTheFirstOpener() {
        var ledger = MCPWindowLedger()
        ledger.opened(3, kind: .app, package: "com.a", by: .person, now: 0)
        ledger.opened(3, kind: .app, package: "com.a", by: .client(c1), now: 5)
        XCTAssertEqual(ledger.openedBy(3, asker: c1), "person")
        XCTAssertEqual(ledger.row(3, asker: c1, now: 7)?["openedAgoMs"] as? Int, 7000)
    }

    private func closeRecord(_ cause: MCPWindowLedger.Cause, asker: MCPClientID = MCPClientID(1))
        -> MCPWindowLedger.Closed? {
        var ledger = MCPWindowLedger()
        ledger.opened(3, kind: .app, package: "com.a", by: .client(c1), now: 0)
        ledger.closed(3, cause: cause, now: 10)
        return ledger.closeRecord(3, asker: asker, now: 12)
    }

    // [MCP-52] one assertion per mapping row of design/mcp.md "Windows and who opened them"
    func testEveryCloseKeepsItsReasonAndCloser() {
        typealias C = MCPWindowLedger.Closed
        XCTAssertEqual(closeRecord(.phone("app_exited")), C(reason: "app_exited", closedBy: "phone", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.phone("moved_to_phone")), C(reason: "moved_to_phone", closedBy: "phone", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.phone("requested")), C(reason: "phone_closed", closedBy: "phone", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.phone("error")), C(reason: "phone_closed", closedBy: "phone", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.mac(.client(c1))), C(reason: "closed", closedBy: "you", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.mac(.client(c1)), asker: c2), C(reason: "closed", closedBy: "another_agent", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.mac(.person)), C(reason: "closed", closedBy: "person", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.openFailed), C(reason: "open_failed", closedBy: "phone", closedAgoMs: 2000))
        XCTAssertEqual(closeRecord(.phoneSwitched), C(reason: "phone_switched", closedBy: "person", closedAgoMs: 2000))
    }

    // [MCP-52]
    func testAnAdoptedPackageStaysInRecentlyClosed_MCP52() {
        // S2: a link window learns the package that displays it after it
        // opened (`window.title`); the close record keeps it, not the nil the
        // ledger captured when the window was created.
        var ledger = MCPWindowLedger()
        ledger.opened(3, kind: .link, package: nil, by: .client(c1), now: 0)
        ledger.setPackage("com.example.browser", for: 3)
        ledger.closed(3, cause: .phone("app_exited"), now: 10)
        let closed = ledger.recentlyClosed(asker: c1, now: 12)
        XCTAssertEqual(closed.first?["package"] as? String, "com.example.browser")
        XCTAssertFalse(closed.first?["package"] is NSNull, "the close record kept the opening nil")
        XCTAssertEqual(ledger.closeRecord(3, asker: c1, now: 12)?.reason, "app_exited")

        // An empty package changes nothing, and a window the ledger does not
        // hold is left alone.
        var untouched = MCPWindowLedger()
        untouched.opened(4, kind: .handoff, package: "com.a", by: .person, now: 0)
        untouched.setPackage("", for: 4)
        untouched.setPackage("com.b", for: 9)
        untouched.closed(4, cause: .mac(.person), now: 10)
        XCTAssertEqual(untouched.recentlyClosed(asker: c1, now: 11).first?["package"] as? String, "com.a")
    }

    // [MCP-52]
    @MainActor
    func testAnAdoptedPackageReachesTheCloseRecordThroughTheWindow_MCP52() throws {
        // The real path (S2): send_link opens a link window with no package,
        // `window.title` adopts the app that displays it, and closing it keeps
        // the adopted package in `recentlyClosed` — not the nil it opened with.
        let fixture = MultiWindowFixture()
        let link = fixture.manager.openLink("https://example.com")
        let stream = link.stream
        XCTAssertNil(link.pkg)
        fixture.manager.handle(.windowTitle(stream: stream, label: "Browser",
                                            pkg: "com.example.browser", title: nil))
        XCTAssertEqual(link.pkg, "com.example.browser", "the window never adopted the package")

        link.window?.close()
        let now = ProcessInfo.processInfo.systemUptime
        let rows = fixture.manager.ledger.recentlyClosed(asker: c1, now: now)
        XCTAssertEqual(rows.first?["id"] as? Int, Int(stream))
        XCTAssertEqual(rows.first?["kind"] as? String, "link")
        XCTAssertEqual(rows.first?["package"] as? String, "com.example.browser")
        XCTAssertFalse(rows.first?["package"] is NSNull, "the close record kept the window's opening nil")
    }

    // [MCP-52]
    func testOnlyTheLast16ForTenMinutesAreKept() {
        var ledger = MCPWindowLedger()
        for id in UInt32(1)...17 {
            ledger.opened(id, kind: .app, package: "p", by: .person, now: 0)
            ledger.closed(id, cause: .mac(.person), now: 0)
        }
        let kept = ledger.recentlyClosed(asker: c1, now: 1)
        XCTAssertEqual(kept.count, 16)
        XCTAssertNil(ledger.closeRecord(1, asker: c1, now: 1))
        XCTAssertNotNil(ledger.closeRecord(17, asker: c1, now: 600))
        XCTAssertNil(ledger.closeRecord(17, asker: c1, now: 600.001))
        XCTAssertEqual(ledger.recentlyClosed(asker: c1, now: 600.001).count, 0)
    }

    // [MCP-50]
    func testRowsCarryKindOriginAgeAndState() {
        var ledger = MCPWindowLedger()
        ledger.opened(3, kind: .link, package: "com.a", by: .client(c1), now: 1)
        ledger.opened(4, kind: .mirror, package: nil, by: .person, now: 2)
        let row = ledger.row(3, asker: c1, now: 3.5)
        XCTAssertEqual(row?["kind"] as? String, "link")
        XCTAssertEqual(row?["openedBy"] as? String, "you")
        XCTAssertEqual(row?["openedAgoMs"] as? Int, 2500)
        XCTAssertEqual(ledger.row(4, asker: c1, now: 3)?["kind"] as? String, "mirror")
        ledger.closed(3, cause: .phone("app_exited"), now: 4)
        XCTAssertNil(ledger.row(3, asker: c1, now: 5))
        let closed = ledger.recentlyClosed(asker: c2, now: 5)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?["id"] as? Int, 3)
        XCTAssertEqual(closed.first?["kind"] as? String, "link")
        XCTAssertEqual(closed.first?["package"] as? String, "com.a")
        XCTAssertEqual(closed.first?["reason"] as? String, "app_exited")
        XCTAssertEqual(closed.first?["closedBy"] as? String, "phone")
        XCTAssertEqual(closed.first?["closedAgoMs"] as? Int, 1000)
        // A window the Mac never saw open still answers a row with a default
        // origin: the person's.
        XCTAssertEqual(ledger.openedBy(9, asker: c1), "person")
    }

    // [MCP-102]
    func testADisconnectedClientsWindowsStayOpenAndKeepTheirOpener() {
        var ledger = MCPWindowLedger()
        ledger.opened(3, kind: .app, package: "com.a", by: .client(c1), now: 0)
        ledger.clientGone(c1)
        XCTAssertNil(ledger.closeRecord(3, asker: c2, now: 1))
        XCTAssertNotNil(ledger.row(3, asker: c2, now: 1))
        XCTAssertEqual(ledger.openedBy(3, asker: c2), "another_agent")
        XCTAssertEqual(ledger.openedBy(3, asker: c3), "another_agent")
    }
}
