import XCTest
@testable import PocketDeck

final class AudioEngineTests: XCTestCase {
    func testJitterStartsAfterTargetAndCapsAtMax() {
        var jitter = AudioJitter()
        XCTAssertFalse(jitter.ready)
        XCTAssertTrue(jitter.push())
        XCTAssertTrue(jitter.push())
        XCTAssertFalse(jitter.ready)
        XCTAssertTrue(jitter.push())
        XCTAssertTrue(jitter.ready)
        for _ in 0..<3 { XCTAssertTrue(jitter.push()) }
        XCTAssertEqual(jitter.depth, 6)
        XCTAssertFalse(jitter.push())
        XCTAssertEqual(jitter.depth, 6)
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
}
