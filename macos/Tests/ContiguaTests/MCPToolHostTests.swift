// MCPToolHost's pure decisions (docs/design/mcp.md).

import AppKit
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
    // MARK: T6: opens answer like actions

    @MainActor
    private func offlineController() -> (ConnectionController, Profile) {
        _ = NSApplication.shared
        let profile = Profile(name: "unit-mcpopen-\(UUID().uuidString.prefix(8).lowercased())")!
        let controller = ConnectionController(options: LaunchOptions.parse(["Contigua"]), profile: profile)
        return (controller, profile)
    }

    @MainActor
    private func dispose(_ controller: ConnectionController, _ profile: Profile) {
        controller.shutdown()
        if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
    }

    private func code(_ result: MCPToolResult) -> MCPErrorCode? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    /// [MCP-42] An MCP open never leaves a pending open behind: with the phone
    /// paired but offline, each open fails `phone_offline` and nothing queues;
    /// with no phone paired it fails `no_phone`.
    @MainActor
    func testOfflineOpensQueueNothing_MCP42() async throws {
        let (controller, profile) = offlineController()
        defer { dispose(controller, profile) }
        let host = MCPToolHost(controller: controller)
        let client = MCPClientID(1)

        let unpaired = await host.perform(.openApp("Settings", newWindow: false), client: client)
        XCTAssertEqual(code(unpaired), .noPhone)

        controller.remembered.remember(PhoneRef(id: "mcp-open-1", name: "Pixel 9", model: "Pixel 9"))
        XCTAssertFalse(controller.link.isOnline)
        let open = await host.perform(.openApp("Settings", newWindow: false), client: client)
        XCTAssertEqual(code(open), .phoneOffline)
        XCTAssertNil(controller.pendingOpen, "open_app queued an open")
        let link = await host.perform(.sendLink("https://example.com"), client: client)
        XCTAssertEqual(code(link), .phoneOffline)
        XCTAssertNil(controller.pendingLink, "send_link queued a link")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-open-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 64).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let drop = await host.perform(.sendFile(file.path), client: client)
        XCTAssertEqual(code(drop), .phoneOffline)
        XCTAssertNil(controller.pendingDrop, "send_file queued a drop")
        XCTAssertTrue(controller.windows.openStreams.isEmpty, "an offline open made a window")
    }

    /// [MCP-43] `send_link` answers the window `WindowManager.openLink`
    /// allocated, as a `link` window; the phone's `launch_failed` fails
    /// `failed` naming that window.
    @MainActor
    func testSendLinkAnswersTheWindowItOpened_MCP43() throws {
        let (controller, profile) = offlineController()
        defer { dispose(controller, profile) }
        let stream = try IntentsBridge.openLinkWindow("https://example.com", controller: controller)
        XCTAssertTrue(controller.windows.controller(for: stream) is LinkWindowController)
        XCTAssertEqual(controller.windows.openStreams, [stream])
        let rows = MCPToolHost(controller: controller, client: MCPClientID(1)).listWindows()["windows"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["id"] as? Int, Int(stream))
        XCTAssertEqual(rows.first?["kind"] as? String, "link")
        XCTAssertThrowsError(try IntentsBridge.openLinkWindow("ftp://example.com", controller: controller)) { error in
            XCTAssertEqual(MCPToolError.mapping(error, phone: nil).code, .badURL)
        }
        XCTAssertEqual(controller.windows.openStreams, [stream], "a refused URL opens nothing")

        let failed = MCPOpenAnswer.failure(code: "launch_failed", window: Int(stream))
        XCTAssertEqual(failed.code, .failed)
        XCTAssertEqual(failed.extra["window"] as? Int, Int(stream))
        XCTAssertTrue(failed.message.contains("window \(stream)"), failed.message)
    }

    /// [MCP-44] `send_file` waits for the phone's `drop.result` (30 s at most):
    /// delivered with its bytes, still `sending` at the bound, or `failed`
    /// with the phone's sentence; never the file's name or path.
    @MainActor
    func testSendFileWaitsForTheDropResult_MCP44() async throws {
        XCTAssertEqual(MCPDropWait.bound, .seconds(30))

        let delivered = MCPDropWait()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200)) // real-time: the phone's drop.result lands 200 ms after the wait starts
            delivered.ended(ok: true, sentence: nil)
        }
        let outcome = await delivered.wait(bound: .seconds(30))
        XCTAssertEqual(outcome, .delivered)
        let answer = try MCPToolHost.sendFileAnswer(bytes: 1_048_576, outcome)
        XCTAssertEqual(answer["bytes"] as? Int, 1_048_576)
        XCTAssertEqual(answer["state"] as? String, "delivered")
        XCTAssertEqual(Set(answer.keys), ["bytes", "state"], "no name or path")

        let silent = MCPDropWait()
        let late = await silent.wait(bound: .milliseconds(150))
        XCTAssertEqual(late, .sending)
        XCTAssertEqual(try MCPToolHost.sendFileAnswer(bytes: 10, late)["state"] as? String, "sending")

        let refused = MCPDropWait()
        refused.ended(ok: false, sentence: "Storage is full.")
        let no = await refused.wait(bound: .seconds(30))
        XCTAssertEqual(no, .failed("Storage is full."))
        XCTAssertThrowsError(try MCPToolHost.sendFileAnswer(bytes: 10, no)) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .failed)
            XCTAssertTrue((error as? MCPToolError)?.message.contains("Storage is full.") ?? false)
        }
    }
}
