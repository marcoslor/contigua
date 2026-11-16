// Input calls on one window run one at a time, in arrival order across
// clients (MCP-84), and the input of every other source that reaches the
// window during a call is reported to that call. `MCPActRunner` drives one
// call's `MCPActMachine`: it owns the continuation, the deadline timer and the
// order its actions run in.

import Foundation

@MainActor
final class WindowActQueue {
    private var busy: Set<UInt32> = []
    private var waiting: [UInt32: [CheckedContinuation<Void, Never>]] = [:]
    private var listeners: [UInt32: (MCPActMachine.Event) -> Void] = [:]

    /// Wait for the window's turn.
    func enter(window: UInt32) async {
        guard busy.contains(window) else {
            busy.insert(window)
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiting[window, default: []].append(cont)
        }
    }

    /// The holder of the window's turn hears other input, the window's close
    /// and the link's loss until it leaves.
    func listen(window: UInt32, _ listener: @escaping (MCPActMachine.Event) -> Void) {
        listeners[window] = listener
    }

    func leave(window: UInt32) {
        listeners[window] = nil
        if var queue = waiting[window], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[window] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            busy.remove(window)
        }
    }

    /// Input from another source (`person`, `another_agent`) reached the
    /// window: the call holding its turn lists it in `alsoActed`.
    func report(window: UInt32, source: String) {
        listeners[window]?(.otherInput(source))
    }

    /// The window closed (MCP-83): the call holding its turn answers why.
    func closed(window: UInt32, reason: String, by: String) {
        listeners[window]?(.windowClosed(reason: reason, by: by))
    }

    /// The link went down: every call holding a turn answers or fails.
    func linkLost() {
        for listener in Array(listeners.values) { listener(.linkLost) }
    }
}

/// MCP-52's closed set of close reasons, from the phone's `window.closed`.
enum MCPCloseReason {
    static let all: Set<String> = ["closed", "app_exited", "moved_to_phone", "phone_closed",
                                   "open_failed", "phone_switched"]

    /// A reason outside the set is the app ending its own screen.
    static func token(phone reason: String) -> String {
        all.contains(reason) ? reason : "app_exited"
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
    func settle(quietMs: Int, timeoutMs: Int) async -> MCPSettleResult
    func readTree() async -> MCPTreeResult
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
    private let started = ContinuousClock.now

    private init(_ machine: MCPActMachine, env: MCPActEnvironment, window: UInt32, queue: WindowActQueue?) {
        self.machine = machine
        self.env = env
        self.window = window
        self.queue = queue
    }

    /// Run one call to its answer, within `deadline` from now (MCP-8). `ref`
    /// marks S1's ref tap, which the window's latest tree may refuse.
    static func run(_ machine: MCPActMachine, window: UInt32, queue: WindowActQueue?,
                    deadline: Duration, env: MCPActEnvironment, ref: Bool = false) async -> MCPActOutcome {
        let runner = MCPActRunner(machine, env: env, window: window, queue: queue)
        return await runner.run(deadline: deadline, ref: ref)
    }

    private func run(deadline: Duration, ref: Bool) async -> MCPActOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<MCPActOutcome, Never>) in
            continuation = cont
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: deadline)
                guard !Task.isCancelled, let self else { return }
                _ = self.feed(.deadline(waitedMs: self.elapsedMs))
            }
            Task { await self.drive(ref: ref) }
        }
    }

    private var elapsedMs: Int {
        let elapsed = ContinuousClock.now - started
        return Int(elapsed.components.seconds * 1000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private func drive(ref: Bool) async {
        var pending: [MCPActMachine.Action]
        switch machine.state {
        case .queued:
            if let queue {
                await queue.enter(window: window)
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
        default:
            pending = []
        }
        while !pending.isEmpty, continuation != nil {
            let action = pending.removeFirst()
            switch action {
            case .sendInput:
                await env.sendInput()
            case .sendPress:
                pending += feed(await env.sendPress())
            case .sendType:
                pending += feed(await env.sendType())
            case .sendSettle(let req, let quietMs, let timeoutMs):
                switch await env.settle(quietMs: quietMs, timeoutMs: timeoutMs) {
                case .reply(let settled, let waitedMs, let reason):
                    pending += feed(.settleReply(req: req, settled: settled, waitedMs: waitedMs, reason: reason))
                case .failed(let code):
                    pending += feed(.settleFailed(req: req, code: code))
                }
            case .sendTree(let req):
                switch await env.readTree() {
                case .ok(let tree): pending += feed(.treeReply(req: req, tree))
                case .failed(let code): pending += feed(.treeFailed(req: req, code: code))
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
        machine = next
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

    private func complete(_ outcome: MCPActOutcome) {
        deadlineTask?.cancel()
        releaseTurn()
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
