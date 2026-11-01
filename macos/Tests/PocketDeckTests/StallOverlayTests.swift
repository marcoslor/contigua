// WIN-39: the disconnection overlay. The picture's stall (WIN-17) and the
// link's two down steps (WIN-16) are one screen over the last frame — the app's
// icon, the title, "Waiting for <phone>…" — with the framed bar under the same
// acrylic. The machine is pure, so every edge is pinned with a fake clock; the
// window half proves the view is the presentation and that it covers the bar's
// mirror until a frame restores it.

import AppKit
import XCTest
@testable import PocketDeck

final class PictureStateTests: XCTestCase {
    private func handle(_ state: PictureState.State, _ event: PictureState.Event,
                        downSince: TimeInterval? = nil, now: TimeInterval = 100)
        -> (PictureState.State, TimeInterval?, [PictureState.Action]) {
        PictureState.transition(state, event, downSince: downSince, now: now)
    }

    func testASilentPictureStallsAndAFrameBringsItBack() {
        var picture = PictureState()
        XCTAssertEqual(picture.state, .live)
        XCTAssertEqual(picture.handle(.stall(true), at: 10), [.present(.stalled)])
        XCTAssertEqual(picture.state, .stalled)
        XCTAssertTrue(picture.isStalled)
        XCTAssertEqual(picture.handle(.stall(true), at: 11), nil, "the watchdog's repeat says nothing")
        XCTAssertEqual(picture.handle(.stall(false), at: 12), [.dismiss])
        XCTAssertEqual(picture.state, .live)
        XCTAssertEqual(picture.handle(.stall(false), at: 13), nil, "already live")
    }

    /// WIN-16: a blip says nothing for 1 s; the overlay then says
    /// "Reconnecting…", and "Phone offline" 15 s after the drop.
    func testTheLinkStepsAtOneAndFifteenSeconds() {
        var picture = PictureState()
        XCTAssertEqual(picture.handle(.linkDown, at: 100), [])
        XCTAssertEqual(picture.state, .linkBlip)
        XCTAssertTrue(picture.isLinkDown)
        XCTAssertNil(picture.overlay, "a blip shows nothing")
        XCTAssertNil(picture.handle(.tick(100.99), at: 100.99))
        XCTAssertEqual(picture.handle(.tick(101), at: 101), [.present(.reconnecting)])
        XCTAssertEqual(picture.state, .reconnecting)
        XCTAssertNil(picture.handle(.tick(114.99), at: 114.99))
        XCTAssertEqual(picture.handle(.tick(115), at: 115), [.present(.offline)])
        XCTAssertEqual(picture.state, .offline)
        XCTAssertEqual(picture.overlay, .offline)
        XCTAssertEqual(picture.handle(.linkUp, at: 116), [.dismiss])
        XCTAssertEqual(picture.state, .live)
        XCTAssertFalse(picture.isLinkDown)
    }

    /// A tick that arrives late must land on the right step, not restart it:
    /// 20 s of silence is "Phone offline", not a fresh "Reconnecting…".
    func testALateTickLandsOnTheRightStep() {
        var picture = PictureState()
        picture.handle(.linkDown, at: 100)
        XCTAssertEqual(picture.handle(.tick(120), at: 120), [.present(.offline)])
        XCTAssertEqual(picture.state, .offline)
    }

    /// A link down while the picture is stalled goes straight to the link's
    /// steps: the link is the reason now, and the stall is not shown again
    /// until the link is back.
    func testALinkDownOverAStallBecomesTheLinksSteps() {
        var picture = PictureState()
        picture.handle(.stall(true), at: 10)
        XCTAssertEqual(picture.handle(.linkDown, at: 11), [.dismiss])
        XCTAssertEqual(picture.state, .linkBlip)
        XCTAssertFalse(picture.isStalled)
    }

    /// A machine already in `state`, driven there by its own events.
    private func machine(_ state: PictureState.State) -> PictureState {
        var picture = PictureState()
        switch state {
        case .live:
            break
        case .stalled:
            picture.handle(.stall(true), at: 10)
        case .linkBlip:
            picture.handle(.linkDown, at: 100)
        case .reconnecting:
            picture.handle(.linkDown, at: 100)
            picture.handle(.tick(101), at: 101)
        case .offline:
            picture.handle(.linkDown, at: 100)
            picture.handle(.tick(115), at: 115)
        }
        return picture
    }

