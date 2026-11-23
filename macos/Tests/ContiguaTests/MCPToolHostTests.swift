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

    // [MCP-34] A query keeps the apps whose label or package holds it,
    // label-prefix matches first, then the other label matches, then the
    // package-only ones; `total` counts them all, whatever `limit` keeps.
    func testListAppsFiltersAndRanksPrefixesFirst() throws {
        let apps = [
            AppInfo(json: ["pkg": "org.example.mycalc", "label": "My Calc"])!,
            AppInfo(json: ["pkg": "com.example.calc", "label": "Numbers"])!,
            AppInfo(json: ["pkg": "com.google.android.calendar", "label": "Calendar"])!,
            AppInfo(json: ["pkg": "com.google.android.calculator", "label": "Calculator"])!,
        ]
        func labels(_ answer: [String: Any]) -> [String] {
            (answer["apps"] as? [[String: String]] ?? []).compactMap { $0["label"] }
        }
        let calc = try MCPToolHost.appsAnswer(apps, query: "calc", limit: nil)
        XCTAssertEqual(labels(calc), ["Calculator", "My Calc", "Numbers"])
        XCTAssertEqual(calc["total"] as? Int, 3)
        let folded = try MCPToolHost.appsAnswer(apps, query: "C\u{C1}LC", limit: nil)
        XCTAssertEqual(labels(folded), ["Calculator", "My Calc", "Numbers"], "case and diacritics")

        let all = try MCPToolHost.appsAnswer(apps, query: nil, limit: nil)
        XCTAssertEqual(labels(all), ["Calculator", "Calendar", "My Calc", "Numbers"])
        XCTAssertEqual(all["total"] as? Int, 4)

        let one = try MCPToolHost.appsAnswer(apps, query: "calc", limit: 1)
        XCTAssertEqual(labels(one), ["Calculator"])
        XCTAssertEqual(one["total"] as? Int, 3)

        let many = (1...25).map { AppInfo(json: ["pkg": "com.example.tool\($0)", "label": "Tool \($0)"])! }
        let capped = try MCPToolHost.appsAnswer(many, query: "tool", limit: nil)
        XCTAssertEqual(labels(capped).count, 20, "a query answers at most 20 by default")
        XCTAssertEqual(capped["total"] as? Int, 25)
        XCTAssertEqual(labels(try MCPToolHost.appsAnswer(many, query: nil, limit: nil)).count, 25,
                       "no query answers every app")

        let nothing = try MCPToolHost.appsAnswer(apps, query: "zzz", limit: nil)
        XCTAssertEqual(labels(nothing), [])
        XCTAssertEqual(nothing["total"] as? Int, 0)
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

    // MARK: press_key and close_window (plan T2)

    /// [MCP-94] home and recents act only in the Phone Mirror (WIN-47): in an
    /// app window they send nothing and `did` says so.
    @MainActor
    func testHomeInAnAppWindowIsIgnored() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        XCTAssertFalse(window is PhoneWindowController)
        for key in ["home", "recents"] {
            let (answer, _) = await fixture.call("press_key", ["window": Int(window.stream), "key": key])
            XCTAssertEqual(answer["isError"] as? Bool, false, "press_key \(key) failed: \(answer)")
            XCTAssertTrue(fixture.sent("nav").isEmpty, "press_key \(key) sent a nav: \(fixture.sentTypes())")
            let did = try XCTUnwrap((answer["structuredContent"] as? [String: Any])?["did"] as? [String: Any])
            XCTAssertEqual(did as NSDictionary,
                           ["action": "key", "key": key, "ignored": true] as NSDictionary)
        }
        // back is the app's own navigation: it goes.
        let (back, _) = await fixture.call("press_key", ["window": Int(window.stream), "key": "back"])
        XCTAssertEqual(back["isError"] as? Bool, false, "press_key back failed: \(back)")
        XCTAssertEqual(fixture.sent("nav").first?.string("action"), "back")
    }

    /// [MCP-54] A window the person opened closes only with `force: true`; an
    /// agent's window closes without it.
    @MainActor
    func testClosingThePersonsWindowNeedsForce() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let person = try await fixture.liveWindow()
        let windows = fixture.controller.windows
        let mine = windows.opening(by: .client(MCPClientID(1))) { windows.openOrRaise(pkg: "com.android.chrome") }
        let theirs = windows.opening(by: .client(MCPClientID(2))) { windows.openOrRaise(pkg: "com.android.vending") }
        let id = Int(person.stream)

        let (refused, _) = await fixture.call("close_window", ["window": id])
        XCTAssertEqual(refused["isError"] as? Bool, true, "closed the person's window: \(refused)")
        let text = ((refused["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let error = (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"]
            as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "failed")
        XCTAssertEqual(error?["message"] as? String,
                       "Window \(id) was opened by the person. Pass force: true to close it anyway.")
        XCTAssertTrue(fixture.sent("window.close").isEmpty, "a refused close sent window.close")
        XCTAssertNotNil(windows.controller(for: person.stream), "a refused close closed the window")

        let (forced, _) = await fixture.call("close_window", ["window": id, "force": true])
        XCTAssertEqual(forced["isError"] as? Bool, false, "force did not close: \(forced)")
        XCTAssertNil(windows.controller(for: person.stream), "force: true left the window open")

        for window in [mine, theirs] {
            let (closed, _) = await fixture.call("close_window", ["window": Int(window.stream)])
            XCTAssertEqual(closed["isError"] as? Bool, false, "an agent's window needed force: \(closed)")
            XCTAssertNil(windows.controller(for: window.stream), "an agent's window stayed open")
        }
    }
    // MARK: Review follow-ups (#262)

    /// The `{"error": {...}}` object of a failed tool call.
    private func error(_ result: [String: Any]) -> [String: Any]? {
        guard result["isError"] as? Bool == true,
              let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object["error"] as? [String: Any]
    }

    /// [MCP-20] [MCP-21] A `ui_tree` whose window closes while the phone reads
    /// it answers `state: "closed"` and the frame the window last had; the
    /// window is the one the call named, looked up before the read.
    @MainActor
    func testATreeWhoseWindowClosedDuringTheCallSaysClosed_MCP20() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        let stream = window.stream
        fixture.hold("ui.tree")
        let call = Task { await fixture.call("ui_tree", ["window": Int(stream)]) }
        let asked = await fixture.wait { !fixture.sent("ui.tree").isEmpty }
        XCTAssertTrue(asked, "no ui.tree went out: \(fixture.sentTypes())")
        fixture.phoneSends(["t": "window.closed", "stream": Int(stream), "reason": "app_exited"])
        let gone = await fixture.wait { fixture.controller.windows.controller(for: stream) == nil }
        XCTAssertTrue(gone, "the window never closed")
        fixture.release("ui.tree")
        let (answer, _) = await call.value

        XCTAssertEqual(answer["isError"] as? Bool, false, "ui_tree failed: \(answer)")
        let structured = try XCTUnwrap(answer["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["state"] as? String, "closed")
        let frame = try XCTUnwrap(structured["frame"] as? [String: Any], "no frame: \(structured)")
        XCTAssertNotNil(frame["seq"] as? Int)
    }

    /// [MCP-61] An offline phone fails `screenshot` with `phone_offline` before
    /// its ref is judged: a ref the window's tree never named is not `stale_ref`.
    @MainActor
    func testAnOfflinePhoneWinsOverAStaleRef_MCP61() async throws {
        let (controller, profile) = offlineController()
        defer { dispose(controller, profile) }
        controller.remembered.remember(PhoneRef(id: "mcp-shot-1", name: "Pixel 9", model: "Pixel 9"))
        let window = controller.windows.openOrRaise(pkg: "com.android.settings")
        window.noteFirstFrame()
        XCTAssertFalse(controller.link.isOnline)
        let host = MCPToolHost(controller: controller)
        let shot = await host.perform(.screenshot(window: Int(window.stream), ref: "e5"), client: MCPClientID(1))
        XCTAssertEqual(code(shot), .phoneOffline)
    }

    /// [MCP-84] Two agents on one window: the second call waits for the
    /// first's turn, and neither answer names the other in `alsoActed`, since
    /// every agent input is sent by the call that holds the window's turn.
    @MainActor
    func testTwoAgentsOnOneWindowNeverReportEachOther_MCP84() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let window = try await fixture.liveWindow()
        let id = Int(window.stream)
        fixture.hold("ui.type")
        let first = Task {
            await fixture.call("type_text", ["window": id, "text": "one", "observe": "none"],
                               client: MCPClientID(1))
        }
        let typed = await fixture.wait { fixture.sent("ui.type").count == 1 }
        XCTAssertTrue(typed, "the first call sent no ui.type: \(fixture.sentTypes())")
        let second = Task {
            await fixture.call("type_text", ["window": id, "text": "two", "observe": "none"],
                               client: MCPClientID(2), clearSent: false)
        }
        let tapped = Task {
            await fixture.call("tap", ["window": id, "x": 0.5, "y": 0.5, "observe": "none"],
                               client: MCPClientID(3), clearSent: false)
        }
        try await Task.sleep(for: .milliseconds(200))  // real-time: give the queued calls time to (wrongly) go out
        XCTAssertEqual(fixture.sent("ui.type").count, 1, "a second call typed during the first's turn")
        fixture.release("ui.type")
        let answers = [await first.value.0, await second.value.0, await tapped.value.0]
        XCTAssertEqual(fixture.sent("ui.type").count, 2)
        for answer in answers {
            XCTAssertEqual(answer["isError"] as? Bool, false, "\(answer)")
            let structured = answer["structuredContent"] as? [String: Any] ?? [:]
            XCTAssertNil(structured["alsoActed"], "an agent was reported: \(structured)")
        }
    }

    /// [MCP-52] [MCP-53] A live window the phone forgot (`no_stream`) closes
    /// with a close record, `phone_closed` by `phone`, and leaves the ledger's
    /// open windows.
    @MainActor
    func testAWindowThePhoneForgotKeepsItsClose_MCP52() throws {
        let (controller, profile) = offlineController()
        defer { dispose(controller, profile) }
        let window = controller.windows.openOrRaise(pkg: "com.android.settings")
        window.noteFirstFrame()
        let stream = window.stream
        controller.windows.handle(.phoneError(code: "no_stream", message: nil, stream: stream))
        XCTAssertNil(controller.windows.controller(for: stream), "the forgotten window stayed open")

        let now = ProcessInfo.processInfo.systemUptime
        let ledger = controller.windows.ledger
        XCTAssertNil(ledger.row(stream, asker: MCPClientID(1), now: now), "its open entry stayed")
        let record = try XCTUnwrap(ledger.closeRecord(stream, asker: MCPClientID(1), now: now), "no close record")
        XCTAssertEqual(record.reason, "phone_closed")
        XCTAssertEqual(record.closedBy, "phone")
        let closed = MCPToolHost(controller: controller, client: MCPClientID(1)).noWindow(Int(stream))
        XCTAssertEqual((closed.extra["closed"] as? [String: Any])?["reason"] as? String, "phone_closed")
    }

    /// [MCP-52] [MCP-53] A handoff the phone refused (`nothing_to_continue`)
    /// closes with a close record, `open_failed` by `phone`, and leaves the
    /// ledger's open windows.
    @MainActor
    func testARefusedHandoffKeepsItsClose_MCP52() throws {
        let (controller, profile) = offlineController()
        defer { dispose(controller, profile) }
        let stream = controller.windows.openHandoffWindow().stream
        controller.windows.closeFailedHandoff(stream: stream)
        XCTAssertNil(controller.windows.controller(for: stream), "the refused handoff stayed open")

        let now = ProcessInfo.processInfo.systemUptime
        let ledger = controller.windows.ledger
        XCTAssertNil(ledger.row(stream, asker: MCPClientID(1), now: now), "its open entry stayed")
        let record = try XCTUnwrap(ledger.closeRecord(stream, asker: MCPClientID(1), now: now), "no close record")
        XCTAssertEqual(record.reason, "open_failed")
        XCTAssertEqual(record.closedBy, "phone")
        let rows = MCPToolHost(controller: controller, client: MCPClientID(1)).listWindows()["recentlyClosed"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(rows.first?["id"] as? Int, Int(stream))
    }

    private static let settingsMulti: [String: Any] = ["pkg": "com.android.settings", "label": "Settings",
                                                       "multi": true]
    private static let clockOne: [String: Any] = ["pkg": "com.android.deskclock", "label": "Clock",
                                                  "multi": false]

    /// [MCP-41] With two windows of one app, `open_app` raises the front one
    /// and answers that window, not the newest.
    @MainActor
    func testOpenAppAnswersTheWindowItRaised_MCP41() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let front = try await fixture.liveWindow()
        await fixture.sendApps([Self.settingsMulti])
        let windows = fixture.controller.windows
        let newer = try XCTUnwrap(windows.openAdditional(pkg: "com.android.settings"), "no second window")
        newer.noteFirstFrame()
        XCTAssertGreaterThan(newer.stream, front.stream)
        windows.noteFront(front.stream)
        XCTAssertEqual(windows.appWindows(pkg: "com.android.settings").first?.stream, front.stream)

        let (answer, _) = await fixture.call("open_app", ["app": "Settings", "wait": "none", "observe": "none"])
        XCTAssertEqual(answer["isError"] as? Bool, false, "open_app failed: \(answer)")
        let structured = try XCTUnwrap(answer["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["window"] as? Int, Int(front.stream), "answered a window it did not raise")
        XCTAssertEqual(structured["opened"] as? String, "raised")
        XCTAssertEqual(windows.appWindows(pkg: "com.android.settings").first?.stream, front.stream)
    }

    /// [MCP-42] `newWindow: true` at the window cap fails `too_many_windows`,
    /// as the phone's own refusal does, and opens nothing.
    @MainActor
    func testANewWindowAtTheCapFailsTooManyWindows_MCP42() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let first = try await fixture.liveWindow()
        await fixture.sendApps([Self.settingsMulti])
        let windows = fixture.controller.windows
        let second = try XCTUnwrap(windows.openAdditional(pkg: "com.android.settings"))
        second.noteFirstFrame()
        windows.setMaxWindows(2)
        let before = windows.openStreams

        let (answer, _) = await fixture.call("open_app", ["app": "Settings", "newWindow": true,
                                                          "wait": "none", "observe": "none"])
        let failure = try XCTUnwrap(error(answer), "open_app at the cap did not fail: \(answer)")
        XCTAssertEqual(failure["code"] as? String, "too_many_windows")
        XCTAssertEqual(failure["maxWindows"] as? Int, 2)
        XCTAssertEqual(failure["message"] as? String,
                       "The phone allows 2 app windows at once. Close one with close_window, then try again.")
        XCTAssertEqual(windows.openStreams, before, "a window opened at the cap")
        XCTAssertNotEqual(first.stream, 0)
    }

    /// [MCP-42] `newWindow: true` while a window of the app is still opening
    /// fails `not_ready` naming that window, and opens nothing.
    @MainActor
    func testANewWindowWhileOneIsOpeningFailsNotReady_MCP42() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        _ = try await fixture.liveWindow()
        await fixture.sendApps([Self.settingsMulti])
        let windows = fixture.controller.windows
        let opening = try XCTUnwrap(windows.openAdditional(pkg: "com.android.settings"))
        XCTAssertEqual(opening.mcpLifecycle, .opening)
        let before = windows.openStreams

        let (answer, _) = await fixture.call("open_app", ["app": "Settings", "newWindow": true,
                                                          "wait": "none", "observe": "none"])
        let failure = try XCTUnwrap(error(answer), "open_app while opening did not fail: \(answer)")
        XCTAssertEqual(failure["code"] as? String, "not_ready")
        XCTAssertEqual(failure["window"] as? Int, Int(opening.stream))
        XCTAssertEqual(failure["state"] as? String, "opening")
        XCTAssertEqual(windows.openStreams, before, "a window opened while one was opening")
    }

    /// [MCP-42] `newWindow: true` for an app that opens one window raises the
    /// window it has, and says `opened: "raised"` because it raised it.
    @MainActor
    func testANewWindowOfAOneWindowAppRaisesItsWindow_MCP42() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        let other = try await fixture.liveWindow()
        await fixture.sendApps([Self.settingsMulti, Self.clockOne])
        let windows = fixture.controller.windows
        let clock = windows.openOrRaise(pkg: "com.android.deskclock")
        clock.noteFirstFrame()
        windows.noteFront(other.stream)
        XCTAssertEqual(windows.appWindows().first?.stream, other.stream)
        let before = windows.openStreams

        let (answer, _) = await fixture.call("open_app", ["app": "Clock", "newWindow": true,
                                                          "wait": "none", "observe": "none"])
        XCTAssertEqual(answer["isError"] as? Bool, false, "open_app failed: \(answer)")
        let structured = try XCTUnwrap(answer["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["window"] as? Int, Int(clock.stream))
        XCTAssertEqual(structured["opened"] as? String, "raised")
        XCTAssertEqual(windows.appWindows().first?.stream, clock.stream, "it said raised but raised nothing")
        XCTAssertEqual(windows.openStreams, before)
    }

    /// [MCP-40] (#183, folded in from #185 and answered as #262 item 9
    /// decides): `newWindow: true` for an app with no window open opens its
    /// first window, as without the flag, even for an app that opens one
    /// window at a time; the answer is `opened: "new"` and no answer sends the
    /// client to list_windows and a retry.
    @MainActor
    func testMCP40NewWindowOnASingleWindowAppWithNoWindowOpensTheFirst() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        _ = try await fixture.liveWindow()
        await fixture.sendApps([Self.settingsMulti, Self.clockOne])
        let windows = fixture.controller.windows
        XCTAssertTrue(windows.appWindows(pkg: "com.android.deskclock").isEmpty)

        let (answer, _) = await fixture.call("open_app", ["app": "Clock", "newWindow": true,
                                                          "wait": "none", "observe": "none"])
        let clocks = windows.appWindows(pkg: "com.android.deskclock")
        XCTAssertEqual(clocks.count, 1, "the first window did not open: \(answer)")
        // The fake phone sends no video: the open answers at its 10 s bound, `opening`.
        XCTAssertEqual(answer["isError"] as? Bool, false, "open_app failed: \(answer)")
        let structured = answer["structuredContent"] as? [String: Any] ?? [:]
        XCTAssertEqual(structured["window"] as? Int, clocks.first.map { Int($0.stream) })
        XCTAssertEqual(structured["opened"] as? String, "new")
        let opens = fixture.sent("window.open")
        XCTAssertEqual(opens.count, 1)
        XCTAssertNil(opens.first?.bool("newInstance"), "the first window is a plain open")
    }

    /// [WIN-36] Shortcuts' (and the debug route's) explicit `newInstance` for
    /// an app with no window open opens its first window, as without the
    /// argument, even for an app that opens one window at a time.
    @MainActor
    func testShortcutsNewInstanceWithNoWindowOpensTheFirst_WIN36() async throws {
        let fixture = try TypeTextFixture()
        defer { fixture.close() }
        _ = try await fixture.liveWindow()
        await fixture.sendApps([Self.settingsMulti, Self.clockOne])
        let controller = fixture.controller
        let phone = try XCTUnwrap(controller.link.phone?.id)
        let before = controller.windows.openStreams.count

        controller.intentsOpenApp("com.android.deskclock", on: phone, newWindow: true)
        XCTAssertEqual(controller.windows.appWindows(pkg: "com.android.deskclock").count, 1,
                       "newInstance with no window open opened nothing")
        XCTAssertEqual(controller.windows.openStreams.count, before + 1)
        XCTAssertNil(controller.pendingOpen)
    }
}

