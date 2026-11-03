// Targeted drops (SHARE-17): an app window's drop names its package and the
// batch fields; the Deck, a phone-mode window and a link window name none; the
// sender announces every file with its index and count.

import AppKit
import XCTest
@testable import PocketDeck

private final class RecordingDropChannel: @unchecked Sendable, DropChannel {
    struct Start: Equatable {
        var id: UInt32
        var name: String
        var target: String?
        var index: Int
        var count: Int
    }

    private let lock = NSLock()
    private(set) var starts: [Start] = []

    func dropStart(id: UInt32, name: String, mime: String, size: Int, sha256: String,
                   resume: Int, target: String?, index: Int, count: Int) {
        lock.lock(); defer { lock.unlock() }
        starts.append(Start(id: id, name: name, target: target, index: index, count: count))
    }

    func cancelDrop(id: UInt32) {}

    func sendDropData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) {
        sent(true)
    }
}

@MainActor
final class TargetedDropTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.targeted.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    func testAnAppWindowNamesItsPackage() {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        XCTAssertEqual("com.example.app", controller.dropTargetPackage)
    }

    func testPhoneAndLinkWindowsCarryNoTarget() {
        let manager = makeManager()
        let phone = PhoneWindowController(stream: 1, phone: nil, manager: manager)
        let link = LinkWindowController(stream: 2, url: "https://example.com", manager: manager)
        defer {
            phone.window?.close()
            link.window?.close()
        }
        XCTAssertNil(phone.dropTargetPackage)
        XCTAssertNil(link.dropTargetPackage)
    }

    func testTheWindowsDropClosurePassesItsPackage() {
        let manager = makeManager()
        let controller = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                             label: "Example", manager: manager)
        defer { controller.window?.close() }
        var captured: String?
        manager.onFilesDropped = { _, target in captured = target }
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        controller.videoView.onDroppedFiles?([url])
        XCTAssertEqual("com.example.app", captured)
    }

    private func tinyFiles(_ count: Int) -> (URL, [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("targeted-drop-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = (1...count).map { index -> URL in
            let url = dir.appendingPathComponent("file-\(index).pdf")
            try! Data([UInt8(index)]).write(to: url)
            return url
        }
        return (dir, urls)
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)  // real-time: the sender's async pump, bounded at 20 ms
        for _ in 0..<40 { await Task.yield() }
    }

    func testTheSenderCarriesTargetAndBatchOnEveryDrop() async {
        let (dir, urls) = tinyFiles(3)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sender = FileDropSender()
        let channel = RecordingDropChannel()
        sender.send(urls, session: channel, target: "com.example.app")
        await settle()
        XCTAssertEqual(1, channel.starts.count)
        XCTAssertEqual([RecordingDropChannel.Start(id: channel.starts[0].id, name: "file-1.pdf",
                                                   target: "com.example.app", index: 1, count: 3)],
                       channel.starts)
        for (expectedIndex, expectedName) in [(2, "file-2.pdf"), (3, "file-3.pdf")] {
            let current = channel.starts.last!
            sender.progress(id: current.id, bytes: 0)
            sender.result(DropResult(id: current.id, ok: true, path: "/sdcard/Download/PocketDeck/\(expectedName)"))
            await settle()
            XCTAssertEqual(expectedIndex, channel.starts.last?.index)
            XCTAssertEqual(3, channel.starts.last?.count)
            XCTAssertEqual("com.example.app", channel.starts.last?.target)
        }
    }

    func testAQueueWithoutATargetNamesNone() async {
        let (dir, urls) = tinyFiles(1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sender = FileDropSender()
        let channel = RecordingDropChannel()
        sender.send(urls, session: channel, target: nil)
        await settle()
        XCTAssertEqual(1, channel.starts.count)
        XCTAssertNil(channel.starts[0].target)
        XCTAssertEqual(1, channel.starts[0].index)
        XCTAssertEqual(1, channel.starts[0].count)
    }

    func testAPluralBatchSaysHowManyWereSaved() async {
        let (dir, urls) = tinyFiles(6)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sender = FileDropSender()
        let channel = RecordingDropChannel()
        sender.send(urls, session: channel, target: "com.example.app")
        await settle()
        for _ in urls {
            guard let current = channel.starts.last else { break }
            sender.progress(id: current.id, bytes: 0)
            sender.result(DropResult(id: current.id, ok: true,
                                     path: "/sdcard/Download/PocketDeck/\(current.name)"))
            await settle()
        }
        XCTAssertEqual(.finished("Saved 6 files on the phone.", ok: true), sender.phase)
    }
}
