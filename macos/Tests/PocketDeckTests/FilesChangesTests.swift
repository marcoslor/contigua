// Remote changes for the Finder domain (FilesChanges.swift, design §5): the
// listing diff (add, edit, delete, rename-by-ino) and the per-container anchor
// log that answers `enumerateChanges(from:)`, including the `.syncAnchorExpired`
// answer for an anchor it cannot replay.

import Foundation
import XCTest
@testable import PocketDeck

final class FilesChangesTests: XCTestCase {
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

    // MARK: Anchors

    func testAnchorProgressesOnlyWhenSomethingMoved() {
        var log = FilesChangeLog(scope: "ino:10")
        XCTAssertEqual(log.generation, 0)
        let start = log.anchor
        XCTAssertFalse(log.record(.none))
        XCTAssertEqual(log.anchor, start)
        XCTAssertTrue(log.record(FilesDelta(items: [item("a.txt", ino: 6)], deleted: [])))
        XCTAssertNotEqual(log.anchor, start)
        XCTAssertEqual(log.generation, 1)
        XCTAssertEqual(log.changes(from: start)?.items.map(\.name), ["a.txt"])
    }

    func testAnchorReplaysEverythingAfterIt() {
        var log = FilesChangeLog(scope: "s")
        log.record(FilesDelta(items: [item("a.txt", ino: 6)], deleted: []))
        let middle = log.anchor
        log.record(FilesDelta(items: [item("b.txt", ino: 7)], deleted: []))
        let delta = log.changes(from: middle)
        XCTAssertEqual(delta?.items.map(\.name), ["b.txt"])
        XCTAssertEqual(delta?.deleted, [])
        XCTAssertEqual(log.changes(from: log.anchor)?.isEmpty, true)
    }

    func testAFileDeletedThenRecreatedEndsUpAsAnUpdate() {
        var log = FilesChangeLog(scope: "s")
        log.record(FilesDelta(items: [], deleted: ["ino:6"]))
        let middle = log.anchor
        log.record(FilesDelta(items: [item("back.txt", ino: 6)], deleted: []))
        let delta = log.changes(from: middle)
        XCTAssertEqual(delta?.items.map(\.name), ["back.txt"])
        XCTAssertEqual(delta?.deleted, [])
    }

    func testAnAnchorFromAnotherContainerExpires() {
        var log = FilesChangeLog(scope: "ino:10")
        log.record(FilesDelta(items: [item("a.txt", ino: 6)], deleted: []))
        XCTAssertNil(log.changes(from: FilesChangeLog.anchor(0, scope: "ino:11")))
        XCTAssertNil(log.changes(from: "files-s3"))
        XCTAssertNil(log.changes(from: "g999.ino:10"))
    }

    func testAnAnchorOlderThanTheKeptHistoryExpires() {
        var log = FilesChangeLog(scope: "s")
        let start = log.anchor
        for index in 0..<(FilesChangeLog.maxEntries + 2) {
            log.record(FilesDelta(items: [item("f\(index).txt", ino: index + 6)], deleted: []))
        }
        XCTAssertEqual(log.entries.count, FilesChangeLog.maxEntries)
        XCTAssertNil(log.changes(from: start))
        XCTAssertNotNil(log.changes(from: log.entries.first.map {
            FilesChangeLog.anchor($0.generation - 1, scope: "s")
        } ?? start))
    }
}
