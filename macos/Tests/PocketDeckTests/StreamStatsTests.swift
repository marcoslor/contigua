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
            window.noteReceived(now: Double(index) * 0.1, bytes: 100)
        }
        window.noteReceived(now: 3.0, bytes: 100)
        let snapshot = window.snapshot(now: 3.0)
        XCTAssertEqual(snapshot.receivedFrames, 1, "only the 3.0 s frame is in the window")
    }

    func testAConfigChangeResetsTheWindow() {
        var window = StreamStatsWindow()
        window.noteReceived(now: 0.1, bytes: 100)
        window.noteReceived(now: 0.2, bytes: 100)
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

    // MARK: Hitches (ISS-40's "dropping frames")

    func testAnEvenSixtyFpsArrivalGivesNoHitches() {
        var window = StreamStatsWindow()
        for index in 0..<60 {
            window.noteEnqueued(now: Double(index) / 60,
                                ptsUs: UInt64(index) * 16_667, offsetUs: nil)
        }
        let snapshot = window.snapshot(now: 1.05)
        XCTAssertEqual(snapshot.hitchCount, 0)
        XCTAssertEqual(snapshot.hitchMs, 0)
    }

    func testAStillWithHeartbeatsGivesNoHitches() {
        var window = StreamStatsWindow()
        for index in 0..<8 {
            window.noteEnqueued(now: Double(index) * 0.5,
                                ptsUs: UInt64(index) * 500_000, offsetUs: nil)
        }
        let snapshot = window.snapshot(now: 3.6)
        XCTAssertEqual(snapshot.hitchCount, 0, "a heartbeat's pts moves with its shown gap")
        XCTAssertEqual(snapshot.hitchMs, 0)
    }

    func testALinkStallGivesOneHitchOfAboutTheStallLessOneFrame() {
        var window = StreamStatsWindow()
        // The last frame before the stall, then the link holds everything for
        // 300 ms: 18 frames (pts every 16.7 ms) arrive in one burst. Only the
        // burst's first frame is late; the rest are early against their pts.
        window.noteEnqueued(now: 0, ptsUs: 0, offsetUs: nil)
        var now = 0.300
        var pts: UInt64 = 16_667
        for _ in 0..<18 {
            window.noteEnqueued(now: now, ptsUs: pts, offsetUs: nil)
            pts += 16_667
            now += 0.000_001
        }
        let snapshot = window.snapshot(now: now)
        XCTAssertEqual(snapshot.hitchCount, 1)
        XCTAssertEqual(snapshot.hitchMs, 283, accuracy: 2)
    }

    func testAPauseResetsTheHitchReference() {
        var window = StreamStatsWindow()
        window.noteEnqueued(now: 0, ptsUs: 0, offsetUs: nil)
        window.notePaused(true, now: 0.01)
        window.notePaused(false, now: 2.0)
        // Without the reset this 2 s shown gap against a 16.7 ms pts gap would
        // be a 1983 ms hitch; covered time is not a hitch.
        window.noteEnqueued(now: 2.0, ptsUs: 16_667, offsetUs: nil)
        let snapshot = window.snapshot(now: 2.05)
        XCTAssertEqual(snapshot.hitchCount, 0)
        XCTAssertEqual(snapshot.hitchMs, 0)
        XCTAssertNil(snapshot.lateP99Ms, "the first frame after a pause has no reference")
    }

    func testLateP99CoversEveryFrameNotOnlyHitches() {
        var window = StreamStatsWindow()
        // 3.3 ms late is below the 50 ms hitch bar but is still a sample.
        window.noteEnqueued(now: 0, ptsUs: 0, offsetUs: nil)
        window.noteEnqueued(now: 0.020, ptsUs: 16_667, offsetUs: nil)
        XCTAssertEqual(window.snapshot(now: 0.03).lateP99Ms ?? -1, 3.333, accuracy: 0.05)
        XCTAssertEqual(window.snapshot(now: 0.03).hitchCount, 0)

        var early = StreamStatsWindow()
        // 10 ms between arrivals for a 16.7 ms pts step: the frame is early,
        // and that negative lateness is a sample too.
        early.noteEnqueued(now: 0, ptsUs: 0, offsetUs: nil)
        early.noteEnqueued(now: 0.010, ptsUs: 16_667, offsetUs: nil)
        XCTAssertEqual(early.snapshot(now: 0.02).lateP99Ms ?? 0, -6.667, accuracy: 0.05)
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
        window.noteEnqueued(now: 1.0, ptsUs: 500_000, offsetUs: nil)
        XCTAssertNil(window.snapshot(now: 1.0).e2eP50Ms)
    }

    func testTheEndToEndDelayIsMeasuredWhenTheSampleIsHandedOver() {
        var window = StreamStatsWindow()
        // The frame arrives at 1.0 s but paced presentation hands it to the
        // layer at 1.016 s: the line's e2e is the hand-off, so the pacing shows.
        window.noteReceived(now: 1.0, bytes: 10)
        window.noteEnqueued(now: 1.016, ptsUs: 500_000, offsetUs: 400_000)
        // pts 0.5 s minus 0.4 s offset = 0.1 s Mac time; 1.016 s now = 916 ms.
        XCTAssertEqual(window.snapshot(now: 1.016).e2eP50Ms ?? -1, 916, accuracy: 0.5)
        XCTAssertEqual(window.snapshot(now: 1.016).e2eP95Ms ?? -1, 916, accuracy: 0.5)
    }

    func testPacedDropsAreMacDrops() {
        var window = StreamStatsWindow()
        window.noteDiscarded(.paced, now: 0.1)
        XCTAssertEqual(window.snapshot(now: 0.2).macDrop, 1)
    }

    // MARK: The phone's counters between two lines (ISS-40 item 1)

    private func phoneMessage(frames: Int, bytes: Int, dropGapMs: Int? = nil,
                              targetBps: Int = 0, qpP50: Double? = nil,
                              qpP95: Double? = nil,
                              windowMs: Int = 2_000) -> PhoneStreamStats {
        var stats = PhoneStreamStats(json: ["frames": frames, "kf": 1, "kfReq": 1,
                                           "bytes": bytes, "drop": 1, "dropEp": 1,
                                           "skip": 1, "susp": 1, "suspMs": 10,
                                           "refine": 1, "targetBps": targetBps,
                                           "windowMs": windowMs,
                                           "encP50": 1_000, "encP95": 2_000,
                                           "queueP50": 300, "queueP95": 600])
        stats.dropGapMs = dropGapMs
        stats.qpP50 = qpP50
        stats.qpP95 = qpP95
        return stats
    }

    /// The `field=value` word for a key on a line, so a test reads what the
    /// reviewer reads without a second accessor.
    private func field(_ key: String, in line: String) -> String? {
        for word in line.split(separator: " ") {
            if word.hasPrefix(key + "=") { return String(word.dropFirst(key.count + 1)) }
        }
        return nil
    }

    private func line(_ stats: StreamStatsSnapshot) -> String {
        StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                             place: "fit", stats: stats)
    }

    func testTwoPhoneMessagesSumTheirCountersAndKeepTheLatestLevels() {
        var window = StreamStatsWindow()
        window.notePhoneStats(phoneMessage(frames: 100, bytes: 40_000,
                                           dropGapMs: 40, targetBps: 4_000_000,
                                           qpP50: 10, qpP95: 20))
        window.notePhoneStats(phoneMessage(frames: 120, bytes: 60_000,
                                           dropGapMs: 60, targetBps: 5_000_000,
                                           qpP50: 30, qpP95: 40))
        let snapshot = window.snapshot(now: 5)
        let phone = try? XCTUnwrap(snapshot.phone)
        let text = line(snapshot)
        XCTAssertEqual(field("phone_n", in: text), "2")
        XCTAssertEqual(phone?.frames, 220)
        XCTAssertEqual(phone?.keyframes, 2)
        XCTAssertEqual(phone?.keyframesRequested, 2)
        XCTAssertEqual(phone?.bytes, 100_000)
        XCTAssertEqual(phone?.deltasDropped, 2)
        XCTAssertEqual(phone?.dropEpisodes, 2)
        XCTAssertEqual(phone?.dropGapMs, 100)
        XCTAssertEqual(phone?.framesSkipped, 2)
        XCTAssertEqual(phone?.suspendedEpisodes, 2)
        XCTAssertEqual(phone?.suspendedMs, 20)
        XCTAssertEqual(phone?.refined, 2)
        // The levels are the latest message's, not a sum.
        XCTAssertEqual(phone?.targetBps, 5_000_000)
        XCTAssertEqual(phone?.qpP50, 30)
        XCTAssertEqual(phone?.qpP95, 40)
        XCTAssertEqual(phone?.encodeP50Us, 1_000)
        XCTAssertEqual(field("target_kbps", in: text), "5000")
    }

    func testKbpsUsesTheSummedBytesAndTheSummedMessageIntervals() {
        var window = StreamStatsWindow()
        // 4,000 bytes over 2 s then 6,000 over 3 s: 10,000 bytes in 5 s.
        window.notePhoneStats(phoneMessage(frames: 1, bytes: 4_000))
        window.notePhoneStats(phoneMessage(frames: 1, bytes: 6_000, windowMs: 3_000))
        let text = line(window.snapshot(now: 5))
        XCTAssertEqual(field("kbps", in: text), "16",
                       "10,000 bytes × 8 / 5,000 ms = 16 kbps")
    }

    func testALineWithNoPhoneMessagePrintsZeroCountersAndNoLevels() {
        var window = StreamStatsWindow()
        window.notePhoneStats(phoneMessage(frames: 100, bytes: 40_000,
                                           dropGapMs: 40, targetBps: 8_000_000,
                                           qpP50: 24, qpP95: 31))
        _ = window.snapshot(now: 5) // the line consumes the message
        let snapshot = window.snapshot(now: 10)
        XCTAssertNil(snapshot.phone)
        let text = line(snapshot)
        for expected in ["phone_n=0", "kbps=-", "target_kbps=-", "qp_p50=-",
                         "qp_p95=-", "enc_p50=-", "enc_p95=-", "queue_p95=-",
                         "phone_drop=0", "drop_ep=0", "drop_ms=0", "skip=0",
                         "susp_n=0", "susp_ms=0", "refine_n=0", "kf=0", "kf_req=0"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in \(text)")
        }
        XCTAssertFalse(text.contains("kbps=0"))
        XCTAssertFalse(text.contains("target_kbps=8000"),
                       "a line with no message must not repeat the previous message")
    }

    func testAConfigBetweenTwoMessagesKeepsTheFirstCounters() {
        var window = StreamStatsWindow()
        window.notePhoneStats(phoneMessage(frames: 100, bytes: 40_000, targetBps: 4_000_000))
        window.noteConfig(now: 1.0)
        window.notePhoneStats(phoneMessage(frames: 20, bytes: 10_000, targetBps: 6_000_000))
        let snapshot = window.snapshot(now: 2.0)
        XCTAssertEqual(field("phone_n", in: line(snapshot)), "2")
        XCTAssertEqual(snapshot.phone?.frames, 120,
                       "a config resets the Mac's window, not the phone's counters")
        XCTAssertEqual(snapshot.phone?.bytes, 50_000)
        XCTAssertEqual(snapshot.phone?.targetBps, 6_000_000)
        XCTAssertEqual(snapshot.receivedFrames, 0, "the config still resets the Mac's samples")
    }

    func testAPhoneWithoutDropGapStaysAbsentAcrossTwoMessages() {
        var window = StreamStatsWindow()
        window.notePhoneStats(phoneMessage(frames: 1, bytes: 1, dropGapMs: nil))
        window.notePhoneStats(phoneMessage(frames: 1, bytes: 1, dropGapMs: nil))
        let snapshot = window.snapshot(now: 1)
        XCTAssertNil(snapshot.phone?.dropGapMs, "no measurement is absent, never zero")
        let text = line(snapshot)
        XCTAssertTrue(text.contains("drop_ms=-"))
        XCTAssertEqual(field("phone_n", in: text), "2")
        XCTAssertTrue(line(window.snapshot(now: 2)).contains("phone_n=0"),
                      "the next line has no message")
    }

    // MARK: The line (item 4)

    func testTheLogLineHasEveryFieldAndDashForMissingValues() {
        var window = StreamStatsWindow()
        window.noteReceived(now: 1.0, bytes: 1000)
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
                      "int_p99=", "freeze_n=0", "freeze_ms=0", "hitch_n=0",
                      "hitch_ms=0", "late_p99=-", "mac_drop=0",
                      "phone_drop=0", "drop_ep=0", "drop_ms=-", "phone_n=1",
                      "skip=0", "susp_n=0", "susp_ms=0", "refine_n=0", "kf=0",
                      "kf_req=0", "kbps=0", "target_kbps=8000", "qp_p50=-", "qp_p95=-",
                      "enc_p50=-", "enc_p95=-", "queue_p95=-",
                      "e2e_p50=-", "e2e_p95=-"] {
            XCTAssertTrue(line.contains(field), "missing \(field) in \(line)")
        }
    }

    func testTheLinePrintsPhoneCountersAndRates() {
        var phone = PhoneStreamStats(json: ["frames": 120, "kf": 2, "kfReq": 1,
                                            "bytes": 250_000, "drop": 9, "dropEp": 2,
                                            "dropGapMs": 250,
                                            "skip": 3, "susp": 4, "suspMs": 850,
                                            "refine": 2, "targetBps": 4_500_000,
                                            "encP50": 12_000, "encP95": 18_000,
                                            "queueP50": 800, "queueP95": 1_500,
                                            "qpP50": 24, "qpP95": 31])
        var window = StreamStatsWindow()
        window.notePhoneStats(phone)
        let line = StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                                        place: "fit", stats: window.snapshot(now: 0))
        for field in ["phone_drop=9", "drop_ep=2", "drop_ms=250", "phone_n=1",
                      "skip=3", "susp_n=4",
                      "susp_ms=850", "refine_n=2", "kf=2", "kf_req=1",
                      "kbps=1000", "target_kbps=4500", "qp_p50=24.0",
                      "qp_p95=31.0", "enc_p50=12.0", "enc_p95=18.0",
                      "queue_p95=1.5"] {
            XCTAssertTrue(line.contains(field), "missing \(field) in \(line)")
        }
        XCTAssertFalse(line.contains("drop_ms=-"))
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

    /// A window opened while the link is down asks for stats, but the write is
    /// refused; the windows re-open with the session and the ask must go again.
    @MainActor
    func testAStatsAskRefusedBeforeTheLinkWasReadyIsAskedAgainWhenItIs() {
        let fixture = MultiWindowFixture()
        fixture.open()
        let first = fixture.session.sent("stream.stats")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?["on"] as? Bool, true)
        fixture.manager.handle(.ready(fixture.manager.phone!, isReconnect: true, address: nil))
        XCTAssertEqual(fixture.session.sent("stream.stats").count, 2,
                       "the refused ask is sent again on the ready session")
        fixture.closeAll()
    }
}
