// Phone files in Finder: the replicated File Provider extension (docs/design/
// files.md §1, §3; slice S3). It owns no phone session and holds no keys: the
// app does, so every answer here comes from the app over a UNIX socket in the
// shared App Group container. File bytes arrive as framed chunks and are written
// into the extension's own temporary file, which Finder then takes.
//
// Read-only in S3: items allow reading and enumerating, and every write op
// answers featureUnsupported. Nothing here logs a file name, a path or content:
// op names, lengths, ids and codes only (design §4).
//
// Built by macos/scripts/bundle.sh with swiftc, together with FilesCore.swift
// (the wire, the item mapping, the id ↔ path map and the error map). The class
// is named in the Info.plist's NSExtensionPrincipalClass as FilesExtension.

import CryptoKit
import FileProvider
import Foundation
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "dev.pocketdeck.mac", category: "files")

/// The read cap (design §3: a write body is capped at 1 GiB; reads follow the
/// file, and anything this large is refused with a clear error).
private let maxFetchBytes = 1024 * 1024 * 1024

// MARK: - Bridge connection

/// One request (or one streamed read) per connection. The app serialises the
/// work; the extension only maps calls onto the wire.
final class BridgeConnection {
    enum Reply {
        case reply(BridgeReply)
        case data([UInt8])
    }

    private let fd: Int32
    private let writeLock = NSLock()
    private var decoder = BridgeDecoder()
    private var queue: [Reply] = []

    init?(path: String) {
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
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { Darwin.close(fd) }

    func send(_ request: BridgeRequest) -> Bool {
        let data = BridgeWire.line(request)
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
    /// closed or answered something this side does not understand.
    func next() -> Reply? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if !queue.isEmpty { return queue.removeFirst() }
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
                case .invalid, .request:
                    return nil
                }
            }
            if decoder.broken { return nil }
        }
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

private func bridgeConnection(for domain: NSFileProviderDomain) -> BridgeConnection? {
    guard let path = bridgeSocketPath(domain: domain) else { return nil }
    return BridgeConnection(path: path)
}

// MARK: - Errors

extension FilesFailure: Error {
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
            return CocoaError(.fileWriteFileExists)
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
    var capabilities: NSFileProviderItemCapabilities {
        mapped.isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading]
    }
}

// MARK: - Extension

