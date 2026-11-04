// The Mac side of read-only phone files (docs/PROTOCOL.md "Phone files"):
// request bookkeeping, chunk reassembly into a file, the SHA-256/size check,
// cancel, and frames for an unknown id. The fake channel is FsClient's whole
// network.

import CryptoKit
import Foundation
import XCTest
@testable import PocketDeck

private final class FakeFsChannel: FsChannel {
    struct Read: Equatable {
        var id: UInt32
        var path: String
        var offset: Int
        var length: Int
        var etag: String?
    }

    private let lock = NSLock()
    private(set) var lists: [(id: UInt32, path: String, page: String?)] = []
    private(set) var stats: [(id: UInt32, path: String)] = []
    private(set) var reads: [Read] = []
    private(set) var thumbs: [(id: UInt32, path: String, size: Int, etag: String?)] = []
    private(set) var cancels: [UInt32] = []
    private(set) var writes: [(id: UInt32, path: String, size: Int, sha256: String, etag: String?, exclusive: Bool)] = []
    private(set) var writeData: [(id: UInt32, bytes: [UInt8])] = []
    private(set) var moves: [(id: UInt32, from: String, to: String, etag: String?)] = []
    private(set) var deletes: [(id: UInt32, path: String, recursive: Bool, etag: String?)] = []
    private(set) var mkdirs: [(id: UInt32, path: String)] = []
    private(set) var setAttrs: [(id: UInt32, path: String, mtime: Int)] = []
    private(set) var watches: [(id: UInt32, paths: [String], on: Bool)] = []
    private(set) var digests: [(id: UInt32, paths: [String])] = []
    /// The session's write completions, held so a test decides when a chunk landed.
    private(set) var sends: [(Int, @Sendable (Bool) -> Void)] = []

    func fsList(id: UInt32, path: String, page: String?) {
        lock.lock(); defer { lock.unlock() }
        lists.append((id, path, page))
    }

    func fsStat(id: UInt32, path: String) {
        lock.lock(); defer { lock.unlock() }
        stats.append((id, path))
    }

    func fsRead(id: UInt32, path: String, offset: Int, length: Int, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        reads.append(Read(id: id, path: path, offset: offset, length: length, etag: etag))
    }

    func fsThumb(id: UInt32, path: String, size: Int, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        thumbs.append((id, path, size, etag))
    }

    func fsWrite(id: UInt32, path: String, size: Int, sha256: String, etag: String?,
                 exclusive: Bool) {
        lock.lock(); defer { lock.unlock() }
        writes.append((id, path, size, sha256, etag, exclusive))
    }

    func fsWriteData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        writeData.append((id, bytes))
        sends.append((bytes.count, sent))
        lock.unlock()
    }

    func fsMove(id: UInt32, from: String, to: String, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        moves.append((id, from, to, etag))
    }

    func fsDelete(id: UInt32, path: String, recursive: Bool, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        deletes.append((id, path, recursive, etag))
    }

    func fsMkdir(id: UInt32, path: String) {
        lock.lock(); defer { lock.unlock() }
        mkdirs.append((id, path))
    }

    func fsSetAttrs(id: UInt32, path: String, mtime: Int) {
        lock.lock(); defer { lock.unlock() }
        setAttrs.append((id, path, mtime))
    }

    func fsWatch(id: UInt32, paths: [String], on: Bool) {
        lock.lock(); defer { lock.unlock() }
        watches.append((id, paths, on))
    }

    func fsDigest(id: UInt32, paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        digests.append((id, paths))
    }

    func fsCancel(id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        cancels.append(id)
    }

    /// Confirms every chunk on the wire so far (the NIO event loop's callback).
    func landAll() {
        lock.lock()
        let pending = sends
        sends = []
        lock.unlock()
        for (_, sent) in pending { sent(true) }
    }

    var lastWriteID: UInt32? {
        lock.lock(); defer { lock.unlock() }
        return writes.last?.id
    }

    var lastRead: Read? {
        lock.lock(); defer { lock.unlock() }
        return reads.last
    }

    var lastListID: UInt32? {
        lock.lock(); defer { lock.unlock() }
        return lists.last?.id
    }

    var lastStatID: UInt32? {
        lock.lock(); defer { lock.unlock() }
        return stats.last?.id
    }
}

@MainActor
final class FsClientTests: XCTestCase {
    private var channel: FakeFsChannel!
    private var client: FsClient!
    private var directory: URL!

