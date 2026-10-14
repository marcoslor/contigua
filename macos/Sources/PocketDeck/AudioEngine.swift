// Device-wide audio playback: Opus/AAC packets from the phone → PCM →
// AVAudioEngine. A small jitter buffer (target 60 ms, max 120 ms) keeps the
// added latency under the 150 ms budget; Mac-side volume/mute only (the phone
// speaker is silenced by the submix routing, never by stream volume).

import AVFoundation
import Foundation

/// Audio payloads from the session, delivered on the session queue.
enum AudioEvent {
    case config(AudioConfig)
    case frame(AudioFrameData)
}

/// Pure jitter accounting, unit-tested without audio hardware.
struct AudioJitter {
    /// Target and max depth in frames (20 ms each).
    var targetFrames = 3
    var maxFrames = 6
    private var queued = 0

    var depth: Int { queued }

    mutating func push() -> Bool {
        queued += 1
        if queued > maxFrames {
            queued = maxFrames
            return false
        }
        return true
    }

    mutating func pop() {
        if queued > 0 { queued -= 1 }
    }

    mutating func reset() { queued = 0 }

    /// True once enough is buffered to start playing.
    var ready: Bool { queued >= targetFrames }
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

final class AudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format48kStereo: AVAudioFormat?
    private var converter: AudioConverterRef?
    private var inputASBD = AudioStreamBasicDescription()
    private var hasConverter = false

    private var jitter = AudioJitter()
    private let lock = NSLock()
    private var pendingPCM: [AVAudioPCMBuffer] = []
    private var started = false
    /// Frames scheduled on the player whose playback has not completed yet.
    private var queuedFrames: Int64 = 0
    /// Player queue target (60 ms) and cap (120 ms) at 48 kHz: past them audio is
    /// shed so bursts and clock drift cannot build up latency.
    private static let targetQueuedFrames: Int64 = 2880
    private static let maxQueuedFrames: Int64 = 5760

    private(set) var stats = AudioStats()
    var statsFile: String?
    var volume: Float = 1.0 {
        didSet { player.volume = muted ? 0 : volume }
    }
    var muted = false {
        didSet { player.volume = muted ? 0 : volume }
    }
    var onStateChange: ((Bool) -> Void)?

    init() {
        engine.attach(player)
        format48kStereo = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        if let format = format48kStereo {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        player.volume = 1.0
    }

    func configure(_ config: AudioConfig) {
        lock.lock()
        stats.configs += 1
        stats.codec = config.codec
        stats.sampleRate = config.sampleRate
        stats.channels = config.channels
        jitter.reset()
        pendingPCM.removeAll()
        lock.unlock()
        setupConverter(config)
        writeStats()
        onStateChange?(true)
    }

    func receive(_ frame: AudioFrameData) {
        lock.lock()
        stats.frames += 1
        stats.bytes += frame.packet.count
        if stats.firstPts == nil { stats.firstPts = frame.ptsUs }
        stats.lastPts = frame.ptsUs
        let keep = jitter.push()
        if !keep { stats.dropped += 1 }
        lock.unlock()
        if !keep { writeStats(); return }
        if let pcm = decode(frame.packet) {
            lock.lock()
            stats.decodedFrames += 1
            pendingPCM.append(pcm)
            // Pre-buffer only before playback starts; after that the player's
            // own queue is the jitter buffer and every packet goes straight in.
            let ready = started || jitter.ready
            lock.unlock()
            if ready { flush() }
        }
        writeStats()
    }

    func stop() {
        lock.lock()
        jitter.reset()
        pendingPCM.removeAll()
        lock.unlock()
        player.stop()
        started = false
        lock.lock()
        queuedFrames = 0
        lock.unlock()
        writeStats()
        onStateChange?(false)
    }

    private func flush() {
        if !started {
            do {
                try engine.start()
                player.play()
                started = true
            } catch {
                return
            }
        }
        lock.lock()
        let buffers = pendingPCM
        pendingPCM.removeAll()
        for _ in buffers { jitter.pop() }
        lock.unlock()
        for buffer in buffers {
            let frames = Int64(buffer.frameLength)
            lock.lock()
            // Over target, shed silent buffers first (inaudible); over max, shed anything.
            let trim = queuedFrames > Self.targetQueuedFrames && isSilent(buffer)
            let full = trim || queuedFrames > Self.maxQueuedFrames
            if trim { stats.trimmed += 1 } else if full { stats.dropped += 1 }
            if !full { queuedFrames += frames }
            let ahead = queuedFrames
            let needOnset = stats.onsetMs == nil
            lock.unlock()
            if full { continue }
            if needOnset, isAudible(buffer) { markOnset(queuedFrames: ahead - frames) }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.queuedFrames = max(0, self.queuedFrames - frames)
                self.lock.unlock()
            }
        }
        lock.lock()
        stats.queuedMs = Int(queuedFrames * 1000 / 48000)
        lock.unlock()
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
        stats.onsetQueuedMs = Int(ahead * 1000 / 48000) + Int(engine.outputNode.presentationLatency * 1000)
        lock.unlock()
    }

    private func configuredFrameCount(packetCount: Int) -> Int {
        // 20 ms at 48 kHz = 960 frames; the packet size is irrelevant.
        _ = packetCount
        return 960
    }

    private func writeStats() {
        guard let path = statsFile else { return }
        let obj: [String: Any] = [
            "configs": stats.configs, "frames": stats.frames, "bytes": stats.bytes,
            "decoded": stats.decodedFrames, "dropped": stats.dropped,
            "decodeErrors": stats.decodeErrors, "trimmed": stats.trimmed,
            "codec": Int(stats.codec), "sampleRate": Int(stats.sampleRate),
            "channels": Int(stats.channels),
            "firstPts": stats.firstPts.map { Int($0) } as Any? ?? 0,
            "lastPts": stats.lastPts.map { Int($0) } as Any? ?? 0,
            "onsetMs": stats.onsetMs ?? 0, "onsetQueuedMs": stats.onsetQueuedMs ?? 0,
            "queuedMs": stats.queuedMs,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
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
