// Which items get a thumbnail request, and what a failure means to Finder
// (docs/specs/files.md FILES-22, FILES-26; docs/design/files.md "Thumbnails
// (S6)"). Shared with the extension by bundle.sh: the app decides from the
// mapped path, and the extension turns a failure into R-1's answer.

import FileProvider
import Foundation
import UniformTypeIdentifiers

enum FilesThumbPolicy {
    /// The most thumbnails in flight for one session (FILES-25).
    static let inFlightLimit = 3
    /// The phone's whole answer is at most 256 KiB (PROTOCOL.md "Thumbnails").
    static let maxBytes = 256 * 1024
    /// The wire's own bound for the wanted long side.
    static let maxLongSide = 4096
    /// How long the extension's thumbnail connection waits for one answer
    /// (FILES-29). A queued ask waits for its turn, and the app's queue runs
    /// three at a time against a phone that generates one at a time, so this
    /// must outlive the queue: 120 s is about 170 photos at 0.7 s each — a
    /// full Finder icon grid — while still bounding a bridge that died.
    static let bridgeReadTimeout = 120

    /// True only for a type conforming to an image or a movie (FILES-22).
    static func isMedia(contentTypeIdentifier: String) -> Bool {
        guard let type = UTType(contentTypeIdentifier) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// The policy for a mapped path, decided with no phone traffic: a name the
    /// system would draw a type icon for is answered at once.
    static func pathIsMedia(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let type = FilesMap.contentTypeIdentifier(name: name, isDirectory: false)
        return isMedia(contentTypeIdentifier: type)
    }

    /// R-1: the answers worth asking again for. The system may remember a nil
    /// answer as "this version has no thumbnail", so only a lost request may be
    /// retried; a timeout, a disconnected phone or a busy phone are lost.
    static func isTransient(code: String) -> Bool {
        switch code {
        case "offline", "closed", "timeout", "fs_busy", "busy":
            return true
        default:
            return false
        }
    }

    /// The per-thumbnail handler's error: serverUnreachable for a transient
    /// failure, which costs nothing to ask again; nil data otherwise.
    static func error(for code: String) -> Error? {
        isTransient(code: code) ? NSFileProviderError(.serverUnreachable) : nil
    }
}
