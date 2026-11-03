// SHARE-18's Mac side (docs/design/dragdrop.md): D1's source order, the
// resolve state machine, image data and promises becoming temp files, and the
// per-gesture folder's cleanup rules. The download itself is in
// DropDownloadTests.

import AppKit
import XCTest
@testable import PocketDeck

final class DropSourceOrderTests: XCTestCase {
    func testTheRichestLocalSourceWins() {
        XCTAssertEqual(.files, DropSourceOrder.choose(files: true, promises: true, image: true, remote: true))
        XCTAssertEqual(.promises, DropSourceOrder.choose(files: false, promises: true, image: true, remote: true))
        XCTAssertEqual(.image, DropSourceOrder.choose(files: false, promises: false, image: true, remote: true))
        XCTAssertEqual(.remote, DropSourceOrder.choose(files: false, promises: false, image: false, remote: true))
        XCTAssertEqual(.none, DropSourceOrder.choose(files: false, promises: false, image: false, remote: false))
    }

    func testAFileURLBeatsEverythingABrowserAlsoPutsOnTheDrag() {
        let drag = DropDrag(files: [URL(fileURLWithPath: "/tmp/report.pdf")],
                            image: DropImage(data: Data([1]), type: .png),
                            remote: URL(string: "https://example.com/a.png"))
        XCTAssertEqual(.files, DropSourceOrder.choose(drag))
        XCTAssertEqual("file(s) 1", drag.kind)
    }
}

final class DropSourceNameTests: XCTestCase {
    func testBareImageDataIsImagePngOrJpg() {
        XCTAssertEqual("Image.png", DropSourceName.image(mime: "image/png"))
        XCTAssertEqual("Image.jpg", DropSourceName.image(mime: "image/jpeg"))
    }

    func testADownloadKeepsItsOwnFileNameButStillFollowsDropName() {
        XCTAssertEqual("photo.png",
                       DropSourceName.downloaded(URL(string: "https://example.com/photo.png")!,
                                                 mime: "image/png", ext: "png"))
        XCTAssertEqual("photo.jpg",
                       DropSourceName.downloaded(URL(string: "https://example.com/photo")!,
                                                 mime: "image/jpeg", ext: "jpg"))
        XCTAssertEqual("Image.heic",
                       DropSourceName.downloaded(URL(string: "https://example.com/")!,
                                                 mime: "image/heic", ext: "heic"))
    }
}

@MainActor
private final class FakePromise: DropPromiseSource {
    var directory: URL?
    var files: [URL] = []
    var error: Error?
    var silent = false

    func receive(into directory: URL, completion: @escaping (Result<[URL], Error>) -> Void) {
        self.directory = directory
        if silent { return }
        if let error { return completion(.failure(error)) }
        do {
            let named = files.isEmpty ? [directory.appendingPathComponent("promised-0.png")] : files
            for url in named { try Data([1, 2, 3]).write(to: url) }
            completion(.success(named))
        } catch {
            completion(.failure(error))
        }
    }
}

private final class FakeDownloader: DropDownloading {
    var answer: Result<DropDownload, DropResolveFailure> = .failure(.failed)
    var requested: URL?
    var cancelled = false

    func download(_ url: URL,
                  completion: @escaping (Result<DropDownload, DropResolveFailure>) -> Void) {
        requested = url
        completion(answer)
    }

    func cancel() { cancelled = true }
}

