import CryptoKit
import XCTest
@testable import Contigua

final class ShareInTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sharein-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: classify

    func testWebLinksAreLinks() {
        XCTAssertEqual(ShareInPolicy.classify("https://example.com/a?b=1"), .link(URL(string: "https://example.com/a?b=1")!))
        XCTAssertEqual(ShareInPolicy.classify("  HTTP://Example.com \n"), .link(URL(string: "HTTP://Example.com")!))
        XCTAssertEqual(ShareInPolicy.classify("Look at this: https://example.com/x."),
                       .link(URL(string: "https://example.com/x")!))
    }

    func testOtherTextIsText() {
        for text in ["hello world", "two https://a.com and https://b.com", "https://", "https:///path",
                     "http://exa\u{0}mple.com", "example.com"] {
            XCTAssertEqual(ShareInPolicy.classify(text), .text(text), text)
        }
    }

    func testOnlyHttpAndHttpsAreEverOpened() {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "contigua://open?url=https%3A%2F%2Fx.com",
                     "intent://scan/#Intent;scheme=zxing;end", "myapp://do/something", "tel:+351210000000",
                     "mailto:a@example.com", "geo:38.7,-9.1", "FILE:///Users", "javascript:https://x.com",
                     "ftp://example.com/file"] {
            XCTAssertEqual(ShareInPolicy.classify(text), .text(text), text)
        }
    }

    func testEmptyAndOversizedTextIsIgnored() {
        XCTAssertNil(ShareInPolicy.classify(""))
        XCTAssertNil(ShareInPolicy.classify("  \n"))
        XCTAssertNil(ShareInPolicy.classify(String(repeating: "x", count: ShareInPolicy.maxTextBytes + 1)))
        XCTAssertNotNil(ShareInPolicy.classify(String(repeating: "x", count: ShareInPolicy.maxTextBytes)))
    }

    // MARK: names

    func testSanitizedNames() {
        XCTAssertEqual(ShareFileName.sanitize("IMG_2024.jpg", mime: "image/jpeg"), "IMG_2024.jpg")
        XCTAssertEqual(ShareFileName.sanitize("../../etc/passwd", mime: "image/png"), "passwd.png")
        XCTAssertEqual(ShareFileName.sanitize(".hidden.png", mime: "image/png"), "hidden.png")
        XCTAssertEqual(ShareFileName.sanitize("photo", mime: "image/webp"), "photo.webp")
        XCTAssertEqual(ShareFileName.sanitize("", mime: "image/png"), "Image.png")
        XCTAssertEqual(ShareFileName.sanitize("写真.jpg", mime: "image/jpeg"), "Image.jpg")
        XCTAssertEqual(ShareFileName.sanitize("a:b*c?.gif", mime: "image/gif"), "abc.gif")
        let long = ShareFileName.sanitize(String(repeating: "a", count: 300) + ".png", mime: "image/png")
        XCTAssertEqual(long.count, ShareFileName.maxLength)
        XCTAssertTrue(long.hasSuffix(".png"))
    }

    func testCollisionsGetANumber() {
        var taken: Set<String> = ["a.png", "a 2.png", "noext"]
        let dir = URL(fileURLWithPath: "/tmp/x")
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(ShareFileName.unique("a.png", in: dir, exists: exists).lastPathComponent, "a 3.png")
        XCTAssertEqual(ShareFileName.unique("b.png", in: dir, exists: exists).lastPathComponent, "b.png")
        XCTAssertEqual(ShareFileName.unique("noext", in: dir, exists: exists).lastPathComponent, "noext 2")
        taken.removeAll()
    }

    // MARK: receiver

    private func hex(_ data: [UInt8]) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    func testSavesAnImageAndNumbersASecondOne() throws {
        let receiver = ShareFileReceiver(directory: directory)
        let bytes: [UInt8] = Array(0..<200).map { UInt8($0) }
        for expected in ["pic.png", "pic 2.png"] {
            receiver.begin(id: 1, name: "pic.png", mime: "image/png")
            receiver.data(id: 1, bytes: Array(bytes[..<100]))
            receiver.data(id: 9, bytes: [1, 2, 3])
            receiver.data(id: 1, bytes: Array(bytes[100...]))
            guard case .saved(let url) = receiver.end(id: 1, size: 200, sha256: hex(bytes)) else {
                return XCTFail("not saved")
            }
            XCTAssertEqual(url.lastPathComponent, expected)
            XCTAssertEqual(try Data(contentsOf: url), Data(bytes))
        }
        XCTAssertEqual(leftovers(), [])
    }

    func testSizeCapRefusesAndCleansUp() {
        let receiver = ShareFileReceiver(directory: directory, maxBytes: 10)
        receiver.begin(id: 2, name: "big.jpg", mime: "image/jpeg")
        receiver.data(id: 2, bytes: [UInt8](repeating: 1, count: 8))
        receiver.data(id: 2, bytes: [UInt8](repeating: 1, count: 8))
        XCTAssertEqual(leftovers(), [])
        XCTAssertEqual(receiver.end(id: 2, size: 16, sha256: hex([UInt8](repeating: 1, count: 16))),
                       .failed("larger than 0 MB"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("big.jpg").path))
    }

    func testExactlyTheCapIsSaved() {
        let receiver = ShareFileReceiver(directory: directory, maxBytes: 10)
        let bytes = [UInt8](repeating: 7, count: 10)
        receiver.begin(id: 3, name: "x.png", mime: "image/png")
        receiver.data(id: 3, bytes: bytes)
        guard case .saved = receiver.end(id: 3, size: 10, sha256: hex(bytes)) else { return XCTFail("not saved") }
    }

    func testDefaultCapIsFiftyMegabytes() {
        XCTAssertEqual(ShareInPolicy.maxFileBytes, 50 * 1_048_576)
    }

    func testChecksumMismatchAndNonImagesAreRefused() {
        let receiver = ShareFileReceiver(directory: directory)
        receiver.begin(id: 4, name: "x.png", mime: "image/png")
        receiver.data(id: 4, bytes: [1, 2, 3])
        XCTAssertEqual(receiver.end(id: 4, size: 3, sha256: hex([1, 2, 4])), .failed("checksum mismatch"))
        receiver.begin(id: 5, name: "x.sh", mime: "application/x-sh")
        receiver.data(id: 5, bytes: [1])
        XCTAssertEqual(receiver.end(id: 5, size: 1, sha256: hex([1])), .failed("not an image (application/x-sh)"))
        XCTAssertNil(receiver.end(id: 99, size: 0, sha256: ""))
        XCTAssertEqual(leftovers(), [])
    }

    func testAbortAndNewBeginDropThePartialFile() {
        let receiver = ShareFileReceiver(directory: directory)
        receiver.begin(id: 6, name: "x.png", mime: "image/png")
        receiver.data(id: 6, bytes: [1])
        receiver.begin(id: 7, name: "y.png", mime: "image/png")
        XCTAssertNil(receiver.end(id: 6, size: 1, sha256: hex([1])))
        receiver.abort(id: 7)
        XCTAssertEqual(leftovers(), [])
    }

    // MARK: inbox

    @MainActor
    func testInboxRoutesLinksTextAndImages() {
        let actions = RecordingActions()
        let inbox = ShareInbox(directory: directory, actions: actions)
        inbox.phoneName = "Pixel"
        inbox.text("https://example.com")
        inbox.text("file:///etc/passwd")
        inbox.fileBegin(id: 1, name: "a.png", mime: "image/png")
        inbox.fileData(id: 1, bytes: [1, 2])
        inbox.fileEnd(id: 1, size: 2, sha256: hex([1, 2]))
        XCTAssertEqual(actions.opened, [URL(string: "https://example.com")!])
        XCTAssertEqual(actions.texts, ["file:///etc/passwd"])
        XCTAssertEqual(actions.images.map(\.lastPathComponent), ["a.png"])
        XCTAssertEqual(actions.notes, ["Copied from Pixel", "Image from Pixel"])
    }

    // MARK: link rate limit (sec H-2)

    func testTheOpenLimiterAllowsOneLinkPerPhonePerWindow() {
        var limiter = ShareOpenLimiter()
        XCTAssertTrue(limiter.allow(phone: "p", now: 10))
        XCTAssertFalse(limiter.allow(phone: "p", now: 10.5))
        XCTAssertFalse(limiter.allow(phone: "p", now: 12.99))
        XCTAssertTrue(limiter.allow(phone: "p", now: 13))
        XCTAssertTrue(limiter.allow(phone: "q", now: 13), "the window is per phone")
        XCTAssertFalse(limiter.allow(phone: "p", now: 12), "a backwards clock does not open early")
    }

    @MainActor
    func testTheInboxHoldsASecondLinkInsideTheWindowAsANotification() {
        let actions = RecordingActions()
        let inbox = ShareInbox(directory: directory, actions: actions)
        inbox.phoneName = "Pixel"
        inbox.phoneId = "phone-1"
        var now: TimeInterval = 100
        inbox.clock = { now }

        inbox.text("https://first.example.com/a?b=1")
        now += 1
        inbox.text("https://second.example.com/secret/path?q=1")
        XCTAssertEqual(actions.opened.compactMap(\.host), ["first.example.com"])
        XCTAssertEqual(actions.links.count, 1)
        XCTAssertEqual(actions.links.first?.title, "Link from Pixel")
        XCTAssertEqual(actions.links.first?.body, "second.example.com", "the notification carries the host only")
        XCTAssertEqual(actions.links.first?.url.absoluteString, "https://second.example.com/secret/path?q=1",
                       "the click target is the whole link")

        // Another phone has its own window.
        inbox.phoneId = "phone-2"
        inbox.text("https://other.example.com")
        XCTAssertEqual(actions.opened.compactMap(\.host), ["first.example.com", "other.example.com"])

        // The same phone after the window opens again.
        inbox.phoneId = "phone-1"
        now += 2
        inbox.text("https://third.example.com")
        XCTAssertEqual(actions.opened.compactMap(\.host),
                       ["first.example.com", "other.example.com", "third.example.com"])
    }

    func testCopiedShareIsNotEchoedBack() {        let pasteboard = FakeBoard()
        var sent: [String] = []
        let sync = ClipboardSync(pasteboard: pasteboard, isEnabled: { false }, send: { sent.append($0) },
                                 clock: { _, _ in {} })
        sync.start()
        sync.adopt("from phone")
        XCTAssertEqual(pasteboard.text, "from phone")
        sync.poll()
        XCTAssertEqual(sent, [])
    }
}

private final class RecordingActions: ShareInActions {
    var opened: [URL] = []
    var texts: [String] = []
    var images: [URL] = []
    var notes: [String] = []
    var links: [(title: String, body: String, url: URL)] = []
    func open(_ url: URL) { opened.append(url) }
    func copy(text: String) { texts.append(text) }
    func copy(imageFile: URL) { images.append(imageFile) }
    func notify(title: String, body: String, file: URL?) { notes.append(title) }
    func notifyLink(title: String, body: String, url: URL) { links.append((title, body, url)) }
}

private final class FakeBoard: ClipboardPasteboard {
    var changeCount = 0
    var text: String?
    func currentItem() -> (text: String?, types: Set<String>) { (text, []) }
    func write(text: String) {
        self.text = text
        changeCount += 1
    }
    // The share tests never touch images; the conformance is inert here.
    func currentImage() -> (data: Data, mime: String)? { nil }
    func writeImage(data: Data, mime: String) {}
}