    override func setUp() async throws {
        channel = FakeFsChannel()
        client = FsClient(channel: channel)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketdeck-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        client.cancelAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func sha(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func out(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testChunksReassembleIntoTheFileAndTheHashMatches() throws {
        let bytes = [UInt8](repeating: 7, count: 1000)
        var result: Result<FsReadResult, FsError>?
        client.read(path: "a.bin", offset: 10, length: 1000, etag: nil, to: out("out.bin")) {
            result = $0
        }
        let read = try XCTUnwrap(channel.lastRead)
        XCTAssertEqual("a.bin", read.path)
        XCTAssertEqual(10, read.offset)
        XCTAssertEqual(1000, read.length)
        XCTAssertNil(read.etag)
        client.data(id: read.id, bytes: Array(bytes.prefix(300)))
        client.data(id: read.id, bytes: Array(bytes.dropFirst(300)))
        client.readEnd(id: read.id, size: 1000, sha256: sha(bytes))
        guard case .success(let done) = result else {
            return XCTFail("read failed: \(String(describing: result))")
        }
        XCTAssertEqual(1000, done.bytes)
        XCTAssertEqual(sha(bytes), done.sha256)
        XCTAssertEqual(bytes, [UInt8](try Data(contentsOf: out("out.bin"))))
    }

    func testAWholeFileReadStatsFirst() throws {
        var result: Result<FsReadResult, FsError>?
        client.read(path: "a.bin", offset: nil, length: nil, etag: nil, to: out("out.bin")) {
            result = $0
        }
        let statID = try XCTUnwrap(channel.lastStatID)
        XCTAssertEqual("a.bin", channel.stats.last?.path)
        client.item(id: statID, item: ["name": "a.bin", "dir": false, "size": 4,
                                       "mtime": 1, "ino": 2, "etag": "0123456789abcdef0123456789abcdef"])
        let read = try XCTUnwrap(channel.lastRead)
        XCTAssertEqual(0, read.offset)
        XCTAssertEqual(4, read.length)
        client.data(id: read.id, bytes: [1, 2, 3, 4])
        client.readEnd(id: read.id, size: 4, sha256: sha([1, 2, 3, 4]))
        guard case .success = result else { return XCTFail("read failed") }
    }

    func testAChecksumMismatchFailsAndRemovesTheFile() throws {
        var result: Result<FsReadResult, FsError>?
        client.read(path: "a.bin", offset: 0, length: 4, etag: nil, to: out("out.bin")) {
            result = $0
        }
        let read = try XCTUnwrap(channel.lastRead)
        client.data(id: read.id, bytes: [1, 2, 3, 4])
        client.readEnd(id: read.id, size: 4, sha256: sha([4, 3, 2, 1]))
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual("checksum", error.code)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out("out.bin").path))
    }

    func testAShortReadFails() throws {
        var result: Result<FsReadResult, FsError>?
        client.read(path: "a.bin", offset: 0, length: 10, etag: nil, to: out("out.bin")) {
            result = $0
        }
        let read = try XCTUnwrap(channel.lastRead)
        client.data(id: read.id, bytes: [1, 2])
        client.readEnd(id: read.id, size: 2, sha256: sha([1, 2]))
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual("checksum", error.code)
    }

    func testMoreBytesThanAnnouncedAreRefused() throws {
        var result: Result<FsReadResult, FsError>?
        client.read(path: "a.bin", offset: 0, length: 2, etag: nil, to: out("out.bin")) {
            result = $0
        }
        let read = try XCTUnwrap(channel.lastRead)
        client.data(id: read.id, bytes: [1, 2, 3])
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual("checksum", error.code)
        XCTAssertEqual([read.id], channel.cancels)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out("out.bin").path))
    }

    func testADigestReplyCarriesHexOrNotFound() {
        var result: Result<[String: FsDigestReply], FsError>?
        client.digest(paths: ["A", "B", "C"]) { result = $0 }
        let request = channel.digests.last
        XCTAssertEqual(["A", "B", "C"], request?.paths)

        client.digests(id: request?.id ?? 0,
                       values: ["A": "00112233445566778899aabbccddeeff",
                                "B": "not_found",
                                "C": "not a digest"])
        guard case .success(let values) = result else {
            return XCTFail("digest failed: \(String(describing: result))")
        }
        XCTAssertEqual(values["A"], .digest("00112233445566778899aabbccddeeff"))
        XCTAssertEqual(values["B"], .notFound)
        XCTAssertNil(values["C"], "a value that is neither is left for the folder's next touch")
    }

    func testAnUnknownDigestIsAFailureTheResyncCanRead() {
        var result: Result<[String: FsDigestReply], FsError>?
        client.digest(paths: ["A"]) { result = $0 }
        client.failure(id: channel.digests.last?.id ?? 0, code: "fs_unknown", message: nil)
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual("fs_unknown", error.code)
    }

    func testCancelSendsFsCancelAndDropsLaterFrames() throws {        var result: Result<FsReadResult, FsError>?
        client.read(path: "a.bin", offset: 0, length: 100, etag: nil, to: out("out.bin")) {
            result = $0
        }
        let read = try XCTUnwrap(channel.lastRead)
        client.data(id: read.id, bytes: [1, 2, 3])
        client.cancel(id: read.id)
        XCTAssertEqual([read.id], channel.cancels)
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual("cancelled", error.code)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out("out.bin").path))
        // Late frames for the abandoned id are dropped, not delivered twice.
        client.data(id: read.id, bytes: [4, 5])
        client.readEnd(id: read.id, size: 5, sha256: sha([1, 2, 3, 4, 5]))
    }

    func testUnknownIdFramesAreDropped() {
        client.data(id: 999, bytes: [1])
        client.readEnd(id: 999, size: 1, sha256: sha([1]))
        client.items(id: 999, page: nil, items: [])
        client.item(id: 999, item: [:])
        client.failure(id: 999, code: "fs_denied", message: nil)
        XCTAssertTrue(channel.reads.isEmpty)
    }

    func testListPagesParseAndCarryTheCursor() throws {
        var page: FsPage?
        client.list(path: "", page: nil) { if case .success(let value) = $0 { page = value } }
        let id = try XCTUnwrap(channel.lastListID)
        XCTAssertEqual("", channel.lists.last?.path)
        XCTAssertNil(channel.lists.last?.page)
        client.items(id: id, page: "1000", items: [
            ["name": "DCIM", "dir": true, "size": 0, "mtime": 5, "ino": 9, "etag": "aaaa"],
            ["name": "a.txt", "dir": false, "size": 12, "mtime": 6, "ino": 10, "etag": "bbbb"],
        ])
        let result = try XCTUnwrap(page)
        XCTAssertEqual("1000", result.next)
        XCTAssertEqual(["DCIM", "a.txt"], result.items.map(\.name))
        XCTAssertEqual([true, false], result.items.map(\.dir))
        XCTAssertEqual([0, 12], result.items.map(\.size))
        XCTAssertEqual(["aaaa", "bbbb"], result.items.map(\.etag))
    }

    func testAnErrorFailsTheMatchingRequest() throws {
        var listError: FsError?
        client.list(path: "Android", page: nil) {
            if case .failure(let error) = $0 { listError = error }
        }
        let id = try XCTUnwrap(channel.lastListID)
        client.failure(id: id, code: "fs_denied", message: "denied: Android")
        XCTAssertEqual("fs_denied", listError?.code)
    }

    func testASessionEndFailsReadsAndRemovesPartials() throws {
        var result: Result<FsReadResult, FsError>?
        client.read(path: "a.bin", offset: 0, length: 100, etag: nil, to: out("out.bin")) {
            result = $0
        }
        let read = try XCTUnwrap(channel.lastRead)
        client.data(id: read.id, bytes: [1, 2])
        client.connectionLost()
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual("closed", error.code)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out("out.bin").path))
    }

    func testAWriteAnnouncesItsSizeAndHashThenPacesChunks() throws {
        let bytes = [UInt8](repeating: 7, count: 6 * 256 * 1024)
        let sha = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        var results: [Result<FsItem, FsError>] = []
        let sink = try XCTUnwrap(client.beginWrite(path: "DCIM/a.bin", size: bytes.count,
                                                   sha256: sha, etag: "old") { results.append($0) })
        let announced = try XCTUnwrap(channel.writes.first)
        XCTAssertEqual("DCIM/a.bin", announced.path)
        XCTAssertEqual(bytes.count, announced.size)
        XCTAssertEqual(sha, announced.sha256)
        XCTAssertEqual("old", announced.etag)
        XCTAssertFalse(announced.exclusive)
        XCTAssertTrue(sink.append(bytes))
        sink.finish()
        // At most four chunks in flight; each completion lets the next go.
        XCTAssertEqual(4, channel.writeData.count)
        channel.landAll()
        drain()
        XCTAssertEqual(6, channel.writeData.count)
        channel.landAll()
        drain()
        XCTAssertEqual(6, channel.writeData.count)
        // The phone answers with the new metadata.
        let item = FsItem(name: "a.bin", dir: false, size: bytes.count, mtime: 9, ino: 77, etag: "new")
        client.result(id: announced.id, ok: true, item: item.jsonObject, code: nil, message: nil)
        XCTAssertEqual([.success(item)], results)
    }

    func testACreateAnnouncesExclusive() throws {
        var results: [Result<FsItem, FsError>] = []
        _ = try XCTUnwrap(client.beginWrite(path: "new.bin", size: 1,
                                            sha256: String(repeating: "a", count: 64),
                                            etag: nil, exclusive: true) { results.append($0) })
        let announced = try XCTUnwrap(channel.writes.last)
        XCTAssertTrue(announced.exclusive)
        XCTAssertNil(announced.etag)
    }

    func testAWriteCancelSendsFsCancelAndFailsTheSink() throws {
        var results: [Result<FsItem, FsError>] = []
        let sink = try XCTUnwrap(client.beginWrite(path: "a.bin", size: 1024, sha256: String(repeating: "a", count: 64),
                                                   etag: nil) { results.append($0) })
        let id = try XCTUnwrap(channel.lastWriteID)
        sink.cancel()
        XCTAssertEqual([id], channel.cancels)
        guard case .failure(let error) = try XCTUnwrap(results.first) else {
            return XCTFail("no failure")
        }
        XCTAssertEqual("cancelled", error.code)
        // A phone answer for the abandoned id is dropped.
        client.result(id: id, ok: true, item: nil, code: nil, message: nil)
        XCTAssertEqual(1, results.count)
    }

    func testMutationsAnswerTheirResultItems() throws {
        var moved: Result<FsItem?, FsError>?
        client.move(from: "a.txt", to: "b.txt", etag: "e") { moved = $0 }
        let move = try XCTUnwrap(channel.moves.first)
        XCTAssertEqual("a.txt", move.from)
        let item = FsItem(name: "b.txt", dir: false, size: 1, mtime: 2, ino: 5, etag: "f")
        client.result(id: move.id, ok: true, item: item.jsonObject, code: nil, message: nil)
        XCTAssertEqual(.success(item), moved)

        var created: Result<FsItem?, FsError>?
        client.mkdir(path: "New") { created = $0 }
        let mkdir = try XCTUnwrap(channel.mkdirs.first)
        XCTAssertEqual("New", mkdir.path)
        client.result(id: mkdir.id, ok: true,
                      item: FsItem(name: "New", dir: true, size: 0, mtime: 3, ino: 6, etag: "g").jsonObject,
                      code: nil, message: nil)
        XCTAssertEqual("New", try created?.get()?.name)

        var deleted: Result<FsItem?, FsError>?
        client.delete(path: "New", recursive: true, etag: "e") { deleted = $0 }
        let del = try XCTUnwrap(channel.deletes.first)
        XCTAssertTrue(del.recursive)
        XCTAssertEqual("e", del.etag)
        client.result(id: del.id, ok: true, item: nil, code: nil, message: nil)
        XCTAssertEqual(.success(nil), deleted)
    }

    func testAMutationFailureCarriesThePhoneCode() throws {
        var result: Result<FsItem?, FsError>?
        client.setAttrs(path: "a.txt", mtime: 12) { result = $0 }
        let call = try XCTUnwrap(channel.setAttrs.first)
        client.result(id: call.id, ok: false, item: nil, code: "fs_stale", message: "changed")
        guard case .failure(let error) = try XCTUnwrap(result) else { return XCTFail("no failure") }
        XCTAssertEqual("fs_stale", error.code)
    }

    /// Lets the main queue run the write completions.
    private func drain() {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }

    func testTheEtagRidesTheRead() throws {
        client.read(path: "a.bin", offset: 0, length: 1, etag: "0123456789abcdef0123456789abcdef",
                    to: out("out.bin")) { _ in }
        XCTAssertEqual("0123456789abcdef0123456789abcdef", channel.lastRead?.etag)
    }
}