    func testTheEventsEachStateCannotTakeAreIgnored() {
        // Live: no link to restore, a repeat stall(false), and ticks.
        var picture = machine(.live)
        XCTAssertNil(picture.handle(.linkUp, at: 100))
        XCTAssertNil(picture.handle(.stall(false), at: 100))
        XCTAssertNil(picture.handle(.tick(100), at: 100))
        // Stalled: a link is the only other event; its own tick says nothing.
        picture = machine(.stalled)
        XCTAssertNil(picture.handle(.tick(100), at: 100))
        XCTAssertNil(picture.handle(.stall(true), at: 100))
        XCTAssertEqual(picture.state, .stalled)
        // Link down: the watchdog's silence is the link's business.
        picture = machine(.linkBlip)
        XCTAssertNil(picture.handle(.stall(true), at: 100.5))
        picture = machine(.reconnecting)
        XCTAssertNil(picture.handle(.stall(true), at: 102))
        picture = machine(.offline)
        XCTAssertNil(picture.handle(.stall(false), at: 120))
        // Offline: nothing but the link's return.
        XCTAssertNil(picture.handle(.tick(200), at: 200))
        // Link down again while already down: the clock does not restart.
        picture = machine(.reconnecting)
        XCTAssertNil(picture.handle(.linkDown, at: 105))
        XCTAssertEqual(picture.state, .reconnecting)
        XCTAssertEqual(picture.downSince, 100, "the drop's clock is the first drop's")
    }

    func testTheStatesNameThemselvesForTheLog() {
        XCTAssertEqual(PictureState.label(.live), "live")
        XCTAssertEqual(PictureState.label(.stalled), "stalled")
        XCTAssertEqual(PictureState.label(.linkBlip), "link-down")
        XCTAssertEqual(PictureState.label(.reconnecting), "reconnecting")
        XCTAssertEqual(PictureState.label(.offline), "offline")
    }
}

