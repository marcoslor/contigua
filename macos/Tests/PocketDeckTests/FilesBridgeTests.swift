// The app bridge's lifecycle (FilesBridge.swift): a listener on a temporary
// directory, a raw client speaking FilesCore's wire, a stub host in place of
// the session. No FileProvider is involved anywhere.
//
// The peer-uid check is exercised on the accepting side (a client of this user
// is accepted); a different uid cannot be played from inside the test process,
// so the rejection branch is covered by reading the code and by the real
// extension in the VM.

import Foundation
import XCTest
@testable import PocketDeck

private final class BridgeTestClient {
    let fd: Int32
    private var decoder = BridgeDecoder()
    private(set) var events: [BridgeEvent] = []
    private(set) var closed = false

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
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit { Darwin.close(fd) }

    func send(_ request: BridgeRequest) {
        let data = BridgeWire.line(request)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.write(fd, base, raw.count)
        }
    }

    func sendRaw(_ text: String) {
        let data = Data(text.utf8)
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

    /// Reads whatever is there without blocking; a pump loop calls this.
    @discardableResult
    func poll() -> [BridgeEvent] {
        guard !closed else { return [] }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                events += decoder.feed(Array(buffer[0..<count]))
            } else if count == 0 {
                closed = true
                return events
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return events
            } else if errno == EINTR {
                continue
            } else {
                closed = true
                return events
            }
        }
    }

    func replies() -> [BridgeReply] {
        events.compactMap { if case .reply(let reply) = $0 { return reply } else { return nil } }
    }

    func dataChunks(id: UInt32) -> [[UInt8]] {
        events.compactMap {
            if case .data(let eventID, let bytes) = $0, eventID == id { return bytes }
            return nil
        }
    }

    var dataHeaders: [(id: UInt32, length: Int)] {
        events.compactMap {
            if case .dataHeader(let id, let length) = $0 { return (id, length) }
            return nil
        }
    }
}

/// Stands in for the session: answers are decided by the test.
@MainActor
private final class StubBridgeHost: FilesBridgeHost {
    var isConnected = true
    var displayName: String? = "Nicky"
    var listResult: Result<FsPage, FsError> = .success(FsPage(items: [], next: nil))
    var statResult: Result<FsItem, FsError> = .failure(FsError(code: "fs_not_found"))
    var cancels: [UInt32] = []
    var cancelAllCount = 0

    /// Manual reads stay open until the test cancels or finishes them.
    struct PendingRead {
        let id: UInt32
        let chunk: ([UInt8]) -> Bool
        let completion: (Result<FsReadResult, FsError>) -> Void
    }
    var pending: [PendingRead] = []
    var nextID: UInt32 = 100

    func list(path: String, page: String?, completion: @escaping (Result<FsPage, FsError>) -> Void) {
        completion(listResult)
    }

    func stat(path: String, completion: @escaping (Result<FsItem, FsError>) -> Void) {
        completion(statResult)
    }

    func streamRead(path: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        let id = nextID
        nextID += 1
        onStart(id)
        pending.append(PendingRead(id: id, chunk: chunk, completion: completion))
    }

    func cancel(id: UInt32) {
        cancels.append(id)
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let read = pending.remove(at: index)
        read.completion(.failure(FsError(code: "cancelled")))
    }

    func cancelAll() { cancelAllCount += 1 }
}

@MainActor
final class FilesBridgeTests: XCTestCase {
    private var directory: URL!
    private var bridge: FilesBridge!
    private var host: StubBridgeHost!
    private var socketPath: String!
    private var clients: [BridgeTestClient] = []

