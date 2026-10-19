// The Mac-side drop rules (docs/design/dragdrop.md): names, the sender's
// chunking/resume/result flow, the clipboard image buffer and the sync's image
// rules. The fake channel is FileDropSender's whole network.

import AppKit
import CryptoKit
import XCTest
@testable import PocketDeck

final class DropNameTests: XCTestCase {
    func testSanitizeMatchesTheShareInReceiver() {
        XCTAssertEqual("Report.jpg", DropName.sanitize("a/b/Report..jpg", mime: "image/jpeg").file)
        XCTAssertEqual("file.txt", DropName.sanitize("..", mime: "text/plain").file)
        XCTAssertEqual("file.pdf", DropName.sanitize("写真.pdf", mime: "application/pdf").file)
        XCTAssertEqual("notes.pdf", DropName.sanitize("notes", mime: "application/pdf").file)
        XCTAssertEqual("hidden", DropName.sanitize(".hidden.png", mime: "image/png").stem)
        XCTAssertEqual("-dash.pdf", DropName.sanitize("-dash.pdf", mime: "application/pdf").file)
        let long = DropName.sanitize(String(repeating: "N", count: 300) + ".pdf", mime: "application/pdf")
        XCTAssertEqual(DropName.maxLength, long.file.count)
        XCTAssertEqual("N", String(long.stem.dropLast(3).first ?? "x"))
    }
}

private final class FakeDropChannel: @unchecked Sendable, DropChannel {
    struct Start: Equatable {
        var id: UInt32
        var name: String
        var size: Int
        var sha256: String
        var resume: Int
    }

    private let lock = NSLock()
    private(set) var starts: [Start] = []
    private(set) var cancels: [UInt32] = []
    private var chunkData: [UInt8] = []
    private var pending: [@Sendable (Bool) -> Void] = []
    var open = true
    /// Keep the send completions until the test acks them (a slow connection).
    var holdAcks = false

    /// Fake responses when the dropdata is sent.
    var respond: @Sendable (Bool) -> Void = { _ in true }

    func dropStart(id: UInt32, name: String, mime: String, size: Int, sha256: String, resume: Int) {
        lock.lock(); defer { lock.unlock() }
        starts.append(Start(id: id, name: name, size: size, sha256: sha256, resume: resume))
    }

    func cancelDrop(id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        cancels.append(id)
    }

    func sendDropData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        chunkData += bytes
        let hold = holdAcks
        if hold { pending.append(sent) }
        lock.unlock()
        if !hold { respond(open) }
    }

    /// Answers every chunk held by [holdAcks], as the connection would.
    func ackAll(_ ok: Bool = true) {
        lock.lock()
        let callbacks = pending
        pending = []
        lock.unlock()
        for callback in callbacks { callback(ok) }
    }

    var received: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return chunkData
    }
}

@MainActor
final class FileDropSenderTests: XCTestCase {
    private var dir: URL!
    private var sender: FileDropSender!
    private var channel = FakeDropChannel()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-sender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([10, 11, 12, 13, 14]).write(to: dir.appendingPathComponent("tiny.pdf"))
        channel = FakeDropChannel()
        sender = FileDropSender()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /**
     * The tiny.pdf's hash, computed so the test keeps holding it.
     */
    private var tinySha: String {
        let data = try! Data(contentsOf: dir.appendingPathComponent("tiny.pdf"))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lets the tasks the sender schedules run (they hop back to the main actor).
    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<40 { await Task.yield() }
    }


    func testAnnouncesThenStreamsThenFinishes() async throws {
        sender.send([dir.appendingPathComponent("tiny.pdf")], session: channel)
        await settle()
        XCTAssertEqual(1, channel.starts.count)
        let start = channel.starts[0]
        XCTAssertEqual("tiny.pdf", start.name)
        XCTAssertEqual(5, start.size)
        XCTAssertEqual(tinySha, start.sha256)
        XCTAssertEqual(0, start.resume)

        // The phone's opening progress unblocks the stream.
        sender.progress(id: start.id, bytes: 0)
        await settle()
        XCTAssertEqual(Data([10, 11, 12, 13, 14]), Data(channel.received))

        sender.result(DropResult(id: start.id, ok: true, code: nil, message: nil, path: "/sdcard/Download/PocketDeck/tiny.pdf"))
        guard case .finished(let text, true) = sender.phase, text.contains("tiny.pdf") else {
            return XCTFail("phase \(sender.phase)")
        }
    }

