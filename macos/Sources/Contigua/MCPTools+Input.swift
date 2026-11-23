// tap, long_press, swipe, type_text and press_key (docs/design/mcp.md "The act
// envelope", MCP-80…94). Each call is one `MCPActMachine` run by
// `MCPActRunner`: its turn on the window (WindowActQueue), the input, the
// phone's settle and the tree read after it (PhoneReadQueue), and one answer
// with no `ok`.

import Foundation

extension MCPToolHost {
    /// MCP-8: an input tool's bound is its gesture's `ms` plus 5 s (the
    /// settle's 2 s plus 3 s).
    nonisolated static func actDeadline(gestureMs: Int = 0) -> Duration {
        .milliseconds(gestureMs + MCPActMachine.timeoutMs + 3000)
    }

    // MARK: Input

    func tap(window id: Int, x: Double, y: Double, wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        let stream = UInt32(id)
        return try await act(id, wait: wait, observe: observe,
                             did: { MCPActDid.tap(x: x, y: y, holdMs: nil,
                                                  latest: controller.uiTreeLatest(stream: stream)) },
                             input: { window in
                                 send(.touch(TouchEvent(action: .down, nx: Float(x), ny: Float(y))), to: window)
                                 send(.touch(TouchEvent(action: .up, nx: Float(x), ny: Float(y))), to: window)
                             })
    }

    /// T10 (MCP-86): a ref is the phone's key; the call sends `ui.press` with
    /// it and the label this client was last answered for it, and the phone
    /// presses the node where it is now or refuses and presses nothing.
    /// `did.node` is the node as the phone read it at the press (MCP-108).
    func tap(window id: Int, ref: String, wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        try await act(id, wait: wait, observe: observe, ref: ref, path: .press,
                      did: { MCPActDid(object: ["action": "tap", "ref": ref], snapshot: nil) },
                      input: { _ in })
    }

    func longPress(window id: Int, x: Double, y: Double, ms: Int,
                   wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        let stream = UInt32(id)
        return try await act(id, wait: wait, observe: observe, gestureMs: ms,
                             did: { MCPActDid.tap(x: x, y: y, holdMs: ms,
                                                  latest: controller.uiTreeLatest(stream: stream)) },
                             input: { window in
                                 send(.touch(TouchEvent(action: .down, nx: Float(x), ny: Float(y))), to: window)
                                 try? await Task.sleep(for: .milliseconds(ms))
                                 send(.touch(TouchEvent(action: .up, nx: Float(x), ny: Float(y))), to: window)
                             })
    }

    /// Down, ~60 Hz interpolated moves for `ms`, up. The endpoints are exact;
    /// intermediate steps never overshoot either end.
    func swipe(window id: Int, x1: Double, y1: Double, x2: Double, y2: Double, ms: Int,
               wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        try await act(id, wait: wait, observe: observe, gestureMs: ms,
                      did: { MCPActDid.swipe(from: [x1, y1], to: [x2, y2], ms: ms) },
                      input: { window in
                          let steps = max(1, Int((Double(ms) / 1000 * 60).rounded()))
                          let interval = ms / steps
                          send(.touch(TouchEvent(action: .down, nx: Float(x1), ny: Float(y1))), to: window)
                          for step in 1...steps {
                              if interval > 0 {
                                  try? await Task.sleep(for: .milliseconds(interval))
                              }
                              let t = Double(step) / Double(steps)
                              send(.touch(TouchEvent(action: .move, nx: Float(x1 + (x2 - x1) * t),
                                                     ny: Float(y1 + (y2 - y1) * t))), to: window)
                          }
                          send(.touch(TouchEvent(action: .up, nx: Float(x2), ny: Float(y2))), to: window)
                      })
    }

    /// T13 (MCP-92, MCP-109): the text goes to the phone as `ui.type`, never
    /// as the `text` message, and neither clipboard is touched (MCP-110).
    /// `did` never carries the text: its length, `clear`, `submit`, and the
    /// phone's `entry` and `via`.
    func typeText(window id: Int, text: String, clear: Bool, submit: Bool,
                  wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        try await act(id, wait: wait, observe: observe, path: .type,
                      typing: MCPTyping(text: text, clear: clear, submit: submit),
                      did: { MCPActDid.type(characters: text.unicodeScalars.count, clear: clear, submit: submit) },
                      input: { _ in })
    }

