// The session and ranking machines (docs/design/paths.md §6, §7.3), pure
// transitions with actions the owner performs. The same tables run on the
// phone (`PathSession.kt`, `PathRanking.kt`) with the same vectors.

import Foundation

// MARK: - Session (PATH-3, PATH-6, PATH-9, PATH-13, PATH-16)

enum PathSessionState: Equatable {
    /// No path has founded the session yet (RRR-10): explicit, never a sentinel
    /// value of another state, so nothing can mistake "not founded" for an
    /// orphan and start its 30 s grace.
    case unfounded
    case live(current: String)
    case migrating(from: String, to: String, since: TimeInterval)
    case orphaned(since: TimeInterval)
    case ended(reason: String)
}

extension PathSessionState {
    /// The closed token the log line uses (docs/design/paths.md §3): never a
    /// path id or anything from the wire.
    var token: String {
        switch self {
        case .unfounded: return "unfounded"
        case .live: return "live"
        case .migrating: return "migrating"
        case .orphaned: return "orphaned"
        case .ended: return "ended"
        }
    }
}

extension PathSessionEvent {
    var token: String {
        switch self {
        case .pathUp: return "up"
        case .pathDown: return "down"
        case .currentFailed: return "failed"
        case .pongLost: return "pong-lost"
        case .peerSwitch: return "switch"
        case .probeWelcomed: return "probe"
        case .standbyAnswered: return "answered"
        case .close: return "close"
        case .graceExpired: return "grace"
        case .drainExpired: return "drain"
        }
    }
}

enum PathSessionEvent: Equatable {
    case pathUp(id: String, joined: Bool)
    case pathDown(id: String)
    /// A socket error (or a five-second joined-path silence): the path is gone.
    case currentFailed(id: String)
    /// One ping went unanswered for 1.5 s (PATH-7). With two or more paths
    /// that fails the current one at once; with only one it is a ranking
    /// sample and the caller has already recorded it.
    case pongLost(id: String)
    /// The peer's marker arrived on `arrivedOn`; `id` is the path being moved to.
    case peerSwitch(id: String, seq: UInt64, arrivedOn: String)
    /// A single-path silence probe (PATH-24) welcomed as a second path;
    /// `oldSilent` says whether the current path had still delivered nothing.
    case probeWelcomed(id: String, oldSilent: Bool)
    /// A `path.pong` arrived on attached path `id` (PATH-54): it proves that
    /// path carries frames again; only an orphaned session acts on it.
    case standbyAnswered(id: String)
    case close(reason: String)
    /// The 30 s orphan grace passed (the caller's clock says so).
    case graceExpired
    /// The 2 s drain backstop for a planned switch passed.
    case drainExpired
}

enum PathSessionAction: Equatable {
    case startPing(path: String)
    case stopPing(path: String)
    case ranking(PathRankingEvent)
    case closePath(path: String)
    /// Make `path` the sending path and send `path.switch` with the next seq.
    case switchTo(path: String)
    case replayFromLastAck
    case requestKeyframes
    /// The windows say "reconnecting" (PATH-17) within 2 s.
    case markReconnecting
    case end(reason: String)
    case ignore
}

/// PATH-6's grace, PATH-9's drain and PATH-7's ping are implementation timers
/// the caller fires; the machine holds no clock of its own.
enum PathTimers {
    static let grace: TimeInterval = 30
    static let drainBackstop: TimeInterval = 2
    static let pingInterval: TimeInterval = 2
    static let pongTimeout: TimeInterval = 1.5
    static let joinedPingDrop: TimeInterval = 5
    static let maxPaths = 3
}

struct PathSessionMachine {
    private(set) var state: PathSessionState
    /// Every attached path, standbys included.
    var live: Set<String>
    /// Demoted by a lost pong only (never a socket error): kept open, still
    /// pinged, never chosen for a failover, can win back on margin (D-2).
    var standby: Set<String>
    /// The ranking's opinion of each live path (0…1000); the failover choice.
    var scores: [String: Int]
    /// The class each live path was ranked with.
    var kinds: [String: PathKind]

    init(state: PathSessionState = .unfounded,
         live: Set<String> = [],
         standby: Set<String> = [],
         scores: [String: Int] = [:],
         kinds: [String: PathKind] = [:]) {
        self.state = state
        self.live = live
        self.standby = standby
        self.scores = scores
        self.kinds = kinds
    }

