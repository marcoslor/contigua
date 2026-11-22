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
/// can drive them against a device change (MEDIA-12). `AudioEngine` calls
/// these only on its audio queue, never on the main thread.
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
    /// `completion` runs on AVFAudio's completion queue, also inside
    /// `stopPlayer()`, which waits for it: it must not call the output.
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void)
    /// Called on whatever thread posts the device change; the handler only
    /// posts to the audio queue.
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

/// Plays the phone's audio. Every engine and player call and all playback
/// state live on one serial audio queue (MEDIA-12, #212). The session queue,
/// the main thread, AVFAudio's notification thread and its completion queue
/// only post work there and never wait for it, so a player call that blocks
/// (the stop waits on completions under AVFAudio's engine lock) blocks only
/// that queue. `AudioOutputMachine` decides every engine and player call;
/// `AudioPlayerMachine` decides prebuffering, starvation and stretch.
final class AudioEngine: @unchecked Sendable {  // unchecked: playback state is confined to `queue`; what other threads read is under `lock`
    private let output: AudioOutput
    /// A serial queue, not an actor: frames must play in arrival order, and
    /// AVFAudio's stop blocks the thread it runs on.
    private let queue = DispatchQueue(label: "app.contigua.audio", qos: .userInitiated)  // gcd: frames in arrival order and AVFAudio's blocking calls; an actor's tasks keep neither

    // Confined to `queue`.
    private var format48kStereo: AVAudioFormat?
    private var converter: AudioConverterRef?
    private var inputASBD = AudioStreamBasicDescription()
    private var hasConverter = false
    private var outputMachine = AudioOutputMachine()
    private var machine = AudioPlayerMachine()
    private var live = AudioStats()
    private var pendingPCM: [AVAudioPCMBuffer] = []
    /// Frames scheduled on the player whose playback has not completed yet.
    private var queuedFrames: Int64 = 0
    /// The last real PCM, the source of concealment while starved.
    private var lastPCM: AVAudioPCMBuffer?
    /// How far the concealment copy has decayed in this starvation episode.
    private var concealGain: Float = 1.0
    /// The previous packet's arrival: a long gap means the radio went
    /// off-channel and the burst after it is one delayed span.
    private var lastArrivalUs: Int64?
    /// Packets older than this pts are the stale head of such a burst.
    private var skipBeforePtsUs: UInt64 = 0
    /// A gap longer than this is a stall, not jitter (the 100 ms AWDL pauses
    /// and a keyframe behind one stay below it).
    private static let reanchorGapUs: Int64 = 400_000

    // Read from other threads: under `lock`, never held across an output call.
    private let lock = NSLock()
    private var published = AudioStats()
    private var statsPath: String?
    private var lastStatsLog: TimeInterval = 0
    private var gain = (volume: Float(1.0), muted: false)

    /// The counters as of the last call the audio queue finished.
    var stats: AudioStats { lock.withLock { published } }
    /// A new file starts from zero counts (e2e: one file per check). The
    /// switch runs on the queue, so no frame before it writes the new file.
    var statsFile: String? {
        get { lock.withLock { statsPath } }
        set {
            queue.async { [self] in
                lock.withLock { statsPath = newValue }
                live = AudioStats()
                machine = AudioPlayerMachine()
                publish()
            }
        }
    }
    var volume: Float {
        get { lock.withLock { gain.volume } }
        set { setGain { $0.volume = newValue } }
    }
    var muted: Bool {
        get { lock.withLock { gain.muted } }
        set { setGain { $0.muted = newValue } }
    }