    func pressKey(window id: Int, key: MCPKey, wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        try await act(id, wait: wait, observe: observe,
                      did: { MCPActDid.key(key.rawValue) },
                      input: { window in
                          let session = controller.windows.session
                          if let action = key.navAction {
                              session.nav(stream: window.stream, action: action)
                          } else if let keycode = key.keycode {
                              session.key(KeyEvent(action: 0, keycode: keycode), stream: window.stream)
                              session.key(KeyEvent(action: 1, keycode: keycode), stream: window.stream)
                          }
                      })
    }

    func send(_ command: InputMapper.Command, to window: StreamWindowController) {
        let session = controller.windows.session
        switch command {
        case .touch(let event): session.touch(event, stream: window.stream)
        case .key(let event): session.key(event, stream: window.stream)
        case .text(let text): session.text(stream: window.stream, text: text)
        case .nav(let action): session.nav(stream: window.stream, action: action)
        default: break
        }
    }

    // MARK: One act call

    /// Run one input call through its machine and build the envelope. `did`
    /// is computed when the call's turn comes (from the window's latest tree
    /// then), `input` sends it.
    private func act(_ id: Int, wait: MCPWait, observe: MCPObserve, ref: String? = nil,
                     path: MCPActMachine.Path = .input, typing: MCPTyping? = nil, gestureMs: Int = 0,
                     did: @escaping @MainActor () -> MCPActDid,
                     input: @escaping @MainActor (StreamWindowController) async -> Void) async throws -> [String: Any] {
        let client = self.client
        let acts = controller.windowActs
        let env = MCPHostActEnvironment(host: self, id: id, ref: ref, typing: typing, client: client, did: did,
                                        input: { window in
            acts.agentInput(window: UInt32(id), client: client)  // MCP-84: another_agent for any other holder
            await input(window)
        })
        let outcome = await MCPActRunner.run(MCPActMachine(path: path, wait: wait, observe: observe),
                                             window: UInt32(id), queue: acts,
                                             deadline: Self.actDeadline(gestureMs: gestureMs), env: env,
                                             ref: ref != nil, client: client)
        switch outcome {
        case .answer(let answer):
            var envelope = MCPActEnvelope.answer(window: id, did: env.didNow ?? did(),
                                                 frameAtInput: env.frameAtInput, result: answer)
            // MCP-20/21: state and frame as they are now; a window gone during
            // the call answers the frame it last had.
            if let window = controller.windows.controller(for: UInt32(id)) {
                if envelope["state"] == nil { envelope["state"] = stateToken(for: window) }
                envelope["frame"] = frameObject(for: window)
            } else {
                if envelope["state"] == nil { envelope["state"] = "closed" }
                envelope["frame"] = env.lastFrame ?? FrameClock.object(seq: 0, ageMs: nil)
            }
            return envelope
        case .fail(let code):
            throw env.error(for: code)
        }
    }

    /// MCP-85: the window as an input sees it when its turn comes.
    func actCondition(_ id: Int) -> MCPActMachine.Condition {
        guard let window = controller.windows.controller(for: UInt32(id)) else { return .gone }
        guard controller.link.isOnline else { return .phoneOffline }
        switch window.mcpLifecycle {
        case .opening, .stalled: return .notReady
        case .closed: return .gone
        case .linkDown, .reconnecting, .offline: return .phoneOffline
        case .live, .paused: return .live
        }
    }

    /// The phone's settle of the window's display (MCP-81), as the machine's
    /// result.
    func settleResult(_ id: Int, quietMs: Int, timeoutMs: Int,
                      until: ContinuousClock.Instant) async -> MCPSettleResult {
        do {
            let reply = try await controller.uiSettle(stream: UInt32(id), quietMs: quietMs,
                                                      timeoutMs: timeoutMs, until: until)
            guard reply.ok else { return .failed(reply.code ?? "failed") }
            return .reply(settled: reply.settled, waitedMs: reply.waitedMs, reason: reply.reason)
        } catch UITreeError.timedOut {
            return .failed("timeout")
        } catch UITreeError.notConnected {
            return .failed("not_connected")
        } catch {
            return .failed("failed")
        }
    }

    /// The `ui_tree` answer read after the settle (MCP-82), stamped with the
    /// window's state and frame, as JSON text; or the failure's code.
    func observedTree(_ id: Int, until: ContinuousClock.Instant? = nil) async -> MCPTreeResult {
        do {
            var answer = try await uiTree(id, until: until)
            if let window = controller.windows.controller(for: UInt32(id)) {
                answer = MCPFreshness.stamp(answer, state: stateToken(for: window),
                                            frame: frameObject(for: window))
            }
            return .ok(MCPJSON.string(answer))
        } catch {
            return .failed(MCPToolError.mapping(error, phone: phoneName).code.rawValue)
        }
    }
}

