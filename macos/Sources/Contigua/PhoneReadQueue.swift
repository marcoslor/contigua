// One `ui.*` request at a time per phone (MCP-9, PROTOCOL.md "UI tree" item
// 6): `ui.tree`, `ui.settle` and, later, `ui.press` and `ui.type` wait their
// turn here in arrival order across every client, so the phone never answers
// `busy` to the Mac. It takes over #162's per-session serialisation of
// `ui.tree` (F6). The wait counts toward the caller's bound: the caller's own
// deadline runs while it queues.

import Foundation

@MainActor
final class PhoneReadQueue {
    private enum Turn { case holds, failed, timedOut }

    private struct Waiter {
        let id: Int
        let cont: CheckedContinuation<Turn, Never>
    }

    private var running = false
    private var waiting: [Waiter] = []
    private var nextWaiter = 0
    private var lastFailure: Error = UITreeError.notConnected

    /// Run `body` when every earlier request has finished, within the
    /// caller's bound `until` (MCP-9): a waiter still queued at `until`
    /// leaves the queue unsent and fails `timedOut`, and `body` is given only
    /// the time left.
    func run<T>(until: ContinuousClock.Instant, _ body: (Duration) async throws -> T) async throws -> T {
        if running {
            nextWaiter += 1
            let id = nextWaiter
            let timer = Task { [weak self] in
                try? await Task.sleep(until: until, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.expire(id)
            }
            let turn = await withCheckedContinuation { (cont: CheckedContinuation<Turn, Never>) in
                waiting.append(Waiter(id: id, cont: cont))
            }
            timer.cancel()
            switch turn {
            case .holds: break
            case .failed: throw lastFailure
            case .timedOut: throw UITreeError.timedOut
            }
        } else {
            running = true
        }
        defer { release() }
        let left = until - .now
        guard left > .zero else { throw UITreeError.timedOut }
        return try await body(left)
    }

    /// The session ended: every queued request fails without being sent. The
    /// running one fails through its own broker.
    func fail(_ error: Error) {
        lastFailure = error
        let failed = waiting
        waiting.removeAll()
        for waiter in failed { waiter.cont.resume(returning: .failed) }
    }

    private func expire(_ id: Int) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).cont.resume(returning: .timedOut)
    }

    private func release() {
        if waiting.isEmpty {
            running = false
        } else {
            waiting.removeFirst().cont.resume(returning: .holds)
        }
    }
}

extension PhoneReadQueue {
    /// No caller bound: tests and reads whose broker carries the whole bound.
    func run<T>(_ body: () async throws -> T) async throws -> T {
        try await run(until: .now + .seconds(3600)) { _ in try await body() }
    }
}

extension Duration {
    /// In seconds, for the brokers' `TimeInterval` deadlines.
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// The phone's `ui.settle` reply (PROTOCOL.md "UI tree" item 7).
struct UISettleReply: Equatable {
    let seq: Int
    let stream: UInt32
    let ok: Bool
    let settled: Bool
    let waitedMs: Int
    let events: Int
    /// `changes` or `loading`, only when not settled (MCP-107).
    let reason: String?
    let code: String?

    init(seq: Int, stream: UInt32, ok: Bool, settled: Bool, waitedMs: Int, events: Int,
         reason: String?, code: String?) {
        self.seq = seq
        self.stream = stream
        self.ok = ok
        self.settled = settled
        self.waitedMs = waitedMs
        self.events = events
        self.reason = reason
        self.code = code
    }

    init?(message: JSONMessage) {
        guard let ok = message.bool("ok"), let stream = message.int("stream") else { return nil }
        self.init(seq: message.int("seq") ?? 0, stream: UInt32(max(0, stream)), ok: ok,
                  settled: message.bool("settled") ?? false,
                  waitedMs: message.int("waitedMs") ?? 0,
                  events: message.int("events") ?? 0,
                  reason: message.string("reason"), code: message.string("code"))
    }
}

/// Pairs each `ui.settle` with its reply by `seq`. The Mac waits the request's
/// own `timeoutMs` plus its read deadline (`grace`); a silent phone fails
/// `timedOut`, and a late reply finds no waiter and is ignored.
@MainActor
final class UISettleBroker {
    /// The phone answers by `timeoutMs` + 2.5 s; the Mac adds 3 s for the
    /// link (MCP-9).
    nonisolated static let grace: TimeInterval = 5.5

    private var seq = 0
    private var waiters: [Int: CheckedContinuation<UISettleReply, Error>] = [:]

    /// `within`: the caller's time left (MCP-9); the wait is never longer.
    func settle(stream: UInt32, quietMs: Int, timeoutMs: Int, grace: TimeInterval = UISettleBroker.grace,
                within: TimeInterval? = nil, send: (Int) -> Void) async throws -> UISettleReply {
        seq += 1
        let id = seq
        let own = Double(timeoutMs) / 1000 + max(0, grace)
        let wait = within.map { min(own, max(0, $0)) } ?? own
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UISettleReply, Error>) in
            waiters[id] = cont
            send(id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self?.finish(id: id, .failure(UITreeError.timedOut))
            }
        }
    }

    func reply(_ reply: UISettleReply) {
        finish(id: reply.seq, .success(reply))
    }

    func fail(_ error: UITreeError) {
        let waiting = Array(waiters.values)
        waiters.removeAll()
        for waiter in waiting { waiter.resume(throwing: error) }
    }

    private func finish(id: Int, _ result: Result<UISettleReply, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(with: result)
    }
}
