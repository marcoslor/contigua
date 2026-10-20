// The watch set behind "S5 round 3": a folder stays watched on the phone for
// ten minutes after the last touch, at most 64 folders, least recently touched
// dropped first. Time is injected, so no test waits.

import Foundation
import XCTest
@testable import PocketDeck

final class FilesWatchSetTests: XCTestCase {
    func testTheDefaultsAreTheDesignsCapAndAPositiveTtl() {
        let set = FilesWatchSet()
        XCTAssertEqual(64, FilesWatchSet.capacity)
        XCTAssertEqual(64, set.capacity)
        XCTAssertGreaterThan(set.ttl, 0)
        XCTAssertLessThanOrEqual(set.ttl, 600, "the TTL may only be shortened, never raised")
    }

    func testATouchAddsAndARefreshKeepsTheFolder() {
        var set = FilesWatchSet(capacity: 4, ttl: 10)
        XCTAssertEqual(.added(evicted: nil), set.touch("A", now: 0))
        XCTAssertEqual(.refreshed, set.touch("A", now: 6))
        XCTAssertEqual(1, set.count)
        XCTAssertEqual(6, set.lastTouch(of: "A"))
        XCTAssertTrue(set.isWatched("A"))
    }

    func testAFolderExpiresTenMinutesAfterItsLastTouch() {
        var set = FilesWatchSet(capacity: 4, ttl: 10)
        set.touch("A", now: 0)
        XCTAssertEqual([], set.expire(now: 9.9))
        XCTAssertEqual(["A"], set.expire(now: 10))
        XCTAssertFalse(set.isWatched("A"))
        XCTAssertEqual(0, set.count)
    }

    func testARefreshRestartsTheTenMinutes() {
        var set = FilesWatchSet(capacity: 4, ttl: 10)
        set.touch("A", now: 0)
        set.touch("A", now: 8)
        XCTAssertEqual([], set.expire(now: 16))
        XCTAssertEqual(["A"], set.expire(now: 18))
    }

    func testOnlyTheExpiredOnesGoOldestFirst() {
        var set = FilesWatchSet(capacity: 4, ttl: 10)
        set.touch("A", now: 0)
        set.touch("B", now: 5)
        XCTAssertEqual(["A"], set.expire(now: 12))
        XCTAssertEqual(["B"], set.watched)
    }

    func testTheSixtyFifthFolderDropsTheLeastRecentlyTouched() {
        var set = FilesWatchSet(capacity: 3, ttl: 10)
        set.touch("A", now: 0)
        set.touch("B", now: 1)
        set.touch("C", now: 2)
        // Re-touching A makes B the oldest.
        set.touch("A", now: 3)
        XCTAssertEqual(.added(evicted: "B"), set.touch("D", now: 4))
        XCTAssertEqual(Set(["A", "C", "D"]), Set(set.watched))
        // The 65th (here the 4th) drops the least recently touched: C.
        XCTAssertEqual(.added(evicted: "C"), set.touch("E", now: 5))
        XCTAssertEqual(Set(["A", "D", "E"]), Set(set.watched))
    }

    func testTheDefaultCapIsSixtyFourFolders() {
        var set = FilesWatchSet(ttl: 600)
        for index in 0..<64 { set.touch("ino:\(index + 1)", now: Double(index)) }
        XCTAssertEqual(64, set.count)
        XCTAssertEqual(.added(evicted: "ino:1"), set.touch("ino:65", now: 100))
        XCTAssertEqual(64, set.count)
        XCTAssertFalse(set.isWatched("ino:1"))
        XCTAssertTrue(set.isWatched("ino:65"))
    }

    func testRemainingIsWhatTheTimerNeeds() {
        var set = FilesWatchSet(capacity: 4, ttl: 10)
        set.touch("A", now: 4)
        XCTAssertEqual(10, set.remaining("A", now: 4))
        XCTAssertEqual(0, set.remaining("A", now: 20))
        XCTAssertNil(set.remaining("B", now: 4))
    }

    func testRemoveAndRemoveAll() {
        var set = FilesWatchSet(capacity: 4, ttl: 10)
        set.touch("A", now: 0)
        set.touch("B", now: 0)
        set.remove("A")
        XCTAssertFalse(set.isWatched("A"))
        set.removeAll()
        XCTAssertEqual(0, set.count)
    }
}
