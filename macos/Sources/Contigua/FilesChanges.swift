// Remote changes for the Finder domain (docs/design/files.md §5, slice S5):
// what a re-listing of one folder shows against the listing the system was last
// given, and the one ordered log that answers both a folder's
// `enumerateChanges(for:from:)` and the working set's (round 3).
//
// Pure values, no FileProvider: the app records the deltas and the extension
// wraps them in NSFileProvider types.

import Foundation

/// One re-listing's difference: items that appeared or moved on, and the
/// identifiers that are gone.
struct FilesDelta: Equatable {
    var items: [FileItem]
    var deleted: [String]

    static let none = FilesDelta(items: [], deleted: [])

    var isEmpty: Bool { items.isEmpty && deleted.isEmpty }
}

enum FilesDiff {
    /// What [new] changed against the items the system was last shown, keyed by
    /// identifier. An item whose metadata moved is an update; the same inode
    /// under a new name is an update too, because the identifier is the ino
    /// (design §3). Anything the new listing does not carry is deleted.
    static func delta(old: [String: FileItem], new: [FileItem]) -> FilesDelta {
        var items: [FileItem] = []
        var seen = Set<String>()
        for item in new {
            seen.insert(item.identifier)
            if let before = old[item.identifier], before == item { continue }
            items.append(item)
        }
        let deleted = old.keys.filter { !seen.contains($0) }
        return FilesDelta(items: items, deleted: deleted)
    }
}

/// One folder's listing walk and its one confirmation re-list (FILES-31). A
/// complete walk reports its delta; a walk that would delete more than half of
/// the recorded items and more than 20 is repeated once after a delay, and only
/// the deletions both walks agree on go out. The transition is pure; the host
/// runs the delay and writes the record from the returned action.
struct FilesWalk: Equatable {
    enum State: Equatable {
        /// The first page walk is running.
        case listing
        /// The first walk was too destructive: a confirmation re-list runs.
        case confirming(deletions: Set<String>)
        case done
    }

    enum Event: Equatable {
        /// The page walk reached its last page.
        case finished(delta: FilesDelta, listing: [FileItem])
        /// The page walk ended early (an error or a cancel).
        case failed(delta: FilesDelta, listing: [FileItem])
        /// The confirmation re-list reached its last page.
        case confirmed(delta: FilesDelta, listing: [FileItem])
        /// The confirmation re-list ended early.
        case confirmFailed(delta: FilesDelta, listing: [FileItem])
    }

    enum Action: Equatable {
        case report(FilesDelta, listing: [FileItem])
        /// Re-list once after the host's delay; only then may a deletion go out.
        case confirm
        case none
    }

    /// More than 20 AND more than half of the recorded items: the person's
    /// 459-of-568 case passes, a phone whose storage is not mounted yet does not
    /// empty Finder.
    static let deletionFloor = 20

    private(set) var state: State = .listing
    /// How many items the folder's record held when the walk began.
    let recorded: Int

    init(recorded: Int) {
        self.recorded = recorded
    }

    var isConfirming: Bool {
        if case .confirming = state { return true }
        return false
    }

    mutating func apply(_ event: Event) -> Action {
        switch (state, event) {
        case (.listing, .finished(let delta, let listing)):
            let deletions = Set(delta.deleted)
            if deletions.count > Self.deletionFloor, deletions.count * 2 > recorded {
                state = .confirming(deletions: deletions)
                return .confirm
            }
            state = .done
            return .report(delta, listing: listing)
        case (.listing, .failed(let delta, let listing)):
            // An incomplete walk reports additions and changes only.
            state = .done
            return .report(FilesDelta(items: delta.items, deleted: []), listing: listing)
        case (.confirming(let first), .confirmed(let delta, let listing)):
            state = .done
            return .report(FilesDelta(items: delta.items,
                                      deleted: delta.deleted.filter(first.contains)),
                           listing: listing)
        case (.confirming, .confirmFailed(let delta, let listing)):
            state = .done
            return .report(FilesDelta(items: delta.items, deleted: []), listing: listing)
        case (.done, _):
            return .none
        case (.listing, .confirmed), (.listing, .confirmFailed),
             (.confirming, .finished), (.confirming, .failed):
            // An event from a walk this machine did not start: ignore it.
            return .none
        }
    }
}

extension FilesWalk.State {
    /// The log's closed-set code: 0 listing, 1 confirming, 2 done.
    var code: Int {
        switch self {
        case .listing: return 0
        case .confirming: return 1
        case .done: return 2
        }
    }
}

extension FilesWalk.Event {
    /// The log's closed-set code: 0 finished, 1 failed, 2 confirmed, 3 confirmFailed.
    var code: Int {
        switch self {
        case .finished: return 0
        case .failed: return 1
        case .confirmed: return 2
        case .confirmFailed: return 3
        }
    }
}

/// What the app answers a `changes` request with (one container, or the working
/// set when the container is nil).
struct FilesChangesReply: Equatable {
    var anchor: String
    var delta: FilesDelta
    var expired: Bool
}

