// Stream measurements (ISS-40): the pong clock-offset estimate, the per-window
// sliding aggregates the log line prints, and the stats subscription machine.
// Everything here is pure and clock-explicit so the unit tests drive it without
// a phone; the window does the I/O around it.

import Foundation

/// The phone's CLOCK_MONOTONIC against the Mac's, from `pong.now`.
///
/// Every sample is `offset = now − (sent + rtt/2)`, where `sent` is the Mac's
/// monotonic µs when its `ping` went out, `rtt` is the round trip and `now` is
/// the phone's µs at the pong. The estimate is the lowest-RTT sample of the
/// last 30 s: RTT jitter only ever makes a sample later, never earlier, so the
/// fastest round trip is the least polluted one.
struct ClockOffsetEstimator {
    struct Sample: Equatable {
        /// When the pong arrived, Mac monotonic seconds (the 30 s horizon).
        var at: TimeInterval
        var rttUs: Double
        var offsetUs: Double
    }

    static let horizon: TimeInterval = 30

    private(set) var samples: [Sample] = []

    /// Adds one pong and returns the current estimate (`nil` with no sample).
    @discardableResult
    mutating func note(sentUs: Double, receivedUs: Double, phoneNowUs: Double,
                       at now: TimeInterval) -> Double? {
        let rtt = max(0, receivedUs - sentUs)
        samples.append(Sample(at: now, rttUs: rtt,
                              offsetUs: phoneNowUs - (sentUs + rtt / 2)))
        prune(at: now)
        return offsetUs
    }

    /// The lowest-RTT sample inside the horizon, nil when there is none.
    var offsetUs: Double? {
        samples.min { $0.rttUs < $1.rttUs }?.offsetUs
    }

    private mutating func prune(at now: TimeInterval) {
        samples.removeAll { now - $0.at > Self.horizon }
    }
}

/// What the phone reports in one `stream.stats` message: the last ~2 s of one
/// stream's encoder and send-queue counters. Absent fields are nil (`-` on the
/// log line): an older phone sends none of this, a codec without encoding
/// statistics sends no QP.
struct PhoneStreamStats: Equatable {
    var frames = 0
    var keyframes = 0
    var keyframesRequested = 0
    var bytes = 0
    var deltasDropped = 0
    var dropEpisodes = 0
    var framesSkipped = 0
    /// Q1: suspend episodes and their total length in the window.
    var suspendedEpisodes = 0
    var suspendedMs = 0
    /// T1: refined frames sent for a still period.
    var refined = 0
    var targetBps = 0
    var encodeP50Us: Double?
    var encodeP95Us: Double?
    var queueP50Us: Double?
    var queueP95Us: Double?
    var qpP50: Double?
    var qpP95: Double?

    init(json: [String: Any]) {
        frames = Self.int(json["frames"])
        keyframes = Self.int(json["kf"])
        keyframesRequested = Self.int(json["kfReq"])
        bytes = Self.int(json["bytes"])
        deltasDropped = Self.int(json["drop"])
        dropEpisodes = Self.int(json["dropEp"])
        framesSkipped = Self.int(json["skip"])
        suspendedEpisodes = Self.int(json["susp"])
        suspendedMs = Self.int(json["suspMs"])
        refined = Self.int(json["refine"])
        targetBps = Self.int(json["targetBps"])
        encodeP50Us = Self.double(json["encP50"])
        encodeP95Us = Self.double(json["encP95"])
        queueP50Us = Self.double(json["queueP50"])
        queueP95Us = Self.double(json["queueP95"])
        qpP50 = Self.double(json["qpP50"])
        qpP95 = Self.double(json["qpP95"])
    }

    /// The phone's counters are per send window; this rate is the window's.
    func kbps(windowMs: Int) -> Double {
        guard windowMs > 0 else { return 0 }
        return Double(bytes) * 8 / Double(windowMs)
    }

