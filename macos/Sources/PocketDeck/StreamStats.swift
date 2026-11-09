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
///
/// The phone's CLOCK_MONOTONIC stops while it sleeps, so the offset jumps
/// between windows. A pong further from the estimate than the two RTTs can
/// explain — (its RTT + the estimate's RTT) / 2 + 5 ms — is a new clock, not a
/// slow one: the window restarts from that sample at once.
struct ClockOffsetEstimator {
    struct Sample: Equatable {
        /// When the pong arrived, Mac monotonic seconds (the 30 s horizon).
        var at: TimeInterval
        var rttUs: Double
        var offsetUs: Double
    }

    /// One pong's effect on the estimate.
    struct Note: Equatable {
        /// The estimate after the sample, nil before the first one.
        var offsetUs: Double?
        /// The restart's jump in ms when this sample was a clock jump.
        var jumpMs: Double?
    }

    static let horizon: TimeInterval = 30
    /// Slack over the two half-RTTs: a LAN sample's jitter, never a clock step.
    static let jumpSlackUs: Double = 5_000

    private(set) var samples: [Sample] = []

    /// Adds one pong and returns the estimate and whether it restarted.
    @discardableResult
    mutating func note(sentUs: Double, receivedUs: Double, phoneNowUs: Double,
                       at now: TimeInterval) -> Note {
        prune(at: now)
        let rtt = max(0, receivedUs - sentUs)
        let offset = phoneNowUs - (sentUs + rtt / 2)
        if let current = estimateSample {
            let boundUs = (rtt + current.rttUs) / 2 + Self.jumpSlackUs
            if abs(offset - current.offsetUs) > boundUs {
                samples = [Sample(at: now, rttUs: rtt, offsetUs: offset)]
                return Note(offsetUs: offset,
                            jumpMs: (offset - current.offsetUs) / 1000)
            }
        }
        samples.append(Sample(at: now, rttUs: rtt, offsetUs: offset))
        return Note(offsetUs: offsetUs, jumpMs: nil)
    }

    /// The lowest-RTT sample inside the horizon, nil when there is none.
    private var estimateSample: Sample? {
        samples.min { $0.rttUs < $1.rttUs }
    }

    var offsetUs: Double? { estimateSample?.offsetUs }

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
    /// ISS-40 round 3: key-flagged buffers with and without a type-5 slice.
    var keyIdr = 0
    var keyNotIdr = 0
    var keyframesRequested = 0
    var bytes = 0
    var deltasDropped = 0
    var dropEpisodes = 0
    /// The measured pts gap of each drop episode, in ms. Absent on an older
    /// phone: the Mac prints `drop_ms=-`.
    var dropGapMs: Int?
    var framesSkipped = 0
    /// Q1: suspend episodes and their total length in the window.
    var suspendedEpisodes = 0
    var suspendedMs = 0
    /// T1: refined frames sent for a still period.
    var refined = 0
    var targetBps = 0
    /// The stream's codec token and the mean of its frame QPs in this window.
    var codec: String?
    var qpAvg: Double?
    var encodeP50Us: Double?
    var encodeP95Us: Double?
    var queueP50Us: Double?
    var queueP95Us: Double?
    var qpP50: Double?
    var qpP95: Double?
    /// X0: the phone's system-wide TCP deltas for the message's window.
    /// Absent when the phone could not read `/proc/net` (or is older).
    var retransmissions: Int?
    var rtoTimeouts: Int?
    var lostRetransmits: Int?
    /// The phone's own measuring window; summed when two messages fold into
    /// one line, so `kbps` divides by the time they cover together.
    var windowMs = 2_000

    init(json: [String: Any]) {
        frames = Self.int(json["frames"])
        keyframes = Self.int(json["kf"])
        keyIdr = Self.int(json["keyIdr"])
        keyNotIdr = Self.int(json["keyNotIdr"])
        keyframesRequested = Self.int(json["kfReq"])
        bytes = Self.int(json["bytes"])
        deltasDropped = Self.int(json["drop"])
        dropEpisodes = Self.int(json["dropEp"])
        dropGapMs = Self.optionalInt(json["dropGapMs"])
        framesSkipped = Self.int(json["skip"])
        suspendedEpisodes = Self.int(json["susp"])
        suspendedMs = Self.int(json["suspMs"])
        refined = Self.int(json["refine"])
        targetBps = Self.int(json["targetBps"])
        codec = (json["codec"] as? String).flatMap { name in
            name == VideoCodec.avc.token || name == VideoCodec.hevc.token ? name : nil
        }
        qpAvg = Self.double(json["qpAvg"])
        encodeP50Us = Self.double(json["encP50"])
        encodeP95Us = Self.double(json["encP95"])
        queueP50Us = Self.double(json["queueP50"])
        queueP95Us = Self.double(json["queueP95"])
        qpP50 = Self.double(json["qpP50"])
        qpP95 = Self.double(json["qpP95"])
        retransmissions = Self.optionalInt(json["retrans"])
        rtoTimeouts = Self.optionalInt(json["rto"])
        lostRetransmits = Self.optionalInt(json["lost_retrans"])
        windowMs = Self.optionalInt(json["windowMs"]).flatMap { $0 > 0 ? $0 : nil } ?? 2_000
    }

