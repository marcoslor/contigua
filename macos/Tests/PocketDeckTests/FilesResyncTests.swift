// The reconnect resync's phases (docs/design/files.md § Sync integrity, slice 3;
// FILES-33): idle → digesting → relisting → done, with one `fs.digest` for the
// record's folders and a listing only for the ones whose digest moved (or that
// have no digest yet). A not-found folder is a deletion; a phone without
// `fs.digest` lists them all. Pure transitions: no socket, no clock.

import Foundation
import XCTest
@testable import PocketDeck

final class FilesResyncTests: XCTestCase {
    private func recorded(_ id: String, _ path: String, _ digest: String?) -> FilesResync.Folder {
        FilesResync.Folder(id: id, path: path, recorded: digest)
    }

    private func answer(_ folder: FilesResync.Folder, _ reply: FsDigestReply?) -> FilesResync.Answer {
        FilesResync.Answer(folder: folder, digest: reply)
    }

    func testAReadyWithNoRecordedFoldersIsImmediatelyDone() {
        var machine = FilesResync()
        XCTAssertEqual(machine.apply(.ready([])), .finished)
        XCTAssertEqual(machine.state, .done)
    }

    func testAReadyAsksOneDigestForEveryFolder() {
        var machine = FilesResync()
        let folders = [recorded("a", "A", "aa"), recorded("b", "B", nil)]
        XCTAssertEqual(machine.apply(.ready(folders)), .ask(["A", "B"]))
        XCTAssertEqual(machine.state, .digesting(folders))
    }

    func testAMatchingDigestNeedsNoListing() {
        var machine = FilesResync()
        let a = recorded("a", "A", "aa")
        _ = machine.apply(.ready([a]))
        XCTAssertEqual(machine.apply(.digests([answer(a, .digest("aa"))])), .finished)
        XCTAssertEqual(machine.state, .done)
    }

    func testAChangedMissingOrNewDigestIsRelisted() {
        var machine = FilesResync()
        let same = recorded("a", "A", "aa")
        let moved = recorded("b", "B", "bb")
        let unknown = recorded("c", "C", nil)
        let missing = recorded("d", "D", "dd")
        _ = machine.apply(.ready([same, moved, unknown, missing]))
        let action = machine.apply(.digests([answer(same, .digest("aa")),
                                             answer(moved, .digest("bb2")),
                                             answer(unknown, nil),
                                             answer(missing, nil)]))
        guard case .apply(let deletions, let relist) = action else {
            return XCTFail("expected a relist, got \(action)")
        }
        XCTAssertEqual(deletions, [])
        XCTAssertEqual(Set(relist), ["b", "c", "d"],
                       "a folder the reply does not name is compared by a listing")
        XCTAssertEqual(machine.state, .relisting(["b", "c", "d"]))
    }

    func testANotFoundFolderIsDeleted() {
        var machine = FilesResync()
        let root = recorded(FilesMap.rootIdentifier, "", "rr")
        let a = recorded("a", "A", "aa")
        let b = recorded("b", "B", "bb")
        _ = machine.apply(.ready([root, a, b]))
        let action = machine.apply(.digests([answer(root, .digest("rr")),
                                             answer(a, .digest("aa")),
                                             answer(b, .notFound)]))
        guard case .apply(let deletions, let relist) = action else {
            return XCTFail("expected a deletion, got \(action)")
        }
        XCTAssertEqual(deletions, ["b"], "the host adds everything the record holds under it")
        XCTAssertEqual(relist, [])
        XCTAssertEqual(machine.state, .done)
    }

