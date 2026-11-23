// Input calls on one window run one at a time, in arrival order across
// clients (MCP-84), and the person's input that reaches the window during a
// call is reported to that call. Every agent input is sent by the call that
// holds the window's turn, so no call sees another agent's input.
// `MCPActRunner` drives one call's `MCPActMachine`: it owns the continuation,
// the deadline timer and the order its actions run in.

import Foundation

@MainActor
final class WindowActQueue {
    private struct Waiter {
        let id: Int
        let client: MCPClientID?
        let cont: CheckedContinuation<Bool, Never>
    }

    private struct Holder {
        let client: MCPClientID?
        var listener: ((MCPActMachine.Event) -> Void)?
    }

    private var holders: [UInt32: Holder] = [:]
    private var waiting: [UInt32: [Waiter]] = [:]
    private var nextWaiter = 0

    /// Wait for the window's turn. False: the client left while it queued,
    /// and the call must send nothing (MCP-84).
    func enter(window: UInt32, client: MCPClientID? = nil) async -> Bool {
        guard holders[window] != nil else {
            holders[window] = Holder(client: client)
            return true
        }
        nextWaiter += 1
        let id = nextWaiter
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            waiting[window, default: []].append(Waiter(id: id, client: client, cont: cont))
        }
    }

    /// The holder of the window's turn hears other input, the window's close
    /// and the link's loss until it leaves.
    func listen(window: UInt32, _ listener: @escaping (MCPActMachine.Event) -> Void) {
        holders[window]?.listener = listener
    }

    func leave(window: UInt32) {
        if var queue = waiting[window], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[window] = queue.isEmpty ? nil : queue
            holders[window] = Holder(client: next.client)
            next.cont.resume(returning: true)
        } else {
            holders[window] = nil
        }
    }

    /// Run `body` holding the window's turn (input_probe, MCP-84).
    func exclusive<T>(window: UInt32, client: MCPClientID?, _ body: () async throws -> T) async rethrows -> T? {
        guard await enter(window: window, client: client) else { return nil }
        defer { leave(window: window) }
        return try await body()
    }

    /// Input from the person reached the window: the call holding its turn
    /// lists it in `alsoActed`.
    func report(window: UInt32, source: String) {
        holders[window]?.listener?(.otherInput(source))
    }

    /// The window closed (MCP-83): the call holding its turn answers why.
    func closed(window: UInt32, reason: String, by: String) {
        holders[window]?.listener?(.windowClosed(reason: reason, by: by))
    }

    /// The Mac closed the window itself (MCP-52): `you` or `another_agent`
    /// as the holder's connection sees the closer, `person` for no connection.
    func macClosed(window: UInt32, by closer: MCPClientID?) {
        guard let holder = holders[window] else { return }
        let closed = MCPCloseReason.mac(closer: closer, asker: holder.client)
        holder.listener?(.windowClosed(reason: closed.reason, by: closed.by))
    }

    /// The link went down: every call holding a turn answers or fails.
    func linkLost() {
        for listener in holders.values.compactMap(\.listener) { listener(.linkLost) }
    }

    /// A connection closed: its queued calls leave without sending, and its
    /// running ones end with no answer (MCP-84).
    func clientGone(_ client: MCPClientID) {
        for (window, queue) in waiting {
            let gone = queue.filter { $0.client == client }
            guard !gone.isEmpty else { continue }
            let kept = queue.filter { $0.client != client }
            waiting[window] = kept.isEmpty ? nil : kept
            for waiter in gone { waiter.cont.resume(returning: false) }
        }
        for holder in holders.values where holder.client == client {
            holder.listener?(.clientGone)
        }
    }
}

/// MCP-52's closed set of close reasons, from the phone's `window.closed`.
enum MCPCloseReason {
    static let all: Set<String> = ["closed", "app_exited", "moved_to_phone", "phone_closed",
                                   "open_failed", "phone_switched"]

    /// The phone's `requested`/`error` is `phone_closed` (design/mcp.md
    /// "Close reasons"); a reason outside the set is the app ending its own
    /// screen.
    static func token(phone reason: String) -> String {
        switch reason {
        case "requested", "error": return "phone_closed"
        default: return all.contains(reason) ? reason : "app_exited"
        }
    }

