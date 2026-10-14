// Clipboard sync rules, on a fake pasteboard and a manual clock: what is sent,
// what is skipped, what is written back without echo, and the toggle.

import XCTest
@testable import PocketDeck

final class ClipboardSyncTests: XCTestCase {

    /// Each `copy` and `write` bumps the change count, as the real pasteboard does.
    private final class FakePasteboard: ClipboardPasteboard {
        private(set) var changeCount = 0
        private var text: String?
        private var types: Set<String> = []
        private(set) var writes: [String] = []

        /// Another app copies `text`, carrying `types`.
        func copy(_ text: String, types: Set<String> = []) {
            self.text = text
            self.types = types
            changeCount += 1
        }

        func currentItem() -> (text: String?, types: Set<String>) { (text, types) }

        func write(text: String) {
            writes.append(text)
            self.text = text
            types = []
            changeCount += 1
        }
    }

    private final class ManualClock {
        private(set) var interval: TimeInterval?
        private var tick: (() -> Void)?
        private(set) var stopped = false

        func schedule(_ interval: TimeInterval, _ tick: @escaping () -> Void) -> () -> Void {
            self.interval = interval
            self.tick = tick
            return { [weak self] in self?.stopped = true }
        }

        /// One timer tick.
        func fire() { tick?() }
    }

    private var pasteboard: FakePasteboard!
    private var clock: ManualClock!
    private var sent: [String] = []
    private var enabled = true
    private var sync: ClipboardSync!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard()
        clock = ManualClock()
        sent = []
        enabled = true
        sync = ClipboardSync(pasteboard: pasteboard,
                             isEnabled: { [unowned self] in self.enabled },
                             send: { [unowned self] in self.sent.append($0) },
                             clock: clock.schedule)
    }

    override func tearDown() {
        sync.stop()
        sync = nil
        clock = nil
        pasteboard = nil
        super.tearDown()
    }

    // MARK: Sending

    func testChangeIsSentOnTheTimerTick() {
        sync.start()
        XCTAssertEqual(clock.interval, 0.5)
        pasteboard.copy("hello")
        clock.fire()
        XCTAssertEqual(sent, ["hello"])
    }

    func testTextAlreadyOnThePasteboardAtStartIsNotSent() {
        pasteboard.copy("before")
        sync.start()
        clock.fire()
        XCTAssertEqual(sent, [])
    }

    func testSameTextCopiedAgainIsSentOnce() {
        sync.start()
        pasteboard.copy("same")
        sync.poll()
        pasteboard.copy("same")
        sync.poll()
        pasteboard.copy("next")
        sync.poll()
        XCTAssertEqual(sent, ["same", "next"])
    }

    func testSecretItemsAreSkipped() {
        for marker in ClipboardSync.secretTypes {
            pasteboard.copy("hunter2", types: [marker, "public.utf8-plain-text"])
            sync.poll()
        }
        XCTAssertEqual(sent, [])
        pasteboard.copy("visible", types: ["public.utf8-plain-text"])
        sync.poll()
        XCTAssertEqual(sent, ["visible"])
    }

    func testTextAtTheLimitIsSentAndOneByteMoreIsNot() {
        sync.start()
        let atLimit = String(repeating: "x", count: ClipboardSync.maxBytes)
        pasteboard.copy(atLimit)
        sync.poll()
        pasteboard.copy(String(repeating: "x", count: ClipboardSync.maxBytes + 1))
        sync.poll()
        XCTAssertEqual(sent, [atLimit])
    }

    func testLimitIsCountedInUTF8Bytes() {
        sync.start()
        // 349 526 characters are fewer than the limit but 1 048 578 UTF-8 bytes
        // (three each), so the text must be dropped.
        pasteboard.copy(String(repeating: "€", count: 349_526))
        sync.poll()
        XCTAssertEqual(sent, [])
    }

    // MARK: Receiving

    func testReceivedTextIsWrittenWithoutEcho() {
        sync.start()
        sync.receive("from phone")
        XCTAssertEqual(pasteboard.writes, ["from phone"])
        clock.fire()
        XCTAssertEqual(sent, [], "the write's own change must not go back to the phone")
    }

    func testCopyingTheReceivedTextAgainIsNotSent() {
        sync.start()
        sync.receive("from phone")
        pasteboard.copy("from phone")
        sync.poll()
        XCTAssertEqual(sent, [])
        pasteboard.copy("mine")
        sync.poll()
        XCTAssertEqual(sent, ["mine"])
    }

    func testReceivedOversizedOrEmptyTextIsIgnored() {
        sync.start()
        sync.receive("")
        sync.receive(String(repeating: "x", count: ClipboardSync.maxBytes + 1))
        XCTAssertEqual(pasteboard.writes, [])
    }

    func testReceiveBeforeStartDoesNothing() {
        sync.receive("early")
        XCTAssertEqual(pasteboard.writes, [])
    }

    // MARK: Toggle

    func testToggleOffSendsAndWritesNothing() {
        sync.start()
        enabled = false
        pasteboard.copy("while off")
        sync.poll()
        sync.receive("from phone")
        XCTAssertEqual(sent, [])
        XCTAssertEqual(pasteboard.writes, [])
    }

    func testChangeMadeWhileOffIsNotSentWhenSyncComesBack() {
        sync.start()
        enabled = false
        pasteboard.copy("while off")
        sync.poll()
        enabled = true
        sync.poll()
        XCTAssertEqual(sent, [])
        pasteboard.copy("after")
        sync.poll()
        XCTAssertEqual(sent, ["after"])
    }

    func testIsEnabledIsOnUntilTurnedOff() {
        let defaults = UserDefaults(suiteName: "dev.pocketdeck.mac.clipboard-sync-tests")!
        defaults.removePersistentDomain(forName: "dev.pocketdeck.mac.clipboard-sync-tests")
        defer { defaults.removePersistentDomain(forName: "dev.pocketdeck.mac.clipboard-sync-tests") }
        XCTAssertTrue(ClipboardSync.isEnabled(in: defaults))
        defaults.set(false, forKey: ClipboardSync.enabledKey)
        XCTAssertFalse(ClipboardSync.isEnabled(in: defaults))
    }

    // MARK: Lifecycle

    func testStopCancelsTheTimerAndStartIsIdempotent() {
        sync.start()
        sync.start()
        XCTAssertTrue(sync.isRunning)
        sync.stop()
        XCTAssertTrue(clock.stopped)
        XCTAssertFalse(sync.isRunning)
    }
}
