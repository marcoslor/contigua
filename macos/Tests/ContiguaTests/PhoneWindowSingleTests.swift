// One phone mirror per phone (the person's report, 2026-10-22): every route
// that opens the mirror goes through WindowManager.openPhoneWindow, and a
// second call raises the window that is already there instead of making
// another mirror of the same screen.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class PhoneWindowSingleTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "app.contigua.tests.phonemirror.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    /// Open twice: one controller and one stream, and the second call answers
    /// with the first — no second `window.open` for the phone.
    func testOpeningTwiceReturnsTheOneMirror() {
        let manager = makeManager()
        let first = manager.openPhoneWindow()
        defer { first.window?.close() }
        let second = manager.openPhoneWindow()
        XCTAssertTrue(first === second, "the second open made a second phone window")
        XCTAssertEqual(manager.openStreams, [first.stream], "one stream for the one mirror")
        XCTAssertTrue(manager.phoneWindow === first)
        XCTAssertEqual(first.stream, 1, "the first mirror is stream 1")
    }

    /// Open, close, open: the next open is a fresh window on a new stream (the
    /// phone closed the old one and no window is left to raise).
    func testReopeningAfterCloseMakesAFreshMirror() {
        let manager = makeManager()
        let first = manager.openPhoneWindow()
        let stream = first.stream
        first.window?.close()
        XCTAssertNil(manager.phoneWindow, "the closed mirror is still the phone window")
        XCTAssertFalse(manager.openStreams.contains(stream))

        let second = manager.openPhoneWindow()
        defer { second.window?.close() }
        XCTAssertFalse(second === first, "the reopen raised the closed window")
        XCTAssertNotEqual(second.stream, stream, "the reopen reused the closed stream")
        XCTAssertEqual(manager.openStreams, [second.stream])
    }

    /// A minimised mirror is brought back rather than duplicated.
    func testASecondOpenUnminimisesTheMirror() throws {
        let manager = makeManager()
        let phone = manager.openPhoneWindow()
        let window = try XCTUnwrap(phone.window)
        defer { window.close() }
        window.orderFront(nil)
        window.performMiniaturize(nil)
        pump(0.2)
        XCTAssertTrue(window.isMiniaturized)
        let again = manager.openPhoneWindow()
        XCTAssertTrue(again === phone)
        XCTAssertFalse(window.isMiniaturized, "the open mirror stayed in the Dock")
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
