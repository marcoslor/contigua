// One `ui.*` request at a time per phone (MCP-9, PROTOCOL.md "UI tree" item
// 6): `ui.tree`, `ui.settle` and, later, `ui.press` and `ui.type` wait their
// turn here in arrival order across every client, so the phone never answers
// `busy` to the Mac. It takes over #162's per-session serialisation of
// `ui.tree` (F6). The caller is answered by its own bound, queueing included;
// a request that went out keeps the queue until the phone answers it or its
// own wait ends, even after its caller gave up.

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

    /// Run `body`, one phone request bounded by its own broker's wait, when
    /// every earlier request has finished. The caller is answered by `until`
    /// (MCP-9): still queued then, the request leaves unsent; running then,
    /// the caller gets `timedOut` while the request keeps the queue until the
    /// phone answers it or its own wait ends, so the next request never meets
    /// the phone's `busy`.
    func run<T>(until: ContinuousClock.Instant,
                _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await run(queuedUntil: until, answeredBy: until, body)
    }

    /// Like `run(until:)`, but once the request is sent the caller waits for
    /// it: its broker carries the whole bound (`ui.type`, whose text the
    /// phone may still be typing, MCP-109). Still queued at `queuedUntil`,
    /// it leaves unsent with `timedOut`.
    func run<T>(queuedUntil: ContinuousClock.Instant,
                _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await run(queuedUntil: queuedUntil, answeredBy: nil, body)
    }

    private func run<T>(queuedUntil until: ContinuousClock.Instant, answeredBy: ContinuousClock.Instant?,
                        _ body: @escaping @MainActor () async throws -> T) async throws -> T {
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
        guard until > .now else {
            release()
            throw UITreeError.timedOut
        }
        let answer = Answer<T>()
        return try await answer.wait(until: answeredBy) {
            Task { @MainActor [weak self] in
                let result: Result<T, Error>
                do { result = .success(try await body()) } catch { result = .failure(error) }
                self?.release()  // only now: the phone is done with it
                answer.finish(result)
            }
        }
    }

    /// One caller's answer: the request's result, or `timedOut` at the
    /// caller's bound, whichever comes first; with no bound, the result.
    @MainActor private final class Answer<T> {
        private var cont: CheckedContinuation<T, Error>?
        private var timer: Task<Void, Never>?

        func wait(until: ContinuousClock.Instant?, start: () -> Void) async throws -> T {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                self.cont = cont
                if let until {
                    timer = Task { @MainActor [weak self] in
                        try? await Task.sleep(until: until, clock: .continuous)
                        guard !Task.isCancelled else { return }
                        self?.finish(.failure(UITreeError.timedOut))
                    }
                }
                start()
            }
        }

        func finish(_ result: Result<T, Error>) {
            timer?.cancel()
            guard let cont else { return }
            self.cont = nil
            cont.resume(with: result)
        }
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
    func run<T>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        try await run(until: .now + .seconds(3600), body)
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

    /// Waits the phone's own bound, `timeoutMs` + `grace`, even when its
    /// caller gave up sooner: the phone's read queue stays held until then
    /// (MCP-9).
    func settle(stream: UInt32, quietMs: Int, timeoutMs: Int, grace: TimeInterval = UISettleBroker.grace,
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

/// The phone's `ui.press` reply (PROTOCOL.md "UI tree" item 8, MCP-86).
struct UIPressReply: Equatable {
    let seq: Int
    let stream: UInt32
    let ok: Bool
    let box: [Int]?
    /// The point pressed, 0..1 of the display's input space.
    let at: [Double]?
    let role: String?
    let text: String?
    let desc: String?
    let code: String?
    /// The cover as a ref (`e<k>`) or `"window"` (MCP-89).
    let coveredBy: String?
    /// The label read at the press, on `changed` (#188).
    let now: String?

    init(seq: Int, stream: UInt32, ok: Bool, box: [Int]? = nil, at: [Double]? = nil,
         role: String? = nil, text: String? = nil, desc: String? = nil, code: String? = nil,
         coveredBy: String? = nil, now: String? = nil) {
        self.seq = seq
        self.stream = stream
        self.ok = ok
        self.box = box
        self.at = at
        self.role = role
        self.text = text
        self.desc = desc
        self.code = code
        self.coveredBy = coveredBy
        self.now = now
    }

    init?(message: JSONMessage) {
        guard let ok = message.bool("ok"), let stream = message.int("stream") else { return nil }
        var cover: String?
        if let key = message.raw["coveredBy"] as? Int { cover = "e\(key)" }
        else if let word = message.raw["coveredBy"] as? String { cover = word }
        self.init(seq: message.int("seq") ?? 0, stream: UInt32(max(0, stream)), ok: ok,
                  box: (message.raw["box"] as? [NSNumber])?.map(\.intValue),
                  at: (message.raw["at"] as? [NSNumber])?.map(\.doubleValue),
                  role: message.string("role"), text: message.string("text"),
                  desc: message.string("desc"), code: message.string("code"),
                  coveredBy: cover, now: message.string("now"))
    }
}

/// Pairs each `ui.press` with its reply by `seq`; a silent phone fails
/// `timedOut` after the hold plus the read deadline, a late reply is ignored.
@MainActor
final class UIPressBroker {
    private var seq = 0
    private var waiters: [Int: CheckedContinuation<UIPressReply, Error>] = [:]

    func press(holdMs: Int, send: (Int) -> Void) async throws -> UIPressReply {
        seq += 1
        let id = seq
        let wait = Double(holdMs) / 1000 + UITreeBroker.deadline
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UIPressReply, Error>) in
            waiters[id] = cont
            send(id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                self?.finish(id: id, .failure(UITreeError.timedOut))
            }
        }
    }

    func reply(_ reply: UIPressReply) { finish(id: reply.seq, .success(reply)) }

    func fail(_ error: UITreeError) {
        let waiting = Array(waiters.values)
        waiters.removeAll()
        for waiter in waiting { waiter.resume(throwing: error) }
    }

    private func finish(id: Int, _ result: Result<UIPressReply, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume(with: result)
    }
}

/// What a `ui.press` came to: the phone's reply, or a failure before one.
enum UIPressResult {
    case reply(UIPressReply)
    case failed(String)

    /// Internal: the call was cancelled (its client left) after the press may
    /// have gone out. The machine sees it as `failed`.
    static let cancelled = "cancelled"
}