    var currentPath: String? {
        if case .live(let current) = state { return current }
        return nil
    }

    /// The first path founds the session: no switch marker, no replay (PATH-3).
    mutating func startLive(path: String) {
        state = .live(current: path)
        live = [path]
        standby = []
        scores[path] = -1
    }

    /// The best path a failover may take: a standby is only reachable by margin.
    private func bestLive(excluding: String? = nil) -> String? {
        let candidates = live.filter { $0 != excluding && !standby.contains($0) }
        return candidates.max { (scores[$0] ?? -1) < (scores[$1] ?? -1) }
    }

    /// One transition: `(state, event, live set, clock) -> (state, actions)`.
    mutating func handle(_ event: PathSessionEvent, now: TimeInterval) -> [PathSessionAction] {
        switch state {
        case .ended:
            return [.ignore]

        case .unfounded:
            switch event {
            case .pathUp(let id, _):
                // The founder normally starts through `startLive`; a first
                // path arriving as an event still founds with no marker and no
                // replay (PATH-3).
                state = .live(current: id)
                live.insert(id)
                scores[id] = scores[id] ?? -1
                return [.startPing(path: id), .ranking(.pathUp(id))]
            case .close(let reason):
                state = .ended(reason: reason)
                return [.end(reason: reason)]
            case .pathDown(let id), .currentFailed(let id), .pongLost(let id):
                live.remove(id)
                standby.remove(id)
                return []
            case .peerSwitch, .graceExpired, .drainExpired, .probeWelcomed, .standbyAnswered:
                return []
            }

        case .live(let current):
            switch event {
            case .pathUp(let id, _):
                if live.contains(id) { return [.closePath(path: id)] }
                live.insert(id)
                scores[id] = scores[id] ?? -1
                return [.startPing(path: id), .ranking(.pathUp(id))]

            case .peerSwitch(let id, _, let arrivedOn):
                guard live.contains(id) else { return [.ignore] }
                if id == current { return [] }
                standby.remove(id)
                if arrivedOn == current {
                    state = .migrating(from: current, to: id, since: now)
                    return [.startPing(path: id), .ranking(.externalSwitch(id))]
                }
                // The old path is already gone: the marker came on the new one.
                state = .live(current: id)
                live.remove(current)
                standby.remove(current)
                return [.closePath(path: current), .stopPing(path: current),
                        .startPing(path: id), .ranking(.externalSwitch(id))]
            case .probeWelcomed(let id, let oldSilent):
                // PATH-24/E-11: the probe is only there to carry a silent
                // single path. Still silent means switch now rather than wait
                // for its first lost pong; either way the old path stays
                // attached as a standby and is never failed or closed here.
                guard live.contains(id), id != current else { return [.ignore] }
                guard oldSilent else { return [] }
                standby.insert(current)
                state = .live(current: id)
                return [.switchTo(path: id), .replayFromLastAck,
                        .requestKeyframes, .ranking(.externalSwitch(id))]
            case .currentFailed(let id):
                guard id == current else { return [] }
                live.remove(id)
                standby.remove(id)
                if let next = bestLive() {
                    state = .migrating(from: id, to: next, since: now)
                    return [.stopPing(path: id), .switchTo(path: next),
                            .replayFromLastAck, .requestKeyframes,
                            .startPing(path: next), .ranking(.currentFailed(id: id))]
                }
                state = .orphaned(since: now)
                return [.stopPing(path: id), .markReconnecting, .ranking(.currentFailed(id: id))]

            case .pongLost(let id):
                guard id == current else { return [] }
                // PATH-21: with one path there is nothing to switch to, and the
                // sample is all. D-2: a lost pong demotes the path to a standby
                // (still open, still pinged) instead of closing a live path; a
                // socket error above still closes it.
                guard live.count >= 2 else { return [] }
                guard let next = bestLive(excluding: id) else {
                    // E-9 (boot 13): every other attached path is a standby, so
                    // nothing can carry the session. Start the grace as when no
                    // path is left; the failing path stays a standby, kept
                    // open and pinged, closed by its socket error or the end.
                    standby.insert(id)
                    state = .orphaned(since: now)
                    return [.markReconnecting, .ranking(.currentFailed(id: id))]
                }
                state = .live(current: next)
                standby.insert(id)
                return [.switchTo(path: next), .replayFromLastAck, .requestKeyframes,
                        .ranking(.externalSwitch(next))]

            case .pathDown(let id):
                live.remove(id)
                standby.remove(id)
                if id == current {
                    if let next = bestLive() {
                        state = .migrating(from: id, to: next, since: now)
                        return [.stopPing(path: id), .switchTo(path: next),
                                .replayFromLastAck, .requestKeyframes,
                                .startPing(path: next), .ranking(.currentFailed(id: id))]
                    }
                    state = .orphaned(since: now)
                    return [.stopPing(path: id), .markReconnecting,
                            .ranking(.currentFailed(id: id))]
                }
                return [.ranking(.pathDown(id))]

            case .close(let reason):
                state = .ended(reason: reason)
                return [.end(reason: reason)]

            case .graceExpired, .drainExpired:
                return []

            case .standbyAnswered:
                // A path carries the session: only the margin rule brings a
                // standby back (D-2).
                return []
            }

        case .migrating(let from, let to, _):
            switch event {
            case .peerSwitch(let id, _, _):
                guard id == to else { return [.ignore] }
                state = .live(current: to)
                live.remove(from)
                standby.remove(from)
                standby.remove(to)
                return [.closePath(path: from), .stopPing(path: from),
                        .ranking(.externalSwitch(to))]
            case .pathDown(let id):
                live.remove(id)
                standby.remove(id)
                if id == to {
                    // The old path is still usable: fall back to it at once.
                    if live.contains(from) {
                        state = .live(current: from)
                        return [.ranking(.externalSwitch(from))]
                    }
                    if let next = bestLive() {
                        state = .migrating(from: from, to: next, since: now)
                        return [.stopPing(path: id), .switchTo(path: next),
                                .replayFromLastAck, .requestKeyframes,
                                .startPing(path: next), .ranking(.currentFailed(id: id))]
                    }
                    state = .orphaned(since: now)
                    return [.markReconnecting, .ranking(.currentFailed(id: id))]
                }
                return []
            case .currentFailed(let id) where id == to:
                live.remove(id)
                standby.remove(id)
                if let next = bestLive(excluding: from) {
                    state = .migrating(from: from, to: next, since: now)
                    return [.switchTo(path: next), .replayFromLastAck,
                            .requestKeyframes, .startPing(path: next),
                            .ranking(.currentFailed(id: id))]
                }
                if live.contains(from) {
                    state = .live(current: from)
                    return [.ranking(.externalSwitch(from))]
                }
                state = .orphaned(since: now)
                return [.markReconnecting, .ranking(.currentFailed(id: id))]
            case .currentFailed:
                return []
            case .pongLost(let id) where id == to:
                // A migration means a failover already happened. A lost pong on
                // its target demotes the target to a standby: the old path
                // carries the session again if it can, else another path, else
                // the grace starts (PATH-21, D-2).
                standby.insert(id)
                if live.contains(from), !standby.contains(from) {
                    state = .live(current: from)
                    return [.ranking(.externalSwitch(from))]
                }
                if let next = bestLive(excluding: from) {
                    state = .migrating(from: from, to: next, since: now)
                    return [.switchTo(path: next), .replayFromLastAck,
                            .requestKeyframes, .startPing(path: next),
                            .ranking(.currentFailed(id: id))]
                }
                // E-9: the target is already a standby above; nothing usable is
                // left, so the grace starts and the target stays attached —
                // never removed from the sets without a close.
                state = .orphaned(since: now)
                return [.markReconnecting, .ranking(.currentFailed(id: id))]
            case .pongLost:
                return []
            case .drainExpired:
                // The peer's marker was not read in 2 s: close the old path and
                // stay Migrating; the new path's own pong timeout decides next.
                live.remove(from)
                standby.remove(from)
                return [.closePath(path: from), .stopPing(path: from)]
            case .close(let reason):
                state = .ended(reason: reason)
                return [.end(reason: reason)]
            case .pathUp(let id, _):
                if live.contains(id) { return [.closePath(path: id)] }
                live.insert(id)
                standby.remove(id)
                scores[id] = scores[id] ?? -1
                return [.startPing(path: id), .ranking(.pathUp(id))]
            case .graceExpired, .probeWelcomed, .standbyAnswered:
                return []
            }

        case .orphaned(let since):
            switch event {
            case .pathUp(let id, _):
                if live.contains(id) { return [.closePath(path: id)] }
                live.insert(id)
                standby.remove(id)
                scores[id] = scores[id] ?? -1
                state = .live(current: id)
                return [.switchTo(path: id), .replayFromLastAck,
                        .requestKeyframes, .startPing(path: id),
                        .ranking(.pathUp(id))]
            case .pathDown(let id):
                live.remove(id)
                standby.remove(id)
                return [.ranking(.pathDown(id))]
            case .graceExpired:
                guard now - since >= PathTimers.grace else { return [] }
                state = .ended(reason: "graceExpired")
                return [.end(reason: "graceExpired")]
            case .currentFailed(let id):
                live.remove(id)
                standby.remove(id)
                return [.ranking(.currentFailed(id: id))]
            case .pongLost(let id):
                // No path is carrying the session: nothing to fail over from.
                // D-2: a lost pong demotes, never detaches. The path stays
                // open and pinged, so its later answer still revives the
                // session (PATH-54); only its socket error or the end closes it.
                guard live.contains(id) else { return [] }
                standby.insert(id)
                return []
            case .peerSwitch:
                return [.ignore]
            case .probeWelcomed:
                return [.ignore]
            case .standbyAnswered(let id):
                // PATH-54 (#248): nothing carries the session, so the first
                // attached path that answers a ping takes it, with a join's
                // unplanned-switch semantics (PATH-6/9); it is already pinged.
                guard live.contains(id) else { return [] }
                standby.remove(id)
                state = .live(current: id)
                return [.switchTo(path: id), .replayFromLastAck,
                        .requestKeyframes, .ranking(.externalSwitch(id))]
            case .close(let reason):
                state = .ended(reason: reason)
                return [.end(reason: reason)]
            case .drainExpired:
                return []
            }
        }
    }