    /// The Mac closed the stream itself: ⌘W, the close light, Close All
    /// (`person`) or a connection's `close_window` (`you` to that connection,
    /// `another_agent` to every other; MCP-52).
    static func mac(closer: MCPClientID?, asker: MCPClientID?) -> MCPActMachine.Closed {
        guard let closer else { return MCPActMachine.Closed(reason: "closed", by: "person") }
        return MCPActMachine.Closed(reason: "closed", by: closer == asker ? "you" : "another_agent")
    }
}

enum MCPSettleResult: Equatable {
    case reply(settled: Bool, waitedMs: Int, reason: String?)
    case failed(String)
}

enum MCPTreeResult: Equatable {
    /// The `ui_tree` answer's JSON text.
    case ok(String)
    case failed(String)
}

enum MCPActOutcome: Equatable {
    case answer(MCPActMachine.Answer)
    case fail(String)
}

/// What one call's actions do: the window, the phone and the session.
@MainActor
protocol MCPActEnvironment: AnyObject {
    func windowCondition() -> MCPActMachine.Condition
    /// S1: for a ref tap, the refusal code when the window's latest tree
    /// refuses the ref; nil to press.
    func refusal() -> String?
    func sendInput() async
    func sendPress() async -> MCPActMachine.Event
    func sendType() async -> MCPActMachine.Event
    /// `until`: the call's own deadline; a read queued past it fails `timeout` (MCP-9).
    func settle(quietMs: Int, timeoutMs: Int, until: ContinuousClock.Instant) async -> MCPSettleResult
    func readTree(until: ContinuousClock.Instant) async -> MCPTreeResult
    /// Opening (MCP-41): feed the open's `windowOpened`, `firstFrame`,
    /// `openFailed` and `windowClosed` as they happen.
    func watchOpen(_ feed: @escaping @MainActor (MCPActMachine.Event) -> Void)
    func stopWatchingOpen()
}

extension MCPActEnvironment {
    func watchOpen(_ feed: @escaping @MainActor (MCPActMachine.Event) -> Void) {}
    func stopWatchingOpen() {}
}

@MainActor
final class MCPActRunner {
    private var machine: MCPActMachine
    private let env: MCPActEnvironment
    private let window: UInt32
    private let queue: WindowActQueue?
    private var continuation: CheckedContinuation<MCPActOutcome, Never>?
    private var holdsTurn = false
    private var deadlineTask: Task<Void, Never>?
    private let client: MCPClientID?
    private var deadlineAt = ContinuousClock.now
    /// When `sendSettle` went out: the deadline's `waitedMs` counts from it (MCP-8).
    private var settleSentAt: ContinuousClock.Instant?
    /// Opening: `drive` waits here until the machine leaves Opening.
    private var openWait: CheckedContinuation<[MCPActMachine.Action], Never>?
    private var openBoundTask: Task<Void, Never>?

    private init(_ machine: MCPActMachine, env: MCPActEnvironment, window: UInt32, queue: WindowActQueue?,
                 client: MCPClientID?) {
        self.machine = machine
        self.env = env
        self.window = window
        self.queue = queue
        self.client = client
    }

    /// Run one call to its answer, within `deadline` from now (MCP-8). `ref`
    /// marks S1's ref tap, which the window's latest tree may refuse.
    static func run(_ machine: MCPActMachine, window: UInt32, queue: WindowActQueue?,
                    deadline: Duration, env: MCPActEnvironment, ref: Bool = false,
                    client: MCPClientID? = nil) async -> MCPActOutcome {
        let runner = MCPActRunner(machine, env: env, window: window, queue: queue, client: client)
        return await runner.run(deadline: deadline, ref: ref)
    }