    private static func int(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        return number.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
}

/// Why the Mac dropped a frame instead of handing it to the picture.
enum StatsDiscardReason: String, CaseIterable {
    /// A display-layer flush took the frames it held (a config change).
    case flush
    /// The layer said it was not ready for another sample.
    case notReady = "not_ready"
    /// The frame arrived before its VIDEO_CONFIG.
    case beforeConfig = "before_config"
    /// M1's paced presenter held two already and dropped the oldest.
    case paced
}

/// One visible window's sliding 2 s window. Pure: every method takes the clock
/// (Mac monotonic seconds) and the caller feeds it from the session or main
/// queue under its own lock.
struct StreamStatsWindow {
    static let window: TimeInterval = 2
    static let freezeThreshold: TimeInterval = 0.1

    private struct Received {
        var at: TimeInterval
        var bytes: Int
    }

    private struct Enqueued {
        var at: TimeInterval
        var latencyMs: Double?
    }

    private var received: [Received] = []
    private var enqueued: [Enqueued] = []
    /// Events since the last snapshot. A 5 s log line must report a freeze
    /// that happened between its 2 s sample windows; counters, not samples.
    private var freezeCount = 0
    private var freezeMs = 0.0
    private var macDropCount = 0
    private var lastEnqueue: TimeInterval?
    private var firstReceived: TimeInterval?
    private var firstEnqueue: TimeInterval?
    private var paused = false
    private(set) var phone: PhoneStreamStats?

    /// A new VIDEO_CONFIG: the old format's samples no longer describe this
    /// stream, so the whole window restarts.
    mutating func noteConfig(now: TimeInterval) {
        received.removeAll()
        enqueued.removeAll()
        freezeCount = 0
        freezeMs = 0
        macDropCount = 0
        phone = nil
        lastEnqueue = nil
        firstReceived = nil
        firstEnqueue = nil
    }

    mutating func notePaused(_ paused: Bool, now: TimeInterval) {
        self.paused = paused
        // The covered span is not a freeze; the next frame starts a fresh one.
        if paused { lastEnqueue = nil }
        prune(now)
    }

    mutating func noteReceived(now: TimeInterval, bytes: Int) {
        if firstReceived == nil { firstReceived = now }
        received.append(Received(at: now, bytes: bytes))
        prune(now)
    }

    /// A sample reached the display layer. This is the moment `shown_fps`, the
    /// intervals and the e2e delay are measured at, so paced presentation shows
    /// its real added latency.
    mutating func noteEnqueued(now: TimeInterval, ptsUs: UInt64, offsetUs: Double?) {
        if !paused, let last = lastEnqueue, now - last > Self.freezeThreshold {
            freezeCount += 1
            freezeMs += (now - last) * 1000
        }
        if !paused { lastEnqueue = now }
        if firstEnqueue == nil { firstEnqueue = now }
        enqueued.append(Enqueued(at: now,
                                 latencyMs: Self.latency(now: now, ptsUs: ptsUs,
                                                         offsetUs: offsetUs)))
        prune(now)
    }

    mutating func noteDiscarded(_ reason: StatsDiscardReason, now: TimeInterval) {
        macDropCount += 1
        prune(now)
    }

    mutating func notePhoneStats(_ stats: PhoneStreamStats) {
        phone = stats
    }

