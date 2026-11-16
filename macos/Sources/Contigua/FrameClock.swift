// Per-window frame freshness (MCP-20, docs/specs/mcp.md "Freshness"): the count
// of complete video access units a window has received and when the newest
// arrived. `FrameClock` is the pure value; `FrameClockStore` is the locked
// holder a window owns — written on the session queue, read on main and by the
// picture watchdog.

import Foundation

/// One counted access unit: its seq (from 1) and its arrival (systemUptime).
struct FrameStamp: Equatable, Sendable {
    let seq: Int
    let at: TimeInterval
}

struct FrameClock: Equatable {
    /// The newest counted access unit: 0 before the first, +1 each, never reset
    /// while the window lives.
    private(set) var newest = 0
    /// When the newest arrived; nil before the first.
    private(set) var lastAt: TimeInterval?

    /// One complete access unit arrived (a whole `VIDEO_FRAME` or a reassembled
    /// `VIDEO_CHUNK` set). Returns its seq, counting from 1.
    @discardableResult
    mutating func received(atUptime now: TimeInterval) -> Int {
        newest += 1
        lastAt = now
        return newest
    }

    /// Milliseconds since the newest frame arrived; nil before the first.
    func age(now: TimeInterval) -> Int? {
        lastAt.map { FrameClock.ms(since: $0, now: now) }
    }

    static func ms(since then: TimeInterval, now: TimeInterval) -> Int {
        Int((max(0, now - then) * 1000).rounded())
    }

    /// MCP-20's `frame` object: `{"seq": N, "ageMs": A}`, A null before the first.
    static func object(seq: Int, ageMs: Int?) -> [String: Any] {
        ["seq": seq, "ageMs": ageMs.map { $0 as Any } ?? NSNull()]
    }
}

/// A window's `FrameClock`, fed from the session queue and read anywhere.
final class FrameClockStore: @unchecked Sendable {
    private let lock = NSLock()
    private var clock = FrameClock()

    /// Count one access unit and return its stamp.
    @discardableResult
    func note(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> FrameStamp {
        lock.lock()
        defer { lock.unlock() }
        return FrameStamp(seq: clock.received(atUptime: time), at: time)
    }

    var newest: Int {
        lock.lock(); defer { lock.unlock() }
        return clock.newest
    }

    var lastFrame: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return clock.lastAt
    }

    /// MCP-20's `frame` object, the seq and the age read together.
    func object(now: TimeInterval) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return FrameClock.object(seq: clock.newest, ageMs: clock.age(now: now))
    }
}
