// The pure half of phone files in Finder (docs/design/files.md §3, slice S3):
// the wire between the app's bridge and the sandboxed File Provider extension,
// the fs item → item mapping, the identifier ↔ path map and the error map.
//
// Nothing here imports FileProvider, so the test target can use it and the
// extension compiles this same file (bundle.sh). The extension adds the
// NSFileProvider types on top.

import CryptoKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Phone items (fs.items / fs.item)

/// One item of `fs.items` / `fs.item` (docs/PROTOCOL.md "Phone files").
struct FsItem: Equatable {
    var name: String
    var dir: Bool
    var size: Int
    var mtime: Int
    var ino: Int
    var etag: String

    init(name: String, dir: Bool, size: Int, mtime: Int, ino: Int, etag: String) {
        self.name = name
        self.dir = dir
        self.size = size
        self.mtime = mtime
        self.ino = ino
        self.etag = etag
    }

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String,
              let dir = json["dir"] as? Bool,
              let etag = json["etag"] as? String else { return nil }
        self.init(name: name, dir: dir,
                  size: (json["size"] as? NSNumber)?.intValue ?? 0,
                  mtime: (json["mtime"] as? NSNumber)?.intValue ?? 0,
                  ino: (json["ino"] as? NSNumber)?.intValue ?? 0,
                  etag: etag)
    }

    var jsonObject: [String: Any] {
        ["name": name, "dir": dir, "size": size, "mtime": mtime, "ino": ino, "etag": etag]
    }
}

/// Where a bridge create/modify pushes the extension's bytes. The app hands one
/// out when `fs.write` starts; the sink streams the chunks into the phone with
/// the drop pacing and answers the completion when the phone finished.
@MainActor
protocol FilesWriteSink: AnyObject {
    /// Takes one chunk; false when the write is over (cancelled or failed).
    func append(_ bytes: [UInt8]) -> Bool
    /// All announced bytes were handed over.
    func finish()
    /// The extension cancelled (or its client went away).
    func cancel()
}

/// One page of a listing; `next` is the phone's cursor for the next page.
struct FsPage: Equatable {
    var items: [FsItem]
    var next: String?
}

/// A completed read: the range's length and the SHA-256 the phone announced.
struct FsReadResult: Equatable {
    var bytes: Int
    var sha256: String
}

/// A refusal: a phone code (`fs_*`) or a bridge code (`offline`, `io`, …).
struct FsError: Error, Equatable, CustomStringConvertible {
    var code: String
    var message: String?

    init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    var description: String { message.map { "\(code): \($0)" } ?? code }
}

// MARK: - Bridge wire

/// A request on the App Group socket: the extension asks, the app answers.
/// Requests name the item (an identifier the app resolves), never a path: the
/// app owns the id ↔ path map because the system runs the extension in more
/// than one process (design §3, S4).
enum BridgeRequest: Equatable {
    case hello(id: UInt32, version: Int)
    case list(id: UInt32, item: String, page: String?)
    case stat(id: UInt32, item: String)
    case read(id: UInt32, item: String, offset: Int, length: Int, etag: String?)
    /// A new file or folder under `parent`; a file's bytes follow once the app
    /// answers `ready`, as `data` frames on this id.
    case create(id: UInt32, request: BridgeCreate)
    /// A changed item: content and/or name/parent/mtime. New content follows the
    /// `ready` as `data` frames.
    case modify(id: UInt32, request: BridgeModify)
    case delete(id: UInt32, item: String, base: String, recursive: Bool)
    case cancel(id: UInt32)

    var id: UInt32 {
        switch self {
        case .hello(let id, _), .list(let id, _, _), .stat(let id, _),
             .read(let id, _, _, _, _), .create(let id, _), .modify(let id, _),
             .delete(let id, _, _, _), .cancel(let id):
            return id
        }
    }
}

/// The fields of a `create`: a folder needs none of the byte fields.
struct BridgeCreate: Equatable {
    var parent: String
    var name: String
    var dir: Bool
    var size: Int
    var sha256: String?

    /// A file with bytes to follow.
    var hasContent: Bool { !dir && size > 0 && sha256 != nil }
}

