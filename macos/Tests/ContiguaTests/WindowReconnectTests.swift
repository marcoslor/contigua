// A reconnect with several windows (WIN-34): one stream per window, in
// front-to-back order, with `newInstance` on every window but that app's first
// — the phone gives each its own task again.

import XCTest
@testable import Contigua

@MainActor
final class WindowReconnectTests: XCTestCase {
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

    func testAReconnectReopensEveryWindowFrontToBack() {
        let docs = fixture.open(taskLabel: "Docs")
        let mail = fixture.add(taskLabel: "Mail")!
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).map(\.stream),
                       [mail.stream, docs.stream], "Mail is in front")
        fixture.session.clearSent()

        fixture.manager.reopenAll()

        let opens = fixture.openRequests
        XCTAssertEqual(opens.count, 2, "one window.open per open window")
        XCTAssertEqual(opens.map { $0["stream"] as? Int }, [Int(mail.stream), Int(docs.stream)],
                       "front to back")
        XCTAssertNil(opens[0]["newInstance"], "the first reopened window takes the app's task")
        XCTAssertEqual(opens[1]["newInstance"] as? Bool, true,
                       "the rest ask for their own task")
    }

    /// Another app's windows reopen on their own count: each app has one window
    /// without `newInstance`.
    func testEachAppKeepsOneWindowOfItsOwn() {
        _ = fixture.open(taskLabel: "Docs")
        _ = fixture.add(taskLabel: "Mail")
        _ = fixture.open(MultiWindowFixture.settings)
        fixture.session.clearSent()

        fixture.manager.reopenAll()

        let opens = fixture.openRequests
        XCTAssertEqual(opens.count, 3)
        let settings = opens.filter { $0["pkg"] as? String == MultiWindowFixture.settings.pkg }
        let chrome = opens.filter { $0["pkg"] as? String == MultiWindowFixture.chrome.pkg }
        XCTAssertEqual(settings.count, 1)
        XCTAssertNil(settings.first?["newInstance"])
        XCTAssertEqual(chrome.filter { $0["newInstance"] as? Bool == true }.count, 1)
        XCTAssertEqual(chrome.filter { $0["newInstance"] == nil }.count, 1)
    }

    /// A window of a link or the phone view is reopened too, without a count of
    /// its own.
    func testTheOtherWindowKindsReopen() {
        _ = fixture.open(taskLabel: "Docs")
        _ = fixture.manager.openLink("https://example.com")
        fixture.session.clearSent()
        fixture.manager.reopenAll()
        XCTAssertEqual(fixture.session.sent("link.open").count, 1)
        XCTAssertEqual(fixture.openRequests.count, 1)
    }
}
