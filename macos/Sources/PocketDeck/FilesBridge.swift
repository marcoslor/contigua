// The app side of phone files in Finder (docs/design/files.md §1, §3, §4): a
// UNIX-domain socket in the App Group container that the sandboxed File
// Provider extension asks for listings, stats, file bytes and writes. The app
// owns the one phone session, so the extension never dials the phone, and the
// app owns the id ↔ path map, so an identifier resolves in any extension
// process (and after a restart).
//
// The wire is FilesCore's: newline-delimited JSON with an `id`, then for a
// transfer a `data` header and exactly that many raw bytes. Reads flow app →
// extension; a create/modify answers `ready` first and the extension's bytes
// flow the other way, paced by the write sink. Nothing that crosses this socket
// is logged with a name, a path or a byte value: op names, counts, lengths and
// codes only (design §4).

import Foundation
import os

/// Where the socket lives: the App Group container (the real thing) or a test
/// directory (`--files-bridge-dir`). The file name carries the profile so two
/// profiles never meet on one socket.
enum FilesSocket {
    static let infoPlistKey = "PDFilesGroup"

    /// bundle.sh writes the group id into the Info.plist; a bare `swift run`
    /// build has none and the bridge simply is not started.
    static func groupIdentifier(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
              !value.isEmpty else { return nil }
        return value
    }

    static func fileName(profile: Profile) -> String {
        profile.isDefault ? "files.sock" : "files-\(profile.name).sock"
    }

    /// The socket path in the group container, when the app carries a group.
    static func groupPath(profile: Profile, bundle: Bundle = .main) -> String? {
        guard let group = groupIdentifier(bundle: bundle),
              let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appendingPathComponent(fileName(profile: profile)).path
    }
}

/// How many write bytes one client may have in flight before the bridge stops
/// reading its socket: the drop rule's 1 MiB (§3). The reader thread blocks and
/// the extension's own write blocks on TCP, so nothing buffers the file here.
final class FilesWriteFlow: @unchecked Sendable {
    static let maxQueuedBytes = 1 << 20
    private let lock = NSLock()
    private var pending = 0

    /// Reserves room for one chunk; false when the budget is spent.
    func reserve(_ bytes: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending + bytes <= Self.maxQueuedBytes else { return false }
        pending += bytes
        return true
    }

    func release(_ bytes: Int) {
        lock.lock()
        pending = max(0, pending - bytes)
        lock.unlock()
    }
}

/// One accepted client. Reads happen on its own queue (blocking recv); writes
/// are serialized by a lock and may come from the main actor.
final class FilesBridgeClient: @unchecked Sendable {
    let fd: Int32
    let flow = FilesWriteFlow()
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }

    func send(_ reply: BridgeReply) {
        write(BridgeWire.line(reply))
    }

    func sendData(id: UInt32, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var data = BridgeWire.dataHeader(id: id, length: bytes.count)
        data.append(contentsOf: bytes)
        write(data)
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        Darwin.close(fd)
    }

    private func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    // The peer went away; the next read notices and the caller
                    // closes. Nothing to log but the fact.
                    break
                }
            }
        }
    }
}

/// The listener: accept, peer-uid check, client cap, one read loop per client.
/// It is not an actor; every callback is handed to the main actor by the owner.
final class FilesBridgeListener {
    static let maxClients = 4

    private let queue = DispatchQueue(label: "dev.pocketdeck.mac.files-bridge")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clients: [FilesBridgeClient] = []
    private var stopped = false
    private(set) var path: String = ""

    /// `onData` answers false when the client's write budget is spent; the read
    /// loop then waits and offers the same bytes again.
    typealias RequestHandler = @Sendable (BridgeRequest, FilesBridgeClient) -> Void
    typealias DataHandler = @Sendable (UInt32, [UInt8], FilesBridgeClient) -> Bool