/// The fields of a `modify`: only what changed, plus the version it changed from.
struct BridgeModify: Equatable {
    var item: String
    var base: String
    var content: Bool
    var name: String?
    var parent: String?
    var mtime: Int?
    var size: Int
    var sha256: String?

    var hasContent: Bool { content && size > 0 && sha256 != nil }
}

/// A reply: one JSON line, and for a read the `data` headers with their raw
/// bytes, then `end` (or `error`).
enum BridgeReply: Equatable {
    case hello(id: UInt32, version: Int, name: String?, connected: Bool)
    case items(id: UInt32, page: String?, items: [FileItem])
    case item(id: UInt32, item: FileItem)
    /// A write's bytes may start: the app is ready for `data` frames on this id.
    case ready(id: UInt32)
    /// A delete succeeded.
    case ok(id: UInt32)
    /// Announcement of `length` raw bytes that follow the newline.
    case data(id: UInt32, length: Int)
    case end(id: UInt32, size: Int, sha256: String)
    case error(id: UInt32, code: String)
}

/// The bridge protocol version. Both sides refuse anything else.
let filesBridgeVersion = 2

enum BridgeWire {
    /// A request line is at most 64 KiB (design §3's cap, applied locally).
    static let maxLineBytes = 64 * 1024
    /// A reply may carry a whole listing page: the phone caps one at 1 MiB of
    /// JSON, so the bridge's re-encoding gets twice that.
    static let maxReplyLineBytes = 2 * 1024 * 1024
    /// A data chunk is one fs.read frame (≤ 256 KiB); the cap is a sanity check.
    static let maxChunkBytes = 8 * 1024 * 1024

    static func line(_ request: BridgeRequest) -> Data {
        var object: [String: Any] = ["id": Int(request.id)]
        switch request {
        case .hello(_, let version):
            object["t"] = "hello"
            object["version"] = version
        case .list(_, let item, let page):
            object["t"] = "list"
            object["item"] = item
            if let page { object["page"] = page }
        case .stat(_, let item):
            object["t"] = "stat"
            object["item"] = item
        case .read(_, let item, let offset, let length, let etag):
            object["t"] = "read"
            object["item"] = item
            object["offset"] = offset
            object["length"] = length
            if let etag { object["etag"] = etag }
        case .create(_, let create):
            object["t"] = "create"
            object["parent"] = create.parent
            object["name"] = create.name
            object["dir"] = create.dir
            if !create.dir {
                object["size"] = create.size
                if let sha256 = create.sha256 { object["sha256"] = sha256 }
            }
        case .modify(_, let modify):
            object["t"] = "modify"
            object["item"] = modify.item
            object["base"] = modify.base
            var fields: [String: Any] = ["content": modify.content]
            if let name = modify.name { fields["name"] = name }
            if let parent = modify.parent { fields["parent"] = parent }
            if let mtime = modify.mtime { fields["mtime"] = mtime }
            object["fields"] = fields
            if modify.content {
                object["size"] = modify.size
                if let sha256 = modify.sha256 { object["sha256"] = sha256 }
            }
        case .delete(_, let item, let base, let recursive):
            object["t"] = "delete"
            object["item"] = item
            object["base"] = base
            object["recursive"] = recursive
        case .cancel:
            object["t"] = "cancel"
        }
        return jsonLine(object)
    }

    static func line(_ reply: BridgeReply) -> Data {
        var object: [String: Any] = [:]
        switch reply {
        case .hello(let id, let version, let name, let connected):
            object = ["t": "hello", "id": Int(id), "version": version, "connected": connected]
            if let name { object["name"] = name }
        case .items(let id, let page, let items):
            object = ["t": "items", "id": Int(id), "items": items.map(\.jsonObject)]
            if let page { object["page"] = page }
        case .item(let id, let item):
            object = ["t": "item", "id": Int(id), "item": item.jsonObject]
        case .ready(let id):
            object = ["t": "ready", "id": Int(id)]
        case .ok(let id):
            object = ["t": "ok", "id": Int(id)]
        case .data(let id, let length):
            object = ["t": "data", "id": Int(id), "len": length]
        case .end(let id, let size, let sha256):
            object = ["t": "end", "id": Int(id), "size": size, "sha256": sha256]
        case .error(let id, let code):
            object = ["t": "error", "id": Int(id), "code": code]
        }
        return jsonLine(object)
    }