    /// One line covers every message since the previous one: the counters add
    /// up, the levels stay the latest message's.
    mutating func addCounters(_ other: PhoneStreamStats) {
        frames += other.frames
        keyframes += other.keyframes
        keyIdr += other.keyIdr
        keyNotIdr += other.keyNotIdr
        keyframesRequested += other.keyframesRequested
        bytes += other.bytes
        deltasDropped += other.deltasDropped
        dropEpisodes += other.dropEpisodes
        if let gap = other.dropGapMs { dropGapMs = (dropGapMs ?? 0) + gap }
        framesSkipped += other.framesSkipped
        suspendedEpisodes += other.suspendedEpisodes
        suspendedMs += other.suspendedMs
        refined += other.refined
        if let retrans = other.retransmissions {
            retransmissions = (retransmissions ?? 0) + retrans
        }
        if let timeouts = other.rtoTimeouts {
            rtoTimeouts = (rtoTimeouts ?? 0) + timeouts
        }
        if let lost = other.lostRetransmits {
            lostRetransmits = (lostRetransmits ?? 0) + lost
        }
        windowMs += other.windowMs
    }

    mutating func takeLevels(from other: PhoneStreamStats) {
        targetBps = other.targetBps
        codec = other.codec
        qpAvg = other.qpAvg
        encodeP50Us = other.encodeP50Us
        encodeP95Us = other.encodeP95Us
        queueP50Us = other.queueP50Us
        queueP95Us = other.queueP95Us
        qpP50 = other.qpP50
        qpP95 = other.qpP95
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

    private static func optionalInt(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
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
    /// The layer said it was not ready for another sample. The sample is
    /// still enqueued (AVFoundation documents enqueueing while not ready as
    /// safe), so this alone does not break the reference chain.
    case notReady = "not_ready"
    /// The frame arrived before its VIDEO_CONFIG.
    case beforeConfig = "before_config"
    /// M1's paced presenter showed the frame without its own refresh. Every
    /// waiting frame is handed over in order, so the chain stays intact.
    case paced
    /// The delta was held because the chain was broken: no decoder got it
    /// until a keyframe (WIN-61).
    case awaitingKey = "awaiting_key"
    /// R6: the chunk assembler threw an incomplete access unit away. The feed
    /// breaks (WIN-62's `incomplete`) and holds deltas until a keyframe.
    case incomplete
}

/// What a wire-key frame's NAL types say: it cannot restart the decoder
/// (`types`, also the first three per stream), or it says nothing new (`none`).
/// The time a drop takes to recover is the phone's `drop:` line and the Mac's
/// `max_gap_ms`: the phone's drop report arrives in a 2 s stats message, often
/// after the recovery IDR, so the Mac cannot time it from that message.
enum KeyFrameNote: Equatable {
    case none
    case types(String)
}

/// One visible window's sliding 2 s window. Pure: every method takes the clock
/// (Mac monotonic seconds) and the caller feeds it from the session or main
/// queue under its own lock.
struct StreamStatsWindow {
    static let window: TimeInterval = 2
    static let freezeThreshold: TimeInterval = 0.1
    /// A frame handed over more than this after its capture step is a hitch:
    /// three refreshes at 60 Hz.
    static let hitchThreshold: TimeInterval = 0.05

    private struct Received {
        var at: TimeInterval
        var bytes: Int
    }

    private struct Enqueued {
        var at: TimeInterval
        var latencyMs: Double?
        /// shownGap − ptsGap in ms; nil when there is no earlier frame to
        /// compare against (the first frame, a pause, a config, a pts reset).
        var lateMs: Double?
    }

    private var received: [Received] = []
    private var enqueued: [Enqueued] = []
    /// Events since the last snapshot. A 5 s log line must report a freeze
    /// that happened between its 2 s sample windows; counters, not samples.
    private var freezeCount = 0
    private var freezeMs = 0.0
    private var hitchCount = 0
    private var hitchMs = 0.0
    /// Discards since the previous line, by the path that made them: the 5 s
    /// line splits `mac_drop` so a flush is never mistaken for `not_ready`.
    private var macDropCounts: [StatsDiscardReason: Int] = [:]
    /// Deltas handed to the layer while the chain was known broken. The gate
    /// makes this zero; a non-zero is the corruption in ISS-54.
    private var chainFedCount = 0
    /// ISS-40 round 3: key-flagged frames whose units carry no IDR.
    private var keyNotIdr = 0
    private var totalKeyNotIdr = 0
    private var keyNotIdrLogged = 0
    /// ISS-40 round 3: the longest interval between received frames. The line
    /// covers the time since the previous line; the totals the whole life.
    /// `lastReceived` survives `noteConfig` on purpose: a resize in the middle
    /// of a gap does not mean the picture came back.
    private var lastReceived: TimeInterval?
    private var lineMaxGapMs = 0.0
    private var totalMaxGapMs = 0.0
    private var lastEnqueue: TimeInterval?
    private var lastEnqueuePtsUs: UInt64?
    private var firstReceived: TimeInterval?
    private var firstEnqueue: TimeInterval?
    private var paused = false
    /// When the current covered span began; the totals line charges it.
    private var pausedAt: TimeInterval?
    /// The phone's counters since the previous line, summed across messages;
    /// the levels are the latest message's. `phoneMessages` counts how many
    /// arrived, so a line with none is visible (`phone_n=0`).
    private(set) var phone: PhoneStreamStats?
    private(set) var phoneMessages = 0

    // X0: the stream socket's own readings. The cumulative out-of-order byte
    // count gives each line its delta and the totals the whole life; a config
    // or a pause resets neither.
    private var firstTCP: TCPConnectionInfo?
    private var latestTCP: TCPConnectionInfo?
    private var lastLineTCP: TCPConnectionInfo?
    private var tcpSrttMaxMs: Int?

    // The window's whole life, for the one line at close. None of this is
    // consumed by the 5 s lines or reset by a config.
    private let startedAt: TimeInterval
    private var totalReceived = 0
    /// The frame bytes this Mac actually received, for the run's own rate.
    /// The phone's `bytes` counter says what it queued, not what arrived.
    private var totalReceivedBytes = 0
    /// Every arrival and display interval over the window's life, thinned to
    /// bounded memory: the stage distributions, not only their p95 (pmaxx P0).
    private var totalIntervals = ThinnedSamples()
    private var totalShownIntervals = ThinnedSamples()
    private var totalEnqueued = 0
    private var totalHitchCount = 0
    private var totalHitchMs = 0.0
    private var totalLateMs = ThinnedSamples()
    private var totalLatencyMs = ThinnedSamples()
    private var totalCoveredMs = 0.0
    private var totalPhoneMessages = 0
    private var totalPhoneFrames = 0
    private var totalPhoneKeyframes = 0
    private var totalPhoneKeyIdr = 0
    private var totalPhoneKeyNotIdr = 0
    private var totalPhoneKeyframesRequested = 0
    private var totalDropEpisodes = 0
    private var totalDropGapMs: Int?
    private var totalSuspendedEpisodes = 0
    private var totalSuspendedMs = 0
    private var totalPhoneBytes = 0
    private var totalPhoneRetransmissions: Int?
    private var totalPhoneRTOs: Int?
    private var totalPhoneLostRetransmits: Int?
    /// The phone's latest codec token and the frame-weighted QP mean over the
    /// window's whole life.
    private var latestCodec: String?
    private var totalQpWeighted = 0.0
    private var totalQpFrames = 0

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        startedAt = now
    }

    /// A new VIDEO_CONFIG: the old format's samples no longer describe this
    /// stream, so the Mac's window restarts. The phone's counters already
    /// received cover time this line still owns; they stay.
    mutating func noteConfig(now: TimeInterval) {
        received.removeAll()
        enqueued.removeAll()
        freezeCount = 0
        freezeMs = 0
        hitchCount = 0
        hitchMs = 0
        macDropCounts = [:]
        chainFedCount = 0
        lastEnqueue = nil
        lastEnqueuePtsUs = nil
        firstReceived = nil
        firstEnqueue = nil
        // `lastReceived` and the max-gap values stay: a config can land in
        // the middle of a gap, and that gap still happened.
    }

    mutating func notePaused(_ paused: Bool, now: TimeInterval) {
        let was = self.paused
        self.paused = paused
        if paused && !was {
            pausedAt = now
        } else if !paused, let began = pausedAt {
            totalCoveredMs += max(0, now - began) * 1000
            pausedAt = nil
        }
        // The covered span is not a freeze or a picture gap: the next frame
        // starts a fresh one.
        if paused {
            lastEnqueue = nil
            lastEnqueuePtsUs = nil
            lastReceived = nil
        }
        prune(now)
    }

    mutating func noteReceived(now: TimeInterval, bytes: Int) {
        if firstReceived == nil { firstReceived = now }
        // While covered, a frame already in flight must not restart the gap
        // clock: the covered silence is not a picture gap.
        if !paused {
            if let last = lastReceived, now > last {
                let gapMs = (now - last) * 1000
                lineMaxGapMs = max(lineMaxGapMs, gapMs)
                totalMaxGapMs = max(totalMaxGapMs, gapMs)
                totalIntervals.append(gapMs)
            }
            lastReceived = now
        }
        received.append(Received(at: now, bytes: bytes))
        totalReceived += 1
        totalReceivedBytes += bytes
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
        var lateMs: Double?
        if !paused, let last = lastEnqueue, let lastPts = lastEnqueuePtsUs, ptsUs > lastPts {
            let shownGap = now - last
            totalShownIntervals.append(shownGap * 1000)
            let ptsGap = Double(ptsUs - lastPts) / 1_000_000
            let late = shownGap - ptsGap
            lateMs = late * 1000
            if late > Self.hitchThreshold {
                hitchCount += 1
                hitchMs += late * 1000
                totalHitchCount += 1
                totalHitchMs += late * 1000
            }
        }
        if let lateMs { totalLateMs.append(lateMs) }
        let latencyMs = Self.latency(now: now, ptsUs: ptsUs, offsetUs: offsetUs)
        if let latencyMs { totalLatencyMs.append(latencyMs) }
        totalEnqueued += 1
        if !paused {
            lastEnqueue = now
            lastEnqueuePtsUs = ptsUs
        }
        if firstEnqueue == nil { firstEnqueue = now }
        enqueued.append(Enqueued(at: now,
                                 latencyMs: latencyMs,
                                 lateMs: lateMs))
        prune(now)
    }

    mutating func noteDiscarded(_ reason: StatsDiscardReason, now: TimeInterval) {
        macDropCounts[reason, default: 0] += 1
        prune(now)
    }

    /// A delta reached the layer while the chain was known broken. The gate
    /// keeps this at zero (WIN-61); the field is the field-log proof.
    mutating func noteChainFed(now: TimeInterval) {
        chainFedCount += 1
        prune(now)
    }

    /// A wire-key frame's NAL types. A frame with no IDR unit cannot restart
    /// the decoder, so it is counted as `key_not_idr`; the types are already in
    /// [codec]'s numbering (AVC 5; HEVC 19/20, a CRA 21 is not an IDR). The
    /// first three per stream also return their types for the field log.
    mutating func noteKeyFrame(isKeyframe: Bool, nalTypes: [UInt8],
                               codec: VideoCodec = .avc,
                               now: TimeInterval) -> KeyFrameNote {
        guard isKeyframe else { return .none }
        let idr: Bool
        switch codec {
        case .avc:
            idr = nalTypes.contains(H264NalType.sliceIdr.rawValue)
        case .hevc:
            idr = nalTypes.contains(HEVCNalType.sliceIdrWRADL.rawValue)
                || nalTypes.contains(HEVCNalType.sliceIdrNLp.rawValue)
        }
        if idr { return .none }
        keyNotIdr += 1
        totalKeyNotIdr += 1
        guard keyNotIdrLogged < 3 else { return .none }
        keyNotIdrLogged += 1
        return .types(nalTypes.map(String.init).joined(separator: ","))
    }

    mutating func notePhoneStats(_ stats: PhoneStreamStats) {
        phoneMessages += 1
        if let codec = stats.codec { latestCodec = codec }
        if let average = stats.qpAvg, stats.frames > 0 {
            totalQpWeighted += average * Double(stats.frames)
            totalQpFrames += stats.frames
        }
        if var accumulated = phone {
            accumulated.addCounters(stats)
            accumulated.takeLevels(from: stats)
            phone = accumulated
        } else {
            phone = stats
        }
        totalPhoneMessages += 1
        totalPhoneFrames += stats.frames
        totalPhoneKeyframes += stats.keyframes
        totalPhoneKeyIdr += stats.keyIdr
        totalPhoneKeyNotIdr += stats.keyNotIdr
        totalPhoneKeyframesRequested += stats.keyframesRequested
        totalDropEpisodes += stats.dropEpisodes
        if let gap = stats.dropGapMs { totalDropGapMs = (totalDropGapMs ?? 0) + gap }
        totalSuspendedEpisodes += stats.suspendedEpisodes
        totalSuspendedMs += stats.suspendedMs
        totalPhoneBytes += stats.bytes
        if let retrans = stats.retransmissions {
            totalPhoneRetransmissions = (totalPhoneRetransmissions ?? 0) + retrans
        }
        if let timeouts = stats.rtoTimeouts {
            totalPhoneRTOs = (totalPhoneRTOs ?? 0) + timeouts
        }
        if let lost = stats.lostRetransmits {
            totalPhoneLostRetransmits = (totalPhoneLostRetransmits ?? 0) + lost
        }
    }

    /// The window's whole life, for the line at close. Percentiles cover every
    /// shown frame, not the last 2 s; `coveredMs` counts the pause so far.
    mutating func total(now: TimeInterval, tcpInfo: TCPConnectionInfo? = nil) -> StreamStatsTotal {
        let covered = totalCoveredMs + (pausedAt.map { max(0, now - $0) * 1000 } ?? 0)
        noteTCPLifetime(tcpInfo)
        return StreamStatsTotal(
            seconds: max(0, now - startedAt),
            receivedFrames: totalReceived,
            enqueuedFrames: totalEnqueued,
            hitchCount: totalHitchCount,
            hitchMs: totalHitchMs,
            lateP99Ms: Self.percentile(totalLateMs.values, 0.99),
            phoneMessages: totalPhoneMessages,
            phoneFrames: totalPhoneFrames,
            phoneKeyframes: totalPhoneKeyframes,
            phoneKeyIdr: totalPhoneKeyIdr,
            phoneKeyNotIdr: totalPhoneKeyNotIdr,
            phoneKeyframesRequested: totalPhoneKeyframesRequested,
            dropEpisodes: totalDropEpisodes,
            dropGapMs: totalDropGapMs,
            suspendedEpisodes: totalSuspendedEpisodes,
            suspendedMs: totalSuspendedMs,
            phoneBytes: totalPhoneBytes,
            receivedBytes: totalReceivedBytes,
            e2eP50Ms: Self.percentile(totalLatencyMs.values, 0.50),
            e2eP95Ms: Self.percentile(totalLatencyMs.values, 0.95),
            e2eP99Ms: Self.percentile(totalLatencyMs.values, 0.99),
            intervalP50Ms: Self.percentile(totalIntervals.values, 0.50),
            intervalP95Ms: Self.percentile(totalIntervals.values, 0.95),
            intervalP99Ms: Self.percentile(totalIntervals.values, 0.99),
            shownP50Ms: Self.percentile(totalShownIntervals.values, 0.50),
            shownP95Ms: Self.percentile(totalShownIntervals.values, 0.95),
            shownP99Ms: Self.percentile(totalShownIntervals.values, 0.99),
            coveredMs: covered,
            maxGapMs: totalMaxGapMs,
            keyNotIdr: totalKeyNotIdr,
            tcpOutOfOrderKB: Self.deltaKB(latest: latestTCP, first: firstTCP),
            tcpSrttMaxMs: tcpSrttMaxMs,
            phoneRetransmissions: totalPhoneRetransmissions,
            phoneRTOs: totalPhoneRTOs,
            phoneLostRetransmits: totalPhoneLostRetransmits,
            codec: latestCodec,
            qpAvg: totalQpFrames > 0 ? totalQpWeighted / Double(totalQpFrames) : nil
        )
    }

    /// The numbers for one log line. Frames, intervals and delays cover the
    /// sliding window ending at `now`; the phone's counters cover every
    /// message since the previous line (the line consumes them).
    mutating func snapshot(now: TimeInterval,
                           tcpInfo: TCPConnectionInfo? = nil) -> StreamStatsSnapshot {
        let link = noteTCPLine(tcpInfo)
        let start = now - Self.window
        let rec = received.filter { $0.at > start }
        let enq = enqueued.filter { $0.at > start }
        let enqLat = enq.filter { $0.latencyMs != nil }
        let frzCount = freezeCount
        let frzMs = freezeMs
        let hitches = hitchCount
        let hitchTime = hitchMs
        let drops = macDropCounts
        let chainFed = chainFedCount
        let keys = keyNotIdr
        let maxGap = lineMaxGapMs
        let phoneStats = phone
        let phoneCount = phoneMessages
        freezeCount = 0
        freezeMs = 0
        hitchCount = 0
        hitchMs = 0
        macDropCounts = [:]
        chainFedCount = 0
        keyNotIdr = 0
        lineMaxGapMs = 0
        phone = nil
        phoneMessages = 0

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
            hitchCount: hitches,
            hitchMs: hitchTime,
            lateP99Ms: Self.percentile(enq.compactMap(\.lateMs), 0.99),
            macDrop: drops.values.reduce(0, +),
            macDrops: drops,
            chainFed: chainFed,
            bytesPerSecond: covered > 0 ? Double(bytes) / covered : 0,
            e2eP50Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.50),
            e2eP95Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.95),
            enqueueP50Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.50),
            enqueueP95Ms: Self.percentile(enqLat.compactMap(\.latencyMs), 0.95),
            phone: phoneStats,
            phoneMessages: phoneCount,
            keyNotIdr: keys,
            maxGapMs: maxGap,
            tcpSrttMs: link.srttMs,
            tcpRttvar: link.rttvar,
            tcpOutOfOrderKB: link.outOfOrderKB
        )
    }

    /// One line's socket numbers. `srtt`/`rttvar` are levels (the latest
    /// reading); `outOfOrderKB` subtracts the previous good reading, nil on
    /// the first line. A failed read leaves the baseline alone so the next
    /// good reading covers both lines.
    private mutating func noteTCPLine(_ info: TCPConnectionInfo?)
        -> (srttMs: Int?, rttvar: Int?, outOfOrderKB: Double?) {
        guard let info else { return (nil, nil, nil) }
        noteTCPLifetime(info)
        let delta = Self.deltaKB(latest: info, first: lastLineTCP)
        lastLineTCP = info
        return (info.srttMs, info.rttvar, delta)
    }

    /// The window's whole life: first reading, latest reading, worst SRTT.
    private mutating func noteTCPLifetime(_ info: TCPConnectionInfo?) {
        guard let info else { return }
        if firstTCP == nil { firstTCP = info }
        latestTCP = info
        tcpSrttMaxMs = max(tcpSrttMaxMs ?? info.srttMs, info.srttMs)
    }

    /// Cumulative counter to a KB delta; a counter that went backwards is no
    /// measurement rather than a negative reading.
    static func deltaKB(latest: TCPConnectionInfo?, first: TCPConnectionInfo?) -> Double? {
        guard let latest, let first,
              latest.rxOutOfOrderBytes >= first.rxOutOfOrderBytes else { return nil }
        return Double(latest.rxOutOfOrderBytes - first.rxOutOfOrderBytes) / 1024
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
    var hitchCount = 0
    var hitchMs = 0.0
    var lateP99Ms: Double?
    var macDrop = 0
    /// The same discards split by the path that made them (WIN-61).
    var macDrops: [StatsDiscardReason: Int] = [:]
    /// Deltas fed while the chain was broken; the gate keeps it at 0.
    var chainFed = 0
    var bytesPerSecond = 0.0
    var e2eP50Ms: Double?
    var e2eP95Ms: Double?
    var enqueueP50Ms: Double?
    var enqueueP95Ms: Double?
    var phone: PhoneStreamStats?
    /// How many phone messages this line folded in (0 when none arrived).
    var phoneMessages = 0
    /// ISS-40 round 3: wire-key frames with no type-5 unit since the last line.
    var keyNotIdr = 0
    /// ISS-40 round 3: the longest gap between received frames since the
    /// previous line, outside covered time.
    var maxGapMs = 0.0
    /// X0: the socket's smoothed RTT and variance (ms), and the bytes that
    /// arrived out of order since the previous line (KB). Nil is `-`.
    var tcpSrttMs: Int?
    var tcpRttvar: Int?
    var tcpOutOfOrderKB: Double?
}

