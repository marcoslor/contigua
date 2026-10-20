// Remote changes for the Finder domain (FilesChanges.swift, design "S5 round
// 3"): the listing diff (add, edit, delete, rename-by-ino) and the one ordered
// domain log that answers the working set's `enumerateChanges(from:)` and each
// folder's, including `.syncAnchorExpired` for an anchor it cannot replay.

import Foundation
import XCTest
@testable import PocketDeck

final class FilesChangesTests: XCTestCase {
    private let epoch = "e1"

    private func item(_ name: String, ino: Int, parent: String = FilesMap.rootIdentifier,
                      size: Int = 4, mtime: Int = 5, etag: String = "aa") -> FileItem {
        FilesMap.item(path: name, parentIdentifier: parent,
                      fs: FsItem(name: name, dir: false, size: size, mtime: mtime,
                                 ino: ino, etag: etag))
    }

    private func byID(_ items: [FileItem]) -> [String: FileItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, $0) })
    }

    // MARK: Diffing

    func testDiffFindsAddedAndEdited() {
        let old = byID([item("a.txt", ino: 6), item("b.txt", ino: 7)])
        let new = [item("a.txt", ino: 6), item("b.txt", ino: 7, size: 9, mtime: 8, etag: "bb"),
                   item("c.txt", ino: 8)]
        let delta = FilesDiff.delta(old: old, new: new)
        XCTAssertEqual(delta.deleted, [])
        XCTAssertEqual(Set(delta.items.map(\.name)), ["b.txt", "c.txt"])
    }

    func testDiffFindsDeletions() {
        let old = byID([item("a.txt", ino: 6), item("b.txt", ino: 7)])
        let delta = FilesDiff.delta(old: old, new: [item("a.txt", ino: 6)])
        XCTAssertEqual(delta.items, [])
        XCTAssertEqual(delta.deleted, ["ino:7"])
    }

    func testRenameByInoIsAnUpdateNotADelete() {
        let old = byID([item("old.txt", ino: 6)])
        let new = [item("new.txt", ino: 6)]
        let delta = FilesDiff.delta(old: old, new: new)
        XCTAssertEqual(delta.deleted, [])
        XCTAssertEqual(delta.items.map(\.name), ["new.txt"])
        XCTAssertEqual(delta.items.first?.identifier, "ino:6")
    }

    func testNothingChangedIsEmpty() {
        let old = byID([item("a.txt", ino: 6)])
        let delta = FilesDiff.delta(old: old, new: [item("a.txt", ino: 6)])
        XCTAssertTrue(delta.isEmpty)
    }

    // MARK: The domain log

    func testAnchorProgressesOnlyWhenSomethingMoved() {
        var log = FilesChangeLog(epoch: epoch)
        XCTAssertEqual(log.sequence, 0)
        let start = log.anchor
        XCTAssertFalse(log.record(container: "ino:10", delta: .none))
        XCTAssertEqual(log.anchor, start)
        XCTAssertTrue(log.record(container: "ino:10",
                                 delta: FilesDelta(items: [item("a.txt", ino: 6)], deleted: [])))
        XCTAssertNotEqual(log.anchor, start)
        XCTAssertEqual(log.sequence, 1)
        XCTAssertEqual(log.changes(from: start, container: nil)?.items.map(\.name), ["a.txt"])
    }

    func testSequenceRunsAcrossContainers() {
        var log = FilesChangeLog(epoch: epoch)
        let start = log.anchor
        log.record(container: "ino:10",
                   delta: FilesDelta(items: [item("a.txt", ino: 6, parent: "ino:10")], deleted: []))
        let middle = log.anchor
        log.record(container: "ino:20",
                   delta: FilesDelta(items: [item("b.txt", ino: 7, parent: "ino:20")], deleted: []))
        XCTAssertEqual(log.sequence, 2)
        // The working set replays both, in order, with the real parents.
        let all = log.changes(from: start, container: nil)
        XCTAssertEqual(all?.items.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(all?.items.map(\.parentIdentifier), ["ino:10", "ino:20"])
        // A folder sees only its own entry.
        XCTAssertEqual(log.changes(from: FilesChangeLog.containerAnchor(0, container: "ino:20", epoch: epoch),
                                    container: "ino:20")?.items.map(\.name), ["b.txt"])
        XCTAssertEqual(log.changes(from: FilesChangeLog.containerAnchor(1, container: "ino:10", epoch: epoch),
                                    container: "ino:10")?.isEmpty, true)
    }

    func testContainerAnchorsAreScopedAndCarryTheEpoch() {
        var log = FilesChangeLog(epoch: epoch)
        log.record(container: "ino:10",
                   delta: FilesDelta(items: [item("a.txt", ino: 6)], deleted: []))
        let folder = log.containerAnchor("ino:10")
        XCTAssertEqual(folder, "g:e1:1:ino:10")
        XCTAssertEqual(log.changes(from: folder, container: "ino:10")?.isEmpty, true)
        XCTAssertNil(log.changes(from: folder, container: "ino:11"))
        XCTAssertNil(log.changes(from: "g:other:1:ino:10", container: "ino:10"))
        XCTAssertNil(log.changes(from: "w:e1:1", container: "ino:10"))
        XCTAssertNil(log.changes(from: "files-s3", container: nil))
        // A working-set anchor is not a folder's.
        XCTAssertNil(log.changes(from: "g:e1:1:ino:10", container: nil))
    }

    func testAnchorReplaysEverythingAfterIt() {
        var log = FilesChangeLog(epoch: epoch)
        log.record(container: "s",
                   delta: FilesDelta(items: [item("a.txt", ino: 6)], deleted: []))
        let middle = log.anchor
        log.record(container: "s",
                   delta: FilesDelta(items: [item("b.txt", ino: 7)], deleted: []))
        let delta = log.changes(from: middle, container: nil)
        XCTAssertEqual(delta?.items.map(\.name), ["b.txt"])
        XCTAssertEqual(delta?.deleted, [])
        XCTAssertEqual(log.changes(from: log.anchor, container: nil)?.isEmpty, true)
    }

    func testAFileDeletedThenRecreatedEndsUpAsAnUpdate() {
        var log = FilesChangeLog(epoch: epoch)
        log.record(container: "s", delta: FilesDelta(items: [], deleted: ["ino:6"]))
        let middle = log.anchor
        log.record(container: "s",
                   delta: FilesDelta(items: [item("back.txt", ino: 6)], deleted: []))
        let delta = log.changes(from: middle, container: nil)
        XCTAssertEqual(delta?.items.map(\.name), ["back.txt"])
        XCTAssertEqual(delta?.deleted, [])
    }

    func testAnAnchorFromAnotherEpochExpires() {
        var log = FilesChangeLog(epoch: epoch)
        log.record(container: "s",
                   delta: FilesDelta(items: [item("a.txt", ino: 6)], deleted: []))
        XCTAssertNil(log.changes(from: "w:e2:1", container: nil))
        XCTAssertNil(log.changes(from: "w:e1:9", container: nil), "a sequence from the future")
    }

    func testAnAnchorOlderThanTheKeptHistoryExpires() {
        var log = FilesChangeLog(epoch: epoch)
        let start = log.anchor
        for index in 0..<(FilesChangeLog.maxEntries + 2) {
            log.record(container: "s",
                       delta: FilesDelta(items: [item("f\(index).txt", ino: index + 6)],
                                         deleted: []))
        }
        XCTAssertEqual(log.entries.count, FilesChangeLog.maxEntries)
        XCTAssertEqual(log.sequence, FilesChangeLog.maxEntries + 2)
        XCTAssertNil(log.changes(from: start, container: nil))
        let first = log.entries.first!.sequence
        XCTAssertNil(log.changes(from: FilesChangeLog.anchor(first - 2, epoch: epoch),
                                 container: nil))
        XCTAssertNotNil(log.changes(from: FilesChangeLog.anchor(first, epoch: epoch),
                                    container: nil))
    }

    func testTheLogIsDomainWideAndCappedTogether() {
        var log = FilesChangeLog(epoch: epoch)
        for index in 0..<FilesChangeLog.maxEntries {
            log.record(container: index % 2 == 0 ? "a" : "b",
                       delta: FilesDelta(items: [item("f\(index).txt", ino: index + 6)],
                                         deleted: []))
        }
        XCTAssertEqual(log.entries.count, FilesChangeLog.maxEntries)
        log.record(container: "a",
                   delta: FilesDelta(items: [item("last.txt", ino: 9999)], deleted: []))
        XCTAssertEqual(log.entries.count, FilesChangeLog.maxEntries)
        XCTAssertEqual(log.entries.last?.container, "a")
    }
}