/// The domain's deltas, newest last, each tied to the sequence it produced and
/// the container it happened in. One log for the whole domain: the working set
/// replays all of it, a folder enumerator replays its own entries, and an anchor
/// older than the kept history cannot be replayed, so the caller answers
/// `.syncAnchorExpired` and the system re-enumerates (design "S5 round 3").
struct FilesChangeLog: Equatable {
    /// Enough for a Finder that has been idle through a burst of changes; the
    /// system re-enumerates past this. The cap is domain-wide, not per folder.
    static let maxEntries = 512

    struct Entry: Equatable {
        var sequence: Int
        var container: String
        var delta: FilesDelta
    }

    /// A fresh epoch per app run. An anchor from an earlier process names a
    /// sequence in a log this process no longer has, so it must expire instead
    /// of replaying an empty delta against unrelated history.
    let epoch: String
    private(set) var sequence = 0
    private(set) var entries: [Entry] = []

    init(epoch: String = FilesChangeLog.newEpoch()) {
        self.epoch = epoch
    }

    /// A log restored from disk (FILES-32): the epoch and sequence continue, so
    /// an anchor the system was given before the app stopped still answers. A
    /// log whose entries do not fit its sequence is not one this app wrote.
    init?(epoch: String, sequence: Int, entries: [Entry]) {
        guard !epoch.isEmpty, sequence >= 0, entries.count <= Self.maxEntries else {
            return nil
        }
        var last = 0
        for entry in entries {
            guard entry.sequence > last, entry.sequence <= sequence else { return nil }
            last = entry.sequence
        }
        self.epoch = epoch
        self.sequence = sequence
        self.entries = entries
    }

    static func newEpoch() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// The anchor the working set reports right now.
    var anchor: String { Self.anchor(sequence, epoch: epoch) }

    static func anchor(_ sequence: Int, epoch: String) -> String {
        "w:\(epoch):\(sequence)"
    }

    /// A folder enumerator's anchor: the same sequence, plus the folder that
    /// owns it, so an anchor from another container cannot be mistaken for a
    /// position in this one.
    func containerAnchor(_ container: String) -> String {
        Self.containerAnchor(sequence, container: container, epoch: epoch)
    }

    static func containerAnchor(_ sequence: Int, container: String,
                                epoch: String) -> String {
        "g:\(epoch):\(sequence):\(container)"
    }

    /// The sequence an anchor names. A working-set anchor (`container == nil`)
    /// must be `w:<epoch>:<sequence>`; a folder anchor must be
    /// `g:<epoch>:<sequence>:<that folder>`.
    func sequence(of anchor: String, container: String?) -> Int? {
        let prefix = container == nil ? "w:" : "g:"
        guard anchor.hasPrefix(prefix) else { return nil }
        let rest = anchor.dropFirst(prefix.count)
        let pieces = rest.split(separator: ":", maxSplits: container == nil ? 1 : 2,
                                omittingEmptySubsequences: false)
        guard let namedEpoch = pieces.first, namedEpoch == epoch else { return nil }
        guard pieces.count == (container == nil ? 2 : 3) else { return nil }
        if let container, pieces[2] != Substring(container) { return nil }
        guard let value = Int(pieces[1]), value >= 0 else { return nil }
        return value
    }

    /// Records what a re-listing changed in one container. Returns true when the
    /// log moved (an empty delta still advances nothing).
    @discardableResult
    mutating func record(container: String, delta: FilesDelta) -> Bool {
        guard !delta.isEmpty else { return false }
        sequence += 1
        entries.append(Entry(sequence: sequence, container: container, delta: delta))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        return true
    }

    /// Everything after [anchor], merged in order and filtered to [container]
    /// when one is given (nil = the whole domain, for the working set). A nil
    /// anchor is a first enumeration: every delta the log still keeps, which the
    /// caller combines with its cached listings. Nil return = the anchor cannot
    /// be replayed here.
    func changes(from anchor: String?, container: String?) -> FilesDelta? {
        var from = 0
        if let anchor {
            guard let named = sequence(of: anchor, container: container) else { return nil }
            guard named <= sequence else { return nil }
            if named == sequence { return FilesDelta.none }
            let oldest = entries.first?.sequence ?? (sequence + 1)
            guard named + 1 >= oldest else { return nil }
            from = named
        }

        var order: [String] = []
        var byID: [String: FileItem] = [:]
        var deleted: [String] = []
        for entry in entries where entry.sequence > from {
            if let container, entry.container != container { continue }
            for identifier in entry.delta.deleted {
                byID.removeValue(forKey: identifier)
                deleted.removeAll { $0 == identifier }
                deleted.append(identifier)
            }
            for item in entry.delta.items {
                if byID[item.identifier] == nil {
                    order.append(item.identifier)
                }
                byID[item.identifier] = item
                deleted.removeAll { $0 == item.identifier }
            }
        }
        let items = order.compactMap { byID[$0] }
        return FilesDelta(items: items, deleted: deleted)
    }
}
