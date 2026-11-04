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
    /// The state line without its `video=` rect, which the picture's band check
    /// reads on its own (the rest of the line is compared exactly).
    private func withoutVideo(_ line: String) -> String {
        line.replacingOccurrences(of: #" video=\d+,\d+,\d+,\d+"#, with: "", options: .regularExpression)
    }

    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.chrome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
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
        controller.noteFirstFrame()
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

    func testTheBarIsTheMirrorAndTheStreamSquaresItsTopCorners() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.noteFirstFrame()
        let chrome = try XCTUnwrap(window.contentView as? StreamChromeView)
        XCTAssertEqual(chrome.barHeight, ChromeBar.height)
        XCTAssertEqual(chrome.style, .framed)
        XCTAssertFalse(chrome.isOpaque)
        XCTAssertEqual(controller.chrome.actionCount, 0, "app windows have no actions")
        // The bar is the extension view's own blurred replica: no material or
        // other fill sits over it, so nothing can tint the stream.
        XCTAssertTrue(chrome.subviews.contains { $0 is NSBackgroundExtensionView })
        XCTAssertFalse(chrome.subviews.contains { $0 is NSVisualEffectView },
                       "no material layer over the bar")
        // The corners round once, on the container (the chrome view): the video
        // stays square so the seam is straight in framed.
        XCTAssertEqual(chrome.layer?.cornerRadius, ChromeBar.cornerRadius)
        XCTAssertEqual(chrome.layer?.masksToBounds, true)
        XCTAssertEqual(controller.videoView.layer?.cornerRadius, 0)
    }

    func testTheTrafficLightsSitOnTheBarsLine() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.noteFirstFrame()
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
        controller.noteFirstFrame()
        XCTAssertFalse(window.ignoresMouseEvents, "the framed bar is the window's (drag)")
        controller.pointerMoved(toWindowPoint: NSPoint(x: 2, y: 20))
        pump(0.4)
        XCTAssertFalse(controller.dwell.shown)
        let frame = "\(Int(window.frame.width.rounded()))x\(Int(window.frame.height.rounded()))"
        let state = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(state.range(of: #" video=\d+,\d+,\d+,\d+\n$"#, options: .regularExpression),
                        "the picture rect is reported")
        XCTAssertEqual(withoutVideo(state), "style=framed lights=shown pill=hidden title_visible=no lights_managed=us fullscreen=no clicks=0 dots=outside touches=\(manager.showTouches ? "on" : "off") dot_count=0 collection=0 collection_none=0 can_fullscreen=1 screen=on overlay=0 secure=0 panel_off=0 panel_pill=0 panel_pill_failed=0 panel_click_at=0 panel_glyph_at=0 panel_requests=0 stall=0 stall_overlay=0 stall_icon=0 stills=0 paused=0 expecting=0 opening=0 frame_age_ms=-1 drop_pill=hidden drop_refusal=none paste_pill=hidden paste_button=0 loading=0 cover_phase=0 cover_buttons=none bar_offline=0 bar_enabled=none bar_focus=none bar_blur_radius=0 haze=1 key=0 responder_video=1 frame=\(frame) video_gap=0\n")
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
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        let frame = "\(Int(window.frame.width.rounded()))x\(Int(window.frame.height.rounded()))"
        let state = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(state.range(of: #" video=\d+,\d+,\d+,\d+\n$"#, options: .regularExpression),
                        "the picture rect is reported")
        // The window is still opening: the cover is one sheet over it and the
        // framed bar's mirror, blur and haze wait for the first frame (WIN-11).
        XCTAssertEqual(withoutVideo(state), "style=framed lights=hidden pill=hidden title_visible=no lights_managed=us fullscreen=no clicks=0 dots=outside touches=\(manager.showTouches ? "on" : "off") dot_count=0 collection=0 collection_none=0 can_fullscreen=1 screen=on overlay=0 secure=0 panel_off=0 panel_pill=0 panel_pill_failed=0 panel_click_at=0 panel_glyph_at=0 panel_requests=0 stall=0 stall_overlay=0 stall_icon=0 stills=0 paused=0 expecting=0 opening=1 frame_age_ms=-1 drop_pill=hidden drop_refusal=none paste_pill=hidden paste_button=0 loading=1 cover_phase=opening cover_buttons=none bar_offline=0 bar_enabled=none bar_focus=none bar_blur_radius=0 haze=0 key=0 responder_video=0 frame=\(frame) video_gap=0\n")
        controller.noteFirstFrame()
        let live = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(live.hasPrefix("style=framed lights=shown pill=hidden"), live)
        XCTAssertTrue(live.contains("loading=0 cover_phase=0"), live)
        XCTAssertTrue(live.contains("bar_blur_radius=0 haze=1"), live)
    }

    func testFullScreenShowsTheTitleAndHandsTheLightsBackOnExit() throws {
        let manager = makeManager()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        manager.chromeStateFile = file
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.noteFirstFrame()
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))

        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
        XCTAssertEqual(window.titleVisibility, .visible, "the system's bar shows the window's title")
        XCTAssertFalse(window.titlebarAppearsTransparent, "and is the standard one")
        XCTAssertTrue(trafficLightsShown(window), "the standard lights stay up")
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification))
        let state = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(state.hasPrefix("style=framed lights=shown pill=hidden title_visible=yes lights_managed=appkit"),
                      state)

        controller.windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification))
        XCTAssertEqual(window.titleVisibility, .hidden, "the windowed chrome's title is hidden again")
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(trafficLightsShown(window), "the framed bar takes the lights back")
        let back = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(back.hasPrefix("style=framed lights=shown pill=hidden title_visible=no lights_managed=us"), back)
    }

    func testThePhoneWindowIsThePhoneShapeWithItsActionsOnTheBar() throws {
        let manager = makeManager()
        let phone = PhoneWindowController(stream: 1, phone: nil, manager: manager)
        defer { phone.window?.close() }
        phone.noteFirstFrame()
        let stream = phone.videoBounds()
        XCTAssertEqual(stream.width / stream.height, 1080 / 2340, accuracy: 0.005, "the stream is the phone's shape")
        XCTAssertEqual(phone.videoView.frame.size, stream)
        XCTAssertEqual(phone.chrome.actionCount, 4,
                       "back, home, recents and Turn Off Phone Screen on the phone window's bar only")
        XCTAssertEqual(AppWindowController(stream: 2, pkg: "a", activity: nil, label: "A", manager: manager)
            .chrome.actionCount, 0)
    }

    /// The opening cover is a frozen mode: no input to the phone until the
    /// stream's first frame, and no stall claim before there is a picture.
    func testAWindowIsFrozenUntilItsFirstFrame() throws {
        let manager = makeManager()
        let app = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                      label: "Example", manager: manager)
        defer { app.window?.close() }
        let window = try XCTUnwrap(app.window)
        window.orderFront(nil)
        app.occlusionVisibleOverride = true

        XCTAssertTrue(app.isOpening)
        XCTAssertTrue(app.frozen, "the phone sees nothing before its picture")
        XCTAssertFalse(app.expectsFrames, "no live picture to be stale yet")

        app.noteFirstFrame()
        XCTAssertFalse(app.isOpening)
        XCTAssertFalse(app.frozen)
        XCTAssertTrue(app.expectsFrames)

        let phone = PhoneWindowController(stream: 2, phone: nil, manager: manager)
        defer { phone.window?.close() }
        XCTAssertTrue(phone.showsOpeningCover)
        XCTAssertTrue(phone.isOpening, "the phone window is covered until its first frame too")
        XCTAssertTrue(phone.frozen)
        phone.noteFirstFrame()
        XCTAssertFalse(phone.isOpening)
    }

    /// The phone turning mid-drag must not move the window under the hand: the
    /// turn waits for the drag to end.
    func testAStreamEventDoesNotMoveThePhoneWindowMidDrag() throws {
        let manager = makeManager()
        let phone = PhoneWindowController(stream: 1, phone: nil, manager: manager)
        defer { phone.window?.close() }
        let window = try XCTUnwrap(phone.window)
        window.orderFront(nil)
        let before = window.frame

        phone.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
        XCTAssertTrue(phone.isLiveResizing)
        phone.videoView.setVideoSizeForTesting(CGSize(width: 2340, height: 1080))
        phone.followRotation()
        XCTAssertEqual(window.frame, before, "the phone turned, but the drag owns the frame")

        phone.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
        XCTAssertFalse(phone.isLiveResizing)
        XCTAssertNotEqual(window.frame.size, before.size, "the deferred turn applies when the drag ends")
    }

    func testTheTouchDotsLayerIsOutsideTheMirroredVideo() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        XCTAssertTrue(controller.chrome.touchDotsOutsideMirror,
                      "the extension view mirrors the video; the dots must not be in it")
        XCTAssertTrue(controller.videoView.touchDotHost === controller.chrome.touchDotsLayer)
        XCTAssertFalse(controller.chrome.touchDotsLayer.superlayer === controller.videoView.layer,
                       "a dot on the video's own layer is reflected into the bar")
        XCTAssertGreaterThan(controller.chrome.touchDotsLayer.zPosition, 0,
                             "the dots composite above the extension view")
        XCTAssertTrue(controller.chrome.touchDotsLayer.masksToBounds,
                      "a touch at the top edge is clipped at the seam, never over the bar")

        controller.videoView.showsTouches = true
        controller.videoView.showTouchPoints([.init(id: 0, nx: 0.5, ny: 0.95)])
        XCTAssertEqual(controller.chrome.touchDotsLayer.sublayers?.count, 1,
                       "the dot is drawn on the chrome's layer")
        XCTAssertEqual(controller.chrome.touchDotCount, 1)
        XCTAssertEqual(controller.videoView.layer?.sublayers?.contains { $0.zPosition == 20 } ?? true, false,
                       "and nothing is drawn on the mirrored video layer")
    }

    func testShowTouchesStartsFromTheHardwareAndRemembersTheToggle() {
        let manager = makeManager()
        addTeardownBlock { StreamMenuState.shared.showTouches = false }
        // Nothing stored yet: the default follows the machine's trackpad.
        XCTAssertEqual(manager.showTouches, TrackpadPresence.anyTrackpad())
        XCTAssertEqual(StreamMenuState.shared.showTouches, TrackpadPresence.anyTrackpad())
        // The stored choice wins from the first toggle on.
        manager.showTouches = false
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
        let pins = PhonePinStoreV2()
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client", pinStore: pins)
        return WindowManager(session: session, defaults: defaults)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func trafficLightsShown(_ window: NSWindow?) -> Bool {
        guard let close = window?.standardWindowButton(.closeButton) else { return false }
        return !close.isHidden && close.alphaValue > 0.99
    }

    /// Settings → General "Reveal controls after" reaches the open windows at
    /// once, and a rest already running is re-timed from its start.
    func testTheRevealDelaySettingAppliesToOpenWindowsLive() throws {
        let manager = makeManager(choose: .immersive)
        // Through the manager, as every window is: the live update walks the
        // windows it owns.
        let controller = manager.openOrRaise(pkg: "com.example.app")
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        XCTAssertEqual(controller.dwell.dwell, RevealDelay.short.seconds, "the default is Short")

        manager.setRevealDelay(.long)
        XCTAssertEqual(controller.dwell.dwell, RevealDelay.long.seconds, "open windows follow at once")
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.4)
        XCTAssertFalse(controller.dwell.shown, "Long has not rested long enough at 400 ms")
        pump(0.35)
        XCTAssertTrue(controller.dwell.shown, "but it has at 750 ms")

        // Leave the zone, let the pill go, then pick Instantly: the next rest
        // shows it without waiting.
        controller.pointerMoved(toWindowPoint: NSPoint(x: 500, y: 300))
        pump(0.75)
        XCTAssertFalse(controller.dwell.shown)
        manager.setRevealDelay(.instantly)
        XCTAssertEqual(controller.dwell.dwell, 0)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.05)
        XCTAssertTrue(controller.dwell.shown, "Instantly needs no dwell")
    }

    func testTheImmersivePillIsClearGlass() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        XCTAssertEqual(controller.chrome.pill.style, .clear, "clear glass: blur without the grey fill")
        XCTAssertEqual(controller.chrome.pill.tintColor, .clear, "and no tint of its own")
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
        controller.noteFirstFrame()
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
        XCTAssertEqual(controller.chrome.pill.alphaValue, 0, "and the pill is gone")
    }

    /// View ▸ Toggle Window Style (⌥⌘F, and the scripted driver's toggle) is
    /// the same switch: the window size flips by the bar and the style with it.
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

    /// The round trip the user asked for: switch an app's window, close it, and
    /// the window that opens again for the same package comes back in the
    /// switched style — one window's choice never reaches another's.
    func testAReopenedAppComesBackInTheSwitchedStyle() throws {
        let manager = makeManager()
        let first = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                        label: "Example", manager: manager)
        defer { first.window?.close() }
        let window = try XCTUnwrap(first.window)
        window.orderFront(nil)
        XCTAssertEqual(first.style, .framed, "no stored choice opens framed")
        first.setStyle(.immersive)
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .immersive, "the switch wrote the package's key")

        // Same manager (so the same profile defaults), a new window for the
        // same package: it opens in the stored style. Another package in the
        // same run still gets framed.
        let second = AppWindowController(stream: 2, pkg: "com.example.app", activity: nil,
                                         label: "Example", manager: manager)
        defer { second.window?.close() }
        XCTAssertEqual(second.style, .immersive)
        let secondWindow = try XCTUnwrap(second.window)
        XCTAssertEqual(secondWindow.frame.size, NSSize(width: 900, height: 600), "the window is the stream alone")

        let other = AppWindowController(stream: 3, pkg: "com.example.other", activity: nil,
                                        label: "Other", manager: manager)
        defer { other.window?.close() }
        XCTAssertEqual(other.style, .framed, "another package opens framed")
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

    // MARK: The opening cover behaves like immersive (WIN-11)

    private func lightFrame(_ window: NSWindow, _ type: NSWindow.ButtonType) throws -> NSRect {
        let light = try XCTUnwrap(window.standardWindowButton(type))
        return light.convert(light.bounds, to: nil)
    }

    /// While a framed window's cover is up, the pointer's rest in the hot zone
    /// brings the pill and the lights exactly as an immersive window of the
    /// same size does; hovering the pill is Mac UI, not a phone hover.
    func testTheCoverDwellsLikeAnImmersiveWindow() throws {
        // The reference: an immersive window the same size as the framed
        // window's content (900 x 628), so the pill's frames compare directly.
        let immersive = makeManager(choose: .immersive)
        let reference = AppWindowController(stream: 2, pkg: "com.example.app", activity: nil,
                                            label: "Reference", manager: immersive)
        defer { reference.window?.close() }
        let referenceWindow = try XCTUnwrap(reference.window)
        reference.present()
        referenceWindow.setContentSize(NSSize(width: 900, height: 628))
        reference.chrome.layoutChrome()
        reference.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 620))
        pump(0.5)
        XCTAssertTrue(reference.chrome.showsPill, "the immersive reference shows its pill")
        let referencePill = reference.chrome.pill.frame
        let referenceClose = try lightFrame(referenceWindow, .closeButton)

        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        controller.present()
        XCTAssertEqual(controller.style, .framed, "the window's stored style is framed")
        XCTAssertEqual(controller.chrome.barHeight, 0, "the cover wears the immersive geometry")
        XCTAssertTrue(controller.videoView.hoverFeedActive(),
                      "the window feed carries the pointer, as in immersive")
        XCTAssertFalse(controller.chrome.showsPill, "nothing shows at rest")

        // The screen feed is the real pointer's path in immersive.
        controller.pointerMoved(toScreen: window.convertPoint(toScreen: NSPoint(x: 20, y: 620)))
        pump(0.5)
        XCTAssertTrue(controller.dwell.shown, "the rest in the hot zone brings the pill")
        XCTAssertTrue(controller.chrome.showsPill)
        XCTAssertTrue(trafficLightsShown(window), "the pill carries the lights")
        XCTAssertEqual(controller.chrome.pill.frame, referencePill,
                       "the pill is laid out exactly as immersive lays it out")
        XCTAssertEqual(try lightFrame(window, .closeButton), referenceClose,
                       "and the lights ride its row in the same place")
        // The pill is Mac UI drawn over the picture, not a phone hover.
        let centre = NSPoint(x: referencePill.midX, y: referencePill.midY)
        XCTAssertEqual(controller.videoView.macUIAtWindowPoint?(centre), true)

        // The first frame: the cover goes, the framed bar returns with its
        // lights, and the framed window has no dwell to run afterwards.
        controller.noteFirstFrame()
        pump(0.25)
        XCTAssertEqual(controller.chrome.barHeight, ChromeBar.height, "the framed bar comes back")
        XCTAssertFalse(controller.chrome.showsPill, "the cover's pill goes with the cover")
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        XCTAssertEqual(try lightFrame(window, .closeButton).midY,
                       window.frame.height - ChromeBar.height / 2, accuracy: 0.5,
                       "the lights are back on the bar's line")
        XCTAssertFalse(controller.videoView.hoverFeedActive(), "the framed window's tracking area feeds hover again")
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 620))
        pump(0.5)
        XCTAssertFalse(controller.chrome.showsPill, "no dwell runs after the cover (framed has none)")
        XCTAssertFalse(controller.dwell.shown)
    }

    /// "Always Visible" shows the cover's lights and pill at once, and they
    /// stay up — the framed window has no dwell even while the cover is up.
    func testAlwaysVisibleShowsTheCoversChromeAtOnce() throws {
        let manager = makeManager()
        manager.setRevealDelay(.alwaysVisible)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        controller.present()
        pump(0.25)
        XCTAssertEqual(controller.chrome.barHeight, 0, "the cover still wears the immersive geometry")
        XCTAssertTrue(controller.chrome.showsPill, "Always Visible shows the pill at once")
        XCTAssertTrue(trafficLightsShown(window), "and the lights with it")
        XCTAssertEqual(controller.chrome.pill.frame.minX, DwellChrome.pillInset, accuracy: 0.5)
        XCTAssertEqual(try lightFrame(window, .closeButton).midX,
                       DwellChrome.pillLightInset + ChromeBar.trafficLightButtonSide / 2, accuracy: 0.5)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 500, y: 300))
        pump(0.8)
        XCTAssertTrue(controller.chrome.showsPill, "there is no dwell to hide it")
        XCTAssertTrue(trafficLightsShown(window))
    }

    /// The first frame while the pill is up takes the pill away and returns the
    /// framed bar and its lights; the cover's visibility reconfigures the dwell.
    func testTheFirstFrameTakesTheCoverPillAway() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        controller.present()
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 620))
        pump(0.5)
        XCTAssertTrue(controller.chrome.showsPill, "the dwell pill is up over the cover")

        controller.noteFirstFrame()
        pump(0.25)
        XCTAssertTrue(controller.chrome.openingCover.isHidden, "the cover is over")
        XCTAssertEqual(controller.chrome.barHeight, ChromeBar.height)
        XCTAssertFalse(controller.chrome.showsPill)
        XCTAssertTrue(trafficLightsShown(window), "the framed bar keeps its lights")
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        XCTAssertEqual(try lightFrame(window, .closeButton).midY,
                       window.frame.height - ChromeBar.height / 2, accuracy: 0.5)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 620))
        pump(0.5)
        XCTAssertFalse(controller.chrome.showsPill, "the pill never comes back in a framed window")
    }

    /// A framed window that is already live has no dwell at all (unchanged by
    /// the cover's immersive behaviour).
    func testALiveFramedWindowNeverDwells() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        controller.present()
        controller.noteFirstFrame()
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        XCTAssertFalse(controller.videoView.hoverFeedActive())
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.5)
        XCTAssertFalse(controller.chrome.showsPill)
        XCTAssertFalse(controller.dwell.shown)
        XCTAssertTrue(trafficLightsShown(window), "the framed bar's lights stay up")
        XCTAssertEqual(try lightFrame(window, .closeButton).midY,
                       window.frame.height - ChromeBar.height / 2, accuracy: 0.5)
    }

    /// A touch that reaches the app through the cover's hot zone restarts the
    /// rest, exactly as it does in an immersive window.
    func testACoverTouchInTheHotZoneRestartsTheRest() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        _ = try XCTUnwrap(controller.window)
        controller.present()
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 620))
        pump(0.3)
        let bounds = controller.videoBounds()
        controller.touchInHotZone(TouchEvent(action: .down, nx: Float(20 / bounds.width),
                                             ny: Float(8 / bounds.height)))
        pump(0.1)
        XCTAssertFalse(controller.chrome.showsPill, "the touch reset the rest (300 ms is no rest)")
        pump(0.4)
        XCTAssertTrue(controller.chrome.showsPill, "350 ms of quiet after the touch shows the pill")
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
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
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
        let alreadyOn = manager.showTouches
        XCTAssertTrue(NSApp.sendAction(#selector(StreamWindowController.toggleShowTouches(_:)), to: controller, from: nil))
        XCTAssertEqual(manager.showTouches, !alreadyOn, "the menu item toggled the setting")
        XCTAssertEqual(state.showTouches, manager.showTouches, "and the menu state follows it")
    }
}