    /// Returns "ok" or an errno-style reason; the caller logs it without the
    /// path.
    func start(path: String,
               onRequest: @escaping RequestHandler,
               onData: @escaping DataHandler,
               onClose: @escaping @Sendable (FilesBridgeClient) -> Void) -> String {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The container belongs to this user; the socket itself is 0600.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
        } catch {
            return "mkdir errno \(errno)"
        }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return "path too long"
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return "socket errno \(errno)" }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let failure = errno
            Darwin.close(fd)
            return "bind errno \(failure)"
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else {
            let failure = errno
            Darwin.close(fd)
            return "listen errno \(failure)"
        }
        listenFD = fd
        queue.async { [weak self] in
            self?.acceptLoop(onRequest: onRequest, onData: onData, onClose: onClose)
        }
        return "ok"
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        let open = clients
        clients = []
        lock.unlock()
        if fd >= 0 { Darwin.close(fd) }
        for client in open { client.close() }
        if !path.isEmpty { unlink(path) }
    }

    private func acceptLoop(onRequest: @escaping RequestHandler,
                            onData: @escaping DataHandler,
                            onClose: @escaping @Sendable (FilesBridgeClient) -> Void) {
        while true {
            lock.lock()
            let fd = listenFD
            let done = stopped
            lock.unlock()
            guard !done, fd >= 0 else { return }
            let accepted = accept(fd, nil, nil)
            guard accepted >= 0 else {
                if errno == EINTR { continue }
                usleep(20_000)
                continue
            }
            // A client that closes between a request and its reply must not
            // raise SIGPIPE: the default action would kill the whole app.
            var noSigPipe: Int32 = 1
            setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                       socklen_t(MemoryLayout<Int32>.size))
            // Same user only: the group container is not a public interface.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(accepted, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(accepted)
                continue
            }
            lock.lock()
            let atCap = clients.count >= Self.maxClients
            lock.unlock()
            guard !atCap else {
                // The extension retries; nothing to answer without a request id.
                Darwin.close(accepted)
                continue
            }
            let client = FilesBridgeClient(fd: accepted)
            lock.lock()
            clients.append(client)
            lock.unlock()
            // A separate queue per client: the accept loop blocks in accept(),
            // so a read loop on the same serial queue would never run.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.readLoop(client, onRequest: onRequest, onData: onData, onClose: onClose)
            }
        }
    }

    private func readLoop(_ client: FilesBridgeClient,
                          onRequest: @escaping RequestHandler,
                          onData: @escaping DataHandler,
                          onClose: @escaping @Sendable (FilesBridgeClient) -> Void) {
        var decoder = BridgeDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        loop: while true {
            let count = read(client.fd, &buffer, buffer.count)
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                break
            }
            for event in decoder.feed(Array(buffer[0..<count])) {
                switch event {
                case .request(let request):
                    onRequest(request, client)
                case .data(let id, let bytes):
                    // Wait for room instead of buffering the file: the extension
                    // is blocked on its own write, so this is the flow control.
                    while !onData(id, bytes, client) {
                        if !client.isOpen { break loop }
                        usleep(20_000)
                    }
                case .dataHeader:
                    break
                case .invalid:
                    // A request channel only carries requests: a malformed line
                    // ends it rather than guessing.
                    break loop
                case .reply:
                    break loop
                }
            }
            if decoder.broken { break }
        }
        client.close()
        lock.lock()
        clients.removeAll { $0 === client }
        lock.unlock()
        onClose(client)
    }
}

/// What the bridge needs from the live phone: the item operations and the
/// display name the domain shows. A protocol so the server can be tested with
/// no session and no File Provider.
@MainActor
protocol FilesBridgeHost: AnyObject {
    var isConnected: Bool { get }
    var displayName: String? { get }
    func list(item: String, page: String?,
              completion: @escaping (Result<(items: [FileItem], next: String?), FsError>) -> Void)
    func stat(item: String, completion: @escaping (Result<FileItem, FsError>) -> Void)
    func streamRead(item: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void)
    /// `ready` fires once with the sink the extension's bytes go into, or nil
    /// when nothing follows (a folder, or a refusal).
    func create(_ request: BridgeCreate,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void)
    func modify(_ request: BridgeModify,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void)
    func delete(item: String, base: String, recursive: Bool,
                completion: @escaping (Result<Void, FsError>) -> Void)
    func cancel(id: UInt32)
    func cancelAll()
}

