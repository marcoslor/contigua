// MCP-6 / MCP-70: every failure a tool can meet maps to exactly one of the
// closed codes, and its answer is JSON a program can switch on.

import XCTest
@testable import Contigua

final class MCPToolErrorTests: XCTestCase {

    private func body(_ result: MCPToolResult) throws -> [String: Any] {
        let line = MCPDispatcher.resultBody(result)
        return line
    }

    // [MCP-6]
    func testEveryFailureMapsToOneClosedCode() {
        XCTAssertEqual(MCPErrorCode.allCases.count, 17)
        XCTAssertEqual(Set(MCPErrorCode.allCases.map(\.rawValue)), [
            "no_phone", "phone_offline", "no_window", "not_ready", "stale_ref", "off_screen",
            "covered", "no_field", "not_found", "ambiguous", "too_many_windows", "bad_url",
            "bad_file", "no_frame", "not_supported", "timeout", "failed",
        ])
        struct Other: Error {}
        let table: [(Error, MCPErrorCode)] = [
            (IntentFailure.phoneNotConnected, .phoneOffline),
            (IntentFailure.phoneNotReady, .phoneOffline),
            (IntentFailure.noPhone, .noPhone),
            (IntentFailure.unknownPhone("x"), .noPhone),
            (IntentFailure.appNotFound("Calc"), .notFound),
            (IntentFailure.severalApps("C"), .ambiguous),
            (IntentFailure.badLink, .badURL),
            (IntentFailure.fileMissing("a"), .badFile),
            (IntentFailure.fileUnreadable("a"), .badFile),
            (UITreeError.timedOut, .timeout),
            (UITreeError.notConnected, .phoneOffline),
            (MCPToolError.noWindow(9), .noWindow),
            (MCPToolError.noFrame(window: 3, state: "live"), .noFrame),
            (Other(), .failed),
        ]
        for (error, code) in table {
            XCTAssertEqual(MCPToolError.mapping(error, phone: "Pixel").code, code, "\(error)")
        }

        // Every sentence names the next step a model can take.
        let notInUse = MCPToolError.mapping(IntentFailure.choosePhone(["A", "B"]), phone: nil)
        XCTAssertEqual(notInUse.code, .noPhone)
        XCTAssertEqual(notInUse.message,
                       "No phone is in use: 2 phones are paired and none is connected. Connect one in Contigua, then call phone_status.")
        XCTAssertEqual(MCPToolError.mapping(IntentFailure.noPhone, phone: nil).message,
                       "No phone is paired with Contigua. Pair one in Contigua's Settings, then try again.")
        let several = MCPToolError.mapping(IntentFailure.severalApps("C"), phone: nil)
        // list_apps takes no query until T9 (MCP-33 target): never name an argument that does not exist.
        XCTAssertEqual(several.message, "Several apps match \"C\". Call list_apps and pass one package as app.")
        XCTAssertEqual(MCPToolError.mapping(IntentFailure.appNotFound("Calc"), phone: nil).message,
                       "No app on the phone matches \"Calc\". Call list_apps and pass its package as app.")
        XCTAssertEqual(MCPToolError.mapping(Other(), phone: nil).message,
                       "Contigua could not do that. Try again; if it keeps failing, check phone_status.")

        // #162's ref refusals keep their sentences; all but the off-screen
        // one are stale_ref with the window's latest snapshot.
        let older = MCPToolError.tapRefusal(.stale(ref: "s1e4", snapshot: 1, latest: 2),
                                            ref: "s1e4", window: 3)
        XCTAssertEqual(older?.code, .staleRef)
        XCTAssertEqual(older?.message, UITreeRefusal.stale(ref: "s1e4", snapshot: 1, latest: 2))
        XCTAssertEqual(older?.extra["snapshot"] as? Int, 2)
        XCTAssertEqual(older?.extra["ref"] as? String, "s1e4")
        XCTAssertEqual(older?.extra["window"] as? Int, 3)
        let never = MCPToolError.tapRefusal(.stale(ref: "s2e99", snapshot: 2, latest: 2),
                                            ref: "s2e99", window: 3)
        XCTAssertEqual(never?.code, .staleRef)
        XCTAssertEqual(never?.message, UITreeRefusal.stale(ref: "s2e99", snapshot: 2, latest: 2))
        let none = MCPToolError.tapRefusal(.noTree, ref: "s1e1", window: 3)
        XCTAssertEqual(none?.code, .staleRef)
        XCTAssertEqual(none?.message, UITreeRefusal.noTree("s1e1"))
        let off = MCPToolError.tapRefusal(
            .placed(snapshot: 2, placed: .init(point: nil, box: [0, 0, 1, 1], off: true)),
            ref: "s2e5", window: 3)
        XCTAssertEqual(off?.code, .offScreen)
        XCTAssertEqual(off?.message, UITreeRefusal.offScreen("s2e5"))
        let on = MCPToolError.tapRefusal(
            .placed(snapshot: 2, placed: .init(point: .init(x: 0.5, y: 0.5), box: nil, off: false)),
            ref: "s2e6", window: 3)
        XCTAssertNil(on, "a ref that resolves is not a failure")

        let ambiguous = MCPToolError.ambiguous("C", matches: [
            AppInfo(json: ["pkg": "a.calc", "label": "Calc"])!, AppInfo(json: ["pkg": "a.cam", "label": "Camera"])!,
        ])
        XCTAssertEqual(ambiguous.code, .ambiguous)
        XCTAssertEqual((ambiguous.extra["matches"] as? [[String: String]])?.count, 2)
    }

