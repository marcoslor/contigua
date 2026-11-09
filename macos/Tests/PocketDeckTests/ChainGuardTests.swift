import XCTest
@testable import PocketDeck

/// WIN-61: after any break the feed holds every delta until a keyframe, asks
/// the phone once and again 500 ms later, and logs the break and the restore.
final class ChainGuardTests: XCTestCase {
    private func awaiting(_ reason: ChainGuard.Reason, since: TimeInterval,
                          retried: Bool = false) -> ChainGuard.State {
        .awaitingKey(reason, since: since, retried: retried)
    }

    func testAFlowingChainFeedsBothKindsOfFrame() {
        var chain = ChainGuard()
        XCTAssertEqual(chain.handle(.sample(isKeyframe: false, now: 0)), [.feed])
        XCTAssertEqual(chain.handle(.sample(isKeyframe: true, now: 0.016)), [.feed])
        XCTAssertEqual(chain.state, .flowing)
        XCTAssertFalse(chain.isAwaitingKey)
    }

    func testABreakAsksForOneKeyframeAndSchedulesTheRetry() {
        var chain = ChainGuard()
        XCTAssertEqual(chain.handle(.breakChain(.config, now: 1)),
                       [.logBroken(.config), .requestKeyframe, .scheduleRetry])
        XCTAssertEqual(chain.state, awaiting(.config, since: 1))
        XCTAssertTrue(chain.isAwaitingKey)
    }

    func testNoDeltaIsFedWhileAwaitingAKey() {
        var chain = ChainGuard()
        _ = chain.handle(.breakChain(.flush, now: 1))
        XCTAssertEqual(chain.handle(.sample(isKeyframe: false, now: 1.016)), [.drop])
        XCTAssertEqual(chain.handle(.sample(isKeyframe: false, now: 1.032)), [.drop])
        XCTAssertEqual(chain.state, awaiting(.flush, since: 1))
    }

    func testAKeyframeRestoresTheFlowAndReportsTheTimeSinceTheBreak() {
        var chain = ChainGuard()
        _ = chain.handle(.breakChain(.beforeConfig, now: 2))
        XCTAssertEqual(chain.handle(.sample(isKeyframe: true, now: 2.5)),
                       [.feed, .logRestored(afterMs: 500), .cancelRetry])
        XCTAssertEqual(chain.state, .flowing)
        XCTAssertEqual(chain.handle(.sample(isKeyframe: false, now: 2.516)), [.feed])
    }

    func testARestoreStillFeedsItsKeyframe() {
        var chain = ChainGuard()
        _ = chain.handle(.breakChain(.layerFailed, now: 0))
        // A restore must never drop its own keyframe: it is the picture.
        let actions = chain.handle(.sample(isKeyframe: true, now: 0.1))
        XCTAssertEqual(actions.first, .feed)
        XCTAssertTrue(actions.contains(.logRestored(afterMs: 100)))
    }

    func testOneRetryFiresAtHalfASecondAndAnotherIsIgnored() {
        XCTAssertEqual(ChainGuard.retryDelay, 0.5)
        var chain = ChainGuard()
        _ = chain.handle(.breakChain(.config, now: 0))
        XCTAssertEqual(chain.handle(.retryDue), [.requestKeyframe])
        XCTAssertEqual(chain.state, awaiting(.config, since: 0, retried: true))
        XCTAssertEqual(chain.handle(.retryDue), [])
        XCTAssertEqual(chain.handle(.retryDue), [])
    }

    func testARetryWithNoBreakAsksNothing() {
        var chain = ChainGuard()
        XCTAssertEqual(chain.handle(.retryDue), [])
        XCTAssertEqual(chain.state, .flowing)
    }

    func testASecondBreakWhileAwaitingRestartsTheClockAndAsksAgain() {
        var chain = ChainGuard()
        _ = chain.handle(.breakChain(.config, now: 1))
        XCTAssertEqual(chain.handle(.breakChain(.flush, now: 2)),
                       [.logBroken(.flush), .requestKeyframe, .scheduleRetry])
        XCTAssertEqual(chain.state, awaiting(.flush, since: 2))
        XCTAssertEqual(chain.handle(.sample(isKeyframe: true, now: 2.25)),
                       [.feed, .logRestored(afterMs: 250), .cancelRetry])
    }

    func testResetCancelsTheRetryAndFlowsAgain() {
        var chain = ChainGuard()
        _ = chain.handle(.breakChain(.config, now: 1))
        XCTAssertEqual(chain.handle(.reset), [.cancelRetry])
        XCTAssertEqual(chain.state, .flowing)
        XCTAssertEqual(chain.handle(.sample(isKeyframe: false, now: 2)), [.feed])
        XCTAssertEqual(chain.handle(.reset), [], "a flowing chain has nothing to cancel")
    }

    func testTheReasonTokensAreTheClosedSet() {
        XCTAssertEqual(ChainGuard.Reason.allCases.map(\.rawValue),
                       ["config", "flush", "before_config", "layer_failed"])
    }
}
