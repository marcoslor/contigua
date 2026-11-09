// Audio jitter accounting: the pure half of the player, so the arrival
// lateness, the adaptive target and the underrun/conceal counters are tested
// without audio hardware. The engine feeds events and performs the actions;
// nothing here touches AVAudioEngine or a clock of its own.

import AVFoundation
import Foundation

/// The player's phases. Prebuffering fills to the target before the first
/// buffer plays; Starved is a playing player whose queue ran dry — one
/// underrun episode, concealed until real audio comes back.
enum AudioPlayerState: String, Equatable {
    case prebuffering
    case playing
    case starved
}

/// What the engine must do after an event. Side effects run in the engine,
/// never inside the transition.
enum AudioPlayerAction: Equatable {
    /// Enough is buffered: start the player and schedule the queue.
    case startPlayback
    /// Schedule one 20 ms concealment buffer built from the last real PCM.
    case conceal
    /// The first real buffer after a starvation starts with a short fade-in.
    case resume
}

enum AudioPlayerEvent: Equatable {
    case configure
    case frame(depthFrames: Int)
    case rendered(depthFrames: Int)
    case stop
}

/// Arrival lateness against the phone's pts, relative to the fastest packet
/// in the last 10 s. The two clocks do not agree, so only the offset's
/// variation matters: `lateness = (arrival - pts) - min(arrival - pts)`.
/// The minimum slides with the window, so clock drift cannot accumulate.
struct ArrivalLateness: Equatable {
    static let windowUs: Int64 = 10_000_000
    private var atUs: [Int64] = []
    private var offsetUs: [Int64] = []
    private var head = 0

    var count: Int { atUs.count }

    mutating func note(arrivalUs: Int64, ptsUs: Int64) {
        atUs.append(arrivalUs)
        offsetUs.append(arrivalUs - ptsUs)
        prune(nowUs: arrivalUs)
    }

    mutating func reset() {
        atUs.removeAll()
        offsetUs.removeAll()
        head = 0
    }

    /// The lateness of one packet: its offset over the window's smallest.
    func lateness(atUs arrivalUs: Int64, ptsUs: Int64) -> Int64 {
        let offset = arrivalUs - ptsUs
        let floor = minOffset(nowUs: arrivalUs) ?? offset
        return max(0, offset - floor)
    }

    /// Nearest-rank p95 of the window's lateness samples; 0 with no samples.
    func p95(nowUs: Int64) -> Int64 {
        percentile(0.95, nowUs: nowUs)
    }

    /// Nearest-rank p99, the target's input (R2: p99 plus a margin).
    func p99(nowUs: Int64) -> Int64 {
        percentile(0.99, nowUs: nowUs)
    }

    private func percentile(_ fraction: Double, nowUs: Int64) -> Int64 {
        let floor = minOffset(nowUs: nowUs) ?? 0
        var values: [Int64] = []
        values.reserveCapacity(atUs.count)
        for index in 0..<atUs.count where nowUs - atUs[index] <= Self.windowUs {
            values.append(max(0, offsetUs[index] - floor))
        }
        guard !values.isEmpty else { return 0 }
        values.sort()
        let rank = max(0, min(values.count - 1,
                              Int((fraction * Double(values.count)).rounded(.up)) - 1))
        return values[rank]
    }

    private func minOffset(nowUs: Int64) -> Int64? {
        var floor: Int64?
        for index in 0..<atUs.count where nowUs - atUs[index] <= Self.windowUs {
            if let current = floor {
                if offsetUs[index] < current { floor = offsetUs[index] }
            } else {
                floor = offsetUs[index]
            }
        }
        return floor
    }

    /// Drops samples older than the window. The ring is only pruned when the
    /// head has aged out, so the arrays stay bounded at ~500 packets (10 s at
    /// 20 ms) plus the head's slack.
    private mutating func prune(nowUs: Int64) {
        while head < atUs.count, nowUs - atUs[head] > Self.windowUs {
            head += 1
        }
        if head > 256 {
            atUs.removeFirst(head)
            offsetUs.removeFirst(head)
            head = 0
        }
    }
}

/// The player's one state machine plus the target policy and the counters R3
/// asks for: underrun, late, concealed and dropped. One transition function,
/// no side effects.
struct AudioPlayerMachine {
    static let frameUs: Int64 = 20_000
    static let minTargetFrames = 3   // 60 ms
    /// 8 × 20 ms = 160 ms of target; an AAC packet is 1024 samples (21.33 ms),
    /// so the queued audio peaks at 8 packets ≈ 171 ms — under the 185 ms A/V
    /// limit (ITU-R BT.1359) with room for the frame being played.
    static let maxTargetFrames = 8
    /// Start at the ceiling: a link's jitter is unknown until the first bursts
    /// arrive, and the first second is exactly when the player has no history
    /// to conceal with. 8 AAC packets are 171 ms, still under 185.
    static let initialTargetFrames = 8
    /// A packet later than the minimum buffer could absorb (60 ms) is late.
    static let lateThresholdUs: Int64 = 60_000
    /// A starved player conceals at most this many 20 ms buffers per episode:
    /// 8 × 20 ms = 160 ms keeps the concealment itself under the 185 ms limit.
    static let maxConcealFrames = 8

    private(set) var state: AudioPlayerState = .prebuffering
    private(set) var targetFrames = AudioPlayerMachine.initialTargetFrames
    private(set) var underruns = 0
    private(set) var concealed = 0
    private(set) var latePackets = 0
    private(set) var lateP95Us: Int64 = 0
    /// The rate the engine should play at while draining a backlog (1 = none).
    private(set) var stretchRatio = 1.0
    private var lateness = ArrivalLateness()
    private var concealedInEpisode = 0

