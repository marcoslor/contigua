// MCP-20: the per-window frame clock — the count of complete video access
// units and the age of the newest (docs/specs/mcp.md "Freshness").

import XCTest
@testable import Contigua

final class FrameClockTests: XCTestCase {

    // [MCP-20]
    func testSeqCountsAccessUnitsAndAgeIsSinceArrival() {
        var clock = FrameClock()
        // A fresh clock: seq 0, no age.
        XCTAssertEqual(clock.newest, 0)
        XCTAssertNil(clock.age(now: 0))
        // Two access units arrive: the seq counts them, the age is since the
        // newest arrived.
        XCTAssertEqual(clock.received(atUptime: 10.0), 1)
        XCTAssertEqual(clock.received(atUptime: 10.5), 2)
        XCTAssertEqual(clock.newest, 2)
        XCTAssertEqual(clock.age(now: 11.0), 500)
        XCTAssertEqual(clock.age(now: 10.5), 0)
    }

    // [MCP-20]
    func testTheSeqNeverResetsAndAgeIsNonNegative() {
        var clock = FrameClock()
        _ = clock.received(atUptime: 5.0)
        XCTAssertEqual(clock.received(atUptime: 5.1), 2)
        // A stale timestamp is not a frame going backwards: the age clamps.
        XCTAssertEqual(clock.age(now: 4.0), 0)
    }
}
