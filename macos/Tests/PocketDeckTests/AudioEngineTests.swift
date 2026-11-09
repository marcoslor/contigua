import XCTest
@testable import PocketDeck

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
}
