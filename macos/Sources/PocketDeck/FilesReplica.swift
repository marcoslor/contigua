// The app's belief about the system's replica of the phone's files, and the
// change log that goes with it (docs/design/files.md § Sync integrity, ISS-37):
// per folder identifier, the children the system was last told it holds, the
// last-touch time and (for the digest slice) the phone's digest; plus the one
// domain-wide delta log and its epoch, so an app restart no longer expires the
// system's anchor (FILES-32).
//
// A pure value beside the id map: the app writes both in the same coalesced
// save. A file from another format is a fresh record, like the id map's.

import Foundation

/// One folder's replica record.
struct FilesFolderRecord: Equatable {
    /// The children as last reported to the system, by identifier.
    var children: [String: FileItem] = [:]
    /// When the system last touched the folder (the resync order, slice 3).
    var touched: TimeInterval = 0
    /// The phone's digest of the folder at this report (slice 3); nil until the
    /// phone carries `fs.digest`. Stored now so the format does not change.
    var digest: String?
}

/// The whole persisted replica: every folder's record and the change log.
struct FilesReplica: Equatable {
    /// The record shares the id map's format version: only the current shape is
    /// read, so a change to either shape means a fresh record.
    static let formatVersion = FilesIdMap.formatVersion

    var folders: [String: FilesFolderRecord] = [:]
    var log: FilesChangeLog

    init(log: FilesChangeLog = FilesChangeLog()) {
        self.log = log
    }

    // MARK: Persistence

    /// The persisted JSON. Names are in it (a `FileItem` carries one), so it is
    /// 0600 like the id map and never logged.
    func encoded() -> Data {
        var foldersJSON: [String: Any] = [:]
        for (identifier, record) in folders {
            var object: [String: Any] = [
                "t": record.touched,
                "children": record.children.values
                    .sorted { $0.identifier < $1.identifier }
                    .map(\.jsonObject)
            ]
            if let digest = record.digest { object["d"] = digest }
            foldersJSON[identifier] = object
        }
        let logJSON: [String: Any] = [
            "epoch": log.epoch,
            "sequence": log.sequence,
            "entries": log.entries.map { entry in
                [
                    "s": entry.sequence,
                    "c": entry.container,
                    "items": entry.delta.items.map(\.jsonObject),
                    "deleted": entry.delta.deleted
                ] as [String: Any]
            }
        ]
        let root: [String: Any] = ["version": Self.formatVersion,
                                   "folders": foldersJSON,
                                   "log": logJSON]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
            ?? Data()
    }

    static func decode(_ data: Data) -> FilesReplica? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = (object["version"] as? NSNumber)?.intValue,
              version == formatVersion,
              let foldersJSON = object["folders"] as? [String: [String: Any]],
              let logJSON = object["log"] as? [String: Any],
              let epoch = logJSON["epoch"] as? String,
              let sequence = (logJSON["sequence"] as? NSNumber)?.intValue,
              let entriesJSON = logJSON["entries"] as? [[String: Any]] else { return nil }

        var entries: [FilesChangeLog.Entry] = []
        for entry in entriesJSON {
            guard let named = (entry["s"] as? NSNumber)?.intValue,
                  let container = entry["c"] as? String,
                  let itemsJSON = entry["items"] as? [[String: Any]],
                  let deleted = entry["deleted"] as? [String] else { return nil }
            var items: [FileItem] = []
            for itemJSON in itemsJSON {
                guard let item = FileItem(json: itemJSON) else { return nil }
                items.append(item)
            }
            entries.append(FilesChangeLog.Entry(sequence: named, container: container,
                                                delta: FilesDelta(items: items,
                                                                  deleted: deleted)))
        }
        guard let log = FilesChangeLog(epoch: epoch, sequence: sequence, entries: entries)
        else { return nil }

        var folders: [String: FilesFolderRecord] = [:]
        for (identifier, folderJSON) in foldersJSON {
            guard let touched = (folderJSON["t"] as? NSNumber)?.doubleValue,
                  let childrenJSON = folderJSON["children"] as? [[String: Any]] else {
                return nil
            }
            var children: [String: FileItem] = [:]
            for childJSON in childrenJSON {
                guard let item = FileItem(json: childJSON) else { return nil }
                children[item.identifier] = item
            }
            let digest = folderJSON["d"] as? String
            folders[identifier] = FilesFolderRecord(children: children, touched: touched,
                                                    digest: digest)
        }
        return FilesReplica(log: log, folders: folders)
    }

    init(log: FilesChangeLog, folders: [String: FilesFolderRecord]) {
        self.log = log
        self.folders = folders
    }

    static func load(_ url: URL) -> FilesReplica {
        guard let data = try? Data(contentsOf: url), let replica = decode(data) else {
            return FilesReplica()
        }
        return replica
    }

    static func save(_ replica: FilesReplica, to url: URL) {
        FilesPrivateStore.write(replica.encoded(), to: url)
    }
}
