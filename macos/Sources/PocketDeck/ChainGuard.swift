// WIN-61's reference-chain state machine. A decoder can start only on a
// keyframe: after a flush, a config change or a discarded frame, every delta
// refers to pictures the decoder no longer has. The states and the transition
// are pure; the view performs the returned actions.
//
// RED (item 2): today's feed records the break and still hands every sample
// over, which is the corruption the brief names. The transitions the tests
// expect are the fix's; this body exists so the failing run names the rule.

import Foundation

struct ChainGuard {
    /// The closed set the `chain broken reason=` line carries.
    enum Reason: String, CaseIterable {
        /// A VIDEO_CONFIG: the layer was flushed for the new format.
        case config
        /// The layer said it needs a flush (failed or requires one).
        case flush
        /// A frame arrived with no config to decode it.
        case beforeConfig = "before_config"
        /// The layer failed after a sample was enqueued.
        case layerFailed = "layer_failed"
    }

    enum State: Equatable {
        case flowing
        case awaitingKey(Reason, since: TimeInterval, retried: Bool)
    }

    enum Event: Equatable {
        case breakChain(Reason, now: TimeInterval)
        case sample(isKeyframe: Bool, now: TimeInterval)
        case retryDue
        case reset
    }

    enum Action: Equatable {
        case logBroken(Reason)
        case requestKeyframe
        case scheduleRetry
        case cancelRetry
        case feed
        case drop
        case logRestored(afterMs: Int)
    }

    /// One retry, half a second after the first request.
    static let retryDelay: TimeInterval = 0.5

    private(set) var state: State = .flowing

    var isAwaitingKey: Bool {
        if case .awaitingKey = state { return true }
        return false
    }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .breakChain(let reason, let now):
            state = .awaitingKey(reason, since: now, retried: false)
            return [.logBroken(reason)]
        case .sample:
            return [.feed]
        case .retryDue, .reset:
            return []
        }
    }
}
