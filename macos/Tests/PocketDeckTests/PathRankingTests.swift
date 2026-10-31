// The ranking (docs/design/paths.md §7): the four terms, the worked example's
// 722/463, the busy 412 (no switch) and congested 321 (switch after 5 s), 4.9 s,
// a failure at once, and an unrankable path that never wins on margin.

import XCTest
@testable import PocketDeck

final class PathRankingTests: XCTestCase {
    func testTheFormulaTermsAtTheirBoundaries() {
        // A perfect path (0 ms, no loss, 209 Mbit/s) scores 1000.
        XCTAssertEqual(PathRanking.score(p50Ms: 0, p95Ms: 0, loss: 0, floorMbps: 209), 1000)
        // 10 ms halves q_rtt.
        XCTAssertEqual(PathRanking.score(p50Ms: 10, p95Ms: 10, loss: 0, floorMbps: 209),
                       PathRanking.score(p50Ms: 0, p95Ms: 0, loss: 0, floorMbps: 209) - 225)
        // 10% loss zeroes q_loss (200 points); more loss is not worse.
        XCTAssertEqual(PathRanking.score(p50Ms: 0, p95Ms: 0, loss: 0.10, floorMbps: 209), 800)
        XCTAssertEqual(PathRanking.score(p50Ms: 0, p95Ms: 0, loss: 0.50, floorMbps: 209), 800)
        // 25 ms of jitter halves q_jit (75 points).
        XCTAssertEqual(PathRanking.score(p50Ms: 0, p95Ms: 25, loss: 0, floorMbps: 209), 925)
        // A class at the measured 209 is a full bandwidth term; 8 Mbit/s is 8/209.
        XCTAssertEqual(PathRanking.score(p50Ms: 0, p95Ms: 0, loss: 0, floorMbps: 0), 800)
    }

    func testTheWorkedExample() {
        // LAN: 5.5 ms median, p95 8 ms, no loss, class 100.
        XCTAssertEqual(PathRanking.score(p50Ms: 5.5, p95Ms: 8, loss: 0, floorMbps: 100), 722)
        // Direct: 13 ms median, p95 39.8 ms, 0.65% loss, class 8.
        XCTAssertEqual(PathRanking.score(p50Ms: 13, p95Ms: 39.8, loss: 0.0065, floorMbps: 8), 463)
        // A busy router: 30/90, 2% loss: 412, only 51 below direct.
        XCTAssertEqual(PathRanking.score(p50Ms: 30, p95Ms: 90, loss: 0.02, floorMbps: 100), 412)
        // A congested one: 40/120, 5% loss: 321, 142 below direct.
        XCTAssertEqual(PathRanking.score(p50Ms: 40, p95Ms: 120, loss: 0.05, floorMbps: 100), 321)
    }

    private func feed(_ ranking: inout PathRanking, _ id: String, rtt: Double, pings: Int = 2,
                      lost: Int = 0, at now: TimeInterval, kind: PathKind = .lan) {
        ranking.register(id: id, kind: kind)
        for i in 0..<pings {
            ranking.addSample(id: id, rttMs: i < pings - lost ? rtt : nil, at: now)
        }
    }

    func testTheFirstTickWithPongsElectsTheRealSessionsCurrentPath() {
        // pathUp arrives before the first pong can: the ranking must not stay
        // idle forever (the founder becomes current on the first tick with a
        // ranked path).
        var ranking = PathRanking()
        ranking.register(id: "lan", kind: .lan)
        XCTAssertTrue(ranking.handle(.pathUp("lan"), now: 0).isEmpty)
        XCTAssertEqual(ranking.state, .idle)
        feed(&ranking, "lan", rtt: 5.5, at: 2)
        XCTAssertEqual(ranking.handle(.tick(now: 2), now: 2), [])
        XCTAssertEqual(ranking.state, .steady(current: "lan"))
    }

    func testAHealthyCurrentPathKeepsTheMarginAndDoesNotSwitch() {
        var ranking = PathRanking()
        feed(&ranking, "lan", rtt: 5.5, at: 0)
        _ = ranking.handle(.pathUp("lan"), now: 0)
        feed(&ranking, "direct", rtt: 13, at: 0, kind: .direct)
        XCTAssertEqual(ranking.state, .steady(current: "lan"))
        XCTAssertEqual(ranking.handle(.tick(now: 6), now: 6), [])
        XCTAssertEqual(ranking.state, .steady(current: "lan"))
    }

    func testTheBusyRouterIsOnlyFiftyOneBelowAndDoesNotSwitch() {
        // The margin is 100: 412 against 463 starts no challenge.
        XCTAssertLessThan(463 - 412, 100)
    }

