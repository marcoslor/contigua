// Which items get a thumbnail request, and what a failure means to Finder
// (docs/specs/files.md FILES-22, FILES-26; docs/design/files.md "Thumbnails
// (S6)", R-1). Shared with the extension by bundle.sh; filled in by the next
// commit, the tests land first.

import Foundation

enum FilesThumbPolicy {
    /// The most thumbnails in flight for one session (FILES-25).
    static let inFlightLimit = 3

    /// True only for a type conforming to an image or a movie (FILES-22).
    static func isMedia(contentTypeIdentifier: String) -> Bool { false }

    /// The policy for a mapped path (the app decides before any phone traffic).
    static func pathIsMedia(_ path: String) -> Bool { false }

    /// R-1: a lost thumbnail may be asked for again; a missing one may not.
    static func isTransient(code: String) -> Bool { false }

    /// The per-thumbnail handler's error: serverUnreachable for a transient
    /// failure, nil data otherwise.
    static func error(for code: String) -> Error? { nil }
}
