// MCP-21: every window lifecycle state answers one closed token.

import XCTest
@testable import Contigua

final class MCPWindowStateTests: XCTestCase {

    // [MCP-21]
    func testEveryLifecycleStateHasOneToken() {
        let cases: [(MCPWindowState.Lifecycle, String)] = [
            (.opening, "opening"), (.live, "live"), (.paused, "paused"), (.stalled, "stalled"),
            (.linkDown, "offline"), (.reconnecting, "offline"), (.offline, "offline"),
            (.closed, "closed"),
        ]
        for (state, token) in cases {
            XCTAssertEqual(MCPWindowState.token(state), token, "\(state)")
        }
    }

    /// [MCP-21] A link window has no opening cover, so its lifecycle never
    /// reached `opening`; its state token (and `list_windows`) said `live`
    /// before every answer's `state` says `opening`, and the first frame
    /// makes it `live` (#255).
    @MainActor
    func testALinkWindowReadsOpeningUntilItsFirstFrame_MCP21() throws {
        _ = NSApplication.shared
        let profile = Profile(name: "unit-mcpstate-\(UUID().uuidString.prefix(8).lowercased())")!
        let controller = ConnectionController(options: LaunchOptions.parse(["Contigua"]), profile: profile)
        defer {
            controller.shutdown()
            if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
        }

        let stream = try IntentsBridge.openLinkWindow("https://example.com", controller: controller)
        let window = try XCTUnwrap(controller.windows.controller(for: stream))
        let host = MCPToolHost(controller: controller, client: MCPClientID(1))

        XCTAssertEqual(host.stateToken(for: window), "opening",
                       "a window with no first frame reads opening, not live")
        let rows = host.listWindows()["windows"] as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["id"] as? Int, Int(stream))
        XCTAssertEqual(rows.first?["state"] as? String, "opening", "list_windows says opening too")

        // The phone's first frame, the way WindowManager delivers it.
        window.frameClock.note()
        XCTAssertEqual(controller.windows.markFirstFrame(stream: stream, hasWindow: true), true)
        window.noteFirstFrame()
        XCTAssertEqual(host.stateToken(for: window), "live", "the first frame makes it live")
        let after = host.listWindows()["windows"] as? [[String: Any]] ?? []
        XCTAssertEqual(after.first?["state"] as? String, "live")

        // A live window keeps its own state: paused while the stream is held.
        window.setPaused(true)
        XCTAssertEqual(host.stateToken(for: window), "paused")
        window.setPaused(false)
        XCTAssertEqual(host.stateToken(for: window), "live")

        // And a window that closes is closed, not opening.
        window.closeFromRemote()
        XCTAssertEqual(host.stateToken(for: window), "closed")
    }
}