@objc(FilesExtension)
final class FilesExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    private let work = DispatchQueue(label: "dev.pocketdeck.mac.files-extension", qos: .utility)
    private let mapLock = NSLock()
    private var map = FilesPathMap()
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

    /// A folder's listing is gone: forget it and everything below it.
    func invalidateSubtree(path: String) {
        withMap { $0.invalidate(subtree: path) }
    }

    /// One listing off the main thread, for the enumerator.
    func loadListing(path: String, page: String?,
                     completion: @escaping (Result<(items: [FsItem], next: String?), FilesFailure>) -> Void) {
        work.async {
            completion(self.list(path: path, page: page))
        }
    }

    // MARK: The id ↔ path map

    private func withMap<T>(_ body: (inout FilesPathMap) -> T) -> T {
        mapLock.lock()
        defer { mapLock.unlock() }
        return body(&map)
    }

    /// The map first, then the path the identifier itself carries: the system
    /// runs more than one extension process, so a fresh one must resolve what
    /// another enumerated.
    private func path(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer { return "" }
        if let known = withMap({ $0.path(for: identifier.rawValue) }) { return known }
        return FilesMap.path(fromIdentifier: identifier.rawValue)
    }

    func remember(_ items: [FsItem], parentPath: String,
                          parentIdentifier: NSFileProviderItemIdentifier) -> [FileItem] {
        withMap { map in
            map.insert(childrenOf: parentPath,
                       parentIdentifier: parentIdentifier == .rootContainer
                           ? FilesMap.rootIdentifier : parentIdentifier.rawValue,
                       items: items)
        }
    }

    func remember(fs: FsItem, path: String) -> FileItem {
        let parentID = parentIdentifier(forPath: path)
        return withMap { $0.insert(fs: fs, path: path, parentIdentifier: parentID) }
    }

    /// The parent's identifier as the system knows it. A fresh instance has no
    /// map entry for the parent, so one stat supplies its ino (design §3: an id
    /// is ino-based); without an answer the path fallback is still a valid id.
    private func parentIdentifier(forPath path: String) -> String {
        let parentPath = (path as NSString).deletingLastPathComponent
        if parentPath.isEmpty { return FilesMap.rootIdentifier }
        if let known = withMap({ $0.identifier(for: parentPath) }) { return known }
        if case .success(let info) = stat(path: parentPath) {
            let identifier = FilesMap.identifier(path: parentPath, ino: info.ino)
            withMap { _ = $0.insert(fs: info, path: parentPath,
                                    parentIdentifier: FilesMap.rootIdentifier) }
            return identifier
        }
        return "path:\(parentPath)"
    }

    private func rootItem() -> FileItem {
        FilesMap.rootItem(name: domain.displayName, version: Data("root-s3".utf8))
    }

    // MARK: Bridge operations

    private func connect() -> Result<BridgeConnection, FilesFailure> {
        guard let connection = bridgeConnection(for: domain) else { return .failure(.offline) }
        return .success(connection)
    }

    func list(path: String, page: String?) -> Result<(items: [FsItem], next: String?), FilesFailure> {
        guard case .success(let connection) = connect() else { return .failure(.offline) }
        let request = BridgeRequest.list(id: 1, path: path, page: page)
        guard connection.send(request) else { return .failure(.offline) }
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

    private func stat(path: String) -> Result<FsItem, FilesFailure> {
        guard case .success(let connection) = connect() else { return .failure(.offline) }
        guard connection.send(.stat(id: 1, path: path)) else { return .failure(.offline) }
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

    // MARK: NSFileProviderReplicatedExtension

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(ProviderItem(rootItem()), nil)
            return Progress()
        }
        guard let path = path(for: identifier) else {
            log.notice("item unknown id")
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        work.async {
            switch self.stat(path: path) {
            case .success(let fs):
                let item = self.remember(fs: fs, path: path)
                log.notice("item stat ok dir=\(fs.dir, privacy: .public) size=\(fs.size, privacy: .public)")
                completionHandler(ProviderItem(item), nil)
            case .failure(.notFound):
                self.withMap { $0.invalidate(subtree: path) }
                completionHandler(nil, FilesFailure.notFound.error)
            case .failure(let failure):
                log.notice("item stat failed code=\(failure.rawValue, privacy: .public)")
                completionHandler(nil, failure.error)
            }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard let path = path(for: containerItemIdentifier) else {
            throw FilesFailure.notFound.error
        }
        return FilesEnumerator(extension: self, container: containerItemIdentifier, path: path)
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let path = path(for: itemIdentifier) else {
            completionHandler(nil, nil, FilesFailure.notFound.error)
            return progress
        }
        progress.isCancellable = true
        work.async {
            self.fetch(path: path, requested: requestedVersion, progress: progress,
                       retried: false, completion: completionHandler)
        }
        return progress
    }

    /// stat → read the whole file into a temporary file → size + sha256 check.
    /// One `fs_stale` refetches the metadata and retries once (design §3).
    private func fetch(path: String, requested: NSFileProviderItemVersion?, progress: Progress,
                       retried: Bool,
                       completion: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) {
        let etag = requested.flatMap { String(data: $0.contentVersion, encoding: .utf8) }
        let metadata: FsItem
        switch stat(path: path) {
        case .success(let item):
            metadata = item
        case .failure(let failure):
            if failure == .notFound { withMap { $0.invalidate(subtree: path) } }
            log.notice("fetch stat failed code=\(failure.rawValue, privacy: .public)")
            completion(nil, nil, failure.error)
            return
        }
        guard !metadata.dir else {
            completion(nil, nil, FilesFailure.notFound.error)
            return
        }
        guard metadata.size <= maxFetchBytes else {
            log.notice("fetch refused size=\(metadata.size, privacy: .public)")
            completion(nil, nil, FilesFailure.tooLarge.error)
            return
        }
        guard case .success(let connection) = connect() else {
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
        guard connection.send(.read(id: id, path: path, offset: 0, length: metadata.size,
                                    etag: etag)) else {
            handle.closeFile()
            try? FileManager.default.removeItem(at: target)
            completion(nil, nil, FilesFailure.offline.error)
            return
        }
        var hasher = SHA256()
        var received = 0
        var failure: FilesFailure?
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
            case .reply(let reply):
                switch reply {
                case .end(_, let size, let sha256):
                    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    if size != received || size != metadata.size || digest != sha256.lowercased() {
                        failure = .io
                    }
                case .error(_, let code):
                    let mapped = FilesFailure.from(code: code)
                    failure = mapped == .stale && !retried ? .stale : mapped
                default:
                    continue
                }
            }
            if failure != nil { break }
        }
        handle.closeFile()
        if failure == nil && received != metadata.size { failure = .io }
        if let failure {
            try? FileManager.default.removeItem(at: target)
            log.notice("fetch failed code=\(failure.rawValue, privacy: .public) bytes=\(received, privacy: .public)")
            if failure == .stale && !retried {
                fetch(path: path, requested: nil, progress: progress, retried: true,
                      completion: completion)
                return
            }
            if failure == .cancelled { progress.cancel() }
            completion(nil, nil, failure.error)
            return
        }
        progress.completedUnitCount = progress.totalUnitCount
        let item = remember(fs: metadata, path: path)
        log.notice("fetch done bytes=\(received, privacy: .public)")
        completion(target, ProviderItem(item), nil)
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

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        log.notice("createItem refused: read-only slice")
        completionHandler(nil, [], false, CocoaError(.featureUnsupported))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        log.notice("modifyItem refused: read-only slice")
        completionHandler(nil, [], false, CocoaError(.featureUnsupported))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        log.notice("deleteItem refused: read-only slice")
        completionHandler(CocoaError(.featureUnsupported))
        return Progress()
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

// MARK: - Enumeration

/// A folder's children, one phone page at a time. The cursor is the phone's own
/// opaque page string in an NSFileProviderPage.
final class FilesEnumerator: NSObject, NSFileProviderEnumerator {
    private weak var owner: FilesExtension?
    private let container: NSFileProviderItemIdentifier
    private let path: String

    init(extension owner: FilesExtension, container: NSFileProviderItemIdentifier, path: String) {
        self.owner = owner
        self.container = container
        self.path = path
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        guard let owner else {
            observer.finishEnumeratingWithError(FilesFailure.offline.error)
            return
        }
        var cursor: String?
        let initialByName = NSFileProviderPage.initialPageSortedByName as Data
        let initialByDate = NSFileProviderPage.initialPageSortedByDate as Data
        if page.rawValue as Data != initialByName,
           page.rawValue as Data != initialByDate {
            cursor = String(data: page.rawValue, encoding: .utf8)
        }
        owner.loadListing(path: path, page: cursor) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let listing):
                let items = owner.remember(listing.items, parentPath: self.path,
                                           parentIdentifier: self.container)
                observer.didEnumerate(items.map(ProviderItem.init))
                let next = listing.next.map { NSFileProviderPage(Data($0.utf8)) }
                log.notice("enumerate items=\(items.count, privacy: .public) more=\(next != nil, privacy: .public)")
                observer.finishEnumerating(upTo: next)
            case .failure(let failure):
                log.notice("enumerate failed code=\(failure.rawValue, privacy: .public)")
                if failure == .notFound {
                    owner.invalidateSubtree(path: self.path)
                }
                observer.finishEnumeratingWithError(failure.error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        // S3 reports no remote changes: the current anchor is the answer (S5
        // turns fs.changes into real deltas).
        observer.finishEnumeratingChanges(upTo: owner?.anchor ?? anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(owner?.anchor)
    }
}
