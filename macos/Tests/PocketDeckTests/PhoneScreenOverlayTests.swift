import AppKit
import XCTest
@testable import PocketDeck

/// The phone window's sleeping-panel state (docs/design/phone-mirror.md): the
/// overlay model, wake-on-open, wake from a click, and no input while frozen.
final class PhoneScreenOverlayTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name = "dev.pocketdeck.tests.phonescreen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeManager() -> WindowManager {
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: makeDefaults())
    }

    private func click() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func keyEvent() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
                         keyCode: 0)!
    }

    // MARK: Model

    func testNoScreenReadsAsLive() {
        let overlay = PhoneScreenOverlay()
        XCTAssertFalse(overlay.isShowing)
        XCTAssertNil(overlay.screen)
    }

    func testScreenOffShowsTheCoverAndOnClearsIt() {
        var overlay = PhoneScreenOverlay(screen: .on)
        XCTAssertFalse(overlay.isShowing)
        XCTAssertTrue(overlay.set(screen: .off))
        XCTAssertTrue(overlay.isShowing)
        XCTAssertFalse(overlay.set(screen: .off), "a repeated off is not a change")
        XCTAssertTrue(overlay.set(screen: .on))
        XCTAssertFalse(overlay.isShowing)
    }

    func testAnOpenAsksForOneWakeAndEveryClickWhileCoveredOneMore() {
        var overlay = PhoneScreenOverlay(screen: .off)
        overlay.opened()
        XCTAssertEqual(overlay.wakeRequests, 1)
        XCTAssertTrue(overlay.click())
        XCTAssertEqual(overlay.wakeRequests, 2)
        overlay.set(screen: .on)
        XCTAssertFalse(overlay.click(), "live video keeps the click as a touch")
        XCTAssertEqual(overlay.wakeRequests, 2)
    }

    /// A secure surface (the PIN pad, the keyguard bouncer, a FLAG_SECURE app):
    /// the phone reports `secure`, the cover is the blurred one with no Wake
    /// button, and a click must not ask the phone to wake.
    func testASecureSurfaceCoversWithNoWakeAndClearsOnTheReport() {
        var overlay = PhoneScreenOverlay(screen: .on)
        XCTAssertTrue(overlay.setSecure(true))
        XCTAssertTrue(overlay.isShowing)
        XCTAssertEqual(overlay.cover, .secure)
        XCTAssertFalse(overlay.click(), "the secure cover has no Wake Screen button")
        XCTAssertEqual(overlay.wakeRequests, 0)
        overlay.opened()
        XCTAssertEqual(overlay.wakeRequests, 1, "opening still asks the panel to wake")
        XCTAssertTrue(overlay.setSecure(false))
        XCTAssertFalse(overlay.isShowing)
        XCTAssertNil(overlay.cover)
    }

    /// Phones that do not report `secure` yet: 500 ms of black frames while
    /// the screen is on is a secure surface, and content clears it.
    func testBlackFramesForHalfASecondCoverAndContentClears() {
        var overlay = PhoneScreenOverlay(screen: .on)
        XCTAssertFalse(overlay.frame(at: 10.0, black: true))
        XCTAssertFalse(overlay.frame(at: 10.3, black: true), "not half a second yet")
        XCTAssertFalse(overlay.isShowing)
        XCTAssertTrue(overlay.frame(at: 10.5, black: true))
        XCTAssertTrue(overlay.isShowing)
        XCTAssertEqual(overlay.cover, .secure)
        // Still black: no repeated change.
        XCTAssertFalse(overlay.frame(at: 11.0, black: true))
        XCTAssertTrue(overlay.frame(at: 11.2, black: false))
        XCTAssertFalse(overlay.isShowing)
    }

    func testBlackFramesWhileTheScreenIsOffOrReportedSecureAddNothing() {
        var off = PhoneScreenOverlay(screen: .off)
        XCTAssertFalse(off.frame(at: 1.0, black: true))
        XCTAssertFalse(off.frame(at: 2.0, black: true))
        XCTAssertEqual(off.cover, .screenOff)

        var secure = PhoneScreenOverlay(screen: .on)
        secure.setSecure(true)
        XCTAssertFalse(secure.frame(at: 1.0, black: true))
        XCTAssertFalse(secure.frame(at: 2.0, black: false))
        XCTAssertEqual(secure.cover, .secure, "the phone's own report wins until it clears it")
    }

    // MARK: Window

    func testOpeningThePhoneWindowWakesOnce() {
        let manager = makeManager()
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        XCTAssertEqual(phone.screenModel.wakeRequests, 1, "open must send exactly one phone.wake")
    }

    func testAStateReachesTheWindowAndTheChromeState() throws {
        let manager = makeManager()
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonescreen-\(UUID().uuidString).txt")
        addTeardownBlock { try? FileManager.default.removeItem(at: stateFile) }
        phone.stateFile = stateFile

        manager.setPhoneScreen(.off)
        XCTAssertTrue(phone.screenModel.isShowing)
        XCTAssertFalse(phone.chrome.phoneOverlay.isHidden)
        let off = try String(contentsOf: stateFile, encoding: .utf8)
        XCTAssertTrue(off.contains("screen=off overlay=1"), off)

        manager.setPhoneScreen(.on)
        XCTAssertFalse(phone.screenModel.isShowing)
        XCTAssertTrue(phone.chrome.phoneOverlay.isHidden)
        let on = try String(contentsOf: stateFile, encoding: .utf8)
        XCTAssertTrue(on.contains("screen=on overlay=0"), on)
    }

    func testAWindowOpenedWhileCoveredStartsCovered() {
        let manager = makeManager()
        manager.setPhoneScreen(.off)
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        phone.noteFirstFrame()
        XCTAssertTrue(phone.screenModel.isShowing)
        XCTAssertFalse(phone.chrome.phoneOverlay.isHidden)
    }

    /// A cover is a frozen mode (AGENTS.md "Modes block what they freeze"): the
    /// one predicate disables the phone-side kinds and shortcuts and the bar's
    /// buttons, while the cover's own Wake Screen button stays allowed. The
    /// `nfr` e2e step drives a person's scroll, typing and ⌘[ at the real
    /// window; this pins the rule.
    func testACoverFreezesTheActionsAndTheShortcuts() {
        let manager = makeManager()
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        phone.noteFirstFrame()
        XCTAssertFalse(phone.frozen)
        manager.setPhoneScreen(.off)
        XCTAssertTrue(phone.frozen)
        XCTAssertFalse(HeaderActionPolicy.allowsPhoneShortcut(frozen: phone.frozen))
        for kind in HeaderActionKind.allCases where kind != .liveText {
            XCTAssertFalse(HeaderActionPolicy.isEnabled(kind, frozen: phone.frozen), "\(kind)")
        }
        XCTAssertTrue(HeaderActionPolicy.isEnabled(.liveText, frozen: phone.frozen))
        if let back = buttons(in: phone.chrome).first(where: { $0.action.kind == .back }) {
            let centre = phone.chrome.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), from: back)
            XCTAssertTrue(phone.chrome.hitTest(centre) === back, "the frozen Back takes and swallows its click")
        } else {
            XCTFail("the phone window has no Back button")
        }
        manager.setPhoneScreen(.on)
        XCTAssertFalse(phone.frozen)
        manager.setPhoneSecure(true)
        XCTAssertTrue(phone.frozen, "the secure cover is a frozen mode too")
        manager.setPhoneSecure(false)
        XCTAssertFalse(phone.frozen)
    }

    /// A click on a disabled bar control never reaches the phone (AGENTS.md
    /// "Modes block what they freeze"): the control takes the hit and swallows
    /// it. If it answered nil, the click would fall through to the video under
    /// the bar and become a tap on the phone. Frozen (the screen-off cover) and
    /// disabled outside a frozen mode (a kind the phone cannot use) both count;
    /// the input mapper is the witness.
    func testAClickOnADisabledBarButtonNeverReachesThePhone() {
        let manager = makeManager()
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        var commands: [InputMapper.Command] = []
        phone.noteFirstFrame()
        phone.videoView.inputMapper?.send = { commands.append($0) }
        guard let back = buttons(in: phone.chrome).first(where: { $0.action.kind == .back }) else {
            return XCTFail("the phone window has no Back button")
        }
        let centre = phone.chrome.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), from: back)
        func deliverClick(at point: NSPoint) {
            guard let hit = phone.chrome.hitTest(point) else { return }
            hit.mouseDown(with: click())
            hit.mouseUp(with: click())
        }
        // The witness works: a click on the video itself is a touch.
        let videoCentre = phone.chrome.convert(NSPoint(x: phone.videoView.bounds.midX,
                                                       y: phone.videoView.bounds.midY),
                                               from: phone.videoView)
        deliverClick(at: videoCentre)
        XCTAssertFalse(commands.isEmpty, "a click on the video sends a touch (the witness)")
        commands.removeAll()

        manager.setPhoneScreen(.off)
        XCTAssertTrue(phone.frozen)
        XCTAssertTrue(phone.chrome.hitTest(centre) === back, "the frozen control takes its own click")
        deliverClick(at: centre)
        XCTAssertTrue(commands.isEmpty, "\(commands.count) touch(es) reached the phone through a frozen Back")

        manager.setPhoneScreen(.on)
        back.isEnabled = false
        deliverClick(at: centre)
        XCTAssertTrue(commands.isEmpty, "\(commands.count) touch(es) reached the phone through a disabled Back")
    }

    private func buttons(in view: NSView) -> [HeaderActionButton] {
        view.subviews.flatMap { sub -> [HeaderActionButton] in
            (sub as? HeaderActionButton).map { [$0] } .map { $0 + buttons(in: sub) } ?? buttons(in: sub)
        }
    }

    func testAClickOnTheCoverWakesAndNoInputLeaves() {
        let manager = makeManager()
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        manager.setPhoneScreen(.off)

        var commands: [InputMapper.Command] = []
        phone.noteFirstFrame()
        phone.videoView.inputMapper?.send = { commands.append($0) }
        // The frozen frame blocks every input path, not just the click.
        phone.videoView.inputMapper?.mouseDown(click())
        phone.videoView.inputMapper?.keyDown(keyEvent())
        XCTAssertTrue(commands.isEmpty, "\(commands.count) input command(s) reached the phone")

        let cover = phone.chrome.phoneOverlay
        let centre = cover.superview!.convert(NSPoint(x: cover.bounds.midX, y: cover.bounds.midY), from: cover)
        XCTAssertTrue(cover.hitTest(centre) === cover, "a click on the cover is the Wake Screen button")
        cover.mouseDown(with: click())
        XCTAssertEqual(phone.screenModel.wakeRequests, 2, "open + click")
        XCTAssertTrue(commands.isEmpty)
    }
}
