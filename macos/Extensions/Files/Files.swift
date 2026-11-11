// Phone files in Finder: the replicated File Provider extension (docs/design/
// files.md §1, §3, §4; slices S3 and S4). It owns no phone session and holds no
// keys: the app does, so every answer here comes from the app over a UNIX socket
// in the shared App Group container. Requests name items by identifier; the app
// owns the id ↔ path map, so a rename or a move keeps the item Finder knows.
//
// Reads stream file bytes app → extension into the extension's own temp file.
// Writes stream the extension's bytes extension → app after the app's `ready`,
// with a real Progress; a cancel sends the bridge's `cancel` (which becomes
// `fs.cancel`). With the phone away the answer is serverUnreachable, so the
// system keeps the change pending and retries after reconnect. A write whose
// base version is stale keeps both: the Mac's bytes become a "(from Mac)" copy
// and the phone's item is returned. There is no trash container: a delete is
// immediate, and the capabilities say so.
//
// Nothing here logs a file name, a path or content: op names, lengths, ids and
// codes only (design §4).
//
// Built by macos/scripts/bundle.sh with swiftc, together with FilesCore.swift
// (the wire, the item mapping, the id map's shape and the error map). The class
// is named in the Info.plist's NSExtensionPrincipalClass as FilesExtension.

import CryptoKit
import FileProvider
import Foundation
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "app.contigua.mac", category: "files")

/// The read and write cap (design §3: a write body is at most 1 GiB; reads
/// follow the file, and anything this large is refused with a clear error).
private let maxTransferBytes = 1024 * 1024 * 1024

/// The extension's chunk size on the bridge: the phone's FS_DATA frame, and the
/// drop pacing's unit.
private let transferChunk = 256 * 1024

// MARK: - Bridge connection

/// One request (or one streamed transfer) per connection. The app serialises
/// the work; the extension only maps calls onto the wire.
final class BridgeConnection {
    enum Reply {
        case reply(BridgeReply)
        case data([UInt8])
        /// The app pushed a change on the watch connection (design §5).
        case signal([String])
    }

    private let fd: Int32
    private let writeLock = NSLock()
    private var decoder = BridgeDecoder(maxLineBytes: BridgeWire.maxReplyLineBytes)
    private var queue: [Reply] = []

    init?(path: String, readTimeout: Int = 20) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            return nil
        }
        // The app may close a connection first; a write then fails instead of
        // raising SIGPIPE, which would kill this process.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                   socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: readTimeout, tv_usec: 0)
        if readTimeout > 0 {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        var sendTimeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { Darwin.close(fd) }

    func send(_ request: BridgeRequest) -> Bool {
        write(BridgeWire.line(request))
    }

    /// One chunk of an upload: the `data` header and exactly its bytes.
    func sendData(id: UInt32, bytes: [UInt8]) -> Bool {
        var data = BridgeWire.dataHeader(id: id, length: bytes.count)
        data.append(contentsOf: bytes)
        return write(data)
    }

    private func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// The next reply frame, blocking until one arrives; nil means the bridge
    /// closed or answered something this side does not understand. With
    /// [waitForever] the socket's receive timeout is bypassed: the watch
    /// connection is idle between changes and must not mistake quiet for death.
    func next(waitForever: Bool = false) -> Reply? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if !queue.isEmpty { return queue.removeFirst() }
            if waitForever {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, -1)
                if ready < 0 && errno == EINTR { continue }
                if ready <= 0 { return nil }
            }
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 {
                if count < 0 && errno == EINTR { continue }
                return nil
            }
            for event in decoder.feed(Array(buffer[0..<count])) {
                switch event {
                case .reply(let reply):
                    queue.append(.reply(reply))
                case .data(_, let bytes):
                    queue.append(.data(bytes))
                case .dataHeader:
                    break
                case .signal(let items):
                    queue.append(.signal(items))
                case .invalid, .request:
                    return nil
                }
            }
            if decoder.broken { return nil }
        }
    }
}

/// The extension's standing subscription to the folders it has open (design
/// §5, S5). One connection per process, kept open by a reader thread: the app
/// answers `changed` push lines on it and the extension signals the enumerator
/// the system gave it. The connection sends `watch`/`unwatch` and nothing else;
/// if the app restarts, the next enumerator call reconnects and re-subscribes.
final class WatchChannel {
    private let domain: NSFileProviderDomain
    /// Called for every change push, before the log, so a cache can be dropped
    /// on the reader's own thread (FILES-30).
    private let onChange: ([String]) -> Void
    private let lock = NSLock()
    private var items: Set<String> = []
    private var connection: BridgeConnection?
    private var thread: Thread?
    /// A fresh id per request: a reply that never came must not poison the next
    /// subscribe (the app refuses a duplicate live id).
    private var nextID: UInt32 = 1

    init(domain: NSFileProviderDomain, onChange: @escaping ([String]) -> Void = { _ in }) {
        self.domain = domain
        self.onChange = onChange
    }

    /// Adds or removes one container. A container that is already in the set is
    /// a no-op, so an enumerator being rebuilt is cheap.
    func set(_ item: String, on: Bool) {
        lock.lock()
        if on { items.insert(item) } else { items.remove(item) }
        lock.unlock()
        // Always re-assert: the app ref-counts, so a duplicate on/off is a
        // no-op there, and a re-assert is what repairs a mismatch after the
        // app's session (and its watch ref-counts) came back from a reconnect.
        if !send(.watch(id: freshID(), items: [item], on: on)) {
            // The app is not there (yet, or any more): one reconnect, then a
            // full re-subscription, so a restarted app knows the whole set.
            if !connect() {
                log.notice("watch: the app is not reachable")
                return
            }
            let set = Array(items)
            if !set.isEmpty {
                _ = send(.watch(id: freshID(), items: set, on: true))
            }
        }
    }