@MainActor
final class StallOverlayTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.stalloverlay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    /// A live app window with its picture in, as the person sees it.
    private func makeWindow(_ manager: WindowManager) throws -> AppWindowController {
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        // The test process has no WindowServer focus of its own: say visible.
        controller.occlusionVisibleOverride = true
        controller.noteFirstFrame()
        controller.chrome.layoutChrome()
        return controller
    }

    private func icon() -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
        image.unlockFocus()
        return image
    }

    /// The watchdog's own path: frames stop and the clock is driven by hand.
    private func stall(_ controller: StreamWindowController, at time: TimeInterval) {
        controller.frameClock.note(at: time)
        controller.tickFrameWatchdog(at: time)
        controller.tickFrameWatchdog(at: time + 2)
    }

    /// WIN-39: the stall is the overlay, with the app's icon and both lines.
    func testTheStallShowsTheOverlayWithTheIconTitleAndWaitingLine() throws {
        let manager = makeManager()
        manager.setPhoneName("Test Phone")
        let picture = icon()
        manager.setIcon(picture, pkg: "com.example.app")
        let controller = try makeWindow(manager)
        defer { controller.window?.close() }

        let t0 = ProcessInfo.processInfo.systemUptime
        stall(controller, at: t0)
        XCTAssertTrue(controller.isStalled)

        let overlay = controller.chrome.stallOverlay
        XCTAssertTrue(overlay.isShowing, "the stall presents the overlay")
        XCTAssertEqual(overlay.titleText, "Not responding")
        XCTAssertEqual(overlay.secondaryText, "Waiting for Test Phone…")
        XCTAssertTrue(overlay.hasIcon, "the overlay shows the app's icon")
        XCTAssertTrue(overlay.iconImage === picture, "the app's own icon, not a placeholder")

        // A frame: the overlay goes, for good until the next stall.
        controller.frameClock.note(at: t0 + 2.1)
        controller.tickFrameWatchdog(at: t0 + 2.1)
        XCTAssertFalse(controller.isStalled)
        XCTAssertFalse(overlay.isShowing, "a frame takes the overlay away")
    }

    /// WIN-16: the link's two down steps, through the window's own clock.
    func testTheLinkDownShowsReconnectingAfterOneSecondAndOfflineAfterFifteen() throws {
        let manager = makeManager()
        manager.setPhoneName("Test Phone")
        let controller = try makeWindow(manager)
        defer { controller.window?.close() }
        let overlay = controller.chrome.stallOverlay
        let t0 = ProcessInfo.processInfo.systemUptime

        controller.setLinkDown(true, at: t0)
        XCTAssertTrue(controller.phoneControlsOffline)
        XCTAssertFalse(overlay.isShowing, "a blip says nothing for the first second")
        controller.tickPicture(at: t0 + 0.9)
        XCTAssertFalse(overlay.isShowing)

        controller.tickPicture(at: t0 + 1)
        XCTAssertTrue(overlay.isShowing)
        XCTAssertEqual(overlay.titleText, "Reconnecting…")
        XCTAssertEqual(overlay.secondaryText, "Waiting for Test Phone…")

        controller.tickPicture(at: t0 + 15)
        XCTAssertEqual(overlay.titleText, "Phone offline")
        XCTAssertTrue(overlay.isShowing)

        controller.setLinkDown(false, at: t0 + 16)
        XCTAssertFalse(overlay.isShowing, "the reconnect takes the overlay away")
        XCTAssertFalse(controller.phoneControlsOffline)
        XCTAssertTrue(controller.expectsFrames)
    }

    /// WIN-39: the overlay reaches over the framed bar, so the bar's mirror is
    /// not the bright stream; a frame restores the live mirror.
    func testTheOverlayCoversTheBarAndAFrameRestoresIt() throws {
        let manager = makeManager()
        let controller = try makeWindow(manager)
        defer { controller.window?.close() }
        let chrome = controller.chrome
        XCTAssertEqual(chrome.barHeight, ChromeBar.height, "the baseline: a framed window with its bar")
        XCTAssertFalse(chrome.barMirrorCovered)

        let t0 = ProcessInfo.processInfo.systemUptime
        stall(controller, at: t0)
        XCTAssertTrue(chrome.barMirrorCovered, "the overlay covers the bar's mirror")
        XCTAssertEqual(chrome.stallOverlay.frame, chrome.bounds, "one sheet from the window's top edge")
        XCTAssertGreaterThan(chrome.stallOverlay.frame.height, chrome.video.frame.height,
                             "the overlay is taller than the stream: it includes the bar")

        controller.frameClock.note(at: t0 + 2.1)
        controller.tickFrameWatchdog(at: t0 + 2.1)
        XCTAssertFalse(chrome.barMirrorCovered, "a frame brings the bar's live mirror back")
        XCTAssertTrue(chrome.stallOverlay.isHidden)
    }

    /// WIN-39: no bar (immersive or full screen) means the overlay is the
    /// stream's own rect, and the words stay centred in it.
    func testTheOverlayWithoutABarIsTheStreamsRect() throws {
        let manager = makeManager()
        let controller = try makeWindow(manager)
        defer { controller.window?.close() }
        controller.chrome.setStyle(.immersive)
        controller.chrome.layoutChrome()
        XCTAssertEqual(controller.chrome.barHeight, 0)

        let t0 = ProcessInfo.processInfo.systemUptime
        stall(controller, at: t0)
        XCTAssertEqual(controller.chrome.stallOverlay.frame, controller.chrome.video.frame)
        XCTAssertEqual(controller.chrome.stallOverlay.topInset, 0)
        XCTAssertFalse(controller.chrome.barMirrorCovered)
    }

    /// WIN-39, light mode: the secondary line keeps WCAG AA against the
    /// acrylic's average colour behind it (the ground each style declares).
    func testTheSecondaryLineKeepsFourAndAHalfToOneInLightAndDark() {
        for style in [StallOverlayStyle.dark, StallOverlayStyle.light] {
            XCTAssertGreaterThanOrEqual(style.secondaryContrast, 4.5,
                                        "\(style.name): the secondary line's contrast")
            XCTAssertGreaterThanOrEqual(style.titleContrast, 4.5,
                                        "\(style.name): the title's contrast")
        }
        // The declared grounds are the ones measured from the shots; a ratio
        // computed against black or white would prove nothing.
        XCTAssertGreaterThan(StallOverlayStyle.light.ground.brightness, 0.3,
                             "the light ground is the light acrylic, not the dark one")
        XCTAssertLessThan(StallOverlayStyle.light.ground.brightness, 0.6,
                          "the light ground is the light acrylic, not white")
    }

    func testTheViewWearsTheAppearancesStyle() throws {
        let view = StallOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.appearance = NSAppearance(named: .aqua)
        view.applyAppearanceStyle()
        XCTAssertEqual(view.secondaryColor, StallOverlayStyle.light.secondary)
        view.appearance = NSAppearance(named: .darkAqua)
        view.applyAppearanceStyle()
        XCTAssertEqual(view.secondaryColor, StallOverlayStyle.dark.secondary)
    }

    /// WIN-39: the overlay takes every click that is not the bar's: no input
    /// reaches the phone while it is up.
    func testTheOverlaySwallowsTheStreamsClicks() throws {
        let manager = makeManager()
        let controller = try makeWindow(manager)
        defer { controller.window?.close() }
        let chrome = controller.chrome
        let t0 = ProcessInfo.processInfo.systemUptime
        stall(controller, at: t0)

        let point = NSPoint(x: chrome.bounds.midX, y: chrome.video.frame.midY)
        XCTAssertTrue(chrome.hitTest(point) === chrome.stallOverlay,
                      "a click on the frozen picture is the overlay's, not the stream's")
        // The bar's own band still drags the window, as the mirror does.
        let barPoint = NSPoint(x: chrome.bounds.midX, y: chrome.bounds.maxY - 4)
        XCTAssertTrue(chrome.hitTest(barPoint) === chrome,
                      "the bar's empty band is still the window's own drag")
    }
}

private extension NSColor {
    /// The colour's perceived brightness (0…1), so a test can tell the light
    /// acrylic from the dark one.
    var brightness: Double {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        return 0.2126 * Double(rgb.redComponent) + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
    }
}
