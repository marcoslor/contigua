// ISS-40's measurements: the pong clock-offset estimator, the sliding 2 s
// window, the `stats …` line's shape and the stats subscription machine.
// Every clock is passed in, so these are deterministic.

import XCTest
@testable import PocketDeck

final class StreamStatsTests: XCTestCase {
    // MARK: ClockOffsetEstimator (item 1)

    func testAFixedSetOfSamplesGivesTheKnownOffset() {
        var estimator = ClockOffsetEstimator()
        // Mac sent at 1_000_000 µs, the phone's clock is 5_000_000 µs ahead,
        // and the round trip is 20 ms: now = sent + 10 ms + offset.
        for index in 0..<4 {
            let sent = 1_000_000.0 + Double(index) * 2_000_000
            let now = sent + 10_000 + 5_000_000
            estimator.note(sentUs: sent, receivedUs: sent + 20_000,
                           phoneNowUs: now, at: Double(index))
        }
        XCTAssertEqual(estimator.offsetUs ?? -1, 5_000_000, accuracy: 1)
    }

    func testAHighRTTSampleDoesNotMoveTheEstimate() {
        var estimator = ClockOffsetEstimator()
        estimator.note(sentUs: 1_000_000, receivedUs: 1_020_000,
                       phoneNowUs: 6_010_000, at: 0) // 20 ms rtt, 5_000_000 offset
        let before = estimator.offsetUs
        // A 500 ms stall: the offset formula divides the rtt by two, so the
        // sample lands 250 ms late. The 20 ms one must stay the estimate.
        estimator.note(sentUs: 3_000_000, receivedUs: 3_500_000,
                       phoneNowUs: 8_360_000, at: 1)
        XCTAssertEqual(estimator.offsetUs, before)
    }

    func testNoSamplesHaveNoEstimate() {
        let estimator = ClockOffsetEstimator()
        XCTAssertNil(estimator.offsetUs)
    }

    func testSamplesOlderThanThirtySecondsAreDropped() {
        var estimator = ClockOffsetEstimator()
        estimator.note(sentUs: 0, receivedUs: 20_000, phoneNowUs: 5_010_000, at: 0)
        XCTAssertNotNil(estimator.offsetUs)
        estimator.note(sentUs: 40_000_000, receivedUs: 40_020_000,
                       phoneNowUs: 45_010_000, at: 31)
        XCTAssertEqual(estimator.samples.count, 1)
        XCTAssertEqual(estimator.offsetUs ?? -1, 5_000_000, accuracy: 1)
    }

    // MARK: Sliding window (item 3)

    func testFPSComesFromTheTimestamps() {
        // Twelve frames 1/60 s apart cover 11 intervals = 183.3 ms.
        let times = (0..<12).map { Double($0) / 60 }
        XCTAssertEqual(StreamStatsWindow.fps(times, covered: 0.2), 60, accuracy: 0.5)
        XCTAssertEqual(StreamStatsWindow.fps([0.0], covered: 0), 0, "no observed time says nothing")
        XCTAssertEqual(StreamStatsWindow.fps([0.0, 0.001], covered: 2), 1,
                       "a burst does not become a huge rate")
    }

    func testPercentilesUseNearestRank() {
        XCTAssertNil(StreamStatsWindow.percentile([], 0.5))
        let values = (1...100).map(Double.init)
        XCTAssertEqual(StreamStatsWindow.percentile(values, 0.50), 50)
        XCTAssertEqual(StreamStatsWindow.percentile(values, 0.95), 95)
        XCTAssertEqual(StreamStatsWindow.percentile(values, 0.99), 99)
    }

    func testTheTwoSecondWindowDropsOldSamples() {
        var window = StreamStatsWindow()
        for index in 0..<10 {
            window.noteReceived(now: Double(index) * 0.1, bytes: 100,
                                ptsUs: 0, offsetUs: nil)
        }
        window.noteReceived(now: 3.0, bytes: 100, ptsUs: 0, offsetUs: nil)
        let snapshot = window.snapshot(now: 3.0)
        XCTAssertEqual(snapshot.receivedFrames, 1, "only the 3.0 s frame is in the window")
    }

    func testAConfigChangeResetsTheWindow() {
        var window = StreamStatsWindow()
        window.noteReceived(now: 0.1, bytes: 100, ptsUs: 0, offsetUs: nil)
        window.noteReceived(now: 0.2, bytes: 100, ptsUs: 0, offsetUs: nil)
        window.noteConfig(now: 0.3)
        let snapshot = window.snapshot(now: 1.0)
        XCTAssertEqual(snapshot.receivedFrames, 0)
        XCTAssertEqual(snapshot.rxFps, 0)
        XCTAssertEqual(snapshot.macDrop, 0)
    }

    func testAFreezeIsCountedOnceHoweverLongItIs() {
        var window = StreamStatsWindow()
        window.noteEnqueued(now: 0, ptsUs: 0, offsetUs: nil)
        window.noteEnqueued(now: 0.05, ptsUs: 0, offsetUs: nil)
        // 1.2 s of silence: one freeze, 1200 ms, not one per missing frame.
        window.noteEnqueued(now: 1.25, ptsUs: 0, offsetUs: nil)
        let snapshot = window.snapshot(now: 1.3)
        XCTAssertEqual(snapshot.freezeCount, 1)
        XCTAssertEqual(snapshot.freezeMs, 1200, accuracy: 1)
    }