    private func freshID() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        nextID += 1
        if nextID == 0 { nextID = 2 }
        return nextID
    }

    /// Sends on the current connection; false means it is gone.
    private func send(_ request: BridgeRequest) -> Bool {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { return false }
        if connection.send(request) { return true }
        lock.lock()
        if self.connection === connection { self.connection = nil }
        lock.unlock()
        return false
    }

    /// Opens the connection and starts its reader; false when the app is away.
    @discardableResult
    private func connect() -> Bool {
        lock.lock()
        if connection != nil { lock.unlock(); return true }
        lock.unlock()
        guard let path = bridgeSocketPath(domain: domain),
              let live = BridgeConnection(path: path),
              live.send(.hello(id: 1, version: filesBridgeVersion)),
              let hello = live.next(), case .reply(.hello(_, let version, _, _)) = hello,
              version == filesBridgeVersion else { return false }
        lock.lock()
        connection = live
        let reader = Thread { [weak self] in self?.readLoop(live) }
        reader.name = "pd-files-watch"
        thread = reader
        lock.unlock()
        reader.start()
        return true
    }

    private func readLoop(_ live: BridgeConnection) {
        while true {
            guard let frame = live.next(waitForever: true) else { break }
            if case .signal(let containers) = frame { signal(containers) }
        }
        lock.lock()
        if connection === live {
            connection = nil
            thread = nil
        }
        let wanted = Array(items)
        lock.unlock()
        guard !wanted.isEmpty else { return }
        // The app's bridge went away (a restart, or the domain reconnecting):
        // open a fresh connection and re-subscribe, with a short backoff so a
        // restarting app is not hammered.
        for attempt in 0..<15 {
            Thread.sleep(forTimeInterval: 1.0 + Double(attempt))
            if connect() {
                if send(.watch(id: freshID(), items: wanted, on: true)) { return }
            }
        }
        log.notice("watch: could not re-subscribe")
    }

    /// The app pushed news about containers on this connection. The extension
    /// cannot signal them: a replicated extension may only signal the working
    /// set, and the app does that itself (design "S5 round 3"). The push is the
    /// fast path only, so there is nothing to do here but account for it.
    private func signal(_ containers: [String]) {
        onChange(containers)
        log.notice("watch: changed containers=\(containers.count, privacy: .public)")
    }
}

/// What the socket path means for this domain: the App Group container from the
/// bundle's Info.plist, the file named after the profile (the domain identifier).
func bridgeSocketPath(domain: NSFileProviderDomain) -> String? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "PDFilesGroup") as? String,
          !group.isEmpty,
          let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
    let profile = domain.identifier.rawValue
    let name = profile == "default" ? "files.sock" : "files-\(profile).sock"
    return container.appendingPathComponent(name).path
}

private func bridgeConnection(for domain: NSFileProviderDomain,
                              readTimeout: Int = 20) -> BridgeConnection? {
    guard let path = bridgeSocketPath(domain: domain) else { return nil }
    return BridgeConnection(path: path, readTimeout: readTimeout)
}

// MARK: - Errors

extension FilesFailure {
    /// The NSError classes the system documents for a replicated provider.
    var error: Error {
        switch self {
        case .offline:
            return NSFileProviderError(.serverUnreachable)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .denied:
            return CocoaError(.fileReadNoPermission)
        case .stale:
            // The caller refetched once already; if it is still stale it is gone
            // from this side's point of view.
            return NSFileProviderError(.noSuchItem)
        case .tooLarge:
            return CocoaError(.fileReadTooLarge)
        case .exists:
            // A rename or move onto a name that is already taken.
            return NSFileProviderError(.filenameCollision)
        case .notADirectory:
            return CocoaError(.fileReadInvalidFileName)
        case .busy:
            return NSFileProviderError(.serverUnreachable)
        case .cancelled:
            return CocoaError(.userCancelled)
        case .io:
            return CocoaError(.fileReadUnknown)
        case .protocolError:
            return CocoaError(.fileReadCorruptFile)
        }
    }
}

// MARK: - Items

final class ProviderItem: NSObject, NSFileProviderItem {
    let mapped: FileItem

    init(_ mapped: FileItem) {
        self.mapped = mapped
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        mapped.identifier == FilesMap.rootIdentifier
            ? .rootContainer : NSFileProviderItemIdentifier(mapped.identifier)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        mapped.parentIdentifier == FilesMap.rootIdentifier
            ? .rootContainer : NSFileProviderItemIdentifier(mapped.parentIdentifier)
    }

    var filename: String { mapped.name }
    var contentType: UTType { UTType(mapped.contentTypeIdentifier) ?? .data }
    var documentSize: NSNumber? { mapped.isDirectory ? nil : NSNumber(value: mapped.size) }
    var contentModificationDate: Date? { mapped.modificationDate }
    var isDirectory: Bool { mapped.isDirectory }
    var isMostRecentVersionDownloaded: Bool { true }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: mapped.contentVersion,
                                  metadataVersion: mapped.metadataVersion)
    }
    /// No trash container on the phone: Finder's delete is immediate, and it
    /// says so because `allowsTrashing` is absent (design §4).
    var capabilities: NSFileProviderItemCapabilities {
        if mapped.isDirectory {
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems,
                    .allowsRenaming, .allowsReparenting, .allowsDeleting]
        }
        return [.allowsReading, .allowsWriting, .allowsRenaming,
                .allowsReparenting, .allowsDeleting]
    }
}

/// What one upload needs from the wire: the request id (for cancel) and the
/// connection it runs on.
final class WriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var connection: BridgeConnection?
    private var id: UInt32?

    func begin(connection: BridgeConnection, id: UInt32) {
        lock.lock()
        self.connection = connection
        self.id = id
        lock.unlock()
        if isCancelled {
            _ = connection.send(.cancel(id: id))
        }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let connection = self.connection
        let id = self.id
        lock.unlock()
        guard let connection, let id else { return }
        _ = connection.send(.cancel(id: id))
        log.notice("write cancelled")
    }
}

// MARK: - Extension

