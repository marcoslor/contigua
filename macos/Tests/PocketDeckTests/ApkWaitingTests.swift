// FILES-16: an install asked for while the phone is paired but away waits for
// the link (up to 120 s), shows "Waiting for your phone…" with Cancel, and a
// Cancel drops the queued file; the sentence names the step that can fix it.

import XCTest
@testable import PocketDeck

@MainActor
final class ApkWaitingTests: XCTestCase {
    func testAPairedPhoneThatIsAwayShowsTheWaitingPhase() {
        let installer = ApkInstaller()
        installer.wait(for: URL(fileURLWithPath: "/tmp/thing.apk"))
        XCTAssertEqual(installer.phase, .waiting("thing"))
        XCTAssertTrue(installer.isBusy)
    }

    func testCancelWhileWaitingDropsTheQueuedFile() {
        let installer = ApkInstaller()
        var cancelled = false
        installer.onWaitingCancelled = { cancelled = true }
        installer.wait(for: URL(fileURLWithPath: "/tmp/thing.apk"))
        installer.cancel()
        XCTAssertTrue(cancelled, "the controller is told to forget the pending file")
        XCTAssertEqual(installer.phase, .finished("Install cancelled.", ok: false))
        XCTAssertFalse(installer.isBusy)
    }

    /// The phone leaving is why the install waits; it must not replace the
    /// waiting phase with a "lost the connection" failure.
    func testThePhoneLeavingKeepsTheWaitingPhase() {
        let installer = ApkInstaller()
        installer.wait(for: URL(fileURLWithPath: "/tmp/thing.apk"))
        installer.connectionLost()
        XCTAssertEqual(installer.phase, .waiting("thing"))
    }

    func testTheWaitTimesOutWithASentence() {
        let installer = ApkInstaller()
        installer.wait(for: URL(fileURLWithPath: "/tmp/thing.apk"))
        installer.waitingExpired()
        XCTAssertEqual(installer.phase, .finished("Your phone didn't connect.", ok: false))
    }

    /// The sentence names the step that can fix it: pairing for no phone, the
    /// connection for one that is paired and away.
    func testTheOfflineSentenceNamesTheRightStep() {
        XCTAssertEqual(ConnectionController.installWaitingLine(paired: false),
                       "Pair a phone to install apps on it.")
        XCTAssertEqual(ConnectionController.installWaitingLine(paired: true),
                       "Connect your phone to install apps on it.")
    }
}
