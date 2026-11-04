// The replica record in the bridge host (docs/design/files.md § Sync
// integrity, FILES-31/32/34): the first listing after a restart diffs against
// the record from the earlier run, the guards keep a listing from deleting a
// file that is not gone, a big deletion is confirmed once, and a phone
// `fs_not_found` repairs the record and re-lists the parent.
//
// The phone is a fake FsChannel: the real FsClient and the real
// SessionBridgeHost run; only the wire is answered by the test.

import Foundation
import XCTest
@testable import PocketDeck

private final class ReplicaChannel: FsChannel {
    private let lock = NSLock()
    private(set) var lists: [(id: UInt32, path: String, page: String?)] = []
    private(set) var stats: [(id: UInt32, path: String)] = []
    private(set) var thumbs: [(id: UInt32, path: String, size: Int, etag: String?)] = []
    private(set) var reads: [(id: UInt32, path: String, offset: Int, length: Int)] = []
    private(set) var writes: [(id: UInt32, path: String, size: Int, sha256: String,
                                etag: String?, exclusive: Bool)] = []
    private(set) var moves: [(id: UInt32, from: String, to: String)] = []
    private(set) var deletes: [(id: UInt32, path: String, recursive: Bool)] = []
    private(set) var mkdirs: [(id: UInt32, path: String)] = []
    private(set) var setAttrs: [(id: UInt32, path: String, mtime: Int)] = []
    private(set) var watches: [(id: UInt32, paths: [String], on: Bool)] = []
    private(set) var cancels: [UInt32] = []

    func fsList(id: UInt32, path: String, page: String?) {
        lock.lock(); defer { lock.unlock() }
        lists.append((id, path, page))
    }

    func fsStat(id: UInt32, path: String) {
        lock.lock(); defer { lock.unlock() }
        stats.append((id, path))
    }

    func fsRead(id: UInt32, path: String, offset: Int, length: Int, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        reads.append((id, path, offset, length))
    }

    func fsThumb(id: UInt32, path: String, size: Int, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        thumbs.append((id, path, size, etag))
    }

    func fsWrite(id: UInt32, path: String, size: Int, sha256: String, etag: String?,
                 exclusive: Bool) {
        lock.lock(); defer { lock.unlock() }
        writes.append((id, path, size, sha256, etag, exclusive))
    }

    func fsWriteData(id: UInt32, bytes: [UInt8], sent: @escaping @Sendable (Bool) -> Void) {
        sent(true)
    }

    func fsMove(id: UInt32, from: String, to: String, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        moves.append((id, from, to))
    }

    func fsDelete(id: UInt32, path: String, recursive: Bool, etag: String?) {
        lock.lock(); defer { lock.unlock() }
        deletes.append((id, path, recursive))
    }

    func fsMkdir(id: UInt32, path: String) {
        lock.lock(); defer { lock.unlock() }
        mkdirs.append((id, path))
    }

    func fsSetAttrs(id: UInt32, path: String, mtime: Int) {
        lock.lock(); defer { lock.unlock() }
        setAttrs.append((id, path, mtime))
    }

    func fsWatch(id: UInt32, paths: [String], on: Bool) {
        lock.lock(); defer { lock.unlock() }
        watches.append((id, paths, on))
    }

    func fsCancel(id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        cancels.append(id)
    }
}

@MainActor
private final class Signals {
    private(set) var calls: [[String]] = []
    var count: Int { calls.count }
    func record(_ containers: [String]) { calls.append(containers) }
}

@MainActor
final class FilesSyncTests: XCTestCase {
    private var directory: URL!
    private var channel: ReplicaChannel!
    private var client: FsClient!