@objc(FilesExtension)
final class FilesExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    let domain: NSFileProviderDomain
    private let work = DispatchQueue(label: "app.contigua.mac.files-extension", qos: .utility)
    /// One thumbnail pool for this extension process, shared by every Finder
    /// batch it is asked for (FILES-25).
    private let thumbs = FilesThumbScheduler()
    /// One phone-page cache for every enumerator in this process (FILES-30):
    /// the system builds a new enumerator per Finder batch, so a per-enumerator
    /// cache fetched every 1,000-item phone page once per 250-item batch.
    private let pages = FilesPageCache()
    /// What a folder enumerator drives. Stateless: the pages live in `pages`.
    lazy var reader = FilesPageReader(cache: pages)
    /// The anchor S3 answers with: no changes are reported (S5 adds them).
    let anchor = NSFileProviderSyncAnchor(Data("files-s3".utf8))

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        let socket = bridgeSocketPath(domain: domain) == nil ? "none" : "group"
        log.notice("init profile=\(domain.identifier.rawValue, privacy: .public) socket=\(socket, privacy: .public)")
    }

    func invalidate() {
        log.notice("invalidate")
    }

    /// One listing off the main thread, for the enumerator.
    func loadListing(item: String, page: String?,
                     completion: @escaping (Result<(items: [FileItem], next: String?), FilesFailure>) -> Void) {
        work.async {
            completion(self.list(item: item, page: page))
        }
    }

    // MARK: Bridge operations

    private func connect(readTimeout: Int = 20) -> Result<BridgeConnection, FilesFailure> {
        guard let connection = bridgeConnection(for: domain, readTimeout: readTimeout) else {
            return .failure(.offline)
        }
        return .success(connection)
    }

    /// Sends `hello` on a fresh connection so the app knows the wire version.
    private func hello(_ connection: BridgeConnection) -> Bool {
        guard connection.send(.hello(id: 1, version: filesBridgeVersion)),
              let frame = connection.next(), case .reply(.hello(_, let version, _, _)) = frame
        else { return false }
        return version == filesBridgeVersion
    }

    func list(item: String, page: String?) -> Result<(items: [FileItem], next: String?), FilesFailure> {
        guard case .success(let connection) = connect() else { return .failure(.offline) }
        guard connection.send(.list(id: 1, item: item, page: page)) else { return .failure(.offline) }
        while let frame = connection.next() {
            guard case .reply(let reply) = frame else { continue }
            switch reply {
            case .items(_, let next, let items):
                return .success((items, next))
            case .error(_, let code):
                return .failure(FilesFailure.from(code: code))
            default:
                continue
            }
        }
        return .failure(.offline)
    }

    private func stat(item: String) -> Result<FileItem, FilesFailure> {
        guard case .success(let connection) = connect() else { return .failure(.offline) }
        guard connection.send(.stat(id: 1, item: item)) else { return .failure(.offline) }
        while let frame = connection.next() {
            guard case .reply(let reply) = frame else { continue }
            switch reply {
            case .item(_, let item):
                return .success(item)
            case .error(_, let code):
                return .failure(FilesFailure.from(code: code))
            default:
                continue
            }
        }
        return .failure(.offline)
    }

    private func rootItem() -> FileItem {
        FilesMap.rootItem(name: domain.displayName, version: Data("root-s4".utf8))
    }

    // MARK: Watching (design "S5 round 3")

    /// One standing subscription per extension process. A container's
    /// enumerator (or a listing, a stat, a write) touches it: the app keeps the
    /// folder on the phone for ten minutes after the last touch, so `invalidate`
    /// only ends the pushes, not the watch.
    private lazy var watchChannel = WatchChannel(domain: domain) { [weak self] containers in
        // A change push invalidates that folder's cached pages at once: the
        // next Finder page must ask the phone, never replay a page the change
        // made stale (FILES-30).
        self?.pages.drop(containers: containers)
    }

    /// The system touched this container: the app watches it on the phone.
    func watch(_ identifier: String, on: Bool) {
        watchChannel.set(identifier, on: on)
    }

    /// Reads a container's deltas off the main thread, for the enumerator.
    func loadChanges(item: String, from: String?,
                     completion: @escaping (Result<FilesChangesReply, FilesFailure>) -> Void) {
        work.async { completion(self.changes(item: item, from: from)) }
    }

    func loadAnchor(item: String, completion: @escaping (Result<String, FilesFailure>) -> Void) {
        work.async { completion(self.anchor(item: item)) }
    }

    private func changes(item: String, from: String?) -> Result<FilesChangesReply, FilesFailure> {
        guard case .success(let connection) = connect(), hello(connection) else {
            return .failure(.offline)
        }
        guard connection.send(.changes(id: 1, item: item, from: from)) else { return .failure(.offline) }
        while let frame = connection.next() {
            guard case .reply(let reply) = frame else { continue }
            switch reply {
            case .changes(_, let anchor, let items, let deleted, let expired):
                return .success(FilesChangesReply(
                    anchor: anchor, delta: FilesDelta(items: items, deleted: deleted),
                    expired: expired))
            case .error(_, let code):
                return .failure(FilesFailure.from(code: code))
            default:
                continue
            }
        }
        return .failure(.offline)
    }

    private func anchor(item: String) -> Result<String, FilesFailure> {
        guard case .success(let connection) = connect(), hello(connection) else {
            return .failure(.offline)
        }
        guard connection.send(.anchor(id: 1, item: item)) else { return .failure(.offline) }
        while let frame = connection.next() {
            guard case .reply(let reply) = frame else { continue }
            switch reply {
            case .anchor(_, let anchor):
                return .success(anchor)
            case .error(_, let code):
                return .failure(FilesFailure.from(code: code))
            default:
                continue
            }
        }
        return .failure(.offline)
    }

    // MARK: NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(ProviderItem(rootItem()), nil)
            return Progress()
        }
        work.async {
            switch self.stat(item: identifier.rawValue) {
            case .success(let item):
                log.notice("item stat ok dir=\(item.isDirectory, privacy: .public) size=\(item.size, privacy: .public)")
                completionHandler(ProviderItem(item), nil)
            case .failure(let failure):
                log.notice("item stat failed code=\(failure.rawValue, privacy: .public)")
                completionHandler(nil, failure.error)
            }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // The two identifiers the system owns are never phone folders (design
        // "S5 round 3"): the working set has its own change log, the trash is
        // empty because a delete on the phone is immediate.
        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(extension: self)
        }
        if containerItemIdentifier == .trashContainer {
            return EmptyEnumerator()
        }
        // The system wants this folder: touch it on the phone (the app keeps it
        // for ten minutes after the last touch).
        let identifier = containerItemIdentifier == .rootContainer
            ? FilesMap.rootIdentifier : containerItemIdentifier.rawValue
        watch(identifier, on: true)
        return FilesEnumerator(extension: self, container: containerItemIdentifier)
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.isCancellable = true
        work.async {
            self.fetch(item: itemIdentifier.rawValue, requested: requestedVersion,
                       progress: progress, retried: false, completion: completionHandler)
        }
        return progress
    }

    /// stat → read the whole file into a temporary file → size + sha256 check.
    /// One `fs_stale` refetches the metadata and retries once (design §3).
    private func fetch(item: String, requested: NSFileProviderItemVersion?, progress: Progress,
                       retried: Bool,
                       completion: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) {
        let started = Date()
        let etag = requested.flatMap { String(data: $0.contentVersion, encoding: .utf8) }
        let metadata: FileItem
        switch stat(item: item) {
        case .success(let item):
            metadata = item
        case .failure(let failure):
            log.notice("fetch stat failed code=\(failure.rawValue, privacy: .public)")
            completion(nil, nil, failure.error)
            return
        }
        guard !metadata.isDirectory else {
            completion(nil, nil, FilesFailure.notFound.error)
            return
        }
        guard metadata.size <= maxTransferBytes else {
            log.notice("fetch refused size=\(metadata.size, privacy: .public)")
            completion(nil, nil, FilesFailure.tooLarge.error)
            return
        }
        guard case .success(let connection) = connect(), hello(connection) else {
            completion(nil, nil, FilesFailure.offline.error)
            return
        }
        let target = temporaryFile()
        FileManager.default.createFile(atPath: target.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: target) else {
            completion(nil, nil, FilesFailure.io.error)
            return
        }
        let state = ReadState(connection: connection)
        let id: UInt32 = 1
        state.begin(id: id)
        progress.totalUnitCount = Int64(max(metadata.size, 1))
        progress.completedUnitCount = 0
        progress.cancellationHandler = { [weak state] in
            state?.cancel()
        }
        guard connection.send(.read(id: id, item: item, offset: 0, length: metadata.size,
                                    etag: etag)) else {
            handle.closeFile()
            try? FileManager.default.removeItem(at: target)
            completion(nil, nil, FilesFailure.offline.error)
            return
        }
        var hasher = SHA256()
        var received = 0
        var failure: FilesFailure?
        // `end` is the read's terminal reply: whether it carried a hash mismatch
        // or the bytes are good, nothing else arrives on this connection. Waiting
        // for another frame cost the socket's 20 s receive timeout per fetch (a
        // Quick Look of a 412-byte file took 20 s, twice).
        var ended = false
        while let frame = connection.next() {
            if state.isCancelled {
                failure = .cancelled
                break
            }
            switch frame {
            case .data(let bytes):
                do {
                    try handle.write(contentsOf: Data(bytes))
                } catch {
                    failure = .io
                    break
                }
                hasher.update(data: Data(bytes))
                received += bytes.count
                progress.completedUnitCount = Int64(received)
                if received > metadata.size { failure = .io; break }
            case .signal:
                continue
            case .reply(let reply):
                switch reply {
                case .end(_, let size, let sha256):
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    if size != received || size != metadata.size || digest != sha256.lowercased() {
                        failure = .io
                    }
                    ended = true
                case .error(_, let code):
                    let mapped = FilesFailure.from(code: code)
                    failure = mapped == .stale && !retried ? .stale : mapped
                    ended = true
                default:
                    continue
                }
            }
            if failure != nil || ended { break }
        }
        handle.closeFile()
        if failure == nil && received != metadata.size { failure = .io }
        if let failure {
            try? FileManager.default.removeItem(at: target)
            log.notice("fetch failed code=\(failure.rawValue, privacy: .public) bytes=\(received, privacy: .public)")
            if failure == .stale && !retried {
                fetch(item: item, requested: nil, progress: progress, retried: true,
                      completion: completion)
                return
            }
            if failure == .cancelled { progress.cancel() }
            completion(nil, nil, failure.error)
            return
        }
        progress.completedUnitCount = progress.totalUnitCount
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        log.notice("fetch done bytes=\(received, privacy: .public) ms=\(elapsed, privacy: .public)")
        completion(target, ProviderItem(metadata), nil)
    }

    /// A file in the extension's own temporary directory: `temporaryDirectoryURL`
    /// when the manager has one, the sandbox's otherwise. The name is a UUID, so
    /// nothing about the phone's tree reaches the disk name.
    private func temporaryFile() -> URL {
        let manager = NSFileProviderManager(for: domain)
        let directory = (try? manager?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("pd-files-\(UUID().uuidString)")
    }

    // MARK: Writes (S4)

    /// The announced size and hash of one upload.
    private struct Upload {
        var size: Int
        var sha256: String
    }

    private func prepare(_ url: URL) throws -> Upload {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += chunk.count
        }
        return Upload(size: size,
                      sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Sends one create/modify and, when it asks for the body, streams `url`
    /// after the app's `ready`, then waits for the item (or the refusal).
    private func upload(_ request: BridgeRequest, url: URL?, announced: Upload?,
                        progress: Progress, state: WriteState) -> Result<FileItem, FilesFailure> {
        guard case .success(let connection) = connect(), hello(connection) else {
            return .failure(.offline)
        }
        let requestID = request.id
        state.begin(connection: connection, id: requestID)
        guard connection.send(request) else { return .failure(.offline) }
        // The app answers `ready` (bytes may come), or the item (nothing to
        // stream), or an error.
        var ready = false
        while let frame = connection.next() {
            guard case .reply(let reply) = frame else { continue }
            switch reply {
            case .ready:
                ready = true
            case .item(_, let item):
                return .success(item)
            case .error(_, let code):
                return .failure(FilesFailure.from(code: code))
            default:
                continue
            }
            break
        }
        guard ready, let url, let announced else {
            return ready ? .failure(.protocolError) : .failure(.offline)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            _ = connection.send(.cancel(id: requestID))
            return .failure(.io)
        }
        var sent = 0
        do {
            while let chunk = try handle.read(upToCount: transferChunk), !chunk.isEmpty {
                if state.isCancelled {
                    _ = connection.send(.cancel(id: requestID))
                    return .failure(.cancelled)
                }
                if !connection.sendData(id: requestID, bytes: [UInt8](chunk)) {
                    return .failure(.offline)
                }
                sent += chunk.count
                progress.completedUnitCount = Int64(sent)
                if sent > announced.size { return .failure(.io) }
            }
        } catch {
            _ = connection.send(.cancel(id: requestID))
            return .failure(.io)
        }
        try? handle.close()
        // The phone's answer: the new item, or why it refused.
        while let frame = connection.next() {
            guard case .reply(let reply) = frame else { continue }
            switch reply {
            case .item(_, let item):
                progress.completedUnitCount = progress.totalUnitCount
                return .success(item)
            case .error(_, let code):
                return .failure(FilesFailure.from(code: code))
            default:
                continue
            }
        }
        return .failure(.offline)
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let parent = itemTemplate.parentItemIdentifier == .rootContainer
            ? FilesMap.rootIdentifier : itemTemplate.parentItemIdentifier.rawValue
        let name = itemTemplate.filename
        let isDirectory = itemTemplate.contentType == .folder || url == nil && itemTemplate.documentSize == nil

        if isDirectory {
            work.async {
                let result = self.mutate(.create(id: 1, request: BridgeCreate(
                    parent: parent, name: name, dir: true, size: 0, sha256: nil)))
                switch result {
                case .success(let item):
                    completionHandler(ProviderItem(item), [], false, nil)
                case .failure(let failure):
                    log.notice("create failed code=\(failure.rawValue, privacy: .public)")
                    completionHandler(nil, [], false, failure.error)
                }
            }
            return progress
        }

        guard let url else {
            completionHandler(nil, [], false, CocoaError(.fileNoSuchFile))
            return progress
        }
        let upload: Upload
        do {
            upload = try prepare(url)
        } catch {
            completionHandler(nil, [], false, CocoaError(.fileReadUnknown))
            return progress
        }
        let state = WriteState()
        progress.isCancellable = true
        progress.totalUnitCount = Int64(max(upload.size, 1))
        progress.cancellationHandler = { state.cancel() }
        work.async {
            // A name taken on the phone (a photo taken since the listing) is
            // resolved here, not by the system: a POSIX copy is not replayed
            // with a new name by every client, and S4's VM run left such a copy
            // pending forever. The next free name is our own create.
            var result: Result<FileItem, FilesFailure> = .failure(.exists)
            for attempt in 0...FilesConflict.maxAttempts {
                let candidate: String
                if attempt == 0 {
                    candidate = name
                } else if let next = FilesConflict.collisionName(for: name, attempt: attempt) {
                    candidate = next
                } else {
                    break
                }
                let request = BridgeRequest.create(id: 1, request: BridgeCreate(
                    parent: parent, name: candidate, dir: false,
                    size: upload.size, sha256: upload.sha256))
                result = self.upload(request, url: url, announced: upload,
                                     progress: progress, state: state)
                if case .failure(.exists) = result { continue }
                break
            }
            if case .failure(.exists) = result {
                log.notice("create: no free name after \(FilesConflict.maxAttempts, privacy: .public) tries")
            }
            self.report(result, progress: progress) { item in
                completionHandler(ProviderItem(item), [], false, nil)
            } failure: { failure in
                completionHandler(nil, [], false, failure.error)
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let base = String(data: version.contentVersion, encoding: .utf8) ?? ""
        let identifier = item.itemIdentifier.rawValue
        let wantsContent = changedFields.contains(.contents)
        let newName = changedFields.contains(.filename) ? item.filename : nil
        let newParent = changedFields.contains(.parentItemIdentifier)
            ? (item.parentItemIdentifier == .rootContainer
                ? FilesMap.rootIdentifier : item.parentItemIdentifier.rawValue) : nil
        var mtime: Int?
        let changedDate: Date? = item.contentModificationDate ?? nil
        if changedFields.contains(.contentModificationDate), let changedDate {
            mtime = Int(changedDate.timeIntervalSince1970 * 1000)
        }

        // The system also sends modifies for its own replica's bookkeeping
        // (last-used date, tags, favourite rank). None of those exist on the
        // phone, so a modify that changes nothing the phone stores is answered
        // locally: sending `content=false` with no fields used to reach the
        // phone and re-write the file after every preview (design "Fixes 10-20").
        let change = FilesModifyChange(
            contents: wantsContent,
            filename: newName != nil,
            parent: newParent != nil,
            modificationDate: mtime != nil)
        let values = FilesModifyValues(
            name: item.filename,
            parent: item.parentItemIdentifier == .rootContainer
                ? FilesMap.rootIdentifier : item.parentItemIdentifier.rawValue,
            mtime: mtime)
        guard FilesModifyDecision.needsPhoneWrite(change, old: nil, new: values) else {
            log.notice("modify local: nothing the phone stores changed")
            completionHandler(item, [], false, nil)
            return progress
        }

        if !wantsContent {
            work.async {
                let request = BridgeRequest.modify(id: 1, request: BridgeModify(
                    item: identifier, base: base, content: false,
                    name: newName, parent: newParent, mtime: mtime, size: 0, sha256: nil))
                switch self.mutate(request) {
                case .success(let mapped):
                    completionHandler(ProviderItem(mapped), [], false, nil)
                case .failure(let failure):
                    log.notice("modify failed code=\(failure.rawValue, privacy: .public)")
                    completionHandler(nil, [], false, failure.error)
                }
            }
            return progress
        }

        guard let newContents else {
            completionHandler(nil, [], false, CocoaError(.fileNoSuchFile))
            return progress
        }
        let upload: Upload
        do {
            upload = try prepare(newContents)
        } catch {
            completionHandler(nil, [], false, CocoaError(.fileReadUnknown))
            return progress
        }
        let state = WriteState()
        progress.isCancellable = true
        progress.totalUnitCount = Int64(max(upload.size, 1))
        progress.cancellationHandler = { state.cancel() }
        work.async {
            let request = BridgeRequest.modify(id: 1, request: BridgeModify(
                item: identifier, base: base, content: true,
                name: newName, parent: newParent, mtime: mtime,
                size: upload.size, sha256: upload.sha256))
            let result = self.upload(request, url: newContents, announced: upload,
                                     progress: progress, state: state)
            if case .failure(.stale) = result {
                self.resolveConflict(item, contents: newContents, announced: upload,
                                     progress: progress, completion: completionHandler)
                return
            }
            self.report(result, progress: progress) { mapped in
                completionHandler(ProviderItem(mapped), [], false, nil)
            } failure: { failure in
                completionHandler(nil, [], false, failure.error)
            }
        }
        return progress
    }

    /// Keep both: the phone's item comes back as it is, and the Mac's bytes land
    /// next to it as `<name> (from Mac).<ext>` (design §4 "Conflicts"). The copy
    /// is an exclusive create, so a name taken while we tried it answers
    /// `fs_exists` and the next number is tried, up to 20. No name reaches the
    /// log.
    private func resolveConflict(_ item: NSFileProviderItem, contents: URL,
                                 announced: Upload, progress: Progress,
                                 completion: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) {
        let parent = item.parentItemIdentifier == .rootContainer
            ? FilesMap.rootIdentifier : item.parentItemIdentifier.rawValue
        let taken: Set<String>
        switch list(item: parent, page: nil) {
        case .failure:
            taken = []
        case .success(let page):
            taken = Set(page.items.map(\.name))
        }
        log.notice("conflict: keeping both")
        var copied: Result<FileItem, FilesFailure> = .failure(.exists)
        for attempt in 1...FilesConflict.maxAttempts {
            // A name the listing shows is skipped without uploading the file.
            guard let name = FilesConflict.candidate(for: item.filename, attempt: attempt),
                  !taken.contains(name) else { continue }
            let copy = BridgeRequest.create(id: 1, request: BridgeCreate(
                parent: parent, name: name, dir: false,
                size: announced.size, sha256: announced.sha256))
            let copyState = WriteState()
            copied = upload(copy, url: contents, announced: announced,
                            progress: progress, state: copyState)
            // A name that was free a moment ago can be taken by the phone: the
            // next number is next, not a failure of the whole conflict copy.
            if case .failure(.exists) = copied { continue }
            break
        }
        if case .failure(.exists) = copied {
            log.notice("conflict: no free name after \(FilesConflict.maxAttempts, privacy: .public) tries")
        }
        // The item the system asked about is the phone's current one.
        if case .success(let current) = stat(item: item.itemIdentifier.rawValue) {
            if case .failure = copied {
                log.notice("conflict: the copy failed")
            }
            completion(ProviderItem(current), [], false, nil)
            return
        }
        if case .failure(let failure) = copied {
            completion(nil, [], false, failure.error)
            return
        }
        completion(nil, [], false, NSFileProviderError(.noSuchItem))
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let base = String(data: version.contentVersion, encoding: .utf8) ?? ""
        let recursive = options.contains(.recursive)
        work.async {
            // The system knows about its own delete; no signal is needed (and a
            // per-container one would be ignored: design "S5 round 3").
            let request = BridgeRequest.delete(id: 1, item: identifier.rawValue,
                                               base: base, recursive: recursive)
            switch self.mutate(request) {
            case .success:
                completionHandler(nil)
            case .failure(.stale):
                // The phone's copy moved on: do not delete it; it comes back in
                // Finder on the next enumeration.
                log.notice("delete refused: stale (keeping the phone's item)")
                completionHandler(NSFileProviderError(.cannotSynchronize))
            case .failure(let failure):
                log.notice("delete failed code=\(failure.rawValue, privacy: .public)")
                completionHandler(failure.error)
            }
        }
        return progress
    }

    /// One create/modify/delete with no body: a folder, a rename, a date or a
    /// delete. Answers from the phone's `item` / `ok`, or its refusal.
    private func mutate(_ request: BridgeRequest) -> Result<FileItem, FilesFailure> {
        guard case .success(let connection) = connect(), hello(connection) else {
            return .failure(.offline)
        }
        guard connection.send(request) else { return .failure(.offline) }
        while let frame = connection.next() {
            guard case .reply(let reply) = frame else { continue }
            switch reply {
            case .item(_, let item):
                return .success(item)
            case .ok:
                // A delete has no item; the caller only needs the success.
                return .success(FilesMap.rootItem(name: "", version: Data()))
            case .error(_, let code):
                return .failure(FilesFailure.from(code: code))
            default:
                continue
            }
        }
        return .failure(.offline)
    }

    private func report(_ result: Result<FileItem, FilesFailure>, progress: Progress,
                        success: (FileItem) -> Void, failure onFailure: (FilesFailure) -> Void) {
        switch result {
        case .success(let item):
            log.notice("write done dir=\(item.isDirectory, privacy: .public) size=\(item.size, privacy: .public)")
            success(item)
        case .failure(let refusal):
            log.notice("write failed code=\(refusal.rawValue, privacy: .public)")
            if refusal == .cancelled {
                progress.cancel()
            }
            onFailure(refusal)
        }
    }
}

/// The cancel side of one fetchContents: the progress handler and the read loop
/// meet here, so a cancel reaches the app (which tells the phone to stop).
final class ReadState {
    private let lock = NSLock()
    private var id: UInt32?
    private var cancelled = false
    private let connection: BridgeConnection

    init(connection: BridgeConnection) {
        self.connection = connection
    }

    func begin(id: UInt32) {
        lock.lock()
        self.id = id
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = self.id
        lock.unlock()
        guard let id else { return }
        _ = connection.send(.cancel(id: id))
        log.notice("fetch cancelled")
    }
}

// MARK: - Thumbnails

/// A batch's answered count, for Finder's progress; per-thumbnail answers may
/// come from several threads at once.
private final class ThumbAnswerCount: NSLock, @unchecked Sendable {
    var count = 0
}

/// Who gets a picture at all: `FilesThumbPolicy` decides the type and the R-1
/// answer in FilesCore's companion file, so K2 pins both.
extension FilesExtension {
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier],
                         requestedSize: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(max(itemIdentifiers.count, 1)))
        progress.isCancellable = true
        let long = max(requestedSize.width, requestedSize.height)
        let size = min(FilesThumbPolicy.maxLongSide, max(1, Int(long.rounded(.up))))
        guard !itemIdentifiers.isEmpty else {
            completionHandler(nil)
            return progress
        }
        let started = Date()
        let answered = ThumbAnswerCount()
        // One pool for every batch: the scheduler decides what runs when, so
        // several Finder batches cannot put 3 x N asks on the bridge, and a
        // cancelled batch answers all of its ids and completes once.
        let batchID = thumbs.open(
            items: itemIdentifiers.map(\.rawValue),
            start: { [weak self] item, isCancelled, completion in
                DispatchQueue.global(qos: .utility).async {
                    guard let self else {
                        completion(nil, FilesThumbPolicy.error(for: "closed"))
                        return
                    }
                    let answer = self.thumb(item: item, size: size, isCancelled: isCancelled)
                    completion(answer.data, answer.error)
                }
            },
            per: { item, data, error in
                perThumbnailCompletionHandler(NSFileProviderItemIdentifier(item), data, error)
                answered.lock()
                answered.count += 1
                let count = answered.count
                answered.unlock()
                progress.completedUnitCount = Int64(count)
            },
            done: { error in
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                log.notice("thumb batch done n=\(itemIdentifiers.count, privacy: .public) ms=\(ms, privacy: .public)")
                completionHandler(error)
            })
        progress.cancellationHandler = { [weak self] in
            log.notice("thumb batch cancel id=\(batchID, privacy: .public) n=\(itemIdentifiers.count, privacy: .public)")
            self?.thumbs.cancel(batchID)
        }
        // A cancel that landed before the handler was set: cancel is idempotent.
        if progress.isCancelled { thumbs.cancel(batchID) }
        log.notice("thumb batch open id=\(batchID, privacy: .public) n=\(itemIdentifiers.count, privacy: .public) size=\(size, privacy: .public)")
        return progress
    }

    /// One item's thumbnail: one request, its data frames, its answer. The
    /// connection waits 120 s (FILES-29): the ask may sit in the app's queue
    /// behind a camera folder, and the socket must not time it out first.
    private func thumb(item: String, size: Int,
                       isCancelled: @escaping () -> Bool) -> (data: Data?, error: Error?) {
        guard case .success(let connection) = connect(readTimeout: FilesThumbPolicy.bridgeReadTimeout),
              hello(connection) else {
            log.notice("thumb failed code=offline")
            return (nil, FilesThumbPolicy.error(for: "offline"))
        }
        let state = ReadState(connection: connection)
        let id: UInt32 = 1
        state.begin(id: id)
        guard connection.send(.thumb(id: id, item: item, size: size)) else {
            log.notice("thumb failed code=offline")
            return (nil, FilesThumbPolicy.error(for: "offline"))
        }
        var data = Data()
        while let frame = connection.next() {
            if isCancelled() {
                state.cancel()
                return (nil, nil)
            }
            switch frame {
            case .data(let bytes):
                data.append(contentsOf: bytes)
                if data.count > FilesThumbPolicy.maxBytes {
                    // A corrupt or oversized answer is permanent: asking again
                    // cannot fix it.
                    state.cancel()
                    log.notice("thumb failed code=too_large")
                    return (nil, nil)
                }
            case .signal:
                continue
            case .reply(let reply):
                switch reply {
                case .thumb(_, _, let size, let sha256):
                    let digest = SHA256.hash(data: data)
                        .map { String(format: "%02x", $0) }.joined()
                    guard Int(size) == data.count, sha256.lowercased() == digest else {
                        log.notice("thumb failed code=checksum")
                        return (nil, nil)
                    }
                    log.notice("thumb done bytes=\(data.count, privacy: .public)")
                    return (data, nil)
                case .error(_, let code):
                    log.notice("thumb failed code=\(code, privacy: .public)")
                    return (nil, FilesThumbPolicy.error(for: code))
                default:
                    continue
                }
            }
        }
        log.notice("thumb failed code=offline")
        return (nil, FilesThumbPolicy.error(for: "offline"))
    }
}