    override func setUp() async throws {
        // A short path: sun_path is 104 bytes and the temporary directory's
        // real path is already long.
        directory = URL(fileURLWithPath: "/tmp/pdb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("files-test.sock").path
        bridge = FilesBridge()
        host = StubBridgeHost()
    }

    override func tearDown() async throws {
        for client in clients { _ = client.poll() }
        clients = []
        bridge.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func connect() throws -> BridgeTestClient {
        let client = try XCTUnwrap(BridgeTestClient(path: socketPath), "connect failed")
        clients.append(client)
        return client
    }

    private func start() throws {
        XCTAssertEqual("ok", bridge.start(path: socketPath))
        XCTAssertEqual(socketPath, bridge.socketPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    /// Pumps the run loop (and with it the main queue) until `done` is true.
    private func pump(timeout: TimeInterval = 3, _ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for client in clients { client.poll() }
            if done() { return true }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        for client in clients { client.poll() }
        return done()
    }

    func testTheSocketIsPrivateAndTheListenerServes() throws {
        try start()
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual(0o600, (attributes[.posixPermissions] as? NSNumber)?.intValue)
        let client = try connect()
        client.send(.hello(id: 1, version: filesBridgeVersion))
        XCTAssertTrue(pump { client.replies().count == 1 })
        XCTAssertEqual([.hello(id: 1, version: filesBridgeVersion, name: nil, connected: false)],
                       client.replies())
    }

    func testHelloAnswersThePhoneWhenTheSessionIsUp() throws {
        try start()
        host.displayName = "Nicky"
        bridge.attach(host: host)
        let client = try connect()
        client.send(.hello(id: 1, version: filesBridgeVersion))
        XCTAssertTrue(pump { client.replies().count == 1 })
        XCTAssertEqual([.hello(id: 1, version: filesBridgeVersion, name: "Nicky", connected: true)],
                       client.replies())
        bridge.detach()
        XCTAssertEqual(1, host.cancelAllCount)
        let second = try connect()
        second.send(.hello(id: 2, version: filesBridgeVersion))
        XCTAssertTrue(pump { second.replies().count == 1 })
        XCTAssertEqual([.hello(id: 2, version: filesBridgeVersion, name: nil, connected: false)],
                       second.replies())
    }

    func testABadVersionIsRefused() throws {
        try start()
        let client = try connect()
        client.send(.hello(id: 1, version: 99))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([.error(id: 1, code: "bad_version")], client.replies())
    }

    func testRequestsAnswerOfflineWithoutASession() throws {
        try start()
        let client = try connect()
        client.send(.list(id: 1, path: "", page: nil))
        client.send(.stat(id: 2, path: "a"))
        client.send(.read(id: 3, path: "a", offset: 0, length: 4, etag: nil))
        XCTAssertTrue(pump { client.replies().count == 3 })
        XCTAssertEqual([.error(id: 1, code: "offline"),
                        .error(id: 2, code: "offline"),
                        .error(id: 3, code: "offline")], client.replies())
    }

    func testListAndStatForwardTheAnswers() throws {
        try start()
        bridge.attach(host: host)
        host.listResult = .success(FsPage(
            items: [FsItem(name: "DCIM", dir: true, size: 0, mtime: 5, ino: 9, etag: "aa")],
            next: "40"))
        host.statResult = .success(FsItem(name: "a.txt", dir: false, size: 3,
                                          mtime: 6, ino: 10, etag: "bb"))
        let client = try connect()
        client.send(.list(id: 1, path: "", page: nil))
        client.send(.stat(id: 2, path: "a.txt"))
        XCTAssertTrue(pump { client.replies().count == 2 })
        host.listResult = .failure(FsError(code: "fs_denied"))
        client.send(.list(id: 3, path: "Android", page: nil))
        XCTAssertTrue(pump { client.replies().count == 3 })
        XCTAssertEqual([.items(id: 1, page: "40",
                               items: [FsItem(name: "DCIM", dir: true, size: 0,
                                              mtime: 5, ino: 9, etag: "aa")]),
                        .item(id: 2, item: FsItem(name: "a.txt", dir: false, size: 3,
                                                  mtime: 6, ino: 10, etag: "bb")),
                        .error(id: 3, code: "fs_denied")], client.replies())
    }

    func testAReadStreamsDataThenEnd() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.read(id: 7, path: "big.bin", offset: 0, length: 5, etag: nil))
        XCTAssertTrue(pump { host.pending.count == 1 })
        let read = try XCTUnwrap(host.pending.first)
        XCTAssertTrue(read.chunk([1, 2]))
        XCTAssertTrue(read.chunk([3, 4, 5]))
        read.completion(.success(FsReadResult(bytes: 5, sha256: "abc")))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([[1, 2], [3, 4, 5]], client.dataChunks(id: 7))
        XCTAssertEqual([2, 3], client.dataHeaders.map(\.length))
        XCTAssertEqual([7, 7], client.dataHeaders.map(\.id))
        XCTAssertEqual([.end(id: 7, size: 5, sha256: "abc")], client.replies())
    }

    func testCancelReachesThePhoneAndStopsTheStream() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.read(id: 7, path: "big.bin", offset: 0, length: 32, etag: nil))
        XCTAssertTrue(pump { host.pending.count == 1 })
        let read = try XCTUnwrap(host.pending.first)
        _ = read.chunk([1, 2, 3])
        client.send(.cancel(id: 7))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([read.id], host.cancels)
        XCTAssertEqual([.error(id: 7, code: "cancelled")], client.replies())
        // The next request on the same client still works.
        host.listResult = .success(FsPage(items: [], next: nil))
        client.send(.list(id: 8, path: "", page: nil))
        XCTAssertTrue(pump { client.replies().count == 2 })
        XCTAssertEqual(.items(id: 8, page: nil, items: []), client.replies().last)
    }

