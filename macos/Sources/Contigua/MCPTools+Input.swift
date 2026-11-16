// tap, long_press, swipe, type_text and press_key (docs/design/mcp.md "The act
// envelope", MCP-80…94). Each call is one `MCPActMachine` run by
// `MCPActRunner`: its turn on the window (WindowActQueue), the input, the
// phone's settle and the tree read after it (PhoneReadQueue), and one answer
// with no `ok`.

import Foundation

extension MCPToolHost {
    /// MCP-8: an input tool's bound is the settle's (2 s) plus 3 s.
    nonisolated static let actDeadline: Duration = .milliseconds(MCPActMachine.timeoutMs + 3000)

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

    /// S1: the ref is checked against the window's latest tree when the call's
    /// turn comes; a stale, closed or off-screen ref is refused and nothing is
    /// pressed (F1, F4, F9). Otherwise TOUCH goes to the node's `at`, and
    /// `did.node` is that tree's row (MCP-108).
    func tap(window id: Int, ref: String, wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        let stream = UInt32(id)
        var point: UITree.Point?
        return try await act(id, wait: wait, observe: observe, ref: ref,
                             did: {
                                 let did = MCPActDid.tap(ref: ref, holdMs: nil,
                                                         latest: controller.uiTreeLatest(stream: stream))
                                 point = did.flatMap(\.point)
                                 return did ?? MCPActDid(object: ["action": "tap", "ref": ref], snapshot: nil)
                             },
                             input: { window in
                                 guard let point else { return }
                                 send(.touch(TouchEvent(action: .down, nx: Float(point.x), ny: Float(point.y))), to: window)
                                 send(.touch(TouchEvent(action: .up, nx: Float(point.x), ny: Float(point.y))), to: window)
                             })
    }

    func longPress(window id: Int, x: Double, y: Double, ms: Int,
                   wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        let stream = UInt32(id)
        return try await act(id, wait: wait, observe: observe,
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
        try await act(id, wait: wait, observe: observe,
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

    /// Until T13 ships `ui.type`, the text goes on the `text` message (the
    /// Sent path); `did` never carries the text, only its length.
    func typeText(window id: Int, text: String, wait: MCPWait, observe: MCPObserve) async throws -> [String: Any] {
        try await act(id, wait: wait, observe: observe,
                      did: { MCPActDid.type(characters: text.count) },
                      input: { window in
                          controller.windows.session.text(stream: window.stream, text: text)
                      })
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
                     did: @escaping @MainActor () -> MCPActDid,
                     input: @escaping @MainActor (StreamWindowController) async -> Void) async throws -> [String: Any] {
        let env = MCPHostActEnvironment(host: self, id: id, ref: ref, did: did, input: input)
        let outcome = await MCPActRunner.run(MCPActMachine(path: .input, wait: wait, observe: observe),
                                             window: UInt32(id), queue: controller.windowActs,
                                             deadline: Self.actDeadline, env: env, ref: ref != nil)
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
    func settleResult(_ id: Int, quietMs: Int, timeoutMs: Int) async -> MCPSettleResult {
        do {
            let reply = try await controller.uiSettle(stream: UInt32(id), quietMs: quietMs, timeoutMs: timeoutMs)
            guard reply.ok else { return .failed(reply.code ?? "failed") }
            return .reply(settled: reply.settled, waitedMs: reply.waitedMs, reason: reply.reason)
        } catch UITreeError.timedOut {
            return .failed("timeout")
        } catch {
            return .failed("not_available")
        }
    }

    /// The `ui_tree` answer read after the settle (MCP-82), stamped with the
    /// window's state and frame, as JSON text; or the failure's code.
    func observedTree(_ id: Int) async -> MCPTreeResult {
        do {
            var answer = try await uiTree(id)
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

    init(host: MCPToolHost, id: Int, ref: String?, did: @escaping () -> MCPActDid,
         input: @escaping (StreamWindowController) async -> Void) {
        self.host = host
        self.id = id
        self.ref = ref
        self.did = did
        self.input = input
    }

    func windowCondition() -> MCPActMachine.Condition { host.actCondition(id) }

    func refusal() -> String? {
        guard let ref else { return nil }
        let resolution = host.controller.uiTreeResolved(ref: ref, stream: UInt32(id))
        switch UITreeTapPlan(resolution, ref: ref) {
        case .press:
            return nil
        case .refuse(let sentence):
            let error = MCPToolError.tapRefusal(resolution, ref: ref, window: id)
                ?? MCPToolError.failed(sentence, window: id)
            refusalError = error
            return error.code.rawValue
        }
    }

    func sendInput() async {
        guard let window = host.controller.windows.controller(for: UInt32(id)) else { return }
        didNow = did()
        let frame = host.frameObject(for: window)
        frameAtSend = frame
        frameAtInput = frame["seq"] as? Int
        await input(window)
    }

    func sendPress() async -> MCPActMachine.Event { .pressFailed("gone") }  // T10: ui.press
    func sendType() async -> MCPActMachine.Event { .typeFailed("not_supported") }  // T13: ui.type

    func settle(quietMs: Int, timeoutMs: Int) async -> MCPSettleResult {
        await host.settleResult(id, quietMs: quietMs, timeoutMs: timeoutMs)
    }

    func readTree() async -> MCPTreeResult { await host.observedTree(id) }

    /// The failure a machine's `fail(code)` throws, with its sentence.
    func error(for code: String) -> MCPToolError {
        if let refusalError, refusalError.code.rawValue == code { return refusalError }
        let state = host.controller.windows.controller(for: UInt32(id)).map { host.stateToken(for: $0) }
        switch code {
        case "no_window": return .noWindow(id)
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
    /// Where a ref tap presses (S1): the node's `at`.
    var point: UITree.Point?

    init(object: [String: Any], snapshot: Int?, point: UITree.Point? = nil) {
        self.object = object
        self.snapshot = snapshot
        self.point = point
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

    /// A ref tap names the node it pressed, from the tree the ref came from
    /// (MCP-108, S1); nil when the latest tree has no on-screen row for it.
    static func tap(ref: String, holdMs: Int?, latest: UITree?) -> MCPActDid? {
        guard let latest, let node = latest.nodes.first(where: { $0.ref == ref }),
              let at = node.at, !node.off else { return nil }
        var named: [String: String] = ["role": node.role]
        if let text = node.text { named["text"] = text }
        if let desc = node.desc { named["desc"] = desc }
        var object: [String: Any] = ["action": "tap", "ref": ref, "at": [at.x, at.y], "node": named]
        if let box = node.box { object["box"] = box }
        if let holdMs { object["holdMs"] = holdMs }
        return MCPActDid(object: object, snapshot: latest.snapshot, point: at)
    }

    static func swipe(from: [Double], to: [Double], ms: Int) -> MCPActDid {
        MCPActDid(object: ["action": "swipe", "from": from, "to": to, "ms": ms], snapshot: nil)
    }

    /// Never the text: only how many characters (MCP-14).
    static func type(characters: Int) -> MCPActDid {
        MCPActDid(object: ["action": "type", "characters": characters, "clear": false,
                           "submit": false], snapshot: nil)
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
