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
//   came after the newest frame is the phone's own report that nothing changed
//   since that frame.

import CoreVideo
import Foundation

enum ScreenshotWaitState: Equatable {
    /// A keyframe was asked for; its decode waits.
    case waiting(repeatAt: TimeInterval, askedAgain: Bool)
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
    var state: ScreenshotWaitState = .waiting(repeatAt: 0, askedAgain: false)
    /// The call's bound, from its start (MCP-61: 2 s).
    let deadline: TimeInterval
    /// Whether a frame was ever counted for this window: the still route can
    /// answer only a picture that exists (PROTOCOL.md: a still is never a
    /// first frame).
    let hasFrame: Bool
}

/// One poll of the call.
enum ScreenshotWaitEvent: Equatable {
    /// `frame` is a keyframe decoded from after the call, if one arrived.
    /// `still` is whether the phone says the window is still since the newest
    /// frame (a `window.still` at the call's start or after it). `displayed` is
    /// the frame on the display, when there is one the still route may answer.
    case tick(now: TimeInterval, frame: SnapshotFrame?, still: Bool,
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
    /// the wire's own one-way latency.
    static let repeatAfter: TimeInterval = 0.3
    /// How often the wait polls: a still is answered on the next poll, and the
    /// bound is honoured to a few tens of milliseconds.
    static let pollInterval: TimeInterval = 0.05
    /// A displayed frame older than this is not a picture to act on (MCP-S1):
    /// the call fails `no_frame` rather than answer a picture from long ago.
    static let maxStillAge: TimeInterval = 60

    /// The model for a call starting now: the first ask goes out at `askAt`.
    static func model(askAt: TimeInterval, bound: TimeInterval = bound,
                      hasFrame: Bool) -> ScreenshotWaitModel {
        ScreenshotWaitModel(state: .waiting(repeatAt: askAt + repeatAfter, askedAgain: false),
                             deadline: askAt + bound, hasFrame: hasFrame)
    }

    /// Whether the still route may answer a displayed frame of this age.
    static func stillFrameUsable(age: TimeInterval) -> Bool {
        age >= 0 && age <= maxStillAge
    }

    /// The rule, once. A keyframe from after the call beats everything: it is
    /// what MCP-60 asks for. A still beats the bound: the phone itself said the
    /// displayed frame is still the picture, so the call answers it at once.
    static func transition(_ model: ScreenshotWaitModel,
                            _ event: ScreenshotWaitEvent) -> ScreenshotWaitTransition {
        guard case .waiting(let repeatAt, let askedAgain) = model.state,
              case .tick(let now, let frame, let still, let displayed) = event else {
            return ScreenshotWaitTransition(model: model, outcome: .wait, actions: [])
        }
        if let frame {
            return finish(model, .keyframe(frame))
        }
        if still, let displayed, model.hasFrame {
            return finish(model, .displayed(displayed))
        }
        if !askedAgain, now >= repeatAt, now < model.deadline {
            var next = model
            next.state = .waiting(repeatAt: repeatAt, askedAgain: true)
            return ScreenshotWaitTransition(model: next, outcome: .wait, actions: [.askAgain])
        }
        if now >= model.deadline {
            return finish(model, .fail)
        }
        return ScreenshotWaitTransition(model: model, outcome: .wait,
                                         actions: [.wait(seconds: pollInterval)])
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
