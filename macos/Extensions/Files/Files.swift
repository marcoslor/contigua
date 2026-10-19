// File Provider experiment (E1/E2/E3/E4 in docs/design/files.md §1): a
// replicated extension serving a hard-coded tree. It never dials the phone:
// the app owns the session, so the extension only asks the app over a UNIX
// socket in the shared App Group container. The two socket paths are also the
// experiment: the group container (E2) and, as the fallback, the profile's
// Application Support folder reached through a temporary sandbox exception.
//
// Built by macos/scripts/bundle.sh with swiftc (SwiftPM cannot link an app
// extension's entry point); the class is named in the Info.plist's
// NSExtensionPrincipalClass as Files.FilesExtension.

import CoreGraphics
import FileProvider
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let groupID = "group.dev.pocketdeck.mac.files.filesexp"
private let profileFolder = "PocketDeck-filesexp"

// MARK: - Logging

/// The extension has no terminal: every step goes to os_log and to a file the
/// check can read afterwards (the group container when it exists, else the
/// profile folder the temporary exception allows).
func expLog(_ message: String) {
    NSLog("files-exp: %@", message)
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    for dir in logDirectories() {
        let url = dir.appendingPathComponent("files-ext.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// The person's real home, not the sandbox container `NSHomeDirectory()`
/// returns inside an appex: the temporary exception is relative to the real one.
func realHome() -> String {
    if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
        return String(cString: home)
    }
    return NSHomeDirectory()
}

func logDirectories() -> [URL] {
    var dirs: [URL] = []
    if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
        dirs.append(group)
    }
    let support = URL(fileURLWithPath: realHome())
        .appendingPathComponent("Library/Application Support/\(profileFolder)", isDirectory: true)
    dirs.append(support)
    for dir in dirs { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    return dirs
}

// MARK: - The app bridge socket (E2)

/// Candidates in order: the App Group container, then the profile folder. The
/// first one that answers `pong` is the one the sandbox honours.
func socketCandidates() -> [(label: String, path: String)] {
    var out: [(String, String)] = []
    if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
        out.append(("group", group.appendingPathComponent("files.sock").path))
    }
    out.append(("app-support", URL(fileURLWithPath: realHome())
        .appendingPathComponent("Library/Application Support/\(profileFolder)/files.sock").path))
    return out
}

/// Returns (label, result) where result is "pong" or "errno N".
func pingBridge() -> [(String, String)] {
    socketCandidates().map { candidate in
        (candidate.label, ping(path: candidate.path))
    }
}

func ping(path: String) -> String {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return "path too long" }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return "errno \(errno)" }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let rc = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { return "errno \(errno)" }
    let request = Array("ping\n".utf8)
    guard write(fd, request, request.count) == request.count else { return "errno \(errno) (write)" }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = read(fd, &buffer, buffer.count)
    guard count > 0 else { return "errno \(errno) (read)" }
    return String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - The hard-coded tree

let bigFileSize = 5 * 1024 * 1024

/// Thread-safe because the system calls the extension from several queues.
final class Tree {
    static let shared = Tree()
    private let lock = NSLock()
    private var items: [String: ExpItem] = [:]

    private init() {
        let version = NSFileProviderItemVersion(
            contentVersion: Data("files-exp-1".utf8),
            metadataVersion: Data("files-exp-1".utf8))
        items["dcim"] = ExpItem(id: "dcim", parent: .rootContainer, name: "DCIM",
                                type: .folder, size: nil, version: version)
        items["notes"] = ExpItem(id: "notes", parent: NSFileProviderItemIdentifier("dcim"),
                                 name: "notes.txt",
                                 type: .plainText, size: 42, version: version)
        items["big"] = ExpItem(id: "big", parent: NSFileProviderItemIdentifier("dcim"),
                               name: "big.bin",
                               type: .data, size: bigFileSize, version: version)
    }

    func children(of parent: NSFileProviderItemIdentifier) -> [ExpItem] {
        lock.lock(); defer { lock.unlock() }
        let wanted = parent == .rootContainer ? NSFileProviderItemIdentifier.rootContainer.rawValue : parent.rawValue
        return items.values.filter { $0.parentItemIdentifier.rawValue == wanted }.sorted { $0.filename < $1.filename }
    }

    func item(_ id: NSFileProviderItemIdentifier) -> ExpItem? {
        if id == .rootContainer { return ExpItem.root }
        lock.lock(); defer { lock.unlock() }
        return items[id.rawValue]
    }

    @discardableResult
    func add(name: String, parent: NSFileProviderItemIdentifier, size: Int) -> ExpItem {
        let id = "local-\(name)"
        let version = NSFileProviderItemVersion(contentVersion: Data(id.utf8), metadataVersion: Data(id.utf8))
        let item = ExpItem(id: id, parent: parent, name: name, type: .data, size: size, version: version)
        lock.lock(); items[id] = item; lock.unlock()
        return item
    }
}

final class ExpItem: NSObject, NSFileProviderItem {
    let rawId: String
    let parent: NSFileProviderItemIdentifier
    let name: String
    let type: UTType
    let size: Int?
    let version: NSFileProviderItemVersion

