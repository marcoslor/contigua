// Drop sources beyond a plain file URL (SHARE-18, docs/design/dragdrop.md):
// image data, an http(s) image link and a file promise all become temp files
// for the existing drop path. D1's order is the heart: a local source always
// wins, and a download is only attempted when nothing richer is on the drag.

import AppKit
import Foundation
import UniformTypeIdentifiers

/// D1: the source one drag resolves to.
enum DropSourceChoice: Equatable {
    case files
    case promises
    case image
    case remote
    case none
}

/// The pure D1 rule: a file URL > a file promise > image data > an http(s) link.
enum DropSourceOrder {
    static func choose(files: Bool, promises: Bool, image: Bool, remote: Bool) -> DropSourceChoice {
        if files { return .files }
        if promises { return .promises }
        if image { return .image }
        if remote { return .remote }
        return .none
    }

    static func choose(_ drag: DropDrag) -> DropSourceChoice {
        choose(files: !drag.files.isEmpty, promises: !drag.promises.isEmpty,
               image: drag.image != nil, remote: drag.remote != nil)
    }
}

/// One image representation from the pasteboard, as it came.
struct DropImage: Sendable {
    var data: Data
    var type: UTType
}

/// A file promise (Photos, Safari's image drags): the receiver delivers files
/// into a folder the caller owns. A seam so K2 can fake delivery and silence.
@MainActor
protocol DropPromiseSource: AnyObject {
    func receive(into directory: URL, completion: @escaping (Result<[URL], Error>) -> Void)
}

/// What one drag carries, reduced to the winner of D1's order.
struct DropDrag {
    var files: [URL] = []
    var promises: [any DropPromiseSource] = []
    var image: DropImage?
    var remote: URL?

    /// A log token: never a name, path or URL (R-PRIV-1).
    var kind: String {
        switch DropSourceOrder.choose(self) {
        case .files: return "file(s) \(files.count)"
        case .promises: return "promise(s) \(promises.count)"
        case .image: return "image data"
        case .remote: return "link"
        case .none: return "nothing"
        }
    }
}

/// The real pasteboard receiver behind `NSFilePromiseReceiver`. The receiver
/// writes the promised files into the gesture's folder under its own names.
@MainActor
final class PasteboardFilePromise: DropPromiseSource {
    private let receiver: NSFilePromiseReceiver
    private var started = false

    init(_ receiver: NSFilePromiseReceiver) {
        self.receiver = receiver
    }

    func receive(into directory: URL, completion: @escaping (Result<[URL], Error>) -> Void) {
        guard !started else { return }
        started = true
        let expected = max(1, receiver.fileNames.count)
        var files: [URL] = []
        var errors: [Error] = []
        receiver.receivePromisedFiles(atDestination: directory, options: [:],
                                      operationQueue: .main) { url, error in
            if let error { errors.append(error) } else { files.append(url) }
            guard files.count + errors.count >= expected else { return }
            if files.isEmpty {
                completion(.failure(errors.first ?? CocoaError(.fileReadUnknown)))
            } else {
                completion(.success(files))
            }
        }
    }
}

/// Reads a pasteboard in D1's order. Only the winning source is materialised,
/// so a browser drag carrying a file URL, a promise and image data never
/// downloads anything.
enum DropDragReader {
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.png.identifier),
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.tiff.identifier),
        NSPasteboard.PasteboardType(UTType.image.identifier),
    ]
    static let promiseTypes: [NSPasteboard.PasteboardType] =
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func canRead(_ board: NSPasteboard) -> Bool {
        board.availableType(from: [.fileURL]) != nil
            || board.availableType(from: promiseTypes) != nil
            || board.availableType(from: imageTypes) != nil
            || board.availableType(from: [.URL]) != nil
    }

    static func read(_ board: NSPasteboard) -> DropDrag? {
        let files = fileURLs(board)
        if !files.isEmpty { return DropDrag(files: files) }
        let promises = promises(board)
        if !promises.isEmpty { return DropDrag(promises: promises) }
        if let image = image(board) { return DropDrag(image: image) }
        if let remote = remoteURL(board) { return DropDrag(remote: remote) }
        return nil
    }

    static func fileURLs(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self],
                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func promises(_ board: NSPasteboard) -> [any DropPromiseSource] {
        guard let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                               options: nil) as? [NSFilePromiseReceiver] else {
            return []
        }
        return receivers.map(PasteboardFilePromise.init)
    }

    static func image(_ board: NSPasteboard) -> DropImage? {
        let types: [(NSPasteboard.PasteboardType, UTType)] = [
            (imageTypes[0], .png), (imageTypes[1], .jpeg), (imageTypes[2], .tiff), (imageTypes[3], .image),
        ]
        for (pasteboardType, type) in types {
            guard board.availableType(from: [pasteboardType]) != nil,
                  let data = board.data(forType: pasteboardType), !data.isEmpty else { continue }
            return DropImage(data: data, type: type)
        }
        // Some apps offer only an NSImage representation; its TIFF goes through
        // the same re-encode rule.
        guard let image = NSImage(pasteboard: board),
              let tiff = image.tiffRepresentation, !tiff.isEmpty else { return nil }
        return DropImage(data: tiff, type: .tiff)
    }

    static func remoteURL(_ board: NSPasteboard) -> URL? {
        if let string = board.string(forType: .URL), let url = URL(string: string),
           DropDownloadPolicy.allows(url) {
            return url
        }
        let urls = (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        return urls.first { DropDownloadPolicy.allows($0) }
    }
}

