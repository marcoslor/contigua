// WIN-61's reference-chain state machine. A decoder can start only on a
// keyframe: after a flush, a config change or a discarded frame, every delta
// refers to pictures the decoder no longer has. The states and the transition
// are pure; the view performs the returned actions.
//
// `not_ready` and the pacer's catch-up are not breaks: AVFoundation accepts an
// enqueue while the layer is not ready (it queues it), and the catch-up hands
// every waiting sample over in order, so neither loses a reference.

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
        /// The VIDEO_CHUNK assembler threw an incomplete access unit away
        /// (a different pts arrived, a bad payload, or the stream closed):
        /// the next delta references a picture the decoder will never get.
        case incomplete
    }

    enum State: Equatable {
        /// Every sample may be fed; the decoder has its references.
        case flowing
        /// A break: only a keyframe may reach the decoder. `retried` says the
        /// one follow-up request has gone out.
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

    /// One follow-up request, half a second after the first.
    static let retryDelay: TimeInterval = 0.5

    private(set) var state: State = .flowing

    var isAwaitingKey: Bool {
        if case .awaitingKey = state { return true }
        return false
    }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .breakChain(let reason, let now):
            // A second break restarts the clock: the restore is timed from the
            // last flush the picture actually saw.
            state = .awaitingKey(reason, since: now, retried: false)
            return [.logBroken(reason), .requestKeyframe, .scheduleRetry]
        case .retryDue:
            guard case .awaitingKey(let reason, let since, let retried) = state,
                  !retried else { return [] }
            state = .awaitingKey(reason, since: since, retried: true)
            return [.requestKeyframe]
        case .sample(let isKeyframe, let now):
            guard case .awaitingKey(_, let since, _) = state else { return [.feed] }
            guard isKeyframe else { return [.drop] }
            state = .flowing
            let ms = max(0, (now - since) * 1000)
            return [.feed, .logRestored(afterMs: Int(ms.rounded())), .cancelRetry]
        case .reset:
            guard isAwaitingKey else { return [] }
            state = .flowing
            return [.cancelRetry]
        }
    }
}
