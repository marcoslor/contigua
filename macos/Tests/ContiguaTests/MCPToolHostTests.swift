// MCPToolHost's pure decisions (docs/design/mcp.md), and `type_text` end to
// end through the dispatcher, a real ConnectionController and the fake phone
// server (plan T13).

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

    // MARK: type_text goes through ui.type (plan T13)

    /// `type_text {window, text: "café", clear: true, submit: true}` goes to
    /// the phone as one `ui.type` with the text, `clear` and `submit`, and no
    /// `text` message; `did` says how it typed and never the text; the tool's
    /// log line carries no text ([MCP-92], [MCP-109]).
    @MainActor
    func testTypeTextAnswersHowItTyped() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        let text = "caf\u{E9}"
        let (answer, logLines) = await fixture.call("type_text", [
            "window": Int(window.stream), "text": text, "clear": true, "submit": true,
        ])

        let types = fixture.sent("ui.type")
        XCTAssertEqual(types.count, 1, "one ui.type: \(fixture.sentTypes())")
        let sent = try XCTUnwrap(types.first)
        XCTAssertEqual(sent.int("stream"), Int(window.stream))
        XCTAssertNotNil(sent.int("seq"))
        XCTAssertEqual(sent.string("text"), text)
        XCTAssertEqual(sent.bool("clear"), true)
        XCTAssertEqual(sent.bool("submit"), true)
        XCTAssertTrue(fixture.sent("text").isEmpty, "type_text sent a text message")

        XCTAssertEqual(answer["isError"] as? Bool, false, "type_text failed: \(answer)")
        let structured = try XCTUnwrap(answer["structuredContent"] as? [String: Any])
        let did = try XCTUnwrap(structured["did"] as? [String: Any])
        XCTAssertEqual(did as NSDictionary, [
            "action": "type", "characters": 4, "clear": true, "submit": true,
            "entry": "replaced", "via": "set_text",
        ] as NSDictionary)

        XCTAssertEqual(logLines.count, 1)
        for line in logLines {
            XCTAssertFalse(line.contains(text), "the log line carried the text: \(line)")
            XCTAssertFalse(line.contains("caf"), "the log line carried the text: \(line)")
        }
    }

    /// No tool reads or writes the Mac's pasteboard or the phone's clipboard:
    /// the general pasteboard's change count is the same after a `type_text`,
    /// and the call sent no `clip.set` and no `text` (the path that pastes
    /// through the phone's clipboard) ([MCP-110]).
    @MainActor
    func testTypeTextNeverTouchesThePasteboard() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        let before = NSPasteboard.general.changeCount
        let (answer, _) = await fixture.call("type_text", ["window": Int(window.stream), "text": "t\u{E9}rmica"])
        XCTAssertEqual(NSPasteboard.general.changeCount, before, "type_text touched the Mac's pasteboard")
        XCTAssertEqual(answer["isError"] as? Bool, false, "type_text failed: \(answer)")
        XCTAssertEqual(fixture.sent("ui.type").count, 1, "type_text sent no ui.type: \(fixture.sentTypes())")
        XCTAssertTrue(fixture.sent("clip.set").isEmpty, "type_text sent a clip.set")
        XCTAssertTrue(fixture.sent("text").isEmpty, "type_text sent a text message")
    }
}

/// A real controller online with the fake phone server, which answers
/// `ui.type` (entry `replaced` with `clear`, else `inserted`; via `set_text`),
/// `ui.settle` (settled) and `ui.tree` (no nodes), and records what the Mac
/// sent from the moment a call starts.
@MainActor
private final class TypeTextFixture {
    let server: FakeServer
    let brain: FakeV2PhoneBrain
    let controller: ConnectionController
    let profile: Profile
    private let lock = NSLock()
    nonisolated(unsafe) private var received: [JSONMessage] = []

    init() throws {
        // A window's open edits the main menu: the app object must exist.
        _ = NSApplication.shared
        profile = Profile(name: "unit-typetext-\(UUID().uuidString.prefix(8).lowercased())")!
        controller = ConnectionController(options: LaunchOptions.parse(["Contigua"]), profile: profile)
        controller.connectTimeout = 0.4
        controller.pairingTimeout = 30
        server = try FakeServer(trustingClientPem: controller.identity.certPem)
        brain = FakeV2PhoneBrain(identity: server.phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        server.onFrame = { [weak self] connection, frame in
            guard frame.messageType == .json,
                  let message = JSONFrame.decode(payload: frame.payload) else { return }
            self?.record(message)
            Self.answer(message, on: connection)
        }
    }

    nonisolated private func record(_ message: JSONMessage) {
        lock.lock(); received.append(message); lock.unlock()
    }

    nonisolated private static func answer(_ message: JSONMessage, on connection: FakeServer.Connection) {
        guard let stream = message.int("stream"), let seq = message.int("seq") else { return }
        switch message.t {
        case "ui.type":
            let clear = message.bool("clear") == true
            connection.sendJSON(["t": "ui.type", "stream": stream, "seq": seq, "ok": true,
                                 "entry": clear ? "replaced" : "inserted", "via": "set_text",
                                 "characters": message.string("text")?.unicodeScalars.count ?? 0])
        case "ui.settle":
            connection.sendJSON(["t": "ui.settle", "stream": stream, "seq": seq, "ok": true,
                                 "settled": true, "waitedMs": 300, "events": 0])
        case "ui.tree":
            connection.sendJSON(["t": "ui.tree", "stream": stream, "seq": seq, "ok": true,
                                 "displayId": 2, "size": [1080, 2340], "layers": [], "nodes": []])
        default:
            break
        }
    }

    func close() {
        controller.shutdown()
        server.stop()
        if let suite = profile.defaultsSuiteName { profile.defaults.removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
    }

    /// Polls while yielding the main actor, so the controller's own main-actor
    /// work runs (an async test cannot spin the run loop for it).
    private func wait(until condition: () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// Online, with one app window that has had its first frame.
    func liveWindow() async throws -> StreamWindowController {
        controller.connectManually(host: "127.0.0.1", port: server.port)
        let asked = await wait { self.brain.sawPairRequest }
        XCTAssertTrue(asked, "never asked to pair: \(controller.link)")
        let online = await wait { self.controller.link.isOnline }
        XCTAssertTrue(online, "not online: \(controller.link)")
        let window = controller.windows.openOrRaise(pkg: "com.android.settings")
        window.noteFirstFrame()
        XCTAssertEqual(window.mcpLifecycle, .live)
        return window
    }

    /// One `tools/call` through the dispatcher and the host: the JSON-RPC
    /// `result`, and the log lines the dispatcher's hook formatted.
    func call(_ name: String, _ arguments: [String: Any]) async -> ([String: Any], [String]) {
        lock.lock(); received.removeAll(); lock.unlock()
        let host = MCPToolHost(controller: controller)
        let lines = LogLines()
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        let line = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        let data = await MCPDispatcher.handle(line: line, client: MCPClientID(1), perform: { call, client in
            await host.perform(call, client: client)
        }, log: { tool, seconds, code, window in
            lines.all.append(MCPLogLine.format(tool: tool, duration: seconds, code: code, window: window))
        })
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return ((object?["result"] as? [String: Any]) ?? object ?? [:], lines.all)
    }

    func sent(_ type: String) -> [JSONMessage] {
        lock.lock(); defer { lock.unlock() }
        return received.filter { $0.t == type }
    }

    func sentTypes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return received.map(\.t)
    }
}

/// The dispatcher's log hook's lines, in order.
private final class LogLines: @unchecked Sendable {
    var all: [String] = []
}
