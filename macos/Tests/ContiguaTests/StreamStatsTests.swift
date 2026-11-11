// ISS-40's measurements: the pong clock-offset estimator, the sliding 2 s
// window, the `stats …` line's shape and the stats subscription machine.
// Every clock is passed in, so these are deterministic.

import XCTest
@testable import Contigua

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

    /// WIN-53: the phone's CLOCK_MONOTONIC stops while it sleeps, so the offset
    /// jumps between windows. A pong outside the RTT-derived bound is a new
    /// clock, not a slow one: the estimate restarts from that sample at once,
    /// even while a stale low-RTT sample is still inside the 30 s horizon.
    func testAClockJumpRestartsTheEstimateFromTheJumpingSample() {
        var estimator = ClockOffsetEstimator()
        estimator.note(sentUs: 1_000_000, receivedUs: 1_020_000,
                       phoneNowUs: 6_010_000, at: 0) // 20 ms rtt, 5 s offset
        let jumped = estimator.note(sentUs: 3_000_000, receivedUs: 3_020_000,
                                    phoneNowUs: 10_010_000, at: 1) // +2 s
        XCTAssertEqual(jumped.jumpMs ?? 0, 2_000, accuracy: 0.01)
        XCTAssertEqual(estimator.samples.count, 1, "the old samples no longer describe this clock")
        XCTAssertEqual(estimator.offsetUs ?? -1, 7_000_000, accuracy: 1)
    }

    /// Inside (rtt + estimate rtt) / 2 + 5 ms the difference is jitter, not a
    /// jump: the sample joins the window and the lowest-RTT estimate stays.
    func testASampleInsideTheBoundNeverRestartsTheEstimate() {
        var estimator = ClockOffsetEstimator()
        estimator.note(sentUs: 1_000_000, receivedUs: 1_020_000,
                       phoneNowUs: 6_010_000, at: 0) // 20 ms rtt
        // 10 ms away with a 30 ms rtt: the bound is (30 + 20) / 2 + 5 = 30 ms.
        let sample = estimator.note(sentUs: 3_000_000, receivedUs: 3_030_000,
                                    phoneNowUs: 8_025_000, at: 1)
        XCTAssertNil(sample.jumpMs)
        XCTAssertEqual(estimator.samples.count, 2)
        XCTAssertEqual(estimator.offsetUs ?? -1, 5_000_000, accuracy: 1,
                       "the 20 ms sample is still the estimate")
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
        let snapshot = window.snapshot(now: 0.4)
        XCTAssertEqual(snapshot.macDrop, 3)
        XCTAssertEqual(snapshot.macDrops[.beforeConfig], 1)
        XCTAssertEqual(snapshot.macDrops[.flush], 1)
        XCTAssertEqual(snapshot.macDrops[.notReady], 1)
        XCTAssertNil(snapshot.macDrops[.paced])
        XCTAssertEqual(window.snapshot(now: 3.0).macDrop, 0, "older than the window")
    }

    /// WIN-61: the line splits the drops, so a flush is never read as
    /// `not_ready`, and counts the deltas that slipped through a broken chain
    /// (`chain_fed`, zero after the gate).
    func testTheLineSplitsMacDropsAndCountsChainFed() {
        var window = StreamStatsWindow()
        window.noteDiscarded(.flush, now: 0.1)
        window.noteDiscarded(.flush, now: 0.2)
        window.noteDiscarded(.paced, now: 0.3)
        window.noteDiscarded(.awaitingKey, now: 0.35)
        window.noteDiscarded(.incomplete, now: 0.4)
        window.noteChainFed(now: 0.45)
        window.noteChainFed(now: 0.5)
        let snapshot = window.snapshot(now: 0.6)
        let line = StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                                        place: "fit", stats: snapshot)
        XCTAssertTrue(line.contains("mac_drop=5"), line)
        XCTAssertTrue(line.contains("mac_drop_flush=2"), line)
        XCTAssertTrue(line.contains("mac_drop_not_ready=0"), line)
        XCTAssertTrue(line.contains("mac_drop_before_config=0"), line)
        XCTAssertTrue(line.contains("mac_drop_paced=1"), line)
        XCTAssertTrue(line.contains("mac_drop_awaiting_key=1"), line)
        XCTAssertTrue(line.contains("mac_drop_incomplete=1"), line)
        XCTAssertTrue(line.contains("chain_fed=2"), line)
        XCTAssertEqual(window.snapshot(now: 1.0).chainFed, 0,
                       "the counters belong to one line")
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
                      "mac_drop_flush=0", "mac_drop_not_ready=0",
                      "mac_drop_before_config=0", "mac_drop_paced=0",
                      "mac_drop_awaiting_key=0", "mac_drop_incomplete=0",
                      "chain_fed=0",
                      "phone_drop=0", "drop_ep=0", "drop_ms=-", "phone_n=1",
                      "skip=0", "susp_n=0", "susp_ms=0", "refine_n=0", "kf=0",
                      "kf_req=0", "kbps=0", "target_kbps=8000", "qp_p50=-", "qp_p95=-",
                      "enc_p50=-", "enc_p95=-", "queue_p95=-",
                      "e2e_p50=-", "e2e_p95=-", "max_gap_ms=",
                      "key_not_idr=0", "ph_key_not_idr=0"] {
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

    // MARK: The window's totals (item 4)

    /// WIN-55/56: the closing line is complete over the window's whole life,
    /// not a sample: counters keep their values across the 5 s snapshots and a
    /// config, the percentiles cover every shown frame, and the covered time is
    /// the pause the window spent hidden.
    func testTheWholeLifeSamplesStayBoundedAndEven() {
        // A window left open for hours must not keep one value per frame
        // forever: the record thins evenly and never passes its capacity.
        var few = ThinnedSamples(capacity: 64)
        for value in 1...50 { few.append(Double(value)) }
        XCTAssertEqual(few.values.count, 50, "below capacity every value is kept")

        var many = ThinnedSamples(capacity: 64)
        for value in 1...10_000 { many.append(Double(value)) }
        XCTAssertLessThan(many.values.count, 64)
        XCTAssertGreaterThanOrEqual(many.values.count, 32)
        let median = StreamStatsWindow.percentile(many.values, 0.5) ?? 0
        XCTAssertEqual(median, 5_000, accuracy: 500, "thinning stays even over the whole life")
        XCTAssertGreaterThan(many.values.last ?? 0, 9_000, "the newest values are still sampled")
    }

    func testTheTotalsLineCoversTheWholeWindowsLife() {
        var window = StreamStatsWindow(now: 0)
        for index in 0..<20 {
            window.noteReceived(now: Double(index) * 0.1, bytes: 100)
        }
        // One frame 183 ms late (a hitch), then a steady 10 fps picture: every
        // shown gap equals its pts gap, so only the second is a hitch.
        window.noteEnqueued(now: 0, ptsUs: 0, offsetUs: 0)
        window.noteEnqueued(now: 0.2, ptsUs: 16_667, offsetUs: 0)
        for index in 2..<20 {
            window.noteEnqueued(now: 0.3 + Double(index - 2) * 0.1,
                                ptsUs: 116_667 + UInt64(index - 2) * 100_000,
                                offsetUs: 0)
        }
        window.notePhoneStats(phoneMessage(frames: 60, bytes: 1_000, dropGapMs: 40))
        window.notePhoneStats(phoneMessage(frames: 40, bytes: 1_000, dropGapMs: 60))
        _ = window.snapshot(now: 2.05) // the 5 s line consumes the messages
        window.noteConfig(now: 2.1)    // a resize: the samples reset, the totals do not
        for index in 0..<10 {
            window.noteReceived(now: 2.2 + Double(index) * 0.1, bytes: 100)
        }
        window.notePaused(true, now: 5.0)
        window.notePaused(false, now: 7.0)
        window.notePhoneStats(phoneMessage(frames: 10, bytes: 500, dropGapMs: 10))

        let total = window.total(now: 10)
        XCTAssertEqual(total.seconds, 10, accuracy: 0.001)
        XCTAssertEqual(total.receivedFrames, 30)
        XCTAssertEqual(total.enqueuedFrames, 20)
        XCTAssertEqual(total.hitchCount, 1)
        XCTAssertEqual(total.hitchMs, 183.3, accuracy: 0.2)
        XCTAssertEqual(total.lateP99Ms ?? -1, 183.3, accuracy: 0.2)
        XCTAssertEqual(total.phoneMessages, 3)
        XCTAssertEqual(total.phoneFrames, 110)
        XCTAssertEqual(total.phoneKeyframes, 3)
        XCTAssertEqual(total.phoneKeyframesRequested, 3)
        XCTAssertEqual(total.dropEpisodes, 3)
        XCTAssertEqual(total.dropGapMs, 110)
        XCTAssertEqual(total.suspendedEpisodes, 3)
        XCTAssertEqual(total.suspendedMs, 30)
        XCTAssertEqual(total.phoneBytes, 2_500)
        XCTAssertEqual(total.receivedBytes, 3_000)
        XCTAssertEqual(total.e2eP50Ms ?? -1, 183.3, accuracy: 0.2)
        XCTAssertEqual(total.e2eP95Ms ?? -1, 183.3, accuracy: 0.2)
        XCTAssertEqual(total.coveredMs, 2_000, accuracy: 1)

        let text = StreamStatsLine.totalText(stream: 7, total: total)
        for field in ["stats total stream=7", "secs=10.0", "rx_frames=30",
                      "shown_frames=20", "hitch_n=1", "hitch_ms=183",
                      "late_p99=183.3", "phone_n=3", "phone_frames=110",
                      "kf=3", "kf_req=3", "drop_ep=3", "drop_ms=110",
                      "susp_n=3", "susp_ms=30", "bytes=2500",
                      "rx_kbps=2.4",
                      "e2e_p50=183.3", "e2e_p95=183.3", "covered_ms=2000",
                      "max_gap_ms=", "key_not_idr=0", "ph_key_not_idr=0"] {
            XCTAssertTrue(text.contains(field), "missing \(field) in \(text)")
        }
    }

    /// P0 (pmaxx): the closing totals carry every stage's distribution, not
    /// only the p95. The arrival intervals show the link's pacing, the shown
    /// intervals show the display's, and e2e_p99 shows the tail a person sees
    /// as a stall even when the median is fine.
    func testTheTotalsCarryEveryStagePercentile() {
        var window = StreamStatsWindow(now: 0)
        for index in 0..<6 {
            window.noteReceived(now: Double(index) * 0.1, bytes: 100)
        }
        window.noteReceived(now: 1.0, bytes: 100) // one 500 ms link gap
        for index in 0..<6 {
            window.noteEnqueued(now: Double(index) * 0.02,
                                ptsUs: UInt64(index) * 16_667, offsetUs: 0)
        }
        window.noteEnqueued(now: 0.5, ptsUs: 100_002, offsetUs: 0) // one 420 ms shown gap
        let total = window.total(now: 2.0)
        XCTAssertEqual(total.intervalP50Ms ?? -1, 100, accuracy: 0.5)
        XCTAssertEqual(total.intervalP95Ms ?? -1, 500, accuracy: 0.5)
        XCTAssertEqual(total.intervalP99Ms ?? -1, 500, accuracy: 0.5)
        XCTAssertEqual(total.shownP50Ms ?? -1, 20, accuracy: 0.5)
        XCTAssertEqual(total.shownP95Ms ?? -1, 400, accuracy: 0.5)
        XCTAssertEqual(total.shownP99Ms ?? -1, 400, accuracy: 0.5)
        XCTAssertEqual(total.e2eP99Ms ?? -1, 400, accuracy: 1)
        let text = StreamStatsLine.totalText(stream: 9, total: total)
        for field in ["e2e_p99=", "int_p50=100.0", "int_p95=500.0",
                      "int_p99=500.0", "shown_p50=20.0", "shown_p95=400.0",
                      "shown_p99=400.0"] {
            XCTAssertTrue(text.contains(field), "missing \(field) in \(text)")
        }
    }

    // MARK: The longest picture gap (item 0)

    /// ISS-40: `max_gap_ms` is the longest interval between received frames
    /// outside covered time, over the line's own period and the whole life;
    /// a VIDEO_CONFIG in the middle of a gap must not hide it, because the
    /// decoder had no picture on either side of it.
    func testTheLongestFrameGapSurvivesAConfigAndReachesBothLines() {
        var window = StreamStatsWindow(now: 0)
        window.noteReceived(now: 1.0, bytes: 100)
        window.noteReceived(now: 1.02, bytes: 100)
        window.noteConfig(now: 1.5)
        window.noteReceived(now: 3.24, bytes: 100) // 2_220 ms since 1.02
        let line = window.snapshot(now: 5.0)
        XCTAssertEqual(line.maxGapMs, 2_220, accuracy: 0.5)
        let text = StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                                        place: "fit", stats: line)
        XCTAssertTrue(text.contains("max_gap_ms=2220"), text)
        // The next line's gap starts from the last frame, not from this line.
        XCTAssertEqual(window.snapshot(now: 10.0).maxGapMs, 0, accuracy: 0.001)
        let total = window.total(now: 10.0)
        XCTAssertEqual(total.maxGapMs, 2_220, accuracy: 0.5)
        let totalText = StreamStatsLine.totalText(stream: 1, total: total)
        XCTAssertTrue(totalText.contains("max_gap_ms=2220"), totalText)
    }

    /// A hidden or paused window is not a picture gap: its span is covered
    /// time (WIN-55's `covered_ms`), so the frame on either side of it must
    /// not become a gap.
    func testACoveredSpanIsNotAMaxGap() {
        var window = StreamStatsWindow(now: 0)
        window.noteReceived(now: 1.0, bytes: 100)
        window.notePaused(true, now: 1.1)
        // A frame already in flight when the window was covered must not
        // restart the gap clock: the covered silence is not a picture gap.
        window.noteReceived(now: 1.2, bytes: 100)
        window.notePaused(false, now: 4.0)
        window.noteReceived(now: 4.05, bytes: 100)
        XCTAssertEqual(window.snapshot(now: 5.0).maxGapMs, 0, accuracy: 0.001)
        XCTAssertEqual(window.total(now: 5.0).maxGapMs, 0, accuracy: 0.001)
    }

    // MARK: The key-flagged frames without an IDR (item 3)

    /// The wire flag says "key"; only a type-5 unit says the decoder can
    /// start there. A run with intra refresh flags recovery points, so the
    /// first three of those must reach the field log with their types.
    func testAKeyFlaggedFrameWithoutAnIdrIsCountedAndLoggedThreeTimes() {
        var window = StreamStatsWindow(now: 0)
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: false, nalTypes: [1], now: 0), .none)
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [7, 8, 5], now: 0), .none,
                       "an IDR key frame is not a key_not_idr")
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [6, 1], now: 0),
                       .types("6,1"))
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [7, 8, 1], now: 0),
                       .types("7,8,1"))
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [6], now: 0),
                       .types("6"))
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [6, 1], now: 0), .none,
                       "the fourth is counted but no longer logged")
        let line = window.snapshot(now: 1)
        XCTAssertEqual(line.keyNotIdr, 4)
        XCTAssertEqual(window.snapshot(now: 2).keyNotIdr, 0, "the next line starts at zero")
        XCTAssertEqual(window.total(now: 2).keyNotIdr, 4)
    }

    /// An IDR is never logged, before or after a drop: the phone's drop report
    /// rides a 2 s stats message, so the Mac can't time the recovery from it.
    func testAnIdrIsQuietAndOnlyANonIdrKeyIsNamed() {
        var window = StreamStatsWindow(now: 0)
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [7, 8, 5], now: 10), .none)
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [6, 1], now: 10.1),
                       .types("6,1"))
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [7, 8, 5], now: 10.4), .none)
    }

    func testTheKeyNoteLinesAreTheDocumentedOnes() {
        XCTAssertEqual(StreamStatsLine.keyNote(stream: 3, note: .types("6,1")),
                       "stream 3 key nal=6,1")
        XCTAssertNil(StreamStatsLine.keyNote(stream: 3, note: .none))
    }

    /// HEVC reads its own type field: an IDR (19/20) is clean and a CRA (21) is
    /// a key frame the decoder cannot restart an IDR on, so it is counted.
    func testAHevcCraIsKeyNotIdr() {
        var window = StreamStatsWindow(now: 0)
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [32, 33, 34, 19],
                                          codec: .hevc, now: 0), .none)
        XCTAssertEqual(window.noteKeyFrame(isKeyframe: true, nalTypes: [32, 33, 34, 21],
                                          codec: .hevc, now: 0),
                       .types("32,33,34,21"))
        XCTAssertEqual(window.snapshot(now: 1).keyNotIdr, 1)
        XCTAssertEqual(window.total(now: 2).keyNotIdr, 1)
    }

    /// WIN-59/60: the line names the stream's codec and the phone's QP mean;
    /// the totals' mean is weighted by each message's frames.
    func testTheCodecAndQpMeanReachBothLines() {
        var window = StreamStatsWindow(now: 0)
        window.notePhoneStats(PhoneStreamStats(json: ["codec": "hevc", "frames": 60,
                                                      "qpAvg": 20.0]))
        window.notePhoneStats(PhoneStreamStats(json: ["codec": "hevc", "frames": 40,
                                                      "qpAvg": 30.0]))
        let line = StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                                        place: "fit", stats: window.snapshot(now: 1))
        XCTAssertTrue(line.contains("codec=hevc"), line)
        XCTAssertTrue(line.contains("qp_avg=30.0"), "the latest message's level")
        let total = window.total(now: 2)
        let totals = StreamStatsLine.totalText(stream: 1, total: total)
        XCTAssertTrue(totals.contains("codec=hevc"), totals)
        XCTAssertTrue(totals.contains("qp_avg=24.0"), totals)
        XCTAssertTrue(totals.contains("ph_key_not_idr=0"), totals)
    }

    func testACodecOrQpMeanThePhoneNeverSentPrintsDash() {
        var window = StreamStatsWindow(now: 0)
        window.notePhoneStats(PhoneStreamStats(json: ["frames": 10]))
        let line = StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                                        place: "fit", stats: window.snapshot(now: 1))
        XCTAssertTrue(line.contains("codec=-"), line)
        XCTAssertTrue(line.contains("qp_avg=-"), line)
        let totals = StreamStatsLine.totalText(stream: 1, total: window.total(now: 2))
        XCTAssertTrue(totals.contains("codec=-"), totals)
        XCTAssertTrue(totals.contains("qp_avg=-"), totals)
    }

    /// The phone's own key_not_idr rides every `stream.stats` message; the
    /// Mac sums it over the window's life and prints its own count beside it.
    func testThePhoneKeyCountsSumAcrossMessagesAndPrintOnBothLines() {
        var window = StreamStatsWindow(now: 0)
        window.notePhoneStats(PhoneStreamStats(json: ["keyIdr": 1, "keyNotIdr": 2]))
        window.notePhoneStats(PhoneStreamStats(json: ["keyIdr": 1, "keyNotIdr": 2]))
        let snapshot = window.snapshot(now: 1)
        let line = StreamStatsLine.text(stream: 1, size: .zero, view: .zero,
                                        place: "fit", stats: snapshot)
        XCTAssertTrue(line.contains("key_not_idr=0"), line)
        XCTAssertTrue(line.contains("ph_key_not_idr=4"), line)
        let total = window.total(now: 2)
        XCTAssertEqual(total.phoneKeyIdr, 2)
        XCTAssertEqual(total.phoneKeyNotIdr, 4)
        let totalText = StreamStatsLine.totalText(stream: 1, total: total)
        XCTAssertTrue(totalText.contains("key_not_idr=0"), totalText)
        XCTAssertTrue(totalText.contains("ph_key_not_idr=4"), totalText)
    }

    func testACloseWhilePausedCountsTheCoveredTimeSoFar() {
        var window = StreamStatsWindow(now: 0)
        window.notePaused(true, now: 2.0)
        let total = window.total(now: 5.0)
        XCTAssertEqual(total.coveredMs, 3_000, accuracy: 1)
        XCTAssertEqual(window.snapshot(now: 5.0).receivedFrames, 0)
    }

    func testATotalsLineWithNoPhoneMessagePrintsZeroCountersAndNoLevels() {
        var window = StreamStatsWindow(now: 0)
        let text = StreamStatsLine.totalText(stream: 1, total: window.total(now: 4.0))
        for field in ["secs=4.0", "rx_frames=0", "shown_frames=0", "hitch_n=0",
                      "hitch_ms=0", "late_p99=-", "phone_n=0", "phone_frames=0",
                      "kf=0", "kf_req=0", "drop_ep=0", "drop_ms=-",
                      "susp_n=0", "susp_ms=0", "bytes=0", "e2e_p50=-",
                      "e2e_p95=-", "covered_ms=0", "max_gap_ms=0",
                      "key_not_idr=0", "ph_key_not_idr=0"] {
            XCTAssertTrue(text.contains(field), "missing \(field) in \(text)")
        }
    }

    // MARK: The socket's TCP state (X0, item 1)

    /// The receiver's own trace of a hole: `tcpi_rxoutoforderbytes` is
    /// cumulative, so each 5 s line reports the delta and the totals the whole
    /// life. The first line has no previous reading and prints `-`.
    func testTCPInfoGivesTheDeltaSinceThePreviousLine() {
        let provider = FakeTCPInfoProvider([
            tcp(srtt: 12, rttvar: 3, ooo: 4_096),
            tcp(srtt: 15, rttvar: 4, ooo: 6_144),
        ])
        var window = StreamStatsWindow(now: 0)
        let first = line(window.snapshot(now: 1, tcpInfo: provider.read()))
        XCTAssertEqual(field("tcp_srtt", in: first), "12")
        XCTAssertEqual(field("tcp_rttvar", in: first), "3")
        XCTAssertEqual(field("tcp_ooo_kb", in: first), "-",
                       "the first line has no earlier reading to subtract")
        let second = line(window.snapshot(now: 6, tcpInfo: provider.read()))
        XCTAssertEqual(field("tcp_srtt", in: second), "15")
        XCTAssertEqual(field("tcp_rttvar", in: second), "4")
        XCTAssertEqual(field("tcp_ooo_kb", in: second), "2.0")
    }

    /// A refused getsockopt is no measurement: all three read `-`, the last
    /// good reading stays the baseline, and the next good one spans both lines.
    func testAFailedTCPInfoReadPrintsDashAndKeepsTheBaseline() {
        let provider = FakeTCPInfoProvider([
            tcp(srtt: 10, rttvar: 1, ooo: 1_024),
            nil,
            tcp(srtt: 20, rttvar: 2, ooo: 3_072),
        ])
        var window = StreamStatsWindow(now: 0)
        _ = window.snapshot(now: 1, tcpInfo: provider.read())
        let failed = line(window.snapshot(now: 6, tcpInfo: provider.read()))
        for key in ["tcp_srtt", "tcp_rttvar", "tcp_ooo_kb"] {
            XCTAssertEqual(field(key, in: failed), "-", "missing \(key) in \(failed)")
        }
        let next = line(window.snapshot(now: 11, tcpInfo: provider.read()))
        XCTAssertEqual(field("tcp_ooo_kb", in: next), "2.0",
                       "2,048 bytes since the last good reading, not since the failed line")
    }

    /// WIN-55/56: a config and a pause reset the frame samples, never the
    /// socket's lifetime counters or its worst round trip.
    func testTheTotalsCarryTCPOutOfOrderAndWorstSRTTAcrossAConfigAndPause() {
        let provider = FakeTCPInfoProvider([
            tcp(srtt: 10, rttvar: 1, ooo: 1_024),
            tcp(srtt: 25, rttvar: 5, ooo: 5_120),
        ])
        var window = StreamStatsWindow(now: 0)
        _ = window.snapshot(now: 1, tcpInfo: provider.read())
        window.noteConfig(now: 2)
        window.notePaused(true, now: 3)
        window.notePaused(false, now: 4)
        _ = window.snapshot(now: 9, tcpInfo: provider.read())
        let total = window.total(now: 10)
        XCTAssertEqual(total.tcpOutOfOrderKB ?? -1, 4.0, accuracy: 0.01)
        XCTAssertEqual(total.tcpSrttMaxMs, 25)
        let text = StreamStatsLine.totalText(stream: 1, total: total)
        XCTAssertTrue(text.contains("tcp_ooo_kb=4.0"), "missing tcp_ooo_kb in \(text)")
        XCTAssertTrue(text.contains("tcp_srtt_max=25"), "missing tcp_srtt_max in \(text)")
    }

    func testATotalsLineWithNoTCPReadingPrintsDash() {
        var window = StreamStatsWindow(now: 0)
        let text = StreamStatsLine.totalText(stream: 1, total: window.total(now: 4))
        XCTAssertTrue(text.contains("tcp_ooo_kb=-"), "missing tcp_ooo_kb in \(text)")
        XCTAssertTrue(text.contains("tcp_srtt_max=-"), "missing tcp_srtt_max in \(text)")
    }

    private func tcp(srtt: Int, rttvar: Int, ooo: UInt64) -> TCPConnectionInfo {
        TCPConnectionInfo(srttMs: srtt, rttvar: rttvar, rxOutOfOrderBytes: ooo)
    }

    /// Stands in for the session's socket reader; nil is a failed read.
    private final class FakeTCPInfoProvider {
        private var readings: [TCPConnectionInfo?]
        init(_ readings: [TCPConnectionInfo?]) { self.readings = readings }
        func read() -> TCPConnectionInfo? {
            readings.isEmpty ? nil : readings.removeFirst()
        }
    }

    // MARK: The phone's TCP resend counters (X0, item 4)

    /// The phone's system-wide counters arrive as deltas; a line sums every
    /// message it folded in, and a missing measurement is `-`, not zero.
    func testThePhoneResendCountersSumAcrossMessagesAndPrintOnTheLine() {
        var window = StreamStatsWindow()
        window.notePhoneStats(PhoneStreamStats(json: [
            "frames": 60, "retrans": 3, "rto": 1, "lost_retrans": 2,
        ]))
        window.notePhoneStats(PhoneStreamStats(json: [
            "frames": 60, "retrans": 4, "rto": 0, "lost_retrans": 1,
        ]))
        let text = line(window.snapshot(now: 5))
        XCTAssertEqual(field("ph_retrans", in: text), "7")
        XCTAssertEqual(field("ph_rto", in: text), "1")
        XCTAssertEqual(field("ph_lost", in: text), "3")
        let total = window.total(now: 5)
        XCTAssertEqual(total.phoneRetransmissions, 7)
        XCTAssertEqual(total.phoneRTOs, 1)
        XCTAssertEqual(total.phoneLostRetransmits, 3)
        let totals = StreamStatsLine.totalText(stream: 1, total: total)
        XCTAssertTrue(totals.contains("ph_retrans=7"), "missing ph_retrans in \(totals)")
        XCTAssertTrue(totals.contains("ph_rto=1"), "missing ph_rto in \(totals)")
        XCTAssertTrue(totals.contains("ph_lost=3"), "missing ph_lost in \(totals)")
    }

    func testAPhoneWithoutTheResendCountersPrintsDash() {
        var window = StreamStatsWindow()
        let empty = line(window.snapshot(now: 1))
        for key in ["ph_retrans", "ph_rto", "ph_lost"] {
            XCTAssertEqual(field(key, in: empty), "-", "missing \(key) in \(empty)")
        }
        window.notePhoneStats(PhoneStreamStats(json: ["frames": 10]))
        let unmeasured = line(window.snapshot(now: 5))
        for key in ["ph_retrans", "ph_rto", "ph_lost"] {
            XCTAssertEqual(field(key, in: unmeasured), "-", "missing \(key) in \(unmeasured)")
        }
        let total = StreamStatsLine.totalText(stream: 1, total: window.total(now: 5))
        XCTAssertTrue(total.contains("ph_retrans=-"), "missing ph_retrans in \(total)")
        XCTAssertTrue(total.contains("ph_rto=-"), "missing ph_rto in \(total)")
        XCTAssertTrue(total.contains("ph_lost=-"), "missing ph_lost in \(total)")
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
