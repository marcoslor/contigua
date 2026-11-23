// MCP-52, MCP-83: the phone's `window.closed` reasons map to MCP's closed set.

import XCTest
@testable import Contigua

final class MCPCloseReasonTests: XCTestCase {
    func testRequestedAndErrorArePhoneClosed_MCP52() {
        XCTAssertEqual(MCPCloseReason.token(phone: "requested"), "phone_closed")
        XCTAssertEqual(MCPCloseReason.token(phone: "error"), "phone_closed")
        XCTAssertEqual(MCPCloseReason.token(phone: "app_exited"), "app_exited")
        XCTAssertEqual(MCPCloseReason.token(phone: "moved_to_phone"), "moved_to_phone")
    }

    /// MCP-52: a stream the Mac closed is `closed`, by the person or an agent.
    func testTheMacsOwnCloseIsClosed_MCP52() {
        XCTAssertEqual(MCPCloseReason.mac(byAgent: false), MCPActMachine.Closed(reason: "closed", by: "person"))
        XCTAssertEqual(MCPCloseReason.mac(byAgent: true), MCPActMachine.Closed(reason: "closed", by: "agent"))
    }
}
