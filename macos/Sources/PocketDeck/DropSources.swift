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
        .none
    }

    static func choose(_ drag: DropDrag) -> DropSourceChoice {
        .none
    }
}

/// One image representation from the pasteboard, as it came.
struct DropImage {
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
    var kind: String { "nothing" }
}

/// The real pasteboard receiver behind `NSFilePromiseReceiver`.
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
    static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes

    static func canRead(_ board: NSPasteboard) -> Bool { false }

    static func read(_ board: NSPasteboard) -> DropDrag? { nil }

    static func fileURLs(_ board: NSPasteboard) -> [URL] { [] }

    static func promises(_ board: NSPasteboard) -> [any DropPromiseSource] { [] }

    static func image(_ board: NSPasteboard) -> DropImage? { nil }

    static func remoteURL(_ board: NSPasteboard) -> URL? { nil }
}

/// The names D2 writes: Image.png/Image.jpg for bare image data, the URL's own
/// file name when it has one. DropName applies the phone's rules.
enum DropSourceName {
    static func image(mime: String) -> String {
        "Image.png"
    }

    static func downloaded(_ url: URL, mime: String, ext: String) -> String {
        "Image.\(ext)"
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

    mutating func handle(_ event: DropResolveEvent) -> [DropResolveAction] { [] }
}

/// The per-gesture temporary folder (D4). Deleted on a result, a cancel and a
/// session end; leftovers older than 24 h are swept at launch.
enum DropScratch {
    static let prefix = "PocketDeck-drop-"
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func makeFolder(in root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        throw CocoaError(.fileWriteUnknown)
    }

    static func sweep(in root: URL = FileManager.default.temporaryDirectory,
                      now: Date = Date(), maxAge: TimeInterval = maxAge) {}

    static func remove(_ folder: URL?) {}
}

/// Materialises the winning D1 source into a per-gesture folder.
@MainActor
final class DropSourceResolver {
    struct Resolved: Equatable {
        var files: [URL]
        var folder: URL?
    }

    init(root: URL = FileManager.default.temporaryDirectory,
         downloader: any DropDownloading = DropDownloader(),
         promiseWait: TimeInterval = 30) {}

    func resolve(_ drag: DropDrag,
                 completion: @escaping (Result<Resolved, DropResolveFailure>) -> Void) {
        completion(.failure(.failed))
    }

    func cancel() {}
}

/// Drives one drag's resolution: the machine above, the resolver's async work,
/// and the one folder the gesture owns.
@MainActor
final class DropSourceFlow {
    private(set) var machine = DropResolveMachine()

    var onFiles: (([URL], URL?) -> Void)?
    var onRefuse: ((DropResolveFailure) -> Void)?
    var onHide: (() -> Void)?

    init(root: URL = FileManager.default.temporaryDirectory, promiseWait: TimeInterval = 30) {}

    var phase: DropResolvePhase { machine.phase }
    var isReady: Bool { machine.phase == .ready }

    func start(_ drag: DropDrag) {}
    func sessionEnded() {}
    func cancelled() {}
    func settled() {}
    func dismissed() {}
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
        DeckDropActions()
    }
}
