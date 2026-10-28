// Opening the same app again must raise the window the app already has, not
// ask the phone for a second stream: while the window waits for its first
// frame (the v104 log: seven dock opens of Chrome in 77 s, the window black)
// and after the picture is in (a Deck click is a click on the app, and one app
// opens one window — Launchpad's behaviour). A second window would wait for an
// explicit "New Window", which is not built.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class OpeningDedupeTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.opening.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    func testASecondOpenWhileTheAppIsOpeningRaisesTheSameWindow() {
        let manager = makeManager()
        let first = manager.openApp(pkg: "com.android.chrome")
        defer { first.window?.close() }
        XCTAssertTrue(first.isOpening)

        let second = manager.openApp(pkg: "com.android.chrome")
        XCTAssertIdentical(first, second, "the waiting window is raised, not a second one")
        XCTAssertEqual(manager.openStreams, [first.stream], "one stream, one launch asked of the phone")

        // Another app is still a new window.
        let other = manager.openApp(pkg: "com.android.documentsui")
        defer { other.window?.close() }
        XCTAssertNotEqual(other.stream, first.stream)
        XCTAssertEqual(manager.openStreams.count, 2)
    }

    func testAFinishedWindowIsRaisedNotDuplicated() {
        let manager = makeManager()
        let first = manager.openApp(pkg: "com.android.chrome")
        defer { first.window?.close() }
        first.noteFirstFrame()
        XCTAssertFalse(first.isOpening)

        let second = manager.openApp(pkg: "com.android.chrome")
        XCTAssertIdentical(first, second, "the open window is raised, not duplicated")
        XCTAssertEqual(manager.openStreams, [first.stream], "one window, one stream, one launch")
    }
}
