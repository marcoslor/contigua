// The session machine (docs/design/paths.md §6): every state/event pair, the
// ignored events, and every timer on a virtual clock.

import XCTest
@testable import PocketDeck

final class PathSessionTests: XCTestCase {
    private func machine(live: Set<String> = ["a"], current: String = "a") -> PathSessionMachine {
        PathSessionMachine(state: .live(current: current), live: live,
                           scores: Dictionary(uniqueKeysWithValues: live.map { ($0, 500) }))
    }

    func testPathUpAddsAPathAndStartsItsPing() {
        var machine = machine()
        let actions = machine.handle(.pathUp(id: "b", joined: true), now: 10)
        XCTAssertEqual(machine.state, .live(current: "a"))
        XCTAssertTrue(machine.live.contains("b"))
        XCTAssertEqual(actions, [.startPing(path: "b"), .ranking(.pathUp("b"))])
    }

    func testASecondPathUpForALivePathClosesTheSecondSocket() {
        var machine = machine()
        XCTAssertEqual(machine.handle(.pathUp(id: "a", joined: true), now: 10),
                       [.closePath(path: "a")])
    }

    func testAPathUpAfterTheEndIsIgnored() {
        var machine = PathSessionMachine(state: .ended(reason: "close"))
        XCTAssertEqual(machine.handle(.pathUp(id: "b", joined: false), now: 1), [.ignore])
    }

    func testAPlannedPeerSwitchMigratesAndDrainsTheOldPath() {
        var machine = machine(live: ["a", "b"])
        let actions = machine.handle(.peerSwitch(id: "b", seq: 9, arrivedOn: "a"), now: 20)
        XCTAssertEqual(machine.state, .migrating(from: "a", to: "b", since: 20))
        XCTAssertEqual(actions, [.startPing(path: "b"), .ranking(.externalSwitch("b"))])
        // The peer's own marker completes it; the old path closes.
        XCTAssertEqual(machine.handle(.peerSwitch(id: "b", seq: 3, arrivedOn: "b"), now: 20.1),
                       [.closePath(path: "a"), .stopPing(path: "a"),
                        .ranking(.externalSwitch("b"))])
        XCTAssertEqual(machine.state, .live(current: "b"))
        XCTAssertFalse(machine.live.contains("a"))
    }

    func testAPeerSwitchArrivingOnTheNewPathIsAlreadyComplete() {
        var machine = machine(live: ["a", "b"])
        let actions = machine.handle(.peerSwitch(id: "b", seq: 9, arrivedOn: "b"), now: 3)
        XCTAssertEqual(machine.state, .live(current: "b"))
        XCTAssertEqual(actions, [.closePath(path: "a"), .stopPing(path: "a"),
                                 .startPing(path: "b"), .ranking(.externalSwitch("b"))])
    }

    func testAMarkerForAnUnknownPathIsIgnored() {
        var machine = machine()
        XCTAssertEqual(machine.handle(.peerSwitch(id: "zz", seq: 1, arrivedOn: "a"), now: 0),
                       [.ignore])
    }

    func testTheCurrentPathFailingSwitchesAtOnce() {
        var machine = machine(live: ["a", "b"])
        machine.scores = ["a": 100, "b": 900]
        let actions = machine.handle(.currentFailed(id: "a"), now: 5)
        XCTAssertEqual(machine.state, .migrating(from: "a", to: "b", since: 5))
        XCTAssertEqual(actions, [.stopPing(path: "a"), .switchTo(path: "b"),
                                 .replayFromLastAck, .requestKeyframes,
                                 .startPing(path: "b"), .ranking(.currentFailed(id: "a"))])
    }

    func testCurrentFailedWithNoOtherPathOrphansAndSaysReconnecting() {
        var machine = machine()
        let actions = machine.handle(.currentFailed(id: "a"), now: 7)
        XCTAssertEqual(machine.state, .orphaned(since: 7))
        XCTAssertTrue(actions.contains(.markReconnecting))
        XCTAssertFalse(actions.contains(.switchTo(path: "a")))
    }

