import XCTest
@testable import Contigua

/// MEDIA-12 (#212): every transition of the audio output's lifecycle.
final class AudioOutputMachineTests: XCTestCase {
    /// A machine in `phase`, reached the way the engine reaches it.
    private func machine(in phase: AudioOutputPhase) -> AudioOutputMachine {
        var machine = AudioOutputMachine()
        switch phase {
        case .idle:
            break
        case .starting:
            _ = machine.handle(.flush(ready: true))
        case .playing:
            _ = machine.handle(.flush(ready: true))
            _ = machine.handle(.engineReady(true))
        }
        XCTAssertEqual(machine.phase, phase)
        return machine
    }

    private struct Row {
        let from: AudioOutputPhase
        let event: AudioOutputEvent
        let to: AudioOutputPhase
        let actions: [AudioOutputAction]
        let line: UInt
    }

    /// The whole table: three phases by every event and its variants. The
    /// `.playing` machine is in generation 1; generation 0 is a stale one.
    private let rows: [Row] = [
        Row(from: .idle, event: .flush(ready: false), to: .idle, actions: [], line: #line),
        Row(from: .idle, event: .flush(ready: true), to: .starting, actions: [.startEngine], line: #line),
        Row(from: .idle, event: .engineReady(true), to: .idle, actions: [], line: #line),
        Row(from: .idle, event: .engineReady(false), to: .idle, actions: [], line: #line),
        Row(from: .idle, event: .deviceChanged, to: .idle, actions: [.reset, .stopEngine], line: #line),
        Row(from: .idle, event: .stop, to: .idle, actions: [.reset], line: #line),
        Row(from: .idle, event: .rendered(generation: 0, frames: 960), to: .idle, actions: [], line: #line),

        Row(from: .starting, event: .flush(ready: false), to: .starting, actions: [], line: #line),
        Row(from: .starting, event: .flush(ready: true), to: .starting, actions: [], line: #line),
        Row(from: .starting, event: .engineReady(true), to: .playing,
            actions: [.play, .schedule(generation: 1)], line: #line),
        Row(from: .starting, event: .engineReady(false), to: .idle, actions: [.dropPending], line: #line),
        Row(from: .starting, event: .deviceChanged, to: .idle, actions: [.reset, .stopEngine], line: #line),
        Row(from: .starting, event: .stop, to: .idle, actions: [.reset], line: #line),
        Row(from: .starting, event: .rendered(generation: 0, frames: 960), to: .starting, actions: [], line: #line),

        Row(from: .playing, event: .flush(ready: false), to: .playing,
            actions: [.schedule(generation: 1)], line: #line),
        Row(from: .playing, event: .flush(ready: true), to: .playing,
            actions: [.schedule(generation: 1)], line: #line),
        Row(from: .playing, event: .engineReady(true), to: .playing, actions: [], line: #line),
        Row(from: .playing, event: .engineReady(false), to: .playing, actions: [], line: #line),
        Row(from: .playing, event: .deviceChanged, to: .idle,
            actions: [.reset, .stopPlayer, .stopEngine], line: #line),
        Row(from: .playing, event: .stop, to: .idle, actions: [.reset, .stopPlayer], line: #line),
        Row(from: .playing, event: .rendered(generation: 1, frames: 960), to: .playing,
            actions: [.played(frames: 960)], line: #line),
        Row(from: .playing, event: .rendered(generation: 0, frames: 960), to: .playing, actions: [], line: #line),
    ]

    func testEveryTransition() {
        for row in rows {
            var machine = machine(in: row.from)
            let actions = machine.handle(row.event)
            XCTAssertEqual(machine.phase, row.to, "\(row.from) + \(row.event.name)", line: row.line)
            XCTAssertEqual(actions, row.actions, "\(row.from) + \(row.event.name)", line: row.line)
        }
    }

    /// The table names every phase with every event kind, so a new phase or
    /// event cannot go untested.
    func testTheTableCoversEveryPhaseAndEvent() {
        let kinds = ["flush", "flush-prebuffering", "engine-ready", "engine-not-ready",
                     "device-changed", "stop", "rendered"]
        for phase in AudioOutputPhase.allCases {
            let covered = Set(rows.filter { $0.from == phase }.map(\.event.name))
            XCTAssertEqual(covered, Set(kinds), "\(phase)")
        }
    }

    /// The fix for #212 in one sequence: a device change while playing
    /// resets before it stops the player, and every completion that stop
    /// discards (the old generation) is a no-op, also once a new episode plays.
    func testADeviceChangeMakesTheDiscardedCompletionsNoOps() {
        var machine = machine(in: .playing)
        XCTAssertEqual(machine.handle(.deviceChanged), [.reset, .stopPlayer, .stopEngine])
        XCTAssertEqual(machine.handle(.rendered(generation: 1, frames: 960)), [])
        XCTAssertEqual(machine.handle(.flush(ready: true)), [.startEngine])
        XCTAssertEqual(machine.handle(.engineReady(true)), [.play, .schedule(generation: 2)])
        XCTAssertEqual(machine.handle(.rendered(generation: 1, frames: 960)), [],
                       "a completion of the ended episode")
        XCTAssertEqual(machine.handle(.rendered(generation: 2, frames: 960)), [.played(frames: 960)])
    }

    /// play() only ever follows a ready engine, and never twice per episode.
    func testPlayOnlyAfterTheEngineIsReady() {
        var machine = AudioOutputMachine()
        XCTAssertEqual(machine.handle(.flush(ready: true)), [.startEngine])
        XCTAssertEqual(machine.handle(.flush(ready: true)), [], "a second flush while starting")
        XCTAssertEqual(machine.handle(.engineReady(false)), [.dropPending])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.handle(.flush(ready: true)), [.startEngine], "the next frame retries")
        XCTAssertEqual(machine.handle(.engineReady(true)), [.play, .schedule(generation: 1)])
        XCTAssertEqual(machine.handle(.engineReady(true)), [])
    }

    func testTheTransitionLineUsesClosedTokens() {
        XCTAssertEqual(AudioOutputMachine.transitionLine(from: .playing, event: .deviceChanged, to: .idle),
                       "audio output: playing --device-changed--> idle")
    }
}
