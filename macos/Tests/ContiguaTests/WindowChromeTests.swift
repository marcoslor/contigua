// The window chrome by style (WindowStyle.swift): Compact's mirrored band under
// AppKit's transparent title bar and its accessory, the phone window's actions, the Framed frame, and
// style switching — and that none of it changes the stream area the virtual
// display is sized from.

import AppKit
import XCTest
@testable import Contigua

/// AppKit's own frame for a 900×600 stream in a standard titled window: the
/// stream plus the system's title bar, whatever its height is on this macOS.
/// Compact's window is that size: its band is AppKit's title-bar height.
private var compactFrameSize: NSSize {
    NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable]).size
}

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
        let name = "app.contigua.tests.chrome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        // These tests exercise Compact: AppKit's own title bar over the stream.
        defaults.set(WindowStyle.compact.rawValue,
                     forKey: WindowStyleStore.key(forPackage: "com.example.app"))
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

    private func openCompact(_ manager: WindowManager) throws -> (AppWindowController, NSWindow) {
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.noteFirstFrame()
        controller.chrome.layoutChrome()
        return (controller, window)
    }

    /// WIN-4, WIN-7: Compact is the stream under a band as tall as AppKit's
    /// title bar. The content view spans the window under AppKit's transparent
    /// title bar; AppKit keeps its own lights there, and the band's title is
    /// ours, in the band's tone (WIN-69). The window is still the stream plus
    /// AppKit's title-bar height.
    func testCompactIsTheStreamUnderItsBandInAppKitsTransparentTitleBar() throws {
        let manager = makeManager()
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        let titleBar = compactFrameSize.height - 600
        XCTAssertEqual(controller.style, .compact)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView), "the band is under the title bar")
        XCTAssertTrue(window.titlebarAppearsTransparent, "the band shows through AppKit's title bar")
        XCTAssertEqual(window.titleVisibility, .hidden, "the band's title is ours, in its tone")
        XCTAssertEqual(window.title, "Example", "the window keeps its title: the Window menu, VoiceOver")
        XCTAssertGreaterThan(titleBar, 0)
        XCTAssertEqual(window.frame.size, compactFrameSize, "the stream plus AppKit's title-bar height")
        XCTAssertEqual(controller.chrome.bounds.size, compactFrameSize)
        XCTAssertEqual(controller.videoView.frame, NSRect(x: 0, y: 0, width: 900, height: 600),
                       "the stream sits under the band")
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.chrome.barHeight, titleBar)
        XCTAssertTrue(controller.chrome.lightsManagedByAppKit)
        XCTAssertTrue(trafficLightsShown(window))
        let atRest = (controller.videoView.frame, controller.displayPixels(), controller.dpi())

        controller.simulateFullScreenForTesting(true)
        XCTAssertTrue(controller.chrome.bandGlass.isHidden, "full screen is the bare system title bar (WIN-14)")
        controller.simulateFullScreenForTesting(false)
        pump(0.2)
        XCTAssertTrue(window.titlebarAppearsTransparent, "windowed again: the band's title bar")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.frame.size, compactFrameSize)
        XCTAssertEqual(controller.videoView.frame, atRest.0, "the stream does not move")
        XCTAssertEqual(controller.displayPixels(), atRest.1, "nor does the virtual display")
        XCTAssertEqual(controller.dpi(), atRest.2)
    }

    /// WIN-67: the band is the stream's own top edge, mirrored up by the
    /// system's NSBackgroundExtensionView, under clear glass. An opaque
    /// backing in the band's own colour sits under the mirror, so a mirror
    /// that draws nothing leaves a solid band, never the desktop (#45).
    func testCompactsBandIsTheSystemMirrorUnderClearGlassOverAnOpaqueBacking() throws {
        let manager = makeManager()
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        let chrome = controller.chrome
        let band = NSRect(x: 0, y: 600, width: 900, height: compactFrameSize.height - 600)
        let mirror = chrome.bandMirror
        XCTAssertTrue(controller.videoView.superview === mirror, "the mirror's content is the stream")
        XCTAssertFalse(mirror.automaticallyPlacesContentView)
        XCTAssertEqual(mirror.frame, chrome.bounds, "the mirror fills the band above the stream")
        XCTAssertFalse(chrome.bandGlass.isHidden)
        XCTAssertEqual(chrome.bandGlass.frame, band)
        XCTAssertEqual(chrome.bandGlass.style, .clear, "the blur stays, the grey scrim does not")
        XCTAssertEqual(chrome.bandGlass.cornerRadius, 0)
        XCTAssertFalse(chrome.bandBacking.isHidden)
        XCTAssertEqual(chrome.bandBacking.frame, band)
        XCTAssertLessThan(chrome.bandBacking.zPosition, mirror.layer?.zPosition ?? 0, "under the mirror")
        XCTAssertEqual(chrome.bandBacking.backgroundColor?.alpha, 1, "opaque: never see-through")
        XCTAssertEqual(chrome.layer?.cornerRadius ?? 0, 0, "the system's window shape rounds the frame")

        controller.setStyle(.framed)
        XCTAssertEqual(mirror.frame, chrome.contentRect, "Framed: the mirror is the picture, no band")
        XCTAssertTrue(chrome.bandGlass.isHidden)
        XCTAssertTrue(chrome.bandBacking.isHidden)
        controller.setStyle(.compact)
        XCTAssertFalse(chrome.bandGlass.isHidden)
    }

    /// WIN-69, #147: the band's mean decides the title's ink, with a margin
    /// so it does not flip on noise, and the glass takes the opposite tint:
    /// light ink over a dark band gets a dark tint, dark ink a light one. The
    /// backing is the band's own colour, opaque.
    func testTheBandsTitleInkAndTintFollowThePicture() throws {
        let manager = makeManager()
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        let chrome = controller.chrome
        chrome.setBarTitle("Example", phone: "Pixel")
        chrome.applyBandSample(BandSample(red: 0.05, green: 0.05, blue: 0.08))
        XCTAssertEqual(chrome.barTone, .light, "a dark band: light ink")
        XCTAssertTrue(chrome.barTitleVisible)
        let rect = try XCTUnwrap(chrome.barTitleRect)
        XCTAssertGreaterThanOrEqual(rect.minY, 600, "in the band")
        XCTAssertEqual(chrome.bandGlass.tintColor, BarTone.light.tint)
        XCTAssertEqual(chrome.bandBacking.backgroundColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB)?.redComponent ?? -1,
                       0.05, accuracy: 0.01, "the backing is the band's own colour")

        chrome.applyBandSample(BandSample(red: 0.95, green: 0.95, blue: 0.95))
        XCTAssertEqual(chrome.barTone, .dark, "a light band: dark ink")
        XCTAssertEqual(chrome.bandGlass.tintColor, BarTone.dark.tint)
        XCTAssertNotEqual(BarTone.light.tint, BarTone.dark.tint)
    }

    /// WIN-69: the band's controls are drawn for the band, not the window:
    /// over a light band in a dark window the capsules go light with dark
    /// glyphs, so a dark glyph never sits on a dark capsule (seen on a real
    /// display). Framed's controls sit on its material and follow the window.
    func testTheBandsControlsTakeTheBandsToneNotTheWindows() throws {
        let manager = makeManager()
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        let chrome = controller.chrome
        chrome.layoutChrome()
        chrome.applyBandSample(BandSample(red: 0.95, green: 0.95, blue: 0.95))
        XCTAssertEqual(chrome.barTone, .dark)
        XCTAssertEqual(chrome.barMaterial, HeaderBar.material(dark: false), "a light capsule over a light band")
        XCTAssertEqual(chrome.liveTextButton.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua,
                       "its glyph is drawn for the same light capsule")
        chrome.applyBandSample(BandSample(red: 0.04, green: 0.04, blue: 0.05))
        XCTAssertEqual(chrome.barMaterial, HeaderBar.material(dark: true), "a dark capsule over a dark band")
        controller.setStyle(.framed)
        XCTAssertEqual(chrome.barMaterial, HeaderBar.material(dark: true), "Framed follows the window")
        window.appearance = NSAppearance(named: .aqua)
        controller.setStyle(.compact)
        chrome.applyBandSample(BandSample(red: 0.04, green: 0.04, blue: 0.05))
        XCTAssertEqual(chrome.barMaterial, HeaderBar.material(dark: true), "a dark band in a light window")
    }

    /// WIN-7: the window kind's controls ride AppKit's trailing title-bar
    /// accessory in Compact, and come back into our chrome in the other styles.
    /// The e2e click route (`nav-click`, `panel-click`) resolves its point by
    /// the window's own hit test, title bar included: in Compact the buttons
    /// are in AppKit's title-bar accessory, outside the content view (MIRROR-13).
    func testTheDebugClickReachesCompactsTitleBarButtons() throws {
        let manager = makeManager()
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        let chrome = controller.chrome
        var fired: [String] = []
        chrome.setActions([.back { fired.append("back") }, .home { fired.append("home") },
                           .recents { fired.append("recents") }])
        chrome.layoutChrome()
        window.layoutIfNeeded()
        for kind in [HeaderActionKind.back, .home, .recents] {
            let centre = try XCTUnwrap(chrome.headerButtonCentre(kind), "\(kind) shows")
            DebugInputDriver.clickControl(at: centre, in: window)
        }
        XCTAssertEqual(fired, ["back", "home", "recents"], "each click runs its own button once")
    }

    func testCompactsControlsRideTheTitleBarAccessory() throws {
        let manager = makeManager()
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        let chrome = controller.chrome
        let accessory = chrome.titlebarControls
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains(accessory))
        XCTAssertEqual(accessory.layoutAttribute, .trailing)
        XCTAssertFalse(accessory.isHidden)
        XCTAssertTrue(chrome.liveTextButton.isDescendant(of: accessory.view),
                      "Live Text is in the title bar")
        XCTAssertFalse(chrome.liveTextButton.isHidden)
        let button = chrome.liveTextButton.convert(chrome.liveTextButton.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(button.minY, controller.chrome.contentRect.maxY - 0.5,
                                    "above the stream, in the title bar over the band")
        XCTAssertLessThanOrEqual(button.maxY, window.frame.height + 0.5)

        controller.setStyle(.framed)
        XCTAssertTrue(accessory.isHidden, "Framed draws its own row")
        XCTAssertTrue(chrome.liveTextButton.isDescendant(of: chrome))
        controller.setStyle(.compact)
        XCTAssertFalse(accessory.isHidden)
        XCTAssertTrue(chrome.liveTextButton.isDescendant(of: accessory.view))
        controller.simulateFullScreenForTesting(true)
        XCTAssertTrue(accessory.isHidden, "full screen is the bare system title bar (WIN-14)")
        controller.simulateFullScreenForTesting(false)
        XCTAssertFalse(accessory.isHidden)
    }

    /// The lights are AppKit's, where a window with a transparent title bar
    /// has them.
    func testTheTrafficLightsAreAppKitsOwnInItsTitleBar() throws {
        let manager = makeManager()
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        let plain = NSWindow(contentRect: NSRect(origin: .zero, size: compactFrameSize),
                             styleMask: WindowStyle.compact.styleMask, backing: .buffered, defer: false)
        plain.titlebarAppearsTransparent = true
        plain.titleVisibility = .hidden
        plain.isReleasedWhenClosed = false
        defer { plain.close() }
        plain.layoutIfNeeded()
        window.layoutIfNeeded()
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let ours = try XCTUnwrap(window.standardWindowButton(kind))
            let theirs = try XCTUnwrap(plain.standardWindowButton(kind))
            XCTAssertFalse(ours.isHidden)
            XCTAssertEqual(ours.convert(ours.bounds, to: nil), theirs.convert(theirs.bounds, to: nil),
                           "\(kind.rawValue) sits where AppKit puts it")
        }
    }

    func testAClickIsTheWindowsOwnAndNeverPassesThrough() throws {
        let manager = makeManager()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        manager.chromeStateFile = file
        let (controller, window) = try openCompact(manager)
        defer { window.close() }
        XCTAssertFalse(window.ignoresMouseEvents)
        controller.pointerMoved(toWindowPoint: NSPoint(x: 2, y: 20))
        let frame = "\(Int(window.frame.width.rounded()))x\(Int(window.frame.height.rounded()))"
        XCTAssertNotNil(controller.chrome.barTitleRect, "the band's title shows")
        let state = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(state.range(of: #" video=\d+,\d+,\d+,\d+\n$"#, options: .regularExpression),
                        "the picture rect is reported")
        XCTAssertEqual(withoutVideo(state), "style=compact lights=shown pill=hidden title_visible=no lights_managed=appkit fullscreen=no clicks=0 touches=\(manager.showTouches ? "on" : "off") dot_count=0 collection=0 collection_none=0 can_fullscreen=1 screen=on overlay=0 secure=0 panel_off=0 panel_pill=0 panel_pill_failed=0 panel_click_at=0 panel_glyph_at=0 panel_requests=0 stall=0 stall_overlay=0 stall_icon=0 stills=0 paused=0 expecting=0 opening=0 frame_age_ms=-1 drop_pill=hidden drop_refusal=none paste_pill=hidden paste_button=0 loading=0 cover_phase=0 cover_buttons=none cover_visible=1 bar_offline=0 bar_enabled=none bar_focus=none bar_title=1 bar_title_rect=X key=0 responder_video=1 frame=\(frame) video_gap=0\n")
    }

    func testCloseAndMinimiseWork() throws {
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
        // The window is still opening: the cover is one sheet over the content,
        // under AppKit's title bar (WIN-11).
        XCTAssertEqual(withoutVideo(state), "style=compact lights=shown pill=hidden title_visible=no lights_managed=appkit fullscreen=no clicks=0 touches=\(manager.showTouches ? "on" : "off") dot_count=0 collection=0 collection_none=0 can_fullscreen=1 screen=on overlay=0 secure=0 panel_off=0 panel_pill=0 panel_pill_failed=0 panel_click_at=0 panel_glyph_at=0 panel_requests=0 stall=0 stall_overlay=0 stall_icon=0 stills=0 paused=0 expecting=0 opening=1 frame_age_ms=-1 drop_pill=hidden drop_refusal=none paste_pill=hidden paste_button=0 loading=1 cover_phase=opening cover_buttons=none cover_visible=1 bar_offline=0 bar_enabled=none bar_focus=none bar_title=0 bar_title_rect=none key=0 responder_video=0 frame=\(frame) video_gap=0\n")
        controller.noteFirstFrame()
        let live = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(live.hasPrefix("style=compact lights=shown pill=hidden title_visible=no lights_managed=appkit"), live)
        XCTAssertTrue(live.contains("loading=0 cover_phase=0"), live)
        XCTAssertTrue(live.contains(" bar_title=1 "), "the band's own title, in its tone: \(live)")
        XCTAssertTrue(live.contains(" band:1"), live)
    }

    /// Full screen looks the same in every style (WIN-14): the stream fills
    /// the screen and the only chrome is the window's own native title bar,
    /// solid, with the system's title and lights; none of ours is on screen.
    /// Leaving restores the style's windowed chrome.
    func testFullScreenIsTheSystemTitleBarInEveryStyle() throws {
        for style in WindowStyle.allCases {
            let manager = makeManager()
            manager.styleStore.set(style, forKey: WindowStyleStore.key(forPackage: "com.example.app"))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-\(UUID().uuidString).txt")
            addTeardownBlock { try? FileManager.default.removeItem(at: file) }
            manager.chromeStateFile = file
            let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                                 label: "Example", manager: manager)
            defer { controller.window?.close() }
            let window = try XCTUnwrap(controller.window)
            window.orderFront(nil)
            controller.noteFirstFrame()
            XCTAssertEqual(controller.style, style)

            controller.simulateFullScreenForTesting(true)
            XCTAssertEqual(window.titleVisibility, .visible, "\(style): the system's title")
            XCTAssertFalse(window.titlebarAppearsTransparent, "\(style): a solid title bar")
            XCTAssertTrue(controller.chrome.lightsManagedByAppKit, "\(style)")
            XCTAssertEqual(controller.chrome.barHeight, 0, "\(style): no windowed bar over the stream")
            XCTAssertTrue(controller.chrome.framedTitleView.isHidden, "\(style): no frame")
            XCTAssertTrue(controller.chrome.pill.isHidden, "\(style): no pill")
            XCTAssertTrue(controller.chrome.liveTextButton.isHidden, "\(style): none of our controls")
            let state = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(state.contains(" pill=hidden title_visible=yes lights_managed=appkit fullscreen=yes"), state)
            XCTAssertTrue(state.contains(" bar_title=0 "), state)

            controller.simulateFullScreenForTesting(false)
            let windowed = ChromeConfig.forState(style: style, fullScreen: false)
            XCTAssertEqual(window.titleVisibility == .visible, windowed.titleVisible, "\(style)")
            XCTAssertEqual(window.titlebarAppearsTransparent, windowed.titlebarTransparent, "\(style)")
            XCTAssertEqual(controller.chrome.lightsManagedByAppKit, windowed.lightsManagedByAppKit, "\(style)")
            let back = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(back.contains(" fullscreen=no"), back)
        }
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

    func testTheTouchDotsRideTheChromesLayerAboveTheVideo() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.window?.orderFront(nil)
        XCTAssertTrue(controller.videoView.touchDotHost === controller.chrome.touchDotsLayer)
        XCTAssertFalse(controller.chrome.touchDotsLayer.superlayer === controller.videoView.layer,
                       "the dots are the chrome's, not the video's")
        XCTAssertGreaterThan(controller.chrome.touchDotsLayer.zPosition, 0,
                             "the dots composite above the stream")
        XCTAssertTrue(controller.chrome.touchDotsLayer.masksToBounds,
                      "a touch at the top edge is clipped to the picture")

        controller.videoView.showsTouches = true
        controller.videoView.showTouchPoints([.init(id: 0, nx: 0.5, ny: 0.95)])
        XCTAssertEqual(controller.chrome.touchDotsLayer.sublayers?.count, 1,
                       "the dot is drawn on the chrome's layer")
        XCTAssertEqual(controller.chrome.touchDotCount, 1)
        XCTAssertEqual(controller.videoView.layer?.sublayers?.contains { $0.zPosition == 20 } ?? true, false,
                       "and nothing is drawn on the video layer")
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
        let name = "app.contigua.tests.chrome.\(UUID().uuidString)"
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

    /// The default: Framed — the stream inside the 38/5 pt frame; the virtual
    /// display is the stream's own size.
    func testTheDefaultIsFramed() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.style, .framed, "no stored choice opens Framed")
        XCTAssertEqual(window.frame.size, NSSize(width: 910, height: 643))
        XCTAssertEqual(controller.chrome.contentRect, NSRect(x: 5, y: 5, width: 900, height: 600))
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.chrome.barHeight, FramedChrome.topInset)
        XCTAssertTrue(trafficLightsShown(window))
    }

    /// Compact: the stream under a band of AppKit's title-bar height, nothing
    /// at the sides or the bottom; the virtual display is the stream's own size.
    func testCompactIsTheStreamUnderItsBand() throws {
        let manager = makeManager(choose: .compact)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.style, .compact)
        XCTAssertEqual(window.frame.size, compactFrameSize)
        XCTAssertEqual(controller.videoView.frame, NSRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.chrome.barHeight, compactFrameSize.height - 600, "AppKit's title-bar height")
        XCTAssertTrue(trafficLightsShown(window))
    }

    /// Immersive: the old pill style — the window is exactly the 900×600 stream,
    /// nothing of it shows at rest, and a rest in the hot zone brings the pill
    /// and the lights in.
    func testImmersiveIsTheStreamAloneWithTheDwellPill() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(controller.style, .immersive)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 600), "the window is the stream alone")
        XCTAssertEqual(controller.videoView.frame.size, window.frame.size)
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.chrome.barHeight, 0, "no bar")
        XCTAssertFalse(controller.chrome.showsPill)
        XCTAssertFalse(trafficLightsShown(window), "no chrome at rest")

        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.45)
        XCTAssertTrue(controller.dwell.shown)
        XCTAssertTrue(controller.chrome.showsPill)
        XCTAssertTrue(trafficLightsShown(window), "the pill carries the lights")
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frame = close.convert(close.bounds, to: nil)
        XCTAssertEqual(frame.midX, DwellChrome.pillLightInset + ChromeBar.trafficLightButtonSide / 2,
                       accuracy: 0.5, "the lights sit on the pill's row")
        XCTAssertEqual(window.frame.height - frame.midY,
                       DwellChrome.pillInset + DwellChrome.pillHeight / 2, accuracy: 0.5)
    }

    /// The pill holds its row with the bar's own spacing: the lights 7 pt in,
    /// the first capsule 8 pt after the zoom light, 6 pt between capsules and
    /// the Live Text capsule 7 pt from the pill's right end — never outside
    /// it. Before: 20 pt after the lights and Live Text 4 pt past the edge of
    /// an app window's pill; 14 pt and 2 pt on the Phone Mirror's.
    func testThePillHoldsItsRowWithTheBarsSpacing() throws {
        let manager = makeManager(choose: .immersive)
        manager.styleStore.set(.immersive, forKey: WindowStyleStore.phoneKey)
        let app = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                      label: "Example", manager: manager)
        let phone = PhoneWindowController(stream: 2, phone: nil, manager: manager)
        for controller in [app, phone] as [StreamWindowController] {
            defer { controller.window?.close() }
            controller.present()
            controller.noteFirstFrame()
            let window = try XCTUnwrap(controller.window)
            let height = try XCTUnwrap(window.contentView).bounds.height
            controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: height - 20))
            pump(0.45)
            XCTAssertTrue(controller.chrome.showsPill)
            let pill = controller.chrome.pill.frame
            let kind = controller === app ? "app" : "phone"
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            let closeFrame = controller.chrome.convert(close.bounds, from: close)
            let zoomFrame = controller.chrome.convert(zoom.bounds, from: zoom)
            XCTAssertEqual(closeFrame.minX - pill.minX, BarGeometry.lightInset, accuracy: 0.5, "\(kind) lights")
            let live = controller.chrome.liveTextFrameForTesting
            let first = controller.chrome.actionsFrameForTesting ?? live
            XCTAssertEqual(first.minX - zoomFrame.maxX, HeaderBar.barGap, accuracy: 0.5,
                           "\(kind) first capsule after the lights")
            if let row = controller.chrome.actionsFrameForTesting {
                XCTAssertEqual(live.minX - row.maxX, HeaderBar.capsuleGap, accuracy: 0.5, "\(kind) capsule gap")
            }
            XCTAssertEqual(pill.maxX - live.maxX, HeaderBar.rightInset, accuracy: 0.5,
                           "\(kind) Live Text inside the pill's right end")
            XCTAssertTrue(pill.contains(live), "\(kind) Live Text inside the pill")
        }
    }

    /// Framed: 5 pt on three sides and 38 pt above, a frame drawn in the
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
        XCTAssertEqual(window.frame.size, NSSize(width: 910, height: 643))
        XCTAssertEqual(controller.chrome.contentRect, controller.chrome.streamContentRect,
                       "the video is the stream's rect inside the frame")
        XCTAssertEqual(controller.chrome.streamContentRect,
                       NSRect(x: FramedChrome.sideInset, y: FramedChrome.bottomInset,
                              width: 900, height: 600))
        XCTAssertEqual(controller.videoBounds(), CGSize(width: 900, height: 600))
        XCTAssertEqual(controller.chrome.barHeight, FramedChrome.topInset)
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

    /// WIN-68: a name that fits is drawn whole in Framed too. The field must
    /// clip (not reserve a middle ellipsis) when its frame is at least the
    /// text's width; a 910 pt window has room for "Settings".
    func testTheFramedTitleDrawsAWholeNameWhenItFits() throws {
        let manager = makeManager(choose: .framed)
        let controller = AppWindowController(stream: 1, pkg: "com.android.settings", activity: nil,
                                             label: "Settings", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let title = controller.chrome.framedTitleView
        XCTAssertEqual(title.titleText, "Settings")
        XCTAssertEqual(title.titleLineBreakMode, .byClipping,
                       "a name that fits must not reserve the middle ellipsis")
        XCTAssertGreaterThanOrEqual(title.titleFrame.width, BarTitle.textWidth("Settings"),
                                    "the field is at least the whole line's width")
    }

    func testTheBarTitleCarriesThePhoneName() throws {
        let manager = makeManager()
        manager.setPhoneName("Pixel 9")
        let controller = AppWindowController(stream: 1, pkg: "com.android.settings", activity: nil,
                                             label: "Settings", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        XCTAssertEqual(controller.chrome.framedTitleView.titleText, "Settings (Pixel 9)")
        XCTAssertEqual(controller.window?.title, "Settings (Pixel 9)",
                       "the window's own title already carried the phone")
        controller.setStyle(.compact)
        XCTAssertEqual(controller.window?.title, "Settings (Pixel 9)",
                       "Compact keeps the window's own title for the Window menu and VoiceOver")
        XCTAssertEqual(controller.window?.titleVisibility, .hidden)
        XCTAssertTrue(controller.chrome.barTitleVisible, "the band draws it, in the band's tone")
        controller.setStyle(.immersive)
        XCTAssertFalse(controller.chrome.barTitleVisible, "Immersive has no bar")
        XCTAssertNil(controller.chrome.barTitleRect)
    }

    func testThePillHidesAfterThePointerLeaves() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.45)
        XCTAssertTrue(controller.chrome.showsPill)

        controller.pointerMoved(toWindowPoint: NSPoint(x: 400, y: 300))
        // The hide starts 600 ms after leaving; the pill parks once its
        // 0.15 s fade has run.
        pump(DwellChrome.hideDelay + DwellChrome.pillFade + 0.15)
        XCTAssertFalse(controller.chrome.showsPill, "600 ms after leaving both the pill and the zone")
        XCTAssertFalse(trafficLightsShown(controller.window))
        XCTAssertTrue(controller.chrome.pill.isHidden)
    }

    /// WIN-74: the pill is one unit. Its glass, its capsules, the Live Text
    /// button and the three lights fade in together and out together over
    /// `pillFade`, and a layout pass in the middle of the fade hides none of
    /// them early. Before: the lights and Live Text took alpha 1 at once on
    /// the way in, and a layout during the fade-out hid them at once.
    func testThePillFadesInAndOutAsOneUnit() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        let chrome = controller.chrome
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        XCTAssertEqual(lights.count, 3)
        let members: [(String, NSView)] = [("glass", chrome.pill), ("Live Text", chrome.liveTextButton)]
            + lights.enumerated().map { ("light \($0.offset)", $0.element as NSView) }
        func fade(_ view: NSView) -> CABasicAnimation? {
            view.layer?.animation(forKey: "opacity") as? CABasicAnimation
        }
        chrome.reduceMotion = { false }

        chrome.setPill(true)
        chrome.layoutChrome()
        for (name, view) in members {
            XCTAssertFalse(view.isHidden, "\(name) shows with the pill")
            let animation = fade(view)
            XCTAssertNotNil(animation, "\(name) fades in with the pill, never pops in")
            XCTAssertEqual(animation?.duration ?? 0, DwellChrome.pillFade, accuracy: 0.001, name)
        }
        pump(DwellChrome.pillFade + 0.1)

        chrome.setPill(false)
        chrome.layoutChrome()
        for (name, view) in members {
            XCTAssertFalse(view.isHidden, "\(name) stays up while the pill fades out")
            let animation = fade(view)
            XCTAssertNotNil(animation, "\(name) fades out with the pill, never vanishes on its own")
            XCTAssertEqual(animation?.duration ?? 0, DwellChrome.pillFade, accuracy: 0.001, name)
        }
        pump(DwellChrome.pillFade + 0.15)
        for (name, view) in members {
            XCTAssertTrue(view.isHidden || view.alphaValue < 0.01, "\(name) is gone once the fade has run")
        }
    }

    /// Reduce Motion: the pill and its members show and go at once, together,
    /// with no fade (WIN-74, CONV-MAC-22).
    func testThePillDoesNotFadeUnderReduceMotion() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        let window = try XCTUnwrap(controller.window)
        let chrome = controller.chrome
        chrome.reduceMotion = { true }
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        let members: [(String, NSView)] = [("glass", chrome.pill), ("Live Text", chrome.liveTextButton)]
            + lights.enumerated().map { ("light \($0.offset)", $0.element as NSView) }

        chrome.setPill(true)
        chrome.layoutChrome()
        for (name, view) in members {
            XCTAssertFalse(view.isHidden, "\(name) shows with the pill")
            XCTAssertNil(view.layer?.animation(forKey: "opacity"), "\(name) does not fade in")
            XCTAssertEqual(view.alphaValue, 1, "\(name) is up at once")
        }

        chrome.setPill(false)
        chrome.layoutChrome()
        for (name, view) in members {
            XCTAssertNil(view.layer?.animation(forKey: "opacity"), "\(name) does not fade out")
            XCTAssertTrue(view.isHidden || view.alphaValue < 0.01, "\(name) is gone at once")
        }
    }

    /// The pill's fade is snappy: 0.15 s in and out (WIN-74).
    func testThePillFadeIsSnappy() {
        XCTAssertEqual(DwellChrome.pillFade, 0.15)
    }

    func testATouchInTheZoneRestartsTheRest() throws {
        let manager = makeManager(choose: .immersive)
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        controller.present()
        controller.noteFirstFrame()
        controller.pointerMoved(toWindowPoint: NSPoint(x: 20, y: 580))
        pump(0.3)
        // The finger lands in the hot zone before the dwell is up: the touch is
        // the app's and the rest starts again from it.
        controller.touchInHotZone(TouchEvent(action: .down, nx: 0.02, ny: 0.02))
        pump(0.2)
        XCTAssertFalse(controller.chrome.showsPill, "the rest is younger than the dwell")
        pump(0.3)
        XCTAssertTrue(controller.chrome.showsPill, "350 ms of quiet after the tap is a rest")
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
        // The stream's top edge at the screen's top: a taller frame has nowhere
        // to go, so the window moves down by exactly what it overflows.
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 200, y: visible.maxY))
        XCTAssertEqual(window.frame.maxY, visible.maxY)
        XCTAssertEqual(controller.style, .framed)
        XCTAssertEqual(window.frame.size, NSSize(width: 910, height: 643))
        // The menu follows the key window: the style switches below are the
        // ones a person makes while this window has the keyboard.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))

        controller.setStyle(.compact)
        XCTAssertEqual(window.frame.size, compactFrameSize, "the window sheds the frame's sides")
        XCTAssertEqual(window.frame.minX, visible.minX + 205, accuracy: 1,
                       "the stream keeps its place: 5 pt of frame came off the left")
        let titleBar = compactFrameSize.height - 600
        XCTAssertEqual(window.frame.maxY, visible.maxY - 38 + titleBar, accuracy: 1,
                       "the stream's top edge stays: the frame's 38 pt bar became the band")
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .compact, "the choice is remembered for the package")
        XCTAssertEqual(StreamMenuState.shared.style, .compact)
        XCTAssertTrue(trafficLightsShown(window), "Compact shows the lights")
        XCTAssertTrue(window.titlebarAppearsTransparent, "Compact's band shows through the title bar")

        controller.setStyle(.immersive)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 600), "the window is the stream alone")
        XCTAssertEqual(window.frame.maxY, visible.maxY - 38, accuracy: 1, "the title bar is gone from above")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .immersive)
        XCTAssertFalse(controller.chrome.barHeight > 0)
        XCTAssertFalse(controller.chrome.showsPill, "the pill waits for a rest")

        controller.setStyle(.framed)
        XCTAssertEqual(window.frame.size, NSSize(width: 910, height: 643), "the frame comes back")
        XCTAssertEqual(window.frame.maxY, visible.maxY, accuracy: 1,
                       "it moves down just enough to fit under the screen's top edge")
        XCTAssertEqual(manager.styleStore.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .framed)
    }

    func testToggleCyclesTheThreeStylesAndTheirSizes() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        XCTAssertEqual(window.frame.height, 643)
        XCTAssertEqual(controller.style, .framed)
        controller.toggleStyle()
        XCTAssertEqual(window.frame.size, compactFrameSize)
        XCTAssertEqual(controller.style, .compact)
        controller.toggleStyle()
        XCTAssertEqual(window.frame.height, 600)
        XCTAssertEqual(controller.style, .immersive)
        controller.toggleStyle()
        XCTAssertEqual(window.frame.height, 643, "the cycle comes back to Framed")
        XCTAssertEqual(controller.style, .framed)
    }

    func testAnUnknownStoredStyleOpensFramed() throws {
        let name = "app.contigua.tests.chrome.\(UUID().uuidString)"
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
        XCTAssertEqual(controller.style, .framed, "the old \"framed\" string is unknown and ignored")
        XCTAssertEqual(controller.window?.frame.size, NSSize(width: 910, height: 643))
    }

    /// View ▸ Hide Controls stacks with the window's style: the pick stores the
    /// Immersive pill's dwell delay and leaves the style untouched.
    func testHideControlsNeverChangesTheStyle() throws {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        XCTAssertEqual(controller.style, .framed)
        manager.pickHideControls(.alwaysVisible)
        XCTAssertEqual(manager.revealDelay, .alwaysVisible)
        XCTAssertEqual(controller.style, .framed, "the pick is not a style switch")
        manager.pickHideControls(.delay(.long))
        XCTAssertEqual(manager.revealDelay, .long)
        XCTAssertEqual(controller.style, .framed)
    }
}

final class StreamMenuTests: XCTestCase {
    private var manager: WindowManager?

    func testTheViewMenuFollowsTheKeyStreamWindow() {
        let name = "app.contigua.tests.menu.\(UUID().uuidString)"
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
        let name = "app.contigua.tests.menu.\(UUID().uuidString)"
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
        XCTAssertEqual(state.style, .framed, "the default is Framed")
        behind.setStyle(.compact)
        XCTAssertEqual(state.style, .framed, "a window behind the key one cannot change the menu")
        XCTAssertEqual(behind.style, .compact, "its own style still changed")
        key.setStyle(.immersive)
        XCTAssertEqual(state.style, .immersive)
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