    /// The header that announces a chunk of raw bytes.
    static func dataHeader(id: UInt32, length: Int) -> Data {
        line(.data(id: id, length: length))
    }

    private static func jsonLine(_ object: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
        return data + Data([0x0A])
    }
}

/// One thing the decoder produced from the stream.
enum BridgeEvent: Equatable {
    case request(BridgeRequest)
    case reply(BridgeReply)
    case dataHeader(id: UInt32, length: Int)
    case data(id: UInt32, bytes: [UInt8])
    /// A malformed line; the code never carries a name or a path.
    case invalid(String)
}

/// Incremental decoder: newline-delimited JSON, then exactly `len` raw bytes
/// after a `data` header. Feed it whatever the socket returned; a line or a
/// chunk may arrive split across any number of reads.
struct BridgeDecoder {
    /// Request channels keep the 64 KiB cap; a reply channel passes the larger
    /// one, because an `items` page is one line.
    private let maxLineBytes: Int
    private var line: [UInt8] = []
    private var chunk: [UInt8] = []
    private var chunkID: UInt32 = 0
    private var remaining = 0
    /// Set when a line grew past the cap: the stream cannot be trusted, the
    /// caller closes the connection.
    private(set) var broken = false

    init(maxLineBytes: Int = BridgeWire.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func feed(_ input: [UInt8]) -> [BridgeEvent] {
        guard !broken else { return [] }
        var events: [BridgeEvent] = []
        var bytes = input
        while !bytes.isEmpty {
            if remaining > 0 {
                let take = min(remaining, bytes.count)
                chunk.append(contentsOf: bytes[0..<take])
                bytes.removeFirst(take)
                remaining -= take
                if remaining == 0 {
                    events.append(.data(id: chunkID, bytes: chunk))
                    chunk = []
                }
                continue
            }
            if let newline = bytes.firstIndex(of: 0x0A) {
                line.append(contentsOf: bytes[0..<newline])
                bytes.removeFirst(newline + 1)
                if line.count > maxLineBytes {
                    broken = true
                    events.append(.invalid("line_too_long"))
                    return events
                }
                let decoded = decode(line)
                line = []
                events.append(decoded)
                if case .dataHeader(let id, let length) = decoded {
                    chunkID = id
                    remaining = length
                    chunk = []
                    chunk.reserveCapacity(min(length, 64 * 1024))
                }
            } else {
                line.append(contentsOf: bytes)
                bytes = []
                if line.count > maxLineBytes {
                    broken = true
                    events.append(.invalid("line_too_long"))
                }
            }
        }
        return events
    }

    private func decode(_ bytes: [UInt8]) -> BridgeEvent {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
              let type = object["t"] as? String else {
            return .invalid("bad_json")
        }
        guard let number = object["id"] as? NSNumber,
              number.intValue > 0, number.intValue <= Int(UInt32.max) else {
            return .invalid("bad_id")
        }
        let id = UInt32(number.intValue)
        switch type {
        case "hello":
            if let connected = object["connected"] as? Bool {
                let version = (object["version"] as? NSNumber)?.intValue ?? 0
                let name = object["name"] as? String
                return .reply(.hello(id: id, version: version, name: name, connected: connected))
            }
            let version = (object["version"] as? NSNumber)?.intValue ?? filesBridgeVersion
            return .request(.hello(id: id, version: version))
        case "list", "stat", "read":
            guard let item = object["item"] as? String else { return .invalid("bad_request") }
            switch type {
            case "list":
                return .request(.list(id: id, item: item, page: object["page"] as? String))
            case "stat":
                return .request(.stat(id: id, item: item))
            default:
                guard let offset = (object["offset"] as? NSNumber)?.intValue,
                      let length = (object["length"] as? NSNumber)?.intValue else {
                    return .invalid("bad_request")
                }
                return .request(.read(id: id, item: item, offset: offset, length: length,
                                      etag: object["etag"] as? String))
            }
        case "create":
            guard let parent = object["parent"] as? String,
                  let name = object["name"] as? String,
                  let dir = object["dir"] as? Bool else { return .invalid("bad_request") }
            let create = BridgeCreate(
                parent: parent, name: name, dir: dir,
                size: (object["size"] as? NSNumber)?.intValue ?? 0,
                sha256: object["sha256"] as? String)
            return .request(.create(id: id, request: create))
        case "modify":
            guard let item = object["item"] as? String,
                  let base = object["base"] as? String,
                  let fields = object["fields"] as? [String: Any] else {
                return .invalid("bad_request")
            }
            let modify = BridgeModify(
                item: item, base: base,
                content: fields["content"] as? Bool ?? false,
                name: fields["name"] as? String,
                parent: fields["parent"] as? String,
                mtime: (fields["mtime"] as? NSNumber)?.intValue,
                size: (object["size"] as? NSNumber)?.intValue ?? 0,
                sha256: object["sha256"] as? String)
            return .request(.modify(id: id, request: modify))
        case "delete":
            guard let item = object["item"] as? String,
                  let base = object["base"] as? String else { return .invalid("bad_request") }
            return .request(.delete(id: id, item: item, base: base,
                                    recursive: object["recursive"] as? Bool ?? false))
        case "cancel":
            return .request(.cancel(id: id))
        case "items":
            let items = (object["items"] as? [[String: Any]])?.compactMap(FileItem.init(json:)) ?? []
            return .reply(.items(id: id, page: object["page"] as? String, items: items))
        case "item":
            guard let item = FileItem(json: object["item"] as? [String: Any] ?? [:]) else {
                return .invalid("bad_item")
            }
            return .reply(.item(id: id, item: item))
        case "ready":
            return .reply(.ready(id: id))
        case "ok":
            return .reply(.ok(id: id))
        case "data":
            guard let length = (object["len"] as? NSNumber)?.intValue,
                  length >= 0, length <= BridgeWire.maxChunkBytes else {
                return .invalid("bad_len")
            }
            return .dataHeader(id: id, length: length)
        case "end":
            guard let size = (object["size"] as? NSNumber)?.intValue,
                  let sha256 = object["sha256"] as? String else {
                return .invalid("bad_end")
            }
            return .reply(.end(id: id, size: size, sha256: sha256))
        case "error":
            guard let code = object["code"] as? String else { return .invalid("bad_error") }
            return .reply(.error(id: id, code: code))
        default:
            return .invalid("unknown_type")
        }
    }
}

// MARK: - Item mapping

/// An item as the File Provider sees it, without FileProvider types: the ids
/// are strings, the content types are UTType identifiers, the versions are the
/// raw bytes the extension wraps in NSFileProviderItemVersion. This is also the
/// shape the bridge carries, so the app builds it once and the extension wraps
/// it unchanged.
struct FileItem: Equatable {
    var identifier: String
    var parentIdentifier: String
    var name: String
    var isDirectory: Bool
    var size: Int
    var modificationDate: Date
    var contentTypeIdentifier: String
    var etag: String
    var contentVersion: Data
    var metadataVersion: Data

