// The hover header: when it shows and hides, and that it never changes the
// stream area the virtual display is sized from.

import AppKit
import XCTest
@testable import PocketDeck

final class HeaderHoverTests: XCTestCase {

    func testHiddenAtRest() {
        var hover = HeaderHover(hideDelay: 1)
        hover.update(now: 0)
        XCTAssertFalse(hover.visible)
        XCTAssertNil(hover.hideAt)
    }

    func testEnteringTheTopShowsItAtOnce() {
        var hover = HeaderHover(hideDelay: 1)
        hover.pointerOver = true
        hover.update(now: 5)
        XCTAssertTrue(hover.visible)
        XCTAssertNil(hover.hideAt, "nothing scheduled while the pointer is up there")
    }

    func testLeavingHidesItAfterTheDelay() {
        var hover = HeaderHover(hideDelay: 1)
        hover.pointerOver = true
        hover.update(now: 0)
        hover.pointerOver = false
        hover.update(now: 2)
        XCTAssertTrue(hover.visible, "still shown right after leaving")
        XCTAssertEqual(hover.hideAt, 3)
        hover.update(now: 2.9)
        XCTAssertTrue(hover.visible)
        hover.update(now: 3)
        XCTAssertFalse(hover.visible)
        XCTAssertNil(hover.hideAt)
    }

    func testByDefaultItHidesAsSoonAsThePointerLeaves() {
        var hover = HeaderHover()
        hover.pointerOver = true
        hover.update(now: 0)
        hover.pointerOver = false
        hover.update(now: 0.01)
        XCTAssertFalse(hover.visible, "no grace period")
        XCTAssertNil(hover.hideAt)
    }

    func testComingBackBeforeTheDelayCancelsTheHide() {
        var hover = HeaderHover(hideDelay: 1)
        hover.pointerOver = true
        hover.update(now: 0)
        hover.pointerOver = false
        hover.update(now: 1)
        hover.pointerOver = true
        hover.update(now: 1.5)
        hover.update(now: 2.5)
        XCTAssertTrue(hover.visible)
        XCTAssertNil(hover.hideAt)
    }

    func testAnOpenMenuKeepsItButDoesNotSummonIt() {
        var hover = HeaderHover(hideDelay: 1)
        hover.menuOpen = true
        hover.update(now: 0)
        XCTAssertFalse(hover.visible, "a menu-bar menu does not bring the header in")

        hover.menuOpen = false
        hover.pointerOver = true
        hover.update(now: 1)
        hover.menuOpen = true
        hover.pointerOver = false
        hover.update(now: 1)
        hover.update(now: 10)
        XCTAssertTrue(hover.visible, "stays while the menu is open")
        hover.menuOpen = false
        hover.update(now: 10)
        XCTAssertEqual(hover.hideAt, 11)
        hover.update(now: 11)
        XCTAssertFalse(hover.visible)
    }

    func testADragKeepsIt() {
        var hover = HeaderHover(hideDelay: 1)
        hover.pointerOver = true
        hover.update(now: 0)
        hover.dragging = true
        hover.pointerOver = false
        hover.update(now: 0)
        hover.update(now: 5)
        XCTAssertTrue(hover.visible, "the pointer can outrun the header while the window moves")
        hover.dragging = false
        hover.update(now: 5)
        hover.update(now: 6)
        XCTAssertFalse(hover.visible)
    }

    func testTheHoverZoneIsTheStreamsTopEdge() {
        XCTAssertEqual(WindowChrome.hoverZone, 12)
        XCTAssertEqual(WindowChrome.hideDelay, 0)
        XCTAssertLessThanOrEqual(WindowChrome.fadeInDuration, 0.1)
        XCTAssertLessThanOrEqual(WindowChrome.fadeOutDuration, 0.15)
        XCTAssertTrue(WindowChrome.isInHoverZone(y: 599, height: 600))
        XCTAssertTrue(WindowChrome.isInHoverZone(y: 588, height: 600))
        XCTAssertFalse(WindowChrome.isInHoverZone(y: 587, height: 600))
        XCTAssertFalse(WindowChrome.isInHoverZone(y: 601, height: 600), "above the stream")
    }