/// The host's side of one call: the real window, session and phone.
@MainActor
final class MCPHostActEnvironment: MCPActEnvironment {
    private let host: MCPToolHost
    private let id: Int
    private let ref: String?
    private let typing: MCPTyping?
    private let did: () -> MCPActDid
    private let input: (StreamWindowController) async -> Void
    /// What the call pressed, fixed when the input went out.
    private(set) var didNow: MCPActDid?
    /// The window's frame seq when the input was sent (`on.frame`).
    private(set) var frameAtInput: Int?
    /// The window's `frame` object, last seen while it was open.
    var lastFrame: [String: Any]? {
        if let window = host.controller.windows.controller(for: UInt32(id)) {
            return host.frameObject(for: window)
        }
        return frameAtSend
    }
    private var frameAtSend: [String: Any]?
    private var refusalError: MCPToolError?

    private let client: MCPClientID?

    init(host: MCPToolHost, id: Int, ref: String?, typing: MCPTyping? = nil, client: MCPClientID? = nil,
         did: @escaping () -> MCPActDid, input: @escaping (StreamWindowController) async -> Void) {
        self.host = host
        self.id = id
        self.ref = ref
        self.typing = typing
        self.client = client
        self.did = did
        self.input = input
    }

    func windowCondition() -> MCPActMachine.Condition { host.actCondition(id) }

    /// T10: before the press, the Mac refuses only what the phone cannot
    /// judge: a window with no tree since it opened or the phone reconnected (F4).
    func refusal() -> String? {
        let error = Self.refusal(ref: ref, window: id,
                                 latestSnapshot: host.controller.uiTreeLatestSnapshot(stream: UInt32(id)))
        if let error { refusalError = error }
        return error?.code.rawValue
    }

    /// The Mac's refusal, pure (WIN-79, MCP-86): nil for a point (no ref) and
    /// for a ref on a window with a tree, which the phone judges; for a ref on
    /// a window with no tree read since it opened or since the phone
    /// reconnected (no latest snapshot), `stale_ref` with WIN-79's sentence,
    /// which never says the window closed. A ref that is no key never gets
    /// here: the argument check refuses it (MCP-71).
    nonisolated static func refusal(ref: String?, window id: Int, latestSnapshot: Int?) -> MCPToolError? {
        guard let ref, latestSnapshot == nil else { return nil }
        return MCPToolError(.staleRef, UITreeRefusal.noTree(ref), ["window": id, "ref": ref])
    }

    /// `"e12"` → 12 (MCP-71).
    nonisolated static func key(_ ref: String) -> Int? {
        guard ref.first == "e", ref.count > 1, ref.dropFirst().allSatisfy(\.isASCII),
              let k = Int(ref.dropFirst()), k >= 0 else { return nil }
        return k
    }

    func sendInput() async {
        guard let window = host.controller.windows.controller(for: UInt32(id)) else { return }
        didNow = did()
        let frame = host.frameObject(for: window)
        frameAtSend = frame
        frameAtInput = frame["seq"] as? Int
        await input(window)
    }

    func sendPress() async -> MCPActMachine.Event {
        guard let ref, let k = Self.key(ref) else { return .pressFailed("gone") }
        let stream = UInt32(id)
        guard let window = host.controller.windows.controller(for: stream) else { return .pressFailed("no_window") }
        let frame = host.frameObject(for: window)
        frameAtSend = frame
        frameAtInput = frame["seq"] as? Int
        let expect = host.controller.uiTreeExpect(client: client, stream: stream, k: k)
        let snapshot = host.controller.uiTreeLatestSnapshot(stream: stream)
        let result: UIPressResult
        do {
            result = .reply(try await host.controller.uiPress(stream: stream, k: k, holdMs: nil, client: client,
                                                              until: .now + MCPToolHost.actDeadline()))
        } catch UITreeError.timedOut {
            result = .failed("timeout")
        } catch UITreeError.notConnected {
            result = .failed("phone_offline")
        } catch is CancellationError {
            // The client left with the press already sent: it may have landed.
            result = .failed(UIPressResult.cancelled)
        } catch {
            result = .failed("failed")
        }
        // MCP-84: only a press that happened, or may have, is input on the window.
        if result.mayHaveActed { host.controller.windowActs.agentInput(window: stream, client: client) }
        switch result {
        case .failed(UIPressResult.cancelled):
            return .pressFailed("failed")  // the machine knows no cancelled code
        case .failed(let code):
            return .pressFailed(code)
        case .reply(let reply) where !reply.ok:
            let code = reply.code ?? "failed"
            refusalError = MCPToolError.pressRefusal(code: code, ref: ref, window: id, latestSnapshot: snapshot,
                                                     expect: expect, now: reply.now, coveredBy: reply.coveredBy)
            return .pressFailed(code)
        case .reply(let reply):
            didNow = MCPActDid.press(ref: ref, reply: reply, snapshot: snapshot)
            return .pressOK
        }
    }

