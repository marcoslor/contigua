// One thumbnail at a time per request, at most three in flight, each bounded by
// an 8 s deadline measured from the ask (docs/specs/files.md FILES-25/29,
// docs/design/files.md "Thumbnails (S6)").
//
// The queue is a small state machine per request: one closed set of phases, one
// pure transition, and the side effects (send, cancel, answer) run from the
// returned actions. Filled in by the next commit; the tests land first.

import Foundation

/// The bytes a thumbnail request answered with.
struct FilesThumb: Equatable, Hashable {
    var data: [UInt8]
    var mime: String
    var sha256: String
}

/// What one request ends with; the bridge turns this into its reply.
enum ThumbAnswer: Equatable, Hashable {
    case success(FilesThumb)
    case failure(code: String)
}

enum ThumbPhase: Equatable, Hashable {
    case queued, running, done, cancelled, expired
}

enum ThumbEvent: Equatable, Hashable {
    case slotFree
    case end(FilesThumb)
    case failure(code: String)
    case cancel
    case deadline
    /// The session went away or the extension client closed.
    case drop
}

enum ThumbAction: Equatable, Hashable {
    case sendRequest
    case sendCancel
    case answer(ThumbAnswer)
}

/// What the queue needs from the app's live session.
@MainActor
protocol FilesThumbHost: AnyObject {
    func thumb(item: String, size: Int,
               onStart: @escaping (UInt32) -> Void,
               completion: @escaping (Result<FilesThumb, FsError>) -> Void)
    func cancel(id: UInt32)
}

@MainActor
final class FilesThumbQueue {
    static let limit = 3

    func request(id: UInt32, client: ObjectIdentifier, item: String, size: Int,
                 deadline: TimeInterval, host: any FilesThumbHost,
                 answer: @escaping (ThumbAnswer) -> Void) {
        _ = (id, client, item, size, deadline, host, answer)
    }

    @discardableResult
    func cancel(id: UInt32, host: any FilesThumbHost) -> Bool { false }

    func cancel(client: ObjectIdentifier, host: any FilesThumbHost) {}

    func reset(host: (any FilesThumbHost)?) {}

    static func transition(_ phase: ThumbPhase,
                           _ event: ThumbEvent) -> (ThumbPhase, [ThumbAction]) {
        (phase, [])
    }
}

extension FilesThumbHost {
    /// A host with no thumbnail source answers `not_media` (the stub commit).
    func thumb(item: String, size: Int,
               onStart: @escaping (UInt32) -> Void,
               completion: @escaping (Result<FilesThumb, FsError>) -> Void) {
        completion(.failure(FsError(code: "not_media")))
    }
}