/// The real host: one session, one FsClient, and the app-owned id ↔ path map.
@MainActor
final class SessionBridgeHost: FilesBridgeHost {
    private let client: FsClient
    private let name: String?
    private let mapURL: URL?
    private var map: FilesIdMap

    init(client: FsClient, name: String?, mapURL: URL?) {
        self.client = client
        self.name = name
        self.mapURL = mapURL
        self.map = mapURL.map(FilesIdMap.load) ?? FilesIdMap()
    }

    var isConnected: Bool { true }
    var displayName: String? { name }

    // MARK: Resolution

    /// An identifier → the phone's relative path. A mapped entry is verified
    /// with one stat (the ino must still be the id); a mismatch is re-resolved
    /// once from the parent's listing, else `fs_not_found` (design §3).
    private func resolve(_ identifier: String,
                         completion: @escaping (Result<String, FsError>) -> Void) {
        if identifier == FilesMap.rootIdentifier { return completion(.success("")) }
        guard let path = map.path(for: identifier) else {
            return reresolve(identifier, completion: completion)
        }
        client.stat(path: path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fs):
                // The path still has a file: that is this item. Its ino may have
                // moved (a verified save renames a temp over it), which must not
                // change the identifier Finder knows.
                _ = self.map.insert(fs: fs, path: path,
                                    parentIdentifier: self.parent(of: identifier),
                                    identifier: identifier)
                self.save()
                completion(.success(path))
            case .failure(let error):
                if error.code == "fs_not_found" {
                    self.map.invalidate(subtree: path)
                    self.save()
                    return self.reresolve(identifier, completion: completion)
                }
                completion(.failure(error))
            }
        }
    }

    /// One listing of the parent: the only other way to learn an id's path.
    private func reresolve(_ identifier: String,
                             completion: @escaping (Result<String, FsError>) -> Void) {
        guard let parentID = map.parent(for: identifier), parentID != identifier else {
            return completion(.failure(FsError(code: "fs_not_found")))
        }
        resolve(parentID) { [weak self] parentResult in
            guard let self else { return }
            guard case .success(let parentPath) = parentResult else {
                return completion(.failure(FsError(code: "fs_not_found")))
            }
            self.client.list(path: parentPath, page: nil) { result in
                switch result {
                case .success(let page):
                    for fs in page.items {
                        let path = FilesMap.childPath(parentPath, fs.name)
                        if FilesMap.identifier(path: path, ino: fs.ino) == identifier {
                            self.map.insert(fs: fs, path: path, parentIdentifier: parentID)
                            self.save()
                            return completion(.success(path))
                        }
                    }
                    completion(.failure(FsError(code: "fs_not_found")))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func parent(of identifier: String) -> String {
        map.parent(for: identifier) ?? FilesMap.rootIdentifier
    }

    private func save() {
        guard let mapURL else { return }
        FilesIdMap.save(map, to: mapURL)
    }

    // MARK: Reads

    func list(item: String, page: String?,
              completion: @escaping (Result<(items: [FileItem], next: String?), FsError>) -> Void) {
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let path):
                self.client.list(path: path, page: page) { result in
                    switch result {
                    case .success(let listing):
                        let items = self.map.insert(childrenOf: path, parentIdentifier: item,
                                                    items: listing.items)
                        self.save()
                        completion(.success((items, listing.next)))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func stat(item: String, completion: @escaping (Result<FileItem, FsError>) -> Void) {
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let path):
                self.client.stat(path: path) { result in
                    switch result {
                    case .success(let fs):
                        let mapped = self.map.insert(fs: fs, path: path,
                                                     parentIdentifier: self.parent(of: item))
                        self.save()
                        completion(.success(mapped))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func streamRead(item: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let path):
                self.client.streamRead(path: path, offset: offset, length: length, etag: etag,
                                       onStart: onStart, chunk: chunk, completion: completion)
            }
        }
    }

    // MARK: Writes

    func create(_ request: BridgeCreate,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        resolve(request.parent) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                ready(nil)
                completion(.failure(error))
            case .success(let parentPath):
                let path = FilesMap.childPath(parentPath, request.name)
                if request.dir {
                    ready(nil)
                    self.client.mkdir(path: path) { result in
                        switch result {
                        case .success(let fs?):
                            let item = self.map.insert(fs: fs, path: path,
                                                       parentIdentifier: request.parent)
                            self.save()
                            completion(.success(item))
                        case .success(nil):
                            completion(.failure(FsError(code: "protocol")))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                    return
                }
                guard let sha256 = request.sha256 else {
                    ready(nil)
                    return completion(.failure(FsError(code: "fs_denied", message: "no digest")))
                }
                let sink = self.client.beginWrite(path: path, size: request.size, sha256: sha256,
                                                  etag: nil) { result in
                    switch result {
                    case .success(let fs):
                        let finalPath = FilesMap.childPath(parentPath, fs.name)
                        let item = self.map.insert(fs: fs, path: finalPath,
                                                   parentIdentifier: request.parent)
                        self.save()
                        completion(.success(item))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
                ready(sink)
            }
        }
    }

    func modify(_ request: BridgeModify,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        resolve(request.item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                ready(nil)
                completion(.failure(error))
            case .success(let path):
                self.performModify(request, path: path, ready: ready, completion: completion)
            }
        }
    }

    private func performModify(_ request: BridgeModify, path: String,
                               ready: @escaping (FilesWriteSink?) -> Void,
                               completion: @escaping (Result<FileItem, FsError>) -> Void) {
        let wantsMove = request.name != nil || request.parent != nil
        if request.hasContent, let sha256 = request.sha256 {
            let sink = client.beginWrite(path: path, size: request.size, sha256: sha256,
                                         etag: request.base) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let fs):
                    self.afterContent(fs, request: request, path: path, wantsMove: wantsMove,
                                      completion: completion)
                }
            }
            ready(sink)
            return
        }
        ready(nil)
        if wantsMove {
            moveItem(request, path: path, etag: request.base, completion: completion)
            return
        }
        if let mtime = request.mtime {
            client.stat(path: path) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let fs):
                    guard fs.etag == request.base else {
                        return completion(.failure(FsError(code: "fs_stale")))
                    }
                    self.client.setAttrs(path: path, mtime: mtime) { result in
                        switch result {
                        case .success(let fs?):
                            completion(.success(self.remember(fs, path: path, item: request.item)))
                        case .success(nil):
                            completion(.failure(FsError(code: "protocol")))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                }
            }
            return
        }
        // Nothing that changes the phone: answer its current metadata.
        client.stat(path: path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fs):
                completion(.success(self.remember(fs, path: path, item: request.item)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// After new content landed: a rename/move and/or a date may follow.
    private func afterContent(_ fs: FsItem, request: BridgeModify, path: String,
                              wantsMove: Bool,
                              completion: @escaping (Result<FileItem, FsError>) -> Void) {
        let landed = remember(fs, path: path, item: request.item)
        if wantsMove {
            moveItem(request, path: path, etag: nil) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let moved):
                    guard let mtime = request.mtime else { return completion(.success(moved)) }
                    self.setMtime(mtime, item: moved, path: self.map.path(for: moved.identifier) ?? path,
                                  completion: completion)
                }
            }
            return
        }
        guard let mtime = request.mtime else { return completion(.success(landed)) }
        setMtime(mtime, item: landed, path: path, completion: completion)
    }

    private func setMtime(_ mtime: Int, item: FileItem, path: String,
                          completion: @escaping (Result<FileItem, FsError>) -> Void) {
        client.setAttrs(path: path, mtime: mtime) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fs?):
                completion(.success(self.remember(fs, path: path, item: item.identifier)))
            case .success(nil):
                completion(.success(item))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func moveItem(_ request: BridgeModify, path: String, etag: String?,
                          completion: @escaping (Result<FileItem, FsError>) -> Void) {
        let name = request.name ?? (path as NSString).lastPathComponent
        let finishMove: (String) -> Void = { [weak self] parentPath in
            guard let self else { return }
            let newPath = FilesMap.childPath(parentPath, name)
            self.client.move(from: path, to: newPath, etag: etag) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let fs?):
                    self.map.rename(identifier: request.item, to: newPath)
                    let item = self.remember(fs, path: newPath,
                                             item: request.item,
                                             parentIdentifier: request.parent ?? self.parent(of: request.item))
                    self.save()
                    completion(.success(item))
                case .success(nil):
                    completion(.failure(FsError(code: "protocol")))
                }
            }
        }
        guard let parentID = request.parent else {
            return finishMove(FilesMap.parentPath(of: path))
        }
        resolve(parentID) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let parentPath):
                finishMove(parentPath)
            }
        }
    }

    private func remember(_ fs: FsItem, path: String, item: String,
                          parentIdentifier: String? = nil) -> FileItem {
        // The item Finder knows keeps its identifier: a save may replace the
        // inode and a move may re-create the row, but the person's item is the
        // same one (design §3, S4).
        let mapped = map.insert(fs: fs, path: path,
                                parentIdentifier: parentIdentifier ?? parent(of: item),
                                identifier: item)
        save()
        return mapped
    }

    func delete(item: String, base: String, recursive: Bool,
                completion: @escaping (Result<Void, FsError>) -> Void) {
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let path):
                // The phone's delete has no etag field: one stat is the check.
                self.client.stat(path: path) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let fs):
                        guard fs.etag == base else {
                            return completion(.failure(FsError(code: "fs_stale")))
                        }
                        self.client.delete(path: path, recursive: recursive) { result in
                            switch result {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success:
                                self.map.invalidate(subtree: path)
                                self.save()
                                completion(.success(()))
                            }
                        }
                    }
                }
            }
        }
    }

    func cancel(id: UInt32) { client.cancel(id: id) }
    func cancelAll() { client.cancelAll() }
}