    /// PATH-7: the 1.5 s rule is for two or more paths. On the only path a
    /// lost pong is a ranking sample, not a failure: no switch, no reconnect.
    func testOneLostPongOnTheOnlyPathStaysLive() {
        var machine = machine()
        XCTAssertEqual(machine.handle(.pongLost(id: "a"), now: 2), [])
        XCTAssertEqual(machine.state, .live(current: "a"))
        XCTAssertTrue(machine.live.contains("a"))
        // A socket error still fails the only path (the rule is the pong's).
        XCTAssertEqual(machine.handle(.currentFailed(id: "a"), now: 3),
                       [.stopPing(path: "a"), .markReconnecting,
                        .ranking(.currentFailed(id: "a"))])
    }

    func testALostPongWithTwoPathsDemotesTheCurrentPath() {
        var machine = machine(live: ["a", "b"])
        machine.scores = ["a": 100, "b": 900]
        let actions = machine.handle(.pongLost(id: "a"), now: 4)
        // D-2: the silent path becomes a standby, it is not closed and it keeps
        // being pinged; the session moves to the other path at once.
        XCTAssertEqual(machine.state, .live(current: "b"))
        XCTAssertEqual(Set(["a", "b"]), machine.live)
        XCTAssertEqual(Set(["a"]), machine.standby)
        XCTAssertEqual(actions, [.switchTo(path: "b"), .replayFromLastAck,
                                 .requestKeyframes, .ranking(.externalSwitch("b"))])
        // A standby is never chosen for a failover: with no other usable path
        // the session stays where it is (the ranking may still win it back).
        XCTAssertEqual(machine.handle(.pongLost(id: "b"), now: 5), [])
        XCTAssertEqual(machine.state, .live(current: "b"))
        // A socket error on the standby drops it for good.
        XCTAssertEqual(machine.handle(.pathDown(id: "a"), now: 6), [.ranking(.pathDown("a"))])
        XCTAssertFalse(machine.live.contains("a"))
        XCTAssertFalse(machine.standby.contains("a"))
    }

    func testALostPongForAStandbyPathIsOnlyASample() {
        var machine = machine(live: ["a", "b"])
        XCTAssertEqual(machine.handle(.pongLost(id: "b"), now: 1), [])
        XCTAssertEqual(machine.state, .live(current: "a"))
    }

    func testALostPongOnTheNewPathDuringMigrationFallsBack() {
        var machine = PathSessionMachine(state: .migrating(from: "a", to: "b", since: 1),
                                         live: ["a", "b"], scores: ["a": 500, "b": 500])
        XCTAssertEqual(machine.handle(.pongLost(id: "b"), now: 2),
                       [.ranking(.externalSwitch("a"))])
        XCTAssertEqual(machine.state, .live(current: "a"))
    }

    /// Boot 6's grace: the first path failed, the drain left the migration's
    /// target as the only live path, and its pong also stopped. That is no
    /// path usable, so the grace starts (PATH-6), not a silent hang.
    func testALostPongOnTheOnlyRemainingMigrationTargetOrphans() {
        var machine = PathSessionMachine(state: .migrating(from: "a", to: "b", since: 1),
                                         live: ["b"], scores: ["b": 500])
        let actions = machine.handle(.pongLost(id: "b"), now: 4)
        XCTAssertEqual(machine.state, .orphaned(since: 4))
        XCTAssertTrue(actions.contains(.markReconnecting))
        XCTAssertFalse(actions.contains(.switchTo(path: "b")))
    }

    func testAPathDownForAnotherPathKeepsTheSessionLive() {
        var machine = machine(live: ["a", "b"])
        XCTAssertEqual(machine.handle(.pathDown(id: "b"), now: 1),
                       [.ranking(.pathDown("b"))])
        XCTAssertEqual(machine.state, .live(current: "a"))
    }