    func testThePaddingIsOnlyTheHeaderBand() {
        XCTAssertEqual(WindowChrome.windowSize(stream: CGSize(width: 900, height: 600)), CGSize(width: 900, height: 652))
        XCTAssertEqual(WindowChrome.streamSize(window: CGSize(width: 900, height: 652)), CGSize(width: 900, height: 600))
        XCTAssertEqual(WindowChrome.streamSize(window: CGSize(width: 1440, height: 900), fullScreen: true),
                       CGSize(width: 1440, height: 900), "no padding in full screen")
    }

    func testPhoneFrameKeepsThePhonesAspectRatioInTheStream() {
        let phone = CGSize(width: 1080, height: 2400)
        let pad = WindowChrome.windowSize(stream: .zero)
        XCTAssertEqual(WindowChrome.phoneFrame(proposed: CGSize(width: 540 + pad.width, height: 1100),
                                               current: CGSize(width: 450 + pad.width, height: 1100), phone: phone),
                       CGSize(width: 540 + pad.width, height: 1200 + pad.height), "the width led")
        XCTAssertEqual(WindowChrome.phoneFrame(proposed: CGSize(width: 450 + pad.width, height: 1200 + pad.height),
                                               current: CGSize(width: 450 + pad.width, height: 1000 + pad.height), phone: phone),
                       CGSize(width: 540 + pad.width, height: 1200 + pad.height), "the height led")
    }

    func testQuantisationBarsAreFilledButRealLetterboxesKept() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        // 900 x 600 pt at 2x asks for 1792 x 1200: 4 px short each side.
        XCTAssertEqual(Letterbox.videoRect(video: CGSize(width: 1792, height: 1200), in: bounds), bounds)
        XCTAssertTrue(Letterbox.fills(video: CGSize(width: 1792, height: 1200), bounds: bounds.size))
        // A frame of a different shape (mid-resize) is still fitted, not stretched.
        let tall = Letterbox.videoRect(video: CGSize(width: 1080, height: 2400), in: bounds)
        XCTAssertEqual(tall.height, 600)
        XCTAssertEqual(tall.width, 270)
        XCTAssertFalse(Letterbox.fills(video: .zero, bounds: bounds.size))
    }
}

