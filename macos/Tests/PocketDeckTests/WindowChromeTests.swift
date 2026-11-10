// The window chrome by style (WindowStyle.swift): the framed bar's frame, the
// lights on its line, the phone window's actions, the Framed frame, and
// style switching — and that none of it changes the stream area the virtual
// display is sized from.

import AppKit
import XCTest
@testable import PocketDeck

final class LetterboxTests: XCTestCase {
    func testAnOlderPhonesSixteenPixelStepCoversTheWindowWithNoBand() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        // 900 x 600 pt at 2x is 1800 x 1200 px; an older phone answers
        // 1792 x 1200 (16 px aligned). A 4 pt band beside the picture is what
        // the person reported as a black bar: the frame covers the view.
        let rect = Letterbox.videoRect(video: CGSize(width: 1792, height: 1200), in: bounds,
                                       backingScale: 2, alignment: 16)
        XCTAssertEqual(rect, bounds)
        // A frame of a different shape (mid-resize) is still fitted, not stretched.
        let tall = Letterbox.videoRect(video: CGSize(width: 1080, height: 2400), in: bounds)
        XCTAssertEqual(tall.height, 600)
        XCTAssertEqual(tall.width, 270)
    }
}

final class StreamChromeWindowTests: XCTestCase {
    /// The state line without its `video=` rect, which the picture's band check
    /// reads on its own (the rest of the line is compared exactly).
    private func withoutVideo(_ line: String) -> String {
        line.replacingOccurrences(of: #" video=\d+,\d+,\d+,\d+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" bar_title_rect=[\d,]+"#, with: " bar_title_rect=X",
                                  options: .regularExpression)
            .replacingOccurrences(of: #" geom=\S+.*? video_gap="#, with: " video_gap=",
                                  options: .regularExpression)
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
        XCTAssertEqual(chrome.style, .immersive)
        XCTAssertFalse(chrome.isOpaque)
        XCTAssertEqual(controller.chrome.actionCount, 0, "app windows have no actions")
        // The bar is the extension view's own blurred replica: no material or
        // other fill sits over it, so nothing can tint the stream.
        XCTAssertTrue(chrome.subviews.contains { $0 is NSBackgroundExtensionView })
        XCTAssertTrue(chrome.subviews.compactMap { $0 as? NSVisualEffectView }.allSatisfy(\.isHidden),
                      "no material layer over the bar: the full-screen acrylic stays hidden")
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
        let frame = "\(Int(window.frame.width.rounded()))x\(Int(window.frame.height.rounded()))"
        let state = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(state.range(of: #" video=\d+,\d+,\d+,\d+\n$"#, options: .regularExpression),
                        "the picture rect is reported")
        XCTAssertEqual(withoutVideo(state), "style=immersive lights=shown fullbar=hidden fullbar_visible=0 title_visible=no lights_managed=us fullscreen=no clicks=0 dots=outside touches=\(manager.showTouches ? "on" : "off") dot_count=0 collection=0 collection_none=0 can_fullscreen=1 screen=on overlay=0 secure=0 panel_off=0 panel_pill=0 panel_pill_failed=0 panel_click_at=0 panel_glyph_at=0 panel_requests=0 stall=0 stall_overlay=0 stall_icon=0 stills=0 paused=0 expecting=0 opening=0 frame_age_ms=-1 drop_pill=hidden drop_refusal=none paste_pill=hidden paste_button=0 loading=0 cover_phase=0 cover_buttons=none bar_offline=0 bar_enabled=none bar_focus=none bar_blur_radius=0 bar_tint=0.14 tint=1 bar_title=1 bar_title_tone=none bar_title_rect=X haze=1 key=0 responder_video=1 frame=\(frame) video_gap=0\n")
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
        XCTAssertEqual(withoutVideo(state), "style=immersive lights=shown fullbar=hidden fullbar_visible=0 title_visible=no lights_managed=us fullscreen=no clicks=0 dots=outside touches=\(manager.showTouches ? "on" : "off") dot_count=0 collection=0 collection_none=0 can_fullscreen=1 screen=on overlay=0 secure=0 panel_off=0 panel_pill=0 panel_pill_failed=0 panel_click_at=0 panel_glyph_at=0 panel_requests=0 stall=0 stall_overlay=0 stall_icon=0 stills=0 paused=0 expecting=0 opening=1 frame_age_ms=-1 drop_pill=hidden drop_refusal=none paste_pill=hidden paste_button=0 loading=1 cover_phase=opening cover_buttons=none bar_offline=0 bar_enabled=none bar_focus=none bar_blur_radius=0 bar_tint=0.14 tint=0 bar_title=0 bar_title_tone=none bar_title_rect=none haze=0 key=0 responder_video=0 frame=\(frame) video_gap=0\n")
        controller.noteFirstFrame()
        let live = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(live.hasPrefix("style=immersive lights=shown fullbar=hidden fullbar_visible=0"), live)
        XCTAssertTrue(live.contains("loading=0 cover_phase=0"), live)
        XCTAssertTrue(live.contains("bar_blur_radius=0 bar_tint=0.14 tint=1 bar_title=1"), live)
        XCTAssertTrue(live.contains("haze=1"), live)
    }

    /// Full screen hands the screen to the stream in either style and starts
    /// with the acrylic bar hidden (WIN-8, WIN-14); leaving brings the stored
    /// style's windowed chrome and its lights back.
    func testFullScreenHidesTheAcrylicBarAndExitRestoresTheStyleChrome() throws {
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

        controller.simulateFullScreenForTesting(true)
        XCTAssertEqual(window.titleVisibility, .hidden, "our bar carries the title, not the system's")
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(controller.chrome.barHeight, 0, "no windowed bar over the stream")
        XCTAssertFalse(controller.chrome.fullBarVisible, "the acrylic bar starts hidden")
        XCTAssertFalse(trafficLightsShown(window), "its lights are out of sight with it")
        let state = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(state.hasPrefix("style=immersive lights=hidden fullbar=hidden fullbar_visible=0"),
                      state)

        controller.simulateFullScreenForTesting(false)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(trafficLightsShown(window), "the Immersive bar takes the lights back")
        XCTAssertEqual(controller.chrome.barHeight, ChromeBar.height)
        let back = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(back.hasPrefix("style=immersive lights=shown fullbar=hidden fullbar_visible=0"),
                      back)
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

final class StreamChromeStyleTests: XCTestCase {
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

    /// The default: the stream plus the 28 pt mirrored bar, nothing at the
    /// sides or the bottom; the virtual display is the stream's own size.
    func testImmersiveIsTheStreamPlusTheBar() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.style, .immersive, "no stored choice opens Immersive")
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 628))
        XCTAssertEqual(controller.videoView.frame, NSRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.chrome.barHeight, ChromeBar.height)
        XCTAssertTrue(trafficLightsShown(window))
        XCTAssertTrue(controller.chrome.hazeVisible)
    }

    /// Framed: 5.5 pt on three sides and 38.5 pt above, a frame drawn in the
    /// chrome, the stream still 900×600 and the display priced on it.
    func testFramedIsTheStreamInsideTheFrame() throws {
        let manager = makeManager(choose: .framed)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.style, .framed)
        XCTAssertEqual(window.frame.size, NSSize(width: 911, height: 644))
        XCTAssertEqual(controller.videoView.frame, NSRect(x: 0, y: 0, width: 900, height: 600),
                       "the video is laid out inside the Frame's content, not in window coordinates")
        XCTAssertEqual(controller.chrome.streamContentRect,
                       NSRect(x: FramedChrome.sideInset, y: FramedChrome.bottomInset,
                              width: 900, height: 600))
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.chrome.barHeight, FramedChrome.topInset)
        XCTAssertFalse(controller.chrome.hazeVisible, "Framed has no mirror or haze")
        XCTAssertEqual(controller.chrome.layer?.cornerRadius, FramedChrome.outerRadius)
        XCTAssertEqual(controller.videoView.layer?.cornerRadius, FramedChrome.contentRadius)
        XCTAssertEqual(controller.chrome.framedTitleView.materialKind, .underWindowBackground)
        XCTAssertEqual(controller.chrome.framedTitleView.titleText, "Example")
        XCTAssertEqual(controller.chrome.framedTitleView.titlePointSize, 13)
        XCTAssertEqual(controller.chrome.framedTitleView.titleTextColor, .labelColor)
        XCTAssertEqual(controller.chrome.framedTitleView.hairlineWidth, FramedChrome.hairline)
        XCTAssertEqual(controller.chrome.framedTitleView.rimWidth, FramedChrome.rim)
        XCTAssertEqual(controller.chrome.framedTitleView.highlightFrame.height, FramedChrome.highlightHeight)
    }

    func testSwitchingStylesKeepsTheStreamAndIsRemembered() throws {
        let manager = makeManager()
        addTeardownBlock { StreamMenuState.shared.handle(.reset) }
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        let window = try XCTUnwrap(controller.window)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.orderFront(nil)
        controller.noteFirstFrame()
        // The stream's top edge at the screen's top: the bar has nowhere to go,
        // so the window moves down by exactly what the frame overflows.
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 200, y: visible.maxY))
        XCTAssertEqual(window.frame.maxY, visible.maxY)
        // The menu follows the key window: the style switch below is the one a
        // person makes while this window has the keyboard.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        controller.setStyle(.framed)
        XCTAssertEqual(window.frame.size, NSSize(width: 911, height: 644), "the window gains the frame")
        XCTAssertEqual(window.frame.minX, visible.minX + 194.5, accuracy: 1,
                       "AppKit rounds a window frame's fractional origin")
        XCTAssertEqual(window.frame.maxY, visible.maxY, "the frame fits under the screen's top edge")
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .framed, "the choice is remembered for the package")
        XCTAssertEqual(StreamMenuState.shared.style, .framed)
        XCTAssertTrue(trafficLightsShown(window), "Framed shows the lights")

        controller.setStyle(.immersive)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 628), "the bar comes back")
        XCTAssertEqual(window.frame.maxY,
                       visible.maxY - (FramedChrome.topInset - ChromeBar.height), accuracy: 1,
                       "the stream keeps its place: the window sheds 16 pt, 10.5 from above")
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .immersive)
        XCTAssertTrue(controller.chrome.hazeVisible, "the mirror's haze is back")
    }

    func testToggleFlipsTheStyleAndTheWindowSizeByTheFrame() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        XCTAssertEqual(window.frame.height, 628)
        controller.toggleStyle()
        XCTAssertEqual(window.frame.height, 644)
        XCTAssertEqual(controller.style, .framed)
        controller.toggleStyle()
        XCTAssertEqual(window.frame.height, 628)
        XCTAssertEqual(controller.style, .immersive)
    }

    func testAnUnknownStoredStyleOpensImmersive() throws {
        let name = "dev.pocketdeck.tests.chrome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        defaults.set("framed", forKey: WindowStyleStore.key(forPackage: "com.example.app"))
        let pins = PhonePinStoreV2()
        let manager = WindowManager(session: Session(endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                                     knownDeviceId: nil, clientId: "test-client",
                                                     pinStore: pins),
                                    defaults: defaults)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        XCTAssertEqual(controller.style, .immersive, "the old \"framed\" string is unknown and ignored")
        XCTAssertEqual(controller.window?.frame.size, NSSize(width: 900, height: 628))
    }

    /// Entering full screen parks the acrylic bar out of sight (WIN-8) and
    /// leaving it restores the stored style's windowed chrome. The real Space
    /// switch is the VM run's; the machine and the chrome transitions are here.
    func testFullScreenEntersHiddenAndExitRestoresTheWindowedChrome() throws {
        let manager = makeManager()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        manager.chromeStateFile = file
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.simulateFullScreenForTesting(true)
        XCTAssertEqual(controller.fullBar.mode, .hidden, "the bar starts hidden on entry")
        XCTAssertFalse(controller.chrome.fullBarVisible)
        XCTAssertEqual(controller.chrome.barHeight, 0, "no windowed bar in full screen")
        let state = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(state.contains("fullbar=hidden fullbar_visible=0"), state)
        XCTAssertTrue(state.contains("fullscreen=yes"), state)

        controller.simulateFullScreenForTesting(false)
        XCTAssertEqual(controller.fullBar.mode, .hidden)
        XCTAssertEqual(controller.chrome.barHeight, ChromeBar.height, "the Immersive bar is back")
        XCTAssertTrue(controller.chrome.hazeVisible)
        XCTAssertTrue(trafficLightsShown(window))
    }

    /// View ▸ Hide Controls stacks with the window's style: the pick stores the
    /// full-screen reveal and leaves the style untouched.
    func testHideControlsNeverChangesTheStyle() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        XCTAssertEqual(controller.style, .immersive)
        manager.pickHideControls(.alwaysVisible)
        XCTAssertEqual(manager.revealDelay, .alwaysVisible)
        XCTAssertEqual(controller.style, .immersive, "the pick is not a style switch")
        manager.pickHideControls(.delay(.long))
        XCTAssertEqual(manager.revealDelay, .long)
        XCTAssertEqual(controller.style, .immersive)
    }
}