    static var root: ExpItem {
        ExpItem(id: NSFileProviderItemIdentifier.rootContainer.rawValue,
                parent: .rootContainer, name: "PocketDeck Files", type: .folder, size: nil,
                version: NSFileProviderItemVersion(contentVersion: Data("root".utf8),
                                                   metadataVersion: Data("root".utf8)))
    }

    init(id: String, parent: NSFileProviderItemIdentifier, name: String,
         type: UTType, size: Int?, version: NSFileProviderItemVersion) {
        self.rawId = id
        self.parent = parent
        self.name = name
        self.type = type
        self.size = size
        self.version = version
        super.init()
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        rawId == NSFileProviderItemIdentifier.rootContainer.rawValue ? .rootContainer
            : NSFileProviderItemIdentifier(rawId)
    }
    var parentItemIdentifier: NSFileProviderItemIdentifier { parent }
    var filename: String { name }
    var contentType: UTType { type }
    var documentSize: NSNumber? { size.map(NSNumber.init) }
    var contentModificationDate: Date? { Date(timeIntervalSince1970: 1_700_000_000) }
    var itemVersion: NSFileProviderItemVersion { version }
    var capabilities: NSFileProviderItemCapabilities {
        type == .folder ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
                        : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting]
    }
}

// MARK: - Extension

@objc(FilesExtension)
final class FilesExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        expLog("init domain=\(domain.identifier.rawValue) display=\(domain.displayName)")
        for (label, result) in pingBridge() {
            expLog("socket \(label)=\(result)")
        }
    }

    func invalidate() {
        expLog("invalidate")
    }

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        expLog("item \(identifier.rawValue)")
        if let item = Tree.shared.item(identifier) {
            completionHandler(item, nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let item = Tree.shared.item(itemIdentifier), item.type != .folder else {
            expLog("fetchContents \(itemIdentifier.rawValue) noSuchItem")
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let size = item.documentSize?.intValue ?? 0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-exp-\(UUID().uuidString)")
        var data = Data()
        if itemIdentifier.rawValue == "big" {
            data = Data(repeating: 0x42, count: size)
        } else {
            data = Data("PocketDeck files experiment: \(item.filename)\n".utf8)
        }
        do {
            try data.write(to: url)
        } catch {
            expLog("fetchContents \(itemIdentifier.rawValue) write failed: \(error)")
            completionHandler(nil, nil, error)
            return Progress()
        }
        expLog("fetchContents \(itemIdentifier.rawValue) bytes=\(data.count) -> \(url.path)")
        completionHandler(url, item, nil)
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        expLog("enumerator \(containerItemIdentifier.rawValue)")
        return TreeEnumerator(container: containerItemIdentifier)
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let bytes = url.flatMap { try? Data(contentsOf: $0).count } ?? 0
        let disconnected = domain.isDisconnected
        if disconnected {
            // Offline (E3): the system keeps the item as pending. notAuthenticated
            // is the code Apple documents for "cannot sync right now, retry later".
            expLog("createItem \(itemTemplate.filename) bytes=\(bytes) rejected: domain disconnected -> pending")
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return Progress()
        }
        let item = Tree.shared.add(name: itemTemplate.filename,
                                   parent: itemTemplate.parentItemIdentifier,
                                   size: bytes)
        expLog("createItem \(itemTemplate.filename) bytes=\(bytes) accepted id=\(item.itemIdentifier.rawValue)")
        completionHandler(item, [], false, nil)
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        expLog("modifyItem \(item.itemIdentifier.rawValue) fields=\(changedFields.rawValue)")
        completionHandler(item, [], false, nil)
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions,
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        expLog("deleteItem \(identifier.rawValue)")
        completionHandler(nil)
        return Progress()
    }

    // E4: a thumbnail for the file types the system asks about, without a
    // materialization (fetchContents is not called for these items).
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier],
                         requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        expLog("fetchThumbnails ids=\(itemIdentifiers.map(\.rawValue).joined(separator: ",")) size=\(Int(size.width))x\(Int(size.height))")
        for id in itemIdentifiers {
            if let png = thumbnailPNG(size: size) {
                perThumbnailCompletionHandler(id, png, nil)
            } else {
                perThumbnailCompletionHandler(id, nil, nil)
            }
        }
        completionHandler(nil)
        return Progress(totalUnitCount: Int64(itemIdentifiers.count))
    }
}

/// A small solid-colour PNG; the point is that the system gets image data from
/// the extension, not that the picture means anything.
func thumbnailPNG(size: CGSize) -> Data? {
    let width = max(1, Int(size.width)), height = max(1, Int(size.height))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

// MARK: - Enumeration

final class TreeEnumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier

    init(container: NSFileProviderItemIdentifier) {
        self.container = container
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        let items = Tree.shared.children(of: container)
        expLog("enumerate \(container.rawValue) -> \(items.count) items")
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        // The experiment never reports remote changes; answer with the current
        // state and a new anchor, which is all Finder needs to draw the folder.
        observer.didUpdate(Tree.shared.children(of: container))
        observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(Data("anchor-1".utf8)), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("anchor-1".utf8)))
    }
}