/// One value per shown frame over a window's whole life, for the closing
/// percentiles, in bounded memory. Below `capacity` it keeps every value. At
/// capacity it drops every other one and from then on keeps one value in two
/// (then four, …), so the record stays even over the window's life: a window
/// left open for hours holds at most `capacity` values, not one per frame.
struct ThinnedSamples {
    private(set) var values: [Double] = []
    private let capacity: Int
    private var keepEvery = 1
    private var sinceKept = 0

    init(capacity: Int = 16_384) {
        self.capacity = max(2, capacity)
    }

    mutating func append(_ value: Double) {
        sinceKept += 1
        guard sinceKept >= keepEvery else { return }
        sinceKept = 0
        values.append(value)
        if values.count >= capacity {
            values = Swift.stride(from: 0, to: values.count, by: 2).map { values[$0] }
            keepEvery *= 2
        }
    }
}

/// One window's counters over its whole life, read once when it closes.
struct StreamStatsTotal {
    var seconds: Double
    var receivedFrames: Int
    var enqueuedFrames: Int
    var hitchCount: Int
    var hitchMs: Double
    var lateP99Ms: Double?
    var phoneMessages: Int
    var phoneFrames: Int
    var phoneKeyframes: Int
    var phoneKeyIdr: Int = 0
    var phoneKeyNotIdr: Int = 0
    var phoneKeyframesRequested: Int
    var dropEpisodes: Int
    var dropGapMs: Int?
    var suspendedEpisodes: Int
    var suspendedMs: Int
    var phoneBytes: Int
    /// The bytes the Mac's own frame path received over the window's life.
    var receivedBytes: Int
    var e2eP50Ms: Double?
    var e2eP95Ms: Double?
    /// P0 (pmaxx): the tail a person feels as a stall, plus the arrival and
    /// display interval distributions over the whole life.
    var e2eP99Ms: Double?
    var intervalP50Ms: Double?
    var intervalP95Ms: Double?
    var intervalP99Ms: Double?
    var shownP50Ms: Double?
    var shownP95Ms: Double?
    var shownP99Ms: Double?
    var coveredMs: Double
    /// ISS-40 round 3: the longest gap between received frames over the
    /// window's life, outside covered time, and the wire-key frames with no
    /// type-5 unit over the same life.
    var maxGapMs = 0.0
    var keyNotIdr = 0
    /// X0: out-of-order bytes over the window's life (KB) and its worst SRTT.
    var tcpOutOfOrderKB: Double?
    var tcpSrttMaxMs: Int?
    /// X0: the phone's system-wide TCP deltas over the window's life.
    var phoneRetransmissions: Int?
    var phoneRTOs: Int?
    var phoneLostRetransmits: Int?
    /// WIN-59: the stream's codec and the phone's frame-weighted QP mean.
    var codec: String?
    var qpAvg: Double?
}

