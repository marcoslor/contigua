// What a screenshot waits for on one call (docs/specs/mcp.md MCP-60, MCP-61;
// #274): a keyframe from after the call, a second ask when the phone answers
// the first with an IDR it already sent, and the phone's own `window.still`
// when a window that is not moving sends no frame at all.
//
// One explicit state machine, pure: `(state, event) -> (state, outcome,
// actions)`, with every case and every transition tested. The caller performs
// the actions against the window's snapshot decoder and clock.
//
// What the phone does (PROTOCOL.md "Video rules", PATH-41):
// - A key request made within 250 ms after the encoder produced an IDR is
//   answered with that IDR: the phone sends nothing, so a decoder that needs a
//   frame counted *after* the call waits forever. A request past the window is
//   honoured, so a second ask ~300 ms later always reaches the encoder.
// - A still surface submits no input frames, so an encoder that drops
//   `KEY_REPEAT_PREVIOUS_FRAME_AFTER` sends `window.still` instead: once after
//   1000 ms without an output buffer, and again each second while the silence
//   lasts (IdleFrameWatchdog). It is never sent on request, so a still that
//   arrived *since this call* is the phone's own report that the picture it
//   shows has not changed. A still from before the ask answers nothing: the
//   screen may have changed after it and the new frame may still be on the
//   wire, so answering it would hand back a picture from before the call
//   (#165). Repeating every second is what makes waiting for the next one
//   cheap: a still screen answers within a second.

import CoreVideo
import Foundation

enum ScreenshotWaitState: Equatable {
    /// The call is waiting for Live Text's freeze to free the one snapshot
    /// decoder: no ask yet. The repeat's moment is not set here, because it is
    /// counted from the first ask, not from the call.
    case beforeAsk
    /// A keyframe was asked for at `askedAt`; the decode waits, and a second
    /// ask is due at `repeatAt` (PATH-41).
    case waiting(askedAt: TimeInterval, repeatAt: TimeInterval, askedAgain: Bool)
    /// The call is over.
    case done
}

/// One thing the caller must do. Values only, never closures: the machine
/// stays pure and a test reads the actions directly.
enum ScreenshotWaitAction: Equatable {
    /// PATH-41: ask again; the decode already waiting stays as it is, and a
    /// frame it decodes is still a frame from after the call.
    case askAgain
    /// Poll again in this long.
    case wait(seconds: TimeInterval)
}

/// What the call knows, fixed when it starts.
struct ScreenshotWaitModel: Equatable {
    var state: ScreenshotWaitState = .beforeAsk
    /// The call's bound, from its start (MCP-61: 2 s). Live Text's hold and
    /// both asks share it.
    let deadline: TimeInterval
    /// Whether a frame was ever counted for this window: the still route can
    /// answer only a picture that exists (PROTOCOL.md: a still is never a
    /// first frame).
    let hasFrame: Bool
}

/// What happens to the call.
enum ScreenshotWaitEvent: Equatable {
    /// The first ask went out at `now`: the snapshot decode is open, and the
    /// second ask is counted from here rather than from the call.
    case asked(now: TimeInterval)
    /// One poll. `frame` is a keyframe decoded from after the call, if one
    /// arrived. `stillAt` is when the phone last said the window is still
    /// (PHONE-21); a still from before the ask answers nothing. `displayed` is
    /// the frame on the display, when there is one the still route may answer.
    case tick(now: TimeInterval, frame: SnapshotFrame?, stillAt: TimeInterval?,
              displayed: SnapshotFrame?)
}

/// What the call does next.
enum ScreenshotWaitOutcome: Equatable {
    case wait
    /// A keyframe from after the call (MCP-60).
    case keyframe(SnapshotFrame)
    /// The displayed frame, for a still window.
    case displayed(SnapshotFrame)
    case fail
}

struct ScreenshotWaitTransition: Equatable {
    var model: ScreenshotWaitModel
    var outcome: ScreenshotWaitOutcome
    var actions: [ScreenshotWaitAction]
}

