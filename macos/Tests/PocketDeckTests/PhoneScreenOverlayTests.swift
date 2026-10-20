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
        XCTAssertTrue(phone.screenModel.isShowing)
        XCTAssertFalse(phone.chrome.phoneOverlay.isHidden)
    }

    func testAClickOnTheCoverWakesAndNoInputLeaves() {
        let manager = makeManager()
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        manager.setPhoneScreen(.off)

        var commands: [InputMapper.Command] = []
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
