// Device-wide audio playback: Opus/AAC packets from the phone → PCM →
// AVAudioEngine. An adaptive jitter buffer (60 ms floor, 180 ms target ceiling;
// 9 AAC packets ≈ 192 ms of buffer, with the video pipeline's own delay keeping
// the A/V trail under the 185 ms limit)
// follows the measured arrival lateness; Mac-side volume/mute only (the phone
// speaker is silenced by the submix routing, never by stream volume).

import AVFoundation
import Foundation

/// Audio payloads from the session, delivered on the session queue.
enum AudioEvent {
    case config(AudioConfig)
    case frame(AudioFrameData)
}

struct AudioStats: Equatable {
    var configs = 0
    var frames = 0
    var bytes = 0
    var decodedFrames = 0
    var dropped = 0
    /// Packets the converter rejected (played as silence).
    var decodeErrors = 0
    /// Silent buffers skipped to bring the queue back to target.
    var trimmed = 0
    /// Starvation episodes: the player ran dry while it was playing.
    var underrun = 0
    /// Packets later than the 60 ms minimum buffer could absorb.
    var late = 0
    /// p95 of arrival lateness against the phone's pts, over the last 10 s.
    var lateP95Ms = 0.0
    /// 20 ms concealment buffers scheduled during starvation episodes.
    var concealed = 0
    /// The player's phase (`prebuffering`, `playing`, `starved`).
    var state = "prebuffering"
    /// The adaptive target the player is using, in ms.
    var targetMs = 60
    var firstPts: UInt64?
    var lastPts: UInt64?
    /// Wall clock (ms) when the first audible buffer was scheduled, and how much
    /// audio was already queued ahead of it: latency evidence for --audio-stats.
    var onsetMs: Int?
    var onsetQueuedMs: Int?
    /// Audio scheduled on the player but not yet rendered, at the last flush.
    var queuedMs = 0
    var codec: UInt8 = 0
    var sampleRate: UInt32 = 0
    var channels: UInt8 = 0
}

/// The engine and player calls `AudioEngine` makes, behind one seam so a test
/// can drive the start against a device change (MEDIA-12).
protocol AudioOutput: AnyObject {
    var isRunning: Bool { get }
    func start() throws
    func stop()
    /// The output node's format: (sample rate, channels).
    var outputFormat: (sampleRate: Double, channels: UInt32) { get }
    var presentationLatency: TimeInterval { get }
    var volume: Float { get set }
    func play()
    func stopPlayer()
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void)
    /// Called on whatever thread posts the device change.
    func onConfigurationChange(_ handler: @escaping () -> Void)
}

/// The real output: one AVAudioEngine with one player node.
final class SystemAudioOutput: AudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var observer: NSObjectProtocol?

    init(format: AVAudioFormat?) {
        engine.attach(player)
        if let format {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isRunning: Bool { engine.isRunning }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
    var outputFormat: (sampleRate: Double, channels: UInt32) {
        let format = engine.outputNode.outputFormat(forBus: 0)
        return (format.sampleRate, format.channelCount)
    }
    var presentationLatency: TimeInterval { engine.outputNode.presentationLatency }
    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    func play() { player.play() }
    func stopPlayer() { player.stop() }
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }
    func onConfigurationChange(_ handler: @escaping () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil,
        ) { _ in handler() }
    }
}

final class AudioEngine {
    private let output: AudioOutput
    private var format48kStereo: AVAudioFormat?
    private var converter: AudioConverterRef?
    private var inputASBD = AudioStreamBasicDescription()
    private var hasConverter = false

    private var machine = AudioPlayerMachine()
    private let lock = NSLock()
    private var pendingPCM: [AVAudioPCMBuffer] = []
    private var started = false
    /// Frames scheduled on the player whose playback has not completed yet.
    private var queuedFrames: Int64 = 0
    /// The last real PCM, the source of concealment while starved.
    private var lastPCM: AVAudioPCMBuffer?
    /// How far the concealment copy has decayed in this starvation episode.
    private var concealGain: Float = 1.0
    private var lastStatsLog: TimeInterval = 0
    /// The previous packet's arrival: a long gap means the radio went
    /// off-channel and the burst after it is one delayed span.
    private var lastArrivalUs: Int64?
    /// Packets older than this pts are the stale head of such a burst.
    private var skipBeforePtsUs: UInt64 = 0
    /// A gap longer than this is a stall, not jitter (the 100 ms AWDL pauses
    /// and a keyframe behind one stay below it).
    private static let reanchorGapUs: Int64 = 400_000

