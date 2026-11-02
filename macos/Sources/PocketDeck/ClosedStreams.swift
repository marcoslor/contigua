// The streams this Session has closed, so nothing else is sent for them
// (WIN-38). The phone forgets a stream at its `window.close` and answers any
// later per-stream message with `error no_stream` (PROTOCOL.md "Error codes"),
// and the Mac used to leak two of them on a person's close: the mapper's
// throttled hover flush and the closing window's occlusion pause. They arrived
// after the close, the phone refused them, and the launcher turned the refusal
// into "That window is no longer open on the phone".
//
// One machine: the closed set, the protocol names that open and close a stream,
// and a pure decision for every other per-stream message. The Session owns it
// and asks it at one point, before any bytes go out, so no caller can bypass
// the gate with its own flag.

import Foundation

struct ClosedStreams: Equatable {
    enum Decision: Equatable {
        /// The message goes out.
        case send
        /// The message is for a stream the Mac has already closed: drop it.
        case drop
    }

    /// The messages that (re)open a stream: a reused id is live again.
    static let opening: Set<String> = ["window.open", "link.open", "task.continue"]
    /// The one message that closes a stream, and the last one sent for it.
    static let closing = "window.close"

    private(set) var ids: Set<UInt32> = []
    /// The streams the Mac has open right now: a mirrored app window runs
    /// with the phone's screen off, and that counts as activity (RR-9).
    private(set) var open: Set<UInt32> = []
    /// Open streams whose picture is paused or covered on the Mac: their
    /// silence is expected, so PATH-24 never probes for them.
    private(set) var paused: Set<UInt32> = []

    /// True while any stream the Mac opened is not closed: D-1's "a stream
    /// runs" half of the fast-ping rule.
    var hasOpenStream: Bool { !open.isEmpty }

    /// True while a stream is open and its picture is expected to move: the
    /// silence probe's other half (PATH-24). A paused or covered stream sends
    /// no frames by design, so its silence proves nothing.
    var hasLiveStream: Bool { !open.subtracting(paused).isEmpty }

    /// Decide one per-stream message. `type` is its protocol name
    /// (`window.pause`, `hover`, …), `stream` the id it carries.
    mutating func decide(type: String, stream: UInt32) -> Decision {
        if Self.opening.contains(type) {
            // RRR-5: only an accepted send [opened] makes it open, so a
            // `window.open` dropped before founding (E-2) never counts.
            ids.remove(stream)
            return .send
        }
        if type == Self.closing {
            // A second close is late too: the phone has forgotten the stream
            // and answers no_stream. The first one ends it.
            guard !ids.contains(stream) else { return .drop }
            ids.insert(stream)
            open.remove(stream)
            return .send
        }
        return ids.contains(stream) ? .drop : .send
    }

    /// The opener's send was accepted: the stream is open (RRR-5).
    mutating func opened(_ stream: UInt32) {
        open.insert(stream)
        paused.remove(stream)
    }

    /// The Mac paused or covered the stream's picture; only an open stream
    /// counts, so a late pause for a closed id changes nothing.
    mutating func pause(_ stream: UInt32) {
        guard open.contains(stream) else { return }
        paused.insert(stream)
    }

    mutating func resume(_ stream: UInt32) {
        paused.remove(stream)
    }

    /// The phone ended the stream (`window.closed`, or `error no_stream` for
    /// it): it stops counting as activity (D-1's active test), and a late
    /// message for it is dropped as before.
    mutating func forget(_ stream: UInt32) {
        open.remove(stream)
        paused.remove(stream)
        ids.insert(stream)
    }

    /// The one log line for a dropped message: the type and the id only.
    static func lateLog(type: String, stream: UInt32) -> String {
        "late \(type) for closed stream \(stream)"
    }
}