    /// A closed token for the transition log (PATH-14): never an address.
    var description: String {
        switch state {
        case .unfounded: return "unfounded"
        case .live(let current): return "live \(current)"
        case .migrating(let from, let to, _): return "migrating \(from)->\(to)"
        case .orphaned: return "orphaned"
        case .ended(let reason): return "ended \(reason)"
        }
    }
}

extension PathSessionMachine {
    /// PATH-6's 30 s grace. E-11c keys the rejoin's timeout and retry on the
    /// session state, never on a flag beside it.
    var isOrphaned: Bool {
        if case .orphaned = state { return true }
        return false
    }
}

// MARK: - Ranking (PATH-7, PATH-8)

struct PathStats {
    /// One sample per ping round: the RTT, or nil when the pong was lost.
    var samples: [(at: TimeInterval, rttMs: Double?)] = []
    var pings: Int = 0

    var pongs: Int { samples.compactMap(\.rttMs).count }

    mutating func prune(now: TimeInterval, window: TimeInterval = PathRanking.window) {
        samples.removeAll { now - $0.at > window }
    }
}

enum PathRankingState: Equatable {
    case idle
    case steady(current: String)
    case challenging(current: String, challenger: String, since: TimeInterval)
}

enum PathRankingEvent: Equatable {
    case pathUp(String)
    case pathDown(String)
    /// One ping round on `id`: the RTT, or nil for a lost pong.
    case sample(id: String, rttMs: Double?)
    case tick(now: TimeInterval)
    case currentFailed(id: String)
    /// The session switched (the peer's marker): the ranking follows.
    case externalSwitch(String)
}