    private(set) var stats = AudioStats()
    /// A new file starts from zero counts (e2e: one file per check).
    var statsFile: String? {
        didSet {
            stats = AudioStats()
            machine = AudioPlayerMachine()
        }
    }
    var volume: Float = 1.0 {
        didSet { output.volume = muted ? 0 : volume }
    }
    var muted = false {
        didSet { output.volume = muted ? 0 : volume }
    }
    var onStateChange: ((Bool) -> Void)?

    init(output: AudioOutput? = nil) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        format48kStereo = format
        self.output = output ?? SystemAudioOutput(format: format)
        self.output.volume = 1.0
        self.output.onConfigurationChange { [weak self] in
            self?.configurationChanged()
        }
    }

    /// Whether starting playback is safe: `player.play()` raises an
    /// Objective-C exception Swift cannot catch when the player has no IO
    /// cycle — seen on the emulator rig's first audio frame, and it can also
    /// hit a real Mac when the output device changes. Playback may only start
    /// when the engine is running and the output node reports a real format.
    static func mayPlay(isRunning: Bool, sampleRate: Double, channels: UInt32) -> Bool {
        isRunning && sampleRate > 0 && channels > 0
    }

    /// The output device changed (headphones, Bluetooth): the engine's IO
    /// cycle is gone, and any later play() on it would abort the process.
    /// Stop cleanly, forget the pre-buffer, and let the next flush start again
    /// on the new device. The device-change notification arrives on whatever
    /// thread posts it; the state is kept consistent under the lock.
    private func configurationChanged() {
        output.stopPlayer()
        output.stop()
        lock.lock()
        pendingPCM.removeAll()
        lastPCM = nil
        concealGain = 1
        skipBeforePtsUs = 0
        lastArrivalUs = nil
        queuedFrames = 0
        started = false
        machine.handle(.stop)
        lock.unlock()
    }

    /// Discard the pre-buffered PCM (playback cannot start right now).
    private func dropPending() {
        lock.lock()
        pendingPCM.removeAll()
        lock.unlock()
    }

    func configure(_ config: AudioConfig) {
        lock.lock()
        stats.configs += 1
        stats.codec = config.codec
        stats.sampleRate = config.sampleRate
        stats.channels = config.channels
        pendingPCM.removeAll()
        lastPCM = nil
        concealGain = 1
        skipBeforePtsUs = 0
        lastArrivalUs = nil
        if !started { machine.handle(.configure) }
        lock.unlock()
        setupConverter(config)
        writeStats()
        onStateChange?(true)
    }

    func receive(_ frame: AudioFrameData) {
        let arrivalUs = Self.nowUs()
        let gapUs = lastArrivalUs.map { arrivalUs - $0 } ?? 0
        lastArrivalUs = arrivalUs
        lock.lock()
        stats.frames += 1
        stats.bytes += frame.packet.count
        if stats.firstPts == nil { stats.firstPts = frame.ptsUs }
        stats.lastPts = frame.ptsUs
        _ = machine.noteArrival(arrivalUs: arrivalUs,
                                ptsUs: Int64(clamping: frame.ptsUs))
        // A burst after a long stall carries the stale head first. Keep only
        // its newest target's worth, so audio resumes with the picture instead
        // of replaying the whole stalled span; the 500 ms burst's first ~15
        // packets go here, not into the buffer.
        if gapUs > Self.reanchorGapUs {
            let targetUs = Int64(machine.targetFrames) * 20_000
            skipBeforePtsUs = frame.ptsUs &+ UInt64(max(0, gapUs - targetUs))
        }
        let staleBurst = frame.ptsUs < skipBeforePtsUs
        let keep = !staleBurst && jitterPushLocked()
        if !keep { stats.dropped += 1 }
        lock.unlock()
        if !keep {
            refreshStatsLocked()
            writeStats()
            return
        }
        if let pcm = decode(frame.packet) {
            lock.lock()
            stats.decodedFrames += 1
            let actions = machine.handle(.frame(depthFrames: depthLocked() + 1))
            if actions.contains(.resume) {
                concealGain = 1
                applyFadeIn(pcm)
            }
            pendingPCM.append(pcm)
            lastPCM = pcm
            lock.unlock()
            perform(actions)
            flush()
        }
        refreshStatsLocked()
        writeStats()
    }

    func stop() {
        lock.lock()
        pendingPCM.removeAll()
        lastPCM = nil
        concealGain = 1
        skipBeforePtsUs = 0
        lastArrivalUs = nil
        started = false
        queuedFrames = 0
        machine.handle(.stop)
        lock.unlock()
        output.stopPlayer()
        refreshStatsLocked()
        writeStats()
        onStateChange?(false)
    }

    /// One 5 s numbers-only line while audio runs (R3): the field log a person
    /// can read back. Closed tokens, counts and timings only.
    func logStatsIfDue(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        let due = now - lastStatsLog >= 5 && stats.frames > 0
        if due { lastStatsLog = now }
        let snapshot = stats
        lock.unlock()
        guard due else { return }
        let line = "audio] stats state=\(snapshot.state) target_ms=\(snapshot.targetMs)" +
            " depth_ms=\(snapshot.queuedMs) underrun=\(snapshot.underrun)" +
            " late=\(snapshot.late) late_p95=\(String(format: "%.1f", snapshot.lateP95Ms))" +
            " concealed=\(snapshot.concealed) dropped=\(snapshot.dropped)" +
            " trimmed=\(snapshot.trimmed) frames=\(snapshot.frames)" +
            " decode_err=\(snapshot.decodeErrors)"
        Log.audio.notice("\(line, privacy: .public)")  // log-ok: states, counts and timings only
    }

    /// The 20 ms depth the machine counts: decoded-but-unscheduled plus
    /// scheduled-but-unplayed.
    private func depthLocked() -> Int {
        let pending = pendingPCM.reduce(Int64(0)) { $0 + Int64($1.frameLength) }
        return Int((pending + queuedFrames) / 960)
    }

    /// The packet cap: a burst past it is dropped rather than queued. It
    /// follows the adaptive target but never passes 8 units (see below).
    private func jitterPushLocked() -> Bool {
        // The cap is the absolute 9 x 20 ms ceiling, not the adaptive target:
        // a target that shrinks after a starved stretch must not cut a packet
        // that has already arrived (MEDIA-15: a backlog above the target is
        // time-compressed, never cut). switchlink measured exactly one such
        // drop ~3 s after the link returned while the queue drained 180 -> 80
        // ms; the machine's stretch ratio drains the excess instead.
        let cap = 9
        let depth = depthLocked()
        return depth < cap
    }

    private func perform(_ actions: [AudioPlayerAction]) {
        for action in actions {
            switch action {
            case .startPlayback, .resume:
                // The flush starts the player and schedules the queue; the
                // resume fade-in is applied to the arriving buffer.
                break
            case .conceal:
                conceal()
            }
        }
    }

    /// One 20 ms concealment buffer built from the last real PCM: a short
    /// crossfade, decaying a little more each time, so a starved player keeps
    /// the clock running without a hard edge.
    private func conceal() {
        lock.lock()
        guard let source = lastPCM, source.frameLength > 0, let format = format48kStereo,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength)
        else {
            lock.unlock()
            return
        }
        let n = Int(source.frameLength)
        buffer.frameLength = source.frameLength
        concealGain *= 0.7
        for channel in 0..<Int(format.channelCount) {
            guard let src = source.floatChannelData?[channel],
                  let dst = buffer.floatChannelData?[channel] else { continue }
            for i in 0..<n {
                dst[i] = src[i] * concealGain * Float(n - i) / Float(n)
            }
        }
        pendingPCM.append(buffer)
        lock.unlock()
        flush()
    }

    /// A short fade-in on the first real buffer after starvation: the other
    /// half of the crossfade that hides the hole (R3).
    private func applyFadeIn(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let fade = min(n, 240)  // 5 ms at 48 kHz
        guard fade > 0 else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            for i in 0..<fade {
                data[channel][i] *= Float(i) / Float(fade)
            }
        }
    }

    private func flush() {
        lock.lock()
        let playing = started || machine.state == .playing
        lock.unlock()
        guard playing else { return }
        if !started {
            if !output.isRunning {
                do {
                    try output.start()
                } catch {
                    dropPending()
                    return
                }
            }
            let outFormat = output.outputFormat
            guard Self.mayPlay(isRunning: output.isRunning,
                               sampleRate: outFormat.sampleRate,
                               channels: outFormat.channels) else {
                // No usable output format (device gone or mid-change): drop the
                // burst rather than crash in play(). The next flush retries.
                dropPending()
                return
            }
            output.play()
            started = true
        }
        lock.lock()
        let buffers = pendingPCM
        pendingPCM.removeAll()
        // The 9-unit (180 ms) ceiling, the same absolute cap as
        // jitterPushLocked: an audible buffer above the adaptive target is
        // drained by the stretch ratio below, not cut (MEDIA-15). Only a
        // queue past the ceiling sheds anything.
        let targetFrames = Int64(machine.targetFrames) * 960
        let maxFrames = 9 * 960
        let ratio = machine.stretchRatio
        lock.unlock()
        for buffer in buffers {
            // R2: a backlog is drained by playing slightly faster, never by
            // cutting audio. The compressed buffer keeps the format.
            let scheduled = ratio < 0.999
                ? (AudioStretch.compress(buffer, ratio: ratio) ?? buffer)
                : buffer
            let frames = Int64(scheduled.frameLength)
            lock.lock()
            // Over target, shed silent buffers first (inaudible); over max, shed anything.
            let trim = queuedFrames > targetFrames && isSilent(scheduled)
            let full = trim || queuedFrames > maxFrames
            if trim { stats.trimmed += 1 } else if full { stats.dropped += 1 }
            if !full { queuedFrames += frames }
            let ahead = queuedFrames
            let needOnset = stats.onsetMs == nil
            lock.unlock()
            if full { continue }
            if needOnset, isAudible(scheduled) { markOnset(queuedFrames: ahead - frames) }
            output.schedule(scheduled) { [weak self] in
                self?.rendered(frames: frames)
            }
        }
        lock.lock()
        stats.queuedMs = Int(queuedFrames * 1000 / 48000)
        lock.unlock()
    }

    /// One buffer finished playing: feed the machine and conceal a dry queue.
    private func rendered(frames: Int64) {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        queuedFrames = max(0, queuedFrames - frames)
        let actions = machine.handle(.rendered(depthFrames: depthLocked()))
        lock.unlock()
        perform(actions)
        refreshStatsLocked()
        writeStats()
    }

    private func setupConverter(_ config: AudioConfig) {
        hasConverter = false
        converter = nil
        guard config.sampleRate == 48000, config.channels == 2 else { return }
        var inASBD = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: config.codec == AudioConfig.codecOpus ? kAudioFormatOpus : kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: config.codec == AudioConfig.codecOpus ? 960 : 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0,
        )
        guard let outFormat = format48kStereo else { return }
        var outASBD = outFormat.streamDescription.pointee
        var converterRef: AudioConverterRef?
        let status = AudioConverterNew(&inASBD, &outASBD, &converterRef)
        if status == noErr, let ref = converterRef {
            // AAC needs the ASC magic cookie from AUDIO_CONFIG setup bytes.
            if config.codec == AudioConfig.codecAAC, !config.setup.isEmpty {
                config.setup.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        AudioConverterSetProperty(ref, kAudioConverterDecompressionMagicCookie,
                                                 UInt32(config.setup.count), base)
                    }
                }
            }
            converter = ref
            inputASBD = inASBD
            hasConverter = true
        }
    }

    private func decode(_ packet: [UInt8]) -> AVAudioPCMBuffer? {
        guard hasConverter, let converter, let outFormat = format48kStereo else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 2048) else { return nil }
        let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: packet.count, alignment: 1)
        defer { bytes.deallocate() }
        bytes.copyBytes(from: packet)
        var context = PacketContext(data: bytes)
        // The buffer list advertises frameLength, not capacity, as writable bytes.
        buffer.frameLength = buffer.frameCapacity
        var ioFrames: UInt32 = 2048
        let status: OSStatus = withUnsafeMutablePointer(to: &context) { ctxPtr in
            withUnsafeMutablePointer(to: &ioFrames) { framesPtr in
                let outData = buffer.mutableAudioBufferList
                return AudioConverterFillComplexBuffer(converter, audioPacketCallback,
                                                       ctxPtr, framesPtr, outData, nil)
            }
        }
        if status == noErr || status == noMorePackets, ioFrames > 0 {
            buffer.frameLength = AVAudioFrameCount(ioFrames)
            return buffer
        }
        // Converter rejected the packet (e.g. Opus without system support):
        // still count the transport, schedule matching silence so the clock runs.
        lock.lock()
        stats.decodeErrors += 1
        lock.unlock()
        buffer.frameLength = AVAudioFrameCount(configuredFrameCount(packetCount: packet.count))
        return buffer
    }

    /// Digital silence (what the phone sends while nothing plays), safe to skip.
    private func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return false }
        for channel in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) where abs(data[channel][i]) > 1e-4 { return false }
        }
        return true
    }

    /// Clearly audible (above -40 dBFS RMS): marks the onset for latency stats.
    private func isAudible(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData else { return false }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        return n > 0 && (sum / Float(n)).squareRoot() > 0.01
    }

    private func markOnset(queuedFrames ahead: Int64) {
        lock.lock()
        stats.onsetMs = Int(Date().timeIntervalSince1970 * 1000)
        stats.onsetQueuedMs = Int(ahead * 1000 / 48000) + Int(output.presentationLatency * 1000)
        lock.unlock()
    }

    private func configuredFrameCount(packetCount: Int) -> Int {
        // 20 ms at 48 kHz = 960 frames; the packet size is irrelevant.
        _ = packetCount
        return 960
    }

    private func refreshStatsLocked() {
        lock.lock()
        stats.underrun = machine.underruns
        stats.late = machine.latePackets
        stats.lateP95Ms = Double(machine.lateP95Us) / 1000
        stats.concealed = machine.concealed
        stats.state = machine.state.rawValue
        stats.targetMs = machine.targetFrames * 20
        stats.queuedMs = Int(queuedFrames * 1000 / 48000)
        lock.unlock()
    }

    private func writeStats() {
        refreshStatsLocked()
        guard let path = statsFile else { return }
        lock.lock()
        let snapshot = stats
        lock.unlock()
        let obj: [String: Any] = [
            "configs": snapshot.configs, "frames": snapshot.frames, "bytes": snapshot.bytes,
            "decoded": snapshot.decodedFrames, "dropped": snapshot.dropped,
            "decodeErrors": snapshot.decodeErrors, "trimmed": snapshot.trimmed,
            "underrun": snapshot.underrun, "late": snapshot.late,
            "lateP95Ms": snapshot.lateP95Ms, "concealed": snapshot.concealed,
            "state": snapshot.state, "targetMs": snapshot.targetMs,
            "codec": Int(snapshot.codec), "sampleRate": Int(snapshot.sampleRate),
            "channels": Int(snapshot.channels),
            "firstPts": snapshot.firstPts.map { Int($0) } as Any? ?? 0,
            "lastPts": snapshot.lastPts.map { Int($0) } as Any? ?? 0,
            "onsetMs": snapshot.onsetMs ?? 0, "onsetQueuedMs": snapshot.onsetQueuedMs ?? 0,
            "queuedMs": snapshot.queuedMs,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private static func nowUs() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
    }
}