    func testAtMostEightLiveIdsPerClient() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        for id in UInt32(1)...UInt32(8) {
            client.send(.read(id: id, path: "big.bin", offset: 0, length: 32, etag: nil))
        }
        XCTAssertTrue(pump { host.pending.count == 8 })
        client.send(.read(id: 9, path: "big.bin", offset: 0, length: 32, etag: nil))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([.error(id: 9, code: "busy")], client.replies())
        // Finishing one id frees a slot.
        let first = try XCTUnwrap(host.pending.first)
        first.completion(.success(FsReadResult(bytes: 0, sha256: "e3b0c442")))
        XCTAssertTrue(pump { client.replies().count == 2 })
        client.send(.read(id: 10, path: "big.bin", offset: 0, length: 1, etag: nil))
        XCTAssertTrue(pump { host.pending.count == 9 })
        XCTAssertEqual(9, host.pending.count)
    }

    func testAtMostFourClients() throws {
        try start()
        bridge.attach(host: host)
        var accepted: [BridgeTestClient] = []
        for index in UInt32(1)...UInt32(4) {
            let client = try connect()
            client.send(.hello(id: index, version: filesBridgeVersion))
            accepted.append(client)
        }
        XCTAssertTrue(pump { accepted.allSatisfy { !$0.replies().isEmpty } })
        let fifth = try connect()
        XCTAssertTrue(pump { fifth.closed })
        XCTAssertTrue(fifth.events.isEmpty)
    }

    func testAMalformedLineEndsTheClient() throws {
        try start()
        let client = try connect()
        client.sendRaw("not json\n")
        XCTAssertTrue(pump { client.closed })
    }

    func testAnOversizedLineEndsTheClient() throws {
        try start()
        let client = try connect()
        client.sendRaw(String(repeating: "A", count: BridgeWire.maxLineBytes + 1))
        XCTAssertTrue(pump { client.closed })
    }

    func testAClosedClientCancelsItsReads() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.read(id: 4, path: "a.bin", offset: 0, length: 9, etag: nil))
        XCTAssertTrue(pump { host.pending.count == 1 })
        let id = try XCTUnwrap(host.pending.first?.id)
        client.sendRaw("")   // nothing; close through stop below
        Darwin.close(client.fd)
        XCTAssertTrue(pump { host.cancels == [id] })
    }

    func testStopRemovesTheSocket() throws {
        try start()
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}
