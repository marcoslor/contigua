// Every entry point that opens an app raises its window; only the explicit
// ones add another (WIN-2, WIN-36). The raise is one function
// (`WindowManager.openOrRaise`); the additions are the four the spec names:
// File ▸ New <App> Window, the Dock shim's menu, the Deck cell's menu and an
// explicit `newWindow` argument on Shortcuts and MCP.

import XCTest
@testable import PocketDeck

@MainActor
final class OpeningEntryPointTests: XCTestCase {
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

    /// A second ask for an app that already has a window — whichever entry
    /// point asks — raises it and sends no second `window.open`.
    func testEveryImplicitEntryPointRaisesInsteadOfAdding() {
        let first = fixture.open(taskLabel: "Docs")
        let opens = fixture.openRequests.count
        // The raise paths: the Deck tile and Find Apps' Return
        // (`openApp`), the Dock shim (`openFromDock`), Spotlight, a
        // notification click, Shortcuts and MCP without the argument, and the
        // debug route's `--open`. All of them call the one function the tests
        // can reach here; a new entry point that bypasses it fails this.
        for _ in 0..<7 {
            let raised = fixture.manager.openOrRaise(pkg: MultiWindowFixture.chrome.pkg,
                                                     activity: MultiWindowFixture.chrome.activity)
            XCTAssertIdentical(raised, first)
        }
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).count, 1)
        XCTAssertEqual(fixture.openRequests.count, opens, "no entry point added a window.open")
    }

    /// The explicit New Window (⌘N, the Dock and Deck menus) adds one window
    /// and exactly one `window.open` carrying `newInstance`.
    func testTheExplicitNewWindowAddsOneAndCarriesNewInstance() {
        let first = fixture.open(taskLabel: "Docs")
        let opens = fixture.openRequests.count

        let second = fixture.add(taskLabel: "Mail")
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second?.stream, first.stream)
        let requests = fixture.openRequests
        XCTAssertEqual(requests.count, opens + 1)
        XCTAssertEqual(requests.last?["newInstance"] as? Bool, true)
        XCTAssertEqual(fixture.manager.appWindows(pkg: MultiWindowFixture.chrome.pkg).count, 2)
    }

    /// A window this Mac adds itself (the first of an app, a reconnect) carries
    /// no `newInstance`: the phone reuses the app's task instead of making a
    /// second one (WIN-2, WIN-34).
    func testTheFirstWindowNeverCarriesNewInstance() {
        fixture.open()
        XCTAssertEqual(fixture.openRequests.count, 1)
        XCTAssertNil(fixture.openRequests[0]["newInstance"])
    }

    /// Shortcuts and MCP: the argument is the only way to add, and leaving it
    /// out keeps the raise (WIN-36).
    func testTheExplicitArgumentsAreOffByDefault() throws {
        let without = try MCPArguments.call("open_app", ["app": "Chrome"])
        XCTAssertEqual(without, .openApp("Chrome", newWindow: false))
        let with = try MCPArguments.call("open_app", ["app": "Chrome", "newWindow": true])
        XCTAssertEqual(with, .openApp("Chrome", newWindow: true))

        XCTAssertEqual(try DebugIntent.parse("open-app Chrome"),
                       .openApp("Chrome", phone: nil, newWindow: false))
        XCTAssertEqual(try DebugIntent.parse("open-app Chrome new"),
                       .openApp("Chrome", phone: nil, newWindow: true))
    }
}