    /// The phone's progress is throttled (250 ms), so its last confirmed offset
    /// can arrive after the whole file is out. That late offset must only move
    /// the pill: the sender has already sent those bytes and must not reopen the
    /// file at that offset (the phone rejects "more bytes than announced").
    func testDelayedAcksAndALateOffsetDoNotResendTheTail() async throws {
        let data = Data((0..<(600 * 1024)).map { UInt8($0 % 251) })
        let url = dir.appendingPathComponent("tail.bin")
        try data.write(to: url)
        channel.holdAcks = true

        sender.send([url], session: channel)
        await settle()
        let start = try XCTUnwrap(channel.starts.first)
        XCTAssertEqual(data.count, start.size)

        // The opening progress unblocks the stream; all three chunks go out and
        // the reader reaches EOF while the acks are still held.
        sender.progress(id: start.id, bytes: 0)
        await settle()
        XCTAssertEqual(data, Data(channel.received))

        // The phone confirms only the first chunk, then acks the held chunks.
        sender.progress(id: start.id, bytes: FileDropSender.chunkSize)
        channel.ackAll()
        await settle()
        channel.ackAll()
        await settle()

        XCTAssertEqual(data.count, channel.received.count)
        XCTAssertEqual(data, Data(channel.received))
    }

    func testResumeCarriesTheOffsetAfterALostConnection() async throws {
        sender.send([dir.appendingPathComponent("tiny.pdf")], session: channel)
        await settle()
        let start = channel.starts[0]
        sender.progress(id: start.id, bytes: 3)
        // A session loss remembers how much the phone confirmed.
        sender.connectionLost()
        guard case .finished("Lost the connection; drop that file again to resume.", false) = sender.phase else {
            return XCTFail("phase \(sender.phase)")
        }
        // No cancel for the phone: its temp is the resume.
        XCTAssertTrue(channel.cancels.isEmpty)

        // The next send of the same file resumes and the flow still completes.
        let channel2 = FakeDropChannel()
        sender.send([dir.appendingPathComponent("tiny.pdf")], session: channel2)
        await settle()
        let second = try XCTUnwrap(channel2.starts.last)
        XCTAssertEqual(3, second.resume)
        sender.progress(id: second.id, bytes: 3)
        await settle()
        XCTAssertEqual(Data([13, 14]), Data(channel2.received))
        sender.result(DropResult(id: second.id, ok: true, code: nil, message: nil,
                                 path: "/sdcard/Download/PocketDeck/tiny.pdf"))
        await settle()
        guard case .finished(_, true) = sender.phase else {
            return XCTFail("phase \(sender.phase)")
        }
    }

    func testOverTheCapRefusesNothingSent() async throws {
        // The whole 200 MB cap is the phone's in the field; here a tiny file is
        // "over the cap" so no 200 MB write is needed for the test.
        DropLimits.testCap = 4
        defer { DropLimits.testCap = nil }
        sender.send([dir.appendingPathComponent("tiny.pdf")], session: channel)
        await settle()
        guard case .finished(let text, false) = sender.phase else { return XCTFail("phase \(sender.phase)") }
        XCTAssertTrue(text.contains("200 MB cap"))
        XCTAssertTrue(channel.starts.isEmpty && channel.received.isEmpty)
    }

    func testCancelAnswersOnTheCorrectId() async throws {
        sender.send([dir.appendingPathComponent("tiny.pdf")], session: channel)
        await settle()
        let start = channel.starts[0]
        sender.progress(id: start.id, bytes: 0)
        sender.cancel()
        XCTAssertEqual([start.id], channel.cancels)
        guard case .finished("Transfer cancelled.", false) = sender.phase else { return XCTFail("phase \(sender.phase)") }
    }
}

