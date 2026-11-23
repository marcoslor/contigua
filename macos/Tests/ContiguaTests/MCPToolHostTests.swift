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

    /// [MCP-41] [MCP-100] A new window's `size` is the display the phone made
    /// (`window.opened`'s `w`×`h`), known as soon as the phone answers: an
    /// open whose first frame has not arrived answers that size with
    /// `state: "opening"`, never `[0, 0]`. A raised window answers the size
    /// its stream already has.
    @MainActor
    func testAnOpenWithNoFrameAnswersTheOpenedSize_MCP41_MCP100() throws {
        let (controller, profile) = offlineController()
        defer { dispose(controller, profile) }
        let window = controller.windows.openOrRaise(pkg: "com.android.settings")
        let stream = window.stream
        let host = MCPToolHost(controller: controller, client: MCPClientID(1))
        controller.windows.handle(.windowOpened(stream: stream, displayId: 2, width: 576, height: 1280,
                                                started: .moved))
        XCTAssertEqual(host.stateToken(for: window), "opening", "the first frame has not arrived")

        let bound = MCPActMachine.Answer(settle: .init(state: "not_ready"), state: "opening")
        let answer = host.openAnswer(stream, kind: .app, opened: .new, result: bound, lastFrame: nil)
        XCTAssertEqual(answer["size"] as? [Int], [576, 1280])
        XCTAssertEqual(answer["state"] as? String, "opening")
        XCTAssertEqual((answer["settle"] as? [String: Any])?["state"] as? String, "not_ready")

        let raised = host.openAnswer(stream, kind: .app, opened: .raised, result: bound, lastFrame: nil)
        let has = host.pixelSize(of: window)
        XCTAssertEqual(raised["size"] as? [Int], [has.0, has.1], "a raise answers the stream it has")
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

    // MARK: phone_status (plan T8)

    private final class TestClock {
        var now = ContinuousClock.now
    }

    private func input(phone: MCPStatusPhone?, foreground: FrontRead?,
                       apps: [AppInfo] = []) -> MCPStatusInput {
        MCPStatusInput(connected: phone != nil, name: phone == nil ? nil : "My phone",
                       battery: phone == nil ? nil : 81, charging: false, windows: 2, maxWindows: 4,
                       phone: phone, foreground: foreground, apps: apps)
    }

    // [MCP-31]
    func testStatusSaysWhatLockedMeans() throws {
        let now = ContinuousClock.now
        let phone = MCPStatusPhone(locked: true, screen: .off, lockSource: .keyguardListener,
                                   lockChangedAt: now - .seconds(360))
        let answer = MCPToolHost.statusAnswer(input(phone: phone, foreground: FrontRead.none), now: now)
        XCTAssertEqual(answer["locked"] as? Bool, true)
        XCTAssertEqual(answer["screen"] as? String, "off")
        XCTAssertEqual(answer["lockSource"] as? String, "keyguard_listener")
        XCTAssertEqual(answer["lockChangedAgoMs"] as? Int, 360000)
        XCTAssertEqual(answer["maxWindows"] as? Int, 4)
        XCTAssertEqual(answer["input"] as? String,
                       "App windows take input whether or not the phone is locked; the Phone Mirror shows the lock screen until the person unlocks it.")

        let none = MCPToolHost.statusAnswer(input(phone: nil, foreground: nil), now: now)
        XCTAssertTrue(none["locked"] is NSNull, "no phone: locked must be null, got \(String(describing: none["locked"]))")
        XCTAssertTrue(none["screen"] is NSNull, "no phone: screen must be null")
        XCTAssertTrue(none["foreground"] is NSNull)
        XCTAssertNil(none["foregroundError"])
        XCTAssertEqual(none["connected"] as? Bool, false)
    }

    // [MCP-32]
    @MainActor
    func testStatusNamesTheForegroundApp() async throws {
        let clock = TestClock()
        let gate = FrontReadGate(now: { clock.now })
        var sent: [Int] = []
        gate.send = { sent.append($0) }
        let browser = AppInfo(json: ["pkg": "org.example.browser", "label": "Browser"])!
        let phone = MCPStatusPhone(locked: false, screen: .on, lockSource: .initialRead,
                                   lockChangedAt: clock.now)

        // A package the app list knows: its label.
        let first = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 1, "one task.front per status call")
        gate.reply(seq: try XCTUnwrap(sent.last), pkg: "org.example.browser")
        let named = await first.value
        let answer = MCPToolHost.statusAnswer(input(phone: phone, foreground: named, apps: [browser]),
                                              now: clock.now)
        let foreground = try XCTUnwrap(answer["foreground"] as? [String: Any])
        XCTAssertEqual(foreground["package"] as? String, "org.example.browser")
        XCTAssertEqual(foreground["label"] as? String, "Browser")
        XCTAssertNil(answer["foregroundError"])

        // pkg: null → foreground null, no error.
        clock.now += .seconds(3)
        let second = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 2)
        gate.reply(seq: sent[1], pkg: nil)
        let nothing = MCPToolHost.statusAnswer(input(phone: phone, foreground: await second.value),
                                               now: clock.now)
        XCTAssertTrue(nothing["foreground"] is NSNull)
        XCTAssertNil(nothing["foregroundError"])

        // not_available → not_supported.
        clock.now += .seconds(3)
        let third = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 3)
        gate.unavailable()
        let refused = MCPToolHost.statusAnswer(input(phone: phone, foreground: await third.value),
                                               now: clock.now)
        XCTAssertTrue(refused["foreground"] is NSNull)
        XCTAssertEqual(refused["foregroundError"] as? String, "not_supported")

        // Silence → timeout at 1 s.
        clock.now += .seconds(3)
        let started = ContinuousClock.now
        let silent = await gate.read()
        let waited = ContinuousClock.now - started
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(silent, .timeout)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(900))
        XCTAssertLessThan(waited, .milliseconds(1600))
        let late = MCPToolHost.statusAnswer(input(phone: phone, foreground: silent), now: clock.now)
        XCTAssertTrue(late["foreground"] is NSNull)
        XCTAssertEqual(late["foregroundError"] as? String, "timeout")

        // The panel's card read 1 s earlier: no new task.front, its answer reused.
        clock.now += .seconds(3)
        XCTAssertTrue(gate.ask(), "the card's read goes out")
        XCTAssertEqual(sent.count, 5)
        gate.reply(seq: sent[4], pkg: "org.example.browser")
        clock.now += .seconds(1)
        let reused = await gate.read()
        XCTAssertEqual(sent.count, 5, "a status call 1 s after the card's read sent another task.front")
        XCTAssertEqual(reused, .pkg("org.example.browser"))
    }

    // [MCP-32]
    @MainActor
    func testTwoStatusCallsInTwoSecondsShareOneRead() async throws {
        let clock = TestClock()
        let gate = FrontReadGate(now: { clock.now })
        var sent: [Int] = []
        gate.send = { sent.append($0) }

        // Two calls while the read is out: one request, both answered.
        let a = Task { await gate.read() }
        let b = Task { await gate.read() }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(sent.count, 1)
        gate.reply(seq: sent[0], pkg: "org.example.browser")
        let first = await a.value
        let second = await b.value
        XCTAssertEqual(first, .pkg("org.example.browser"))
        XCTAssertEqual(second, .pkg("org.example.browser"))

        // A third call 1.9 s after the request reuses it; the panel's ask too.
        clock.now += .milliseconds(1900)
        let third = await gate.read()
        XCTAssertEqual(third, .pkg("org.example.browser"))
        XCTAssertFalse(gate.ask(), "the card asked again within 2 s of the status call")
        XCTAssertEqual(sent.count, 1)

        // 2 s after the request: a new one.
        clock.now += .milliseconds(100)
        let fourth = Task { await gate.read() }
        await Task.yield()
        XCTAssertEqual(sent.count, 2)
        gate.reply(seq: sent[1], pkg: nil)
        let refreshed = await fourth.value
        XCTAssertEqual(refreshed, FrontRead.none)
    }
}