// MARK: - Enumeration

/// A folder's children, one phone page at a time. The cursor is the phone's own
/// opaque page string in an NSFileProviderPage; the container is an identifier
/// the app resolves.
final class FilesEnumerator: NSObject, NSFileProviderEnumerator {
    private weak var owner: FilesExtension?
    private let container: NSFileProviderItemIdentifier

    init(extension owner: FilesExtension, container: NSFileProviderItemIdentifier) {
        self.owner = owner
        self.container = container
    }

    func invalidate() {
        // The system is done with this folder's enumerator: its pushes stop, but
        // the phone keeps watching the folder until its ten minutes run out
        // (design "S5 round 3").
        owner?.watch(containerIdentifier, on: false)
    }

    private var containerIdentifier: String {
        container == .rootContainer ? FilesMap.rootIdentifier : container.rawValue
    }

    /// One `didEnumerate` batch. A phone page holds up to 1000 items; handing
    /// 1000 to the system in one callback made a 1500-entry folder list as
    /// empty in the round-2 VM run, so a page is delivered in batches of this
    /// size and the page cursor carries the offset (FilesPageReader).
    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        guard let owner else {
            observer.finishEnumeratingWithError(FilesFailure.offline.error)
            return
        }
        let identifier = containerIdentifier
        owner.watch(identifier, on: true)
        owner.reader.enumerate(
            container: identifier, token: FilesPageToken(page.rawValue),
            load: { [weak owner] container, cursor, completion in
                owner?.loadListing(item: container, page: cursor, completion: completion)
            },
            deliver: { delivery in
                observer.didEnumerate(delivery.items.map(ProviderItem.init))
                log.notice("\(FilesPageLog.line(count: delivery.items.count, fetched: delivery.fetched, milliseconds: delivery.milliseconds), privacy: .public)")
                observer.finishEnumerating(
                    upTo: delivery.next.map { NSFileProviderPage($0.page) })
            },
            fail: { failure in
                log.notice("enumerate failed code=\(failure.rawValue, privacy: .public)")
                observer.finishEnumeratingWithError(failure.error)
            })
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        guard let owner else {
            observer.finishEnumeratingWithError(FilesFailure.offline.error)
            return
        }
        owner.watch(containerIdentifier, on: true)
        let from = String(data: anchor.rawValue, encoding: .utf8) ?? ""
        owner.loadChanges(item: containerIdentifier, from: from) { result in
            switch result {
            case .failure(let failure):
                log.notice("changes failed code=\(failure.rawValue, privacy: .public)")
                observer.finishEnumeratingWithError(failure.error)
            case .success(let reply) where reply.expired:
                // Older than the app's kept history (or from another process):
                // the system starts over with a fresh enumeration.
                log.notice("changes anchor expired")
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            case .success(let reply):
                if !reply.delta.items.isEmpty {
                    observer.didUpdate(reply.delta.items.map(ProviderItem.init))
                }
                if !reply.delta.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: reply.delta.deleted.map {
                        NSFileProviderItemIdentifier($0)
                    })
                }
                log.notice("changes items=\(reply.delta.items.count, privacy: .public) deleted=\(reply.delta.deleted.count, privacy: .public)")
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(Data(reply.anchor.utf8)), moreComing: false)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let owner else { return completionHandler(nil) }
        owner.watch(containerIdentifier, on: true)
        owner.loadAnchor(item: containerIdentifier) { result in
            switch result {
            case .success(let anchor):
                completionHandler(NSFileProviderSyncAnchor(Data(anchor.utf8)))
            case .failure:
                completionHandler(nil)
            }
        }
    }
}

