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
        engine.waitUntilIdle()
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
        engine.waitUntilIdle()
        XCTAssertEqual(output.plays, 1, "the first flush starts the player")
        XCTAssertTrue(output.raceFired, "the device change fired during the start")
        XCTAssertTrue(output.waitHandlerDone(), "the device-change handler finished")
        engine.waitUntilIdle()
        XCTAssertEqual(output.violations, 0, "play() ran on an engine the device change had stopped")
        XCTAssertFalse(output.isRunning, "the device change stopped the engine after play()")
        feed(AudioPlayerMachine.initialTargetFrames + 2)
        engine.waitUntilIdle()
        XCTAssertEqual(output.starts, 2, "the next flush starts the engine again")
        XCTAssertEqual(output.plays, 2, "the next flush plays again")
        XCTAssertEqual(output.violations, 0)
    }

    /// MEDIA-12 (#212): a device change during playback stops the player while
    /// completions are outstanding. AVFAudio's stop holds the engine lock and
    /// waits for each completion; a completion that calls the player again
    /// (conceal → schedule) needs that lock. The stop must never wait on such
    /// a completion, and the next frames must start playback again.
    func testADeviceChangeDuringPlaybackDoesNotDeadlockThePlayersStop() {
        let output = LockingAudioOutput()
        let engine = AudioEngine(output: output)
        let session = DispatchQueue(label: "test.session")
        var pts: UInt64 = 0
        func feed(_ count: Int) {
            // async: a sync block would run on the calling (main) thread.
            let first = pts
            session.async {
                for index in 1...count {
                    engine.receive(AudioFrameData(ptsUs: first + UInt64(index) * 20_000, packet: [1, 2, 3]))
                }
            }
            pts += UInt64(count) * 20_000
            session.sync {}
            engine.waitUntilIdle()
        }
        engine.configure(AudioConfig(codec: AudioConfig.codecAAC, sampleRate: 48000, channels: 2,
                                     frameMs: 20, setup: []))
        feed(AudioPlayerMachine.initialTargetFrames + 2)
        XCTAssertEqual(output.plays, 1, "the prebuffer started the player")
        XCTAssertGreaterThan(output.outstanding, 0, "completions are outstanding")
        XCTAssertTrue(output.fireDeviceChange(), "the device-change handler returned")
        engine.waitUntilIdle()
        XCTAssertEqual(output.deadlocks, 0, "a player call waited on the stop that waited on it")
        XCTAssertFalse(output.isRunning, "the device change stopped the engine")
        feed(AudioPlayerMachine.initialTargetFrames + 2)
        XCTAssertEqual(output.plays, 2, "the next frames start playback again")
        XCTAssertEqual(output.deadlocks, 0)
    }

    /// MEDIA-12 (#212): the last window closing stops audio from the main
    /// thread. No player or engine call may run there: one that waits on the
    /// engine lock freezes the whole app.
    func testStoppingFromTheMainThreadMakesNoPlayerCallThere() {
        let output = LockingAudioOutput()
        let engine = AudioEngine(output: output)
        let session = DispatchQueue(label: "test.session")
        engine.configure(AudioConfig(codec: AudioConfig.codecAAC, sampleRate: 48000, channels: 2,
                                     frameMs: 20, setup: []))
        // async: a sync block would run on the calling (main) thread.
        session.async {
            for index in 1...(AudioPlayerMachine.initialTargetFrames + 2) {
                engine.receive(AudioFrameData(ptsUs: UInt64(index) * 20_000, packet: [1, 2, 3]))
            }
        }
        session.sync {}
        engine.waitUntilIdle()
        XCTAssertEqual(output.plays, 1, "the prebuffer started the player")
        XCTAssertTrue(Thread.isMainThread)
        engine.stop()
        engine.waitUntilIdle()
        XCTAssertEqual(output.mainThreadCalls, 0, "a player or engine call ran on the main thread")
        XCTAssertEqual(output.stopPlayers, 1, "the stop reached the player")
        XCTAssertEqual(output.deadlocks, 0)
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

/// AVFAudio's locking shape (#212), seen in a sample of the hung app: every
/// player and engine call takes one engine lock; the player's stop takes it,
/// then hands each outstanding completion to the completion queue and waits
/// for it there (`AVAudioPlayerNodeImpl::StopImpl`). A call that cannot get
/// the lock within 200 ms is counted as a deadlock and returns, so the test
/// fails instead of hanging.
private final class LockingAudioOutput: AudioOutput {
    private let engineLock = NSRecursiveLock()
    private let state = NSLock()
    private let completions = DispatchQueue(label: "test.completions")
    private var pending: [() -> Void] = []
    private var running = false
    private var handler: (() -> Void)?
    private var counts = (deadlocks: 0, mainThreadCalls: 0, plays: 0, stopPlayers: 0)

    var deadlocks: Int { state.withLock { counts.deadlocks } }
    var mainThreadCalls: Int { state.withLock { counts.mainThreadCalls } }
    var plays: Int { state.withLock { counts.plays } }
    var stopPlayers: Int { state.withLock { counts.stopPlayers } }
    var outstanding: Int { state.withLock { pending.count } }

    /// The engine's configuration-change notification, posted on a thread
    /// of its own as AVFAudio does. True when the handler returned in time.
    func fireDeviceChange() -> Bool {
        guard let handler = state.withLock({ self.handler }) else { return false }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            handler()
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success
    }

    /// Takes the engine lock as an AVFAudio call does; false (counted) when
    /// it would have waited forever.
    private func enter() -> Bool {
        if Thread.isMainThread { state.withLock { counts.mainThreadCalls += 1 } }
        if engineLock.lock(before: Date() + 0.2) { return true }
        state.withLock { counts.deadlocks += 1 }
        return false
    }

    /// Stops the player under the engine lock, waiting for each outstanding
    /// completion on the completion queue.
    private func drainCompletions() {
        let waiting = state.withLock { () -> [() -> Void] in
            let all = pending
            pending.removeAll()
            return all
        }
        for completion in waiting {
            let done = DispatchSemaphore(value: 0)
            completions.async {
                completion()
                done.signal()
            }
            if done.wait(timeout: .now() + 2) == .timedOut {
                state.withLock { counts.deadlocks += 1 }
            }
        }
    }

    var isRunning: Bool {
        if Thread.isMainThread { state.withLock { counts.mainThreadCalls += 1 } }
        return state.withLock { running }
    }
    func start() throws {
        guard enter() else { return }
        defer { engineLock.unlock() }
        state.withLock { running = true }
    }
    func stop() {
        guard enter() else { return }
        defer { engineLock.unlock() }
        drainCompletions()
        state.withLock { running = false }
    }
    var outputFormat: (sampleRate: Double, channels: UInt32) { (48000, 2) }
    var presentationLatency: TimeInterval { 0 }
    var volume: Float = 1
    func play() {
        guard enter() else { return }
        defer { engineLock.unlock() }
        state.withLock { counts.plays += 1 }
    }
    func stopPlayer() {
        guard enter() else { return }
        defer { engineLock.unlock() }
        state.withLock { counts.stopPlayers += 1 }
        drainCompletions()
    }
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping () -> Void) {
        guard enter() else { return }
        defer { engineLock.unlock() }
        state.withLock { pending.append(completion) }
    }
    func onConfigurationChange(_ handler: @escaping () -> Void) {
        state.withLock { self.handler = handler }
    }
}