/// The socket server: turns requests into host calls and writes the replies.
@MainActor
final class FilesBridge {
    static let shared = FilesBridge()

    /// Live ids per client (design §3: ≤ 8) and, per read, the phone-level id a
    /// cancel needs.
    private var liveIDs: [ObjectIdentifier: Set<UInt32>] = [:]
    private var readIDs: [ObjectIdentifier: [UInt32: UInt32]] = [:]
    /// The sink a create/modify's data frames go into, per client and id.
    private var writeSinks: [ObjectIdentifier: [UInt32: FilesWriteSink]] = [:]

    private var listener: FilesBridgeListener?
    private var host: FilesBridgeHost?
    private(set) var socketPath: String?

    /// The shared bridge the app runs; tests make their own instance so two
    /// listeners never share state.
    init() {}

    var isServing: Bool { listener != nil }

    /// Starts the listener on `path`; "ok" or a reason without the path.
    @discardableResult
    func start(path: String) -> String {
        if listener != nil { return "ok" }
        let listener = FilesBridgeListener()
        let result = listener.start(
            path: path,
            onRequest: { [weak self] request, client in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(request, from: client) }
                }
            },
            onData: { [weak self] id, bytes, client in
                guard client.flow.reserve(bytes.count) else { return false }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.accept(bytes, id: id, from: client)
                        client.flow.release(bytes.count)
                    }
                }
                return true
            },
            onClose: { [weak self] client in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.forget(client) }
                }
            })
        guard result == "ok" else { return result }
        self.listener = listener
        socketPath = path
        return "ok"
    }

    func stop() {
        listener?.stop()
        listener = nil
        socketPath = nil
        host?.cancelAll()
        host = nil
        liveIDs.removeAll()
        readIDs.removeAll()
        writeSinks.removeAll()
    }

    /// A session became ready: the bridge answers from now on.
    func attach(host: FilesBridgeHost) {
        self.host?.cancelAll()
        self.host = host
        Log.files.notice("bridge: session attached")
    }

    /// The session ended: requests answer `offline` until the next attach.
    func detach() {
        host?.cancelAll()
        host = nil
        liveIDs.removeAll()
        readIDs.removeAll()
        writeSinks.removeAll()
        Log.files.notice("bridge: session detached")
    }

    // MARK: Requests

    private func handle(_ request: BridgeRequest, from client: FilesBridgeClient) {
        let slot = ObjectIdentifier(client)
        switch request {
        case .hello(let id, let version):
            guard version == filesBridgeVersion else {
                return client.send(.error(id: id, code: "bad_version"))
            }
            client.send(.hello(id: id, version: filesBridgeVersion,
                               name: host?.displayName,
                               connected: host?.isConnected ?? false))
            Log.files.notice("bridge: hello connected=\(self.host != nil, privacy: .public)")
        case .list(let id, let item, let page):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.list(item: item, page: page) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.end(id, client)
                    switch result {
                    case .success(let listing):
                        client.send(.items(id: id, page: listing.next, items: listing.items))
                        Log.files.notice("bridge: list page items=\(listing.items.count, privacy: .public)")
                    case .failure(let error):
                        client.send(.error(id: id, code: error.code))
                        Log.files.notice("bridge: list failed code=\(error.code, privacy: .public)")
                    }
                }
            }
        case .stat(let id, let item):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.stat(item: item) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.end(id, client)
                    switch result {
                    case .success(let item):
                        client.send(.item(id: id, item: item))
                    case .failure(let error):
                        client.send(.error(id: id, code: error.code))
                        Log.files.notice("bridge: stat failed code=\(error.code, privacy: .public)")
                    }
                }
            }
        case .read(let id, let item, let offset, let length, let etag):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            // A whole-file read needs the item's size; the extension stats
            // first, so a request with length 0 is an empty file.
            guard begin(id, client) else { return }
            host.streamRead(
                item: item, offset: offset, length: length, etag: etag,
                onStart: { [weak self] fsID in
                    MainActor.assumeIsolated { self?.readIDs[slot, default: [:]][id] = fsID }
                },
                chunk: { [weak client] bytes in
                    guard let client, client.isOpen else { return false }
                    client.sendData(id: id, bytes: bytes)
                    return true
                },
                completion: { [weak self] result in
                    MainActor.assumeIsolated {
                        self?.readIDs[slot]?[id] = nil
                        self?.end(id, client)
                        switch result {
                        case .success(let read):
                            client.send(.end(id: id, size: read.bytes, sha256: read.sha256))
                            Log.files.notice("bridge: read done bytes=\(read.bytes, privacy: .public)")
                        case .failure(let error):
                            let code = FilesFailure.from(code: error.code) == .offline ? "offline" : error.code
                            client.send(.error(id: id, code: code))
                            Log.files.notice("bridge: read failed code=\(code, privacy: .public)")
                        }
                    }
                })
        case .create(let id, let create):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.create(create, ready: { [weak self] sink in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let sink {
                        self.writeSinks[slot, default: [:]][id] = sink
                        client.send(.ready(id: id))
                    }
                }
            }, completion: { [weak self] result in
                MainActor.assumeIsolated {
                    self?.finishWrite(id: id, client: client, result: result)
                }
            })
            Log.files.notice("bridge: create dir=\(create.dir, privacy: .public) size=\(create.size, privacy: .public)")
        case .modify(let id, let modify):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.modify(modify, ready: { [weak self] sink in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let sink {
                        self.writeSinks[slot, default: [:]][id] = sink
                        client.send(.ready(id: id))
                    }
                }
            }, completion: { [weak self] result in
                MainActor.assumeIsolated {
                    self?.finishWrite(id: id, client: client, result: result)
                }
            })
            Log.files.notice("bridge: modify content=\(modify.hasContent, privacy: .public) size=\(modify.size, privacy: .public)")
        case .delete(let id, let item, let base, let recursive):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.delete(item: item, base: base, recursive: recursive) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.end(id, client)
                    switch result {
                    case .success:
                        client.send(.ok(id: id))
                        Log.files.notice("bridge: delete ok")
                    case .failure(let error):
                        client.send(.error(id: id, code: error.code))
                        Log.files.notice("bridge: delete failed code=\(error.code, privacy: .public)")
                    }
                }
            }
        case .cancel(let id):
            if let fsID = readIDs[slot]?[id] {
                readIDs[slot]?[id] = nil
                end(id, client)
                host?.cancel(id: fsID)
                Log.files.notice("bridge: read cancelled")
            } else if let sink = writeSinks[slot]?[id] {
                writeSinks[slot]?[id] = nil
                end(id, client)
                sink.cancel()
                Log.files.notice("bridge: write cancelled")
            }
        }
    }

    /// One data chunk for a create/modify's write sink (main actor).
    private func accept(_ bytes: [UInt8], id: UInt32, from client: FilesBridgeClient) {
        let slot = ObjectIdentifier(client)
        guard let sink = writeSinks[slot]?[id] else { return }
        guard sink.append(bytes) else {
            // The sink refused: the write is over; the phone's answer (or the
            // extension's cancel) finishes the request.
            return
        }
    }

    private func finishWrite(id: UInt32, client: FilesBridgeClient,
                             result: Result<FileItem, FsError>) {
        let slot = ObjectIdentifier(client)
        writeSinks[slot]?[id] = nil
        end(id, client)
        switch result {
        case .success(let item):
            client.send(.item(id: id, item: item))
            Log.files.notice("bridge: write done dir=\(item.isDirectory, privacy: .public) size=\(item.size, privacy: .public)")
        case .failure(let error):
            // A session that ended mid-write is "offline" to the extension: the
            // system keeps the change pending and retries on reconnect.
            let code = FilesFailure.from(code: error.code) == .offline ? "offline" : error.code
            client.send(.error(id: id, code: code))
            Log.files.notice("bridge: write failed code=\(code, privacy: .public)")
        }
    }

    /// Reserves a live id (design §3: at most 8 per client).
    private func begin(_ id: UInt32, _ client: FilesBridgeClient) -> Bool {
        let slot = ObjectIdentifier(client)
        var set = liveIDs[slot] ?? []
        guard !set.contains(id), set.count < 8 else {
            client.send(.error(id: id, code: "busy"))
            Log.files.notice("bridge: too many live ids")
            return false
        }
        set.insert(id)
        liveIDs[slot] = set
        return true
    }

    private func end(_ id: UInt32, _ client: FilesBridgeClient) {
        let slot = ObjectIdentifier(client)
        liveIDs[slot]?.remove(id)
        if liveIDs[slot]?.isEmpty == true { liveIDs.removeValue(forKey: slot) }
    }

    private func forget(_ client: FilesBridgeClient) {
        let slot = ObjectIdentifier(client)
        // Every read this client had in flight is abandoned on the phone too.
        for (_, fsID) in readIDs[slot] ?? [:] { host?.cancel(id: fsID) }
        for (_, sink) in writeSinks[slot] ?? [:] { sink.cancel() }
        readIDs.removeValue(forKey: slot)
        writeSinks.removeValue(forKey: slot)
        liveIDs.removeValue(forKey: slot)
        Log.files.notice("bridge: client gone")
    }
}
