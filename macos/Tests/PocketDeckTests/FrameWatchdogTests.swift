// The per-window picture watchdog (FrameWatchdog.swift): a fake clock, no
// timers. docs/NFR.md "No stale picture": a live stream's encoder repeats its
// last frame twice a second, so a second of silence is a stalled picture; a
// static screen therefore never trips it.

import XCTest
@testable import PocketDeck

final class FrameWatchdogTests: XCTestCase {
    func testSilenceOnALiveStreamStallsAfterThreeMissedBeats() {
        var watchdog = FrameWatchdog()
        XCTAssertFalse(watchdog.tick(at: 10, expecting: true), "no frame yet: nothing to time")
        watchdog.frame(at: 10)
        XCTAssertFalse(watchdog.tick(at: 10.5, expecting: true))
        XCTAssertFalse(watchdog.tick(at: 11.0, expecting: true), "a one-second Wi-Fi hiccup is not a stall")
        XCTAssertFalse(watchdog.tick(at: 11.4, expecting: true))
        XCTAssertTrue(watchdog.tick(at: 11.5, expecting: true), "1.5 s of silence is a stall")
        XCTAssertTrue(watchdog.stalled)
        XCTAssertFalse(watchdog.tick(at: 12, expecting: true), "the stall is reported once")
        XCTAssertTrue(watchdog.stalled, "it lasts until a frame")
    }

    func testTheHeartbeatKeepsItLive() {
        var watchdog = FrameWatchdog()
        var now = 0.0
        // The encoder repeats its last frame every 500 ms on a static screen.
        for _ in 0..<20 {
            watchdog.frame(at: now)
            XCTAssertFalse(watchdog.tick(at: now + 0.5, expecting: true), "a static screen is not a stall")
            now += 0.5
        }
        XCTAssertFalse(watchdog.stalled)
    }

    func testTheNextFrameClearsTheStall() {
        var watchdog = FrameWatchdog()
        watchdog.frame(at: 0)
        XCTAssertTrue(watchdog.tick(at: 1.5, expecting: true))
        XCTAssertTrue(watchdog.frame(at: 1.6), "the frame ended the stall")
        XCTAssertFalse(watchdog.stalled)
        XCTAssertFalse(watchdog.frame(at: 1.5), "an older clock read is not a new frame")
        XCTAssertFalse(watchdog.tick(at: 1.7, expecting: true))
    }

    func testTimeSpentNotExpectingFramesIsNotEvidence() {
        var watchdog = FrameWatchdog()
        watchdog.frame(at: 0)
        // Paused, covered or Live Text from 0.5 s to 30 s: no timer counts.
        XCTAssertFalse(watchdog.tick(at: 30, expecting: false))
        XCTAssertFalse(watchdog.tick(at: 30.5, expecting: true), "the clock restarted when frames were wanted")
        XCTAssertFalse(watchdog.stalled)
        XCTAssertTrue(watchdog.tick(at: 32.0, expecting: true))
    }

    func testTheClockRestartsAfterCoveredTimeWithoutTicks() {
        var watchdog = FrameWatchdog()
        watchdog.frame(at: 0)
        XCTAssertFalse(watchdog.tick(at: 0.5, expecting: true))
        // The occlusion notification ticks once (expecting false); AppKit then
        // throttles the timer, so nothing runs until the window is visible
        // again 10 s later.
        XCTAssertFalse(watchdog.tick(at: 1, expecting: false))
        XCTAssertFalse(watchdog.tick(at: 11, expecting: true),
                       "the clock restarts when the window returns")
        XCTAssertFalse(watchdog.stalled)
        XCTAssertTrue(watchdog.tick(at: 12.5, expecting: true))
    }

    /// The deadline sits under docs/NFR.md's stale_picture_ms (the JSON is the
    /// one source of truth for the shell checks too).
    func testTheDeadlineIsWithinTheNfrLimit() {
        let limit = Double(NFRTestLimits.shared.int("stale_picture_ms")) / 1000
        XCTAssertLessThanOrEqual(FrameWatchdog.staleAfter, limit)
        XCTAssertLessThanOrEqual(FrameWatchdog.staleAfter + FrameWatchdog.tickInterval, limit,
                                 "the stall is shown within the limit even when it lands just after a tick")
    }
}