/// A real controller online with the fake phone server, which answers
/// `ui.type` (entry `replaced` with `clear`, else `inserted`; via `set_text`),
/// `ui.settle` (settled) and `ui.tree` ([treeNodes], none by default), and
/// records what the Mac sent from the moment a call starts.
@MainActor
final class TypeTextFixture {
    let server: FakeServer
    let brain: FakeV2PhoneBrain
    let controller: ConnectionController
    let profile: Profile
    private let lock = NSLock()
    nonisolated(unsafe) private var received: [JSONMessage] = []
    nonisolated(unsafe) private var nodes: [[String: Any]] = []

    /// The rows every `ui.tree` reply carries from now on (plan T9).
    nonisolated var treeNodes: [[String: Any]] {
        get { lock.lock(); defer { lock.unlock() }; return nodes }
        set { lock.lock(); nodes = newValue; lock.unlock() }
    }

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
            if frame.messageType == .touch { self?.recordTouch() }
            guard frame.messageType == .json,
                  let message = JSONFrame.decode(payload: frame.payload) else { return }
            guard let self else { return }
            self.record(message, from: connection)
            if !self.held(message, on: connection) { self.answer(message, on: connection) }
        }
    }

    nonisolated private func record(_ message: JSONMessage, from connection: FakeServer.Connection) {
        lock.lock(); received.append(message); phone = connection; lock.unlock()
    }

    nonisolated(unsafe) private var touchCount = 0
    nonisolated private func recordTouch() {
        lock.lock(); touchCount += 1; lock.unlock()
    }

    /// TOUCH frames the Mac has sent since the fixture started.
    var touches: Int {
        lock.lock(); defer { lock.unlock() }
        return touchCount
    }

    /// The phone's side of the link, once the Mac has sent anything.
    nonisolated(unsafe) private var phone: FakeServer.Connection?
    /// Message types the fake phone holds its answer to until `release`.
    nonisolated(unsafe) private var holding: Set<String> = []
    nonisolated(unsafe) private var heldMessages: [(JSONMessage, FakeServer.Connection)] = []

    nonisolated private func held(_ message: JSONMessage, on connection: FakeServer.Connection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard holding.contains(message.t) else { return false }
        heldMessages.append((message, connection))
        return true
    }

    /// Hold the fake phone's answers to `type` until `release(type)`.
    func hold(_ type: String) {
        lock.lock(); holding.insert(type); lock.unlock()
    }

    /// Answer every held `type` request, and stop holding it.
    func release(_ type: String) {
        lock.lock()
        holding.remove(type)
        let due = heldMessages.filter { $0.0.t == type }
        heldMessages.removeAll { $0.0.t == type }
        lock.unlock()
        for (message, connection) in due { answer(message, on: connection) }
    }

    /// A message from the phone, unasked (`window.closed`, `apps`, `drop.result`).
    func phoneSends(_ object: [String: Any]) {
        lock.lock(); let connection = phone; lock.unlock()
        XCTAssertNotNil(connection, "the Mac has not spoken to the fake phone yet")
        connection?.sendJSON(object)
    }

    /// The phone's app list (MCP-33); waits until the controller has it.
    func sendApps(_ apps: [[String: Any]]) async {
        phoneSends(["t": "apps", "apps": apps])
        let loaded = await wait { self.controller.appsLoaded && self.controller.apps.count == apps.count }
        XCTAssertTrue(loaded, "the app list never arrived")
    }

    nonisolated private func answer(_ message: JSONMessage, on connection: FakeServer.Connection) {
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
                                 "displayId": 2, "size": [1080, 2340], "layers": [], "nodes": treeNodes])
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
    func wait(until condition: () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }  // real-time: polls the live controller's pairing with the fake server, to the deadline
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
    func call(_ name: String, _ arguments: [String: Any], client: MCPClientID = MCPClientID(1),
              clearSent: Bool = true) async -> ([String: Any], [String]) {
        if clearSent { lock.withLock { received.removeAll() } }
        let host = MCPToolHost(controller: controller)
        let lines = LogLines()
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": arguments]]
        let line = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        let data = await MCPDispatcher.handle(line: line, client: client, perform: { call, client in
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
