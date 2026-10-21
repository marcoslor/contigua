// Live Text mode's states (docs/design/livetext.md). Pure: time and views are
// outside, so the unit tests pin every transition. A window is in the mode
// exactly while the state is not idle; the mapper reads `isActive` through the
// video view and forwards no input while it is true.

import Foundation

enum LiveTextState: String, Equatable {
    case idle
    case capturing
    case analyzing
    case shown

    var isActive: Bool { self != .idle }
}

/// Why the mode was left. Logged as its raw value only; the reasons share one
/// behaviour (drop the overlay, show live video again). A resize and a new
/// stream config are the phone answering a window change, a close and a lost
/// link mean there is no frame to hold, and the rest are the person's.
enum LiveTextExitReason: String, Equatable {
    case escape
    case toggle
    case menu
    case barButton
    case resize
    case close
    case disconnect
    case streamConfig
    /// No frame could be frozen in time (the keyframe route timed out).
    case captureFailed
}

enum LiveTextEvent: Equatable {    /// Enter the mode (the shortcut, the menu or the bar button).
    case enter
    /// The displayed frame was copied into the freeze image.
    case frameCaptured
    case analysisFinished
    /// VisionKit found nothing or failed: the frozen frame still supports copy
    /// and drag, so the mode goes on to `shown` without an overlay analysis.
    case analysisFailed
    case exit(LiveTextExitReason)
}

struct LiveTextMode: Equatable {
    private(set) var state: LiveTextState = .idle
    /// The last reason the mode was left for; nil until it was entered once.
    private(set) var lastExitReason: LiveTextExitReason?

    var isActive: Bool { state.isActive }

    /// Applies one event; true when the state changed. Events that do not
    /// belong to the current state are ignored (a second `enter` while
    /// capturing, a frame after exit), so the caller can forward freely.
    @discardableResult
    mutating func handle(_ event: LiveTextEvent) -> Bool {
        switch (state, event) {
        case (.idle, .enter):
            state = .capturing
        case (.capturing, .frameCaptured):
            state = .analyzing
        case (.analyzing, .analysisFinished), (.analyzing, .analysisFailed):
            state = .shown
        case (_, .exit(let reason)) where state.isActive:
            state = .idle
            lastExitReason = reason
        default:
            return false
        }
        return true
    }

    /// A stream config, a resize, a close or a lost link came from outside:
    /// leave the mode if it is in one.
    @discardableResult
    mutating func exit(_ reason: LiveTextExitReason) -> Bool {
        handle(.exit(reason))
    }
}

