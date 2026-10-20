// Remote changes for the Finder domain (docs/design/files.md §5, slice S5):
// what a re-listing of one folder shows against the listing the system was last
// given, and the anchor log that answers `enumerateChanges(for:from:)`.
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

/// What the app answers a `changes` request with (one container).
struct FilesChangesReply: Equatable {
    var anchor: String
    var delta: FilesDelta
    var expired: Bool
}

/// One container's deltas, newest last, each tied to the anchor it produced.
/// Bounded: an anchor older than the kept history cannot be replayed, and the
/// caller answers `.syncAnchorExpired` so the system re-enumerates.
struct FilesChangeLog: Equatable {
    /// Enough for a Finder that has been idle through a burst of changes; the
    /// system re-enumerates past this.
    static let maxEntries = 32

    struct Entry: Equatable {
        var generation: Int
        var delta: FilesDelta
    }

    /// The container this log belongs to. It rides in the anchor so an anchor
    /// from another folder (or another process's stale idea of this one) cannot
    /// be mistaken for a position in this history.
    let scope: String
    private(set) var generation = 0
    private(set) var entries: [Entry] = []

    init(scope: String) {
        self.scope = scope
    }

    /// The anchor a container reports right now.
    var anchor: String { Self.anchor(generation, scope: scope) }

    static func anchor(_ generation: Int, scope: String) -> String {
        "g\(generation).\(scope)"
    }

    /// The generation an anchor names, or nil when it is not this log's.
    func generation(of anchor: String) -> Int? {
        let suffix = "." + scope
        guard anchor.hasPrefix("g"), anchor.hasSuffix(suffix) else { return nil }
        let number = anchor.dropFirst().dropLast(suffix.count)
        guard let value = Int(number), value >= 0 else { return nil }
        return value
    }

    /// Records what a re-listing changed. Returns true when the container moved
    /// (an empty delta still advances nothing).
    @discardableResult
    mutating func record(_ delta: FilesDelta) -> Bool {
        guard !delta.isEmpty else { return false }
        generation += 1
        entries.append(Entry(generation: generation, delta: delta))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        return true
    }

    /// Everything after [anchor], merged in order; nil when the anchor is
    /// unknown here or older than the kept entries.
    func changes(from anchor: String) -> FilesDelta? {
        guard let from = generation(of: anchor), from <= generation else { return nil }
        if from == generation { return FilesDelta.none }
        let oldest = entries.first?.generation ?? (generation + 1)
        if from + 1 < oldest { return nil }

        var order: [String] = []
        var byID: [String: FileItem] = [:]
        var deleted: [String] = []
        for entry in entries where entry.generation > from {
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