    private var root: String { FilesMap.rootIdentifier }
    private var mapURL: URL { directory.appendingPathComponent("files-ids.json") }
    private var replicaURL: URL { directory.appendingPathComponent("files-replica.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketdeck-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        channel = ReplicaChannel()
        client = FsClient(channel: channel)
    }

    override func tearDown() async throws {
        client.cancelAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func fs(_ name: String, ino: Int, dir: Bool = false, size: Int = 4,
                    mtime: Int = 5, etag: String = "aa") -> FsItem {
        FsItem(name: name, dir: dir, size: size, mtime: mtime, ino: ino, etag: etag)
    }

    private func item(_ name: String, ino: Int, parent: String = FilesMap.rootIdentifier) -> FileItem {
        FilesMap.item(path: name, parentIdentifier: parent, fs: fs(name, ino: ino))
    }

    private func byID(_ items: [FileItem]) -> [String: FileItem] {
        var result: [String: FileItem] = [:]
        for item in items { result[item.identifier] = item }
        return result
    }

    /// The record and log an earlier app run left in the profile folder.
    private func saveEarlierRun(_ items: [FileItem], container: String = FilesMap.rootIdentifier,
                                logged: FileItem? = nil) -> String {
        var replica = FilesReplica()
        replica.folders[container] = FilesFolderRecord(children: byID(items), touched: 1)
        if let logged {
            replica.log.record(container: container,
                               delta: FilesDelta(items: [logged], deleted: []))
        }
        FilesReplica.save(replica, to: replicaURL)
        return replica.log.anchor
    }

    private func makeHost(_ signals: Signals) -> SessionBridgeHost {
        SessionBridgeHost(client: client, name: "Test Phone", mapURL: mapURL,
                          signal: { signals.record($0) })
    }

    private func answerList(_ items: [FsItem], next: String? = nil) {
        let request = channel.lists.last!
        client.items(id: request.id, page: next, items: items.map(\.jsonObject))
    }

    private func answerStat(_ fs: FsItem) {
        client.item(id: channel.stats.last!.id, item: fs.jsonObject)
    }

    // MARK: The first listing

    func testTheFirstListingDiffsTheRecordFromAnEarlierRun() throws {
        let fiveFS = (6...10).map { fs("f\($0).txt", ino: $0) }
        let five = fiveFS.map { FilesMap.item(path: $0.name, parentIdentifier: root, fs: $0) }
        let anchor = saveEarlierRun(five, logged: five[0])

        let signals = Signals()
        let host = makeHost(signals)
        var listed: Result<(items: [FileItem], next: String?), FsError>?
        host.list(item: root, page: nil) { listed = $0 }
        // Two of five gone and one added on the phone while the app was off.
        answerList([fiveFS[0], fiveFS[1], fiveFS[3], fs("added.txt", ino: 11, size: 9)])

        XCTAssertEqual(try listed?.get().items.count, 4)
        XCTAssertEqual(signals.count, 1, "one signal for the one listing")
        XCTAssertEqual(signals.calls.first, [root])
        let replay = try XCTUnwrap(host.replica.log.changes(from: anchor, container: nil))
        XCTAssertEqual(Set(replay.deleted), [five[2].identifier, five[4].identifier])
        XCTAssertEqual(replay.items.map(\.name), ["added.txt"])
        XCTAssertEqual(host.replica.folders[root]?.children.count, 4)
    }

    func testAnIncompleteWalkReportsAdditionsAndChangesOnly() throws {
        let fiveFS = (6...10).map { fs("f\($0).txt", ino: $0) }
        let five = fiveFS.map { FilesMap.item(path: $0.name, parentIdentifier: root, fs: $0) }
        let anchor = saveEarlierRun(five)

        let host = makeHost(Signals())
        host.list(item: root, page: nil) { _ in }
        answerList([fiveFS[0], fiveFS[1], fs("new.txt", ino: 20, size: 1, etag: "cc")],
                   next: "p2")
        // The system asks the second page, and it fails: the walk saw three of
        // five items and knows nothing about the two it did not see.
        host.list(item: root, page: "p2") { _ in }
        client.failure(id: channel.lists.last!.id, code: "io", message: nil)

        let replay = try XCTUnwrap(host.replica.log.changes(from: anchor, container: nil))
        XCTAssertEqual(replay.deleted, [])
        XCTAssertEqual(replay.items.map(\.name), ["new.txt"])
        XCTAssertEqual(host.replica.folders[root]?.children.count, 6,
                       "the record keeps the items the failed walk never saw")
    }

    /// A restart's first visit to a folder: the system touches it (Finder shows
    /// it), and nothing else may be needed for what changed on the phone while
    /// the app was off to reach the system (design § Sync integrity, slice 1).
    func testTheFirstTouchAfterARestartListsTheFolderAndReportsTheChanges() throws {
        let fiveFS = (6...10).map { fs("f\($0).txt", ino: $0) }
        let five = fiveFS.map { FilesMap.item(path: $0.name, parentIdentifier: root, fs: $0) }
        let anchor = saveEarlierRun(five)

        let signals = Signals()
        let host = makeHost(signals)
        host.touch(item: root) { _ in }
        guard channel.lists.count == 1 else {
            return XCTFail("the first touch lists the folder once (lists=\(channel.lists.count))")
        }
        answerList([fiveFS[0], fiveFS[1], fiveFS[3]])

        let replay = try XCTUnwrap(host.replica.log.changes(from: anchor, container: nil))
        XCTAssertEqual(Set(replay.deleted), [five[2].identifier, five[4].identifier])
        XCTAssertEqual(signals.count, 1)

        host.touch(item: root) { _ in }
        XCTAssertEqual(channel.lists.count, 1, "a second touch in this process lists nothing")
    }

    /// A Mac move to another folder: the system already knows the item's new
    /// parent. Identifiers are domain-wide, so a deletion logged for the old
    /// folder would delete the moved item itself on the next replay.
    func testAMoveToAnotherFolderNeverLogsTheItemDeleted() throws {
        let photo = item("photo.jpg", ino: 6)
        let folderFS = fs("D", ino: 7, dir: true)
        let folder = FilesMap.item(path: "D", parentIdentifier: root, fs: folderFS)
        let anchor = saveEarlierRun([photo, folder])
        var map = FilesIdMap()
        map.remember(identifier: "ino:6", path: "photo.jpg", parentIdentifier: root)
        map.remember(identifier: "ino:7", path: "D", parentIdentifier: root)
        FilesIdMap.save(map, to: mapURL)

        let host = makeHost(Signals())
        var moved: Result<FileItem, FsError>?
        host.modify(BridgeModify(item: "ino:6", base: "aa", content: false, name: nil,
                                 parent: "ino:7", mtime: nil, size: 0, sha256: nil),
                    ready: { _ in },
                    completion: { moved = $0 })
        // The source and the target folder are checked on the phone first.
        var answered = 0
        while channel.moves.isEmpty, channel.stats.count > answered, answered < 4 {
            let request = channel.stats[answered]
            answered += 1
            client.item(id: request.id,
                        item: (request.path == "D" ? folderFS : fs("photo.jpg", ino: 6)).jsonObject)
        }
        let request = try XCTUnwrap(channel.moves.last, "the move reached the phone")
        XCTAssertEqual(request.to, "D/photo.jpg")
        client.result(id: request.id, ok: true, item: fs("photo.jpg", ino: 6).jsonObject,
                      code: nil, message: nil)

        XCTAssertEqual(try moved?.get().parentIdentifier, "ino:7")
        let replay = try XCTUnwrap(host.replica.log.changes(from: anchor, container: nil))
        XCTAssertFalse(replay.deleted.contains("ino:6"),
                       "the moved item is not reported deleted")
        XCTAssertNil(host.replica.folders[root]?.children["ino:6"])
        XCTAssertEqual(host.replica.folders["ino:7"]?.children["ino:6"]?.name, "photo.jpg")
    }

    // MARK: Guards

    func testAnItemWithAnUploadInFlightIsNotDeleted() throws {
        let fiveFS = (6...10).map { fs("f\($0).txt", ino: $0) }
        let five = fiveFS.map { FilesMap.item(path: $0.name, parentIdentifier: root, fs: $0) }
        saveEarlierRun(five)
        var map = FilesIdMap()
        map.remember(identifier: "ino:6", path: "f6.txt", parentIdentifier: root)
        FilesIdMap.save(map, to: mapURL)

        let signals = Signals()
        let host = makeHost(signals)
        var sink: FilesWriteSink?
        var finished: Result<FileItem, FsError>?
        host.modify(BridgeModify(item: "ino:6", base: "aa", content: true, name: nil,
                                 parent: nil, mtime: nil, size: 4,
                                 sha256: String(repeating: "a", count: 64)),
                    ready: { sink = $0 },
                    completion: { finished = $0 })
        answerStat(fs("f6.txt", ino: 6))
        XCTAssertNotNil(sink)
        XCTAssertEqual(channel.writes.count, 1)

        host.list(item: root, page: nil) { _ in }
        answerList(fiveFS.filter { $0.ino != 6 })

        let replay = try XCTUnwrap(host.replica.log.changes(from: nil, container: nil))
        XCTAssertEqual(replay.deleted, [], "the in-flight upload is not a deletion")
        XCTAssertEqual(host.replica.folders[root]?.children["ino:6"]?.name, "f6.txt")
        XCTAssertEqual(signals.count, 0)

        // Finish the upload so nothing is left pending.
        client.result(id: channel.writes.last!.id, ok: false, item: nil,
                      code: "io", message: nil)
        XCTAssertEqual(finished?.failure?.code, "io")
    }

    func testAnItemReportedDuringTheWalkIsNotDeleted() throws {
        let fiveFS = (6...10).map { fs("f\($0).txt", ino: $0) }
        let five = fiveFS.map { FilesMap.item(path: $0.name, parentIdentifier: root, fs: $0) }
        saveEarlierRun(five)
        var map = FilesIdMap()
        for (index, item) in five.enumerated() {
            map.remember(identifier: item.identifier, path: "f\(index + 6).txt",
                         parentIdentifier: root)
        }
        FilesIdMap.save(map, to: mapURL)

        let host = makeHost(Signals())
        host.list(item: root, page: nil) { _ in }
        answerList([fiveFS[1], fiveFS[2], fiveFS[3]], next: "p2")

        // Mid-walk: a Mac write changes f6 and creates a new folder. The phone
        // listing that is still paging does not carry either one.
        host.modify(BridgeModify(item: "ino:6", base: "aa", content: false, name: nil,
                                 parent: nil, mtime: 99, size: 4, sha256: nil),
                    ready: { _ in }, completion: { _ in })
        answerStat(fs("f6.txt", ino: 6))
        answerStat(fs("f6.txt", ino: 6))
        client.result(id: channel.setAttrs.last!.id, ok: true,
                      item: fs("f6.txt", ino: 6, mtime: 99, etag: "bb").jsonObject,
                      code: nil, message: nil)
        host.create(BridgeCreate(parent: root, name: "newdir", dir: true, size: 0,
                                 sha256: nil),
                    ready: { _ in }, completion: { _ in })
        client.result(id: channel.mkdirs.last!.id, ok: true,
                      item: fs("newdir", ino: 30, dir: true, mtime: 9, etag: "ee").jsonObject,
                      code: nil, message: nil)

        host.list(item: root, page: "p2") { _ in }
        answerList([fiveFS[1], fiveFS[2], fiveFS[3]])

        let replay = try XCTUnwrap(host.replica.log.changes(from: nil, container: nil))
        XCTAssertEqual(replay.deleted, ["ino:10"],
                       "only the item neither written nor gained is deleted")
        XCTAssertNotNil(host.replica.folders[root]?.children["ino:6"])
        XCTAssertNotNil(host.replica.folders[root]?.children["ino:30"])
        XCTAssertNil(host.replica.folders[root]?.children["ino:10"])
    }

    func testABigDeletionIsConfirmedOnceAndOnlyAgreedDeletionsGoOut() throws {
        let thirty = (100..<130).map { item("f\($0).txt", ino: $0) }
        saveEarlierRun(thirty)

        let signals = Signals()
        let host = makeHost(signals)
        host.confirmDelay = 0
        host.confirmScheduler = { _, work in work() }
        host.list(item: root, page: nil) { _ in }
        // The first walk says 25 of 30 are gone; the confirm re-list says 24.
        answerList((125..<130).map { fs("f\($0).txt", ino: $0) })
        XCTAssertEqual(channel.lists.count, 2, "the big deletion is re-listed once")
        answerList((124..<130).map { fs("f\($0).txt", ino: $0) })

        let replay = try XCTUnwrap(host.replica.log.changes(from: nil, container: nil))
        XCTAssertEqual(Set(replay.deleted), Set((100..<124).map { "ino:\($0)" }))
        XCTAssertEqual(host.replica.folders[root]?.children.count, 6)
        XCTAssertEqual(signals.count, 1, "only the confirmed walk signals")
    }

    // MARK: Not-found repair (FILES-34)

    func testANotFoundThumbnailReportsTheItemDeletedAndRelistsItsParent() throws {
        let photo = item("photo.jpg", ino: 6)
        let other = item("other.txt", ino: 7)
        saveEarlierRun([photo, other])
        var map = FilesIdMap()
        map.remember(identifier: "ino:6", path: "photo.jpg", parentIdentifier: root)
        map.remember(identifier: "ino:7", path: "other.txt", parentIdentifier: root)
        FilesIdMap.save(map, to: mapURL)

        let signals = Signals()
        let host = makeHost(signals)
        var result: Result<FilesThumb, FsError>?
        host.thumb(item: "ino:6", size: 512, onStart: { _ in },
                   completion: { result = $0 })
        XCTAssertEqual(channel.thumbs.count, 1)
        client.failure(id: channel.thumbs.last!.id, code: "fs_not_found", message: nil)

        XCTAssertEqual(result?.failure?.code, "fs_not_found")
        XCTAssertNil(host.replica.folders[root]?.children["ino:6"])
        let replay = try XCTUnwrap(host.replica.log.changes(from: nil, container: nil))
        XCTAssertEqual(replay.deleted, ["ino:6"])
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(channel.lists.count, 1, "the parent is re-listed once")
        answerList([fs("other.txt", ino: 7)])
        XCTAssertEqual(host.replica.folders[root]?.children.count, 1)
    }

    func testANotFoundStatReportsTheItemDeleted() throws {
        let photo = item("photo.jpg", ino: 6)
        let other = item("other.txt", ino: 7)
        saveEarlierRun([photo, other])
        var map = FilesIdMap()
        map.remember(identifier: "ino:6", path: "photo.jpg", parentIdentifier: root)
        FilesIdMap.save(map, to: mapURL)

        let host = makeHost(Signals())
        var result: Result<FileItem, FsError>?
        host.stat(item: "ino:6") { result = $0 }
        // The stat of the item says not found; the re-resolve lists the parent
        // and does not find it either.
        client.failure(id: channel.stats.last!.id, code: "fs_not_found", message: nil)
        answerList([fs("other.txt", ino: 7)])
        // The repair's own re-list.
        answerList([fs("other.txt", ino: 7)])

        XCTAssertEqual(result?.failure?.code, "fs_not_found")
        XCTAssertNil(host.replica.folders[root]?.children["ino:6"])
        let replay = try XCTUnwrap(host.replica.log.changes(from: nil, container: nil))
        XCTAssertEqual(replay.deleted, ["ino:6"])
    }

    // MARK: The durable anchor (FILES-32)

    func testTheWorkingSetAnswersTheRecordAfterAnExpiredAnchor() throws {
        let items = [item("a.txt", ino: 6), item("b.txt", ino: 7)]
        saveEarlierRun(items)
        let host = makeHost(Signals())

        var expired: FilesChangesReply?
        host.changes(item: filesWorkingSetIdentifier, from: "w:another:1") {
            expired = try? $0.get()
        }
        XCTAssertEqual(expired?.expired, true)

        var full: FilesChangesReply?
        host.changes(item: filesWorkingSetIdentifier, from: nil) { full = try? $0.get() }
        XCTAssertEqual(Set(full?.delta.items.map(\.name) ?? []), ["a.txt", "b.txt"])
        XCTAssertEqual(full?.delta.deleted, [])
    }
}

private extension Result where Failure == FsError {
    var failure: FsError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
