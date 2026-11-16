// One `ui.*` request at a time per phone (MCP-9, PROTOCOL.md "UI tree" item
// 6): `ui.tree`, `ui.settle` and, later, `ui.press` and `ui.type` wait their
// turn here in arrival order across every client, so the phone never answers
// `busy` to the Mac. It takes over #162's per-session serialisation of
// `ui.tree` (F6). The wait counts toward the caller's bound: the caller's own
// deadline runs while it queues.

import Foundation

@MainActor
final class PhoneReadQueue {
    private var running = false
    /// Each waiter is resumed with true when it holds the slot, false when the
    /// session it queued for ended (it never sends).
    private var waiting: [CheckedContinuation<Bool, Never>] = []
    private var lastFailure: Error = UITreeError.notConnected

    /// Run `body` when every earlier request has finished.
    func run<T>(_ body: () async throws -> T) async throws -> T {
        if running {
            let holds = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                waiting.append(cont)
            }
            guard holds else { throw lastFailure }
        } else {
            running = true
        }
        defer { release() }
        return try await body()
    }

    /// The session ended: every queued request fails without being sent. The
    /// running one fails through its own broker.
    func fail(_ error: Error) {
        lastFailure = error
        let failed = waiting
        waiting.removeAll()
        for waiter in failed { waiter.resume(returning: false) }
    }

    private func release() {
        if waiting.isEmpty {
            running = false
        } else {
            waiting.removeFirst().resume(returning: true)
        }
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
    private var seq = 0
    private var waiters: [Int: CheckedContinuation<UISettleReply, Error>] = [:]

    func settle(stream: UInt32, quietMs: Int, timeoutMs: Int, grace: TimeInterval,
                send: (Int) -> Void) async throws -> UISettleReply {
        seq += 1
        let id = seq
        let wait = Double(timeoutMs) / 1000 + max(0, grace)
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
