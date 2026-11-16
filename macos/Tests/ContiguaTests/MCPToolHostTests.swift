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
}