final class ClipImageBufferTests: XCTestCase {
    private let bytes = Data([1, 2, 3, 4, 5])

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testAssemblesAndChecksTheDigest() {
        let buffer = ClipImageBuffer()
        XCTAssertTrue(buffer.begin(id: 3, mime: "image/png", size: bytes.count))
        XCTAssertTrue(buffer.data(id: 3, bytes: [UInt8](bytes)))
        let image = buffer.end(id: 3, size: bytes.count, sha256: sha(bytes))
        XCTAssertEqual(bytes, image?.data)
        XCTAssertEqual("image/png", image?.mime)
    }

    func testAChecksumMismatchDropsIt() {
        let buffer = ClipImageBuffer()
        XCTAssertTrue(buffer.begin(id: 3, mime: "image/png", size: bytes.count))
        buffer.data(id: 3, bytes: [UInt8](bytes))
        XCTAssertNil(buffer.end(id: 3, size: bytes.count, sha256: sha(Data([9]))))
        // A mismatched announcement is refused before any chunk lands.
        XCTAssertFalse(ClipImageBuffer().begin(id: 3, mime: "image/png", size: ClipImagePolicy.maxBytes + 1))
        XCTAssertFalse(ClipImageBuffer().begin(id: 3, mime: "text/plain", size: 5))
    }
}

/// The pasteboard cameo for the sync's image rules: images poll + echo rules.
final class ClipboardImageSyncTests: XCTestCase {
    private final class Board: ClipboardPasteboard {
        var changeCount = 0
        var text: String?
        var types: Set<String> = []
        var image: (data: Data, mime: String)?
        private(set) var textWrites: [String] = []
        private(set) var imageWrites: [(data: Data, mime: String)] = []

        func currentItem() -> (text: String?, types: Set<String>) { (self.text, types) }
        func write(text: String) {
            textWrites.append(text)
            self.text = text
            image = nil
            changeCount += 1
        }
        func currentImage() -> (data: Data, mime: String)? { text == nil ? image : nil }
        func writeImage(data: Data, mime: String) {
            guard !imageWrites.contains(where: { $0.data == data }) else { return }
            imageWrites.append((data, mime))
            image = (data, mime)
            self.text = nil
            changeCount += 1
        }
    }

    private var board = Board()
    private var syncedText = ""
    private var imageSends: [(Data, String)] = []
    private var clock: ClipboardSync!
    private var tick: (() -> Void)?

    override func setUp() {
        board = Board()
        imageSends = []
        tick = nil
        clock = ClipboardSync(pasteboard: board,
                              isEnabled: { true },
                              send: { self.syncedText = $0 },
                              sendImage: { data, mime in self.imageSends.append((data, mime)) },
                              clock: { _, t in
            self.tick = t
            return { [weak self] in self?.tick = nil }
        })
    }

    /** One poll of the pasted change. */
    private func poll() { tick?() }

    func testAnImageWithoutTextIsSentOnce() {
        clock.start()
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        board.image = (png, "image/png")
        board.changeCount += 1
        poll()
        XCTAssertEqual(1, imageSends.count)
        XCTAssertEqual(png, imageSends[0].0)
        XCTAssertEqual("image/png", imageSends[0].1)
        // A poll of the same content sent nothing again.
        poll()
        XCTAssertEqual(1, imageSends.count)
        XCTAssertEqual("", syncedText)
    }

    func testTextNextToAnImageGoesThroughTheTextRule() {
        clock.start()
        board.text = "Bodytext"
        board.changeCount += 1
        poll()
        XCTAssertEqual("Bodytext", syncedText)
        XCTAssertTrue(imageSends.isEmpty)
    }

    func testAnImageOverTheCapIsNeverSent() {
        clock.start()
        let big = Data(count: ClipboardSync.maxImageBytes + 1)
        board.image = (big, "image/png")
        board.changeCount += 1
        poll()
        XCTAssertTrue(imageSends.isEmpty)
    }

    func testReceivedImageLandsAndIsNotEchoed() {
        clock.start()
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        clock.receiveImage(png, mime: "image/png")
        XCTAssertEqual(1, board.imageWrites.count)
        XCTAssertEqual(png, board.imageWrites[0].data)
        // The write's change count is consumed; the image does not bounce out.
        poll()
        XCTAssertEqual(0, imageSends.count)
        XCTAssertEqual(1, board.imageWrites.count)
    }
}
