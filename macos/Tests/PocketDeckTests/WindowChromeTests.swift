// The window chrome by style (WindowStyle.swift): the framed bar's frame, the
// lights on its line, the phone window's actions, and that none of it changes
// the stream area the virtual display is sized from.

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

    func testTheStreamFillsTheWindowUnderTheBar() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 628), "the window is the stream plus the bar")
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(controller.videoView.frame, NSRect(x: 0, y: 0, width: 900, height: 600),
                       "the stream fills the window minus the bar")
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.dwell.shown, false)
        XCTAssertTrue(trafficLightsShown(window), "the framed bar holds the lights at once")
        let atRest = (controller.videoView.frame, controller.displayPixels(), controller.dpi())

        // The bar is permanent: no hover syntax can change the stream's geometry.
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification))
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        pump(0.2)
        XCTAssertEqual(controller.videoView.frame, atRest.0, "the stream does not move")
        XCTAssertEqual(controller.displayPixels(), atRest.1, "nor does the virtual display")
        XCTAssertEqual(controller.dpi(), atRest.2)
    }

    func testTheBarIsTheWindowsMaterialAndTheStreamSquaresItsTopCorners() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        let chrome = try XCTUnwrap(window.contentView as? StreamChromeView)
        XCTAssertEqual(chrome.barHeight, ChromeBar.height)
        XCTAssertEqual(chrome.style, .framed)
        XCTAssertFalse(chrome.isOpaque)
        XCTAssertEqual(controller.chrome.actionCount, 0, "app windows have no actions")
        // The seam is the stream's top edge: bottom corners rounded, top square.
        XCTAssertEqual(controller.videoView.layer?.cornerRadius, ChromeBar.cornerRadius)
        XCTAssertEqual(controller.videoView.layer?.maskedCorners,
                       [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    func testTheTrafficLightsSitOnTheBarsLine() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frame = close.convert(close.bounds, to: nil)
        XCTAssertEqual(frame.midX, ChromeBar.trafficLightInset + 7, accuracy: 0.5)
        XCTAssertEqual(window.frame.height - frame.midY, 14, accuracy: 0.5, "centred on the 28 pt bar")
        XCTAssertFalse(close.isHidden)
    }

    func testABarClickIsTheWindowsOwnAndNeverPassesThrough() throws {
        let manager = makeManager()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        manager.chromeStateFile = file
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        XCTAssertFalse(window.ignoresMouseEvents, "the framed bar is the window's (drag)")
        controller.pointerMoved(toWindowPoint: NSPoint(x: 2, y: 20))
        pump(0.4)
        XCTAssertFalse(controller.dwell.shown)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "style=framed lights=shown clicks=0\n")
    }

    func testCloseAndMinimiseWorkWithTheBar() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        window.performMiniaturize(nil)
        pump(0.2)
        XCTAssertTrue(window.isMiniaturized)
        window.deminiaturize(nil)
        pump(0.2)
        XCTAssertFalse(window.isMiniaturized)
        window.performClose(nil)
        pump(0.2)
        XCTAssertFalse(window.isVisible, "⌘W closes the window")
    }

    func testTheDebugStateFileReportsTheStyleAndLights() throws {
        let manager = makeManager()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        manager.chromeStateFile = file
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "style=framed lights=shown clicks=0\n")
    }

    func testThePhoneWindowIsThePhoneShapeWithItsActionsOnTheBar() throws {
        let manager = makeManager()
        let phone = PhoneWindowController(stream: 1, phone: nil, manager: manager)
        defer { phone.window?.close() }
        let stream = phone.videoBounds()
        XCTAssertEqual(stream.width / stream.height, 1080 / 2340, accuracy: 0.005, "the stream is the phone's shape")
        XCTAssertEqual(phone.videoView.frame.size, stream)
        XCTAssertEqual(phone.chrome.actionCount, 3, "back, home, recents on the bar")
        XCTAssertEqual(AppWindowController(stream: 2, pkg: "a", activity: nil, label: "A", manager: manager)
            .chrome.actionCount, 0)
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