    func testTheGraceEndsTheSessionAtThirtySecondsNotBefore() {
        var machine = PathSessionMachine(state: .orphaned(since: 100), live: [])
        XCTAssertEqual(machine.handle(.graceExpired, now: 129.9), [])
        XCTAssertEqual(machine.state, .orphaned(since: 100))
        XCTAssertEqual(machine.handle(.graceExpired, now: 130), [.end(reason: "graceExpired")])
        XCTAssertEqual(machine.state, .ended(reason: "graceExpired"))
    }

    func testAJoinDuringTheGraceFoundTheLiveSessionAgain() {
        var machine = PathSessionMachine(state: .orphaned(since: 0), live: [])
        let actions = machine.handle(.pathUp(id: "b", joined: true), now: 12)
        XCTAssertEqual(machine.state, .live(current: "b"))
        XCTAssertEqual(actions, [.switchTo(path: "b"), .replayFromLastAck,
                                 .requestKeyframes, .startPing(path: "b"),
                                 .ranking(.pathUp("b"))])
    }

    func testPathDownDuringTheGraceStaysOrphaned() {
        var machine = PathSessionMachine(state: .orphaned(since: 1), live: [])
        XCTAssertEqual(machine.handle(.pathDown(id: "a"), now: 2), [.ranking(.pathDown("a"))])
        XCTAssertEqual(machine.state, .orphaned(since: 1))
    }

    func testTheDrainBackstopClosesTheOldPathAndStaysMigrating() {
        var machine = machine(live: ["a", "b"])
        machine.handle(.peerSwitch(id: "b", seq: 1, arrivedOn: "a"), now: 0)
        let actions = machine.handle(.drainExpired, now: 2)
        XCTAssertEqual(actions, [.closePath(path: "a"), .stopPing(path: "a")])
        XCTAssertEqual(machine.state, .migrating(from: "a", to: "b", since: 0))
        XCTAssertFalse(machine.live.contains("a"))
    }

    func testTheNewPathFailingDuringMigrationFallsBackToTheOldOne() {
        var machine = machine(live: ["a", "b"])
        machine.handle(.peerSwitch(id: "b", seq: 1, arrivedOn: "a"), now: 0)
        XCTAssertEqual(machine.handle(.pathDown(id: "b"), now: 1),
                       [.ranking(.externalSwitch("a"))])
        XCTAssertEqual(machine.state, .live(current: "a"))
    }

    func testTheNewPathFailingWithNothingElseOrphans() {
        var machine = machine(live: ["a", "b"])
        machine.handle(.peerSwitch(id: "b", seq: 1, arrivedOn: "a"), now: 0)
        machine.live.remove("a")
        let actions = machine.handle(.pathDown(id: "b"), now: 1)
        XCTAssertEqual(machine.state, .orphaned(since: 1))
        XCTAssertTrue(actions.contains(.markReconnecting))
    }

    func testCloseEndsEveryLiveState() {
        for state in [PathSessionState.live(current: "a"),
                      .migrating(from: "a", to: "b", since: 0),
                      .orphaned(since: 0)] {
            var machine = PathSessionMachine(state: state, live: ["a", "b"])
            XCTAssertEqual(machine.handle(.close(reason: "person"), now: 0),
                           [.end(reason: "person")])
            XCTAssertEqual(machine.state, .ended(reason: "person"))
        }
    }

    func testTheEndedStateIgnoresEverything() {
        var machine = PathSessionMachine(state: .ended(reason: "x"))
        for event: PathSessionEvent in [.pathDown(id: "a"), .currentFailed(id: "a"),
                                        .peerSwitch(id: "b", seq: 1, arrivedOn: "a"),
                                        .graceExpired, .drainExpired, .close(reason: "y")] {
            XCTAssertEqual(machine.handle(event, now: 99), [.ignore])
        }
    }

    func testTheMachineLogsOnlyClosedTokens() {
        var machine = machine()
        XCTAssertEqual(machine.description, "live a")
        machine.handle(.currentFailed(id: "a"), now: 1)
        XCTAssertEqual(machine.description, "orphaned")
    }
}
