// The window chrome by style (WindowStyle.swift): the framed bar's frame, the
// lights on its line, the phone window's actions, the immersive dwell pill, and
// style switching — and that none of it changes the stream area the virtual
// display is sized from.

import AppKit
import XCTest
@testable import PocketDeck

final class LetterboxTests: XCTestCase {
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
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "style=framed lights=shown pill=hidden clicks=0\n")
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
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "style=framed lights=shown pill=hidden clicks=0\n")
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

final class StreamChromeImmersiveTests: XCTestCase {
    private func makeManager(choose: WindowStyle? = nil) -> WindowManager {
        let name = "dev.pocketdeck.tests.chrome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        if let choose {
            defaults.set(choose.rawValue, forKey: WindowStyleStore.key(forPackage: "com.example.app"))
        }
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

    /// An immersive window is exactly the stream: the bar's pixels on neither
    /// side, the lights out of sight until the dwell pill, and the virtual
    /// display that same window's stream.
    func testImmersiveIsTheStreamAloneWithNothingShowing() throws {
        let manager = makeManager(choose: .immersive)
        addTeardownBlock { StreamMenuState.shared.hasStream = false }
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 600), "the window is the stream alone")
        XCTAssertEqual(controller.videoView.frame.size, window.frame.size)
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertFalse(controller.chrome.barHeight > 0)
        XCTAssertFalse(trafficLightsShown(window), "no chrome at rest")
        // The View menu's radio follows the key window's style.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(StreamMenuState.shared.style, .immersive)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertTrue(close.isHidden || close.alphaValue < 1)
    }

    /// The hot zone dwell: 400 ms of rest shows the pill (the lights with it),
    /// movement or an early tap does not, and the pill leaves 600 ms after the
    /// pointer does.
    func testTheDwellPillShowsAndHides() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        window.makeKeyAndOrderFront(nil)

        // Inside the zone, but gone before the dwell is up: nothing shows.
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.2)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 500, y: 400))
        pump(0.3)
        XCTAssertFalse(controller.dwell.shown)

        // A rest in the zone shows the pill over 350 ms; the lights ride it.
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.05)
        XCTAssertFalse(controller.dwell.shown, "100 ms is no rest")
        pump(0.4)
        XCTAssertTrue(controller.dwell.shown)
        XCTAssertTrue(controller.chrome.showsPill)
        XCTAssertTrue(trafficLightsShown(window), "the pill carries the lights")
        let closeFrame = try XCTUnwrap(window.standardWindowButton(.closeButton)).convert(
            try XCTUnwrap(window.standardWindowButton(.closeButton)).bounds, to: nil)
        XCTAssertEqual(closeFrame.midX, DwellChrome.pillLightInset + 7, accuracy: 0.5,
                       "the lights sit on the pill's row")
    }

    func testThePillHidesAfterThePointerLeaves() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.5)
        XCTAssertTrue(controller.dwell.shown)
        // The pointer left: 600 ms of grace, hidden before a whole second.
        controller.pointerMoved(toWindowPoint: NSPoint(x: 500, y: 300))
        pump(0.45)
        XCTAssertTrue(controller.dwell.shown, "still within the 600 ms grace")
        pump(0.35)
        XCTAssertFalse(controller.dwell.shown, "gone 600 ms after the pointer left")
        pump(0.15)
        XCTAssertFalse(trafficLightsShown(window))
    }

    /// A touch through the hot zone restarts the rest (the pill cannot appear
    /// while the finger is still tapping there), though it reaches the app.
    func testATouchInTheZoneRestartsTheRest() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.3)
        // A tap through the zone at 300 ms: the rest begins at the tap, so the
        // pill is not up 50 ms after it. The touch itself was the app's.
        let bounds = controller.videoBounds()
        let nx = Float(20 / bounds.width), ny = Float(20 / bounds.height)
        controller.touchInHotZone(TouchEvent(action: .down, nx: nx, ny: ny))
        pump(0.05)
        XCTAssertFalse(controller.dwell.shown, "the tap reset the rest")
        pump(0.4)
        XCTAssertTrue(controller.dwell.shown, "350 ms of quiet after the tap shows the pill")
    }

    /// Switching keeps the stream's place and remembers the choice: near the
    /// top of the screen the window moves down by just what would poke above.
    func testSwitchingStylesKeepsTheStreamAndIsRemembered() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        let window = try XCTUnwrap(controller.window)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.orderFront(nil)
        // The stream's top edge at the screen's top: the bar has nowhere to go,
        // so the window moves down by exactly the bar on the way to immersive.
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 200, y: visible.maxY))
        XCTAssertEqual(window.frame.maxY, visible.maxY)

        controller.setStyle(.immersive)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 600), "the window is the stream alone")
        XCTAssertEqual(window.frame.minX, visible.minX + 200)
        XCTAssertEqual(window.frame.maxY - window.frame.height, visible.maxY - 628,
                       "the stream keeps its place; the bar went")
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .immersive, "the choice is remembered for the package")
        XCTAssertEqual(StreamMenuState.shared.style, .immersive)
        controller.setStyle(.framed)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 628))
        XCTAssertEqual(window.frame.maxY, visible.maxY, "the bar is back and fits again")
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .framed)
        XCTAssertTrue(trafficLightsShown(window), "framed shows the lights again")
        XCTAssertFalse(controller.chrome.toggleHidden, "and the toggle rides the bar again")
        XCTAssertEqual(controller.chrome.pill.alphaValue, 0, "and the pill is gone")
    }

    /// The toggle's action (bar and pill) is the same switch.
    func testToggleFlipsTheStyleAndTheWindowSizeByTheBar() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        XCTAssertEqual(window.frame.height, 628)
        controller.toggleStyle()
        XCTAssertEqual(window.frame.height, 600)
        XCTAssertEqual(controller.style, .immersive)
        controller.toggleStyle()
        XCTAssertEqual(window.frame.height, 628)
        XCTAssertEqual(controller.style, .framed)
    }

    /// A stored immersive choice opens the window already immersive.
    func testAStoredImmersiveChoiceOpensImmersive() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.style, .immersive)
        window.orderFront(nil)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 600))
    }

    /// Full screen drops the chrome in both styles: the stream is the whole
    /// screen and the dwell is not fed.
    func testFullScreenDropsTheBarAndTheDwell() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification))
        pump(0.1)
        XCTAssertEqual(controller.videoBounds(), window.frame.size, "no padding in full screen")
        XCTAssertFalse(controller.chrome.showsPill, "no dwell pill in full screen")
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        pump(0.1)
        XCTAssertEqual(controller.videoView.frame.size, window.frame.size, "immersive at rest again")
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