/// The names D2 writes: Image.png/Image.jpg for bare image data, the URL's own
/// file name when it has one. DropName applies the phone's rules.
enum DropSourceName {
    static func image(mime: String) -> String {
        mime.lowercased() == "image/jpeg" ? "Image.jpg" : "Image.png"
    }

    static func downloaded(_ url: URL, mime: String, ext: String) -> String {
        var raw = url.lastPathComponent
        if raw.isEmpty || raw == "/" { raw = "Image" }
        if (raw as NSString).pathExtension.isEmpty { raw += ".\(ext)" }
        return DropName.sanitize(raw, mime: mime).file
    }
}

/// Why a source never became files. `text` is the pill's one line; only
/// `notImage` is the spec's own copy (SHARE-18).
enum DropResolveFailure: Error, Equatable {
    case notImage
    case tooLarge
    case timedOut
    case failed
    case unreadable
    case cancelled

    var text: String {
        switch self {
        case .notImage: return "That link isn't an image. Drop the link itself to open it."
        case .tooLarge: return "That image is bigger than 8 MB, nothing was sent."
        case .timedOut: return "That image took too long to download."
        case .unreadable: return "Couldn't read that image."
        case .failed: return "Couldn't download that image."
        case .cancelled: return "Drop cancelled."
        }
    }

    /// A closed token for the e2e chrome state, never a message.
    var token: String {
        switch self {
        case .notImage: return "not_image"
        case .tooLarge: return "too_large"
        case .timedOut: return "timed_out"
        case .failed: return "failed"
        case .unreadable: return "unreadable"
        case .cancelled: return "cancelled"
        }
    }
}

enum DropResolvePhase: Equatable {
    case idle
    case resolving
    case ready
    case refused(DropResolveFailure)
    case timedOut
    case cancelled
}

enum DropResolveEvent: Equatable {
    case start
    case resolved
    case refused(DropResolveFailure)
    case timedOut
    case cancelled
    case sessionEnded
    case finished
    case dismissed
}

enum DropResolveAction: Equatable {
    case begin
    case handOff
    case refuse(DropResolveFailure)
    case cancel
    case cleanup
    case hide
}

/// resolving -> ready | refused | timedOut | cancelled, with the session able
/// to end in every state (SHARE-18, AGENTS.md).
struct DropResolveMachine {
    private(set) var phase: DropResolvePhase = .idle

    mutating func handle(_ event: DropResolveEvent) -> [DropResolveAction] {
        switch event {
        case .start:
            switch phase {
            case .idle, .refused, .timedOut, .cancelled:
                phase = .resolving
                return [.begin]
            case .resolving, .ready:
                return []
            }
        case .resolved:
            guard phase == .resolving else { return [] }
            phase = .ready
            return [.handOff]
        case .refused(let failure):
            guard phase == .resolving else { return [] }
            phase = .refused(failure)
            return [.refuse(failure)]
        case .timedOut:
            guard phase == .resolving else { return [] }
            phase = .timedOut
            return [.refuse(.timedOut)]
        case .cancelled:
            guard phase == .resolving else { return [] }
            phase = .cancelled
            return [.cancel]
        case .sessionEnded:
            switch phase {
            case .idle:
                return []
            case .resolving:
                phase = .cancelled
                return [.cancel]
            case .ready:
                phase = .cancelled
                return [.cleanup]
            case .refused, .timedOut, .cancelled:
                phase = .cancelled
                return [.cleanup, .hide]
            }
        case .finished:
            guard phase == .ready else { return [] }
            phase = .idle
            return [.cleanup]
        case .dismissed:
            switch phase {
            case .idle:
                return []
            case .resolving:
                phase = .cancelled
                return [.cancel, .hide]
            case .ready:
                phase = .idle
                return [.cleanup]
            case .refused, .timedOut, .cancelled:
                phase = .idle
                return [.hide]
            }
        }
    }
}