/// The one `notice` line per visible window every 5 s. Numbers only: no
/// titles, package names, URLs or pixels (R-PRIV-1). A missing value is `-`.
enum StreamStatsLine {
    static func text(stream: UInt32, size: CGSize, view: CGSize, place: String,
                     stats: StreamStatsSnapshot) -> String {
        let phone = stats.phone
        let kbps = phone.map { $0.kbps(windowMs: $0.windowMs) }
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
            "hitch_n=\(stats.hitchCount)",
            "hitch_ms=\(Int(stats.hitchMs.rounded()))",
            "late_p99=\(one(stats.lateP99Ms))",
            "mac_drop=\(stats.macDrop)",
            "mac_drop_flush=\(stats.macDrops[.flush] ?? 0)",
            "mac_drop_not_ready=\(stats.macDrops[.notReady] ?? 0)",
            "mac_drop_before_config=\(stats.macDrops[.beforeConfig] ?? 0)",
            "mac_drop_paced=\(stats.macDrops[.paced] ?? 0)",
            "mac_drop_awaiting_key=\(stats.macDrops[.awaitingKey] ?? 0)",
            "mac_drop_incomplete=\(stats.macDrops[.incomplete] ?? 0)",
            "chain_fed=\(stats.chainFed)",
            "phone_drop=\(phone?.deltasDropped ?? 0)",
            "drop_ep=\(phone?.dropEpisodes ?? 0)",
            "drop_ms=\(phone.map { $0.dropGapMs.map(String.init) ?? "-" } ?? "0")",
            "phone_n=\(stats.phoneMessages)",
            "skip=\(phone?.framesSkipped ?? 0)",
            "susp_n=\(phone?.suspendedEpisodes ?? 0)",
            "susp_ms=\(phone?.suspendedMs ?? 0)",
            "refine_n=\(phone?.refined ?? 0)",
            "kf=\(phone?.keyframes ?? 0)",
            "key_not_idr=\(stats.keyNotIdr)",
            "ph_key_not_idr=\(phone?.keyNotIdr ?? 0)",
            "kf_req=\(phone?.keyframesRequested ?? 0)",
            "kbps=\(kbps.map { String(Int($0.rounded())) } ?? "-")",
            "target_kbps=\(phone.map { String(Int((Double($0.targetBps) / 1000).rounded())) } ?? "-")",
            "qp_p50=\(qp ? one(phone?.qpP50) : "-")",
            "qp_p95=\(qp ? one(phone?.qpP95) : "-")",
            "enc_p50=\(ms(phone?.encodeP50Us))",
            "enc_p95=\(ms(phone?.encodeP95Us))",
            "queue_p95=\(ms(phone?.queueP95Us))",
            "e2e_p50=\(one(stats.e2eP50Ms))",
            "e2e_p95=\(one(stats.e2eP95Ms))",
            "max_gap_ms=\(Int(stats.maxGapMs.rounded()))",
            "tcp_srtt=\(stats.tcpSrttMs.map(String.init) ?? "-")",
            "tcp_rttvar=\(stats.tcpRttvar.map(String.init) ?? "-")",
            "tcp_ooo_kb=\(stats.tcpOutOfOrderKB.map { one($0) } ?? "-")",
            "ph_retrans=\(phone.map { $0.retransmissions.map(String.init) ?? "-" } ?? "-")",
            "ph_rto=\(phone.map { $0.rtoTimeouts.map(String.init) ?? "-" } ?? "-")",
            "ph_lost=\(phone.map { $0.lostRetransmits.map(String.init) ?? "-" } ?? "-")",
            "codec=\(phone?.codec ?? "-")",
            "qp_avg=\(phone?.qpAvg.map { one($0) } ?? "-")",
        ].joined(separator: " ")
    }

    /// The two event lines a key frame may write. Types and durations only.
    static func keyNote(stream: UInt32, note: KeyFrameNote) -> String? {
        switch note {
        case .none:
            return nil
        case .types(let types):
            return "stream \(stream) key nal=\(types)"
        }
    }

    static func one(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.1f", value)
    }

    static func ms(_ us: Double?) -> String {
        guard let us, us.isFinite else { return "-" }
        return String(format: "%.1f", us / 1000)
    }

    /// The one line a window writes as it closes (WIN-55/56): every counter
    /// over its whole life, `covered_ms` the pause it spent hidden.
    static func totalText(stream: UInt32, total: StreamStatsTotal) -> String {
        let rxKbps = total.seconds > 0
            ? Double(total.receivedBytes) * 8 / (total.seconds * 1000)
            : nil
        return [
            "stats total stream=\(stream)",
            "secs=\(String(format: "%.1f", total.seconds))",
            "rx_frames=\(total.receivedFrames)",
            "shown_frames=\(total.enqueuedFrames)",
            "hitch_n=\(total.hitchCount)",
            "hitch_ms=\(Int(total.hitchMs.rounded()))",
            "late_p99=\(one(total.lateP99Ms))",
            "phone_n=\(total.phoneMessages)",
            "phone_frames=\(total.phoneFrames)",
            "kf=\(total.phoneKeyframes)",
            "key_not_idr=\(total.keyNotIdr)",
            "ph_key_not_idr=\(total.phoneKeyNotIdr)",
            "kf_req=\(total.phoneKeyframesRequested)",
            "drop_ep=\(total.dropEpisodes)",
            "drop_ms=\(total.dropGapMs.map(String.init) ?? "-")",
            "susp_n=\(total.suspendedEpisodes)",
            "susp_ms=\(total.suspendedMs)",
            "bytes=\(total.phoneBytes)",
            "rx_kbps=\(one(rxKbps))",
            "e2e_p50=\(one(total.e2eP50Ms))",
            "e2e_p95=\(one(total.e2eP95Ms))",
            "e2e_p99=\(one(total.e2eP99Ms))",
            "covered_ms=\(Int(total.coveredMs.rounded()))",
            "max_gap_ms=\(Int(total.maxGapMs.rounded()))",
            "int_p50=\(one(total.intervalP50Ms))",
            "int_p95=\(one(total.intervalP95Ms))",
            "int_p99=\(one(total.intervalP99Ms))",
            "shown_p50=\(one(total.shownP50Ms))",
            "shown_p95=\(one(total.shownP95Ms))",
            "shown_p99=\(one(total.shownP99Ms))",
            "tcp_ooo_kb=\(total.tcpOutOfOrderKB.map { one($0) } ?? "-")",
            "tcp_srtt_max=\(total.tcpSrttMaxMs.map(String.init) ?? "-")",
            "ph_retrans=\(total.phoneRetransmissions.map(String.init) ?? "-")",
            "ph_rto=\(total.phoneRTOs.map(String.init) ?? "-")",
            "ph_lost=\(total.phoneLostRetransmits.map(String.init) ?? "-")",
            "codec=\(total.codec ?? "-")",
            "qp_avg=\(total.qpAvg.map { one($0) } ?? "-")",
        ].joined(separator: " ")
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

    /// The ask never reached the phone (the link was not ready, so the send was
    /// refused): put the machine back where the phone still is, so the next
    /// window-set event — or the ready session's sync — asks again.
    mutating func deliveryFailed(_ wanted: Bool) {
        state = wanted ? .off : .on
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
    private let stream: UInt32

    init(stream: UInt32 = 0) {
        self.stream = stream
    }

    /// A wire-key frame's NAL types; the first three non-IDR frames per stream
    /// are logged (types only, never content).
    func noteKeyFrame(nalTypes: [UInt8], codec: VideoCodec = .avc) {
        lock.lock()
        let note = model.noteKeyFrame(isKeyframe: true, nalTypes: nalTypes, codec: codec,
                                      now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        if let line = StreamStatsLine.keyNote(stream: stream, note: note) {
            Log.video.notice("\(line, privacy: .public)")  // log-ok: NAL types and a duration only; no frame bytes
        }
    }

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

    func noteChainFed(now: TimeInterval) {
        lock.lock(); model.noteChainFed(now: now); lock.unlock()
    }

    func notePhoneStats(_ stats: PhoneStreamStats) {
        lock.lock(); model.notePhoneStats(stats); lock.unlock()
    }

    func snapshot(now: TimeInterval, tcpInfo: TCPConnectionInfo? = nil) -> StreamStatsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return model.snapshot(now: now, tcpInfo: tcpInfo)
    }

    func total(now: TimeInterval, tcpInfo: TCPConnectionInfo? = nil) -> StreamStatsTotal {
        lock.lock(); defer { lock.unlock() }
        return model.total(now: now, tcpInfo: tcpInfo)
    }
}
