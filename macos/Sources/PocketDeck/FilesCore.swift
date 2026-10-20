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
enum BridgeRequest: Equatable {
    case hello(id: UInt32, version: Int)
    case list(id: UInt32, path: String, page: String?)
    case stat(id: UInt32, path: String)
    case read(id: UInt32, path: String, offset: Int, length: Int, etag: String?)
    case cancel(id: UInt32)

    var id: UInt32 {
        switch self {
        case .hello(let id, _), .list(let id, _, _), .stat(let id, _),
             .read(let id, _, _, _, _), .cancel(let id):
            return id
        }
    }
}

/// A reply: one JSON line, and for a read the `data` headers with their raw
/// bytes, then `end` (or `error`).
enum BridgeReply: Equatable {
    case hello(id: UInt32, version: Int, name: String?, connected: Bool)
    case items(id: UInt32, page: String?, items: [FsItem])
    case item(id: UInt32, item: FsItem)
    /// Announcement of `length` raw bytes that follow the newline.
    case data(id: UInt32, length: Int)
    case end(id: UInt32, size: Int, sha256: String)
    case error(id: UInt32, code: String)
}

/// The bridge protocol version. Both sides refuse anything else.
let filesBridgeVersion = 1

enum BridgeWire {
    /// A request line is at most 64 KiB (design §3's cap, applied locally).
    static let maxLineBytes = 64 * 1024
    /// A data chunk is one fs.read frame (≤ 256 KiB); the cap is a sanity check.
    static let maxChunkBytes = 8 * 1024 * 1024

    static func line(_ request: BridgeRequest) -> Data {
        var object: [String: Any] = ["id": Int(request.id)]
        switch request {
        case .hello(_, let version):
            object["t"] = "hello"
            object["version"] = version
        case .list(_, let path, let page):
            object["t"] = "list"
            object["path"] = path
            if let page { object["page"] = page }
        case .stat(_, let path):
            object["t"] = "stat"
            object["path"] = path
        case .read(_, let path, let offset, let length, let etag):
            object["t"] = "read"
            object["path"] = path
            object["offset"] = offset
            object["length"] = length
            if let etag { object["etag"] = etag }
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
    private var line: [UInt8] = []
    private var chunk: [UInt8] = []
    private var chunkID: UInt32 = 0
    private var remaining = 0
    /// Set when a line grew past the cap: the stream cannot be trusted, the
    /// caller closes the connection.
    private(set) var broken = false

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
                if line.count > BridgeWire.maxLineBytes {
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
                if line.count > BridgeWire.maxLineBytes {
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
            guard let path = object["path"] as? String else { return .invalid("bad_request") }
            switch type {
            case "list":
                return .request(.list(id: id, path: path, page: object["page"] as? String))
            case "stat":
                return .request(.stat(id: id, path: path))
            default:
                guard let offset = (object["offset"] as? NSNumber)?.intValue,
                      let length = (object["length"] as? NSNumber)?.intValue else {
                    return .invalid("bad_request")
                }
                return .request(.read(id: id, path: path, offset: offset, length: length,
                                      etag: object["etag"] as? String))
            }
        case "cancel":
            return .request(.cancel(id: id))
        case "items":
            let items = (object["items"] as? [[String: Any]])?.compactMap(FsItem.init(json:)) ?? []
            return .reply(.items(id: id, page: object["page"] as? String, items: items))
        case "item":
            guard let item = FsItem(json: object["item"] as? [String: Any] ?? [:]) else {
                return .invalid("bad_item")
            }
            return .reply(.item(id: id, item: item))
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
/// raw bytes the extension wraps in NSFileProviderItemVersion.
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
}

enum FilesMap {
    /// NSFileProviderItemIdentifier.rootContainer's raw value.
    static let rootIdentifier = filesRootIdentifier

    /// `ino:<st_ino>` identifies the item; a phone that reports ino 0 (some
    /// FUSE mounts do) falls back to the relative path, which a rename breaks
    /// but an ino-less phone cannot do better (design §3 "Identifiers").
    static func identifier(path: String, ino: Int) -> String {
        if path.isEmpty { return rootIdentifier }
        if ino > 0 { return "ino:\(ino)" }
        return "path:\(path)"
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
}

/// NSFileProviderItemIdentifier.rootContainer is the string ".rootContainer";
/// repeated here so this file does not need FileProvider.
let filesRootIdentifier = ".rootContainer"

// MARK: - Identifier ↔ path map

/// The extension's id ↔ path map, filled by listings and stats. Identifiers
/// come from the phone's ino (or the path when it reports none); a rename
/// keeps the identifier and only moves the path.
struct FilesPathMap: Equatable {
    private(set) var pathByIdentifier: [String: String] = [FilesMap.rootIdentifier: ""]
    private(set) var identifierByPath: [String: String] = ["": FilesMap.rootIdentifier]

    init() {}

    /// Registers one item (a listing entry or a stat result) and returns its
    /// mapped item. The parent identifier is the container's identifier.
    @discardableResult
    mutating func insert(fs: FsItem, path: String, parentIdentifier: String) -> FileItem {
        let item = FilesMap.item(path: path, parentIdentifier: parentIdentifier, fs: fs)
        pathByIdentifier[item.identifier] = path
        identifierByPath[path] = item.identifier
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

    func path(for identifier: String) -> String? {
        pathByIdentifier[identifier]
    }

    func identifier(for path: String) -> String? {
        identifierByPath[path]
    }

    /// Forgets a path and everything below it (a delete, or a folder whose
    /// listing is about to be re-read).
    mutating func invalidate(subtree path: String) {
        let prefix = path.isEmpty ? "" : path + "/"
        let doomed = pathByIdentifier.filter { id, known in
            id != FilesMap.rootIdentifier && (known == path || known.hasPrefix(prefix))
        }
        for (id, known) in doomed {
            pathByIdentifier.removeValue(forKey: id)
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