    /// Records one packet's arrival and returns its lateness in µs. The target
    /// follows the 10 s p99: p99 + 20 ms margin + one 20 ms frame (the packet
    /// being played), clamped to 60–160 ms (R2; 185 ms is the A/V limit, and
    /// 8 AAC packets stay under it).
    mutating func noteArrival(arrivalUs: Int64, ptsUs: Int64) -> Int64 {
        let late = lateness.lateness(atUs: arrivalUs, ptsUs: ptsUs)
        lateness.note(arrivalUs: arrivalUs, ptsUs: ptsUs)
        lateP95Us = lateness.p95(nowUs: arrivalUs)
        // A tiny window's p99 is 0: without this gate the target collapses to
        // the 60 ms floor on the first packets and the opening keyframe's
        // burst starves the player. Hold the starting target for the first
        // second (50 packets at 20 ms) while the link shows its shape.
        if lateness.count >= 50 {
            targetFrames = Self.targetFrames(lateP99Us: lateness.p99(nowUs: arrivalUs))
        }
        if late > Self.lateThresholdUs { latePackets += 1 }
        return late
    }

    /// The target in 20 ms frames: p99 + 20 ms margin + one frame, clamped.
    static func targetFrames(lateP99Us: Int64) -> Int {
        let wanted = (max(0, lateP99Us) + 40_000 + Self.frameUs - 1) / Self.frameUs
        return Int(min(Int64(maxTargetFrames), max(Int64(minTargetFrames), wanted)))
    }

    /// One transition. `depthFrames` is every 20 ms packet the engine holds:
    /// decoded-but-unscheduled plus scheduled-but-unplayed.
    mutating func handle(_ event: AudioPlayerEvent) -> [AudioPlayerAction] {
        switch event {
        case .configure:
            state = .prebuffering
            targetFrames = Self.initialTargetFrames
            lateness.reset()
            concealedInEpisode = 0
            stretchRatio = 1
            return []
        case .stop:
            state = .prebuffering
            targetFrames = Self.initialTargetFrames
            lateness.reset()
            concealedInEpisode = 0
            stretchRatio = 1
            return []
        case .frame(let depthFrames):
            updateStretch(depthFrames: depthFrames)
            switch state {
            case .prebuffering:
                guard depthFrames >= targetFrames else { return [] }
                state = .playing
                return [.startPlayback]
            case .starved:
                state = .playing
                concealedInEpisode = 0
                return [.resume]
            case .playing:
                return []
            }
        case .rendered(let depthFrames):
            updateStretch(depthFrames: depthFrames)
            switch state {
            case .prebuffering:
                return []
            case .playing:
                guard depthFrames <= 0 else { return [] }
                state = .starved
                underruns += 1
                concealedInEpisode = 0
                return conceal()
            case .starved:
                guard depthFrames <= 0 else { return [] }
                return conceal()
            }
        }
    }

    private mutating func conceal() -> [AudioPlayerAction] {
        guard concealedInEpisode < Self.maxConcealFrames else { return [] }
        concealedInEpisode += 1
        concealed += 1
        return [.conceal]
    }

    /// R2: a backlog over the target is drained by playing slightly faster,
    /// never by cutting audio. Hysteresis keeps the rate from flapping.
    private mutating func updateStretch(depthFrames: Int) {
        let over = depthFrames - targetFrames
        if over >= 5 {
            stretchRatio = 0.95
        } else if over >= 2 {
            stretchRatio = 0.98
        } else if over <= 1 {
            stretchRatio = 1.0
        }
    }

    /// Log one transition so a field log shows the path (AGENTS.md).
    static func transitionLine(from: AudioPlayerState, event: String,
                               to: AudioPlayerState) -> String {
        "audio player: \(from.rawValue) --\(event)--> \(to.rawValue)"
    }
}

/// Time compression for draining a jitter backlog (R2): a mid-buffer splice
/// with a short crossfade. Pitch is preserved (no resampling) and no sample is
/// cut — the two sides of the splice are blended.
enum AudioStretch {
    /// Compresses one PCM buffer by `ratio` (0.90...1.0). Nil when the buffer
    /// is too short or the ratio would not change it.
    static func compress(_ buffer: AVAudioPCMBuffer, ratio: Double) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let outFrames = max(1, Int((Double(frames) * ratio).rounded()))
        let format = buffer.format
        guard outFrames < frames,
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(outFrames)),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else {
            return nil
        }
        let drop = frames - outFrames
        let fade = max(1, min(drop, min(240, frames / 8)))
        let splice = min(max(frames / 2, fade), frames - drop - fade)
        guard splice - fade >= 0, splice + drop <= frames else { return nil }
        out.frameLength = AVAudioFrameCount(outFrames)
        for channel in 0..<Int(format.channelCount) {
            var o = 0
            for i in 0..<(splice - fade) {
                dst[channel][o] = src[channel][i]
                o += 1
            }
            for i in 0..<fade {
                let t = Float(i + 1) / Float(fade + 1)
                dst[channel][o] = src[channel][splice - fade + i] * (1 - t)
                    + src[channel][splice + drop - fade + i] * t
                o += 1
            }
            for i in (splice + drop)..<frames {
                dst[channel][o] = src[channel][i]
                o += 1
            }
        }
        return out
    }
}
