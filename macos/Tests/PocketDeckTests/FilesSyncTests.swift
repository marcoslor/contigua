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
    private(set) var digests: [(id: UInt32, paths: [String])] = []
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

    func fsDigest(id: UInt32, paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        digests.append((id, paths))
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
    /// The answer helpers' place in the request log (the resync lists more than
    /// one folder).
    private var answeredStats = 0
    private var answeredLists = 0

    private var root: String { FilesMap.rootIdentifier }
    private var mapURL: URL { directory.appendingPathComponent("files-ids.json") }
    private var replicaURL: URL { directory.appendingPathComponent("files-replica.json") }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocketdeck-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        channel = ReplicaChannel()
        client = FsClient(channel: channel)
        answeredStats = 0
        answeredLists = 0
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

    private func answerList(_ items: [FsItem], next: String? = nil, digest: String? = nil) {
        let request = channel.lists.last!
        client.items(id: request.id, page: next, digest: digest, items: items.map(\.jsonObject))
    }

    private func answerStat(_ fs: FsItem) {
        client.item(id: channel.stats.last!.id, item: fs.jsonObject)
    }

    // MARK: The reconnect resync's fixtures (FILES-33)

    private func folder(_ name: String, ino: Int) -> FileItem {
        FilesMap.item(path: name, parentIdentifier: root, fs: fs(name, ino: ino, dir: true))
    }

    private struct Recorded {
        var children: [FileItem]
        var digest: String?
        var touched: TimeInterval
    }

    /// The record an earlier ready left: folders by identifier, with the
    /// digest of their last complete listing.
    private func saveRecord(_ folders: [String: Recorded]) {
        var replica = FilesReplica()
        for (identifier, entry) in folders {
            replica.folders[identifier] = FilesFolderRecord(
                children: byID(entry.children), touched: entry.touched, digest: entry.digest)
        }
        FilesReplica.save(replica, to: replicaURL)
    }

    /// The id map an earlier run left: the resync's identifiers must resolve to
    /// the phone's paths.
    private func rememberPaths(_ paths: [String: String]) {
        var map = FilesIdMap()
        for (identifier, path) in paths {
            map.remember(identifier: identifier, path: path, parentIdentifier: root)
        }
        FilesIdMap.save(map, to: mapURL)
    }

    private func answerDigest(_ values: [String: String]) {
        client.digests(id: channel.digests.last!.id, values: values)
    }

    /// A 32-hex digest the FsClient accepts as the phone's answer.
    private func hex(_ value: Int) -> String { String(format: "%032x", value) }

    /// Every folder the resync re-lists is resolved with one stat first.
    private func answerPendingStats() {
        while answeredStats < channel.stats.count {
            let request = channel.stats[answeredStats]
            answeredStats += 1
            let name = (request.path as NSString).lastPathComponent
            client.item(id: request.id,
                        item: fs(name.isEmpty ? "root" : name, ino: 900 + answeredStats,
                                 dir: true).jsonObject)
        }
    }

    /// Answers every list request still waiting, from its folder's path.
    private func answerPendingLists(_ itemsByPath: [String: [FsItem]], digest: String? = nil) {
        while answeredLists < channel.lists.count {
            let request = channel.lists[answeredLists]
            answeredLists += 1
            client.items(id: request.id, page: nil, digest: digest,
                         items: (itemsByPath[request.path] ?? []).map(\.jsonObject))
        }
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

    // MARK: The reconnect resync (FILES-33)

    /// (a) Three recorded folders, one digest differs: one `fs.digest` for all
    /// of them, exactly one listing, and its deletions reach the log.
    func testAReadyAsksEveryRecordedFolderAndRelistsOnlyTheOneThatMoved() throws {
        let a = folder("A", ino: 100)
        let b = folder("B", ino: 200)
        let c = folder("C", ino: 300)
        saveRecord([
            a.identifier: Recorded(children: [item("a1.txt", ino: 101, parent: a.identifier)],
                                   digest: hex(1), touched: 1),
            b.identifier: Recorded(children: [item("b1.txt", ino: 201, parent: b.identifier),
                                              item("b2.txt", ino: 202, parent: b.identifier)],
                                   digest: hex(2), touched: 2),
            c.identifier: Recorded(children: [item("c1.txt", ino: 301, parent: c.identifier)],
                                   digest: hex(3), touched: 3),
        ])
        rememberPaths([a.identifier: "A", b.identifier: "B", c.identifier: "C"])

        let signals = Signals()
        let host = makeHost(signals)
        host.sessionReady()

        XCTAssertEqual(channel.digests.count, 1, "one fs.digest for the whole ready")
        XCTAssertEqual(channel.digests.first?.paths, ["C", "B", "A"],
                       "the most recently touched folders are asked first")
        XCTAssertEqual(channel.lists.count, 0, "nothing is listed before the answer")

        answerDigest(["A": hex(1), "B": hex(9), "C": hex(3)])
        answerPendingStats()
        XCTAssertEqual(channel.lists.count, 1, "only the moved folder is re-listed")
        XCTAssertEqual(channel.lists.last?.path, "B")
        XCTAssertEqual(channel.lists.last?.page, nil)

        answerPendingLists(["B": [fs("b3.txt", ino: 203), fs("b4.txt", ino: 204)]],
                           digest: hex(12))
        let replay = try XCTUnwrap(host.replica.log.changes(from: nil, container: nil))
        XCTAssertEqual(Set(replay.deleted), ["ino:201", "ino:202"])
        XCTAssertEqual(Set(replay.items.map(\.name)), ["b3.txt", "b4.txt"])
        XCTAssertEqual(host.replica.folders[b.identifier]?.digest, hex(12),
                       "(f) the last page's digest lands in the record")
        XCTAssertEqual(signals.count, 1)
        XCTAssertNotNil(host.replica.folders[a.identifier]?.children["ino:101"],
                        "an unchanged folder keeps its record and is not listed")
    }

    /// (b) A folder the phone answers `not_found` for is reported deleted with
    /// everything the record holds under it, as one delta.
    func testANotFoundFolderIsDeletedWithEverythingTheRecordHoldsUnderIt() throws {
        let a = folder("A", ino: 100)
        let b = folder("B", ino: 200)
        let d = FilesMap.item(path: "B/D", parentIdentifier: b.identifier,
                              fs: fs("D", ino: 210, dir: true))
        saveRecord([
            a.identifier: Recorded(children: [item("a1.txt", ino: 101, parent: a.identifier)],
                                   digest: hex(1), touched: 1),
            b.identifier: Recorded(children: [item("b1.txt", ino: 201, parent: b.identifier), d],
                                   digest: hex(2), touched: 2),
            d.identifier: Recorded(children: [item("d1.txt", ino: 211, parent: d.identifier)],
                                   digest: hex(4), touched: 1),
        ])
        rememberPaths([a.identifier: "A", b.identifier: "B", d.identifier: "B/D"])

        let signals = Signals()
        let host = makeHost(signals)
        host.sessionReady()
        answerDigest(["A": hex(1), "B": "not_found", "B/D": hex(4)])

        XCTAssertEqual(channel.lists.count, 0, "no listing: the folder is gone")
        XCTAssertNil(host.replica.folders[b.identifier])
        XCTAssertNil(host.replica.folders[d.identifier])
        let replay = try XCTUnwrap(host.replica.log.changes(from: nil, container: nil))
        XCTAssertEqual(Set(replay.deleted),
                       [b.identifier, "ino:201", d.identifier, "ino:211"],
                       "the folder and its recorded children are one delta")
        XCTAssertEqual(signals.count, 1)
    }

    /// A phone whose storage is not mounted answers not_found for the root:
    /// that must never empty Finder.
    func testANotFoundRootIsRelistedNeverDeleted() throws {
        let a = folder("A", ino: 100)
        saveRecord([
            root: Recorded(children: [], digest: hex(9), touched: 2),
            a.identifier: Recorded(children: [], digest: hex(1), touched: 1),
        ])
        rememberPaths([a.identifier: "A"])
        let host = makeHost(Signals())
        host.sessionReady()
        answerDigest(["": "not_found", "A": hex(1)])
        XCTAssertNotNil(host.replica.folders[root], "the root is never deleted")
        XCTAssertEqual(channel.lists.count, 1, "the root is re-listed instead")
        answerPendingLists([:], digest: hex(9))
    }

    /// (c) `fs_unknown`: the phone has no digest, so every folder is listed.
    func testAnUnknownDigestRelistsEveryRecordedFolder() throws {
        let a = folder("A", ino: 100)
        let b = folder("B", ino: 200)
        let c = folder("C", ino: 300)
        saveRecord([
            a.identifier: Recorded(children: [], digest: hex(1), touched: 1),
            b.identifier: Recorded(children: [], digest: hex(2), touched: 2),
            c.identifier: Recorded(children: [], digest: hex(3), touched: 3),
        ])
        rememberPaths([a.identifier: "A", b.identifier: "B", c.identifier: "C"])

        let host = makeHost(Signals())
        host.sessionReady()
        client.failure(id: channel.digests.last!.id, code: "fs_unknown", message: nil)
        answerPendingStats()
        XCTAssertEqual(channel.lists.count, 3)
        XCTAssertEqual(Set(channel.lists.map(\.path)), ["A", "B", "C"])
    }

    /// (d) More than 64 recorded folders: only the 64 most recently touched.
    func testOnlyTheSixtyFourMostRecentlyTouchedFoldersAreAsked() throws {
        var folders: [String: Recorded] = [:]
        var paths: [String: String] = [:]
        for index in 1...70 {
            let name = "F\(index)"
            let recorded = FilesMap.item(path: name, parentIdentifier: root,
                                         fs: fs(name, ino: 1_000 + index, dir: true))
            folders[recorded.identifier] = Recorded(children: [], digest: hex(index),
                                                    touched: Double(index))
            paths[recorded.identifier] = name
        }
        saveRecord(folders)
        rememberPaths(paths)
        let host = makeHost(Signals())
        host.sessionReady()
        let asked = channel.digests.first?.paths ?? []
        XCTAssertEqual(asked.count, 64)
        XCTAssertEqual(Set(asked), Set((7...70).map { "F\($0)" }),
                       "the 64 most recently touched, the rest wait for their next touch")
        answerDigest(Dictionary(uniqueKeysWithValues: asked.map {
            ($0, hex(Int($0.dropFirst()) ?? 0))
        }))
        XCTAssertEqual(channel.lists.count, 0)
    }

    /// (e) A session drop mid-relist stops the work; the next ready starts over.
    func testADropDuringRelistingHoldsUntilTheNextReady() {
        let a = folder("A", ino: 100)
        let b = folder("B", ino: 200)
        let c = folder("C", ino: 300)
        saveRecord([
            a.identifier: Recorded(children: [], digest: hex(1), touched: 1),
            b.identifier: Recorded(children: [], digest: hex(2), touched: 2),
            c.identifier: Recorded(children: [], digest: hex(3), touched: 3),
        ])
        rememberPaths([a.identifier: "A", b.identifier: "B", c.identifier: "C"])
        let host = makeHost(Signals())
        host.sessionReady()
        answerDigest(["A": hex(1), "B": hex(9), "C": hex(10)])
        answerPendingStats()
        XCTAssertEqual(channel.lists.count, 2)

        host.sessionDropped()
        answerPendingLists([:], digest: hex(20))
        XCTAssertEqual(channel.lists.count, 2, "a dropped session asks nothing more")
        XCTAssertEqual(channel.digests.count, 1)

        host.sessionReady()
        XCTAssertEqual(channel.digests.count, 2, "the next ready starts over")
        answerDigest(["A": hex(1), "B": hex(9), "C": hex(10)])
    }

    /// (f) A digest is stored only by a complete listing, from its last page.
    func testOnlyTheLastPageOfACompleteWalkStoresTheDigest() throws {
        let host = makeHost(Signals())
        host.list(item: root, page: nil) { _ in }
        answerList([fs("a.txt", ino: 6)], next: "p2", digest: "first-page")
        XCTAssertEqual(host.replica.folders[root]?.digest, nil,
                       "a page that is not the last carries no digest into the record")
        host.list(item: root, page: "p2") { _ in }
        answerList([fs("b.txt", ino: 7)], digest: "last-page")
        XCTAssertEqual(host.replica.folders[root]?.digest, "last-page")

        // An incomplete walk leaves the digest of the last complete one alone.
        host.list(item: root, page: nil) { _ in }
        answerList([fs("a.txt", ino: 6)], next: "p3", digest: "partial")
        host.list(item: root, page: "p3") { _ in }
        client.failure(id: channel.lists.last!.id, code: "io", message: nil)
        XCTAssertEqual(host.replica.folders[root]?.digest, "last-page")
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
