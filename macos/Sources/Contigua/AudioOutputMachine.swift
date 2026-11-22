// The audio output's lifecycle (MEDIA-12, #212): one pure machine decides
// every engine and player call. `AudioEngine` runs it on its one audio queue
// and performs the actions there, so the calls happen in the order decided
// here and nowhere else. A played-buffer completion only reports `.rendered`
// back to that queue: AVFAudio's player stop waits for those completions while
// it holds the engine's lock, so a completion that called the player again
// would wait on the stop that waits on it. Each playing episode has its own
// generation, so a completion from an episode that a stop or a device change
// ended is a no-op.

/// Where the output is.
enum AudioOutputPhase: String, Equatable, CaseIterable {
    /// The player is stopped. The engine may still run: a stop keeps it for
    /// the next start; a device change stops it too.
    case idle
    /// The engine is being started and its output format checked; `play()`
    /// comes only after `.engineReady(true)`.
    case starting
    /// The player plays; every buffer scheduled now carries `generation`.
    case playing
}

enum AudioOutputEvent: Equatable {
    /// Decoded audio is waiting. `ready` is the jitter machine's word that
    /// the prebuffer is filled (it has left `prebuffering`).
    case flush(ready: Bool)
    /// The `.startEngine` outcome: the engine runs and reports a usable format.
    case engineReady(Bool)
    /// AVFAudio's configuration-change notification: the output device changed.
    case deviceChanged
    /// No window wants audio, or the session ended.
    case stop
    /// One scheduled buffer was played, or discarded by a stop.
    case rendered(generation: Int, frames: Int64)

    /// A closed token for the transition log line.
    var name: String {
        switch self {
        case .flush(let ready): return ready ? "flush" : "flush-prebuffering"
        case .engineReady(let ok): return ok ? "engine-ready" : "engine-not-ready"
        case .deviceChanged: return "device-changed"
        case .stop: return "stop"
        case .rendered: return "rendered"
        }
    }
}

enum AudioOutputAction: Equatable {
    /// Forget everything queued: pending PCM, the scheduled count, the
    /// concealment source, the stale-burst skip; the jitter machine stops
    /// (back to prebuffering).
    case reset
    /// Start the engine when it is not running, then check that it runs with
    /// a real output format; report `.engineReady`.
    case startEngine
    case play
    /// Schedule the pending PCM, each buffer's completion tagged `generation`.
    case schedule(generation: Int)
    /// Discard the pending PCM: playback cannot start now; the next frame retries.
    case dropPending
    case stopPlayer
    case stopEngine
    /// Account one played buffer and feed the jitter machine (which may conceal).
    case played(frames: Int64)
}

struct AudioOutputMachine: Equatable {
    private(set) var phase: AudioOutputPhase = .idle
    /// The current playing episode; a new one begins at every `play`.
    private(set) var generation = 0

    /// One transition. Every (phase, event) pair is written out.
    mutating func handle(_ event: AudioOutputEvent) -> [AudioOutputAction] {
        switch (phase, event) {
        // Idle: nothing plays and nothing scheduled is current.
        case (.idle, .flush(ready: false)):
            return []
        case (.idle, .flush(ready: true)):
            phase = .starting
            return [.startEngine]
        case (.idle, .engineReady):
            // Unreachable on the one queue (a start's report follows it);
            // nothing was played, so nothing to undo.
            return []
        case (.idle, .deviceChanged):
            // The player is already stopped; the engine a stop kept is not.
            return [.reset, .stopEngine]
        case (.idle, .stop):
            return [.reset]
        case (.idle, .rendered):
            // A completion from an episode that already ended.
            return []

        // Starting: the engine start and the format check are being performed.
        case (.starting, .flush):
            // The start schedules everything pending once it plays.
            return []
        case (.starting, .engineReady(true)):
            phase = .playing
            generation += 1
            return [.play, .schedule(generation: generation)]
        case (.starting, .engineReady(false)):
            phase = .idle
            return [.dropPending]
        case (.starting, .deviceChanged):
            // play() has not run; the next report finds the machine idle.
            phase = .idle
            return [.reset, .stopEngine]
        case (.starting, .stop):
            phase = .idle
            return [.reset]
        case (.starting, .rendered):
            // Nothing of a new episode is scheduled yet: an old completion.
            return []

        // Playing.
        case (.playing, .flush):
            return [.schedule(generation: generation)]
        case (.playing, .engineReady):
            // Unreachable on the one queue; the player already plays.
            return []
        case (.playing, .deviceChanged):
            // Reset first: whatever the stop discards is already forgotten.
            phase = .idle
            return [.reset, .stopPlayer, .stopEngine]
        case (.playing, .stop):
            phase = .idle
            return [.reset, .stopPlayer]
        case (.playing, .rendered(let generation, let frames)):
            return generation == self.generation ? [.played(frames: frames)] : []
        }
    }

    /// Log one phase change so a field log shows the path (AGENTS.md).
    static func transitionLine(from: AudioOutputPhase, event: AudioOutputEvent,
                               to: AudioOutputPhase) -> String {
        "audio output: \(from.rawValue) --\(event.name)--> \(to.rawValue)"
    }
}