enum PathRankingAction: Equatable {
    case switchTo(String)
    case sessionOrphan
}

struct PathRanking {
    static let window: TimeInterval = 30
    static let margin = 100
    static let hysteresis: TimeInterval = 5
    static let minPongs = 2
    /// E-8/RRR-4: a planned (margin) switch is held to one per session per
    /// this many seconds. Unplanned failovers and demotes are never held.
    static let plannedHold: TimeInterval = 30

    private(set) var state: PathRankingState = .idle
    private(set) var stats: [String: PathStats] = [:]
    private(set) var kinds: [String: PathKind] = [:]
    /// The last planned switch this session made (nil = none yet).
    private(set) var lastPlannedSwitchAt: TimeInterval?

    mutating func register(id: String, kind: PathKind = .lan) {
        kinds[id] = kind
        if stats[id] == nil { stats[id] = PathStats() }
    }

    mutating func addSample(id: String, rttMs: Double?, at now: TimeInterval) {
        register(id: id)
        stats[id]!.pings += 1
        stats[id]!.samples.append((now, rttMs))
        stats[id]!.prune(now: now)
    }

    /// The score in 0…1000, or nil while the path has fewer than 2 pongs.
    func score(id: String, now: TimeInterval) -> Int? {
        guard var s = stats[id] else { return nil }
        s.prune(now: now)
        guard s.pongs >= Self.minPongs, s.pings > 0 else { return nil }
        let rtts = s.samples.compactMap(\.rttMs).sorted()
        let p50 = Self.nearestRank(rtts, 0.50)
        let p95 = Self.nearestRank(rtts, 0.95)
        let loss = Double(s.pings - s.pongs) / Double(s.pings)
        return Self.score(p50Ms: p50, p95Ms: p95, loss: loss,
                          floorMbps: (kinds[id] ?? .lan).throughputClass.floorMbps)
    }