    /// A phone that rebooted and isn't unlocked yet can't read its shared
    /// storage, so every path answers not_found. Without the root's digest in
    /// the same reply nothing proves the storage readable: no folder is
    /// deleted (Finder would empty, its downloaded copies with it); each is
    /// listed instead, and a failed listing deletes nothing either.
    func testNotFoundEverywhereDeletesNothingWithoutAReadableRoot() {
        var machine = FilesResync()
        let root = recorded(FilesMap.rootIdentifier, "", "rr")
        let a = recorded("a", "A", "aa")
        let b = recorded("b", "B", "bb")
        _ = machine.apply(.ready([root, a, b]))
        let action = machine.apply(.digests([answer(root, .notFound),
                                             answer(a, .notFound),
                                             answer(b, .notFound)]))
        guard case .apply(let deletions, let relist) = action else {
            return XCTFail("expected listings, got \(action)")
        }
        XCTAssertEqual(deletions, [])
        XCTAssertEqual(Set(relist), [FilesMap.rootIdentifier, "a", "b"])
    }

    func testANotFoundIsNoDeletionWhenTheReplyLacksTheRoot() {
        var machine = FilesResync()
        let a = recorded("a", "A", "aa")
        let b = recorded("b", "B", "bb")
        _ = machine.apply(.ready([a, b]))
        let action = machine.apply(.digests([answer(a, .digest("aa")),
                                             answer(b, .notFound)]))
        XCTAssertEqual(action, .apply(deletions: [], relist: ["b"]))
    }

    func testANotFoundRootIsRelistedNeverDeleted() {
        var machine = FilesResync()
        let root = recorded(FilesMap.rootIdentifier, "", "old")
        _ = machine.apply(.ready([root]))
        let action = machine.apply(.digests([answer(root, .notFound)]))
        XCTAssertEqual(action, .apply(deletions: [], relist: [FilesMap.rootIdentifier]))
    }

    func testADigestFailureRelistsEveryFolder() {
        var machine = FilesResync()
        let a = recorded("a", "A", "aa")
        let b = recorded("b", "B", "bb")
        _ = machine.apply(.ready([a, b]))
        guard case .apply(let deletions, let relist) = machine.apply(.unknown) else {
            return XCTFail("expected every folder to be listed")
        }
        XCTAssertEqual(deletions, [])
        XCTAssertEqual(relist, ["a", "b"], "the folders are re-listed by identifier")
        XCTAssertEqual(machine.state, .relisting(["a", "b"]))
    }

    func testEachListedFolderCountsDownAndTheLastFinishes() {
        var machine = FilesResync()
        let a = recorded("a", "A", nil)
        let b = recorded("b", "B", nil)
        _ = machine.apply(.ready([a, b]))
        _ = machine.apply(.digests([answer(a, nil), answer(b, nil)]))
        XCTAssertEqual(machine.apply(.listed("a")), .none)
        XCTAssertEqual(machine.state, .relisting(["b"]))
        XCTAssertEqual(machine.apply(.listed("b")), .finished)
        XCTAssertEqual(machine.state, .done)
    }

    func testADropReturnsToIdleAndTheNextReadyStartsOver() {
        var machine = FilesResync()
        let a = recorded("a", "A", nil)
        _ = machine.apply(.ready([a]))
        XCTAssertEqual(machine.apply(.dropped), .none)
        XCTAssertEqual(machine.state, .idle)

        _ = machine.apply(.ready([a]))
        _ = machine.apply(.digests([answer(a, nil)]))
        XCTAssertEqual(machine.apply(.dropped), .none)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNotEqual(machine.apply(.ready([a])), .none,
                          "the next ready starts over from idle")
    }

    func testEventsOutOfPhaseAreIgnored() {
        var machine = FilesResync()
        XCTAssertEqual(machine.apply(.listed("a")), .none)
        XCTAssertEqual(machine.apply(.digests([])), .none)
        XCTAssertEqual(machine.apply(.unknown), .none)

        let a = recorded("a", "A", nil)
        _ = machine.apply(.ready([a]))
        XCTAssertEqual(machine.apply(.ready([a])), .none, "a second ready does not restart")
        XCTAssertEqual(machine.apply(.listed("a")), .none, "no listing is running")
        XCTAssertEqual(machine.state, .digesting([a]))
    }
}
