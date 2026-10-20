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
