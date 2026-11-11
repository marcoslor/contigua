// M1's paced presentation (ISS-40): decoded samples wait for the window's
// display refresh instead of being shown on arrival. A closed set of states and
// one pure transition function; the view performs the actions.

import Foundation

struct PacedPresenter<Sample> {
    /// `presenting` means the last refresh handed a sample over and more may
    /// still wait; `idle` means nothing is waiting.
    enum Phase: Equatable {
        case idle
        case waiting
        case presenting

        var token: String {
            switch self {
            case .idle: return "idle"
            case .waiting: return "waiting"
            case .presenting: return "presenting"
            }
        }
    }

    enum Event {
        case arrive(Sample, isKeyframe: Bool)
        case tick
        case flush
        case pause
        case close

        var token: String {
            switch self {
            case .arrive: return "arrive"
            case .tick: return "tick"
            case .flush: return "flush"
            case .pause: return "pause"
            case .close: return "close"
            }
        }
    }

    enum Action {
        /// Run the window's display link (idempotent).
        case startLink
        /// The link is not wanted any more (idempotent).
        case stopLink
        /// Hand this sample to the display layer.
        case show(Sample)
        /// A backlog was handed over at once: `skipped` frames reached the
        /// layer without their own refresh (counted as `mac_drop`, reason
        /// paced). Every frame is still decoded, so no keyframe is needed.
        case caughtUp(skipped: Int)
    }

    /// More than this waiting is a backlog the refresh cannot clear in time:
    /// everything waiting is handed over at once (never dropped: the samples
    /// are encoded frames, and a gap would break the chain until a keyframe).
    static var maxWaiting: Int { 2 }

    private struct Waiting {
        var sample: Sample
        var isKeyframe: Bool
    }

    private(set) var phase: Phase = .idle
    private var waiting: [Waiting] = []

    var hasWaiting: Bool { !waiting.isEmpty }
    var waitingSamples: [Sample] { waiting.map(\.sample) }
    /// A keyframe already waits: no need to ask the phone for another one when
    /// a delta falls out of the queue.
    var hasKeyframeWaiting: Bool { waiting.contains(where: \.isKeyframe) }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .arrive(let sample, let isKeyframe):
            return arrive(sample, isKeyframe: isKeyframe)
        case .tick:
            return tick()
        case .flush:
            // A new VIDEO_CONFIG: the old format's samples cannot be shown.
            // The layer flush is the caller's; the link stays up.
            waiting.removeAll()
            phase = .idle
            return []
        case .pause, .close:
            waiting.removeAll()
            phase = .idle
            return [.stopLink]
        }
    }

    private mutating func arrive(_ sample: Sample, isKeyframe: Bool) -> [Action] {
        var actions: [Action] = []
        let wasIdle = phase == .idle
        waiting.append(Waiting(sample: sample, isKeyframe: isKeyframe))
        if waiting.count > Self.maxWaiting {
            // Catch up: hand every waiting frame to the layer now, in order.
            // The layer decodes them all and the next refresh shows the newest.
            if wasIdle { actions.append(.startLink) }
            actions.append(contentsOf: waiting.map { .show($0.sample) })
            actions.append(.caughtUp(skipped: waiting.count - 1))
            waiting.removeAll()
            phase = .idle
            return actions
        }
        // A new sample always waits for the next refresh, even when the last
        // one was just shown (`presenting`).
        phase = .waiting
        if wasIdle { actions.insert(.startLink, at: 0) }
        return actions
    }

    private mutating func tick() -> [Action] {
        guard phase != .idle, !waiting.isEmpty else {
            phase = .idle
            return []
        }
        let sample = waiting.removeFirst().sample
        phase = waiting.isEmpty ? .idle : .presenting
        return [.show(sample)]
    }
}

extension PacedPresenter.Action: Equatable where Sample: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.startLink, .startLink), (.stopLink, .stopLink):
            return true
        case (.caughtUp(let left), .caughtUp(let right)):
            return left == right
        case (.show(let left), .show(let right)):
            return left == right
        default:
            return false
        }
    }
}
