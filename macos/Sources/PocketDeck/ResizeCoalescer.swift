// One window's `window.resize` requests, as a state machine.
//
// A person's burst of ⌘+/⌘- presses, or a drag that keeps changing the shape,
// used to send every value: at the clamp the Mac sent the same request seven
// times in 1.2 s (the 10-27 report), and every request re-attaches the phone's
// encoder, so overlapping attaches lost frames. The rules here are the fix —
// one request in flight, at most one pending (the latest value wins), and a
// value equal to the last one sent or in flight is never sent.
//
// Not a timer: the pending value goes out when the phone answers the request in
// flight (`window.resize.ack`, or the VIDEO_CONFIG that follows it), so the
// next re-attach starts only once the phone has finished the last one.

import Foundation

/// The pixels and dpi one `window.resize` carries.
struct ResizeRequest: Equatable {
    var w: Int
    var h: Int
    var dpi: Int
}

struct ResizeCoalescer {
    enum State: Equatable {
        /// Nothing in flight; `last` is what the phone was last asked for.
        case idle(last: ResizeRequest?)
        /// One request at the phone, and the single value waiting behind it.
        case inFlight(ResizeRequest, pending: ResizeRequest?)
    }

    enum Event: Equatable {
        case request(ResizeRequest)
        /// The phone applied that request (any outcome: resized, density only,
        /// refused). A value it does not name is a late answer and is ignored.
        case settled(ResizeRequest)
        /// A fresh `window.open` sizes the stream itself: the last value no
        /// longer means anything.
        case reset
    }

    enum Action: Equatable {
        case send(ResizeRequest)
    }

    private(set) var state: State = .idle(last: nil)

    /// The pure rule, for the tests and the transitions log.
    static func reduce(_ state: State, _ event: Event) -> (State, [Action]) {
        switch (state, event) {
        case (.idle(let last), .request(let request)):
            guard request != last else { return (state, []) }
            return (.inFlight(request, pending: nil), [.send(request)])
        case (.inFlight(let inFlight, let pending), .request(let request)):
            // The value at the phone, or the one already waiting, changes
            // nothing: nothing is queued behind a duplicate.
            guard request != inFlight, request != pending else { return (state, []) }
            return (.inFlight(inFlight, pending: request), [])
        case (.inFlight(let inFlight, let pending), .settled(let request)):
            guard request == inFlight else { return (state, []) }
            guard let pending else { return (.idle(last: inFlight), []) }
            return (.inFlight(pending, pending: nil), [.send(pending)])
        case (.idle, .settled):
            return (state, [])
        case (_, .reset):
            return (.idle(last: nil), [])
        }
    }

    /// Applies one event and returns what to send now.
    mutating func apply(_ event: Event) -> [Action] {
        let (next, actions) = Self.reduce(state, event)
        state = next
        return actions
    }

    /// A window that never sent a resize starts from `last` (a stream the phone
    /// opened at a size the window already knows).
    mutating func reset(to last: ResizeRequest? = nil) {
        state = .idle(last: last)
    }

    var inFlight: ResizeRequest? {
        if case .inFlight(let request, _) = state { return request }
        return nil
    }
}