    init(identifier: String, parentIdentifier: String, name: String, isDirectory: Bool,
         size: Int, modificationDate: Date, contentTypeIdentifier: String, etag: String,
         contentVersion: Data, metadataVersion: Data) {
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.contentTypeIdentifier = contentTypeIdentifier
        self.etag = etag
        self.contentVersion = contentVersion
        self.metadataVersion = metadataVersion
    }

    init?(json: [String: Any]) {
        guard let identifier = json["id"] as? String,
              let parent = json["parent"] as? String,
              let name = json["name"] as? String,
              let dir = json["dir"] as? Bool,
              let type = json["type"] as? String,
              let etag = json["etag"] as? String,
              let contentVersion = (json["cv"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let metadataVersion = (json["mv"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return nil }
        let mtime = (json["mtime"] as? NSNumber)?.intValue ?? 0
        self.init(identifier: identifier, parentIdentifier: parent, name: name,
                  isDirectory: dir, size: (json["size"] as? NSNumber)?.intValue ?? 0,
                  modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime) / 1000),
                  contentTypeIdentifier: type, etag: etag,
                  contentVersion: contentVersion, metadataVersion: metadataVersion)
    }

    /// The versions encode everything the date carries, so equality does not
    /// depend on a Date's last bit surviving a JSON round trip.
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.identifier == rhs.identifier && lhs.parentIdentifier == rhs.parentIdentifier
            && lhs.name == rhs.name && lhs.isDirectory == rhs.isDirectory
            && lhs.size == rhs.size && lhs.etag == rhs.etag
            && lhs.contentTypeIdentifier == rhs.contentTypeIdentifier
            && lhs.contentVersion == rhs.contentVersion
            && lhs.metadataVersion == rhs.metadataVersion
    }