/// The per-gesture temporary folder (D4). Deleted on a result, a cancel and a
/// session end; leftovers older than 24 h are swept at launch.
enum DropScratch {
    static let prefix = "Contigua-drop-"
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func makeFolder(in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func sweep(in root: URL = FileManager.default.temporaryDirectory,
                      now: Date = Date(), maxAge: TimeInterval = maxAge) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > maxAge else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func remove(_ folder: URL?) {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Materialises the winning D1 source into a per-gesture folder.
@MainActor
final class DropSourceResolver {
    struct Resolved: Equatable {
        var files: [URL]
        var folder: URL?
    }

    private let root: URL
    private let downloader: any DropDownloading
    private let promiseWait: TimeInterval
    private var cancelled = false
    private var folder: URL?
    private var promiseTimeout: Task<Void, Never>?

    init(root: URL = FileManager.default.temporaryDirectory,
         downloader: any DropDownloading = DropDownloader(),
         promiseWait: TimeInterval = 30) {
        self.root = root
        self.downloader = downloader
        self.promiseWait = promiseWait
    }

    func resolve(_ drag: DropDrag,
                 completion: @escaping (Result<Resolved, DropResolveFailure>) -> Void) {
        cancelled = false
        switch DropSourceOrder.choose(drag) {
        case .files:
            completion(.success(Resolved(files: drag.files, folder: nil)))
        case .promises:
            resolvePromises(drag.promises, completion: completion)
        case .image:
            guard let image = drag.image else { return completion(.failure(.unreadable)) }
            resolveImage(image, completion: completion)
        case .remote:
            guard let url = drag.remote else { return completion(.failure(.failed)) }
            resolveRemote(url, completion: completion)
        case .none:
            completion(.failure(.failed))
        }
    }

    func cancel() {
        cancelled = true
        promiseTimeout?.cancel()
        promiseTimeout = nil
        downloader.cancel()
        removeFolder()
    }

    private func makeFolder() -> URL? {
        guard let made = try? DropScratch.makeFolder(in: root) else { return nil }
        folder = made
        return made
    }

    private func resolvePromises(_ promises: [any DropPromiseSource],
                                 completion: @escaping (Result<Resolved, DropResolveFailure>) -> Void) {
        guard let folder = makeFolder() else { return completion(.failure(.failed)) }
        let group = DispatchGroup()
        var files: [URL] = []
        var refused = false
        for promise in promises {
            group.enter()
            promise.receive(into: folder) { result in
                switch result {
                case .success(let delivered): files += delivered
                case .failure: refused = true
                }
                group.leave()
            }
        }
        promiseTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(promiseWait))
            guard !Task.isCancelled, let self, !self.cancelled else { return }
            self.promiseTimeout = nil
            self.fail(.timedOut, completion)
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, !self.cancelled else { return }
            self.promiseTimeout?.cancel()
            self.promiseTimeout = nil
            if files.isEmpty {
                self.fail(refused ? .failed : .unreadable, completion)
            } else {
                completion(.success(Resolved(files: files, folder: folder)))
            }
        }
    }

    private func resolveImage(_ image: DropImage,
                              completion: @escaping (Result<Resolved, DropResolveFailure>) -> Void) {
        guard image.data.count <= ClipboardSync.maxImageBytes else {
            return completion(.failure(.tooLarge))
        }
        guard let folder = makeFolder() else { return completion(.failure(.failed)) }
        Task.detached(priority: .userInitiated) { [weak self] in
            let encoded = FileCopyImage.encode(image.data, type: image.type)
            await MainActor.run {
                guard let self, !self.cancelled else { return }
                guard let (data, mime) = encoded else {
                    return self.fail(.unreadable, completion)
                }
                let file = folder.appendingPathComponent(DropSourceName.image(mime: mime))
                do {
                    try data.write(to: file)
                    completion(.success(Resolved(files: [file], folder: folder)))
                } catch {
                    self.fail(.failed, completion)
                }
            }
        }
    }

    private func resolveRemote(_ url: URL,
                               completion: @escaping (Result<Resolved, DropResolveFailure>) -> Void) {
        guard let folder = makeFolder() else { return completion(.failure(.failed)) }
        downloader.download(url) { [weak self] result in
            guard let self, !self.cancelled else { return }
            switch result {
            case .failure(let failure):
                self.fail(failure, completion)
            case .success(let download):
                let name = DropSourceName.downloaded(url, mime: download.mime, ext: download.ext)
                let file = folder.appendingPathComponent(name)
                do {
                    try download.data.write(to: file)
                    completion(.success(Resolved(files: [file], folder: folder)))
                } catch {
                    self.fail(.failed, completion)
                }
            }
        }
    }

    private func fail(_ failure: DropResolveFailure,
                      _ completion: @escaping (Result<Resolved, DropResolveFailure>) -> Void) {
        removeFolder()
        completion(.failure(failure))
    }

    private func removeFolder() {
        DropScratch.remove(folder)
        folder = nil
    }
}

/// Drives one drag's resolution: the machine above, the resolver's async work,
/// and the one folder the gesture owns.
@MainActor
final class DropSourceFlow {
    private(set) var machine = DropResolveMachine()

