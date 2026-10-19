// Mouse hover over the video (docs/PROTOCOL.md HOVER): enter/move/exit order,
// exit before a button's touch DOWN, enter again after the release, no hover
// while dragging, at most one move per 16 ms (the newest point), nothing when
// the setting is off, and an exit when the pointer enters Mac UI over the
// video (the framed bar, the immersive pill).

import AppKit
import XCTest
@testable import PocketDeck

final class HoverInputTests: XCTestCase {

    private struct Sent: Equatable {
        var hovers: [HoverEvent] = []
        var touches: [TouchAction] = []

        var actions: [HoverAction] { hovers.map(\.action) }
    }

    private var now: TimeInterval = 1_000
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

    private func makeMapper(enabled: Bool = true) -> (InputMapper, () -> Sent) {
        let mapper = InputMapper(stream: 1)
        var sent = Sent()
        mapper.videoRectProvider = { CGRect(x: 0, y: 0, width: 900, height: 600) }
        mapper.viewIsFlipped = { false }
        mapper.hoverEnabled = { enabled }
        mapper.hoverClock = { self.now }
        mapper.scheduleHoverMove = { delay, work in self.scheduled.append((delay, work)) }
        mapper.send = { command in
            switch command {
            case .hover(let event): sent.hovers.append(event)
            case .touch(let event): sent.touches.append(event.action)
            default: break
            }
        }
        return (mapper, { sent })
    }

    /// The view point of a video-space point, for a 900×600 unflipped video.
    private func point(_ nx: Float, _ ny: Float) -> CGPoint {
        CGPoint(x: CGFloat(nx) * 900, y: (1 - CGFloat(ny)) * 600)
    }