    /// T13 (MCP-109): `ui.type` through the phone's read queue. The phone
    /// types nothing when it refuses; with no answer the text may be in.
    func sendType() async -> MCPActMachine.Event {
        guard let typing else { return .typeFailed("failed") }
        let stream = UInt32(id)
        guard let window = host.controller.windows.controller(for: stream) else { return .typeFailed("no_window") }
        let frame = host.frameObject(for: window)
        frameAtSend = frame
        frameAtInput = frame["seq"] as? Int
        let reply: UITypeReply
        do {
            reply = try await host.controller.uiType(stream: stream, text: typing.text, clear: typing.clear,
                                                     submit: typing.submit,
                                                     until: .now + MCPToolHost.actDeadline())
        } catch {
            // MCP-84: no answer, so the text may have gone in.
            host.controller.windowActs.agentInput(window: stream, client: client)
            switch error {
            case UITreeError.timedOut: return .typeFailed("timeout")
            case UITreeError.notConnected: return .typeFailed("phone_offline")
            default: return .typeFailed("failed")  // the client left, or the queue failed
            }
        }
        guard reply.ok else {
            let code = reply.code ?? "failed"
            refusalError = MCPToolError.typeRefusal(code: code, window: id)
            return .typeFailed(code)
        }
        host.controller.windowActs.agentInput(window: stream, client: client)
        didNow = MCPActDid.type(characters: reply.characters ?? typing.text.unicodeScalars.count,
                                clear: typing.clear, submit: typing.submit)
        // A phone always names both; "unknown"/"keys" only stand in for a torn reply.
        return .typeOK(entry: reply.entry ?? "unknown", via: reply.via ?? "keys")
    }

    func settle(quietMs: Int, timeoutMs: Int, until: ContinuousClock.Instant) async -> MCPSettleResult {
        await host.settleResult(id, quietMs: quietMs, timeoutMs: timeoutMs, until: until)
    }

    func readTree(until: ContinuousClock.Instant) async -> MCPTreeResult {
        await host.observedTree(id, until: until)
    }

    /// The failure a machine's `fail(code)` throws, with its sentence.
    func error(for code: String) -> MCPToolError {
        if let refusalError, refusalError.code.rawValue == code || code == "stale_ref" && refusalError.code == .staleRef {
            return refusalError
        }
        let state = host.controller.windows.controller(for: UInt32(id)).map { host.stateToken(for: $0) }
        switch code {
        case "no_window": return host.noWindow(id)
        case "phone_offline": return .phoneOffline(host.phoneName)
        case "timeout": return .timeout(host.phoneName)
        case "not_ready":
            let shown = state ?? "opening"
            return MCPToolError(.notReady,
                                "Window \(id) is \(shown): it takes no input until its picture is live. Call list_windows, or try again in a moment.",
                                ["window": id, "state": shown])
        default:
            return MCPToolError(MCPErrorCode(rawValue: code) ?? .failed,
                                "The phone could not do that in window \(id).", ["window": id])
        }
    }
}

/// What an input call did (MCP-80): the `did` object and the snapshot of the
/// tree it acted on (`on.snapshot`). Pure, from the window's latest tree.
struct MCPActDid {
    var object: [String: Any]
    var snapshot: Int?

    init(object: [String: Any], snapshot: Int?) {
        self.object = object
        self.snapshot = snapshot
    }

    /// A point tap names the smallest clickable node of the latest tree whose
    /// box holds the point, in that tree's pixels (MCP-87).
    static func tap(x: Double, y: Double, holdMs: Int?, latest: UITree?) -> MCPActDid {
        var object: [String: Any] = ["action": "tap", "at": [x, y]]
        if let holdMs { object["holdMs"] = holdMs }
        guard let latest, let size = latest.size, size.count == 2 else {
            return MCPActDid(object: object, snapshot: latest?.snapshot)
        }
        let px = x * Double(size[0])
        let py = y * Double(size[1])
        let holding = latest.nodes.filter { node in
            guard node.click, !node.off, let box = node.box, box.count == 4 else { return false }
            return Double(box[0]) <= px && px <= Double(box[2]) && Double(box[1]) <= py && py <= Double(box[3])
        }
        let smallest = holding.min { area($0.box ?? []) < area($1.box ?? []) }
        if let hit = smallest {
            var named: [String: Any] = ["ref": hit.ref, "role": hit.role]
            if let text = hit.text { named["text"] = text }
            if let desc = hit.desc { named["desc"] = desc }
            object["hit"] = named
        }
        return MCPActDid(object: object, snapshot: latest.snapshot)
    }

