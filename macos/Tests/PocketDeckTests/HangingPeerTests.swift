// The 20 s bug class (docs/design/files.md "Fixes 10-20"): a request ended with
// a terminal frame, but the reader waited for the socket's receive timeout
// before believing it. These tests give the reader a peer that answers and then
// keeps the connection open, and demand the answer within
// docs/NFR.md's `hanging_reply_ms`.
//
// Covered here: every terminal reply the bridge wire can carry (the decoder
// half), and every bridge request type answered by the real listener while the
// client holds its socket open (the app half). The extension's own read loop is
// compiled into the File Provider extension, not the test target; its timing is
// the VM's `files-domain` check. The Mac session's other reply paths (fs
// requests in FsClient, APK install, drops, clipboard images) are covered by
// their own K2 tests and e2e checks; they all answer from a terminal frame the
// session hands over, never from EOF.

import Foundation
import XCTest
@testable import PocketDeck

private final class HangingBridgeClient {
    let fd: Int32
    private var decoder = BridgeDecoder()
    private(set) var events: [BridgeEvent] = []

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                   socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    }

    deinit { Darwin.close(fd) }

    /// Sends a request and then never closes: the peer that keeps the socket
    /// open is the whole point.
    func send(_ request: BridgeRequest) {
        let data = BridgeWire.line(request)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1_000)
                } else {
                    return
                }
            }
        }
    }

    @discardableResult
    func poll() -> [BridgeEvent] {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                events += decoder.feed(Array(buffer[0..<count]))
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return events
            } else {
                return events
            }
        }
    }

    var replies: [BridgeReply] {
        events.compactMap { if case .reply(let reply) = $0 { return reply } else { return nil } }
    }
}

/// Answers every request the moment it arrives, like the live host does.
@MainActor
private final class AnsweringHost: FilesBridgeHost {
    var isConnected = true
    var displayName: String? = "NFR"
    var onTouch: ((String) -> Void)?

    private func makeItem(name: String) -> FileItem {
        FilesMap.item(path: name, parentIdentifier: FilesMap.rootIdentifier,
                      fs: FsItem(name: name, dir: false, size: 3, mtime: 5, ino: 9, etag: "aa"))
    }

    func list(item: String, page: String?,
              completion: @escaping (Result<(items: [FileItem], next: String?), FsError>) -> Void) {
        completion(.success(([self.makeItem(name: "a.txt")], nil)))
    }

    func stat(item: String, completion: @escaping (Result<FileItem, FsError>) -> Void) {
        completion(.success(makeItem(name: "a.txt")))
    }

    func thumb(item: String, size: Int,
               onStart: @escaping (UInt32) -> Void,
               completion: @escaping (Result<FilesThumb, FsError>) -> Void) {
        completion(.failure(FsError(code: "not_media")))
    }

    func streamRead(item: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        onStart(1)
        _ = chunk([1, 2, 3])
        completion(.success(FsReadResult(bytes: 3, sha256: "aa")))
    }

    func create(_ request: BridgeCreate, ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        ready(nil)
        completion(.success(makeItem(name: request.name)))
    }

    func modify(_ request: BridgeModify, ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        ready(nil)
        completion(.success(makeItem(name: "a.txt")))
    }

    func delete(item: String, base: String, recursive: Bool,
                completion: @escaping (Result<Void, FsError>) -> Void) {
        completion(.success(()))
    }

    func touch(item: String, completion: @escaping (Result<Void, FsError>) -> Void) {
        completion(.success(()))
    }

    func unwatch(item: String, completion: @escaping (Result<Void, FsError>) -> Void) {
        completion(.success(()))
    }

    func changes(item: String, from: String?,
                 completion: @escaping (Result<FilesChangesReply, FsError>) -> Void) {
        completion(.success(FilesChangesReply(anchor: "g0.ino:9", delta: .none, expired: false)))
    }

    func anchor(item: String, completion: @escaping (Result<String, FsError>) -> Void) {
        completion(.success("g0.ino:9"))
    }

    func filesChanged(paths: [String]) {}
    func cancel(id: UInt32) {}
    func cancelAll() {}
}

