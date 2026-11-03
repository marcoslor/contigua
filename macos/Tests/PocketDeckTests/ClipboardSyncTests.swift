// Clipboard sync rules, on a fake pasteboard and a manual clock: what is sent,
// what is skipped, what is written back without echo, and the toggle.

import AppKit
import ImageIO
import XCTest
@testable import PocketDeck

final class ClipboardSyncTests: XCTestCase {

    /// Each `copy` and `write` bumps the change count, as the real pasteboard does.
    private final class FakePasteboard: ClipboardPasteboard {
        private(set) var changeCount = 0
        private var text: String?
        private var types: Set<String> = []
        private var fileURLs: [URL] = []
        private(set) var writes: [String] = []

        /// Another app copies `text`, carrying `types`.
        func copy(_ text: String, types: Set<String> = []) {
            self.text = text
            self.types = types
            fileURLs = []
            changeCount += 1
        }

        /// A Finder copy: file URLs, plus the file's name as text.
        func copyFiles(_ urls: [URL], text: String? = nil) {
            fileURLs = urls
            self.text = text
            types = Set(["public.file-url"] + (text == nil ? [] : ["public.utf8-plain-text"]))
            changeCount += 1
        }

        func currentItem() -> (text: String?, types: Set<String>) { (text, types) }

        func currentFileURLs() -> [URL] { fileURLs }

        func write(text: String) {
            writes.append(text)
            self.text = text
            types = []
            fileURLs = []
            changeCount += 1
        }

        /// (Clipboard images) the item's image when it has one and no text.
        func currentImage() -> (data: Data, mime: String)? { image }

        func writeImage(data: Data, mime: String) {
            imageWrites.append((data, mime))
            image = (data, mime)
            self.text = nil
            types = []
            fileURLs = []
            changeCount += 1
        }

        /// An image on the copy side: `copy(image:)`.
        var image: (data: Data, mime: String)?
        private(set) var imageWrites: [(data: Data, mime: String)] = []
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
    private var imageSends: [(data: Data, mime: String)] = []
    private var enabled = true
    private var sync: ClipboardSync!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        pasteboard = FakePasteboard()
        clock = ManualClock()
        sent = []
        imageSends = []
        enabled = true
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastedrop-clipboard-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sync = ClipboardSync(pasteboard: pasteboard,
                             isEnabled: { [unowned self] in self.enabled },
                             send: { [unowned self] in self.sent.append($0) },
                             sendImage: { [unowned self] in self.imageSends.append(($0, $1)) },
                             clock: clock.schedule)
    }

    override func tearDown() {
        sync.stop()
        sync = nil
        clock = nil
        pasteboard = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        super.tearDown()
    }

    // MARK: File copies

    /// A tiny image in `type`, written into the test's temp folder.
    private func imageFile(_ name: String, type: NSBitmapImageRep.FileType) -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let bytes = rep.bitmapData!
        for i in 0..<(rep.bytesPerRow * rep.pixelsHigh) { bytes[i] = UInt8((i * 7) & 0xFF) }
        let data = rep.representation(using: type, properties: [:])!
        let url = tempDir.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    /// A HEIC file, when this macOS can encode one.
    private func heicFile(_ name: String) -> URL? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        guard let image = rep.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let url = tempDir.appendingPathComponent(name)
        try? (data as Data).write(to: url)
        return url
    }

    private func file(_ name: String, bytes: Int) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    func testAFileCopyNeverSendsItsNameAsText() {
        sync.start()
        // The Mac may be unable to read the URL back; the type alone still
        // says this is a Finder copy, so its text never travels.
        pasteboard.copy("report.pdf", types: ["public.file-url", "public.utf8-plain-text"])
        sync.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(imageSends.count, 0)
    }

    func testASinglePNGFileCopySendsTheFile() {
        let url = imageFile("photo.png", type: .png)
        let bytes = try! Data(contentsOf: url)
        sync.start()
        pasteboard.copyFiles([url], text: "photo.png")
        sync.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(imageSends.count, 1)
        XCTAssertEqual(imageSends.first?.data, bytes)
        XCTAssertEqual(imageSends.first?.mime, "image/png")
    }

    func testATIFFFileCopyBecomesPNG() {
        let url = imageFile("photo.tiff", type: .tiff)
        sync.start()
        pasteboard.copyFiles([url], text: "photo.tiff")
        sync.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(imageSends.count, 1)
        XCTAssertEqual(imageSends.first?.mime, "image/png")
        XCTAssertEqual(imageSends.first?.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testAHEICFileCopyBecomesPNG() throws {
        guard let url = heicFile("photo.heic") else {
            throw XCTSkip("this macOS cannot encode HEIC in a test")
        }
        sync.start()
        pasteboard.copyFiles([url], text: "photo.heic")
        sync.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(imageSends.count, 1)
        XCTAssertEqual(imageSends.first?.mime, "image/png")
    }

    func testTwoFilesSendNothing() {
        let first = imageFile("one.png", type: .png)
        let second = imageFile("two.png", type: .png)
        sync.start()
        pasteboard.copyFiles([first, second])
        sync.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(imageSends.count, 0)
    }

    func testANonImageFileSendsNothing() {
        let url = file("report.pdf", bytes: 64)
        sync.start()
        pasteboard.copyFiles([url], text: "report.pdf")
        sync.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(imageSends.count, 0)
    }

    func testAnOversizedImageFileSendsNothing() {
        let url = file("big.png", bytes: ClipboardSync.maxImageBytes + 1)
        sync.start()
        pasteboard.copyFiles([url], text: "big.png")
        sync.poll()
        XCTAssertEqual(sent, [])
        XCTAssertEqual(imageSends.count, 0)
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

    func testIsEnabledIsOffUntilThePersonTurnsItOn() {
        let defaults = UserDefaults(suiteName: "dev.pocketdeck.mac.clipboard-sync-tests")!
        defaults.removePersistentDomain(forName: "dev.pocketdeck.mac.clipboard-sync-tests")
        defer { defaults.removePersistentDomain(forName: "dev.pocketdeck.mac.clipboard-sync-tests") }
        // A fresh profile shares no clipboard text or image (AGENTS.md).
        XCTAssertFalse(ClipboardSync.isEnabled(in: defaults))
        defaults.set(true, forKey: ClipboardSync.enabledKey)
        XCTAssertTrue(ClipboardSync.isEnabled(in: defaults))
        // An explicit off survives a later launch; nothing re-defaults it.
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