    /// A press by key names what the phone pressed, as it read the node at
    /// the press (MCP-108); `on.snapshot` is the window's latest read.
    static func press(ref: String, reply: UIPressReply, snapshot: Int?) -> MCPActDid {
        var named: [String: String] = ["role": reply.role ?? ""]
        if let text = reply.text { named["text"] = text }
        if let desc = reply.desc { named["desc"] = desc }
        var object: [String: Any] = ["action": "tap", "ref": ref, "node": named]
        if let at = reply.at { object["at"] = at }
        if let box = reply.box { object["box"] = box }
        return MCPActDid(object: object, snapshot: snapshot)
    }

    static func swipe(from: [Double], to: [Double], ms: Int) -> MCPActDid {
        MCPActDid(object: ["action": "swipe", "from": from, "to": to, "ms": ms], snapshot: nil)
    }

    /// Never the text: only how many characters, in code points (MCP-14, MCP-92).
    static func type(characters: Int, clear: Bool, submit: Bool) -> MCPActDid {
        MCPActDid(object: ["action": "type", "characters": characters, "clear": clear,
                           "submit": submit], snapshot: nil)
    }

    static func key(_ key: String) -> MCPActDid {
        MCPActDid(object: ["action": "key", "key": key], snapshot: nil)
    }

    private static func area(_ box: [Int]) -> Int {
        guard box.count == 4 else { return .max }
        return (box[2] - box[0]) * (box[3] - box[1])
    }
}

/// The act envelope (MCP-80): `window`, `did`, `on`, `settle`, and what the
/// machine's answer adds. `state` and `frame` are stamped when the answer is
/// made, unless the call itself knows the state (closed, offline).
enum MCPActEnvelope {
    static func answer(window: Int, did: MCPActDid, frameAtInput: Int?,
                       result: MCPActMachine.Answer) -> [String: Any] {
        var didObject = did.object
        if let entry = result.entry { didObject["entry"] = entry }
        if let via = result.via { didObject["via"] = via }
        var answer: [String: Any] = [
            "window": window,
            "did": didObject,
            "on": ["snapshot": did.snapshot.map { $0 as Any } ?? NSNull(),
                   "frame": frameAtInput.map { $0 as Any } ?? NSNull()] as [String: Any],
            "settle": settle(result.settle),
        ]
        if let state = result.state { answer["state"] = state }
        if !result.alsoActed.isEmpty { answer["alsoActed"] = result.alsoActed }
        if let closed = result.closed {
            answer["closed"] = ["reason": closed.reason, "closedBy": closed.by]
        }
        if let tree = result.tree,
           let object = try? JSONSerialization.jsonObject(with: Data(tree.utf8)) as? [String: Any] {
            answer["tree"] = object
        }
        if let treeError = result.treeError { answer["treeError"] = treeError }
        return answer
    }

    static func settle(_ settle: MCPActMachine.Settle) -> [String: Any] {
        var object: [String: Any] = ["state": settle.state]
        if let waitedMs = settle.waitedMs { object["waitedMs"] = waitedMs }
        if let reason = settle.reason { object["reason"] = reason }
        return object
    }
}

/// What `type_text` sends as `ui.type` (MCP-109). Never logged.
struct MCPTyping {
    let text: String
    let clear: Bool
    let submit: Bool
}

extension MCPToolError {
    /// The phone's `ui.type` refusal as a closed code with design/mcp.md's
    /// sentence; nil for a code whose generic sentence stands (MCP-6, MCP-109).
    static func typeRefusal(code: String, window id: Int) -> MCPToolError? {
        switch code {
        case "no_field":
            return MCPToolError(.noField, "Window \(id) has no focused text field. Tap the field first.",
                                ["window": id])
        case "not_supported":
            return MCPToolError(.notSupported,
                                "The focused field on window \(id) can't take this text: type only letters, digits and symbols a keyboard has, or pass clear: true to replace what is there.",
                                ["window": id])
        default:
            return nil
        }
    }
}
