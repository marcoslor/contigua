// The switch's marker order (docs/design/paths.md §5.4, PATH-5/9): a planned
// switch's marker is the last frame on the old path, an unplanned one's the
// first on the new, and one keyframe request per open stream follows.

import XCTest
@testable import Contigua

final class PathSwitchTests: XCTestCase {
    func testAPlannedSwitchSendsTheMarkerLastOnTheOldPath() {
        let plan = PathSwitch.plan(kind: .planned, from: "aaa", to: "bbb",
                                   nextSeq: 42, streams: [1, 2])
        XCTAssertEqual(plan, [
            .marker(path: "aaa", seq: 42),
            .replayFromLastAck,
            .requestKeyframe(stream: 1),
            .requestKeyframe(stream: 2),
            .closePath("aaa"),
        ])
        XCTAssertEqual(plan.first, .marker(path: "aaa", seq: 42))
    }

    func testAnUnplannedSwitchSendsTheMarkerFirstOnTheNewPath() {
        let plan = PathSwitch.plan(kind: .unplanned, from: "aaa", to: "bbb",
                                   nextSeq: 7, streams: [3])
        XCTAssertEqual(plan.first, .marker(path: "bbb", seq: 7))
        XCTAssertEqual(plan, [
            .marker(path: "bbb", seq: 7),
            .replayFromLastAck,
            .requestKeyframe(stream: 3),
            .closePath("aaa"),
        ])
    }

    func testAMarkerForAnUnknownPathIsIgnored() {
        XCTAssertTrue(PathSwitch.accepts(marker: "aaa", live: ["aaa", "bbb"]))
        XCTAssertFalse(PathSwitch.accepts(marker: "ccc", live: ["aaa", "bbb"]))
    }

    func testOneKeyframeRequestPerOpenStreamAndNoneWithNoStreams() {
        let none = PathSwitch.plan(kind: .planned, from: "a", to: "b", nextSeq: 1, streams: [])
        XCTAssertEqual(none.filter { if case .requestKeyframe = $0 { return true }; return false }.count, 0)
        let three = PathSwitch.plan(kind: .unplanned, from: "a", to: "b", nextSeq: 1,
                                    streams: [9, 8, 7])
        XCTAssertEqual(three.filter { if case .requestKeyframe = $0 { return true }; return false }.count, 3)
    }
}