    static func nearestRank(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(0, Int(ceil(q * Double(sorted.count))) - 1)
        return sorted[min(index, sorted.count - 1)]
    }

    /// The pure formula (docs/design/paths.md §7.1), 0…1000.
    static func score(p50Ms: Double, p95Ms: Double, loss: Double, floorMbps: Int) -> Int {
        let qRtt = 1 / (1 + max(0, p50Ms) / 10)
        let qJit = 1 / (1 + max(0, p95Ms - p50Ms) / 25)
        let qLoss = 1 - min(max(0, loss), 0.10) / 0.10
        let qBw = min(1, Double(floorMbps) / 209)
        let score = 1000 * (0.45 * qRtt + 0.15 * qJit + 0.20 * qLoss + 0.20 * qBw)
        return Int(score.rounded())
    }

    private func bestLiveRankable(now: TimeInterval, excluding: String? = nil) -> String? {
        stats.keys.filter { $0 != excluding }
            .compactMap { id in score(id: id, now: now).map { (id, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    private func bestLiveAny(now: TimeInterval, excluding: String? = nil) -> String? {
        stats.keys.filter { $0 != excluding }
            .max { (score(id: $0, now: now) ?? -1) < (score(id: $1, now: now) ?? -1) }
    }

    mutating func handle(_ event: PathRankingEvent, now: TimeInterval) -> [PathRankingAction] {
        switch event {
        case .pathUp(let id):
            register(id: id)
            switch state {
            case .idle:
                guard let best = bestLiveRankable(now: now) else { return [] }
                state = .steady(current: best)
                return []
            case .steady, .challenging:
                return []
            }
        case .pathDown(let id):
            stats[id] = nil
            switch state {
            case .idle:
                return []
            case .steady(let current):
                if id == current {
                    guard let next = bestLiveAny(now: now) else {
                        state = .idle
                        return [.sessionOrphan]
                    }
                    state = .steady(current: next)
                    return [.switchTo(next)]
                }
                return []
            case .challenging(let current, let challenger, _):
                if id == challenger {
                    state = .steady(current: current)
                }
                if id == current {
                    guard let next = bestLiveAny(now: now) else {
                        state = .idle
                        return [.sessionOrphan]
                    }
                    state = .steady(current: next)
                    return [.switchTo(next)]
                }
                return []
            }
        case .sample(let id, let rtt):
            guard stats[id] != nil || state != .idle else { return [] }
            addSample(id: id, rttMs: rtt, at: now)
            return []
        case .tick(let tickNow):
            switch state {
            case .idle:
                // A real start is pathUp first, pongs seconds later: with no
                // score at pathUp the ranking stays idle, so the first tick
                // that has a ranked path elects it (the founder in practice).
                if let best = bestLiveRankable(now: tickNow) {
                    state = .steady(current: best)
                }
                return []
            case .challenging:
                break
            case .steady(let current):
                guard let challenger = bestLiveRankable(now: tickNow, excluding: current),
                      let currentScore = score(id: current, now: tickNow),
                      let challengerScore = score(id: challenger, now: tickNow),
                      challengerScore >= currentScore + Self.margin else { return [] }
                state = .challenging(current: current, challenger: challenger, since: tickNow)
                return []
            }
            switch state {
            case .challenging(let current, let challenger, let since):
                guard stats[challenger] != nil, stats[current] != nil else {
                    state = .steady(current: current)
                    return []
                }
                guard let currentScore = score(id: current, now: tickNow),
                      let challengerScore = score(id: challenger, now: tickNow),
                      challengerScore >= currentScore + Self.margin else {
                    state = .steady(current: current)
                    return []
                }
                guard tickNow - since >= Self.hysteresis else { return [] }
                // E-8/RRR-4: a planned switch drains and closes the old path,
                // which E-5 re-dials at once; without the hold the fresh idle
                // path wins straight back and the pair churns a handshake every
                // 10–25 s. The margin must still hold when the hold expires.
                if let last = lastPlannedSwitchAt, tickNow - last < Self.plannedHold {
                    return []
                }
                lastPlannedSwitchAt = tickNow
                state = .steady(current: challenger)
                return [.switchTo(challenger)]
            case .idle, .steady:
                return []
            }
        case .currentFailed(let id):
            stats[id] = nil
            guard let next = bestLiveAny(now: now) else {
                state = .idle
                return [.sessionOrphan]
            }
            state = .steady(current: next)
            return [.switchTo(next)]
        case .externalSwitch(let id):
            register(id: id)
            state = .steady(current: id)
            return []
        }
    }
}

// MARK: - The single-path silence probe (PATH-24, E-11)

/// A session with one path cannot notice a radio that died but whose socket
/// is still open: PATH-21 keeps that path live on a lost pong, and the old TCP
/// connection may sit in retransmission backoff for seconds after the network
/// returns. While a stream is open, 2 s without ANY inbound frame is the one
/// cheap signal that the path is silent, so the Mac dials one join beside it
/// and, when that fails, dials the next one at once (E-11b). It never fails or
/// closes the live path; the session decides the switch when the probe
/// welcomes.
enum PathProbeState: Equatable {
    case idle
    /// One dial is out; a failure goes back to `idle` and the next tick dials.
    case inFlight
}

enum PathProbeEvent: Equatable {
    /// The session's 0.25 s tick. `silentFor` is the current path's own
    /// inbound silence; only the machine decides whether it is a trigger.
    case tick(pathCount: Int, streamLive: Bool, silentFor: TimeInterval)
    /// The probe's path welcomed: the session has two paths now.
    case welcomed
    /// The probe's dial failed before a welcome.
    case failed
    /// Any inbound frame arrived on a live path: the silence is over.
    case inbound
    /// The stream closed or the session ended.
    case stop
}

enum PathProbeAction: Equatable {
    case dial
    case cancel
    case ignore
}

struct PathProbeMachine {
    /// E-11: frames, `window.still`, JSON or anything else count as inbound.
    static let silence: TimeInterval = 2.0

    /// E-11b: the probe's own connect timeout. It is deliberately shorter than
    /// the session's general dial timeout (the first connect keeps that one) so
    /// a probe begun during an outage catches the network's return within
    /// about a second instead of sitting out the general timeout.
    static let connectTimeout: TimeInterval = 2.0

    private(set) var state: PathProbeState = .idle

    /// `(state, event) -> (state, actions)`; the session owns the dial.
    mutating func handle(_ event: PathProbeEvent, now: TimeInterval) -> [PathProbeAction] {
        switch event {
        case .tick(let pathCount, let streamLive, let silentFor):
            let trigger = pathCount == 1 && streamLive && silentFor >= Self.silence
            switch state {
            case .idle:
                guard trigger else { return [.ignore] }
                state = .inFlight
                return [.dial]
            case .inFlight:
                // One probe in flight is the most the rule allows. A tick with
                // frames back means the silence ended: drop the dial.
                guard !trigger else { return [.ignore] }
                state = .idle
                return [.cancel]
            }

        case .welcomed:
            state = .idle
            return [.ignore]

        case .failed:
            switch state {
            case .idle:
                return [.ignore]
            case .inFlight:
                // E-11b: no backoff. The next tick finds the trigger still
                // holding and dials at once, so a returning network meets a
                // probe within a tick instead of seconds later.
                state = .idle
                return [.ignore]
            }

        case .inbound:
            switch state {
            case .inFlight:
                state = .idle
                return [.cancel]
            case .idle:
                state = .idle
                return [.ignore]
            }

        case .stop:
            switch state {
            case .inFlight:
                state = .idle
                return [.cancel]
            case .idle:
                state = .idle
                return [.ignore]
            }
        }
    }
}

// MARK: - The orphan's rejoin schedule (PATH-6, PATH-22, E-11c)

/// PATH-6's grace exists to get a session back quickly, so while the session
/// is orphaned a rejoin gives up after 2.0 s (the probe's own timeout, E-11b)
/// and a failed one is redialed on the next tick, back-to-back inside the
/// grace (E-11c). Outside the grace — a live session that is a path short —
/// and for every new-session attempt after it, the reconnect backoff
/// (1, 2, 4, 8, 15 s) is unchanged.
enum PathRejoinState: Equatable {
    case idle
    /// A round is out: one dial per missing provider. No tick may start a
    /// second round while it is unresolved. `failures` carries the reconnect
    /// backoff step across the round so the backoff outside the grace keeps
    /// stepping up.
    case inFlight(failures: Int)
    /// Outside the grace: the reconnect backoff holds the next round until
    /// `until`; `failures` is the backoff step it waits on.
    case waiting(until: TimeInterval, failures: Int)
    /// Inside the grace: a round that failed at once (a refused connection)
    /// waits until a second after it started, so a phone whose server is
    /// down is dialed once a second, not every tick.
    case spacing(until: TimeInterval)

    /// A closed token for the transition log: never an address or a session.
    var token: String {
        switch self {
        case .idle: return "idle"
        case .inFlight: return "in-flight"
        case .waiting: return "waiting"
        case .spacing: return "spacing"
        }
    }
}

enum PathRejoinEvent: Equatable {
    /// The session's 0.25 s tick. `needed` is true while the session has
    /// fewer paths than its ready providers can give and a provider has
    /// neither a path nor a dial; `orphaned` is the session's grace.
    case tick(needed: Bool, orphaned: Bool, now: TimeInterval)
    /// A rejoin dial failed before a welcome.
    case failed(orphaned: Bool, now: TimeInterval)
    /// A rejoin welcomed: its path attached.
    case welcomed
    /// The session closed.
    case stop

    var token: String {
        switch self {
        case .tick: return "tick"
        case .failed: return "failed"
        case .welcomed: return "welcomed"
        case .stop: return "stop"
        }
    }
}

enum PathRejoinAction: Equatable {
    case dial
    case ignore
}

struct PathRejoinMachine {
    /// E-11c: an orphaned rejoin's own connect timeout, the probe's 2.0 s.
    static let connectTimeout: TimeInterval = PathProbeMachine.connectTimeout

    /// Back-to-back rounds inside the grace start at least this far apart: a
    /// timed-out dial (2.0 s) is redialed at once, a refusal a second later.
    static let minRoundSpacing: TimeInterval = 1.0

    private(set) var state: PathRejoinState = .idle
    /// When the round in flight was dialed: the grace's spacing counts from it.
    private var roundStartedAt: TimeInterval = -.infinity

    /// `(state, event) -> (state, actions)`; the session owns the dials.
    mutating func handle(_ event: PathRejoinEvent, now: TimeInterval) -> [PathRejoinAction] {
        switch event {
        case .tick(let needed, let orphaned, let now):
            guard needed else { return [.ignore] }
            switch state {
            case .idle:
                state = .inFlight(failures: 0)
                roundStartedAt = now
                return [.dial]
            case .spacing(let until):
                guard now >= until else { return [.ignore] }
                state = .inFlight(failures: 0)
                roundStartedAt = now
                return [.dial]
            case .inFlight:
                // One round at a time: a tick never doubles a dial.
                return [.ignore]
            case .waiting(let until, let failures):
                // The grace overrides a wait begun while the session was live.
                guard orphaned || now >= until else { return [.ignore] }
                state = .inFlight(failures: failures)
                roundStartedAt = now
                return [.dial]
            }

        case .failed(let orphaned, let now):
            let failures: Int
            switch state {
            case .idle, .spacing:
                return [.ignore]
            case .inFlight(let step):
                failures = step + 1
            case .waiting(_, let step):
                failures = step + 1
            }
            if orphaned {
                // E-11c: no backoff inside the grace; the next tick dials, but
                // never sooner than a second after this round began.
                let earliest = roundStartedAt + Self.minRoundSpacing
                state = now >= earliest ? .idle : .spacing(until: earliest)
                return [.ignore]
            }
            state = .waiting(until: now + ReconnectPolicy.delay(afterFailures: failures),
                             failures: failures)
            return [.ignore]

        case .welcomed:
            state = .idle
            return [.ignore]

        case .stop:
            state = .idle
            return [.ignore]
        }
    }
}

// MARK: - One attempt's lifecycle (R-14)

/// A dialed path from `dial` to its welcome, its join, a refusal or a timeout.
/// One enum, one pure transition function: the flags (`ready`, `joinAsked`, a
/// live timer) used to mean the same things apart from each other.
enum AttemptPhase: Equatable {
    case dialing
    /// TLS finished; the plain hello's slot (PathStart) has not reached it yet.
    case ready
    /// Its hello went out; `join` is the session id it asked for (nil = plain).
    case hello(join: String?)
    case welcomed(session: String)
    case failed(reason: String)
    case closed
}

enum AttemptEvent: Equatable {
    case tlsReady
    case sentHello(join: String?)
    case welcomed(session: String)
    case failed(reason: String)
    case closed
}

/// The session owns the side effects (close the channel, report to PathStart);
/// the machine only says, per event, whether the phase moved.
enum AttemptAction: Equatable {
    case ignore
}

extension AttemptPhase {
    var token: String {
        switch self {
        case .dialing: return "dialing"
        case .ready: return "ready"
        case .hello(let join): return join == nil ? "hello" : "hello-join"
        case .welcomed: return "welcomed"
        case .failed: return "failed"
        case .closed: return "closed"
        }
    }

    /// The session id this attempt's hello asked to join, if it was a join.
    var joinSession: String? {
        if case .hello(let join) = self { return join }
        return nil
    }

    var isWelcomed: Bool {
        if case .welcomed = self { return true }
        return false
    }
}

extension AttemptEvent {
    var token: String {
        switch self {
        case .tlsReady: return "tls"
        case .sentHello(let join): return join == nil ? "hello" : "join"
        case .welcomed: return "welcome"
        case .failed: return "fail"
        case .closed: return "close"
        }
    }
}

struct AttemptMachine {
    private(set) var phase: AttemptPhase = .dialing

    /// `(phase, event) -> (phase, actions)`; an event that cannot happen in the
    /// current phase is ignored, never guessed at.
    mutating func handle(_ event: AttemptEvent) -> [AttemptAction] {
        switch (phase, event) {
        case (.dialing, .tlsReady):
            phase = .ready
            return []
        case (.ready, .sentHello(let join)):
            phase = .hello(join: join)
            return []
        case (.hello, .welcomed(let session)):
            phase = .welcomed(session: session)
            return []
        case (.dialing, .failed(let reason)),
             (.ready, .failed(let reason)),
             (.hello, .failed(let reason)),
             (.welcomed, .failed(let reason)):
            phase = .failed(reason: reason)
            return []
        case (.dialing, .closed), (.ready, .closed), (.hello, .closed),
             (.welcomed, .closed), (.failed, .closed):
            phase = .closed
            return []
        case (.dialing, .sentHello), (.dialing, .welcomed),
             (.ready, .tlsReady), (.ready, .welcomed),
             (.hello, .tlsReady), (.hello, .sentHello),
             (.welcomed, .tlsReady), (.welcomed, .sentHello), (.welcomed, .welcomed),
             (.failed, .tlsReady), (.failed, .sentHello), (.failed, .welcomed),
             (.failed, .failed), (.closed, .tlsReady), (.closed, .sentHello),
             (.closed, .welcomed), (.closed, .failed), (.closed, .closed):
            return [.ignore]
        }
    }
}

// MARK: - The switch's marker order (PATH-9)

enum PathSwitchKind: Equatable {
    case planned
    case unplanned
}

enum PathSwitchStep: Equatable {
    /// Send `path.switch{path, seq}` on `path`.
    case marker(path: String, seq: UInt64)
    case replayFromLastAck
    case requestKeyframe(stream: UInt32)
    case closePath(String)
}

enum PathSwitch {
    /// A planned switch sends the marker last on the path being left; an
    /// unplanned one sends it first on the new path (PATH-9).
    static func plan(kind: PathSwitchKind, from: String, to: String,
                     nextSeq: UInt64, streams: [UInt32]) -> [PathSwitchStep] {
        switch kind {
        case .planned:
            return [.marker(path: from, seq: nextSeq), .replayFromLastAck]
                + streams.map { .requestKeyframe(stream: $0) }
                + [.closePath(from)]
        case .unplanned:
            return [.marker(path: to, seq: nextSeq), .replayFromLastAck]
                + streams.map { .requestKeyframe(stream: $0) }
                + [.closePath(from)]
        }
    }

    /// A marker naming a path this side does not have is ignored (logged once).
    static func accepts(marker path: String, live: Set<String>) -> Bool {
        live.contains(path)
    }
}
