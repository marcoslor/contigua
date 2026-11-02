// The window half of the picture watchdog (docs/NFR.md "No stale picture"):
// a covered window is not a live picture. AppKit throttles an occluded app, so
// the frames stop arriving without the phone being at fault; the window must
// not call that a stall, and the clock restarts when it is visible again.
//
// The WindowServer's occlusion state cannot be driven from a test process, so
// the window takes an override (the e2e's `occlude` command uses the same one).

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class StreamWindowWatchdogTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.watchdog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    func testACoveredWindowDoesNotExpectFrames() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        // The test process has no WindowServer focus of its own: say visible.
        controller.occlusionVisibleOverride = true
        // The opening cover is down: this is about a window with its picture.
        controller.noteFirstFrame()

        XCTAssertFalse(controller.isWindowOccluded)
        XCTAssertTrue(controller.expectsFrames, "a visible live window expects its frames")

        controller.occlusionVisibleOverride = false
        XCTAssertTrue(controller.isWindowOccluded)
        XCTAssertFalse(controller.expectsFrames, "a covered window has no live picture to be wrong about")

        controller.occlusionVisibleOverride = true
        XCTAssertFalse(controller.isWindowOccluded)
        XCTAssertTrue(controller.expectsFrames)
    }

    func testCoveredTimeNeverStallsAndTheClockRestartsOnReturn() throws {        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.occlusionVisibleOverride = true
        controller.noteFirstFrame()
        // Real-based times: the window's own timer also ticks during the test.
        let t0 = ProcessInfo.processInfo.systemUptime
        controller.frameClock.note(at: t0)
        controller.tickFrameWatchdog(at: t0)
        controller.tickFrameWatchdog(at: t0 + 2)
        XCTAssertTrue(controller.isStalled, "the baseline: 2 s of silence on a visible window stalls")

        // Covered at t0+2.1 for 10 s: no stall, and the clock is idle.
        controller.occlusionVisibleOverride = false
        controller.tickFrameWatchdog(at: t0 + 2.1)
        XCTAssertFalse(controller.isStalled, "a covered window's silence is not a stall")
        for step in stride(from: 2.35, through: 12, by: 0.25) {
            controller.tickFrameWatchdog(at: t0 + step)
        }
        XCTAssertFalse(controller.isStalled)

        // Visible again: the first tick restarts the clock...
        controller.occlusionVisibleOverride = true
        controller.tickFrameWatchdog(at: t0 + 12.1)
        XCTAssertFalse(controller.isStalled, "the covered time must not count against the first seconds")
        // ...and only 1.5 s of real silence after that is a stall.
        controller.tickFrameWatchdog(at: t0 + 13.7)
        XCTAssertTrue(controller.isStalled)

        // A frame ends it, as on a live stream.
        controller.frameClock.note(at: t0 + 14)
        controller.tickFrameWatchdog(at: t0 + 14)
        XCTAssertFalse(controller.isStalled)
    }

    /// `window.still` is a heartbeat, never a first frame: the opening cover
    /// stays up (WIN-11) and the cover's ground is not changed by it.
    func testAStillBeforeTheFirstFrameDoesNotEndTheOpeningCover() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.occlusionVisibleOverride = true
        let t0 = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(controller.isOpening, "a fresh window wears the opening cover")

        controller.noteStill(at: t0)
        XCTAssertTrue(controller.isOpening, "a still is not a frame: the cover and its ground stay")
        for step in stride(from: 0.25, through: 30, by: 0.25) {
            controller.tickFrameWatchdog(at: t0 + step)
        }
        XCTAssertTrue(controller.isOpening)
    }

    /// A still ends a stall the same way a frame does.
    func testAStillEndsAShownStallInTheWindow() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.occlusionVisibleOverride = true
        controller.noteFirstFrame()
        let t0 = ProcessInfo.processInfo.systemUptime
        controller.frameClock.note(at: t0)
        controller.tickFrameWatchdog(at: t0)
        controller.tickFrameWatchdog(at: t0 + 2)
        XCTAssertTrue(controller.isStalled, "the baseline: 2 s of silence stalls")

        controller.noteStill(at: t0 + 2.1)
        XCTAssertFalse(controller.isStalled, "the phone said the stream is alive")
        controller.tickFrameWatchdog(at: t0 + 2.1)
        XCTAssertFalse(controller.isStalled)
    }

    /// The change is per stream: another stream's still says nothing about
    /// this window's picture.
    func testAnotherStreamsStillDoesNotKeepThisWindowLive() {
        let manager = makeManager()
        let first = manager.openOrRaise(pkg: "com.example.one")
        let second = manager.openOrRaise(pkg: "com.example.two")
        defer {
            first.window?.close()
            second.window?.close()
        }
        first.occlusionVisibleOverride = true
        second.occlusionVisibleOverride = true
        first.noteFirstFrame()
        second.noteFirstFrame()
        let t0 = ProcessInfo.processInfo.systemUptime
        first.frameClock.note(at: t0)
        second.frameClock.note(at: t0)
        first.tickFrameWatchdog(at: t0)
        second.tickFrameWatchdog(at: t0)

        manager.handle(.windowStill(stream: second.stream))
        let now = ProcessInfo.processInfo.systemUptime
        first.tickFrameWatchdog(at: now + 2)
        second.tickFrameWatchdog(at: now + 0.5)
        XCTAssertTrue(first.isStalled, "stream 2's still is not stream 1's heartbeat")
        XCTAssertFalse(second.isStalled, "stream 2's own still kept it live")
    }

    /// L2: the phone's own power press with our streams up (`power.locked`).
    /// The window holds the last frame — no "Not responding" pill, no input
    /// block — through the grace, and a real stall after it still says so.
    func testAPowerPressHoldsTheLastFrameAndARealStallStillShows() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.occlusionVisibleOverride = true
        controller.noteFirstFrame()
        let t0 = ProcessInfo.processInfo.systemUptime
        controller.frameClock.note(at: t0)
        controller.tickFrameWatchdog(at: t0)
        controller.tickFrameWatchdog(at: t0 + 2)
        XCTAssertTrue(controller.isStalled, "the baseline: 2 s of silence stalls")

        // The press: the picture is the person's own action, so the window holds
        // the last frame and the frozen input block goes with the pill.
        controller.powerLocked(at: t0 + 2.1)
        XCTAssertFalse(controller.isStalled)
        XCTAssertTrue(controller.expectsFrames, "the window still expects the stream to come back")
        controller.tickFrameWatchdog(at: t0 + 3.5)
        XCTAssertFalse(controller.isStalled, "inside the grace the picture is not called stale")

        // Past the grace with no frame: a real stall, said visibly.
        controller.tickFrameWatchdog(at: t0 + 4.2)
        XCTAssertTrue(controller.isStalled)
    }
}
