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
}
