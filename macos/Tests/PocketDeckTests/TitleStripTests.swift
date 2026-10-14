// The title strip: the virtual display is sized from, and input is mapped
// against, the video area only; the strip above it belongs to the titlebar.

import AppKit
import XCTest
@testable import PocketDeck

final class TitleStripTests: XCTestCase {

    // MARK: Arithmetic

    func testTheStripIsTheTitlebarWhenOnAndNothingWhenOff() {
        XCTAssertEqual(TitleStrip.reservedHeight(titlebar: 32, enabled: true), 32)
        XCTAssertEqual(TitleStrip.reservedHeight(titlebar: 32, enabled: false), 0)
        XCTAssertEqual(TitleStrip.reservedHeight(titlebar: 0, enabled: true), 0, "no titlebar in full screen, no strip")
    }

    func testVideoAreaIsTheContentBelowTheStrip() {
        XCTAssertEqual(TitleStrip.videoSize(content: CGSize(width: 900, height: 632), titlebar: 32, enabled: true),
                       CGSize(width: 900, height: 600))
        XCTAssertEqual(TitleStrip.videoSize(content: CGSize(width: 900, height: 632), titlebar: 32, enabled: false),
                       CGSize(width: 900, height: 632))
        XCTAssertEqual(TitleStrip.videoSize(content: CGSize(width: 900, height: 20), titlebar: 32, enabled: true).height, 0)
        XCTAssertEqual(TitleStrip.contentHeight(videoHeight: 600, titlebar: 32, enabled: true), 632)
    }

    func testTheVirtualDisplayExcludesTheStrip() {
        let content = CGSize(width: 900, height: 632)
        let scale = 2.0
        let on = VideoSize.displayPixels(
            bounds: TitleStrip.videoSize(content: content, titlebar: 32, enabled: true), backingScale: scale)
        let off = VideoSize.displayPixels(
            bounds: TitleStrip.videoSize(content: content, titlebar: 32, enabled: false), backingScale: scale)
        XCTAssertEqual(on, CGSize(width: 1792, height: 1200), "600 pt x 2, floored to 16")
        XCTAssertEqual(off, CGSize(width: 1792, height: 1264), "the whole 632 pt when the strip is off")
        XCTAssertEqual(off.height - on.height, 64, "the strip's 32 pt at 2x")
    }

    func testTheDensityIsTheSameWithAndWithoutTheStrip() {
        // Same width, so the apps lay out at the same dp width either way.
        let on = VideoSize.dpi(pixels: CGSize(width: 1792, height: 1200), bounds: CGSize(width: 900, height: 600), density: 1)
        let off = VideoSize.dpi(pixels: CGSize(width: 1792, height: 1264), bounds: CGSize(width: 900, height: 632), density: 1)
        XCTAssertEqual(on, off, accuracy: 1e-9)
    }

    func testInputIsMappedInsideTheVideoAreaOnly() {
        // The video view is 900 x 600 and starts under the strip; its own
        // coordinates have no strip in them, so its top edge is ny = 0.
        let video = CGRect(x: 0, y: 0, width: 900, height: 600)
        let top = Letterbox.normalized(point: CGPoint(x: 450, y: 600), videoRect: video, flipped: false)
        let middle = Letterbox.normalized(point: CGPoint(x: 450, y: 300), videoRect: video, flipped: false)
        XCTAssertEqual(top.ny, 0)
        XCTAssertEqual(middle.ny, 0.5)
        // A point in the strip (above the video's top) clamps to the edge.
        XCTAssertEqual(Letterbox.normalized(point: CGPoint(x: 450, y: 615), videoRect: video, flipped: false).ny, 0)
    }

    // MARK: Phone window shape

    func testPhoneFrameKeepsTheVideoAspectRatioNotTheFrames() {
        let phone = CGSize(width: 1080, height: 2400)
        // The width led: the height is the video height plus the strip.
        let widthLed = TitleStrip.phoneFrame(proposed: CGSize(width: 540, height: 1100),
                                             current: CGSize(width: 450, height: 1100), phone: phone, reserved: 32)
        XCTAssertEqual(widthLed, CGSize(width: 540, height: 1200 + 32))
        // The height led: the width follows from the video height.
        let heightLed = TitleStrip.phoneFrame(proposed: CGSize(width: 450, height: 1232),
                                              current: CGSize(width: 450, height: 1100), phone: phone, reserved: 32)
        XCTAssertEqual(heightLed, CGSize(width: 540, height: 1232))
        // Without a strip nothing is added.
        XCTAssertEqual(TitleStrip.phoneFrame(proposed: CGSize(width: 540, height: 900),
                                             current: CGSize(width: 450, height: 900), phone: phone, reserved: 0),
                       CGSize(width: 540, height: 1200))
    }