    var onFiles: (([URL], URL?) -> Void)?
    var onRefuse: ((DropResolveFailure) -> Void)?
    var onHide: (() -> Void)?

    private let resolver: DropSourceResolver
    private var drag: DropDrag?
    private var pending: DropSourceResolver.Resolved?
    private(set) var folder: URL?

    init(root: URL = FileManager.default.temporaryDirectory, promiseWait: TimeInterval = 30) {
        resolver = DropSourceResolver(root: root, promiseWait: promiseWait)
    }

    var phase: DropResolvePhase { machine.phase }
    var isReady: Bool { machine.phase == .ready }

    func start(_ drag: DropDrag) {
        let actions = machine.handle(.start)
        guard !actions.isEmpty else { return }
        self.drag = drag
        run(actions)
    }

    func sessionEnded() { run(machine.handle(.sessionEnded)) }
    func cancelled() { run(machine.handle(.cancelled)) }
    func settled() { run(machine.handle(.finished)) }
    func dismissed() { run(machine.handle(.dismissed)) }

    private func resolved(_ result: Result<DropSourceResolver.Resolved, DropResolveFailure>) {
        switch result {
        case .success(let resolved):
            pending = resolved
            run(machine.handle(.resolved))
        case .failure(let failure):
            run(machine.handle(failure == .timedOut ? .timedOut : .refused(failure)))
        }
    }

    private func run(_ actions: [DropResolveAction]) {
        for action in actions {
            switch action {
            case .begin:
                guard let drag else { continue }
                resolver.resolve(drag) { [weak self] result in self?.resolved(result) }
            case .handOff:
                guard let resolved = pending else { continue }
                pending = nil
                folder = resolved.folder
                onFiles?(resolved.files, resolved.folder)
            case .refuse(let failure):
                cleanup()
                onRefuse?(failure)
            case .cancel:
                resolver.cancel()
                cleanup()
                onHide?()
            case .cleanup:
                cleanup()
            case .hide:
                onHide?()
            }
        }
    }

    private func cleanup() {
        DropScratch.remove(folder)
        folder = nil
    }
}

/// What a Deck drop does with the winning source (SHARE-8/11/17/18).
struct DeckDropActions: Equatable {
    var install: URL?
    var links: [URL] = []
    var files: [URL] = []
    var generated = false
    var download: URL?

    var isEmpty: Bool {
        install == nil && links.isEmpty && files.isEmpty && !generated && download == nil
    }
}

enum DeckDropRouter {
    static func actions(_ drag: DropDrag) -> DeckDropActions {
        var routed = DeckDropActions()
        switch DropSourceOrder.choose(drag) {
        case .files:
            for url in drag.files {
                if ApkBundle.kind(of: url) != nil {
                    if routed.install == nil { routed.install = url }
                } else if let link = OpenLinkRequest.webloc(at: url) {
                    if let url = URL(string: link) { routed.links.append(url) }
                } else {
                    routed.files.append(url)
                }
            }
        case .promises, .image:
            routed.generated = true
        case .remote:
            routed.download = drag.remote
        case .none:
            break
        }
        return routed
    }
}
