// The per-window picture watchdog (docs/NFR.md "No stale picture").
//
// A phone stream has no frames of its own while the display is static:
// SurfaceFlinger composes only when something draws. Silence alone is therefore
// not a stall. The phone's encoder repeats its last frame at least every 500 ms
// while a stream is open (WindowStream.configure,
// KEY_REPEAT_PREVIOUS_FRAME_AFTER), which gives every live stream a steady
// heartbeat even on an unchanging screen. 1.5 s of silence (three missed beats)
// is a stalled picture: the window says "Not responding" and blocks input until
// a frame arrives. One missed second is left alone: Wi-Fi drops that much now
// and then, and a flashing pill on a healthy stream is worse than a late one.
//
// Pure: the window feeds it the clock, so a fake clock pins the rule.

import Foundation

struct FrameWatchdog: Equatable {
    /// stale_picture_ms (nfr-limits.json) is 2000 ms, the limit for saying so;
    /// the deadline plus one timer tick stays under it (a test pins that).
    static let staleAfter: TimeInterval = 1.5

    /// How often the window asks; finer than the deadline and cheap.
    static let tickInterval: TimeInterval = 0.25

    /// The last accepted frame; while the window is not expecting frames this
    /// is reset to the current time so paused/covered time is not evidence.
    private(set) var lastFrame: TimeInterval?
    private(set) var stalled = false

    /// A frame arrived (from the session queue, through the window's clock).
    /// True when it ended a stall.
    @discardableResult
    mutating func frame(at now: TimeInterval) -> Bool {
        // An older timestamp than the last one is a stale read, not a frame.
        guard now > (lastFrame ?? -.greatestFiniteMagnitude) else { return false }
        lastFrame = now
        guard stalled else { return false }
        stalled = false
        return true
    }

    /// The timer's question. `expecting` is the window's rule (session up,
    /// screen on, visible, not paused, not Live Text). Returns true once when
    /// the picture turns stalled; the stall stays until `frame(at:)` ends it.
    mutating func tick(at now: TimeInterval, expecting: Bool) -> Bool {
        guard expecting else {
            // Not expecting frames (paused, covered, Live Text, link down):
            // that time says nothing about the encoder. Start the clock again
            // when frames are wanted.
            lastFrame = now
            return false
        }
        guard !stalled, let lastFrame, now - lastFrame >= Self.staleAfter else { return false }
        stalled = true
        return true
    }
}

/// The last frame's time, written from the session queue and read by the
/// window's main-thread watchdog.
final class FrameClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval?

    func note(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        last = time
        lock.unlock()
    }

    var lastFrame: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }
}