/// The bar's row against the lights: a control added to a phone window's bar
/// (Turn Off Phone Screen) widens the row, and the window's minimum width has
/// to follow it, or the first capsule sits over the traffic lights.
final class HeaderBarFitTests: XCTestCase {
    private var phoneActions: [HeaderAction] {
        [.back {}, .home {}, .recents {},
         HeaderAction(kind: .custom, customSymbol: "iphone", help: "Turn Off Phone Screen") {}]
    }

    func testThePhoneBarFitsBesideTheLightsAtItsMinimumWidth() throws {
        let actions = phoneActions
        let minWidth = HeaderBar.minimumWidth(for: actions)
        let lightsEnd = BarGeometry.lightInset + 2 * BarGeometry.lightSpacing + BarGeometry.lightSide
        let row = try XCTUnwrap(HeaderBar.row(actions, rightEdge: minWidth))
        XCTAssertGreaterThanOrEqual(row.actionsX, lightsEnd + HeaderBar.barGap - 0.5,
                                    "the first capsule clears the third light")
        XCTAssertEqual(minWidth - (row.liveTextX + HeaderBar.liveTextSide), BarGeometry.rightInset,
                       accuracy: 0.5, "the Live Text button still mirrors the lights' inset")
        // Two capsules (navigation + the phone control), the gap and Live Text.
        XCTAssertEqual(minWidth, 250, accuracy: 0.5)
    }

    /// The same row one point narrower than the minimum would overlap: the
    /// check above is not vacuous.
    func testOnePointNarrowerWouldOverlapTheLights() throws {
        let actions = phoneActions
        let row = try XCTUnwrap(HeaderBar.row(actions, rightEdge: HeaderBar.minimumWidth(for: actions) - 1))
        let lightsEnd = BarGeometry.lightInset + 2 * BarGeometry.lightSpacing + BarGeometry.lightSide
        XCTAssertLessThan(row.actionsX, lightsEnd + HeaderBar.barGap)
    }
}
