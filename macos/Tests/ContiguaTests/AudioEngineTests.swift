import AVFoundation
import XCTest
@testable import Contigua

final class AudioEngineTests: XCTestCase {
    func testPrebufferStartsAtTheInitialTarget() {
        var machine = AudioPlayerMachine()
        _ = machine.handle(.configure)
        XCTAssertEqual(machine.state, .prebuffering)
        for depth in 1..<AudioPlayerMachine.initialTargetFrames {
            XCTAssertEqual(machine.handle(.frame(depthFrames: depth)), [])
            XCTAssertEqual(machine.state, .prebuffering)
        }
        XCTAssertEqual(machine.handle(.frame(depthFrames: AudioPlayerMachine.initialTargetFrames)),
                       [.startPlayback])
        XCTAssertEqual(machine.state, .playing)
    }

    func testStatsCountConfigsFramesAndPts() {
        let engine = AudioEngine()
        engine.configure(AudioConfig(codec: AudioConfig.codecAAC, sampleRate: 48000, channels: 2, frameMs: 20, setup: []))
        engine.receive(AudioFrameData(ptsUs: 1000, packet: [1, 2, 3]))
        engine.receive(AudioFrameData(ptsUs: 21000, packet: [4, 5]))
        XCTAssertEqual(engine.stats.configs, 1)
        XCTAssertEqual(engine.stats.frames, 2)
        XCTAssertEqual(engine.stats.bytes, 5)
        XCTAssertEqual(engine.stats.firstPts, 1000)
        XCTAssertEqual(engine.stats.lastPts, 21000)
        XCTAssertEqual(engine.stats.codec, AudioConfig.codecAAC)
    }

    func testVolumeAndMuteDriveGain() {
        let engine = AudioEngine()
        engine.volume = 0.5
        XCTAssertEqual(engine.volume, 0.5)
        engine.muted = true
        XCTAssertTrue(engine.muted)
        engine.muted = false
        XCTAssertFalse(engine.muted)
    }

    func testMayPlayRequiresRunningEngineAndUsableOutputFormat() {
        XCTAssertTrue(AudioEngine.mayPlay(isRunning: true, sampleRate: 48000, channels: 2))
        XCTAssertTrue(AudioEngine.mayPlay(isRunning: true, sampleRate: 44100, channels: 1))
        // Engine not running: play() would abort (no IO cycle).
        XCTAssertFalse(AudioEngine.mayPlay(isRunning: false, sampleRate: 48000, channels: 2))
        // Output node reports no device: sample rate and channels go to zero.
        XCTAssertFalse(AudioEngine.mayPlay(isRunning: true, sampleRate: 0, channels: 2))
        XCTAssertFalse(AudioEngine.mayPlay(isRunning: true, sampleRate: 48000, channels: 0))
        XCTAssertFalse(AudioEngine.mayPlay(isRunning: false, sampleRate: 0, channels: 0))
    }

    /// MEDIA-12: a device change that lands while flush starts playback
    /// (between the running check and play()) must not stop the engine under
    /// play(); it runs after play() returns and the next flush starts again.
    func testADeviceChangeCannotLandBetweenTheCheckAndPlay() {
        let output = RacingAudioOutput()
        let engine = AudioEngine(output: output)
        engine.configure(AudioConfig(codec: AudioConfig.codecAAC, sampleRate: 48000, channels: 2,
                                     frameMs: 20, setup: []))
        var pts: UInt64 = 0
        func feed(_ count: Int) {
            for _ in 0..<count {
                pts += 20_000
                engine.receive(AudioFrameData(ptsUs: pts, packet: [1, 2, 3]))
            }
        }
        feed(AudioPlayerMachine.initialTargetFrames + 2)
        XCTAssertEqual(output.plays, 1, "the first flush starts the player")
        XCTAssertTrue(output.raceFired, "the device change fired during the start")
        XCTAssertTrue(output.waitHandlerDone(), "the device-change handler finished")
        XCTAssertEqual(output.violations, 0, "play() ran on an engine the device change had stopped")
        XCTAssertFalse(output.isRunning, "the device change stopped the engine after play()")
        feed(AudioPlayerMachine.initialTargetFrames + 2)
        XCTAssertEqual(output.starts, 2, "the next flush starts the engine again")
        XCTAssertEqual(output.plays, 2, "the next flush plays again")
        XCTAssertEqual(output.violations, 0)
    }
}

/// A fake output whose `isRunning` read while the engine runs fires the
/// device-change handler on another thread and waits up to 200 ms for it,
/// the window a real notification can hit.
private final class RacingAudioOutput: AudioOutput {
    private let state = NSLock()
    private var running = false
    private var handler: (() -> Void)?
    private var fired = false
    private let handlerDone = DispatchSemaphore(value: 0)
    private var counts = (starts: 0, plays: 0, violations: 0)

    var starts: Int { state.withLock { counts.starts } }
    var plays: Int { state.withLock { counts.plays } }
    var violations: Int { state.withLock { counts.violations } }
    var raceFired: Bool { state.withLock { fired } }
    func waitHandlerDone() -> Bool { handlerDone.wait(timeout: .now() + 2) == .success }

    var isRunning: Bool {
        state.lock()
        let value = running
        let fire = value && !fired
        if fire { fired = true }
        let handler = self.handler
        state.unlock()
        if fire, let handler {
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread { [handlerDone] in
                handler()
                done.signal()
                handlerDone.signal()
            }
            _ = done.wait(timeout: .now() + 0.2)
        }
        return value
    }
    func start() throws { state.withLock { running = true; counts.starts += 1 } }
    func stop() { state.withLock { running = false } }
    var outputFormat: (sampleRate: Double, channels: UInt32) { (48000, 2) }
    var presentationLatency: TimeInterval { 0 }
    var volume: Float = 1
    func play() {
        state.withLock {
            counts.plays += 1
            if !running { counts.violations += 1 }
        }
    }
    func stopPlayer() {}
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {}
    func onConfigurationChange(_ handler: @escaping () -> Void) {
        state.withLock { self.handler = handler }
    }
}
