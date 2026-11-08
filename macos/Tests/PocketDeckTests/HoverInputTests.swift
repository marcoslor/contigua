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

    func testHoverNeverShowsTouchDots() {
        let (map, _) = makeMapper()
        var dots: [[InputMapper.TouchPoint]] = []
        map.touchPointsChanged = { dots.append($0) }
        map.hoverMove(at: point(0.5, 0.98))
        map.hoverMove(at: point(0.55, 0.9))
        map.hoverExit()
        XCTAssertTrue(dots.isEmpty, "Show Touches draws touches only: a hover is not a touch")
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
        controller.noteFirstFrame()
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
        controller.noteFirstFrame()
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

    // MARK: The band is never phone input (WIN-61)

    /// The window's top band is the window's own for hover as it is for
    /// clicks: the extension view stretches the picture over the whole
    /// window, so the framed bar's mirror is still inside the video view, and
    /// moving the pointer there must end the phone's hover and send nothing
    /// while it stays (ISS-49, WIN-61).
    func testHoverIntoTheFramedBandLeavesThePhoneAndStaysOut() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.noteFirstFrame()
        // The real window's geometry: the extension view's contentView (the
        // video) fills the window, mirroring its top edge into the bar.
        controller.videoView.frame = controller.chrome.bounds
        var sent = Sent()
        let mapper = try XCTUnwrap(controller.videoView.inputMapper)
        mapper.scheduleHoverMove = { _, work in work() }
        mapper.send = { command in
            if case .hover(let event) = command { sent.hovers.append(event) }
        }
        let bounds = controller.chrome.bounds
        let bandBottom = min(bounds.height - ChromeBar.height, window.contentLayoutRect.maxY)
        let x = bounds.midX

        controller.pointerMoved(toWindowPoint: CGPoint(x: x, y: bandBottom - 20))
        XCTAssertEqual(sent.actions, [.enter], "the picture below the band is the phone's")

        // The bar's own 28 pt and the titlebar rows above the stream's first
        // visible row are both the band.
        for y in [bandBottom + 1, bounds.height - 1] {
            controller.pointerMoved(toWindowPoint: CGPoint(x: x, y: y))
            XCTAssertEqual(sent.actions, [.enter, .exit], "hover at y=\(y) enters the band")
            controller.pointerMoved(toWindowPoint: CGPoint(x: x + 40, y: y))
            XCTAssertEqual(sent.actions, [.enter, .exit], "no hover move while over the band")
        }

        controller.pointerMoved(toWindowPoint: CGPoint(x: x, y: bandBottom - 20))
        XCTAssertEqual(sent.actions, [.enter, .exit, .enter], "below the band the hover resumes")
    }

    /// The Phone Mirror wears the same chrome: its framed band belongs to the
    /// window, not to the phone's own screen.
    func testHoverIntoThePhoneMirrorsFramedBandLeavesThePhone() throws {
        let manager = makeManager()
        let controller = PhoneWindowController(stream: 1, phone: nil, manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.noteFirstFrame()
        controller.videoView.frame = controller.chrome.bounds
        var sent = Sent()
        let mapper = try XCTUnwrap(controller.videoView.inputMapper)
        mapper.scheduleHoverMove = { _, work in work() }
        mapper.send = { command in
            if case .hover(let event) = command { sent.hovers.append(event) }
        }
        let bounds = controller.chrome.bounds
        let bandBottom = min(bounds.height - ChromeBar.height, window.contentLayoutRect.maxY)
        let x = bounds.midX

        controller.pointerMoved(toWindowPoint: CGPoint(x: x, y: bandBottom - 40))
        XCTAssertEqual(sent.actions, [.enter])
        controller.pointerMoved(toWindowPoint: CGPoint(x: x, y: bandBottom + 1))
        XCTAssertEqual(sent.actions, [.enter, .exit])
        controller.pointerMoved(toWindowPoint: CGPoint(x: x + 40, y: bandBottom + 1))
        XCTAssertEqual(sent.actions, [.enter, .exit], "no hover move while over the band")
        controller.pointerMoved(toWindowPoint: CGPoint(x: x, y: bandBottom - 40))
        XCTAssertEqual(sent.actions, [.enter, .exit, .enter])
    }

    /// In immersive the pill appears under a pointer that is resting in the
    /// hot zone. The pointer does not move to leave the phone: the pill's
    /// arrival itself must end the hover, once, and further moves over it send
    /// nothing until the pointer is back on the picture.
    func testTheImmersivePillAppearingUnderARestingPointerEndsTheHover() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        controller.setStyle(.immersive)
        window.orderFront(nil)
        controller.noteFirstFrame()
        var sent = Sent()
        let mapper = try XCTUnwrap(controller.videoView.inputMapper)
        mapper.scheduleHoverMove = { _, work in work() }
        mapper.send = { command in
            if case .hover(let event) = command { sent.hovers.append(event) }
        }
        let hotZone = CGPoint(x: 20, y: window.frame.height - 16)
        controller.pointerMoved(toWindowPoint: hotZone)
        XCTAssertEqual(sent.actions, [.enter], "at rest the hot zone is still the picture")

        pump(0.5)
        XCTAssertTrue(controller.chrome.showsPill, "the pill is up")
        XCTAssertEqual(sent.actions, [.enter, .exit],
                       "the pill came up under the resting pointer: the hover ends")

        controller.pointerMoved(toWindowPoint: hotZone)
        controller.pointerMoved(toWindowPoint: CGPoint(x: 40, y: hotZone.y))
        XCTAssertEqual(sent.actions, [.enter, .exit], "no hover move while over the pill")

        controller.pointerMoved(toWindowPoint: CGPoint(x: 40, y: hotZone.y - 80))
        XCTAssertEqual(sent.actions, [.enter, .exit, .enter], "the picture below resumes the hover")
    }
}
