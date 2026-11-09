import AVFoundation
import XCTest
@testable import PocketDeck

final class AudioJitterTests: XCTestCase {
    private let frameUs: Int64 = 20_000

    /// The real session's arrival pattern: five 20 ms packets arrive together
    /// every 100 ms (the radio comes back and the AP bursts), so every packet
    /// after the first waits behind a 100 ms gap.
    private func runBurstPattern(ticks: Int) -> AudioPlayerMachine {
        var machine = AudioPlayerMachine()
        _ = machine.handle(.configure)
        var queued = 0
        var tick = 0
        while tick < ticks {
            if tick % 5 == 0 {
                for offset in 0..<5 {
                    let pts = Int64(tick + offset) * frameUs
                    let arrival = Int64(tick) * frameUs
                    _ = machine.noteArrival(arrivalUs: arrival, ptsUs: pts)
                    queued += 1
                    _ = machine.handle(.frame(depthFrames: queued))
                }
            }
            if machine.state == .playing {
                queued = max(0, queued - 1)
                _ = machine.handle(.rendered(depthFrames: queued))
            }
            tick += 1
        }
        return machine
    }

    func testArrivalLatenessIsRelativeToTheFastestPacket() {
        var lateness = ArrivalLateness()
        // First burst: offsets 0, -20, -40, -60, -80 ms.
        for offset in 0..<5 {
            lateness.note(arrivalUs: 1_000_000, ptsUs: 1_000_000 + Int64(offset) * frameUs)
        }
        // Next burst arrives 100 ms later, pts 20 ms after the previous.
        let arrival: Int64 = 1_100_000
        let pts: Int64 = 1_100_000
        XCTAssertEqual(lateness.lateness(atUs: arrival, ptsUs: pts), 80_000)
        lateness.note(arrivalUs: arrival, ptsUs: pts)
        XCTAssertEqual(lateness.p95(nowUs: arrival), 80_000)
    }

    func testTargetFollowsTheMeasuredLateness() {
        let machine = runBurstPattern(ticks: 250)  // 5 s
        XCTAssertGreaterThanOrEqual(machine.targetFrames, 6,
                                    "100 ms arrival gaps need at least a 120 ms target")
        XCTAssertLessThanOrEqual(machine.targetFrames, AudioPlayerMachine.maxTargetFrames)
    }

    func testTheMeasuredArrivalPatternNeverStarves() {
        let machine = runBurstPattern(ticks: 300)  // 6 s
        XCTAssertEqual(machine.underruns, 0,
                       "the 100 ms burst pattern must play without a starvation episode")
        XCTAssertEqual(machine.state, .playing)
    }

    func testStarvationCountsOneUnderrunAndConceals() {
        var machine = AudioPlayerMachine()
        _ = machine.handle(.configure)
        for depth in 1...AudioPlayerMachine.initialTargetFrames {
            _ = machine.handle(.frame(depthFrames: depth))
        }
        XCTAssertEqual(machine.state, .playing)
        let first = machine.handle(.rendered(depthFrames: 0))
        XCTAssertEqual(machine.state, .starved)
        XCTAssertEqual(machine.underruns, 1)
        XCTAssertEqual(machine.concealed, 1)
        XCTAssertEqual(first, [.conceal])
        _ = machine.handle(.rendered(depthFrames: 0))
        XCTAssertEqual(machine.underruns, 1, "one starvation episode, one underrun")
        XCTAssertEqual(machine.concealed, 2)
        let resumed = machine.handle(.frame(depthFrames: 1))
        XCTAssertEqual(machine.state, .playing)
        XCTAssertEqual(resumed, [.resume])
    }

    func testConcealmentIsBounded() {
        var machine = AudioPlayerMachine()
        _ = machine.handle(.configure)
        for depth in 1...AudioPlayerMachine.initialTargetFrames {
            _ = machine.handle(.frame(depthFrames: depth))
        }
        _ = machine.handle(.rendered(depthFrames: 0))
        for _ in 0..<20 { _ = machine.handle(.rendered(depthFrames: 0)) }
        XCTAssertEqual(machine.concealed, AudioPlayerMachine.maxConcealFrames)
    }

    func testStretchDrainsABacklogAndStopsAtTheTarget() {
        var machine = AudioPlayerMachine()
        _ = machine.handle(.configure)
        for depth in 1...AudioPlayerMachine.initialTargetFrames {
            _ = machine.handle(.frame(depthFrames: depth))
        }
        _ = machine.handle(.frame(depthFrames: AudioPlayerMachine.initialTargetFrames + 6))
        XCTAssertLessThan(machine.stretchRatio, 1.0, "a backlog plays slightly faster")
        for depth in stride(from: AudioPlayerMachine.initialTargetFrames + 6,
                            through: AudioPlayerMachine.initialTargetFrames, by: -1) {
            _ = machine.handle(.rendered(depthFrames: depth))
        }
        XCTAssertEqual(machine.stretchRatio, 1.0, "back at target, normal speed")
    }

    func testStretchKeepsPitchAndLength() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for i in 0..<960 {
                data[channel][i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48000)) * 0.5
            }
        }
        let out = try XCTUnwrap(AudioStretch.compress(buffer, ratio: 0.95))
        XCTAssertEqual(Int(out.frameLength), 912)
        let outData = try XCTUnwrap(out.floatChannelData)
        var largest: Float = 0
        for i in 1..<Int(out.frameLength) {
            largest = max(largest, abs(outData[0][i] - outData[0][i - 1]))
        }
        XCTAssertLessThan(largest, 0.2, "the splice must not click")
        XCTAssertLessThanOrEqual(abs(outData[0][100]), 0.6)
    }

    func testTargetStaysInRange() {
        XCTAssertEqual(AudioPlayerMachine.targetFrames(lateP99Us: 0), 3)
        XCTAssertEqual(AudioPlayerMachine.targetFrames(lateP99Us: 79_000), 6)
        XCTAssertEqual(AudioPlayerMachine.targetFrames(lateP99Us: 500_000), 10)
    }
}