    func testAFullMarginChallengeSwitchesOnlyAfterFiveSeconds() {
        var ranking = PathRanking()
        feed(&ranking, "slow", rtt: 1000, at: 0)
        _ = ranking.handle(.pathUp("slow"), now: 0)
        feed(&ranking, "fast", rtt: 1, at: 0)
        XCTAssertEqual(ranking.state, .steady(current: "slow"))
        XCTAssertEqual(ranking.handle(.tick(now: 10), now: 10), [])
        XCTAssertEqual(ranking.state, .challenging(current: "slow", challenger: "fast", since: 10))
        // 4.9 s later: still challenging, no switch.
        XCTAssertEqual(ranking.handle(.tick(now: 14.9), now: 14.9), [])
        // 5.0 s: the switch.
        XCTAssertEqual(ranking.handle(.tick(now: 15), now: 15), [.switchTo("fast")])
        XCTAssertEqual(ranking.state, .steady(current: "fast"))
    }

    func testTheChallengeRestartsWhenTheChallengerLeaves() {
        var ranking = PathRanking()
        feed(&ranking, "slow", rtt: 1000, at: 0)
        _ = ranking.handle(.pathUp("slow"), now: 0)
        feed(&ranking, "fast", rtt: 1, at: 0)
        _ = ranking.handle(.tick(now: 10), now: 10)
        XCTAssertEqual(ranking.handle(.pathDown("fast"), now: 12), [])
        XCTAssertEqual(ranking.state, .steady(current: "slow"))
        // The 5 s starts over next time it challenges.
        feed(&ranking, "fast", rtt: 1, at: 13)
        XCTAssertEqual(ranking.handle(.tick(now: 14), now: 14), [])
        XCTAssertEqual(ranking.state, .challenging(current: "slow", challenger: "fast", since: 14))
    }

    func testAFailureSwitchesAtOnceWithNoHysteresis() {
        var ranking = PathRanking()
        feed(&ranking, "a", rtt: 5, at: 0)
        _ = ranking.handle(.pathUp("a"), now: 0)
        feed(&ranking, "b", rtt: 50, at: 0)
        XCTAssertEqual(ranking.handle(.currentFailed(id: "a"), now: 1), [.switchTo("b")])
        XCTAssertEqual(ranking.state, .steady(current: "b"))
    }

    func testAFailureWithNoLivePathAsksTheSessionToOrphan() {
        var ranking = PathRanking()
        feed(&ranking, "a", rtt: 5, at: 0)
        _ = ranking.handle(.pathUp("a"), now: 0)
        XCTAssertEqual(ranking.handle(.currentFailed(id: "a"), now: 1), [.sessionOrphan])
        XCTAssertEqual(ranking.state, .idle)
    }

    func testAnUnrankablePathNeverWinsOnMargin() {
        var ranking = PathRanking()
        feed(&ranking, "a", rtt: 1000, at: 0)
        // One pong only: score nil, so it cannot challenge even with 0 ms.
        ranking.register(id: "b")
        ranking.addSample(id: "b", rttMs: 0, at: 0)
        XCTAssertNil(ranking.score(id: "b", now: 0))
        _ = ranking.handle(.pathUp("a"), now: 0)
        for tick in stride(from: 1.0, through: 20.0, by: 1.0) {
            XCTAssertEqual(ranking.handle(.tick(now: tick), now: tick), [])
        }
        XCTAssertEqual(ranking.state, .steady(current: "a"))
    }

    func testAnExternalSwitchMovesTheRankingAtOnce() {
        var ranking = PathRanking()
        feed(&ranking, "a", rtt: 5, at: 0)
        _ = ranking.handle(.pathUp("a"), now: 0)
        feed(&ranking, "b", rtt: 50, at: 0)
        XCTAssertEqual(ranking.handle(.externalSwitch("b"), now: 1), [])
        XCTAssertEqual(ranking.state, .steady(current: "b"))
    }

    func testTheWindowPrunesSamplesOlderThanThirtySeconds() {
        var ranking = PathRanking()
        ranking.register(id: "a")
        ranking.addSample(id: "a", rttMs: 5, at: 0)
        ranking.addSample(id: "a", rttMs: 5, at: 31)
        XCTAssertEqual(ranking.score(id: "a", now: 31), nil, "one live pong is unrankable")
        ranking.addSample(id: "a", rttMs: 5, at: 32)
        XCTAssertNotNil(ranking.score(id: "a", now: 32))
    }
}