    private func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                           pressure: 1)!
    }

    // MARK: Order

    func testFirstMoveEntersThenMovesThenExits() {
        let (map, sent) = makeMapper()
        map.hoverMove(at: point(0.25, 0.5))
        XCTAssertEqual(sent().hovers, [HoverEvent(action: .enter, nx: 0.25, ny: 0.5)])

        now += 0.02
        map.hoverMove(at: point(0.5, 0.75))
        XCTAssertEqual(sent().hovers.last, HoverEvent(action: .move, nx: 0.5, ny: 0.75))

        map.hoverExit()
        XCTAssertEqual(sent().actions, [.enter, .move, .exit])
        XCTAssertEqual(sent().hovers.last, HoverEvent(action: .exit, nx: 0.5, ny: 0.75),
                       "the exit carries the last point")
    }

    func testExitComesBeforeTheTouchDownAndEnterReturnsAfterTheUp() {
        let (map, sent) = makeMapper()
        map.hoverMove(at: point(0.5, 0.5))
        map.mouseDown(mouse(.leftMouseDown))

        XCTAssertEqual(sent().actions, [.enter, .exit])
        XCTAssertEqual(sent().touches, [.down])

        map.mouseUp(mouse(.leftMouseUp))
        XCTAssertEqual(sent().touches, [.down, .up])
        XCTAssertEqual(sent().actions, [.enter, .exit], "the release itself sends no hover")

        now += 0.02
        map.hoverMove(at: point(0.6, 0.5))
        XCTAssertEqual(sent().actions, [.enter, .exit, .enter])
    }

    func testRightAndSideButtonsEndTheHoverToo() {
        let (map, sent) = makeMapper()
        map.hoverMove(at: point(0.5, 0.5))
        map.rightMouseDown(mouse(.rightMouseDown))
        XCTAssertEqual(sent().actions, [.enter, .exit])

        now += 0.02
        map.hoverMove(at: point(0.5, 0.5))
        let button = NSEvent.mouseEvent(with: .otherMouseDown, location: .zero,
                                        modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1)!
        map.otherMouseDown(button)
        XCTAssertEqual(sent().actions, [.enter, .exit, .enter, .exit])
    }

    func testADragSendsTouchesAndNoHover() {
        let (map, sent) = makeMapper()
        map.hoverMove(at: point(0.5, 0.5))
        map.mouseDown(mouse(.leftMouseDown))
        let before = sent().hovers.count

        map.mouseDragged(mouse(.leftMouseDragged))
        map.mouseDragged(mouse(.leftMouseDragged))

        XCTAssertEqual(sent().hovers.count, before, "a drag is touch MOVEs only")
        XCTAssertEqual(sent().touches, [.down, .move, .move])
    }

    func testAWindowThatClosesOrLosesKeySendsNoMoreHover() {
        let (map, sent) = makeMapper()
        map.hoverMove(at: point(0.5, 0.5))
        map.hoverExit()
        XCTAssertEqual(sent().actions, [.enter, .exit])
        // A second exit (resign key, then close) adds nothing.
        map.hoverExit()
        XCTAssertEqual(sent().actions, [.enter, .exit])
    }

    // MARK: Rate

    func testMovesAreHeldToOnePerSixteenMillisecondsAndTheNewestWins() {
        let (map, sent) = makeMapper()
        map.hoverMove(at: point(0.1, 0.1))
        XCTAssertEqual(sent().actions, [.enter])

        now += 0.004
        map.hoverMove(at: point(0.2, 0.2))
        now += 0.004
        map.hoverMove(at: point(0.3, 0.3))
        now += 0.004
        map.hoverMove(at: point(0.4, 0.4))
        XCTAssertEqual(sent().actions, [.enter], "nothing inside the 16 ms window yet")
        XCTAssertEqual(scheduled.count, 1, "one timer, not one per move")

        // The timer fires at the end of the window with the latest point only.
        scheduled.removeFirst().work()
        XCTAssertEqual(sent().hovers.last, HoverEvent(action: .move, nx: 0.4, ny: 0.4))

        // A move after the window goes at once.
        now += 0.02
        map.hoverMove(at: point(0.5, 0.5))
        XCTAssertEqual(sent().hovers.last, HoverEvent(action: .move, nx: 0.5, ny: 0.5))
    }

    func testAnExitCancelsAPendingMove() {
        let (map, sent) = makeMapper()
        map.hoverMove(at: point(0.1, 0.1))
        now += 0.004
        map.hoverMove(at: point(0.9, 0.9))
        map.hoverExit()

        scheduled.forEach { $0.work() } // the timer still fires; it must send nothing
        XCTAssertEqual(sent().actions, [.enter, .exit])
    }

    // MARK: Setting

    func testNothingIsSentWithTheSettingOff() {
        let (map, sent) = makeMapper(enabled: false)
        map.hoverMove(at: point(0.5, 0.5))
        now += 0.02
        map.hoverMove(at: point(0.6, 0.5))
        map.hoverExit()

        XCTAssertTrue(sent().hovers.isEmpty)
        XCTAssertTrue(sent().touches.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testTurningTheSettingOffMidHoverStopsTheFramesAndOnAgainReenters() {
        var enabled = true
        let mapper = InputMapper(stream: 1)
        var sent = Sent()
        mapper.videoRectProvider = { CGRect(x: 0, y: 0, width: 900, height: 600) }
        mapper.viewIsFlipped = { false }
        mapper.hoverEnabled = { enabled }
        mapper.hoverClock = { self.now }
        mapper.scheduleHoverMove = { delay, work in self.scheduled.append((delay, work)) }
        mapper.send = { command in
            if case .hover(let event) = command { sent.hovers.append(event) }
        }

        mapper.hoverMove(at: point(0.5, 0.5))
        enabled = false
        mapper.hoverMove(at: point(0.6, 0.5))
        mapper.hoverExit()
        XCTAssertEqual(sent.actions, [.enter], "off sends nothing, not even the exit")

        enabled = true
        now += 0.02
        mapper.hoverMove(at: point(0.7, 0.5))
        XCTAssertEqual(sent.actions, [.enter, .enter], "the first move after it comes back enters again")
    }

    // MARK: Mac UI over the video

    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.hover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testTheFramedBarIsNotThePhone() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        var sent = Sent()
        controller.videoView.inputMapper?.send = { command in
            if case .hover(let event) = command { sent.hovers.append(event) }
        }

        // Mid-video: enter. Then the bar above the stream: exit.
        controller.pointerMoved(toWindowPoint: CGPoint(x: 450, y: 300))
        XCTAssertEqual(sent.actions, [.enter])
        controller.pointerMoved(toWindowPoint: CGPoint(x: 450, y: controller.videoView.frame.height + 10))
        XCTAssertEqual(sent.actions, [.enter, .exit])
    }

    func testTheImmersivePillIsNotThePhone() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        controller.setStyle(.immersive)
        window.orderFront(nil)
        var sent = Sent()
        controller.videoView.inputMapper?.send = { command in
            if case .hover(let event) = command { sent.hovers.append(event) }
        }
        // Rest in the hot zone until the pill fades in over the video.
        let hotZone = CGPoint(x: 20, y: window.frame.height - 16)
        controller.pointerMoved(toWindowPoint: hotZone)
        pump(0.5)
        XCTAssertTrue(controller.chrome.showsPill, "the pill is up")
        XCTAssertEqual(sent.actions, [.enter])

        // The same point is now Mac UI: the phone sees the mouse leave.
        controller.pointerMoved(toWindowPoint: hotZone)
        XCTAssertEqual(sent.actions, [.enter, .exit])
    }
}
