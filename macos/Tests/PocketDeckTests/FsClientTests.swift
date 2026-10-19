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
    private(set) var cancels: [UInt32] = []

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

    func fsCancel(id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        cancels.append(id)
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

    func testCancelSendsFsCancelAndDropsLaterFrames() throws {
        var result: Result<FsReadResult, FsError>?
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

    func testTheEtagRidesTheRead() throws {
        client.read(path: "a.bin", offset: 0, length: 1, etag: "0123456789abcdef0123456789abcdef",
                    to: out("out.bin")) { _ in }
        XCTAssertEqual("0123456789abcdef0123456789abcdef", channel.lastRead?.etag)
    }
}
