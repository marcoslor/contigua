// open_app, send_link and send_file (docs/design/mcp.md, MCP-40…44).
//
// An open answers like an action (MCP-41): the window's `MCPActMachine`
// enters at Opening, waits for the phone's `window.opened` and the first
// frame (the open bound, 10 s), then settles and reads the tree. Nothing an
// MCP call asks for is queued for a phone that is not online (MCP-42).

import Foundation

extension MCPToolHost {
    /// MCP-8: an open's bound is the open bound, then the settle's 2 s + 3 s
    /// and the read's 5 s.
    nonisolated static let openDeadline: Duration =
        .milliseconds(MCPActMachine.openBoundMs + MCPActMachine.timeoutMs + 3000 + 5000)

    /// MCP-42: the phone in use, online; `no_phone` or `phone_offline` otherwise.
    func onlinePhone() throws -> IntentPhone {
        let phone = try IntentsBridge.resolve(nil, in: controller)
        guard controller.link.isOnline, controller.link.phone?.id == phone.id else {
            throw IntentFailure.phoneNotConnected
        }
        return phone
    }

    private var opener: MCPWindowLedger.Opener { client.map { .client($0) } ?? .person }

    func openApp(_ query: String, newWindow: Bool, shape: MCPWindowShape = .phone, wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        let phone = try onlinePhone()
        let app = try Self.chooseApp(query, in: IntentsBridge.apps(for: phone, in: controller))
        let addWindow = try newWindow && addsWindow(app, phone: phone.id)
        let before = Set(controller.windows.openStreams)
        // MCP-51: a window this call creates is this connection's. The answer
        // is the window the open made or raised (MCP-41), never another of
        // the app's windows.
        let window = controller.windows.opening(by: opener, shape: shape) {
            controller.intentsOpenApp(app.pkg, on: phone.id, newWindow: addWindow)
        }
        guard let stream = window?.stream else {
            throw MCPToolError.failed("The app couldn't open a window. Call list_windows, then try open_app again.")
        }
        return try await opened(stream, kind: .app, opened: before.contains(stream) ? .raised : .new,
                                wait: wait, observe: observe)
    }

    /// MCP-42: `newWindow: true` when the Mac itself cannot add the window.
    /// True adds one; false raises the app's window, for an app that opens
    /// one window at a time (the answer says `raised` because it was). At
    /// the cap it fails `too_many_windows`, as the phone's own refusal does;
    /// while a window of the app is still opening, `not_ready` naming it.
    /// With no window of the app open the flag opens the first (MCP-40).
    private func addsWindow(_ app: AppInfo, phone: String) throws -> Bool {
        let windows = controller.windows
        let existing = windows.appWindows(pkg: app.pkg, deviceId: phone)
        guard !existing.isEmpty else { return true }
        switch windows.newWindowItem(for: app.pkg, deviceId: phone).blocker {
        case .oneWindow:
            return false
        case .atCap:
            throw MCPOpenAnswer.atCap(windows.maxWindows)
        case .opening:
            let opening = existing.first(where: \.isOpening) ?? existing[0]
            throw MCPOpenAnswer.stillOpening(window: Int(opening.stream))
        case .link:
            throw IntentFailure.phoneNotConnected
        case .noApp, nil:
            return true
        }
    }

    /// MCP-43: the link opens in a new window on the live link path; the
    /// answer is that window.
    func sendLink(_ url: String, shape: MCPWindowShape = .phone, wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        _ = try onlinePhone()
        let stream = try controller.windows.opening(by: opener, shape: shape) {
            try IntentsBridge.openLinkWindow(url, controller: controller)
        }
        return try await opened(stream, kind: .link, opened: .new, wait: wait, observe: observe)
    }

    /// MCP-44: the file goes on the drop path; the answer waits for the
    /// phone's `drop.result` and never names the file.
    func sendFile(_ path: String) async throws -> [String: Any] {
        _ = try onlinePhone()
        let url = try IntentFilePolicy.validate(path)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sender = controller.dropSender
        guard !sender.isBusy else {
            throw MCPToolError.failed("The phone is still taking a file. Try send_file again when it is done.")
        }
        let wait = MCPDropWait()
        sender.onEnded = { ok, sentence in wait.ended(ok: ok, sentence: sentence) }
        defer { sender.onEnded = nil }
        guard controller.mcpSendFile(url) else { throw IntentFailure.phoneNotConnected }
        return try Self.sendFileAnswer(bytes: bytes, await wait.wait(bound: MCPDropWait.bound))
    }