    func testAShortGapIsNotAFreeze() {
        var window = StreamStatsWindow()
        window.noteEnqueued(now: 0, ptsUs: 0, offsetUs: nil)
        window.noteEnqueued(now: 0.09, ptsUs: 0, offsetUs: nil)
        let snapshot = window.snapshot(now: 0.1)
        XCTAssertEqual(snapshot.freezeCount, 0)
        XCTAssertEqual(snapshot.freezeMs, 0)
    }

    func testAPausedSpanIsNotAFreeze() {
        var window = StreamStatsWindow()
        window.noteEnqueued(now: 0, ptsUs: 0, offsetUs: nil)
        window.notePaused(true, now: 0.02)
        window.notePaused(false, now: 3.0)
        window.noteEnqueued(now: 3.1, ptsUs: 0, offsetUs: nil)
        let snapshot = window.snapshot(now: 3.2)
        XCTAssertEqual(snapshot.freezeCount, 0)
        XCTAssertEqual(snapshot.freezeMs, 0)
    }

    func testMacDropsAreCountedByReasonInTheWindow() {
        var window = StreamStatsWindow()
        window.noteDiscarded(.beforeConfig, now: 0.1)
        window.noteDiscarded(.flush, now: 0.2)
        window.noteDiscarded(.notReady, now: 0.3)
        XCTAssertEqual(window.snapshot(now: 0.4).macDrop, 3)
        XCTAssertEqual(window.snapshot(now: 3.0).macDrop, 0, "older than the window")
    }

    func testCaptureDelayNeedsAnOffset() {
        var window = StreamStatsWindow()
        window.noteReceived(now: 1.0, bytes: 10, ptsUs: 500_000, offsetUs: nil)
        XCTAssertNil(window.snapshot(now: 1.0).e2eP50Ms)
        window.noteConfig(now: 1.0)
        window.noteReceived(now: 1.0, bytes: 10, ptsUs: 500_000, offsetUs: 400_000)
        // pts 0.5 s minus 0.4 s offset = 0.1 s Mac time; 1.0 s now = 900 ms.
        XCTAssertEqual(window.snapshot(now: 1.0).e2eP50Ms ?? -1, 900, accuracy: 0.5)
    }

    // MARK: The line (item 4)

    func testTheLogLineHasEveryFieldAndDashForMissingValues() {
        var window = StreamStatsWindow()
        window.noteReceived(now: 1.0, bytes: 1000, ptsUs: 0, offsetUs: nil)
        window.noteEnqueued(now: 1.0, ptsUs: 0, offsetUs: nil)
        var phone = PhoneStreamStats(json: [:])
        phone.targetBps = 8_000_000
        window.notePhoneStats(phone)
        let line = StreamStatsLine.text(stream: 7,
                                        size: CGSize(width: 1232, height: 2410),
                                        view: CGSize(width: 2464, height: 4820),
                                        place: "oneToOne",
                                        stats: window.snapshot(now: 1.0))
        for field in ["stats stream=7", "size=1232x2410", "view=2464x4820",
                      "place=oneToOne", "rx_fps=", "shown_fps=", "int_p95=",
                      "int_p99=", "freeze_n=0", "freeze_ms=0", "mac_drop=0",
                      "phone_drop=0", "drop_ep=0", "skip=0", "kf=0", "kf_req=0",
                      "kbps=0", "target_kbps=8000", "qp_p50=-", "qp_p95=-",
                      "enc_p50=-", "enc_p95=-", "queue_p95=-",
                      "e2e_p50=-", "e2e_p95=-"] {
            XCTAssertTrue(line.contains(field), "missing \(field) in \(line)")
        }
    }

    func testTheLinePrintsPhoneCountersAndRates() {
        var phone = PhoneStreamStats(json: ["frames": 120, "kf": 2, "kfReq": 1,
                                            "bytes": 250_000, "drop": 9, "dropEp": 2,
                                            "skip": 3, "targetBps": 4_500_000,
                                            "encP50": 12_000, "encP95": 18_000,
                                            "queueP50": 800, "queueP95": 1_500,
                                            "qpP50": 24, "qpP95": 31])
        var window = StreamStatsWindow()
        window.notePhoneStats(phone)
        let line = StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                                        place: "fit", stats: window.snapshot(now: 0))
        for field in ["phone_drop=9", "drop_ep=2", "skip=3", "kf=2", "kf_req=1",
                      "kbps=1000", "target_kbps=4500", "qp_p50=24.0",
                      "qp_p95=31.0", "enc_p50=12.0", "enc_p95=18.0",
                      "queue_p95=1.5"] {
            XCTAssertTrue(line.contains(field), "missing \(field) in \(line)")
        }
        XCTAssertFalse(line.contains("phone_drop=-"))
        // A codec without encoding statistics sends no QP keys at all.
        phone = PhoneStreamStats(json: ["bytes": 0])
        XCTAssertNil(phone.qpP50)
    }

    // MARK: The stats subscription machine

    func testStatsTurnOnWithTheFirstWindowAndOffWithTheLast() {
        var subscription = StatsSubscription()
        XCTAssertNil(subscription.windowsChanged(open: 0))
        XCTAssertEqual(subscription.windowsChanged(open: 1), true)
        XCTAssertNil(subscription.windowsChanged(open: 2))
        XCTAssertEqual(subscription.windowsChanged(open: 1), nil)
        XCTAssertEqual(subscription.windowsChanged(open: 0), false)
        XCTAssertNil(subscription.windowsChanged(open: 0))
    }

    func testANewSessionStartsOff() {
        var subscription = StatsSubscription()
        _ = subscription.windowsChanged(open: 1)
        subscription.sessionEnded()
        XCTAssertEqual(subscription.state, .off)
        XCTAssertEqual(subscription.windowsChanged(open: 1), true)
    }
}
