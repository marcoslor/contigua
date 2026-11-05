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
        case arrive(Sample)
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
        /// Count one Mac drop (`mac_drop`, reason paced).
        case dropOldest
    }

    /// More than this waiting is a backlog the refresh cannot clear in time:
    /// the oldest goes.
    static var maxWaiting: Int { 2 }

    private(set) var phase: Phase = .idle
    private(set) var waiting: [Sample] = []

    var hasWaiting: Bool { !waiting.isEmpty }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .arrive(let sample):
            return arrive(sample)
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

    private mutating func arrive(_ sample: Sample) -> [Action] {
        var actions: [Action] = []
        let wasIdle = phase == .idle
        waiting.append(sample)
        if waiting.count > Self.maxWaiting {
            waiting.removeFirst()
            actions.append(.dropOldest)
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
        let sample = waiting.removeFirst()
        phase = waiting.isEmpty ? .idle : .presenting
        return [.show(sample)]
    }
}

extension PacedPresenter.Action: Equatable where Sample: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.startLink, .startLink), (.stopLink, .stopLink), (.dropOldest, .dropOldest):
            return true
        case (.show(let left), .show(let right)):
            return left == right
        default:
            return false
        }
    }
}
