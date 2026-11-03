// One thumbnail at a time per request, at most three in flight, each bounded by
// an 8 s deadline measured from the `fs.thumb` send — a queued ask waits for
// its turn, because queue time is not the phone's work (docs/specs/files.md
// FILES-25/29, docs/design/files.md "Thumbnails (S6)").
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
        let deadline: TimeInterval
        let host: any FilesThumbHost
        let answer: (ThumbAnswer) -> Void
        var phase: ThumbPhase = .queued
        var fsID: UInt32?
        var started = false
        var settled = false
        var answered = false
        var timer: DispatchWorkItem?  // gcd: one deadline timer per request

        init(id: UInt32, client: ObjectIdentifier, item: String, size: Int,
             deadline: TimeInterval, host: any FilesThumbHost,
             answer: @escaping (ThumbAnswer) -> Void) {
            self.id = id
            self.client = client
            self.item = item
            self.size = size
            self.deadline = deadline
            self.host = host
            self.answer = answer
        }
    }

    /// The id space is each bridge connection's own: two extensions may both
    /// ask for id 2, and they are different requests.
    private struct Key: Hashable {
        let client: ObjectIdentifier
        let id: UInt32
    }

    private var jobs: [Key: Job] = [:]
    private var order: [Key] = []
    private var running = 0
    private var scheduling = false

    /// Where a transition line goes. Production logs it to the files category;
    /// tests capture it, so both ends of the arrow are pinned (AGENTS.md).
    var logTransition: (String) -> Void = { line in
        Log.files.notice("\(line, privacy: .public)")
    }

    /// Accepts one ask; it starts now or waits its turn. The deadline is
    /// armed only when `fs.thumb` goes to the phone (FILES-29): a queued ask
    /// waits until it runs, Finder cancels it, or the session ends.
    func request(id: UInt32, client: ObjectIdentifier, item: String, size: Int,
                 deadline: TimeInterval, host: any FilesThumbHost,
                 answer: @escaping (ThumbAnswer) -> Void) {
        let key = Key(client: client, id: id)
        guard jobs[key] == nil else { return }
        let job = Job(id: id, client: client, item: item, size: size,
                      deadline: deadline, host: host, answer: answer)
        jobs[key] = job
        order.append(key)
        startNext()
    }

    @discardableResult
    func cancel(id: UInt32, client: ObjectIdentifier) -> Bool {
        let key = Key(client: client, id: id)
        guard jobs[key] != nil else { return false }
        advance(key, .cancel)
        return true
    }

    /// The extension client went away: its slots free at once.
    func cancel(client: ObjectIdentifier) {
        for key in Array(jobs.keys) where key.client == client {
            advance(key, .cancel)
        }
    }

    /// The session went away; nothing left can be asked or cancelled.
    func reset() {
        for key in Array(jobs.keys) {
            advance(key, .drop)
        }
    }

    private func advance(_ key: Key, _ event: ThumbEvent) {
        guard let job = jobs[key], !job.settled else { return }
        let before = job.phase
        let (next, actions) = Self.transition(before, event)
        guard next != before else { return }
        job.phase = next
        logTransition(Self.transitionLine(from: before, event: event, to: next))
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
            let key = Key(client: job.client, id: job.id)
            // The deadline starts here, at the phone's work, not at the ask.
            let timer = DispatchWorkItem { [weak self] in  // gcd: a deadline timer
                MainActor.assumeIsolated { self?.advance(key, .deadline) }
            }
            job.timer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + max(job.deadline, 0.001), execute: timer)  // gcd: a deadline hops back to the main actor
            job.host.thumb(item: job.item, size: job.size, onStart: { [weak job] fsID in
                job?.fsID = fsID
            }, completion: { [weak self] result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let thumb): self?.advance(key, .end(thumb))
                    case .failure(let error): self?.advance(key, .failure(code: error.code))
                    }
                }
            })
        case .sendCancel:
            if let fsID = job.fsID {
                job.host.cancel(id: fsID)
                Log.files.notice("thumb: cancel fs")
            } else {
                Log.files.notice("thumb: cancel without an fs id")
            }
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
        let key = Key(client: job.client, id: job.id)
        jobs[key] = nil
        order.removeAll { $0 == key }
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
            // Queue time is not the phone's work: a queued ask waits for its
            // turn, Finder's cancel, or the session's end (FILES-29).
            return (.queued, [])
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

    /// The one-line record of a transition: the phase it left, the event, the
    /// phase it entered. Pure so a test can pin both ends of the arrow.
    static func transitionLine(from: ThumbPhase, event: ThumbEvent, to: ThumbPhase) -> String {
        "thumb: \(token(from)) --\(token(event))--> \(token(to))"
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
