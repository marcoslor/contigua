// MCPToolHost's pure decisions (docs/design/mcp.md).

import XCTest
@testable import Contigua

final class MCPToolHostTests: XCTestCase {

    // [MCP-33]
    func testNoAppListYetIsNotReady() {
        XCTAssertThrowsError(try MCPToolHost.appsAnswer([])) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .notReady)
            XCTAssertEqual((error as? MCPToolError)?.message,
                           "The phone's app list has not arrived yet; try again in a few seconds.")
        }
        XCTAssertThrowsError(try MCPToolHost.chooseApp("Settings", in: [])) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .notReady)
        }
        let apps = [AppInfo(json: ["pkg": "com.android.settings", "label": "Settings"])!]
        XCTAssertEqual(try MCPToolHost.chooseApp("Settings", in: apps).pkg, "com.android.settings")
        let answer = try? MCPToolHost.appsAnswer(apps)
        XCTAssertEqual((answer?["apps"] as? [[String: String]])?.first?["package"], "com.android.settings")
    }

    /// MCP-40 (#183): newWindow for an app that already has a window and opens
    /// one at a time fails naming the flag, and never sends the client to
    /// list_windows and a retry.
    func testMCP40NewWindowOnASingleWindowAppNamesTheFlag() {
        let error = MCPToolHost.newWindowRefusal(app: "Settings", windowCount: 1, blocker: .oneWindow)
        XCTAssertEqual(error?.code, .failed)
        XCTAssertEqual(error?.message,
                       "Settings does not open several windows at once; call open_app without newWindow to bring its window forward.")
        XCTAssertFalse(error?.message.contains("list_windows") ?? true)
        XCTAssertNil(MCPToolHost.newWindowRefusal(app: "Settings", windowCount: 0, blocker: .oneWindow),
                     "with no window open the flag opens the first one")
        XCTAssertNil(MCPToolHost.newWindowRefusal(app: "Chrome", windowCount: 1, blocker: nil))
    }
}