final class StreamMenuTests: XCTestCase {
    private var manager: WindowManager?

    func testTheViewMenuFollowsTheKeyStreamWindow() {
        let name = "dev.pocketdeck.tests.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
            StreamMenuState.shared.handle(.reset)
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

    /// ISS-88: only the key stream window publishes its values. A style change
    /// in a second window behind the Deck cannot reach the menu, and the key
    /// window's own change can.
    func testAWindowBehindTheKeyWindowCannotChangeTheMenu() {
        let name = "dev.pocketdeck.tests.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
            StreamMenuState.shared.handle(.reset)
        }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        let manager = WindowManager(session: session, defaults: defaults)
        self.manager = manager
        let key = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil, label: "Example",
                                      manager: manager)
        let behind = AppWindowController(stream: 2, pkg: "com.example.other", activity: nil, label: "Other",
                                         manager: manager)
        defer {
            key.window?.close()
            behind.window?.close()
        }
        let state = StreamMenuState.shared
        key.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertEqual(state.style, .immersive, "the default is Immersive")
        behind.setStyle(.framed)
        XCTAssertEqual(state.style, .immersive, "a window behind the key one cannot change the menu")
        XCTAssertEqual(behind.style, .framed, "its own style still changed")
        key.setStyle(.framed)
        XCTAssertEqual(state.style, .framed)
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