    // [MCP-6]
    func testAFailureIsJSONWithCodeAndSentence() throws {
        let failure = MCPToolError(.noWindow, "No window 9. Call list_windows to see what is open.",
                                   ["window": 9])
        let result = try body(.failure(failure))
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNil(result["structuredContent"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        let text = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertEqual(text,
            #"{"error":{"code":"no_window","message":"No window 9. Call list_windows to see what is open.","window":9}}"#)
        XCTAssertEqual(MCPToolError.noWindow(9).message,
                       "No window 9. Call list_windows to see what is open.")
    }

    // [MCP-70]
    @MainActor
    func testTreeFailuresMapToClosedCodes() async throws {
        let table: [(String, MCPErrorCode)] = [
            ("no_window", .noWindow), ("not_available", .notSupported),
            ("no_a11y", .notSupported), ("no_display", .notReady),
            ("busy", .failed), ("failed", .failed),
        ]
        for (phoneCode, code) in table {
            let failure = MCPToolError.uiTreeFailed(code: phoneCode, message: "The phone said so.",
                                                    window: 3, phone: "Pixel")
            XCTAssertEqual(failure.code, code, phoneCode)
        }
        // The Mac has the window, but its display has nothing to read yet (an
        // app still opening, seen on the emulator right after open_app): that
        // is "try again", never "no window" (MCP-70).
        let empty = MCPToolError.uiTreeFailed(code: "no_display", message: nil, window: 3, phone: "Pixel")
        XCTAssertEqual(empty.message,
                       "Window 3 has nothing on screen to read yet: its app may still be opening. Try again in a moment.")
        XCTAssertEqual(empty.extra["window"] as? Int, 3)
        // A silent phone, through the read's real deadline.
        let broker = UITreeBroker()
        do {
            _ = try await broker.read(stream: 3, timeout: UITreeBroker.deadline, send: { _ in })
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(MCPToolError.mapping(error, phone: "Pixel").code, .timeout)
        }
        XCTAssertEqual(UITreeBroker.deadline, 5)
    }

    // [MCP-5] The text mirror is JSON: escapes, booleans apart from 1,
    // shortest numbers, and nil as null.
    func testMCPJSONWritesValidShortestJSON() throws {
        let missing: Int? = nil
        let value: [String: Any] = [
            "s": "a\u{1}\u{8}\"\\\n/",
            "flags": [true, 1, false, 0] as [Any],
            "x": 0.651,
            "whole": 3.0,
            "tiny": 1e-7,
            "null": NSNull(),
            "missing": missing as Any,
        ]
        let text = MCPJSON.string(value)
        XCTAssertEqual(text, #"{"flags":[true,1,false,0],"missing":null,"null":null,"s":"a\u0001\b\"\\\n/","tiny":1e-07,"whole":3,"x":0.651}"#)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(back["tiny"] as? Double, 1e-7)
        XCTAssertEqual(back["s"] as? String, "a\u{1}\u{8}\"\\\n/")
    }

    // [MCP-71] T10: a ref the phone finds gone keeps S1's sentence shape.
    func testAGoneRefKeepsS1sSentenceShape() {
        let error = MCPToolError.pressRefusal(code: "gone", ref: "e12", window: 3, latestSnapshot: 6,
                                              expect: "Item 3", now: nil, coveredBy: nil)
        XCTAssertEqual(error.code, .staleRef)
        XCTAssertEqual(error.message,
                       "e12 is no longer on window 3; its latest tree is snapshot 6. Use a ref from snapshot 6, or call ui_tree.")
    }
}

extension MCPToolErrorTests {
    // [MCP-53]
    func testAClosedWindowSaysWhyItClosed() {
        let closed = MCPWindowLedger.Closed(reason: "app_exited", closedBy: "phone", closedAgoMs: 3000)
        let error = MCPToolError.noWindow(4, closed: closed)
        XCTAssertEqual(error.code, .noWindow)
        let object = error.object["error"] as? [String: Any]
        XCTAssertEqual(object?["window"] as? Int, 4)
        let record = object?["closed"] as? [String: Any]
        XCTAssertEqual(record?["reason"] as? String, "app_exited")
        XCTAssertEqual(record?["closedBy"] as? String, "phone")
        XCTAssertEqual(record?["closedAgoMs"] as? Int, 3000)
        XCTAssertEqual(error.message,
                       "Window 4 closed 3 s ago: the app exited. Call list_windows to see what is open.")
    }
}
