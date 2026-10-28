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
        let first = manager.openOrRaise(pkg: "com.android.chrome")
        defer { first.window?.close() }
        XCTAssertTrue(first.isOpening)

        let second = manager.openOrRaise(pkg: "com.android.chrome")
        XCTAssertIdentical(first, second, "the waiting window is raised, not a second one")
        XCTAssertEqual(manager.openStreams, [first.stream], "one stream, one launch asked of the phone")

        // Another app is still a new window.
        let other = manager.openOrRaise(pkg: "com.android.documentsui")
        defer { other.window?.close() }
        XCTAssertNotEqual(other.stream, first.stream)
        XCTAssertEqual(manager.openStreams.count, 2)
    }

    /// The one open-or-raise entry point brings a window back: minimised in the
    /// Dock, or ordered out, the next ask raises it rather than opening a
    /// second stream.
    func testARaisedWindowComesBackFromTheDockAndFromBehind() {
        let manager = makeManager()
        let first = manager.openOrRaise(pkg: "com.android.chrome")
        defer { first.window?.close() }
        first.noteFirstFrame()
        guard let window = first.window else { return XCTFail("no window") }

        window.miniaturize(nil)
        // The Dock animation is asynchronous.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        XCTAssertTrue(window.isMiniaturized, "the window is in the Dock")
        let raised = manager.openOrRaise(pkg: "com.android.chrome")
        XCTAssertIdentical(first, raised)
        XCTAssertFalse(window.isMiniaturized, "the raise took it out of the Dock")
        XCTAssertEqual(manager.openStreams, [first.stream])

        window.orderOut(nil)
        XCTAssertFalse(window.isVisible, "the window is out of sight")
        _ = manager.openOrRaise(pkg: "com.android.chrome")
        XCTAssertTrue(window.isVisible, "the raise put it back on screen")
        XCTAssertEqual(manager.openStreams, [first.stream], "still one window, one stream")
    }

    func testAFinishedWindowIsRaisedNotDuplicated() {
        let manager = makeManager()
        let first = manager.openOrRaise(pkg: "com.android.chrome")
        defer { first.window?.close() }
        first.noteFirstFrame()
        XCTAssertFalse(first.isOpening)

        let second = manager.openOrRaise(pkg: "com.android.chrome")
        XCTAssertIdentical(first, second, "the open window is raised, not duplicated")
        XCTAssertEqual(manager.openStreams, [first.stream], "one window, one stream, one launch")
    }
}