// MARK: - Converter input callback

private struct PacketContext {
    var data: UnsafeMutableRawBufferPointer
    var consumed = false
    var description = AudioStreamPacketDescription()
}

/// Returned by the input callback once its single packet is used up; ends the
/// fill call without being an error.
private let noMorePackets: OSStatus = 1

private func audioPacketCallback(
    _ converter: AudioConverterRef,
    _ ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outPacketDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?,
) -> OSStatus {
    guard let inUserData else { return -1 }
    let ctx = inUserData.assumingMemoryBound(to: PacketContext.self)
    if ctx.pointee.consumed {
        ioNumberDataPackets.pointee = 0
        return noMorePackets
    }
    ctx.pointee.consumed = true
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = 2
    ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.pointee.data.count)
    ioData.pointee.mBuffers.mData = ctx.pointee.data.baseAddress
    ioNumberDataPackets.pointee = 1
    // Opus and AAC are variable-size packets: the converter needs a description.
    ctx.pointee.description = AudioStreamPacketDescription(
        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(ctx.pointee.data.count),
    )
    if let outPacketDescriptions {
        let offset = MemoryLayout<PacketContext>.offset(of: \PacketContext.description)!
        outPacketDescriptions.pointee = UnsafeMutableRawPointer(ctx).advanced(by: offset)
            .assumingMemoryBound(to: AudioStreamPacketDescription.self)
    }
    return noErr
}
