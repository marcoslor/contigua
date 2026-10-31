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

    /// True while any stream the Mac opened is not closed: D-1's "a stream
    /// runs" half of the fast-ping rule.
    var hasOpenStream: Bool { !open.isEmpty }

    /// Decide one per-stream message. `type` is its protocol name
    /// (`window.pause`, `hover`, …), `stream` the id it carries.
    mutating func decide(type: String, stream: UInt32) -> Decision {
        if Self.opening.contains(type) {
            ids.remove(stream)
            open.insert(stream)
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

    /// The one log line for a dropped message: the type and the id only.
    static func lateLog(type: String, stream: UInt32) -> String {
        "late \(type) for closed stream \(stream)"
    }
}