    func testTheTitlebarFadeZoneIsTheTopEdge() {
        XCTAssertTrue(TitlebarFader.isNearTop(y: 630, windowHeight: 632))
        XCTAssertTrue(TitlebarFader.isNearTop(y: 632 - TitlebarFader.nearEdge, windowHeight: 632))
        XCTAssertFalse(TitlebarFader.isNearTop(y: 300, windowHeight: 632))
        XCTAssertEqual(TitlebarFader.idleDelay, 2)
    }

    // MARK: A real window

    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.strip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keys = PairKeyStore(defaults: defaults, keys: .scratch())
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client", keyStore: keys)
        return WindowManager(session: session, defaults: defaults)
    }

    /// Lays the window out the way the screen would; the video view's own bounds
    /// are what input is mapped against, so they must equal the arithmetic.
    private func laidOut(_ controller: StreamWindowController) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    func testTheVideoViewSitsBelowTheStripAndMatchesTheVirtualDisplayArea() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        laidOut(controller)
        let content = try XCTUnwrap(controller.window?.contentView).bounds
        let titlebar = controller.titlebarHeight
        XCTAssertGreaterThan(titlebar, 0)
        XCTAssertTrue(controller.strip.titleStrip, "on by default")
        XCTAssertEqual(controller.videoView.bounds.size, controller.videoBounds())
        XCTAssertEqual(controller.videoView.bounds.height, content.height - titlebar, accuracy: 0.5)
        // The video's top edge is the titlebar's bottom edge.
        let top = controller.videoView.convert(CGPoint(x: 10, y: controller.videoView.bounds.maxY), to: nil)
        XCTAssertEqual(top.y, content.height - titlebar, accuracy: 0.5)
        // Mapping a click at the video's top edge gives ny = 0 and the virtual
        // display is the video area only.
        let pixels = controller.displayPixels()
        let scale = Double(controller.window?.backingScaleFactor ?? 2)
        XCTAssertEqual(Double(pixels.height), ((content.height - titlebar) * scale / 16).rounded(.down) * 16)
    }

    func testTurningTheStripOffGivesTheVideoTheWholeWindowAndIsRemembered() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        laidOut(controller)
        let withStrip = controller.displayPixels()
        controller.setTitleStrip(false)
        laidOut(controller)
        let content = try XCTUnwrap(controller.window?.contentView).bounds
        XCTAssertEqual(controller.videoView.bounds.size.height, content.height, accuracy: 0.5)
        XCTAssertEqual(controller.videoBounds(), content.size)
        XCTAssertGreaterThan(controller.displayPixels().height, withStrip.height)
        XCTAssertFalse(manager.titleStrip(forKey: "app.com.example.app"))
        XCTAssertTrue(manager.titleStrip(forKey: "app.com.example.other"), "per app, on by default")
        // A new window of the same app starts the way the last one was left.
        let again = AppWindowController(stream: 2, pkg: "com.example.app", activity: nil,
                                        label: "Example", manager: manager)
        defer { again.window?.close() }
        XCTAssertFalse(again.strip.titleStrip)
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
    /// A controller holds its manager unowned.
    private var manager: WindowManager?

    private func makeController() -> (AppWindowController, WindowManager) {
        let name = "dev.pocketdeck.tests.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
            StreamMenuState.shared.hasStream = false
            StreamMenuState.shared.titleStrip = true
            StreamMenuState.shared.showTouches = false
        }
        let keys = PairKeyStore(defaults: defaults, keys: .scratch())
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client", keyStore: keys)
        let manager = WindowManager(session: session, defaults: defaults)
        self.manager = manager
        return (AppWindowController(stream: 1, pkg: "com.example.app", activity: nil, label: "Example", manager: manager),
                manager)
    }

    func testTheViewMenuFollowsTheKeyStreamWindow() {
        let (controller, _) = makeController()
        defer { controller.window?.close() }
        let state = StreamMenuState.shared
        XCTAssertFalse(state.hasStream)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertTrue(state.hasStream)
        XCTAssertTrue(state.titleStrip)
        controller.setTitleStrip(false)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertFalse(state.titleStrip, "the check mark shows the key window's own state")
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(state.hasStream, "the strip item is disabled when no stream window is key")
    }

    func testTheMenuActionReachesTheWindowsController() throws {
        // The menu sends the action to "nobody"; AppKit asks the key window's
        // responder chain and then its delegate, which is the controller. A test
        // process cannot make a window key, so the delegate is checked directly.
        let (controller, _) = makeController()
        defer { controller.window?.close() }
        XCTAssertTrue(controller.window?.delegate === controller)
        XCTAssertTrue(controller.responds(to: #selector(StreamWindowController.toggleTitleStrip(_:))))
        XCTAssertTrue(NSApp.sendAction(#selector(StreamWindowController.toggleTitleStrip(_:)), to: controller, from: nil))
        XCTAssertFalse(controller.strip.titleStrip)
        XCTAssertTrue(NSApp.sendAction(#selector(StreamWindowController.toggleTitleStrip(_:)), to: controller, from: nil))
        XCTAssertTrue(controller.strip.titleStrip)
    }
}

final class TitlebarFaderTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.orderFront(nil)
        addTeardownBlock { window.close() }
        return window
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testTheTrafficLightsFadeOutWhenTheyAreIdleAndBackInNearTheTopEdge() {
        let window = makeWindow()
        var pointer = NSPoint(x: window.frame.midX, y: window.frame.minY - 500)
        let fader = TitlebarFader(window: window, idleDelay: 0.05, pointerLocation: { pointer })
        fader.start()
        defer { fader.stop() }
        XCTAssertEqual(fader.titlebarAlpha, 1, "shown at first")
        pump(0.8)
        XCTAssertEqual(fader.titlebarAlpha, 0, accuracy: 0.001, "faded out without the pointer near")
        pointer = NSPoint(x: window.frame.midX, y: window.frame.maxY - 5)
        fader.pointerMoved(toWindowY: window.frame.height - 5)
        pump(0.8)
        XCTAssertEqual(fader.titlebarAlpha, 1, accuracy: 0.001, "faded back in, and stays while the pointer is up there")
        pointer = NSPoint(x: window.frame.midX, y: window.frame.minY - 500)
        pump(0.8)
        XCTAssertEqual(fader.titlebarAlpha, 0, accuracy: 0.001, "and out again once the pointer left")
    }

    func testAMoveAwayFromTheTopEdgeDoesNotShowThem() {
        let window = makeWindow()
        let away = NSPoint(x: window.frame.midX, y: window.frame.minY - 500)
        let fader = TitlebarFader(window: window, idleDelay: 0.05, pointerLocation: { away })
        fader.start()
        defer { fader.stop() }
        pump(0.8)
        fader.pointerMoved(toWindowY: 100)
        pump(0.4)
        XCTAssertEqual(fader.titlebarAlpha, 0, accuracy: 0.001)
    }

    func testThePointerRestingNearTheTopEdgeKeepsThemShown() {
        let window = makeWindow()
        let near = NSPoint(x: window.frame.midX, y: window.frame.maxY - 5)
        let fader = TitlebarFader(window: window, idleDelay: 0.05, pointerLocation: { near })
        fader.start()
        defer { fader.stop() }
        pump(0.8)
        XCTAssertEqual(fader.titlebarAlpha, 1, "no idle fade while the pointer is up there")
    }

    func testStoppingBringsThemBackForGood() {
        let window = makeWindow()
        let away = NSPoint(x: window.frame.midX, y: window.frame.minY - 500)
        let fader = TitlebarFader(window: window, idleDelay: 0.05, pointerLocation: { away })
        fader.start()
        pump(0.8)
        XCTAssertEqual(fader.titlebarAlpha, 0, accuracy: 0.001)
        fader.stop()
        XCTAssertEqual(fader.titlebarAlpha, 1)
        pump(0.5)
        XCTAssertEqual(fader.titlebarAlpha, 1, "the pending hide is gone")
    }
}