    /// The numbers for one log line. Frames, intervals and delays cover the
    /// sliding window ending at `now`; the phone's counters are its own latest
    /// 2 s report.
    mutating func snapshot(now: TimeInterval) -> StreamStatsSnapshot {
        let start = now - Self.window
        let rec = received.filter { $0.at > start }
        let enq = enqueued.filter { $0.at > start }
        let enqLat = enq.filter { $0.latencyMs != nil }
        let frzCount = freezeCount
        let frzMs = freezeMs
        let drops = macDropCount
        freezeCount = 0
        freezeMs = 0
        macDropCount = 0

        let rxFps = Self.fps(rec.map(\.at),
                             covered: Self.covered(since: firstReceived, now: now))
        let shownFps = Self.fps(enq.map(\.at),
                                covered: Self.covered(since: firstEnqueue, now: now))
        let intervals = Self.intervals(rec.map(\.at))
        let bytes = rec.reduce(0) { $0 + $1.bytes }
        let covered = Self.covered(since: firstReceived, now: now)

        return StreamStatsSnapshot(
            receivedFrames: rec.count,
            enqueuedFrames: enq.count,
            rxFps: rxFps,
            shownFps: shownFps,
            intervalP50Ms: Self.percentile(intervals, 0.50),
            intervalP95Ms: Self.percentile(intervals, 0.95),
            intervalP99Ms: Self.percentile(intervals, 0.99),
            freezeCount: frzCount,
            freezeMs: frzMs,
            macDrop: drops,
            bytesPerSecond: covered > 0 ? Double(bytes) / covered : 0,
            e2eP50Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.50),
            e2eP95Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.95),
            enqueueP50Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.50),
            enqueueP95Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.95),
            phone: phone
        )
    }

    // MARK: Pure helpers (the K2 checks drive these directly)

    /// The observation time a rate divides by: the sliding window, or less
    /// while the stream is younger than it. A burst delivered in one run loop
    /// does not become a huge rate: the count still spans this time.
    static func covered(since first: TimeInterval?, now: TimeInterval) -> Double {
        guard let first else { return 0 }
        return min(window, max(0, now - first))
    }

    /// Frames per second from their arrival timestamps, divided by the time
    /// the window has been observed (at least 0.2 s to mean anything).
    static func fps(_ times: [TimeInterval], covered: Double) -> Double {
        guard covered >= 0.2, !times.isEmpty else { return 0 }
        return Double(times.count) / covered
    }

    /// The covered time of the samples inside the window, for a byte rate.
    static func span(_ times: [TimeInterval], now: TimeInterval) -> Double {
        guard let first = times.first, let last = times.last else { return 0 }
        return max(last - max(first, now - Self.window), 0)
    }

    static func intervals(_ times: [TimeInterval]) -> [Double] {
        guard times.count >= 2 else { return [] }
        var out: [Double] = []
        out.reserveCapacity(times.count - 1)
        for index in 1..<times.count {
            out.append((times[index] - times[index - 1]) * 1000)
        }
        return out
    }

    /// Nearest-rank percentile; nil for an empty set.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1,
                              Int((fraction * Double(sorted.count)).rounded(.up)) - 1))
        return sorted[rank]
    }

    /// Capture→local delay in ms: the frame's pts on the phone's clock mapped
    /// through the offset, against the Mac's clock now. Nil with no estimate.
    static func latency(now: TimeInterval, ptsUs: UInt64, offsetUs: Double?) -> Double? {
        guard let offsetUs else { return nil }
        let captureUs = Double(ptsUs) - offsetUs
        let delayMs = (now * 1_000_000 - captureUs) / 1000
        // A clock change can put the frame "in the future"; that is not a
        // measurement and must not pull the percentile down.
        guard delayMs >= -50, delayMs < 60_000 else { return nil }
        return delayMs
    }

    private mutating func prune(_ now: TimeInterval) {
        let start = now - Self.window
        received.removeAll { $0.at <= start }
        enqueued.removeAll { $0.at <= start }
    }
}

struct StreamStatsSnapshot {
    var receivedFrames = 0
    var enqueuedFrames = 0
    var rxFps = 0.0
    var shownFps = 0.0
    var intervalP50Ms: Double?
    var intervalP95Ms: Double?
    var intervalP99Ms: Double?
    var freezeCount = 0
    var freezeMs = 0.0
    var macDrop = 0
    var bytesPerSecond = 0.0
    var e2eP50Ms: Double?
    var e2eP95Ms: Double?
    var enqueueP50Ms: Double?
    var enqueueP95Ms: Double?
    var phone: PhoneStreamStats?
}