final class StreamChromeWindowTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.chrome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keys = PairKeyStore(defaults: defaults, keys: .scratch())
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client", keyStore: keys)
        return WindowManager(session: session, defaults: defaults)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func trafficLightsShown(_ window: NSWindow?) -> Bool {
        guard let close = window?.standardWindowButton(.closeButton) else { return false }
        return !close.isHidden && close.alphaValue > 0.99
    }

    func testTheStreamSitsInsideThePaddingAndHoverChangesNoSize() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 652))
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(controller.videoView.frame, NSRect(x: 0, y: 0, width: 900, height: 600),
                       "the window's sides and bottom are the stream's")
        XCTAssertEqual(controller.header.frame, NSRect(x: 0, y: 600, width: 900, height: 52), "the band above it")
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(controller.headerController?.isVisible ?? true, "hidden at rest")
        XCTAssertFalse(trafficLightsShown(window))
        XCTAssertEqual(controller.header.alphaValue, 0)
        let atRest = (controller.videoView.frame, controller.displayPixels(), controller.dpi())

        controller.pointerMoved(toWindowPoint: content.convert(NSPoint(x: 450, y: 600), to: nil))
        pump(0.2)
        XCTAssertTrue(controller.headerController?.isVisible ?? false)
        XCTAssertTrue(trafficLightsShown(window))
        XCTAssertEqual(controller.header.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(controller.videoView.frame, atRest.0, "the stream does not move")
        XCTAssertEqual(controller.displayPixels(), atRest.1, "nor does the virtual display")
        XCTAssertEqual(controller.dpi(), atRest.2)
    }

    func testTheTrafficLightsSitWhereAStandardWindowHasThem() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frame = close.convert(close.bounds, to: nil)
        XCTAssertEqual(frame.midX, 26, accuracy: 0.5)
        XCTAssertEqual(window.frame.height - frame.midY, WindowChrome.trafficLightCentre, accuracy: 0.5)
    }

    func testTheBandLetsClicksThroughOnlyAtRest() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 1, y: 300))
        XCTAssertFalse(window.ignoresMouseEvents, "the stream reaches the window's edge (resize)")
        XCTAssertFalse(controller.headerController?.isVisible ?? true, "and does not bring the glass in")
        controller.pointerMoved(toWindowPoint: NSPoint(x: 450, y: 630))
        XCTAssertTrue(controller.headerController?.isVisible ?? false, "the hidden band brings it in")
        XCTAssertFalse(window.ignoresMouseEvents, "and then the header is clickable")
        controller.pointerMoved(toWindowPoint: NSPoint(x: 450, y: 300))
        XCTAssertFalse(controller.headerController?.isVisible ?? true)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 900, y: 300))
        XCTAssertFalse(window.ignoresMouseEvents, "just outside the right edge stays the window's (resize)")
    }

    func testItFadesOutAfterThePointerLeaves() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.pointerMoved(toWindowPoint: CGPoint(x: 450, y: 600))
        pump(0.2)
        controller.pointerMoved(toWindowPoint: CGPoint(x: 450, y: 300))
        XCTAssertFalse(controller.headerController?.isVisible ?? true, "no grace period")
        pump(0.3)
        XCTAssertEqual(controller.header.alphaValue, 0, accuracy: 0.01)
        XCTAssertFalse(trafficLightsShown(window), "and the traffic lights go with it")
    }

    func testCloseAndMinimiseWorkWhileTheTrafficLightsAreHidden() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.pointerMoved(toWindowPoint: CGPoint(x: 450, y: 600))
        pump(0.2)
        controller.pointerMoved(toWindowPoint: CGPoint(x: 450, y: 300))
        pump(0.3)
        XCTAssertFalse(trafficLightsShown(window))
        // ⌘M and ⌘W simulate a click on the buttons, which AppKit refuses for a transparent one.
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.alphaValue, 1)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.alphaValue, 1)
        window.performClose(nil)
        pump(0.2)
        XCTAssertFalse(window.isVisible, "⌘W closes the window at rest")
    }

    func testTheDebugStateFileFollowsTheHeader() throws {
        let manager = makeManager()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        manager.chromeStateFile = file
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "header=hidden lights=hidden clicks=0\n")
        controller.pointerMoved(toWindowPoint: CGPoint(x: 450, y: 600))
        pump(0.4)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "header=shown lights=shown clicks=0\n")
    }

    func testThePhoneWindowIsThePhoneShapeWithItsNavInTheHeader() throws {
        let manager = makeManager()
        let phone = PhoneWindowController(stream: 1, phone: nil, manager: manager)
        defer { phone.window?.close() }
        let stream = phone.videoBounds()
        XCTAssertEqual(stream.width / stream.height, 1080 / 2340, accuracy: 0.005, "the stream is the phone's shape")
        XCTAssertEqual(phone.videoView.frame.size, stream)
        XCTAssertEqual(phone.header.actionCount, 3, "back, home, recents")
        XCTAssertEqual(AppWindowController(stream: 2, pkg: "a", activity: nil, label: "A", manager: manager)
            .header.actionCount, 0)
    }

    func testShowTouchesIsOffByDefaultAndRemembered() {
        let manager = makeManager()
        addTeardownBlock { StreamMenuState.shared.showTouches = false }
        XCTAssertFalse(manager.showTouches)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        XCTAssertFalse(controller.videoView.showsTouches)
        manager.showTouches = true
        XCTAssertTrue(manager.showTouches)
        XCTAssertTrue(StreamMenuState.shared.showTouches)
        let next = AppWindowController(stream: 2, pkg: "com.example.app", activity: nil,
                                       label: "Example", manager: manager)
        defer { next.window?.close() }
        XCTAssertTrue(next.videoView.showsTouches, "a new window follows the setting")
    }
}

final class StreamMenuTests: XCTestCase {
    private var manager: WindowManager?

    func testTheViewMenuFollowsTheKeyStreamWindow() {
        let name = "dev.pocketdeck.tests.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
            StreamMenuState.shared.hasStream = false
        }
        let keys = PairKeyStore(defaults: defaults, keys: .scratch())
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client", keyStore: keys)
        let manager = WindowManager(session: session, defaults: defaults)
        self.manager = manager
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil, label: "Example",
                                             manager: manager)
        defer { controller.window?.close() }
        let state = StreamMenuState.shared
        XCTAssertFalse(state.hasStream)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertTrue(state.hasStream)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(state.hasStream)
        XCTAssertTrue(NSApp.sendAction(#selector(StreamWindowController.toggleShowTouches(_:)), to: controller, from: nil))
        XCTAssertTrue(manager.showTouches)
    }
}