    var jsonObject: [String: Any] {
        ["id": identifier, "parent": parentIdentifier, "name": name, "dir": isDirectory,
         "size": size, "mtime": Int(modificationDate.timeIntervalSince1970 * 1000),
         "type": contentTypeIdentifier, "etag": etag,
         "cv": contentVersion.base64EncodedString(),
         "mv": metadataVersion.base64EncodedString()]
    }
}

// MARK: - Item mapping

enum FilesMap {
    /// NSFileProviderItemIdentifier.rootContainer's raw value.
    static let rootIdentifier = filesRootIdentifier

    /// `ino:<st_ino>` is the identity, so a rename or a move keeps it; a phone
    /// that reports ino 0 (some FUSE mounts do) falls back to the path. The app
    /// resolves both through its own map (design §3 "Identifiers", S4).
    static func identifier(path: String, ino: Int) -> String {
        if path.isEmpty { return rootIdentifier }
        if ino > 0 { return "ino:\(ino)" }
        return "path:\(encodedPath(path))"
    }

    /// The path part of a path-form identifier stays one opaque token: "/" would
    /// read as a subpath to anything that treats an identifier as one.
    static func encodedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "/", with: "%2F")
    }

    static func decodedPath(_ text: String) -> String {
        text.replacingOccurrences(of: "%2F", with: "/")
            .replacingOccurrences(of: "%25", with: "%")
    }

    /// The relative path a path-form identifier carries. An ino identifier has
    /// none: only the app's map can resolve it.
    static func path(fromIdentifier identifier: String) -> String? {
        if identifier == rootIdentifier { return "" }
        if identifier.hasPrefix("path:") {
            return decodedPath(String(identifier.dropFirst("path:".count)))
        }
        return nil
    }

    static func contentTypeIdentifier(name: String, isDirectory: Bool) -> String {
        if isDirectory { return UTType.folder.identifier }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type.identifier }
        return UTType.data.identifier
    }

    static func item(path: String, parentIdentifier: String, fs: FsItem) -> FileItem {
        let date = Date(timeIntervalSince1970: TimeInterval(fs.mtime) / 1000)
        let contentType = contentTypeIdentifier(name: fs.name, isDirectory: fs.dir)
        return FileItem(
            identifier: identifier(path: path, ino: fs.ino),
            parentIdentifier: parentIdentifier,
            name: fs.name,
            isDirectory: fs.dir,
            size: fs.size,
            modificationDate: date,
            contentTypeIdentifier: contentType,
            etag: fs.etag,
            contentVersion: Data(fs.etag.utf8),
            metadataVersion: metadataVersion(name: fs.name, size: fs.size,
                                             mtime: fs.mtime, ino: fs.ino))
    }

    /// A hash of (name, size, mtime, ino): the metadata version changes when
    /// anything but the content does (design §3).
    static func metadataVersion(name: String, size: Int, mtime: Int, ino: Int) -> Data {
        let text = "\(name)|\(size)|\(mtime)|\(ino)"
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    /// The root item: a folder named after the phone, versioned by its children.
    static func rootItem(name: String, version: Data) -> FileItem {
        FileItem(identifier: rootIdentifier, parentIdentifier: rootIdentifier,
                 name: name, isDirectory: true, size: 0,
                 modificationDate: Date(timeIntervalSince1970: 0),
                 contentTypeIdentifier: UTType.folder.identifier, etag: "",
                 contentVersion: version, metadataVersion: version)
    }

    static func childPath(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : "\(parent)/\(name)"
    }

    static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

/// NSFileProviderItemIdentifier.rootContainer is the string ".rootContainer";
/// repeated here so this file does not need FileProvider.
let filesRootIdentifier = ".rootContainer"

// MARK: - The app-owned identifier map

/// The app's id ↔ path map (design §3, S4). It is the only thing that can turn
/// an `ino:` identifier back into a path, so it lives in the app, one process,
/// and is persisted per profile. Every listing and stat reply fills it; every
/// successful write, move, delete and mkdir updates it.
struct FilesIdMap: Equatable {
    /// The persisted shape. A different version is a fresh map: S3's ids carried
    /// a path and are not worth migrating.
    static let formatVersion = 2

    private(set) var pathByIdentifier: [String: String] = [FilesMap.rootIdentifier: ""]
    private(set) var identifierByPath: [String: String] = ["": FilesMap.rootIdentifier]
    private(set) var parentByIdentifier: [String: String] = [FilesMap.rootIdentifier: FilesMap.rootIdentifier]

    init() {}

    var isEmpty: Bool { pathByIdentifier.count <= 1 }

    /// Registers one item (a listing entry, a stat result or a write's reply)
    /// and returns its mapped item.
    @discardableResult
    mutating func insert(fs: FsItem, path: String, parentIdentifier: String) -> FileItem {
        let item = FilesMap.item(path: path, parentIdentifier: parentIdentifier, fs: fs)
        remember(identifier: item.identifier, path: path, parentIdentifier: parentIdentifier)
        return item
    }

    /// Registers a whole page; returns the mapped items in listing order.
    mutating func insert(childrenOf parentPath: String, parentIdentifier: String,
                         items: [FsItem]) -> [FileItem] {
        items.map { fs in
            insert(fs: fs, path: FilesMap.childPath(parentPath, fs.name),
                   parentIdentifier: parentIdentifier)
        }
    }

    /// Records an id the app already has an item for (a write or move reply
    /// carries the new metadata, not a fresh listing).
    mutating func remember(identifier: String, path: String, parentIdentifier: String) {
        if let old = pathByIdentifier[identifier], old != path {
            identifierByPath.removeValue(forKey: old)
        }
        if let occupant = identifierByPath[path], occupant != identifier {
            pathByIdentifier.removeValue(forKey: occupant)
            parentByIdentifier.removeValue(forKey: occupant)
        }
        pathByIdentifier[identifier] = path
        identifierByPath[path] = identifier
        parentByIdentifier[identifier] = parentIdentifier
    }

    func path(for identifier: String) -> String? { pathByIdentifier[identifier] }

    func identifier(for path: String) -> String? { identifierByPath[path] }

    func parent(for identifier: String) -> String? { parentByIdentifier[identifier] }

    /// Forgets a path and everything below it (a delete, or a folder whose
    /// listing is about to be re-read).
    mutating func invalidate(subtree path: String) {
        let prefix = path.isEmpty ? "" : path + "/"
        let doomed = pathByIdentifier.filter { id, known in
            id != FilesMap.rootIdentifier && (known == path || known.hasPrefix(prefix))
        }
        for (id, known) in doomed {
            pathByIdentifier.removeValue(forKey: id)
            parentByIdentifier.removeValue(forKey: id)
            identifierByPath.removeValue(forKey: known)
        }
    }

    /// A rename keeps the identifier: only the path (and its descendants')
    /// changes. The old path is forgotten.
    mutating func rename(identifier: String, to newPath: String) {
        guard let old = pathByIdentifier[identifier] else { return }
        identifierByPath.removeValue(forKey: old)
        if let occupant = identifierByPath[newPath] {
            pathByIdentifier.removeValue(forKey: occupant)
            parentByIdentifier.removeValue(forKey: occupant)
        }
        pathByIdentifier[identifier] = newPath
        identifierByPath[newPath] = identifier
        guard !old.isEmpty else { return }
        let prefix = old + "/"
        for (id, known) in pathByIdentifier where known.hasPrefix(prefix) {
            let moved = newPath + String(known.dropFirst(old.count))
            identifierByPath.removeValue(forKey: known)
            pathByIdentifier[id] = moved
            identifierByPath[moved] = id
        }
    }

    // MARK: Persistence

    /// The persisted JSON: a version and one entry per id. Names are not in it
    /// (only paths), and the file is 0600 in the profile's support folder.
    func encoded() -> Data {
        var ids: [String: [String: String]] = [:]
        for (identifier, path) in pathByIdentifier {
            ids[identifier] = ["p": path,
                               "n": parentByIdentifier[identifier] ?? FilesMap.rootIdentifier]
        }
        let object: [String: Any] = ["version": Self.formatVersion, "ids": ids]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// A corrupt, foreign or older file is a fresh map (the caller re-adds the
    /// domain, which drops the ids the map cannot explain).
    static func decode(_ data: Data) -> FilesIdMap? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = (object["version"] as? NSNumber)?.intValue,
              version == formatVersion,
              let ids = object["ids"] as? [String: [String: String]] else { return nil }
        var map = FilesIdMap()
        map.pathByIdentifier.removeAll()
        map.identifierByPath.removeAll()
        map.parentByIdentifier.removeAll()
        for (identifier, fields) in ids {
            guard let path = fields["p"], let parent = fields["n"] else { return nil }
            map.pathByIdentifier[identifier] = path
            if map.identifierByPath[path] == nil { map.identifierByPath[path] = identifier }
            map.parentByIdentifier[identifier] = parent
        }
        guard map.pathByIdentifier[FilesMap.rootIdentifier] == "" else { return nil }
        return map
    }

    static func load(_ url: URL) -> FilesIdMap {
        guard let data = try? Data(contentsOf: url), let map = decode(data) else {
            return FilesIdMap()
        }
        return map
    }

    static func save(_ map: FilesIdMap, to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? map.encoded().write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }
}

// MARK: - Conflicts

/// What a write becomes when the phone's copy moved on (design §4 "Conflicts"):
/// keep both. `<name> (from Mac).<ext>`, numbered when that is taken too.
enum FilesConflict {
    static func name(for name: String, taken: (String) -> Bool = { _ in false }) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = "\(base) (from Mac)\(suffix)"
        var number = 2
        while taken(candidate) {
            candidate = "\(base) (from Mac \(number))\(suffix)"
            number += 1
        }
        return candidate
    }
}

