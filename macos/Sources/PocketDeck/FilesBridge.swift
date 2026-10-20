// The app side of phone files in Finder (docs/design/files.md §1, §3): a
// UNIX-domain socket in the App Group container that the sandboxed File
// Provider extension asks for listings, stats and file bytes. The app owns the
// one phone session, so the extension never dials the phone.
//
// The wire is FilesCore's: newline-delimited JSON with an `id`, then for a read
// a `data` header and exactly that many raw bytes, repeatedly, then `end`.
// Nothing that crosses this socket is logged with a name, a path or a byte
// value: op names, counts, lengths and codes only (design §4).

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

/// One accepted client. Reads happen on its own queue (blocking recv); writes
/// are serialized by a lock and may come from the main actor.
final class FilesBridgeClient: @unchecked Sendable {
    let fd: Int32
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

    /// Returns "ok" or an errno-style reason; the caller logs it without the
    /// path.
    func start(path: String,
               onRequest: @escaping @Sendable (BridgeRequest, FilesBridgeClient) -> Void,
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
        queue.async { [weak self] in self?.acceptLoop(onRequest: onRequest, onClose: onClose) }
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

    private func acceptLoop(onRequest: @escaping @Sendable (BridgeRequest, FilesBridgeClient) -> Void,
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
                self?.readLoop(client, onRequest: onRequest, onClose: onClose)
            }
        }
    }

    private func readLoop(_ client: FilesBridgeClient,
                          onRequest: @escaping @Sendable (BridgeRequest, FilesBridgeClient) -> Void,
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
                case .invalid:
                    // A request channel only carries requests: a malformed line
                    // ends it rather than guessing.
                    break loop
                default:
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

/// What the bridge needs from the live phone: list/stat/read/cancel and the
/// display name the domain shows. A protocol so the server can be tested with
/// no session and no File Provider.
@MainActor
protocol FilesBridgeHost: AnyObject {
    var isConnected: Bool { get }
    var displayName: String? { get }
    func list(path: String, page: String?, completion: @escaping (Result<FsPage, FsError>) -> Void)
    func stat(path: String, completion: @escaping (Result<FsItem, FsError>) -> Void)
    func streamRead(path: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void)
    func cancel(id: UInt32)
    func cancelAll()
}

/// The real host: one session, one FsClient.
@MainActor
final class SessionBridgeHost: FilesBridgeHost {
    private let client: FsClient
    private let name: String?

    init(client: FsClient, name: String?) {
        self.client = client
        self.name = name
    }

    var isConnected: Bool { true }
    var displayName: String? { name }

    func list(path: String, page: String?, completion: @escaping (Result<FsPage, FsError>) -> Void) {
        client.list(path: path, page: page, completion: completion)
    }

    func stat(path: String, completion: @escaping (Result<FsItem, FsError>) -> Void) {
        client.stat(path: path, completion: completion)
    }

    func streamRead(path: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        client.streamRead(path: path, offset: offset, length: length, etag: etag,
                          onStart: onStart, chunk: chunk, completion: completion)
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
        case .list(let id, let path, let page):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.list(path: path, page: page) { [weak self] result in
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
        case .stat(let id, let path):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.stat(path: path) { [weak self] result in
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
        case .read(let id, let path, let offset, let length, let etag):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            // A whole-file read needs the item's size; the extension stats
            // first, so a request with length 0 is an empty file.
            guard begin(id, client) else { return }
            host.streamRead(
                path: path, offset: offset, length: length, etag: etag,
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
                            client.send(.error(id: id, code: error.code))
                            Log.files.notice("bridge: read failed code=\(error.code, privacy: .public)")
                        }
                    }
                })
        case .cancel(let id):
            guard let fsID = readIDs[slot]?[id] else { return }
            readIDs[slot]?[id] = nil
            end(id, client)
            host?.cancel(id: fsID)
            Log.files.notice("bridge: read cancelled")
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
        readIDs.removeValue(forKey: slot)
        liveIDs.removeValue(forKey: slot)
        Log.files.notice("bridge: client gone")
    }
}