/// The one `notice` line per visible window every 5 s. Numbers only: no
/// titles, package names, URLs or pixels (R-PRIV-1). A missing value is `-`.
enum StreamStatsLine {
    static func text(stream: UInt32, size: CGSize, view: CGSize, place: String,
                     stats: StreamStatsSnapshot) -> String {
        let phone = stats.phone
        let kbps = phone.map { $0.kbps(windowMs: 2000) } ?? 0
        let qp = phone.map { $0.qpP50 != nil || $0.qpP95 != nil } ?? false
        return [
            "stats stream=\(stream)",
            "size=\(Int(size.width.rounded()))x\(Int(size.height.rounded()))",
            "view=\(Int(view.width.rounded()))x\(Int(view.height.rounded()))",
            "place=\(place)",
            "rx_fps=\(one(stats.rxFps))",
            "shown_fps=\(one(stats.shownFps))",
            "int_p95=\(one(stats.intervalP95Ms))",
            "int_p99=\(one(stats.intervalP99Ms))",
            "freeze_n=\(stats.freezeCount)",
            "freeze_ms=\(Int(stats.freezeMs.rounded()))",
            "mac_drop=\(stats.macDrop)",
            "phone_drop=\(phone?.deltasDropped ?? 0)",
            "drop_ep=\(phone?.dropEpisodes ?? 0)",
            "skip=\(phone?.framesSkipped ?? 0)",
            "susp_n=\(phone?.suspendedEpisodes ?? 0)",
            "susp_ms=\(phone?.suspendedMs ?? 0)",
            "refine_n=\(phone?.refined ?? 0)",
            "kf=\(phone?.keyframes ?? 0)",
            "kf_req=\(phone?.keyframesRequested ?? 0)",
            "kbps=\(Int(kbps.rounded()))",
            "target_kbps=\(phone.map { Int((Double($0.targetBps) / 1000).rounded()) } ?? 0)",
            "qp_p50=\(qp ? one(phone?.qpP50) : "-")",
            "qp_p95=\(qp ? one(phone?.qpP95) : "-")",
            "enc_p50=\(ms(phone?.encodeP50Us))",
            "enc_p95=\(ms(phone?.encodeP95Us))",
            "queue_p95=\(ms(phone?.queueP95Us))",
            "e2e_p50=\(one(stats.e2eP50Ms))",
            "e2e_p95=\(one(stats.e2eP95Ms))",
        ].joined(separator: " ")
    }

    static func one(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.1f", value)
    }

    static func ms(_ us: Double?) -> String {
        guard let us, us.isFinite else { return "-" }
        return String(format: "%.1f", us / 1000)
    }
}

/// When the Mac asks the phone for `stream.stats`, one decision per session:
/// on with the first open window, off when the last one closes (and a new
/// session starts off). The actions are the caller's; the machine only says
/// whether the wire state must change.
struct StatsSubscription {
    enum State: Equatable { case off, on }

    private(set) var state: State = .off

    /// A window set changed. Returns the new `stream.stats {on}` value when the
    /// wire must change, nil when it already agrees.
    mutating func windowsChanged(open: Int) -> Bool? {
        switch (state, open > 0) {
        case (.off, true):
            state = .on
            return true
        case (.on, false):
            state = .off
            return false
        case (.on, true), (.off, false):
            return nil
        }
    }

    /// A session ended: the next one starts off. Nothing goes on the wire (the
    /// phone is gone).
    mutating func sessionEnded() {
        state = .off
    }
}

/// Thread-safe home for one window's `StreamStatsWindow`: frames arrive on the
/// session's video queue, enqueue/discard callbacks on the main queue, and the
/// 5 s log line reads both. The lock is one short section per event; the frame
/// path does no allocation beyond the small sample record.
final class StreamStatsRecorder {
    private var model = StreamStatsWindow()
    private let lock = NSLock()

    func noteConfig(now: TimeInterval) {
        lock.lock(); model.noteConfig(now: now); lock.unlock()
    }

    func notePaused(_ paused: Bool, now: TimeInterval) {
        lock.lock(); model.notePaused(paused, now: now); lock.unlock()
    }

    func noteReceived(now: TimeInterval, bytes: Int) {
        lock.lock(); model.noteReceived(now: now, bytes: bytes); lock.unlock()
    }

    func noteEnqueued(now: TimeInterval, ptsUs: UInt64, offsetUs: Double?) {
        lock.lock(); model.noteEnqueued(now: now, ptsUs: ptsUs, offsetUs: offsetUs); lock.unlock()
    }

    func noteDiscarded(_ reason: StatsDiscardReason, now: TimeInterval) {
        lock.lock(); model.noteDiscarded(reason, now: now); lock.unlock()
    }

    func notePhoneStats(_ stats: PhoneStreamStats) {
        lock.lock(); model.notePhoneStats(stats); lock.unlock()
    }

    func snapshot(now: TimeInterval) -> StreamStatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return model.snapshot(now: now)
    }
}
