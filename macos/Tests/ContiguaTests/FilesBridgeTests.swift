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
@testable import Contigua

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
        write(BridgeWire.line(request))
    }

    func sendChunk(id: UInt32, bytes: [UInt8]) {
        var data = BridgeWire.dataHeader(id: id, length: bytes.count)
        data.append(contentsOf: bytes)
        write(data)
    }

    func sendRaw(_ text: String) {
        write(Data(text.utf8))
    }

    private func write(_ data: Data) {
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

    /// The app's watch pushes on this connection, if any.
    func signals() -> [[String]] {
        events.compactMap { if case .signal(let items) = $0 { return items } else { return nil } }
    }

    /// The peer goes away without a request (a killed extension process).
    func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
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
private final class StubSink: FilesWriteSink {
    var chunks: [[UInt8]] = []
    var finished = false
    var cancelled = false

    func append(_ bytes: [UInt8]) -> Bool {
        guard !cancelled else { return false }
        chunks.append(bytes)
        return true
    }

    func finish() { finished = true }
    func cancel() { cancelled = true }
}

/// One host watch call, comparable in the assertions.
@MainActor
private struct WatchCall: Equatable {
    var item: String
    var on: Bool
}

@MainActor
private final class StubBridgeHost: FilesBridgeHost {
    var isConnected = true
    var displayName: String? = "Nicky"
    var listResult: Result<(items: [FileItem], next: String?), FsError> = .success(([], nil))
    var statResult: Result<FileItem, FsError> = .failure(FsError(code: "fs_not_found"))
    var createResult: Result<FileItem, FsError>?
    /// A create that fails before any bytes can be ready for.
    var createRefusal: FsError?
    var modifyResult: Result<FileItem, FsError>?
    var deleteResult: Result<Void, FsError> = .success(())
    var cancels: [UInt32] = []
    var cancelAllCount = 0
    var creates: [BridgeCreate] = []
    var modifies: [BridgeModify] = []
    var deletes = 0
    var watches: [WatchCall] = []
    var watchError: FsError?
    var touched: [String] = []
    var onTouch: ((String) -> Void)?
    var changesReply = FilesChangesReply(anchor: "g0.ino:9", delta: .none, expired: false)
    var changeRequests: [(String, String?)] = []
    var changedPaths: [[String]] = []

    struct StubWrite {
        let sink: StubSink
        let completion: (Result<FileItem, FsError>) -> Void
    }
    var write: StubWrite?

    /// Manual reads stay open until the test cancels or finishes them.
    struct PendingRead {
        let id: UInt32
        let chunk: ([UInt8]) -> Bool
        let completion: (Result<FsReadResult, FsError>) -> Void
    }
    var pending: [PendingRead] = []
    var nextID: UInt32 = 100

    /// Thumbnails stay open until the test finishes them.
    struct PendingThumb {
        let id: UInt32
        let item: String
        let size: Int
        let completion: (Result<FilesThumb, FsError>) -> Void
    }
    var pendingThumbs: [PendingThumb] = []
    var thumbItems: [String] = []

    func thumb(item: String, size: Int,
               onStart: @escaping (UInt32) -> Void,
               completion: @escaping (Result<FilesThumb, FsError>) -> Void) {
        let id = nextID
        nextID += 1
        onStart(id)
        thumbItems.append(item)
        pendingThumbs.append(PendingThumb(id: id, item: item, size: size, completion: completion))
    }

    func finishThumb(_ index: Int, _ result: Result<FilesThumb, FsError>) {
        pendingThumbs[index].completion(result)
    }

    func list(item: String, page: String?,
              completion: @escaping (Result<(items: [FileItem], next: String?), FsError>) -> Void) {
        completion(listResult)
    }

    func stat(item: String, completion: @escaping (Result<FileItem, FsError>) -> Void) {
        completion(statResult)
    }

    func streamRead(item: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        let id = nextID
        nextID += 1
        onStart(id)
        pending.append(PendingRead(id: id, chunk: chunk, completion: completion))
    }

    func create(_ request: BridgeCreate,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        creates.append(request)
        if let refusal = createRefusal {
            ready(nil)
            return completion(.failure(refusal))
        }
        if request.dir {
            ready(nil)
            completion(createResult ?? .failure(FsError(code: "fs_denied")))
            return
        }
        let sink = StubSink()
        write = StubWrite(sink: sink, completion: completion)
        ready(sink)
    }

    func modify(_ request: BridgeModify,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        modifies.append(request)
        if request.hasContent {
            let sink = StubSink()
            write = StubWrite(sink: sink, completion: completion)
            ready(sink)
            return
        }
        ready(nil)
        completion(modifyResult ?? .failure(FsError(code: "fs_denied")))
    }

    func delete(item: String, base: String, recursive: Bool,
                completion: @escaping (Result<Void, FsError>) -> Void) {
        deletes += 1
        completion(deleteResult)
    }

    /// The real host sends `fs.watch` only for the first touch of a folder.
    private var phoneWatched: Set<String> = []

    func touch(item: String, completion: @escaping (Result<Void, FsError>) -> Void) {
        touched.append(item)
        if phoneWatched.insert(item).inserted {
            watches.append(WatchCall(item: item, on: true))
        }
        if let error = watchError { return completion(.failure(error)) }
        completion(.success(()))
    }

    func unwatch(item: String, completion: @escaping (Result<Void, FsError>) -> Void) {
        if phoneWatched.remove(item) != nil {
            watches.append(WatchCall(item: item, on: false))
        }
        if let error = watchError { return completion(.failure(error)) }
        completion(.success(()))
    }

    func changes(item: String, from: String?,
                 completion: @escaping (Result<FilesChangesReply, FsError>) -> Void) {
        changeRequests.append((item, from))
        completion(.success(changesReply))
    }

    func anchor(item: String, completion: @escaping (Result<String, FsError>) -> Void) {
        completion(.success(changesReply.anchor))
    }

    func filesChanged(paths: [String]) {
        changedPaths.append(paths)
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

    private func fsItem(_ name: String, ino: Int = 9, dir: Bool = false) -> FsItem {
        FsItem(name: name, dir: dir, size: dir ? 0 : 3, mtime: 5, ino: ino, etag: "aa")
    }

    private func fileItem(_ name: String, ino: Int = 9, dir: Bool = false) -> FileItem {
        FilesMap.item(path: name, parentIdentifier: FilesMap.rootIdentifier,
                      fs: fsItem(name, ino: ino, dir: dir))
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
        client.send(.list(id: 1, item: FilesMap.rootIdentifier, page: nil))
        client.send(.stat(id: 2, item: "ino:1"))
        client.send(.read(id: 3, item: "ino:1", offset: 0, length: 4, etag: nil))
        client.send(.delete(id: 4, item: "ino:1", base: "aa", recursive: false))
        XCTAssertTrue(pump { client.replies().count == 4 })
        XCTAssertEqual([.error(id: 1, code: "offline"),
                        .error(id: 2, code: "offline"),
                        .error(id: 3, code: "offline"),
                        .error(id: 4, code: "offline")], client.replies())
    }

    func testListAndStatForwardTheAnswers() throws {
        try start()
        bridge.attach(host: host)
        let listed = fileItem("DCIM", ino: 9, dir: true)
        let stated = fileItem("a.txt", ino: 10)
        host.listResult = .success(([listed], "40"))
        host.statResult = .success(stated)
        let client = try connect()
        client.send(.list(id: 1, item: FilesMap.rootIdentifier, page: nil))
        client.send(.stat(id: 2, item: "ino:10"))
        XCTAssertTrue(pump { client.replies().count == 2 })
        host.listResult = .failure(FsError(code: "fs_denied"))
        client.send(.list(id: 3, item: "ino:99", page: nil))
        XCTAssertTrue(pump { client.replies().count == 3 })
        XCTAssertEqual([.items(id: 1, page: "40", items: [listed]),
                        .item(id: 2, item: stated),
                        .error(id: 3, code: "fs_denied")], client.replies())
    }

    func testAReadStreamsDataThenEnd() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.read(id: 7, item: "ino:1", offset: 0, length: 5, etag: nil))
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
        client.send(.read(id: 7, item: "ino:1", offset: 0, length: 32, etag: nil))
        XCTAssertTrue(pump { host.pending.count == 1 })
        let read = try XCTUnwrap(host.pending.first)
        _ = read.chunk([1, 2, 3])
        client.send(.cancel(id: 7))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([read.id], host.cancels)
        XCTAssertEqual([.error(id: 7, code: "cancelled")], client.replies())
        // The next request on the same client still works.
        host.listResult = .success(([], nil))
        client.send(.list(id: 8, item: FilesMap.rootIdentifier, page: nil))
        XCTAssertTrue(pump { client.replies().count == 2 })
        XCTAssertEqual(.items(id: 8, page: nil, items: []), client.replies().last)
    }

    func testACreateAnswersReadyThenTakesTheDataThenTheItem() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        let request = BridgeCreate(parent: FilesMap.rootIdentifier, name: "new.bin", dir: false,
                                   size: 4, sha256: String(repeating: "a", count: 64))
        client.send(.create(id: 11, request: request))
        XCTAssertTrue(pump { host.write != nil && client.replies() == [.ready(id: 11)] })
        XCTAssertEqual(request, host.creates.first)
        client.sendChunk(id: 11, bytes: [1, 2])
        client.sendChunk(id: 11, bytes: [3, 4])
        XCTAssertTrue(pump { host.write?.sink.chunks.count == 2 })
        XCTAssertEqual([[1, 2], [3, 4]], host.write?.sink.chunks)
        let made = fileItem("new.bin", ino: 77)
        host.write?.completion(.success(made))
        XCTAssertTrue(pump { client.replies().count == 2 })
        XCTAssertEqual([.ready(id: 11), .item(id: 11, item: made)], client.replies())
    }

    func testACreateRefusalNeverAsksForData() throws {
        try start()
        bridge.attach(host: host)
        host.createRefusal = FsError(code: "fs_not_found")
        let client = try connect()
        client.send(.create(id: 12, request: BridgeCreate(parent: "ino:404", name: "x", dir: false,
                                                          size: 1, sha256: String(repeating: "b", count: 64))))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertNil(host.write)
        XCTAssertEqual([.error(id: 12, code: "fs_not_found")], client.replies())
    }

    func testAFolderCreateAnswersTheItemWithoutData() throws {
        try start()
        bridge.attach(host: host)
        host.createResult = .success(fileItem("Folder", ino: 88, dir: true))
        let client = try connect()
        client.send(.create(id: 13, request: BridgeCreate(parent: FilesMap.rootIdentifier,
                                                          name: "Folder", dir: true,
                                                          size: 0, sha256: nil)))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual(1, host.creates.count)
        XCTAssertEqual(0, client.dataChunks(id: 13).count)
        XCTAssertEqual([.item(id: 13, item: fileItem("Folder", ino: 88, dir: true))], client.replies())
    }

    func testAModifyWithContentStreamsItsData() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        let request = BridgeModify(item: "ino:9", base: "aa", content: true, name: nil,
                                   parent: nil, mtime: nil, size: 2,
                                   sha256: String(repeating: "c", count: 64))
        client.send(.modify(id: 14, request: request))
        XCTAssertTrue(pump { host.write != nil && client.replies() == [.ready(id: 14)] })
        client.sendChunk(id: 14, bytes: [9, 8])
        XCTAssertTrue(pump { host.write?.sink.chunks == [[9, 8]] })
        let updated = fileItem("a.txt", ino: 9)
        host.write?.completion(.success(updated))
        XCTAssertTrue(pump { client.replies().count == 2 })
        XCTAssertEqual([.ready(id: 14), .item(id: 14, item: updated)], client.replies())
    }

    func testCancelOfAWriteCancelsTheSink() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.create(id: 15, request: BridgeCreate(parent: FilesMap.rootIdentifier,
                                                          name: "x", dir: false, size: 8,
                                                          sha256: String(repeating: "d", count: 64))))
        XCTAssertTrue(pump { host.write != nil && client.replies() == [.ready(id: 15)] })
        client.send(.cancel(id: 15))
        XCTAssertTrue(pump { host.write?.sink.cancelled == true })
    }

    func testDeleteAnswersOk() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.delete(id: 16, item: "ino:9", base: "aa", recursive: true))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual(1, host.deletes)
        XCTAssertEqual([.ok(id: 16)], client.replies())
    }

    func testAtMostEightLiveIdsPerClient() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        for id in UInt32(1)...UInt32(8) {
            client.send(.read(id: id, item: "ino:1", offset: 0, length: 32, etag: nil))
        }
        XCTAssertTrue(pump { host.pending.count == 8 })
        client.send(.read(id: 9, item: "ino:1", offset: 0, length: 32, etag: nil))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([.error(id: 9, code: "busy")], client.replies())
        // Finishing one id frees a slot.
        let first = try XCTUnwrap(host.pending.first)
        first.completion(.success(FsReadResult(bytes: 0, sha256: "e3b0c442")))
        XCTAssertTrue(pump { client.replies().count == 2 })
        client.send(.read(id: 10, item: "ino:1", offset: 0, length: 1, etag: nil))
        XCTAssertTrue(pump { host.pending.count == 9 })
        XCTAssertEqual(9, host.pending.count)
    }

    func testAtMostSixClients() throws {
        try start()
        bridge.attach(host: host)
        var accepted: [BridgeTestClient] = []
        for index in UInt32(1)...UInt32(FilesBridgeListener.maxClients) {
            let client = try connect()
            client.send(.hello(id: index, version: filesBridgeVersion))
            accepted.append(client)
        }
        XCTAssertTrue(pump { accepted.allSatisfy { !$0.replies().isEmpty } })
        let extra = try connect()
        XCTAssertTrue(pump { extra.closed })
        XCTAssertTrue(extra.events.isEmpty)
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
        client.send(.read(id: 4, item: "ino:1", offset: 0, length: 9, etag: nil))
        XCTAssertTrue(pump { host.pending.count == 1 })
        let id = try XCTUnwrap(host.pending.first?.id)
        client.sendRaw("")   // nothing; close through stop below
        Darwin.close(client.fd)
        XCTAssertTrue(pump { host.cancels == [id] })
    }

    // MARK: The watch set (design "S5 round 3")

    func testATouchAsksThePhoneOnceAndARepeatedOneNothing() throws {
        try start()
        bridge.attach(host: host)
        let a = try connect()
        let b = try connect()
        a.send(.watch(id: 1, items: ["ino:9"], on: true))
        XCTAssertTrue(pump { a.replies().count == 1 })
        XCTAssertEqual([.ok(id: 1)], a.replies())
        // A second extension process touches the same folder: the phone is
        // told once (a second `fs.watch` would be idempotent, but pointless).
        b.send(.watch(id: 1, items: ["ino:9"], on: true))
        XCTAssertTrue(pump { b.replies().count == 1 })
        XCTAssertEqual(["ino:9", "ino:9"], host.touched, "both processes touched it")
        XCTAssertEqual([WatchCall(item: "ino:9", on: true)], host.watches,
                       "the phone was told once")

        // Closing the enumerator stops the pushes but not the phone's watch.
        a.send(.watch(id: 2, items: ["ino:9"], on: false))
        XCTAssertTrue(pump { a.replies().count == 2 })
        XCTAssertEqual([WatchCall(item: "ino:9", on: true)], host.watches)
    }

    func testAClientGoingAwayKeepsItsFoldersWatched() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.watch(id: 1, items: ["ino:9", FilesMap.rootIdentifier], on: true))
        XCTAssertTrue(pump { client.replies().count == 1 })
        XCTAssertEqual(2, host.watches.count)
        // A killed extension process is not the end of the ten minutes.
        client.shutdown()
        for _ in 0..<50 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertEqual(["ino:9", FilesMap.rootIdentifier], host.watches.map(\.item),
                       "no unwatch from a dead client")
        XCTAssertEqual([true, true], host.watches.map(\.on))
    }

    func testAFolderIsUnwatchedWhenItsTenMinutesAreOver() throws {
        try start()
        var now: TimeInterval = 1000
        bridge.watchClock = { now }
        bridge.attach(host: host)
        let client = try connect()
        client.send(.watch(id: 1, items: ["ino:9"], on: true))
        XCTAssertTrue(pump { client.replies().count == 1 })
        now += 599
        bridge.expireWatches()
        XCTAssertEqual([WatchCall(item: "ino:9", on: true)], host.watches, "still inside the ten minutes")
        now += 2
        bridge.expireWatches()
        XCTAssertEqual([WatchCall(item: "ino:9", on: true), WatchCall(item: "ino:9", on: false)], host.watches)
    }

    func testTheSixtyFifthFolderDropsTheLeastRecentlyTouched() throws {
        try start()
        bridge.watchSet = FilesWatchSet(capacity: 2, ttl: 600)
        var now: TimeInterval = 1000
        bridge.watchClock = { now }
        bridge.attach(host: host)
        let client = try connect()
        for (index, item) in ["ino:1", "ino:2", "ino:3"].enumerated() {
            now += 1
            client.send(.watch(id: UInt32(index + 1), items: [item], on: true))
            XCTAssertTrue(pump { client.replies().count == index + 1 })
        }
        XCTAssertEqual(["ino:1", "ino:2", "ino:3"], host.touched)
        XCTAssertEqual(["ino:1", "ino:2", "ino:1", "ino:3"], host.watches.map(\.item))
        XCTAssertEqual([true, true, false, true], host.watches.map(\.on))
    }

    func testAWorkingSetIdentifierNeverTouchesThePhone() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.watch(id: 1, items: [filesWorkingSetIdentifier], on: true))
        XCTAssertTrue(pump { client.replies().count == 1 })
        XCTAssertEqual([.error(id: 1, code: "fs_not_found")], client.replies())
        XCTAssertTrue(host.watches.isEmpty)
    }

    func testASignalReachesOnlyTheWatchingClient() throws {
        try start()
        bridge.attach(host: host)
        let a = try connect()
        let b = try connect()
        a.send(.watch(id: 1, items: ["ino:9"], on: true))
        b.send(.watch(id: 1, items: ["ino:11"], on: true))
        XCTAssertTrue(pump { a.replies().count == 1 && b.replies().count == 1 })
        bridge.signal(containers: ["ino:9"])
        XCTAssertTrue(pump { !a.signals().isEmpty })
        XCTAssertEqual([["ino:9"]], a.signals())
        _ = b.poll()
        XCTAssertTrue(b.signals().isEmpty)
    }

    /// The extension that asked for the watch is short-lived: a phone-side
    /// change often arrives with no client connected, and the mount only moves
    /// because the app signals the working set itself (the one container a
    /// replicated extension may signal).
    func testASignalAsksTheWorkingSetEvenWithNoClientConnected() throws {
        try start()
        bridge.attach(host: host)
        var asked = 0
        bridge.signalWorkingSet = { asked += 1 }
        bridge.signal(containers: ["ino:9"])
        XCTAssertEqual(1, asked)
        bridge.signal(containers: [])
        XCTAssertEqual(1, asked, "an empty batch asks for nothing")
    }

    func testWorkingSetSignalsAreCoalescedToTwoASecond() throws {
        try start()
        bridge.attach(host: host)
        var now: TimeInterval = 1000
        bridge.watchClock = { now }
        var asked = 0
        bridge.signalWorkingSet = { asked += 1 }
        bridge.signal(containers: ["ino:9"])
        bridge.signal(containers: ["ino:9"])
        XCTAssertEqual(1, asked, "a burst in the same half second is one call")
        now += 0.6
        bridge.signal(containers: ["ino:9"])
        XCTAssertEqual(2, asked)
    }

    func testChangesAndAnchorForwardTheHostsAnswer() throws {
        try start()
        bridge.attach(host: host)
        let item = fileItem("a.txt")
        host.changesReply = FilesChangesReply(
            anchor: "w:e1:2", delta: FilesDelta(items: [item], deleted: ["ino:8"]),
            expired: false)
        let client = try connect()
        client.send(.changes(id: 1, item: filesWorkingSetIdentifier, from: "w:e1:1"))
        client.send(.anchor(id: 2, item: filesWorkingSetIdentifier))
        XCTAssertTrue(pump { client.replies().count == 2 })
        XCTAssertEqual([.changes(id: 1, anchor: "w:e1:2", items: [item],
                                 deleted: ["ino:8"], expired: false),
                        .anchor(id: 2, anchor: "w:e1:2")], client.replies())
        XCTAssertEqual(filesWorkingSetIdentifier, host.changeRequests.first?.0)
        XCTAssertEqual("w:e1:1", host.changeRequests.first?.1)
    }

    func testAnExpiredAnchorIsForwarded() throws {
        try start()
        bridge.attach(host: host)
        host.changesReply = FilesChangesReply(anchor: "w:e1:0", delta: .none, expired: true)
        let client = try connect()
        client.send(.changes(id: 1, item: "ino:9", from: "files-s3"))
        XCTAssertTrue(pump { client.replies().count == 1 })
        XCTAssertEqual([.changes(id: 1, anchor: "w:e1:0", items: [], deleted: [],
                                 expired: true)], client.replies())
    }

    func testStopRemovesTheSocket() throws {
        try start()
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    /// The Files switch turned off and on while the phone stays connected: the
    /// domain controller stops the socket and starts it again. The session
    /// attaches its host only when it becomes ready, so the restarted socket
    /// must still answer through it (the person, 2026-11-04: Finder stayed
    /// offline after an uncheck and a check).
    func testARestartedSocketStillAnswersThroughTheSessionsHost() throws {
        try start()
        host.displayName = "Nicky"
        bridge.attach(host: host)
        bridge.stop()
        try start()
        let client = try connect()
        client.send(.hello(id: 1, version: filesBridgeVersion))
        XCTAssertTrue(pump { client.replies().count == 1 })
        XCTAssertEqual([.hello(id: 1, version: filesBridgeVersion, name: "Nicky", connected: true)],
                       client.replies())
    }

    // MARK: Thumbnails (FILES-23/25/26/29, R-1)

    private let thumb = FilesThumb(data: [0xFF, 0xD8, 0xFF], mime: "image/jpeg", sha256: "ab")

    func testAThumbAnswersDataThenTheEnd() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.thumb(id: 7, item: "ino:1", size: 512))
        XCTAssertTrue(pump { host.pendingThumbs.count == 1 })
        XCTAssertEqual(["ino:1"], host.thumbItems)
        XCTAssertEqual(512, host.pendingThumbs.first?.size)
        host.finishThumb(0, .success(thumb))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([[0xFF, 0xD8, 0xFF]], client.dataChunks(id: 7))
        XCTAssertEqual([.thumb(id: 7, mime: "image/jpeg", size: 3, sha256: "ab")], client.replies())
    }

    func testAThumbFailureAnswersItsCode() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.thumb(id: 8, item: "ino:2", size: 512))
        XCTAssertTrue(pump { host.pendingThumbs.count == 1 })
        host.finishThumb(0, .failure(FsError(code: "fs_no_thumb")))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual([.error(id: 8, code: "fs_no_thumb")], client.replies())
        XCTAssertTrue(client.dataChunks(id: 8).isEmpty)
    }

    func testThumbRequestsQueueThreeAtATime() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        for id in 1...4 {
            client.send(.thumb(id: UInt32(id), item: "ino:\(id)", size: 512))
        }
        XCTAssertTrue(pump { host.pendingThumbs.count == 3 })
        Thread.sleep(forTimeInterval: 0.2) // real-time: a fourth thumb would land in this window
        XCTAssertEqual(3, host.pendingThumbs.count, "a fourth thumb reached the phone")
        host.finishThumb(0, .success(thumb))
        XCTAssertTrue(pump { host.pendingThumbs.count == 4 })
        XCTAssertEqual(["ino:1", "ino:2", "ino:3", "ino:4"], host.thumbItems)
    }

    func testACancelledQueuedThumbNeverReachesThePhone() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        for id in 1...4 {
            client.send(.thumb(id: UInt32(id), item: "ino:\(id)", size: 512))
        }
        XCTAssertTrue(pump { host.pendingThumbs.count == 3 })
        guard host.pendingThumbs.count == 3 else { return }
        client.send(.cancel(id: 4))
        XCTAssertTrue(pump { client.replies().count >= 1 })
        XCTAssertEqual([.error(id: 4, code: "cancelled")], client.replies())
        Thread.sleep(forTimeInterval: 0.2) // real-time: a fourth thumb would land in this window
        XCTAssertEqual(3, host.pendingThumbs.count)
        XCTAssertEqual([100, 101, 102], host.pendingThumbs.map { Int($0.id) })
    }

    func testACancelledRunningThumbSendsFsCancel() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.thumb(id: 5, item: "ino:5", size: 512))
        XCTAssertTrue(pump { host.pendingThumbs.count == 1 })
        guard !host.pendingThumbs.isEmpty else { return }
        client.send(.cancel(id: 5))
        XCTAssertTrue(pump { !client.replies().isEmpty })
        XCTAssertEqual(host.pendingThumbs.map(\.id), host.cancels)
        XCTAssertEqual([.error(id: 5, code: "cancelled")], client.replies())
    }

    func testAThumbPastTheDeadlineAnswersTimeoutAndCancels() throws {
        bridge.thumbDeadline = 0.05
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.thumb(id: 6, item: "ino:6", size: 512))
        guard pump(timeout: 2, { !client.replies().isEmpty }) else { return }
        XCTAssertEqual([.error(id: 6, code: "timeout")], client.replies())
        XCTAssertEqual(host.pendingThumbs.map(\.id), host.cancels)
    }

    func testAClosedClientCancelsItsThumb() throws {
        try start()
        bridge.attach(host: host)
        let client = try connect()
        client.send(.thumb(id: 9, item: "ino:9", size: 512))
        XCTAssertTrue(pump { host.pendingThumbs.count == 1 })
        guard let fsID = host.pendingThumbs.first?.id else { return XCTFail("no thumb") }
        client.shutdown()
        XCTAssertTrue(pump { host.cancels == [fsID] })
    }
}