    init(output: AudioOutput? = nil) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        format48kStereo = format
        self.output = output ?? SystemAudioOutput(format: format)
        self.output.volume = 1.0
        // AVFAudio posts this on its own thread, possibly holding its engine
        // lock: hand it to the queue and return.
        self.output.onConfigurationChange { [weak self] in
            guard let self else { return }
            self.queue.async { self.send(.deviceChanged) }
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

    // MARK: Calls from other threads (each posts and returns)

    func configure(_ config: AudioConfig) {
        queue.async { [self] in configureOnQueue(config) }
    }

    func receive(_ frame: AudioFrameData) {
        let arrivalUs = Self.nowUs()
        queue.async { [self] in receiveOnQueue(frame, arrivalUs: arrivalUs) }
    }

    func stop() {
        queue.async { [self] in
            send(.stop)
            writeStats()
        }
    }

    /// Returns once every call posted so far has run (tests and checks).
    /// Never from the audio queue itself.
    func waitUntilIdle() {
        queue.sync {}
    }

    /// One 5 s numbers-only line while audio runs (R3): the field log a person
    /// can read back. Closed tokens, counts and timings only.
    func logStatsIfDue(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        let due = now - lastStatsLog >= 5 && published.frames > 0
        if due { lastStatsLog = now }
        let snapshot = published
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

    private func setGain(_ change: (inout (volume: Float, muted: Bool)) -> Void) {
        let value = lock.withLock { () -> Float in
            change(&gain)
            return gain.muted ? 0 : gain.volume
        }
        queue.async { [self] in output.volume = value }
    }

    // MARK: The audio queue

    /// Runs one output event, performs its actions in order, then any event
    /// those actions report. The only caller of the output after init.
    private func send(_ event: AudioOutputEvent) {
        dispatchPrecondition(condition: .onQueue(queue))
        var events = [event]
        while !events.isEmpty {
            let next = events.removeFirst()
            let from = outputMachine.phase
            let actions = outputMachine.handle(next)
            if outputMachine.phase != from {
                let line = AudioOutputMachine.transitionLine(from: from, event: next, to: outputMachine.phase)
                Log.audio.notice("\(line, privacy: .public)")  // log-ok: closed phase and event tokens only
            }
            for action in actions {
                if let reported = perform(action) { events.append(reported) }
            }
        }
    }

    private func perform(_ action: AudioOutputAction) -> AudioOutputEvent? {
        switch action {
        case .reset:
            pendingPCM.removeAll()
            lastPCM = nil
            concealGain = 1
            skipBeforePtsUs = 0
            lastArrivalUs = nil
            queuedFrames = 0
            _ = machine.handle(.stop)
            return nil
        case .startEngine:
            if !output.isRunning {
                do {
                    try output.start()
                } catch {
                    return .engineReady(false)
                }
            }
            let format = output.outputFormat
            // No usable output format (device gone or mid-change): the start
            // fails rather than crash in play(); the next frame retries.
            return .engineReady(Self.mayPlay(isRunning: output.isRunning,
                                             sampleRate: format.sampleRate,
                                             channels: format.channels))
        case .play:
            output.play()
            return nil
        case .schedule(let generation):
            schedulePending(generation: generation)
            return nil
        case .dropPending:
            pendingPCM.removeAll()
            return nil
        case .stopPlayer:
            output.stopPlayer()
            return nil
        case .stopEngine:
            output.stop()
            return nil
        case .played(let frames):
            return played(frames: frames)
        }
    }

    private func configureOnQueue(_ config: AudioConfig) {
        live.configs += 1
        live.codec = config.codec
        live.sampleRate = config.sampleRate
        live.channels = config.channels
        pendingPCM.removeAll()
        lastPCM = nil
        concealGain = 1
        skipBeforePtsUs = 0
        lastArrivalUs = nil
        if outputMachine.phase == .idle { _ = machine.handle(.configure) }
        setupConverter(config)
        writeStats()
    }

    private func receiveOnQueue(_ frame: AudioFrameData, arrivalUs: Int64) {
        let gapUs = lastArrivalUs.map { arrivalUs - $0 } ?? 0
        lastArrivalUs = arrivalUs
        live.frames += 1
        live.bytes += frame.packet.count
        if live.firstPts == nil { live.firstPts = frame.ptsUs }
        live.lastPts = frame.ptsUs
        _ = machine.noteArrival(arrivalUs: arrivalUs, ptsUs: Int64(clamping: frame.ptsUs))
        // A burst after a long stall carries the stale head first. Keep only
        // its newest target's worth, so audio resumes with the picture instead
        // of replaying the whole stalled span; the 500 ms burst's first ~15
        // packets go here, not into the buffer.
        if gapUs > Self.reanchorGapUs {
            let targetUs = Int64(machine.targetFrames) * 20_000
            skipBeforePtsUs = frame.ptsUs &+ UInt64(max(0, gapUs - targetUs))
        }
        let staleBurst = frame.ptsUs < skipBeforePtsUs
        guard !staleBurst, jitterPush() else {
            live.dropped += 1
            writeStats()
            return
        }
        if let pcm = decode(frame.packet) {
            live.decodedFrames += 1
            let actions = machine.handle(.frame(depthFrames: depth() + 1))
            if actions.contains(.resume) {
                concealGain = 1
                applyFadeIn(pcm)
            }
            pendingPCM.append(pcm)
            lastPCM = pcm
            performJitter(actions)
            send(.flush(ready: machine.state != .prebuffering))
        }
        writeStats()
    }

    /// One buffer finished playing (current episode only): feed the jitter
    /// machine, and flush the concealment it asks for.
    private func played(frames: Int64) -> AudioOutputEvent? {
        queuedFrames = max(0, queuedFrames - frames)
        let actions = machine.handle(.rendered(depthFrames: depth()))
        let concealed = performJitter(actions)
        writeStats()
        return concealed ? .flush(ready: true) : nil
    }

    /// The 20 ms depth the machine counts: decoded-but-unscheduled plus
    /// scheduled-but-unplayed.
    private func depth() -> Int {
        let pending = pendingPCM.reduce(Int64(0)) { $0 + Int64($1.frameLength) }
        return Int((pending + queuedFrames) / 960)
    }

    /// The packet cap: a burst past it is dropped rather than queued. It
    /// follows the adaptive target but never passes 8 units (see below).
    private func jitterPush() -> Bool {
        // The cap is the absolute 9 x 20 ms ceiling, not the adaptive target:
        // a target that shrinks after a starved stretch must not cut a packet
        // that has already arrived (MEDIA-15: a backlog above the target is
        // time-compressed, never cut). switchlink measured exactly one such
        // drop ~3 s after the link returned while the queue drained 180 -> 80
        // ms; the machine's stretch ratio drains the excess instead.
        let cap = 9
        return depth() < cap
    }

    /// True when a concealment buffer was queued.
    @discardableResult
    private func performJitter(_ actions: [AudioPlayerAction]) -> Bool {
        var concealed = false
        for action in actions {
            switch action {
            case .startPlayback, .resume:
                // The flush starts the player and schedules the queue; the
                // resume fade-in is applied to the arriving buffer.
                break
            case .conceal:
                if conceal() { concealed = true }
            }
        }
        return concealed
    }

    /// One 20 ms concealment buffer built from the last real PCM: a short
    /// crossfade, decaying a little more each time, so a starved player keeps
    /// the clock running without a hard edge.
    private func conceal() -> Bool {
        guard let source = lastPCM, source.frameLength > 0, let format = format48kStereo,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength)
        else { return false }
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
        return true
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

    /// Schedules the pending PCM on the playing player. A completion runs on
    /// AVFAudio's completion queue, maybe inside the player's stop: it only
    /// reports to the audio queue and never calls the player (#212).
    private func schedulePending(generation: Int) {
        let buffers = pendingPCM
        pendingPCM.removeAll()
        // The 9-unit (180 ms) ceiling, the same absolute cap as jitterPush:
        // an audible buffer above the adaptive target is drained by the
        // stretch ratio below, not cut (MEDIA-15). Only a queue past the
        // ceiling sheds anything.
        let targetFrames = Int64(machine.targetFrames) * 960
        let maxFrames = Int64(9 * 960)
        let ratio = machine.stretchRatio
        for buffer in buffers {
            // R2: a backlog is drained by playing slightly faster, never by
            // cutting audio. The compressed buffer keeps the format.
            let scheduled = ratio < 0.999
                ? (AudioStretch.compress(buffer, ratio: ratio) ?? buffer)
                : buffer
            let frames = Int64(scheduled.frameLength)
            // Over target, shed silent buffers first (inaudible); over max, shed anything.
            let trim = queuedFrames > targetFrames && isSilent(scheduled)
            let full = trim || queuedFrames > maxFrames
            if trim { live.trimmed += 1 } else if full { live.dropped += 1 }
            if full { continue }
            queuedFrames += frames
            if live.onsetMs == nil, isAudible(scheduled) { markOnset(queuedFrames: queuedFrames - frames) }
            output.schedule(scheduled) { [weak self] in
                guard let self else { return }
                self.queue.async { self.send(.rendered(generation: generation, frames: frames)) }
            }
        }
        live.queuedMs = Int(queuedFrames * 1000 / 48000)
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
        live.decodeErrors += 1
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
        live.onsetMs = Int(Date().timeIntervalSince1970 * 1000)
        live.onsetQueuedMs = Int(ahead * 1000 / 48000) + Int(output.presentationLatency * 1000)
    }

    private func configuredFrameCount(packetCount: Int) -> Int {
        // 20 ms at 48 kHz = 960 frames; the packet size is irrelevant.
        _ = packetCount
        return 960
    }

    /// Copies the machine's counters into the stats and publishes them for
    /// readers on other threads.
    private func publish() {
        live.underrun = machine.underruns
        live.late = machine.latePackets
        live.lateP95Ms = Double(machine.lateP95Us) / 1000
        live.concealed = machine.concealed
        live.state = machine.state.rawValue
        live.targetMs = machine.targetFrames * 20
        live.queuedMs = Int(queuedFrames * 1000 / 48000)
        let snapshot = live
        lock.withLock { published = snapshot }
    }

    private func writeStats() {
        publish()
        guard let path = lock.withLock({ statsPath }) else { return }
        let snapshot = live
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