@MainActor
final class DropSourceResolverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func png() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    }

    private func jpeg() -> Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    private func resolve(_ drag: DropDrag, wait: TimeInterval = 30,
                         downloader: FakeDownloader = FakeDownloader()) async
        -> Result<DropSourceResolver.Resolved, DropResolveFailure> {
        let resolver = DropSourceResolver(root: root, downloader: downloader, promiseWait: wait)
        return await withCheckedContinuation { continuation in
            resolver.resolve(drag) { continuation.resume(returning: $0) }
        }
    }

    func testImageDataIsWrittenAsItCame() async throws {
        let bytes = png()
        let result = await resolve(DropDrag(image: DropImage(data: bytes, type: .png)))
        let resolved = try XCTUnwrap(try? result.get())

        XCTAssertEqual("Image.png", resolved.files.single?.lastPathComponent)
        XCTAssertEqual(bytes, try Data(contentsOf: resolved.files.single!))
        XCTAssertEqual(resolved.folder, resolved.files.single?.deletingLastPathComponent())
    }

    func testJPEGIsVerbatimAndTIFFIsReencoded() async throws {
        let photo = jpeg()
        let jpegAnswer = await resolve(DropDrag(image: DropImage(data: photo, type: .jpeg)))
        let jpegResult = try jpegAnswer.get()
        XCTAssertEqual("Image.jpg", jpegResult.files.single?.lastPathComponent)
        XCTAssertEqual(photo, try Data(contentsOf: jpegResult.files.single!))

        let image = NSImage(data: photo)!
        let tiffAnswer = await resolve(DropDrag(image: DropImage(data: image.tiffRepresentation!,
                                                                type: .tiff)))
        let tiffResult = try tiffAnswer.get()
        let name = try XCTUnwrap(tiffResult.files.single?.lastPathComponent)
        XCTAssertTrue(name == "Image.png" || name == "Image.jpg")
        XCTAssertFalse(try Data(contentsOf: tiffResult.files.single!).isEmpty)
    }

    func testAnOverCapImageIsRefusedAndLeavesNoFolder() async {
        let bytes = Data(count: ClipboardSync.maxImageBytes + 1)
        let result = await resolve(DropDrag(image: DropImage(data: bytes, type: .png)))
        XCTAssertEqual(.failure(.tooLarge), result)
        XCTAssertTrue(children.isEmpty)
    }

    func testADeliveredPromiseBecomesTheBatch() async throws {
        let promise = FakePromise()
        let result = await resolve(DropDrag(promises: [promise]))
        let resolved = try result.get()

        XCTAssertEqual(1, resolved.files.count)
        XCTAssertEqual("promised-0.png", resolved.files.first?.lastPathComponent)
        XCTAssertEqual(resolved.folder, promise.directory)
    }

    func testAPromiseThatNeverArrivesTimesOut() async {
        let promise = FakePromise()
        promise.silent = true
        let result = await resolve(DropDrag(promises: [promise]), wait: 0.1)
        XCTAssertEqual(.failure(.timedOut), result)
        XCTAssertTrue(children.isEmpty)
    }

    func testADownloadBecomesItsOwnFileNameAndMime() async throws {
        let downloader = FakeDownloader()
        downloader.answer = .success(DropDownload(data: png(), mime: "image/png", ext: "png"))
        let result = await resolve(DropDrag(remote: URL(string: "https://example.com/photo.png")!),
                                   downloader: downloader)
        let resolved = try result.get()

        XCTAssertEqual("photo.png", resolved.files.single?.lastPathComponent)
        XCTAssertEqual(png(), try Data(contentsOf: resolved.files.single!))
    }

    func testANonImageDownloadIsRefusedAndLeavesNoFolder() async {
        let downloader = FakeDownloader()
        downloader.answer = .failure(.notImage)
        let result = await resolve(DropDrag(remote: URL(string: "https://example.com/page")!),
                                   downloader: downloader)
        XCTAssertEqual(.failure(.notImage), result)
        XCTAssertTrue(children.isEmpty)
    }

    private var children: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

@MainActor
final class DropResolveMachineTests: XCTestCase {
    private func phase(after events: [DropResolveEvent]) -> DropResolvePhase {
        var machine = DropResolveMachine()
        for event in events { _ = machine.handle(event) }
        return machine.phase
    }

    func testResolvingEndsInEachTerminalState() {
        XCTAssertEqual(.resolving, phase(after: [.start]))
        XCTAssertEqual(.ready, phase(after: [.start, .resolved]))
        XCTAssertEqual(.refused(.notImage), phase(after: [.start, .refused(.notImage)]))
        XCTAssertEqual(.timedOut, phase(after: [.start, .timedOut]))
        XCTAssertEqual(.cancelled, phase(after: [.start, .cancelled]))
    }

