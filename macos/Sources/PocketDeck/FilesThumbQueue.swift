// One thumbnail at a time per request, at most three in flight, each bounded by
// an 8 s deadline measured from the ask (docs/specs/files.md FILES-25/29,
// docs/design/files.md "Thumbnails (S6)").
//
// The queue is a small state machine per request: one closed set of phases, one
// pure transition, and the side effects (send, cancel, answer) run from the
// returned actions. The queue itself is only the FIFO and the slot count; a
// finished request starts the next one.

import Foundation

/// The bytes a thumbnail request answered with.
struct FilesThumb: Equatable, Hashable {
    var data: [UInt8]
    var mime: String
    var sha256: String
}

/// What one request ends with; the bridge turns this into its reply.
enum ThumbAnswer: Equatable, Hashable {
    case success(FilesThumb)
    case failure(code: String)
}

enum ThumbPhase: Equatable, Hashable {
    case queued, running, done, cancelled, expired
}

enum ThumbEvent: Equatable, Hashable {
    case slotFree
    case end(FilesThumb)
    case failure(code: String)
    case cancel
    case deadline
    /// The session went away or the extension client closed.
    case drop
}

enum ThumbAction: Equatable, Hashable {
    case sendRequest
    case sendCancel
    case answer(ThumbAnswer)
}

/// What the queue needs from the app's live session.
@MainActor
protocol FilesThumbHost: AnyObject {
    func thumb(item: String, size: Int,
               onStart: @escaping (UInt32) -> Void,
               completion: @escaping (Result<FilesThumb, FsError>) -> Void)
    func cancel(id: UInt32)
}

@MainActor
final class FilesThumbQueue {
    static let limit = 3

    private final class Job {
        let id: UInt32
        let client: ObjectIdentifier
        let item: String
        let size: Int
        let host: any FilesThumbHost
        let answer: (ThumbAnswer) -> Void
        var phase: ThumbPhase = .queued
        var fsID: UInt32?
        var started = false
        var settled = false
        var answered = false
        var timer: DispatchWorkItem?

        init(id: UInt32, client: ObjectIdentifier, item: String, size: Int,
             host: any FilesThumbHost, answer: @escaping (ThumbAnswer) -> Void) {
            self.id = id
            self.client = client
            self.item = item
            self.size = size
            self.host = host
            self.answer = answer
        }
    }

    private var jobs: [UInt32: Job] = [:]
    private var order: [UInt32] = []
    private var running = 0
    private var scheduling = false

    /// Accepts one ask; it starts now or waits its turn.
    func request(id: UInt32, client: ObjectIdentifier, item: String, size: Int,
                 deadline: TimeInterval, host: any FilesThumbHost,
                 answer: @escaping (ThumbAnswer) -> Void) {
        guard jobs[id] == nil else { return }
        let job = Job(id: id, client: client, item: item, size: size, host: host, answer: answer)
        jobs[id] = job
        order.append(id)
        // From the ask, queue time included: a person sees the type icon
        // meanwhile, so a request that misses its turn is answered, not kept.
        let timer = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.advance(id, .deadline) }
        }
        job.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + max(deadline, 0.001), execute: timer)
        startNext()
    }

    @discardableResult
    func cancel(id: UInt32) -> Bool {
        guard jobs[id] != nil else { return false }
        advance(id, .cancel)
        return true
    }

    /// The extension client went away: its slots free at once.
    func cancel(client: ObjectIdentifier) {
        for job in Array(jobs.values) where job.client == client {
            advance(job.id, .cancel)
        }
    }

    /// The session went away; nothing left can be asked or cancelled.
    func reset() {
        for id in Array(jobs.keys) {
            advance(id, .drop)
        }
    }

    private func advance(_ id: UInt32, _ event: ThumbEvent) {
        guard let job = jobs[id], !job.settled else { return }
        let (next, actions) = Self.transition(job.phase, event)
        guard next != job.phase else { return }
        job.phase = next
        Log.files.notice("thumb: \(Self.token(job.phase), privacy: .public) --\(Self.token(event), privacy: .public)--> \(Self.token(next), privacy: .public)")
        for action in actions { perform(action, job) }
        if next == .done || next == .cancelled || next == .expired {
            settle(job)
        }
    }

    private func perform(_ action: ThumbAction, _ job: Job) {
        switch action {
        case .sendRequest:
            job.started = true
            running += 1
            job.host.thumb(item: job.item, size: job.size, onStart: { [weak job] fsID in
                job?.fsID = fsID
            }, completion: { [weak self] result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let thumb): self?.advance(job.id, .end(thumb))
                    case .failure(let error): self?.advance(job.id, .failure(code: error.code))
                    }
                }
            })
        case .sendCancel:
            if let fsID = job.fsID { job.host.cancel(id: fsID) }
        case .answer(let answer):
            guard !job.answered else { return }
            job.answered = true
            job.answer(answer)
        }
    }

    private func settle(_ job: Job) {
        guard !job.settled else { return }
        job.settled = true
        job.timer?.cancel()
        if job.started { running -= 1 }
        jobs[job.id] = nil
        order.removeAll { $0 == job.id }
        startNext()
    }

    private func startNext() {
        guard !scheduling else { return }
        scheduling = true
        defer { scheduling = false }
        while running < Self.limit {
            guard let id = order.first(where: { jobs[$0]?.phase == .queued }) else { break }
            advance(id, .slotFree)
        }
    }

    /// (state, event) -> (state, actions), exhaustive and side-effect free.
    static func transition(_ phase: ThumbPhase,
                           _ event: ThumbEvent) -> (ThumbPhase, [ThumbAction]) {
        switch (phase, event) {
        case (.queued, .slotFree):
            return (.running, [.sendRequest])
        case (.queued, .cancel):
            return (.cancelled, [.answer(.failure(code: "cancelled"))])
        case (.queued, .deadline):
            return (.expired, [.answer(.failure(code: "timeout"))])
        case (.queued, .drop):
            return (.cancelled, [.answer(.failure(code: "offline"))])
        case (.queued, .end(_)), (.queued, .failure(_)):
            return (phase, [])
        case (.running, .end(let thumb)):
            return (.done, [.answer(.success(thumb))])
        case (.running, .failure(let code)):
            return (.done, [.answer(.failure(code: code))])
        case (.running, .cancel):
            return (.cancelled, [.sendCancel, .answer(.failure(code: "cancelled"))])
        case (.running, .deadline):
            return (.expired, [.sendCancel, .answer(.failure(code: "timeout"))])
        case (.running, .drop):
            return (.cancelled, [.answer(.failure(code: "offline"))])
        case (.running, .slotFree):
            return (phase, [])
        case (.done, _), (.cancelled, _), (.expired, _):
            return (phase, [])
        }
    }

    private static func token(_ phase: ThumbPhase) -> String {
        switch phase {
        case .queued: return "queued"
        case .running: return "running"
        case .done: return "done"
        case .cancelled: return "cancelled"
        case .expired: return "expired"
        }
    }

    private static func token(_ event: ThumbEvent) -> String {
        switch event {
        case .slotFree: return "slot"
        case .end(_): return "end"
        case .failure(_): return "failure"
        case .cancel: return "cancel"
        case .deadline: return "deadline"
        case .drop: return "drop"
        }
    }
}