// MARK: - Error mapping

/// What a failure means to the File Provider. The extension turns these into
/// the NSError classes the system documents; the mapping itself is testable.
enum FilesFailure: String, CaseIterable {
    /// No phone session: dataless items are unreachable, cached ones still open.
    case offline
    /// The phone says the item is gone.
    case notFound
    /// The phone refuses to read it.
    case denied
    /// The etag moved: refetch the metadata once, then notFound if it is gone.
    case stale
    /// Over the 1 GiB cap.
    case tooLarge
    /// Something already exists at that path.
    case exists
    /// A folder operation on a file.
    case notADirectory
    /// The phone is serving its other client / this feature is busy.
    case busy
    /// The system cancelled the transfer.
    case cancelled
    /// Local I/O or a broken read (size or hash mismatch).
    case io
    /// The phone answered something this side does not understand.
    case protocolError

    /// One mapping for every code either side can produce.
    static func from(code: String) -> FilesFailure {
        switch code {
        case "offline", "closed": return .offline
        case "fs_not_found": return .notFound
        case "fs_denied": return .denied
        case "fs_stale": return .stale
        case "fs_too_large": return .tooLarge
        case "fs_exists": return .exists
        case "fs_not_a_dir": return .notADirectory
        case "fs_busy", "busy": return .busy
        case "cancelled": return .cancelled
        case "io", "checksum": return .io
        default: return .protocolError
        }
    }
}