    func testAStartIsOnlyAcceptedWhenNothingIsInFlight() {
        var fresh = DropResolveMachine()
        XCTAssertEqual([.begin], fresh.handle(.start))
        var machine = DropResolveMachine()
        _ = machine.handle(.start)
        XCTAssertEqual([], machine.handle(.start))
        _ = machine.handle(.resolved)
        XCTAssertEqual([], machine.handle(.start))
    }

    func testLateOrForeignEventsAreIgnored() {
        var machine = DropResolveMachine()
        XCTAssertEqual([], machine.handle(.resolved))
        XCTAssertEqual([], machine.handle(.timedOut))
        _ = machine.handle(.start)
        XCTAssertEqual([], machine.handle(.resolved))
        XCTAssertEqual([], machine.handle(.refused(.failed)))
        XCTAssertEqual([], machine.handle(.cancelled))
        XCTAssertEqual([], machine.handle(.timedOut))
    }

    func testTheSessionEndsInEveryState() {
        XCTAssertEqual(.cancelled,
                       phase(after: [.start, .sessionEnded]))
        XCTAssertEqual(.cancelled,
                       phase(after: [.start, .resolved, .sessionEnded]))
        XCTAssertEqual(.cancelled,
                       phase(after: [.start, .refused(.notImage), .sessionEnded]))
        XCTAssertEqual(.cancelled,
                       phase(after: [.start, .timedOut, .sessionEnded]))
        XCTAssertEqual(.cancelled,
                       phase(after: [.start, .cancelled, .sessionEnded]))
        XCTAssertEqual(.idle, phase(after: [.sessionEnded]))
    }

    func testDismissAndFinishReturnToIdle() {
        XCTAssertEqual(.idle, phase(after: [.start, .refused(.notImage), .dismissed]))
        XCTAssertEqual(.idle, phase(after: [.start, .resolved, .finished]))
        var machine = DropResolveMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.resolved)
        XCTAssertEqual([.cleanup], machine.handle(.dismissed))
    }
}

@MainActor
final class DropSourceFlowTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func flow() -> DropSourceFlow {
        DropSourceFlow(root: root)
    }

    private func settle() async {
        for _ in 0..<40 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 30_000_000)  // real-time: the resolver's detached write and the flow's main-actor hop
        for _ in 0..<40 { await Task.yield() }
    }

    private func children() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }

    func testAFinishedDropDeletesItsFolder() async {
        let flow = flow()
        var folder: URL?
        flow.onFiles = { _, made in folder = made }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        flow.start(DropDrag(image: DropImage(data: png, type: .png)))
        await settle()
        XCTAssertEqual(.ready, flow.phase)
        XCTAssertNotNil(folder)
        XCTAssertEqual(1, children().count)

        flow.settled()
        XCTAssertEqual(.idle, flow.phase)
        XCTAssertTrue(children().isEmpty)
    }

    func testACancelDuringAResolveDeletesTheFolder() async {
        let promise = FakePromise()
        promise.silent = true
        let flow = DropSourceFlow(root: root, promiseWait: 30)
        flow.start(DropDrag(promises: [promise]))
        XCTAssertEqual(.resolving, flow.phase)
        flow.cancelled()
        XCTAssertEqual(.cancelled, flow.phase)
        await settle()
        XCTAssertTrue(children().isEmpty)
    }

    func testASessionEndDuringAResolveDeletesTheFolder() async {
        let promise = FakePromise()
        promise.silent = true
        let flow = DropSourceFlow(root: root, promiseWait: 30)
        flow.start(DropDrag(promises: [promise]))
        flow.sessionEnded()
        XCTAssertEqual(.cancelled, flow.phase)
        await settle()
        XCTAssertTrue(children().isEmpty)
    }
}

final class DropScratchTests: XCTestCase {
    func testOnlyFoldersOlderThan24HoursAreSwept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = try DropScratch.makeFolder(in: root)
        let fresh = try DropScratch.makeFolder(in: root)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-25 * 60 * 60)], ofItemAtPath: old.path)

        DropScratch.sweep(in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(old.lastPathComponent.hasPrefix(DropScratch.prefix))
    }
}
