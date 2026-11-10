// One folder's sync job (FolderJob.swift, ISS-37; FILES-31/33/34/35): every
// phase and every event, including the ones a phase must ignore. Pure values:
// no socket, no clock, no record store.

import Foundation
import XCTest
@testable import PocketDeck

final class FolderJobTests: XCTestCase {
    private let folder = "ino:10"

    private func item(_ name: String, ino: Int, parent: String? = nil,
                      size: Int = 4, mtime: Int = 5, etag: String = "aa") -> FileItem {
        FilesMap.item(path: name, parentIdentifier: parent ?? folder,
                      fs: FsItem(name: name, dir: false, size: size, mtime: mtime,
                                 ino: ino, etag: etag))
    }

    private func byID(_ items: [FileItem]) -> [String: FileItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, $0) })
    }

    private func makeWalk(recorded: Int = 0, start: [String: FileItem] = [:],
                      owner: FolderJob.Owner = .host,
                      token: Int = 1) -> FolderJob.Walk {
        FolderJob.Walk(recorded: recorded, start: start, owner: owner, token: token)
    }

    private func bigRecord(_ count: Int = 30) -> [String: FileItem] {
        byID((100..<(100 + count)).map { item("f\($0).txt", ino: $0) })
    }

    /// A job in one phase, reached through the real events.
    private func job(_ state: FolderJob.State) -> FolderJob {
        switch state {
        case .idle:
            return FolderJob(folder: folder)
        case .walking(let walk, let after):
            var job = FolderJob(folder: folder)
            _ = job.apply(.visit(recorded: walk.machine.recorded, start: walk.start,
                                 token: walk.token))
            if after { _ = job.apply(.refresh(token: walk.token)) }
            return job
        case .confirming(let walk, let after, let waiting):
            var job = FolderJob(folder: folder)
            let record = bigRecord()
            _ = job.apply(.systemStart(recorded: record.count, start: record, token: walk.token))
            _ = job.apply(.lastPage(token: walk.token, items: [], digest: nil, record: record,
                                    idMap: FilesIdMap(), uploading: [], uploadNames: []))
            if !waiting { _ = job.apply(.confirmDue(token: walk.token)) }
            if after { _ = job.apply(.refresh(token: walk.token)) }
            return job
        case .repairing(let walk, let after):
            var job = FolderJob(folder: folder)
            _ = job.apply(.notFound(recorded: 0, start: [:], token: walk.token))
            if after { _ = job.apply(.refresh(token: walk.token)) }
            return job
        case .refreshing(let again, let token):
            var job = FolderJob(folder: folder)
            _ = job.apply(.refresh(token: token))
            if again { _ = job.apply(.refresh(token: token)) }
            return job
        }
    }

    // MARK: Starts

    func testAVisitStartsAHostWalk() {
        var job = FolderJob(folder: folder)
        let start = byID([item("a.txt", ino: 6)])
        XCTAssertEqual(job.apply(.visit(recorded: 1, start: start, token: 7)), .start)
        guard case .walking(let walk, let after) = job.state else {
            return XCTFail("expected walking, got \(job.state)")
        }
        XCTAssertEqual(walk.owner, .host)
        XCTAssertEqual(walk.token, 7)
        XCTAssertEqual(walk.start, start)
        XCTAssertFalse(after)
        XCTAssertEqual(walk.pages, [:])
    }

    func testAFirstSystemReadStartsAWalkAndALaterOneIsServedOnly() {
        var job = FolderJob(folder: folder)
        XCTAssertEqual(job.apply(.systemStart(recorded: 0, start: [:], token: 2)), .start)
        guard case .walking(let walk, _) = job.state else {
            return XCTFail("expected walking, got \(job.state)")
        }
        XCTAssertEqual(walk.owner, .system)
        XCTAssertEqual(job.apply(.systemStart(recorded: 0, start: [:], token: 2)), .serveOnly,
                       "a second read does not own the record")
        XCTAssertEqual(job.state, .walking(walk, refreshAfter: false), "and does not reset the walk")

        var confirming = self.job(.confirming(makeWalk(recorded: 0, token: 1), refreshAfter: false, waiting: true))
        XCTAssertEqual(confirming.apply(.systemStart(recorded: 0, start: [:], token: 1)),
                       .serveOnly)
        var refreshing = self.job(.refreshing(again: false, token: 1))
        XCTAssertEqual(refreshing.apply(.systemStart(recorded: 0, start: [:], token: 1)),
                       .serveOnly)
    }

    func testAResyncStartIsServedOnlyWhileABusyPassRuns() {
        var job = self.job(.walking(makeWalk(recorded: 0), refreshAfter: false))
        XCTAssertEqual(job.apply(.hostStart(recorded: 0, start: [:], token: 1)), .serveOnly)
        var idle = FolderJob(folder: folder)
        XCTAssertEqual(idle.apply(.hostStart(recorded: 0, start: [:], token: 1)), .start)
    }

    // MARK: Pushes

    func testAPhonePushSettlesBeforeItsWalk() {
        var job = FolderJob(folder: folder)
        XCTAssertEqual(job.apply(.refresh(token: 3)), .scheduleRefresh)
        XCTAssertEqual(job.state, .refreshing(again: false, token: 3))

        XCTAssertEqual(job.apply(.refresh(token: 3)), .none)
        XCTAssertEqual(job.state, .refreshing(again: true, token: 3),
                       "a second push in the settle is the same walk")

        let start = byID([item("a.txt", ino: 6)])
        XCTAssertEqual(job.apply(.refreshDue(token: 4, recorded: 1, start: start)), .none,
                       "a settle from another run changes nothing")
        XCTAssertEqual(job.apply(.refreshDue(token: 3, recorded: 1, start: start)), .start)
        guard case .walking(let walk, let after) = job.state else {
            return XCTFail("expected walking, got \(job.state)")
        }
        XCTAssertEqual(walk.owner, .host)
        XCTAssertEqual(walk.token, 3)
        XCTAssertEqual(walk.start, start)
        XCTAssertFalse(after)
    }

    func testAPushDuringAWalkRunsOneRefreshAfterIt() {
        var job = self.job(.walking(makeWalk(recorded: 2, start: byID([item("a.txt", ino: 6),
                                                                    item("b.txt", ino: 7)])),
                              refreshAfter: false))
        XCTAssertEqual(job.apply(.refresh(token: 1)), .none)
        guard case .walking(_, let after) = job.state else {
            return XCTFail("expected walking, got \(job.state)")
        }
        XCTAssertTrue(after)
        XCTAssertEqual(job.apply(.refresh(token: 1)), .none, "still one refresh")

        let listing = [item("a.txt", ino: 6)]
        let record = byID([item("a.txt", ino: 6), item("b.txt", ino: 7)])
        let action = job.apply(.lastPage(token: 1, items: listing, digest: "d2",
                                         record: record, idMap: FilesIdMap(), uploading: [], uploadNames: []))
        guard case .report(_, _, let digest, let dropped) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertEqual(digest, "d2")
        XCTAssertEqual(dropped, [])
        XCTAssertEqual(job.state, .refreshing(again: true, token: 1),
                       "the push that arrived during the walk gets one refresh")
    }

    // MARK: Confirmation

    func testABigDeletionConfirmsFirstThenReportsTheAgreedOnes() {
        let record = byID((100..<130).map { item("f\($0).txt", ino: $0) })
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: record.count, start: record, token: 1))
        let first = (125..<130).map { item("f\($0).txt", ino: $0) }
        XCTAssertEqual(job.apply(.lastPage(token: 1, items: first, digest: "d1",
                                           record: record, idMap: FilesIdMap(), uploading: [], uploadNames: [])),
                       .scheduleConfirm)
        guard case .confirming(let walk, _, true) = job.state else {
            return XCTFail("expected a waiting confirmation, got \(job.state)")
        }
        XCTAssertEqual(walk.pages.count, 5, "the first walk's pages are kept until the confirm")

        XCTAssertEqual(job.apply(.confirmDue(token: 1)), .start)
        guard case .confirming(let cleared, _, false) = job.state else {
            return XCTFail("expected a running confirmation, got \(job.state)")
        }
        XCTAssertTrue(cleared.pages.isEmpty, "the confirmation starts its own listing")
        XCTAssertEqual(job.apply(.confirmDue(token: 1)), .none, "one confirmation")

        // The confirm sees 6: the 25 agreed deletions plus f124 which came back.
        let second = (124..<130).map { item("f\($0).txt", ino: $0) }
        let action = job.apply(.lastPage(token: 1, items: second, digest: "d2",
                                         record: record, idMap: FilesIdMap(), uploading: [], uploadNames: []))
        guard case .report(let delta, _, let digest, _) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertEqual(Set(delta.deleted), Set((100..<124).map { "ino:\($0)" }))
        XCTAssertEqual(digest, "d2")
        XCTAssertEqual(job.state, .idle)
    }

    func testTheConfirmationKeepsTheWalksStartRecord() {
        let f = (100..<130).map { item("f\($0).txt", ino: $0) }
        let start = byID(f + [item("a.txt", ino: 6)])
        // The record gained new metadata for a.txt after the walk began.
        let record = byID(f + [item("a.txt", ino: 6, mtime: 99, etag: "bb")])
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: record.count, start: start, token: 1))
        let first = (125..<130).map { item("f\($0).txt", ino: $0) }
        XCTAssertEqual(job.apply(.lastPage(token: 1, items: first, digest: nil,
                                           record: record, idMap: FilesIdMap(), uploading: [], uploadNames: [])),
                       .scheduleConfirm)
        _ = job.apply(.confirmDue(token: 1))
        let action = job.apply(.lastPage(token: 1, items: first, digest: nil,
                                         record: record, idMap: FilesIdMap(), uploading: [], uploadNames: []))
        guard case .report(let delta, _, _, _) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertFalse(delta.deleted.contains("ino:6"),
                       "the item a Mac write changed during the walk is not deleted")
    }

    func testASmallDeletionReportsAtOnce() {
        let record = byID((100..<110).map { item("f\($0).txt", ino: $0) })
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: record.count, start: record, token: 1))
        let action = job.apply(.lastPage(token: 1, items: (105..<110).map { item("f\($0).txt", ino: $0) },
                                         digest: nil, record: record, idMap: FilesIdMap(), uploading: [], uploadNames: []))
        guard case .report(let delta, _, _, _) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertEqual(Set(delta.deleted), Set((100..<105).map { "ino:\($0)" }))
        XCTAssertEqual(job.state, .idle)
    }

    // MARK: The guards

    func testAnUploadInFlightOrANameUnderUploadIsNotDeleted() {
        let record = byID([item("a.jpg", ino: 6), item("b.jpg", ino: 7), item("c.jpg", ino: 8)])
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: 3, start: record, token: 1))
        let action = job.apply(.lastPage(token: 1, items: [], digest: nil, record: record,
                                         idMap: FilesIdMap(), uploading: ["ino:6"], uploadNames: ["b.jpg"]))
        guard case .report(let delta, let listing, _, _) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertEqual(delta.deleted, ["ino:8"], "only the untouched item is deleted")
        _ = listing
    }

    func testAnItemTheIdMapPlacesElsewhereIsNotDeleted() {
        let record = byID([item("a.txt", ino: 6), item("b.txt", ino: 7)])
        var map = FilesIdMap()
        map.remember(identifier: "ino:6", path: "D/a.txt", parentIdentifier: "ino:20")
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: 2, start: record, token: 1))
        let action = job.apply(.lastPage(token: 1, items: [], digest: nil, record: record,
                                         idMap: map, uploading: [], uploadNames: []))
        guard case .report(let delta, _, _, let dropped) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertEqual(dropped, ["ino:6"], "the moved item leaves the old folder's record")
        XCTAssertEqual(delta.deleted, ["ino:7"], "and is not reported deleted")
    }

    func testAFailedWalkNeverDeletes() {
        let record = byID((100..<110).map { item("f\($0).txt", ino: $0) })
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: record.count, start: record, token: 1))
        let action = job.apply(.failedPage(token: 1, record: record, recordDigest: "d0", idMap: FilesIdMap(),
                                           uploading: [], uploadNames: []))
        guard case .report(let delta, let listing, let digest, _) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertEqual(delta.deleted, [])
        XCTAssertEqual(Set(listing.map(\.identifier)), Set(record.keys),
                       "the record keeps every item the walk never saw")
        XCTAssertEqual(digest, "d0", "an incomplete walk keeps the record's digest")
        XCTAssertEqual(job.state, .idle)
    }

    func testAFailedConfirmationDeletesNothing() throws {
        let record = byID((100..<130).map { item("f\($0).txt", ino: $0) })
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: record.count, start: record, token: 1))
        XCTAssertEqual(job.apply(.lastPage(token: 1, items: [], digest: nil, record: record,
                                           idMap: FilesIdMap(), uploading: [], uploadNames: [])), .scheduleConfirm)
        _ = job.apply(.confirmDue(token: 1))
        let action = job.apply(.failedPage(token: 1, record: record, recordDigest: "d1", idMap: FilesIdMap(),
                                           uploading: [], uploadNames: []))
        guard case .report(let delta, _, _, _) = action else {
            return XCTFail("expected a report, got \(action)")
        }
        XCTAssertEqual(delta.deleted, [])
    }

    // MARK: Repair

    func testANotFoundStartsARepairAndRepeatsAreIgnored() {
        var job = FolderJob(folder: folder)
        XCTAssertEqual(job.apply(.notFound(recorded: 3, start: [:], token: 1)), .start)
        guard case .repairing(let walk, let after) = job.state else {
            return XCTFail("expected repairing, got \(job.state)")
        }
        XCTAssertFalse(after)
        XCTAssertEqual(job.apply(.notFound(recorded: 3, start: [:], token: 1)), .none)
        XCTAssertEqual(job.state, .repairing(walk, refreshAfter: false),
                       "one repair re-list is enough")

        // A not-found while another pass runs becomes one refresh after it.
        var walking = self.job(.walking(makeWalk(recorded: 0), refreshAfter: false))
        XCTAssertEqual(walking.apply(.notFound(recorded: 0, start: [:], token: 1)), .none)
        guard case .walking(_, let pending) = walking.state else {
            return XCTFail("expected walking, got \(walking.state)")
        }
        XCTAssertTrue(pending)
        XCTAssertEqual(walking.apply(.notFound(recorded: 0, start: [:], token: 1)), .none)
    }

    // MARK: Drop and late callbacks

    func testADropEndsEveryPhase() {
        let phases: [FolderJob.State] = [
            .idle,
            .walking(makeWalk(recorded: 1), refreshAfter: false),
            .walking(makeWalk(recorded: 1), refreshAfter: true),
            .confirming(makeWalk(recorded: 1), refreshAfter: false, waiting: true),
            .confirming(makeWalk(recorded: 1), refreshAfter: false, waiting: false),
            .repairing(makeWalk(recorded: 1), refreshAfter: true),
            .refreshing(again: false, token: 1),
            .refreshing(again: true, token: 1),
        ]
        for state in phases {
            var job = self.job(state)
            XCTAssertEqual(job.apply(.dropped), .none, "\(state)")
            XCTAssertEqual(job.state, .idle, "\(state)")
        }
    }

    func testALatePageFromAnotherRunChangesNothing() {
        var job = self.job(.walking(makeWalk(recorded: 2, start: byID([item("a.txt", ino: 6),
                                                                    item("b.txt", ino: 7)])),
                              refreshAfter: false))
        let before = job.state
        XCTAssertEqual(job.apply(.page(token: 2, items: [item("c.txt", ino: 8)], next: "p2")),
                       .none)
        XCTAssertEqual(job.state, before)
        XCTAssertEqual(job.apply(.lastPage(token: 2, items: [], digest: nil,
                                           record: [:], idMap: FilesIdMap(), uploading: [], uploadNames: [])), .none)
        XCTAssertEqual(job.apply(.failedPage(token: 2, record: [:], recordDigest: nil, idMap: FilesIdMap(),
                                             uploading: [], uploadNames: [])), .none)
        XCTAssertEqual(job.state, before, "the current walk is untouched")

        // A timer from the old run is ignored too.
        var confirming = self.job(.confirming(makeWalk(recorded: 0, token: 1), refreshAfter: false, waiting: true))
        XCTAssertEqual(confirming.apply(.confirmDue(token: 2)), .none)
        var refreshing = self.job(.refreshing(again: false, token: 1))
        XCTAssertEqual(refreshing.apply(.refreshDue(token: 2, recorded: 0, start: [:])), .none)
    }

    // MARK: Pages

    func testASystemWalkOnlyTakesItsOwnCursor() {
        var job = FolderJob(folder: folder)
        _ = job.apply(.systemStart(recorded: 0, start: [:], token: 1))
        XCTAssertEqual(job.systemPageToken(nil), 1)
        XCTAssertEqual(job.systemPageToken("p1"), nil, "no page has been answered yet")
        XCTAssertEqual(job.apply(.page(token: 1, items: [], next: "p2")), .none)
        XCTAssertEqual(job.systemPageToken("p2"), 1)
        XCTAssertEqual(job.systemPageToken("p3"), nil, "another read's cursor")

        var host = self.job(.walking(makeWalk(recorded: 0), refreshAfter: false))
        XCTAssertNil(host.systemPageToken("p2"), "the app walk is not the system's")
    }

    func testAWalkKeepsItsPagesAcrossPages() {
        var job = self.job(.walking(makeWalk(recorded: 0), refreshAfter: false))
        _ = job.apply(.page(token: 1, items: [item("a.txt", ino: 6)], next: "p2"))
        _ = job.apply(.page(token: 1, items: [item("b.txt", ino: 7)], next: "p3"))
        guard case .walking(let walk, _) = job.state else {
            return XCTFail("expected walking, got \(job.state)")
        }
        XCTAssertEqual(Set(walk.pages.keys), ["ino:6", "ino:7"])
    }

    // MARK: Ignored events

    func testEventsOutOfPhaseAreIgnored() {
        var idle = FolderJob(folder: folder)
        XCTAssertEqual(idle.apply(.confirmDue(token: 1)), .none)
        XCTAssertEqual(idle.apply(.refreshDue(token: 1, recorded: 0, start: [:])), .none)
        XCTAssertEqual(idle.apply(.page(token: 1, items: [], next: "p")), .none)
        XCTAssertEqual(idle.apply(.lastPage(token: 1, items: [], digest: nil, record: [:],
                                            idMap: FilesIdMap(), uploading: [], uploadNames: [])), .none)
        XCTAssertEqual(idle.apply(.failedPage(token: 1, record: [:], recordDigest: nil, idMap: FilesIdMap(),
                                              uploading: [], uploadNames: [])), .none)
        XCTAssertEqual(idle.state, .idle)

        var walking = self.job(.walking(makeWalk(recorded: 0), refreshAfter: false))
        let before = walking.state
        XCTAssertEqual(walking.apply(.visit(recorded: 0, start: [:], token: 1)), .none)
        XCTAssertEqual(walking.apply(.confirmDue(token: 1)), .none)
        XCTAssertEqual(walking.apply(.refreshDue(token: 1, recorded: 0, start: [:])), .none)
        XCTAssertEqual(walking.state, before, "a running walk ignores touches and timers")

        var refreshing = self.job(.refreshing(again: false, token: 1))
        XCTAssertEqual(refreshing.apply(.visit(recorded: 0, start: [:], token: 1)), .none)
        XCTAssertEqual(refreshing.apply(.page(token: 1, items: [], next: "p")), .none)
        XCTAssertEqual(refreshing.state, .refreshing(again: false, token: 1))
    }
}