    nonisolated static func sendFileAnswer(bytes: Int, _ outcome: MCPDropWait.Outcome) throws -> [String: Any] {
        switch outcome {
        case .delivered: return ["bytes": bytes, "state": "delivered"]
        case .sending: return ["bytes": bytes, "state": "sending"]
        case .failed(let sentence): throw MCPToolError.failed(sentence)
        }
    }

    // MARK: The opened window

    private func opened(_ stream: UInt32, kind: MCPOpenAnswer.Kind, opened: MCPOpenAnswer.Opened,
                        wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        let id = Int(stream)
        let start = ContinuousClock.now
        let env = MCPOpenEnvironment(host: self, stream: stream)
        let outcome = await MCPActRunner.run(MCPActMachine(opening: wait, observe: observe), window: stream,
                                             queue: nil, deadline: Self.openDeadline, env: env, client: client)
        switch outcome {
        case .fail(let code):
            switch code {
            case "no_window": throw noWindow(id)
            case "phone_offline": throw MCPToolError.phoneOffline(phoneName)
            default: throw MCPOpenAnswer.failure(code: code, window: id)
            }
        case .answer(let result):
            // MCP-43: a link window's names come from the phone's first
            // `window.title`, waited for within the open bound.
            if kind == .link {
                let bound = start + .milliseconds(MCPActMachine.openBoundMs)
                while names(of: stream).package == nil, controller.windows.controller(for: stream) != nil,
                      ContinuousClock.now < bound {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            return openAnswer(stream, kind: kind, opened: opened, result: result, lastFrame: env.lastFrame,
                              observe: observe)
        }
    }

    /// The opened-window answer for `stream` now (MCP-41). A new window's
    /// `size` is the display the phone made (`window.opened`), known before
    /// its first frame; a raised one keeps the size its stream has (MCP-100,
    /// MCP-101).
    func openAnswer(_ stream: UInt32, kind: MCPOpenAnswer.Kind, opened: MCPOpenAnswer.Opened,
                    result: MCPActMachine.Answer, lastFrame: [String: Any]?,
                    observe: MCPObserve = .tree) -> [String: Any] {
        let window = controller.windows.controller(for: stream)
        let made = opened == .new ? controller.windows.openedSize(stream).map { [$0.width, $0.height] } : nil
        let size = made ?? window.map { pixelSize(of: $0) }.map { [$0.0, $0.1] } ?? [0, 0]
        let named = names(of: stream)
        var answer = MCPOpenAnswer.answer(
            window: Int(stream), kind: kind, package: named.package, label: named.label, opened: opened,
            openedBy: controller.windows.ledger.openedBy(stream, asker: client), size: size, result: result,
            observe: observe)
        if let window {
            if answer["state"] == nil { answer["state"] = stateToken(for: window) }
            answer["frame"] = frameObject(for: window)
        } else {
            if answer["state"] == nil { answer["state"] = "closed" }
            answer["frame"] = lastFrame ?? FrameClock.object(seq: 0, ageMs: nil)
        }
        return answer
    }

    private func names(of stream: UInt32) -> (package: String?, label: String?) {
        guard let window = controller.windows.controller(for: stream) else { return (nil, nil) }
        if let app = window as? AppWindowController { return (app.pkg, app.appLabel) }
        guard let pkg = WindowManager.ledgerPackage(window) else { return (nil, nil) }
        return (pkg, controller.apps.first { $0.pkg == pkg }?.label)
    }
}

/// The opened-window answer (design/mcp.md "open_app and send_link", MCP-41).
enum MCPOpenAnswer {
    enum Kind: String { case app, link }
    enum Opened: String { case new, raised }

    static func answer(window: Int, kind: Kind, package: String?, label: String?, opened: Opened,
                       openedBy: String, size: [Int], result: MCPActMachine.Answer,
                       observe: MCPObserve = .tree) -> [String: Any] {
        var answer: [String: Any] = [
            "window": window, "kind": kind.rawValue,
            "package": package.map { $0 as Any } ?? NSNull(),
            "label": label.map { $0 as Any } ?? NSNull(),
            "opened": opened.rawValue, "openedBy": openedBy, "size": size,
            "settle": MCPActEnvelope.settle(result.settle),
        ]
        if let state = result.state { answer["state"] = state }
        MCPObserved.add(result.tree, observe: observe, to: &answer)
        if let treeError = result.treeError { answer["treeError"] = treeError }
        return answer
    }

    /// The Mac at the phone's window cap refuses `newWindow: true` itself
    /// (MCP-42), with design/mcp.md's sentence.
    static func atCap(_ maxWindows: Int) -> MCPToolError {
        MCPToolError(.tooManyWindows,
                     "The phone allows \(maxWindows) app windows at once. Close one with close_window, then try again.",
                     ["maxWindows": maxWindows])
    }

    /// `newWindow: true` while a window of the app is still opening (MCP-42).
    static func stillOpening(window: Int) -> MCPToolError {
        MCPToolError(.notReady, "Window \(window) is still opening. Call wait on it, then try again.",
                     ["window": window, "state": "opening"])
    }

    /// The phone refused the window it was opening (MCP-42, MCP-43).
    static func failure(code: String, window: Int) -> MCPToolError {
        switch code {
        case "too_many_windows":
            return MCPToolError(.tooManyWindows,
                                "The phone has as many windows open as it allows. Close one with close_window, then try again.",
                                ["window": window])
        case "timeout":
            return MCPToolError(.timeout, "Window \(window) did not open in time. Call list_windows.",
                                ["window": window])
        default:
            return MCPToolError.failed(
                "The phone could not open window \(window) (\(code)). Call list_windows, then try again.",
                window: window)
        }
    }
}

/// One `send_file`'s wait for the phone's `drop.result` (MCP-44).
@MainActor
final class MCPDropWait {
    enum Outcome: Equatable {
        case delivered
        /// The bound passed first: the file is still on its way.
        case sending
        case failed(String)
    }

    nonisolated static let bound: Duration = .seconds(30)

    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?
    private var timer: Task<Void, Never>?

    func ended(ok: Bool, sentence: String?) {
        resolve(ok ? .delivered : .failed(sentence ?? "The phone refused the file."))
    }

    func wait(bound: Duration) async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            waiter = cont
            timer = Task { [weak self] in
                try? await Task.sleep(for: bound)
                guard !Task.isCancelled else { return }
                self?.resolve(.sending)
            }
        }
    }