/// The working set (design "S5 round 3"): every change the app saw on the phone,
/// in one sequence, with each item carrying its real parent. It is enumerated
/// with `enumerateChangesFromSyncAnchor:` (NSFileProviderEnumerating.h), which is
/// also how the system learns that a folder it is showing moved — a replicated
/// extension may only signal this container.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private weak var owner: FilesExtension?
    /// The item list `enumerateItems` pages through. Asking the app for the
    /// working-set snapshot once per enumeration is enough: it answers from the
    /// cached listings in memory.
    private var snapshot: [FileItem]?

    init(extension owner: FilesExtension) {
        self.owner = owner
    }

    func invalidate() {}

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        guard let owner else {
            return observer.finishEnumeratingWithError(FilesFailure.offline.error)
        }
        let from = String(data: anchor.rawValue, encoding: .utf8)
        owner.loadChanges(item: filesWorkingSetIdentifier, from: from) { result in
            switch result {
            case .failure(let failure):
                log.notice("working set changes failed code=\(failure.rawValue, privacy: .public)")
                observer.finishEnumeratingWithError(failure.error)
            case .success(let reply) where reply.expired:
                // The system drops its cached data and starts over at nil
                // (NSFileProviderEnumerating.h): a fresh enumeration answers
                // every cached item.
                log.notice("working set anchor expired")
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            case .success(let reply):
                if !reply.delta.items.isEmpty {
                    observer.didUpdate(reply.delta.items.map(ProviderItem.init))
                }
                if !reply.delta.deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: reply.delta.deleted.map {
                        NSFileProviderItemIdentifier($0)
                    })
                }
                log.notice("working set changes items=\(reply.delta.items.count, privacy: .public) deleted=\(reply.delta.deleted.count, privacy: .public)")
                observer.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(Data(reply.anchor.utf8)), moreComing: false)
            }
        }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        guard let owner else {
            observer.finishEnumeratingWithError(FilesFailure.offline.error)
            return
        }
        var offset = 0
        if page.rawValue as Data != NSFileProviderPage.initialPageSortedByName as Data,
           page.rawValue as Data != NSFileProviderPage.initialPageSortedByDate as Data,
           let text = String(data: page.rawValue, encoding: .utf8) {
            offset = Int(text) ?? 0
        }
        deliver(owner: owner, offset: offset, observer: observer)
    }

    /// The app's cached listings, one local page at a time. The system removes
    /// an item only through `didDeleteItemsWithIdentifiers:`, so an item this
    /// enumeration does not return is not treated as gone.
    private func deliver(owner: FilesExtension, offset: Int,
                         observer: NSFileProviderEnumerationObserver) {
        let finish: ([FileItem]) -> Void = { [weak self] items in
            self?.snapshot = items
            // The same batch size as a folder: 1000 items in one callback made
            // the system list nothing (round 2's 1500-entry folder).
            let pageSize = FilesPageReader.batchSize
            let slice = Array(items.dropFirst(offset).prefix(pageSize))
            observer.didEnumerate(slice.map(ProviderItem.init))
            let next = offset + slice.count < items.count
                ? NSFileProviderPage(Data(String(offset + slice.count).utf8)) : nil
            log.notice("working set items=\(slice.count, privacy: .public) more=\(next != nil, privacy: .public)")
            observer.finishEnumerating(upTo: next)
        }
        if let snapshot {
            return finish(snapshot)
        }
        owner.loadChanges(item: filesWorkingSetIdentifier, from: nil) { result in
            switch result {
            case .success(let reply):
                finish(reply.delta.items)
            case .failure(let failure):
                log.notice("working set items failed code=\(failure.rawValue, privacy: .public)")
                observer.finishEnumeratingWithError(failure.error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard let owner else { return completionHandler(nil) }
        owner.loadAnchor(item: filesWorkingSetIdentifier) { result in
            switch result {
            case .success(let anchor):
                completionHandler(NSFileProviderSyncAnchor(Data(anchor.utf8)))
            case .failure:
                completionHandler(nil)
            }
        }
    }
}

/// The trash container: there is none on the phone (design §4, S4), so it
/// enumerates nothing and never touches the phone.
final class EmptyEnumerator: NSObject, NSFileProviderEnumerator {
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(nil)
    }
}
