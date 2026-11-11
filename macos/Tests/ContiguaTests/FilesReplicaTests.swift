// The replica record, the change log it persists with, and the listing walk's
// one confirmation re-list (docs/design/files.md § Sync integrity, FILES-31/32):
// a complete listing diffs even when it is the first after an app start, an
// incomplete walk never deletes, and a walk that would delete most of a folder
// asks a second one before anything goes out.

import Foundation
import XCTest
@testable import Contigua

final class FilesReplicaTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("contigua-replica-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ name: String, ino: Int, parent: String = FilesMap.rootIdentifier,
                      size: Int = 4, mtime: Int = 5, etag: String = "aa") -> FileItem {
        FilesMap.item(path: name, parentIdentifier: parent,
                      fs: FsItem(name: name, dir: false, size: size, mtime: mtime,
                                 ino: ino, etag: etag))
    }

    private func byID(_ items: [FileItem]) -> [String: FileItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, $0) })
    }

    private var replicaURL: URL { directory.appendingPathComponent("files-replica.json") }

    // MARK: The persisted record and log

    func testARecordAndItsLogSurviveASaveAndLoad() throws {
        let children = [item("a.txt", ino: 6), item("b.txt", ino: 7)]
        var replica = FilesReplica()
        replica.folders[FilesMap.rootIdentifier] = FilesFolderRecord(
            children: byID(children), touched: 1_700_000_000.5, digest: nil)
        let added = item("c.txt", ino: 8)
        // The anchor the system was given before the save.
        let anchor = replica.log.anchor
        replica.log.record(container: FilesMap.rootIdentifier,
                           delta: FilesDelta(items: [added], deleted: []))

        FilesReplica.save(replica, to: replicaURL)
        let loaded = FilesReplica.load(replicaURL)

        XCTAssertEqual(loaded, replica)
        XCTAssertEqual(loaded.folders[FilesMap.rootIdentifier]?.children.count, 2)
        XCTAssertEqual(loaded.folders[FilesMap.rootIdentifier]?.touched, 1_700_000_000.5)
        let replay = try XCTUnwrap(loaded.log.changes(from: anchor, container: nil))
        XCTAssertEqual(replay.items.map(\.name), ["c.txt"])
        XCTAssertEqual(replay.deleted, [])
    }

    func testTheDigestSlotIsKeptForSliceThree() throws {
        var replica = FilesReplica()
        replica.folders["ino:10"] = FilesFolderRecord(children: [:], touched: 1,
                                                      digest: "0011223344556677")
        let loaded = try XCTUnwrap(FilesReplica.decode(replica.encoded()))
        XCTAssertEqual(loaded.folders["ino:10"]?.digest, "0011223344556677")
        XCTAssertNil(FilesReplica().folders["ino:10"]?.digest)
    }

    func testAFileFromAnotherFormatIsAFreshRecord() throws {
        let foreign: [String: Any] = ["version": FilesReplica.formatVersion + 1,
                                      "folders": [:], "log": ["epoch": "e", "sequence": 0,
                                                              "entries": []]]
        let data = try JSONSerialization.data(withJSONObject: foreign)
        XCTAssertNil(FilesReplica.decode(data))
        XCTAssertTrue(FilesReplica.load(replicaURL).folders.isEmpty)
    }

    func testACorruptLogIsAFreshRecord() throws {
        let corrupt: [String: Any] = ["version": FilesReplica.formatVersion,
                                      "folders": [:],
                                      "log": ["epoch": "e", "sequence": 4,
                                              "entries": [["s": 9, "c": "ino:1",
                                                           "items": [], "deleted": []]]]]
        let data = try JSONSerialization.data(withJSONObject: corrupt)
        XCTAssertNil(FilesReplica.decode(data))
    }

    // MARK: The walk machine

    func testASmallDeletionIsReportedAtOnce() {
        var walk = FilesWalk(recorded: 5)
        let delta = FilesDelta(items: [], deleted: ["ino:6", "ino:7"])
        XCTAssertEqual(walk.apply(.finished(delta: delta, listing: [])),
                       .report(delta, listing: []))
        XCTAssertEqual(walk.state, .done)
    }

    func testAnIncompleteWalkReportsNoDeletion() {
        let added = item("new.txt", ino: 9)
        let delta = FilesDelta(items: [added], deleted: ["ino:6"])
        var walk = FilesWalk(recorded: 5)
        XCTAssertEqual(walk.apply(.failed(delta: delta, listing: [added])),
                       .report(FilesDelta(items: [added], deleted: []), listing: [added]))
    }

    func testABigDeletionIsConfirmedAndOnlyAgreedDeletionsGoOut() {
        var walk = FilesWalk(recorded: 30)
        let first = FilesDelta(items: [],
                               deleted: (0..<25).map { "ino:\(100 + $0)" })
        XCTAssertEqual(walk.apply(.finished(delta: first, listing: [])), .confirm)
        XCTAssertEqual(walk.state, .confirming(deletions: Set(first.deleted)))

        let second = FilesDelta(items: [],
                                deleted: (0..<24).map { "ino:\(100 + $0)" })
        let agreed = FilesDelta(items: [], deleted: (0..<24).map { "ino:\(100 + $0)" })
        XCTAssertEqual(walk.apply(.confirmed(delta: second, listing: [])),
                       .report(agreed, listing: []))
        XCTAssertEqual(walk.state, .done)
    }

    func testExactlyHalfAndTwentyAreNotConfirmed() {
        // More than half AND more than 20; 20 of 40 is neither.
        var walk = FilesWalk(recorded: 40)
        let delta = FilesDelta(items: [], deleted: (0..<20).map { "ino:\(100 + $0)" })
        XCTAssertEqual(walk.apply(.finished(delta: delta, listing: [])),
                       .report(delta, listing: []))
    }

    func testAFailedConfirmationDeletesNothing() {
        var walk = FilesWalk(recorded: 30)
        let first = FilesDelta(items: [], deleted: (0..<25).map { "ino:\(100 + $0)" })
        _ = walk.apply(.finished(delta: first, listing: []))
        let partial = FilesDelta(items: [], deleted: (0..<3).map { "ino:\(100 + $0)" })
        XCTAssertEqual(walk.apply(.confirmFailed(delta: partial, listing: [])),
                       .report(FilesDelta(items: [], deleted: []), listing: []))
    }

    func testEventsOutOfPhaseAreIgnored() {
        var walk = FilesWalk(recorded: 5)
        XCTAssertEqual(walk.apply(.confirmed(delta: .none, listing: [])), .none)
        _ = walk.apply(.finished(delta: .none, listing: []))
        XCTAssertEqual(walk.apply(.failed(delta: .none, listing: [])), .none)
        XCTAssertEqual(walk.apply(.confirmFailed(delta: .none, listing: [])), .none)
    }
}
