// The reconnect resync (docs/design/files.md § Sync integrity, slice 3;
// FILES-33): when the session becomes ready the host asks the phone for one
// `fs.digest` over the folders in the record, most recently touched first and
// at most 64. Only the folders whose digest differs from the recorded one (or
// that have no digest yet) are re-listed; a folder the phone says is gone is
// reported deleted with everything the record holds under it, and a phone
// without `fs.digest` lists them all as before.
//
// One explicit machine, no flags: idle → digesting → relisting → done. A
// session drop returns to idle, and the next ready starts over from the record
// as it then is. Pure transitions: the host runs the returned actions.

import Foundation

struct FilesResync: Equatable {
    /// One folder to check: the record's identifier, the phone's path, and the
    /// digest its last complete listing stored (nil until one has).
    struct Folder: Equatable {
        var id: String
        var path: String
        var recorded: String?
    }

    /// One folder's answer from the digest reply. A path the reply does not
    /// name is `nil`, which is compared by a listing (the safe direction).
    struct Answer: Equatable {
        var folder: Folder
        var digest: FsDigestReply?
    }

    enum State: Equatable {
        case idle
        /// The one `fs.digest` is in flight for these folders.
        case digesting([Folder])
        /// These folders still have a listing to finish.
        case relisting(Set<String>)
        case done
    }

    enum Event: Equatable {
        case ready([Folder])
        case digests([Answer])
        /// No usable answer: `fs_unknown`, or the request failed.
        case unknown
        case listed(String)
        case dropped
    }

    enum Action: Equatable {
        /// One `fs.digest` for these paths.
        case ask([String])
        /// Report the deletions, then list the folders.
        case apply(deletions: [String], relist: [String])
        case finished
        case none
    }

    /// The watch cap: a reconnect asks the phone for at most 64 folders, the
    /// same number the Mac keeps watched (FILES-36).
    static let folderLimit = 64

    private(set) var state: State = .idle

    mutating func apply(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .ready(let folders)):
            guard !folders.isEmpty else {
                state = .done
                return .finished
            }
            state = .digesting(folders)
            return .ask(folders.map(\.path))
        case (.digesting, .digests(let answers)):
            var deletions: [String] = []
            var relist: Set<String> = []
            for answer in answers {
                guard let reply = answer.digest else {
                    // The reply did not name this path: compare by listing.
                    relist.insert(answer.folder.id)
                    continue
                }
                switch reply {
                case .digest(let value):
                    if answer.folder.recorded != value {
                        relist.insert(answer.folder.id)
                    }
                case .notFound:
                    // The root is never reported deleted: a phone whose storage
                    // is not mounted yet answers not_found, and emptying Finder
                    // is worse than a stale folder. A listing then repairs it.
                    if answer.folder.id == FilesMap.rootIdentifier {
                        relist.insert(answer.folder.id)
                    } else {
                        // The host reports the folder and everything the record
                        // holds under it as one delta (it owns the record).
                        deletions.append(answer.folder.id)
                    }
                }
            }
            state = relist.isEmpty ? .done : .relisting(relist)
            if relist.isEmpty && deletions.isEmpty {
                return .finished
            }
            return .apply(deletions: deletions, relist: Array(relist))
        case (.digesting(let folders), .unknown):
            // No digest from this phone: list every recorded folder as today.
            state = .relisting(Set(folders.map(\.id)))
            return .apply(deletions: [], relist: folders.map(\.id))
        case (.relisting(var remaining), .listed(let id)):
            remaining.remove(id)
            state = remaining.isEmpty ? .done : .relisting(remaining)
            return remaining.isEmpty ? .finished : .none
        case (_, .dropped):
            state = .idle
            return .none
        case (.idle, .digests), (.idle, .unknown), (.idle, .listed),
             (.done, .ready), (.done, .digests), (.done, .unknown), (.done, .listed),
             (.digesting, .ready), (.digesting, .listed),
             (.relisting, .ready), (.relisting, .digests), (.relisting, .unknown):
            // A duplicate, or an event from a run the drop already ended.
            return .none
        }
    }
}

extension FilesResync.State {
    /// The log's closed-set code: 0 idle, 1 digesting, 2 relisting, 3 done.
    var code: Int {
        switch self {
        case .idle: return 0
        case .digesting: return 1
        case .relisting: return 2
        case .done: return 3
        }
    }
}

extension FilesResync.Event {
    /// The log's closed-set code: 0 ready, 1 digests, 2 unknown, 3 listed, 4 dropped.
    var code: Int {
        switch self {
        case .ready: return 0
        case .digests: return 1
        case .unknown: return 2
        case .listed: return 3
        case .dropped: return 4
        }
    }
}