@MainActor
final class HangingPeerTests: XCTestCase {
    private var directory: URL!
    private var bridge: FilesBridge!
    private var socketPath: String!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: "/tmp/nfrh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("nfr.sock").path
        bridge = FilesBridge()
    }

    override func tearDown() async throws {
        bridge.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private var limit: TimeInterval {
        Double(NFRTestLimits.shared.int("hanging_reply_ms")) / 1000
    }

    /// Feeds exactly one frame and no EOF: the decoder must hand the terminal
    /// event to its loop now, not wait for a read that never returns.
    func testEveryTerminalReplyIsDecodedFromOneFrameWithoutEOF() {
        let replies: [(String, BridgeReply)] = [
            ("hello", .hello(id: 1, version: filesBridgeVersion, name: "NFR", connected: true)),
            ("list", .items(id: 2, page: nil, items: [])),
            ("stat", .item(id: 3, item: FilesMap.item(
                path: "a", parentIdentifier: FilesMap.rootIdentifier,
                fs: FsItem(name: "a", dir: false, size: 1, mtime: 1, ino: 1, etag: "aa")))),
            ("read end", .end(id: 4, size: 3, sha256: "aa")),
            ("create", .ok(id: 5)),
            ("modify", .ok(id: 6)),
            ("delete", .ok(id: 7)),
            ("change content", .ready(id: 8)),
            ("error", .error(id: 9, code: "fs_offline")),
            ("changes", .changes(id: 10, anchor: "g0", items: [], deleted: [], expired: false)),
            ("anchor", .anchor(id: 11, anchor: "g0")),
        ]
        for (name, reply) in replies {
            var decoder = BridgeDecoder()
            let events = decoder.feed(Array(BridgeWire.line(reply)))
            XCTAssertEqual(events, [.reply(reply)], "\(name): one frame must yield its terminal event")
        }
    }

    /// The real listener answers each request while the client keeps the
    /// socket open and never sends another byte.
    func testEveryBridgeRequestIsAnsweredWhileThePeerHoldsTheSocket() throws {
        XCTAssertEqual("ok", bridge.start(path: socketPath))
        bridge.attach(host: AnsweringHost())
        let client = try XCTUnwrap(HangingBridgeClient(path: socketPath))

        func ask(_ name: String, _ request: BridgeRequest,
                 terminal: (BridgeReply) -> Bool) {
            let before = client.replies.count
            let started = Date()
            client.send(request)
            var answered = false
            while Date().timeIntervalSince(started) < limit * 5 {
                client.poll()
                if client.replies.count > before, terminal(client.replies[before]) {
                    answered = true
                    break
                }
                // The listener hands a request to the main actor; a busy loop
                // here would starve that hand-off and time the test's own
                // block, not the bridge's answer.
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            }
            let took = Date().timeIntervalSince(started)
            XCTAssertTrue(answered, "\(name): no terminal reply while the peer kept the socket open")
            XCTAssertLessThanOrEqual(took, limit, "\(name): reply took \(Int(took * 1000)) ms")
        }

        // The poll above may run longer than the limit only to produce a good
        // failure message; the assertion is the file's `hanging_reply_ms`.
        ask("hello", .hello(id: 1, version: filesBridgeVersion)) {
            if case .hello = $0 { return true }; return false
        }
        ask("list", .list(id: 2, item: FilesMap.rootIdentifier, page: nil)) {
            if case .items = $0 { return true }; return false
        }
        ask("stat", .stat(id: 3, item: "x")) {
            if case .item = $0 { return true }; return false
        }
        ask("read", .read(id: 4, item: "x", offset: 0, length: 3, etag: nil)) {
            if case .end = $0 { return true }; return false
        }
        ask("create", .create(id: 5, request: BridgeCreate(
            parent: FilesMap.rootIdentifier, name: "a.txt", dir: false, size: 0, sha256: nil))) {
            if case .item = $0 { return true }; return false
        }
        ask("modify", .modify(id: 6, request: BridgeModify(
            item: "x", base: "aa", content: false, name: "b.txt", parent: nil,
            mtime: nil, size: 0, sha256: nil))) {
            if case .item = $0 { return true }; return false
        }
        ask("delete", .delete(id: 7, item: "x", base: "aa", recursive: false)) {
            if case .ok = $0 { return true }; return false
        }
        ask("watch", .watch(id: 8, items: [FilesMap.rootIdentifier], on: true)) {
            if case .ok = $0 { return true }; return false
        }
        ask("changes", .changes(id: 9, item: FilesMap.rootIdentifier, from: nil)) {
            if case .changes = $0 { return true }; return false
        }
        ask("anchor", .anchor(id: 10, item: FilesMap.rootIdentifier)) {
            if case .anchor = $0 { return true }; return false
        }
        // `cancel` carries no reply by design: it ends a read or a write that
        // already has its own terminal frame.
    }
}