enum ScreenshotWait {
    /// The bound for a keyframe to arrive, from the call (MCP-61).
    static let bound: TimeInterval = 2
    /// PATH-41: the phone answers a request made within this window with the
    /// IDR it already sent and sends nothing; a later request is honoured.
    static let duplicateIdr: TimeInterval = 0.25
    /// The second ask: past the phone's duplicate-IDR window, with a margin for
    /// the wire's own one-way latency. Counted from the first ask.
    static let repeatAfter: TimeInterval = 0.3
    /// How often the wait polls: a still is answered on the next poll, and the
    /// bound is honoured to a few tens of milliseconds.
    static let pollInterval: TimeInterval = 0.05

    /// The model for a call starting now. The bound runs from `callStart`
    /// (MCP-61); the first ask goes out later, when Live Text lets go, and its
    /// own event sets the second ask's moment.
    static func model(callStart: TimeInterval, bound: TimeInterval = bound,
                      hasFrame: Bool) -> ScreenshotWaitModel {
        ScreenshotWaitModel(state: .beforeAsk, deadline: callStart + bound, hasFrame: hasFrame)
    }

    /// Whether a still the phone sent at `stillAt` vouches for the picture on
    /// screen, when the first ask went out at `askedAt`. A still from before
    /// the ask does not: the screen may have changed after it, with the newer
    /// frame still on the wire (#165).
    static func stillVouches(_ stillAt: TimeInterval?, askedAt: TimeInterval) -> Bool {
        guard let stillAt else { return false }
        return stillAt >= askedAt
    }

    /// The rule, once. A keyframe from after the call beats everything: it is
    /// what MCP-60 asks for. A still the phone sent *since the ask* beats the
    /// bound: the phone itself said the displayed frame is still the picture,
    /// so the call answers it at once. A still from before the ask is not
    /// evidence of anything the call can answer (#165).
    static func transition(_ model: ScreenshotWaitModel,
                            _ event: ScreenshotWaitEvent) -> ScreenshotWaitTransition {
        switch (model.state, event) {
        case (.done, _):
            return ScreenshotWaitTransition(model: model, outcome: .wait, actions: [])
        case (.beforeAsk, .asked(let now)):
            var next = model
            next.state = .waiting(askedAt: now, repeatAt: now + repeatAfter, askedAgain: false)
            return ScreenshotWaitTransition(model: next, outcome: .wait, actions: [])
        case (.beforeAsk, .tick(let now, _, _, _)):
            // No ask has gone out: only the bound can end the call.
            return now >= model.deadline
                ? finish(model, .fail)
                : ScreenshotWaitTransition(model: model, outcome: .wait,
                                            actions: [.wait(seconds: pollInterval)])
        case (.waiting(let askedAt, let repeatAt, let askedAgain),
              .tick(let now, let frame, let stillAt, let displayed)):
            if let frame {
                return finish(model, .keyframe(frame))
            }
            if stillVouches(stillAt, askedAt: askedAt), let displayed, model.hasFrame {
                return finish(model, .displayed(displayed))
            }
            if !askedAgain, now >= repeatAt, now < model.deadline {
                var next = model
                next.state = .waiting(askedAt: askedAt, repeatAt: repeatAt, askedAgain: true)
                return ScreenshotWaitTransition(model: next, outcome: .wait, actions: [.askAgain])
            }
            if now >= model.deadline {
                return finish(model, .fail)
            }
            return ScreenshotWaitTransition(model: model, outcome: .wait,
                                             actions: [.wait(seconds: pollInterval)])
        case (.waiting, .asked(let now)):
            // A second `asked` is the repeat ask; its moment already stands.
            var next = model
            if case .waiting(_, let repeatAt, _) = model.state {
                next.state = .waiting(askedAt: now, repeatAt: repeatAt, askedAgain: true)
            }
            return ScreenshotWaitTransition(model: next, outcome: .wait, actions: [])
        }
    }

    /// The call ends: `.fail` for `no_frame`. The outcome is the whole signal,
    /// so a caller cannot fail the call twice.
    static func finish(_ model: ScreenshotWaitModel,
                       _ outcome: ScreenshotWaitOutcome) -> ScreenshotWaitTransition {
        var next = model
        next.state = .done
        return ScreenshotWaitTransition(model: next, outcome: outcome, actions: [])
    }
}
