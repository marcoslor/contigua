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
    static let infoPlistKey = filesGroupInfoKey

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

    /// A push on the watch connection: these containers moved (design §5). It
    /// carries no id, so it can never be mistaken for a reply.
    func sendSignal(items: [String]) {
        write(BridgeWire.signal(items: items))
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
    /// The extension's watch subscription holds one connection for its whole
    /// life; the rest carry the ordinary per-request connections.
    static let maxClients = 6

    private let queue = DispatchQueue(label: "app.contigua.mac.files-bridge")
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
                case .reply, .signal:
                    // A request channel carries requests only.
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
protocol FilesBridgeHost: AnyObject, FilesThumbHost {
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
    /// One container entered the system's view (design "S5 round 3"): make sure
    /// the phone watches its folder, and remember its path. A repeated touch is
    /// cheap and never sends a second `fs.watch`.
    func touch(item: String, completion: @escaping (Result<Void, FsError>) -> Void)
    /// The ten minutes are over (or the LRU cap dropped it): stop watching the
    /// folder on the phone.
    func unwatch(item: String, completion: @escaping (Result<Void, FsError>) -> Void)
    /// A container's deltas after an anchor.
    func changes(item: String, from: String?,
                 completion: @escaping (Result<FilesChangesReply, FsError>) -> Void)
    /// A container's current sync anchor.
    func anchor(item: String, completion: @escaping (Result<String, FsError>) -> Void)
    /// A folder was touched (a listing, a stat of its child, a write): the
    /// bridge keeps it watched on the phone for ten minutes.
    var onTouch: ((String) -> Void)? { get set }
    /// A watched folder moved: re-list, diff and signal the extension.
    func filesChanged(paths: [String])
    /// The session became ready (every connect, and so once after an app start):
    /// start the record's resync (FILES-33).
    func sessionReady()
    /// The session ended: abandon the resync; the next ready starts over.
    func sessionDropped()
    func cancel(id: UInt32)
    func cancelAll()
}

extension FilesBridgeHost {
    /// A host without a record (the bridge's own tests) has nothing to resync.
    func sessionReady() {}
    func sessionDropped() {}
}

/// The real host: one session, one FsClient, and the app-owned id ↔ path map.
@MainActor
final class SessionBridgeHost: FilesBridgeHost {
    private let client: FsClient
    private let name: String?
    private let mapURL: URL?
    private let replicaURL: URL?
    private var map: FilesIdMap
    /// What the system was last told each folder holds, plus the durable change
    /// log and epoch (FILES-31/32). Written with the id map in one coalesced
    /// save.
    private(set) var replica: FilesReplica
    /// The app tells the extension which containers moved (design §5).
    private let signal: ([String]) -> Void
    /// The app's watch set keeps a touched folder on the phone for ten minutes.
    var onTouch: ((String) -> Void)?

    /// One job per folder (ISS-37): its phase, the one walk that may run for
    /// it, and the refresh a phone push may owe. Empty means the folder is idle.
    private var jobs: [String: FolderJob] = [:]
    /// The session run: a drop or a new ready changes it, and a late page or
    /// timer from the old run changes nothing.
    private var jobToken = 0
    /// Which containers a folder belongs to, for a phone-side change.
    private var pathByItem: [String: String] = [:]
    private var itemsByPath: [String: Set<String>] = [:]

    /// Identifiers (and create names per folder) with an upload in flight: a
    /// listing never deletes one (FILES-31).
    private var uploading: Set<String> = []
    private var uploadNames: [String: Set<String>] = [:]
    /// The reconnect resync (FILES-33): its phases and the record it reads.
    private(set) var resync = FilesResync()
    /// The record's folders this session's resync has taken responsibility for:
    /// the bridge's re-watch touches must not list them again, because the
    /// digest compare (or the resync's own listing) is that folder's check.
    private var resyncCovered: Set<String> = []
    /// The folders one `fs.digest` was asked about, for mapping path → folder.
    private var resyncFolders: [FilesResync.Folder] = []
    /// The record's clock and the two delays; tests move all three by hand.
    var clock: () -> TimeInterval = { Date().timeIntervalSince1970 }
    var confirmDelay: TimeInterval = 2
    var refreshDelay: TimeInterval = 0.15
    var confirmScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {  // gcd: one injected delay
            MainActor.assumeIsolated { work() }
        }
    }
    var refreshScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {  // gcd: one injected delay
            MainActor.assumeIsolated { work() }
        }
    }

    init(client: FsClient, name: String?, mapURL: URL?,
         signal: @escaping ([String]) -> Void = { _ in }) {
        self.client = client
        self.name = name
        self.mapURL = mapURL
        let replicaURL = mapURL?.deletingLastPathComponent()
            .appendingPathComponent("files-replica.json")
        self.replicaURL = replicaURL
        self.signal = signal
        self.map = mapURL.map(FilesIdMap.load) ?? FilesIdMap()
        self.replica = replicaURL.map(FilesReplica.load) ?? FilesReplica()
    }

    var isConnected: Bool { true }
    var displayName: String? { name }

    // MARK: Resolution

    /// An identifier → the phone's relative path. A mapped entry is verified
    /// with one stat (the ino must still be the id); a mismatch is re-resolved
    /// once from the parent's listing, else `fs_not_found` (design §3).
    private func resolve(_ identifier: String,
                         completion: @escaping (Result<String, FsError>) -> Void) {
        resolveKind(identifier) { result in completion(result.map { $0.path }) }
    }

    /// As `resolve`, plus whether the phone says the item is a folder: a watch
    /// names folders, and a file answered `fs_not_a_dir` (design "Fixes 10-20").
    private func resolveKind(_ identifier: String,
                             completion: @escaping (Result<(path: String, dir: Bool), FsError>) -> Void) {
        if identifier == FilesMap.rootIdentifier { return completion(.success(("", true))) }
        guard let path = map.path(for: identifier) else {
            return reresolveKind(identifier, completion: completion)
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
                completion(.success((path, fs.dir)))
            case .failure(let error):
                if error.code == "fs_not_found" {
                    self.forget(self.map.invalidate(subtree: path))
                    self.save()
                    return self.reresolveKind(identifier, completion: completion)
                }
                completion(.failure(error))
            }
        }
    }

    /// One listing of the parent: the only other way to learn an id's path.
    private func reresolve(_ identifier: String,
                             completion: @escaping (Result<String, FsError>) -> Void) {
        reresolveKind(identifier) { result in completion(result.map { $0.path }) }
    }

    private func reresolveKind(_ identifier: String,
                               completion: @escaping (Result<(path: String, dir: Bool), FsError>) -> Void) {
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
                            return completion(.success((path, fs.dir)))
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

    /// Writing the id map and the replica record is a cache update, not a
    /// durability promise: a big listing (1500 entries, one `insert` per item)
    /// used to rewrite the whole JSON file per item. Coalesce both files to one
    /// write per quarter second.
    private var saveScheduled = false
    private var saveDirty = false

    private func save() {
        guard mapURL != nil else { return }
        saveDirty = true
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                guard self.saveDirty, let url = self.mapURL else { return }
                self.saveDirty = false
                FilesIdMap.save(self.map, to: url)
                if let replicaURL = self.replicaURL {
                    FilesReplica.save(self.replica, to: replicaURL)
                }
            }
        }
    }

    // MARK: Reads

    /// The extension's read of a folder (design § Sync integrity, 2): when the
    /// folder is idle this page starts its job's walk, so even a repeat
    /// enumeration diffs the record; while a pass already runs, the read is
    /// answered without recording (one pass owns the record).
    func list(item: String, page: String?,
              completion: @escaping (Result<(items: [FileItem], next: String?), FsError>) -> Void) {
        guard !filesSystemContainer(item) else {
            return completion(.failure(FsError(code: "fs_not_found")))
        }
        onTouch?(item)
        var token: Int?
        if page == nil {
            let (record, _) = currentRecord(item)
            let action = step(.systemStart(recorded: record.count, start: record,
                                           token: jobToken), on: item)
            if action == .start { token = jobs[item]?.walk?.token }
        } else {
            token = jobs[item]?.systemPageToken(page)
        }
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if let token {
                    let action = self.pageEvent(item: item, token: token, items: [], next: nil,
                                                digest: nil, failed: true)
                    self.run(action, item: item)
                }
                completion(.failure(error))
            case .success(let path):
                self.client.list(path: path, page: page) { result in
                    switch result {
                    case .success(let listing):
                        let items = self.map.insert(childrenOf: path, parentIdentifier: item,
                                                    items: listing.items)
                        self.save()
                        if let token {
                            let action = self.pageEvent(item: item, token: token, items: items,
                                                        next: listing.next, digest: listing.digest,
                                                        failed: false)
                            self.run(action, item: item)
                        }
                        completion(.success((items, listing.next)))
                    case .failure(let error):
                        if let token {
                            let action = self.pageEvent(item: item, token: token, items: [],
                                                        next: nil, digest: nil, failed: true)
                            self.run(action, item: item)
                        }
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// The record's children and digest as they are now.
    private func currentRecord(_ item: String) -> ([String: FileItem], String?) {
        let record = replica.folders[item]
        return (record?.children ?? [:], record?.digest)
    }

    /// One event through a folder's job, with one phase log per change. An idle
    /// job leaves the map, so a session's folders do not accumulate.
    @discardableResult
    private func step(_ event: FolderJob.Event, on item: String) -> FolderJob.Action {
        var job = jobs[item] ?? FolderJob(folder: item)
        let before = job.state
        let action = job.apply(event)
        if before.code != job.state.code {
            Log.files.notice("folder: \(before.code, privacy: .public) --\(event.code, privacy: .public)--> \(job.state.code, privacy: .public)")
        }
        if case .idle = job.state {
            jobs.removeValue(forKey: item)
        } else {
            jobs[item] = job
        }
        return action
    }

    /// Runs one job action. `.start` asks the first page of a host pass;
    /// `.serveOnly` answers a read without recording it; a timer comes back as
    /// `confirmDue`/`refreshDue` after the host's delay.
    private func run(_ action: FolderJob.Action, item: String,
                     completion: ((Result<Void, FsError>) -> Void)? = nil) {
        switch action {
        case .start:
            guard let token = jobs[item]?.walk?.token else {
                completion?(.success(()))
                return
            }
            walkPages(item: item, cursor: nil, token: token, completion: completion)
        case .serveOnly:
            walkPages(item: item, cursor: nil, token: nil, completion: completion)
        case .scheduleConfirm:
            guard let token = jobs[item]?.walk?.token else { return }
            confirmScheduler(confirmDelay) { [weak self] in
                guard let self else { return }
                self.run(self.step(.confirmDue(token: token), on: item), item: item)
            }
        case .scheduleRefresh:
            guard let state = jobs[item]?.state,
                  case .refreshing(_, let token) = state else { return }
            refreshScheduler(refreshDelay) { [weak self] in
                guard let self else { return }
                let (record, _) = self.currentRecord(item)
                self.run(self.step(.refreshDue(token: token, recorded: record.count,
                                               start: record), on: item), item: item)
            }
        case .report(let delta, let listing, let digest, let dropped):
            applyReport(delta, listing: listing, digest: digest, dropped: dropped, item: item)
        case .none:
            break
        }
    }

    /// Every page of one host-driven walk; `token` nil is a read that records
    /// nothing. The closure runs once, at the last page or the first failure.
    private func walkPages(item: String, cursor: String?, token: Int?,
                           completion: ((Result<Void, FsError>) -> Void)?) {
        onTouch?(item)
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if let token {
                    let action = self.pageEvent(item: item, token: token, items: [], next: nil,
                                                digest: nil, failed: true)
                    self.run(action, item: item)
                }
                completion?(.failure(error))
            case .success(let path):
                self.client.list(path: path, page: cursor) { result in
                    switch result {
                    case .success(let listing):
                        let items = self.map.insert(childrenOf: path, parentIdentifier: item,
                                                    items: listing.items)
                        self.save()
                        if let token {
                            let action = self.pageEvent(item: item, token: token, items: items,
                                                        next: listing.next, digest: listing.digest,
                                                        failed: false)
                            self.run(action, item: item)
                        }
                        if let next = listing.next {
                            self.walkPages(item: item, cursor: next, token: token,
                                           completion: completion)
                        } else {
                            completion?(.success(()))
                        }
                    case .failure(let error):
                        if let token {
                            let action = self.pageEvent(item: item, token: token, items: [],
                                                        next: nil, digest: nil, failed: true)
                            self.run(action, item: item)
                        }
                        completion?(.failure(error))
                    }
                }
            }
        }
    }

    /// One page (or a failure) into the job: the page events carry the token the
    /// pass started with, so a page from a dropped run changes nothing.
    private func pageEvent(item: String, token: Int, items: [FileItem], next: String?,
                           digest: String?, failed: Bool) -> FolderJob.Action {
        let (record, recordDigest) = currentRecord(item)
        let names = uploadNames[item] ?? []
        if failed {
            return step(.failedPage(token: token, record: record, recordDigest: recordDigest,
                                    idMap: map, uploading: uploading, uploadNames: names),
                        on: item)
        }
        if let next {
            return step(.page(token: token, items: items, next: next), on: item)
        }
        return step(.lastPage(token: token, items: items, digest: digest, record: record,
                              idMap: map, uploading: uploading, uploadNames: names), on: item)
    }

    /// Writes what the system is told: the record's children, the change log,
    /// and the working-set signal (FILES-31). A guarded deletion keeps the
    /// item; an identifier the id map moved elsewhere leaves the record without
    /// a deletion, because the system itself moved it.
    private func applyReport(_ delta: FilesDelta, listing: [FileItem], digest: String?,
                             dropped: Set<String>, item: String) {
        let current = replica.folders[item]?.children ?? [:]
        var children: [String: FileItem] = [:]
        for child in listing { children[child.identifier] = child }
        for (identifier, old) in current
        where children[identifier] == nil && !delta.deleted.contains(identifier)
            && !dropped.contains(identifier) {
            children[identifier] = old
        }
        replica.folders[item] = FilesFolderRecord(children: children, touched: clock(),
                                                  digest: digest)
        if replica.log.record(container: item, delta: delta) {
            signal([item])
        }
        Log.files.notice("folder: report items=\(delta.items.count, privacy: .public) deletions=\(delta.deleted.count, privacy: .public) dropped=\(dropped.count, privacy: .public)")
        save()
    }

    func stat(item: String, completion: @escaping (Result<FileItem, FsError>) -> Void) {
        guard !filesSystemContainer(item) else {
            return completion(.failure(FsError(code: "fs_not_found")))
        }
        if item == FilesMap.rootIdentifier {
            onTouch?(item)
        } else {
            onTouch?(parent(of: item))
        }
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if error.code == "fs_not_found" { self.notFound(item) }
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
                        if error.code == "fs_not_found" { self.notFound(item, path: path) }
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// One thumbnail: the type is decided from the mapped path, with no phone
    /// traffic for a document (FILES-22), and the phone's bytes come back whole.
    func thumb(item: String, size: Int,
               onStart: @escaping (UInt32) -> Void,
               completion: @escaping (Result<FilesThumb, FsError>) -> Void) {
        guard let path = map.path(for: item) else {
            return completion(.failure(FsError(code: "fs_not_found")))
        }
        guard FilesThumbPolicy.pathIsMedia(path) else {
            return completion(.failure(FsError(code: "not_media")))
        }
        client.streamThumb(path: path, size: size, etag: nil, onStart: onStart) {
            [weak self] result in
            if case .failure(let error) = result, error.code == "fs_not_found" {
                self?.notFound(item, path: path)
            }
            completion(result)
        }
    }

    func streamRead(item: String, offset: Int, length: Int, etag: String?,
                    onStart: @escaping (UInt32) -> Void,
                    chunk: @escaping ([UInt8]) -> Bool,
                    completion: @escaping (Result<FsReadResult, FsError>) -> Void) {
        onTouch?(parent(of: item))
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if error.code == "fs_not_found" { self.notFound(item) }
                completion(.failure(error))
            case .success(let path):
                self.client.streamRead(path: path, offset: offset, length: length, etag: etag,
                                       onStart: onStart, chunk: chunk) { result in
                    if case .failure(let error) = result, error.code == "fs_not_found" {
                        self.notFound(item, path: path)
                    }
                    completion(result)
                }
            }
        }
    }

    // MARK: Writes

    func create(_ request: BridgeCreate,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        onTouch?(request.parent)
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
                            self.noteReported(item, in: request.parent)
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
                let identifier = self.map.identifier(for: path)
                self.beginUpload(identifier: identifier, parent: request.parent,
                                 name: request.name)
                let finish: (Result<FileItem, FsError>) -> Void = { [weak self] result in
                    self?.endUpload(identifier: identifier, parent: request.parent,
                                    name: request.name)
                    completion(result)
                }
                let sink = self.client.beginWrite(path: path, size: request.size, sha256: sha256,
                                                  etag: nil, exclusive: true) { result in
                    switch result {
                    case .success(let fs):
                        let finalPath = FilesMap.childPath(parentPath, fs.name)
                        let item = self.map.insert(fs: fs, path: finalPath,
                                                   parentIdentifier: request.parent)
                        self.save()
                        self.noteReported(item, in: request.parent)
                        finish(.success(item))
                    case .failure(let error):
                        finish(.failure(error))
                    }
                }
                ready(sink)
            }
        }
    }

    func modify(_ request: BridgeModify,
                ready: @escaping (FilesWriteSink?) -> Void,
                completion: @escaping (Result<FileItem, FsError>) -> Void) {
        onTouch?(parent(of: request.item))
        if let parent = request.parent { onTouch?(parent) }
        let upload = request.hasContent
        let container = parent(of: request.item)
        let name = replica.folders[container]?.children[request.item]?.name
        if upload { beginUpload(identifier: request.item, parent: container, name: name) }
        let finish: (Result<FileItem, FsError>) -> Void = { [weak self] result in
            if upload {
                self?.endUpload(identifier: request.item, parent: container, name: name)
            }
            completion(result)
        }
        resolve(request.item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                ready(nil)
                finish(.failure(error))
            case .success(let path):
                self.performModify(request, path: path, ready: ready, completion: finish)
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
        let oldParent = parent(of: request.item)
        let finishMove: (String) -> Void = { [weak self] parentPath in
            guard let self else { return }
            let newPath = FilesMap.childPath(parentPath, name)
            self.client.move(from: path, to: newPath, etag: etag) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let fs?):
                    let newParent = request.parent ?? oldParent
                    if newParent != oldParent {
                        // The system made this move and knows the new parent.
                        // Identifiers are domain-wide: a logged deletion here
                        // would delete the moved item itself on a replay.
                        self.dropReported(request.item, from: oldParent)
                    }
                    self.map.rename(identifier: request.item, to: newPath)
                    let item = self.remember(fs, path: newPath, item: request.item,
                                             parentIdentifier: newParent)
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
        let container = parentIdentifier ?? parent(of: item)
        let mapped = map.insert(fs: fs, path: path, parentIdentifier: container,
                                identifier: item)
        noteReported(mapped, in: container)
        return mapped
    }

    /// The system was told this item (a create, modify, move or setAttrs
    /// completion): the record keeps it, so a listing that was asked before the
    /// write cannot delete it (FILES-31).
    private func noteReported(_ item: FileItem, in container: String) {
        var record = replica.folders[container] ?? FilesFolderRecord()
        record.children[item.identifier] = item
        record.touched = clock()
        replica.folders[container] = record
        save()
    }

    /// The system was told the item is gone (a delete completion, or a
    /// `fs_not_found` repair): drop it from the record and log the deletion.
    private func removeReported(_ identifier: String, from container: String) {
        guard var record = replica.folders[container],
              record.children.removeValue(forKey: identifier) != nil else { return }
        record.touched = clock()
        replica.folders[container] = record
        let delta = FilesDelta(items: [], deleted: [identifier])
        if replica.log.record(container: container, delta: delta) {
            signal([container])
        }
        save()
    }

    /// The item left this folder's record without being gone (a Mac move to
    /// another folder): nothing is logged, the system already knows.
    private func dropReported(_ identifier: String, from container: String) {
        guard var record = replica.folders[container],
              record.children.removeValue(forKey: identifier) != nil else { return }
        record.touched = clock()
        replica.folders[container] = record
        save()
    }

    /// The folder was in the system's view: remember when, for the resync order
    /// (design § Sync integrity, slice 3).
    private func noteTouched(_ container: String) {
        guard var record = replica.folders[container] else { return }
        record.touched = clock()
        replica.folders[container] = record
        save()
    }

    // MARK: The reconnect resync (FILES-33)

    /// The session is ready: one `fs.digest` over the record's folders, most
    /// recently touched first and at most 64 (design § Sync integrity, 4).
    /// Every connect comes through here, and so does an app start.
    func sessionReady() {
        // A new run: every job and every late callback of the old session is
        // void (the same token the resync guards its replies with).
        jobToken += 1
        jobs.removeAll()
        let generation = jobToken
        let candidates = resyncCandidates()
        resyncFolders = candidates
        resyncCovered = Set(candidates.map(\.id))
        let action = resync.apply(.ready(candidates))
        Log.files.notice("resync: ready folders=\(candidates.count, privacy: .public)")
        runResync(action, generation: generation)
    }

    /// The session ended (or the switch went off): every pass is abandoned, the
    /// resync goes back to idle, and the next ready starts over. A late phone
    /// reply changes nothing.
    func sessionDropped() {
        jobToken += 1
        jobs.removeAll()
        _ = resync.apply(.dropped)
        resyncCovered.removeAll()
        resyncFolders.removeAll()
        Log.files.notice("resync: dropped")
    }

    /// The record's folders, most recently touched first, at most 64. The root
    /// is always one of them when there are any: its digest is what lets the
    /// machine trust a not_found for the others.
    private func resyncCandidates() -> [FilesResync.Folder] {
        let root = FilesMap.rootIdentifier
        let ordered = replica.folders
            .filter { !filesSystemContainer($0.key) && $0.key != root }
            .sorted { left, right in
                if left.value.touched != right.value.touched {
                    return left.value.touched > right.value.touched
                }
                return left.key < right.key
            }
        var folders: [FilesResync.Folder] = []
        var seen: Set<String> = [""]
        for (identifier, record) in ordered where folders.count < FilesResync.folderLimit - 1 {
            guard let path = map.path(for: identifier), seen.insert(path).inserted else { continue }
            folders.append(FilesResync.Folder(id: identifier, path: path,
                                              recorded: record.digest))
        }
        guard !folders.isEmpty || replica.folders[root] != nil else { return [] }
        return [FilesResync.Folder(id: root, path: "",
                                   recorded: replica.folders[root]?.digest)] + folders
    }

    private func stepResync(_ event: FilesResync.Event, generation: Int) {
        guard generation == jobToken else { return }
        let before = resync.state
        let action = resync.apply(event)
        if before != resync.state {
            Log.files.notice("resync: \(before.code, privacy: .public) --\(event.code, privacy: .public)--> \(self.resync.state.code, privacy: .public)")
        }
        runResync(action, generation: generation)
    }

    private func runResync(_ action: FilesResync.Action, generation: Int) {
        guard generation == jobToken else { return }
        switch action {
        case .none, .finished:
            break
        case .ask(let paths):
            client.digest(paths: paths) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, generation == self.jobToken else { return }
                    switch result {
                    case .success(let values):
                        self.stepResync(.digests(self.answers(values)), generation: generation)
                    case .failure(let error):
                        // No usable digest (`fs_unknown`, or a refusal): compare
                        // by listing every folder, as a phone without the
                        // message would be handled.
                        Log.files.notice("resync: digest failed code=\(error.code, privacy: .public)")
                        self.stepResync(.unknown, generation: generation)
                    }
                }
            }
        case .apply(let deletions, let relist):
            for identifier in Set(deletions) { deleteRecordSubtree(identifier) }
            guard !relist.isEmpty else { return }
            Log.files.notice("resync: relisting=\(relist.count, privacy: .public) deleted=\(Set(deletions).count, privacy: .public)")
            for identifier in relist {
                let (record, _) = currentRecord(identifier)
                startHostPass(identifier,
                              .hostStart(recorded: record.count, start: record,
                                         token: generation)) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.stepResync(.listed(identifier), generation: generation)
                    }
                }
            }
        }
    }

    private func answers(_ values: [String: FsDigestReply]) -> [FilesResync.Answer] {
        resyncFolders.map { folder in
            FilesResync.Answer(folder: folder, digest: values[folder.path])
        }
    }

    /// A folder the phone says is gone: one delta in its parent's container
    /// (so that enumerator sees it), with the folder and everything the record
    /// held under it; then the records and the id map go.
    private func deleteRecordSubtree(_ identifier: String) {
        guard identifier != FilesMap.rootIdentifier,
              !filesSystemContainer(identifier) else { return }
        let container = parent(of: identifier)
        var deleted: [String] = []
        var seen: Set<String> = []
        var frontier = [identifier]
        while let next = frontier.popLast() {
            guard let record = replica.folders.removeValue(forKey: next) else { continue }
            jobs.removeValue(forKey: next)
            if seen.insert(next).inserted { deleted.append(next) }
            for (childID, child) in record.children {
                if seen.insert(childID).inserted { deleted.append(childID) }
                if child.isDirectory { frontier.append(childID) }
            }
        }
        if var record = replica.folders[container] {
            record.children.removeValue(forKey: identifier)
            record.touched = clock()
            replica.folders[container] = record
        }
        if let path = map.path(for: identifier) {
            _ = map.invalidate(subtree: path)
        }
        let delta = FilesDelta(items: [], deleted: deleted)
        if replica.log.record(container: container, delta: delta) {
            signal([container])
        }
        save()
        Log.files.notice("resync: folder gone items=\(deleted.count, privacy: .public)")
    }

    // MARK: Uploads in flight (FILES-31)

    private func beginUpload(identifier: String?, parent: String, name: String?) {
        if let identifier { uploading.insert(identifier) }
        if let name { uploadNames[parent, default: []].insert(name) }
    }

    private func endUpload(identifier: String?, parent: String, name: String?) {
        if let identifier { uploading.remove(identifier) }
        if let name {
            uploadNames[parent]?.remove(name)
            if uploadNames[parent]?.isEmpty != false { uploadNames.removeValue(forKey: parent) }
        }
    }

    // MARK: Not-found repair (FILES-34)

    /// The phone answered `fs_not_found` for an item's thumbnail, read or stat:
    /// the item is gone. Report it deleted and re-list its parent once.
    private func notFound(_ item: String, path: String? = nil) {
        guard item != FilesMap.rootIdentifier, !filesSystemContainer(item) else { return }
        if let path { forget(map.invalidate(subtree: path)) }
        replica.folders.removeValue(forKey: item)
        jobs.removeValue(forKey: item)
        let container = parent(of: item)
        removeReported(item, from: container)
        Log.files.notice("bridge: not found repair")
        let (record, _) = currentRecord(container)
        startHostPass(container,
                      .notFound(recorded: record.count, start: record, token: jobToken))
    }

    /// A subtree the id map no longer knows: its folders' records and jobs are
    /// stale too.
    private func forget(_ identifiers: [String]) {
        for identifier in identifiers {
            replica.folders.removeValue(forKey: identifier)
            jobs.removeValue(forKey: identifier)
        }
    }

    func delete(item: String, base: String, recursive: Bool,
                completion: @escaping (Result<Void, FsError>) -> Void) {
        onTouch?(parent(of: item))
        let container = parent(of: item)
        resolve(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let path):
                // The phone checks the version right before it deletes: one
                // round trip, no stat-then-delete window.
                self.client.delete(path: path, recursive: recursive, etag: base) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success:
                        self.forget(self.map.invalidate(subtree: path))
                        self.replica.folders.removeValue(forKey: item)
                        self.removeReported(item, from: container)
                        self.save()
                        completion(.success(()))
                    }
                }
            }
        }
    }

    // MARK: Watching (design "S5 round 3")

    /// The folder is in the system's view (its enumerator, a listing, a stat of
    /// its child, or a write in it): tell the phone to watch it. The app's watch
    /// set owns the ten minutes and the cap; this only asks for the transition.
    func touch(item: String, completion: @escaping (Result<Void, FsError>) -> Void) {
        guard !filesSystemContainer(item) else {
            return completion(.failure(FsError(code: "fs_not_found")))
        }
        resolveKind(item) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let resolved) where !resolved.dir:
                // A watch names a folder. The system can still ask about a file
                // (a preview did): the phone refuses `fs_not_a_dir`, and the
                // file's folder is what the list of changes is about anyway. A
                // watch for the parent covers the file's own changes too.
                let parent = self.parent(of: item)
                guard parent != item else { return completion(.success(())) }
                self.touch(item: parent, completion: completion)
            case .success(let resolved):
                self.noteTouched(item)
                if self.pathByItem[item] == resolved.path {
                    return completion(.success(()))
                }
                self.pathByItem[item] = resolved.path
                self.itemsByPath[resolved.path, default: []].insert(item)
                self.visit(item)
                self.client.watch(paths: [resolved.path], on: true, completion: completion)
            }
        }
    }

    /// The ten minutes are over or the cap dropped this folder: the phone stops
    /// watching its path when no other container shares it.
    func unwatch(item: String, completion: @escaping (Result<Void, FsError>) -> Void) {
        // A folder that leaves the watch set is compared by its next touch
        // again: the resync's cover ends with the watch's life.
        resyncCovered.remove(item)
        guard let path = pathByItem.removeValue(forKey: item) else {
            return completion(.success(()))
        }
        itemsByPath[path]?.remove(item)
        if itemsByPath[path]?.isEmpty != false {
            itemsByPath.removeValue(forKey: path)
            client.watch(paths: [path], on: false, completion: completion)
        } else {
            completion(.success(()))
        }
    }

    func changes(item: String, from: String?,
                 completion: @escaping (Result<FilesChangesReply, FsError>) -> Void) {
        let log = replica.log
        if item == filesWorkingSetIdentifier {
            // The working set's first enumeration: every item the record says
            // the system has, not just this process's cache (FILES-32).
            if from == nil {
                var seen: [String: FileItem] = [:]
                for folder in replica.folders.values {
                    for (identifier, mapped) in folder.children { seen[identifier] = mapped }
                }
                return completion(.success(FilesChangesReply(
                    anchor: log.anchor, delta: FilesDelta(items: Array(seen.values), deleted: []),
                    expired: false)))
            }
        } else {
            guard !filesSystemContainer(item) else {
                return completion(.failure(FsError(code: "fs_not_found")))
            }
            onTouch?(item)
        }
        let container: String? = item == filesWorkingSetIdentifier ? nil : item
        guard let delta = log.changes(from: from, container: container) else {
            return completion(.success(FilesChangesReply(anchor: log.anchor, delta: .none,
                                                        expired: true)))
        }
        let anchor = container.map { log.containerAnchor($0) } ?? log.anchor
        completion(.success(FilesChangesReply(anchor: anchor, delta: delta, expired: false)))
    }

    func anchor(item: String, completion: @escaping (Result<String, FsError>) -> Void) {
        if item != filesWorkingSetIdentifier {
            guard !filesSystemContainer(item) else {
                return completion(.failure(FsError(code: "fs_not_found")))
            }
            onTouch?(item)
            return completion(.success(replica.log.containerAnchor(item)))
        }
        completion(.success(replica.log.anchor))
    }

    func filesChanged(paths: [String]) {
        for path in paths {
            for item in itemsByPath[path] ?? [] { refresh(item) }
        }
    }

    /// A folder starts being watched (its first touch in this process, or the
    /// first since the watch set dropped it): list it once. The walk diffs the
    /// listing against the record, so what changed on the phone while nothing
    /// watched it reaches the system (design § Sync integrity, 2). Later touches
    /// only keep the watch alive; the phone's pushes cover the rest.
    private func visit(_ item: String) {
        // The resync already compared this folder against the phone (its digest,
        // or its own listing): a re-watch touch must not list it a second time.
        guard !resyncCovered.contains(item) else { return }
        let (record, _) = currentRecord(item)
        startHostPass(item, .visit(recorded: record.count, start: record, token: jobToken))
    }

    /// Re-lists one container after a phone push; the walk diffs it against the
    /// record and signals when something moved (FILES-31). The job settles the
    /// push briefly first (a rename arrives as a delete and an add), holds one
    /// pass at a time per folder, and remembers one more if it moved again.
    private func refresh(_ item: String) {
        startHostPass(item, .refresh(token: jobToken))
    }

    /// Starts one app-driven pass and runs what the job asks for. The closure
    /// runs once, when the pass is over.
    private func startHostPass(_ item: String, _ event: FolderJob.Event,
                               completion: ((Result<Void, FsError>) -> Void)? = nil) {
        run(step(event, on: item), item: item, completion: completion)
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
    /// The watch subscriptions the extension clients hold, so a push reaches the
    /// ones that asked for that container (design §5). The phone's watches are
    /// the bridge's `watchSet`, not a per-client ref-count (round 3).
    private var watchSets: [ObjectIdentifier: Set<String>] = [:]
    private var watchClients: [ObjectIdentifier: FilesBridgeClient] = [:]
    /// Folders the system touched, kept for ten minutes after the last touch,
    /// at most 64 (design "S5 round 3"). It outlives a session: the phone's
    /// watches are dropped on disconnect and re-sent on reconnect.
    var watchSet = FilesWatchSet()
    /// The clock the watch set uses; the tests move it by hand.
    var watchClock: () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// FILES-29: the deadline of one thumb request, measured from the ask.
    var thumbDeadline: TimeInterval = 8
    /// At most three thumbnails run, the rest wait (FILES-25).
    let thumbQueue = FilesThumbQueue()
    private var expiryTimer: DispatchWorkItem?
    /// Working-set signals are coalesced: at most two a second (design).
    static let minSignalGap: TimeInterval = 0.5
    private var lastSignal: TimeInterval = -.greatestFiniteMagnitude
    private var signalScheduled = false

    private var listener: FilesBridgeListener?
    private var host: FilesBridgeHost?
    private(set) var socketPath: String?
    /// Asks the system to re-enumerate the working set. Set once by the app: the
    /// bridge cannot reach NSFileProviderManager without the live domain. A
    /// replicated extension may only be signalled through the working set
    /// (NSFileProviderManager.h), so this is the only signal there is.
    var signalWorkingSet: (() -> Void)?

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

    /// The socket goes away (the Files switch turned off). The session's host
    /// stays: only `detach` drops it, when the session ends. The session
    /// attaches it once, when it becomes ready, so a switch turned on again
    /// while the phone is connected must find it here.
    func stop() {
        listener?.stop()
        listener = nil
        socketPath = nil
        thumbQueue.reset()
        host?.sessionDropped()
        host?.cancelAll()
        liveIDs.removeAll()
        readIDs.removeAll()
        writeSinks.removeAll()
        watchSets.removeAll()
        watchClients.removeAll()
        watchSet.removeAll()
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    /// A session became ready: the bridge answers from now on, and the folders
    /// whose ten minutes have not run out are watched on the phone again
    /// (design "S5 round 3": dropped on disconnect, re-sent on reconnect).
    func attach(host: FilesBridgeHost) {
        self.host?.cancelAll()
        self.host = host
        host.onTouch = { [weak self] item in self?.touchWatch(item) }
        // The record's folders are compared before the watch set is re-sent, so
        // a folder inside its ten minutes is checked once, not listed twice.
        host.sessionReady()
        expireWatches()
        let wanted = watchSet.lastTouch.keys.sorted()
        for item in wanted {
            host.touch(item: item) { result in
                if case .failure(let error) = result {
                    Log.files.notice("bridge: re-watch failed code=\(error.code, privacy: .public)")
                }
            }
        }
        scheduleExpiry()
        Log.files.notice("bridge: session attached, re-watched \(wanted.count, privacy: .public)")
    }

    /// The session ended: requests answer `offline` until the next attach. The
    /// phone's watches are gone with the session; the timestamps stay so a quick
    /// reconnect re-sends the folders that are still inside their ten minutes.
    func detach() {
        thumbQueue.reset()
        host?.sessionDropped()
        host?.cancelAll()
        host = nil
        liveIDs.removeAll()
        readIDs.removeAll()
        writeSinks.removeAll()
        Log.files.notice("bridge: session detached")
    }

    /// A watched container moved: push the news to every extension process that
    /// asked for it, and signal the working set once. The extension processes are
    /// short-lived — Finder does not keep one alive between two operations — so a
    /// push alone reaches nobody exactly when a phone-side change arrives with no
    /// extension running. Since round 3 the only signal a replicated extension
    /// may send is the working set (`NSFileProviderManager.h`: other container
    /// identifiers are ignored), so `signalWorkingSet` is that one call,
    /// coalesced to at most two a second.
    func signal(containers: [String]) {
        guard !containers.isEmpty else { return }
        for (slot, client) in watchClients {
            let mine = (watchSets[slot] ?? []).filter { containers.contains($0) }
            if !mine.isEmpty { client.sendSignal(items: Array(mine)) }
        }
        requestWorkingSetSignal()
        Log.files.notice("bridge: signal containers=\(containers.count, privacy: .public)")
    }

    /// One working-set signal now, or one scheduled for the end of the current
    /// half second (a phone-side burst becomes one call).
    private func requestWorkingSetSignal() {
        guard signalWorkingSet != nil else { return }
        let now = watchClock()
        let wait = Self.minSignalGap - (now - lastSignal)
        if wait <= 0 {
            fireWorkingSetSignal()
            return
        }
        guard !signalScheduled else { return }
        signalScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.signalScheduled = false
                self.fireWorkingSetSignal()
            }
        }
    }

    private func fireWorkingSetSignal() {
        lastSignal = watchClock()
        signalWorkingSet?()
    }

    // MARK: The watch set (design "S5 round 3")

    /// A touch keeps the folder on the phone for ten minutes. The first touch
    /// adds it (and drops the least recently touched when 64 are held); a later
    /// one only refreshes its time.
    private func touchWatch(_ item: String,
                            completion: ((Result<Void, FsError>) -> Void)? = nil) {
        guard !filesSystemContainer(item) else {
            completion?(.failure(FsError(code: "fs_not_found")))
            return
        }
        let now = watchClock()
        switch watchSet.touch(item, now: now) {
        case .added(let evicted):
            if let evicted {
                Log.files.notice("bridge: watch set full, dropped the oldest")
                host?.unwatch(item: evicted) { _ in }
            }
            guard let host, host.isConnected else {
                completion?(.failure(FsError(code: "offline")))
                return
            }
            host.touch(item: item) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    // Nothing is watching that folder: let a later touch try again.
                    self.watchSet.remove(item)
                    Log.files.notice("bridge: phone watch failed code=\(error.code, privacy: .public)")
                } else {
                    Log.files.notice("bridge: phone watch on")
                }
                completion?(result)
            }
        case .refreshed:
            // A new session's host has no path for it yet; a repeated touch in
            // the same session answers from its own map and sends nothing.
            host?.touch(item: item) { result in completion?(result) }
        }
        scheduleExpiry()
    }

    /// Expires everything whose ten minutes are over, then re-arms the timer for
    /// the next one.
    func expireWatches() {
        let gone = watchSet.expire(now: watchClock())
        for item in gone {
            host?.unwatch(item: item) { _ in }
        }
        if !gone.isEmpty {
            Log.files.notice("bridge: watch ttl off count=\(gone.count, privacy: .public)")
        }
    }

    private func scheduleExpiry() {
        expiryTimer?.cancel()
        expiryTimer = nil
        let now = watchClock()
        guard let next = watchSet.lastTouch.values.map({ $0 + watchSet.ttl }).min() else { return }
        let wait = max(0.05, next - now + 0.05)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expiryTimer = nil
                self.expireWatches()
                self.scheduleExpiry()
            }
        }
        expiryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// The phone reported these folders changed: the host re-lists them.
    func filesChanged(paths: [String]) {
        host?.filesChanged(paths: paths)
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
        case .thumb(let id, let item, let size):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            thumbQueue.request(id: id, client: slot, item: item, size: size,
                               deadline: thumbDeadline, host: host) { [weak self, weak client] answer in
                MainActor.assumeIsolated {
                    guard let self, let client else { return }
                    self.end(id, client)
                    switch answer {
                    case .success(let thumb):
                        client.sendData(id: id, bytes: thumb.data)
                        client.send(.thumb(id: id, mime: thumb.mime,
                                           size: thumb.data.count, sha256: thumb.sha256))
                        let mime = thumb.mime == "image/png" ? "png" : "jpeg"
                        Log.files.notice("bridge: thumb done bytes=\(thumb.data.count, privacy: .public) mime=\(mime, privacy: .public)")
                    case .failure(let code):
                        client.send(.error(id: id, code: code))
                        Log.files.notice("bridge: thumb failed code=\(code, privacy: .public)")
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
        case .watch(let id, let items, let on):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            applyWatch(items, on: on, client: client) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.end(id, client)
                    switch result {
                    case .success:
                        client.send(.ok(id: id))
                    case .failure(let error):
                        client.send(.error(id: id, code: error.code))
                    }
                }
            }
            Log.files.notice("bridge: watch on=\(on, privacy: .public) items=\(items.count, privacy: .public)")
        case .changes(let id, let item, let from):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.changes(item: item, from: from) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.end(id, client)
                    switch result {
                    case .success(let reply):
                        client.send(.changes(id: id, anchor: reply.anchor, items: reply.delta.items,
                                             deleted: reply.delta.deleted, expired: reply.expired))
                        Log.files.notice("bridge: changes expired=\(reply.expired, privacy: .public) items=\(reply.delta.items.count, privacy: .public) deleted=\(reply.delta.deleted.count, privacy: .public)")
                    case .failure(let error):
                        client.send(.error(id: id, code: error.code))
                        Log.files.notice("bridge: changes failed code=\(error.code, privacy: .public)")
                    }
                }
            }
        case .anchor(let id, let item):
            guard let host, host.isConnected else { return client.send(.error(id: id, code: "offline")) }
            guard begin(id, client) else { return }
            host.anchor(item: item) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.end(id, client)
                    switch result {
                    case .success(let anchor):
                        client.send(.anchor(id: id, anchor: anchor))
                    case .failure(let error):
                        client.send(.error(id: id, code: error.code))
                    }
                }
            }
        case .cancel(let id):
            if thumbQueue.cancel(id: id, client: slot) { return }
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

    /// One client says which containers it is showing. Since round 3 a watch is
    /// a touch: the folder stays on the phone for ten minutes after it, so
    /// `on: false` only ends the pushes, not the subscription (design "S5
    /// round 3").
    private func applyWatch(_ items: [String], on: Bool, client: FilesBridgeClient,
                            completion: @escaping (Result<Void, FsError>) -> Void) {
        let slot = ObjectIdentifier(client)
        var set = watchSets[slot] ?? []
        watchClients[slot] = client
        if on {
            set.formUnion(items)
        } else {
            set.subtract(items)
        }
        watchSets[slot] = set
        guard on else { return completion(.success(())) }
        var rest = items
        func next() {
            guard !rest.isEmpty else { return completion(.success(())) }
            let item = rest.removeFirst()
            touchWatch(item) { result in
                switch result {
                case .success: next()
                case .failure(let error): completion(.failure(error))
                }
            }
        }
        next()
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
        thumbQueue.cancel(client: slot)
        for (_, sink) in writeSinks[slot] ?? [:] { sink.cancel() }
        readIDs.removeValue(forKey: slot)
        writeSinks.removeValue(forKey: slot)
        liveIDs.removeValue(forKey: slot)
        // An extension process that went away stops receiving pushes. Its
        // folders stay watched on the phone until their ten minutes run out
        // (design "S5 round 3"): the extension was not the thing keeping them.
        watchSets.removeValue(forKey: slot)
        watchClients.removeValue(forKey: slot)
        Log.files.notice("bridge: client gone")
    }
}