    private func run(deadline: Duration, ref: Bool) async -> MCPActOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<MCPActOutcome, Never>) in
            continuation = cont
            deadlineAt = .now + deadline
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled, let self else { return }
                _ = self.feed(.deadline(waitedMs: self.settleSentAt.map { Self.ms(.now - $0) }))
            }
            Task { await self.drive(ref: ref) }
        }
    }

    private static func ms(_ elapsed: Duration) -> Int {
        Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func drive(ref: Bool) async {
        var pending: [MCPActMachine.Action]
        switch machine.state {
        case .queued:
            if let queue {
                guard await queue.enter(window: window, client: client) else {
                    _ = feed(.clientGone)  // the client left while the call queued: nothing is sent
                    return
                }
                holdsTurn = true
                if machine.state == .done {  // the deadline ended the call while it queued
                    releaseTurn()
                    return
                }
                queue.listen(window: window) { [weak self] event in
                    _ = self?.feed(event)
                }
            }
            let condition = env.windowCondition()
            if condition == .live, ref, let code = env.refusal() {
                pending = feed(.refused(code))
            } else {
                pending = feed(.turn(condition))
            }
        case .sent:
            pending = feed(.entry)
        case .opening:
            pending = await withCheckedContinuation { (cont: CheckedContinuation<[MCPActMachine.Action], Never>) in
                openWait = cont
                openBoundTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(MCPActMachine.openBoundMs))
                    guard !Task.isCancelled else { return }
                    _ = self?.feed(.openBound)
                }
                env.watchOpen { [weak self] event in _ = self?.feed(event) }
            }
        default:
            pending = []
        }
        while !pending.isEmpty, continuation != nil {
            let action = pending.removeFirst()
            switch action {
            case .sendInput:
                await env.sendInput()
                // Fed even after an answer: a draining call releases the turn here.
                pending += feed(.inputSent)
            case .sendPress:
                pending += feed(await env.sendPress())
            case .sendType:
                pending += feed(await env.sendType())
            case .sendSettle(let req, let quietMs, let timeoutMs):
                settleSentAt = .now
                switch await env.settle(quietMs: quietMs, timeoutMs: timeoutMs, until: deadlineAt) {
                case .reply(let settled, let waitedMs, let reason):
                    pending += feed(.settleReply(req: req, settled: settled, waitedMs: waitedMs, reason: reason))
                case .failed(let code):
                    pending += feed(.settleFailed(req: req, code: code))
                }
            case .sendTree(let req):
                switch await env.readTree(until: deadlineAt) {
                case .ok(let tree): pending += feed(.treeReply(req: req, tree))
                case .failed(let code): pending += feed(.treeFailed(req: req, code: code))
                }
            case .waitForClose(let ms):
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(ms))
                    _ = self?.feed(.closeWaitOver)
                }
            case .answer(let answer):
                complete(.answer(answer))  // after the sends before it
            case .fail(let code):
                complete(.fail(code))
            }
        }
    }

    /// Step the machine; an answer or failure completes the call at once, the
    /// sends are returned for `drive` to run in order.
    func feed(_ event: MCPActMachine.Event) -> [MCPActMachine.Action] {
        let (next, actions) = MCPActMachine.step(machine, event)
        let wasOpening = machine.state == .opening
        machine = next
        if wasOpening, machine.state != .opening {
            return leftOpening(actions, after: event)
        }
        // The turn is released only when Done: a draining call still has
        // its input going out (MCP-84).
        if machine.state == .done { releaseTurn() }
        // An answer that follows sends in the same step (wait none, observe
        // none) waits for `drive` to run them first; one alone answers now.
        let sends = actions.filter {
            switch $0 {
            case .answer, .fail: return false
            default: return true
            }
        }
        if !sends.isEmpty { return actions }
        for action in actions {
            switch action {
            case .answer(let answer): complete(.answer(answer))
            case .fail(let code): complete(.fail(code))
            default: break
            }
        }
        if event == .clientGone, continuation != nil {
            // clientGone: no answer, but the waiter still returns.
            complete(.fail("cancelled"))
        }
        return []
    }

    /// The open is over: its sends go to `drive`, an answer completes now.
    private func leftOpening(_ actions: [MCPActMachine.Action], after event: MCPActMachine.Event) -> [MCPActMachine.Action] {
        openBoundTask?.cancel()
        var sends: [MCPActMachine.Action] = []
        for action in actions {
            switch action {
            case .answer(let answer) where sends.isEmpty: complete(.answer(answer))
            case .fail(let code) where sends.isEmpty: complete(.fail(code))
            default: sends.append(action)
            }
        }
        if event == .clientGone, continuation != nil { complete(.fail("cancelled")) }
        let wait = openWait
        openWait = nil
        wait?.resume(returning: sends)
        return []
    }

    private func complete(_ outcome: MCPActOutcome) {
        deadlineTask?.cancel()
        openBoundTask?.cancel()
        env.stopWatchingOpen()
        if machine.state == .done { releaseTurn() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }

    private func releaseTurn() {
        guard holdsTurn else { return }
        holdsTurn = false
        queue?.leave(window: window)
    }
}