    private func resolve(_ next: Outcome) {
        guard outcome == nil else { return }
        outcome = next
        timer?.cancel()
        let waiter = self.waiter
        self.waiter = nil
        waiter?.resume(returning: next)
    }
}

/// An open's side of its call: the window's open events, the phone's settle
/// and the tree read. Nothing is pressed.
@MainActor
final class MCPOpenEnvironment: MCPActEnvironment {
    private let host: MCPToolHost
    private let stream: UInt32
    private var watch: Int?
    private(set) var lastFrame: [String: Any]?

    init(host: MCPToolHost, stream: UInt32) {
        self.host = host
        self.stream = stream
    }

    func windowCondition() -> MCPActMachine.Condition { host.actCondition(Int(stream)) }
    func refusal() -> String? { nil }
    func sendInput() async {}
    func sendPress() async -> MCPActMachine.Event { .pressFailed("gone") }
    func sendType() async -> MCPActMachine.Event { .typeFailed("not_supported") }

    func settle(quietMs: Int, timeoutMs: Int, until: ContinuousClock.Instant) async -> MCPSettleResult {
        noteFrame()
        return await host.settleResult(Int(stream), quietMs: quietMs, timeoutMs: timeoutMs, until: until)
    }

    func readTree(until: ContinuousClock.Instant) async -> MCPTreeResult {
        noteFrame()
        return await host.observedTree(Int(stream), until: until)
    }

    func watchOpen(_ feed: @escaping @MainActor (MCPActMachine.Event) -> Void) {
        noteFrame()
        watch = host.controller.windows.watchOpen(stream: stream, client: host.client) { event in
            MainActor.assumeIsolated { feed(event) }
        }
    }

    func stopWatchingOpen() {
        noteFrame()
        guard let watch else { return }
        self.watch = nil
        host.controller.windows.unwatchOpen(stream: stream, id: watch)
    }

    private func noteFrame() {
        if let window = host.controller.windows.controller(for: stream) {
            lastFrame = host.frameObject(for: window)
        }
    }
}
