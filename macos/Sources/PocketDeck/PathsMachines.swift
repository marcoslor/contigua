// The session and ranking machines (docs/design/paths.md §6, §7.3), pure
// transitions with actions the owner performs. The same tables run on the
// phone (`PathSession.kt`, `PathRanking.kt`) with the same vectors.

import Foundation

// MARK: - Session (PATH-3, PATH-6, PATH-9, PATH-13, PATH-16)

enum PathSessionState: Equatable {
    case live(current: String)
    case migrating(from: String, to: String, since: TimeInterval)
    case orphaned(since: TimeInterval)
    case ended(reason: String)
}

enum PathSessionEvent: Equatable {
    case pathUp(id: String, joined: Bool)
    case pathDown(id: String)
    case currentFailed(id: String)
    /// The peer's marker arrived on `arrivedOn`; `id` is the path being moved to.
    case peerSwitch(id: String, seq: UInt64, arrivedOn: String)
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
    var live: Set<String>
    /// The ranking's opinion of each live path (0…1000); the failover choice.
    var scores: [String: Int]
    /// The class each live path was ranked with.
    var kinds: [String: PathKind]

    init(state: PathSessionState = .orphaned(since: 0),
         live: Set<String> = [],
         scores: [String: Int] = [:],
         kinds: [String: PathKind] = [:]) {
        self.state = state
        self.live = live
        self.scores = scores
        self.kinds = kinds
    }

    var currentPath: String? {
        if case .live(let current) = state { return current }
        return nil
    }

    private func bestLive(excluding: String? = nil) -> String? {
        let candidates = live.filter { $0 != excluding }
        return candidates.max { (scores[$0] ?? -1) < (scores[$1] ?? -1) }
    }

    /// One transition: `(state, event, live set, clock) -> (state, actions)`.
    mutating func handle(_ event: PathSessionEvent, now: TimeInterval) -> [PathSessionAction] {
        switch state {
        case .ended:
            return [.ignore]

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
                if arrivedOn == current {
                    state = .migrating(from: current, to: id, since: now)
                    return [.startPing(path: id), .ranking(.externalSwitch(id))]
                }
                // The old path is already gone: the marker came on the new one.
                state = .live(current: id)
                live.remove(current)
                return [.closePath(path: current), .stopPing(path: current),
                        .startPing(path: id), .ranking(.externalSwitch(id))]
            case .currentFailed(let id):
                guard id == current else { return [] }
                live.remove(id)
                if let next = bestLive() {
                    state = .migrating(from: id, to: next, since: now)
                    return [.stopPing(path: id), .switchTo(path: next),
                            .replayFromLastAck, .requestKeyframes,
                            .startPing(path: next), .ranking(.currentFailed(id: id))]
                }
                state = .orphaned(since: now)
                return [.stopPing(path: id), .markReconnecting, .ranking(.currentFailed(id: id))]

            case .pathDown(let id):
                live.remove(id)
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
            }

        case .migrating(let from, let to, _):
            switch event {
            case .peerSwitch(let id, _, _):
                guard id == to else { return [.ignore] }
                state = .live(current: to)
                live.remove(from)
                return [.closePath(path: from), .stopPing(path: from),
                        .ranking(.externalSwitch(to))]
            case .pathDown(let id):
                live.remove(id)
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
            case .drainExpired:
                // The peer's marker was not read in 2 s: close the old path and
                // stay Migrating; the new path's own pong timeout decides next.
                live.remove(from)
                return [.closePath(path: from), .stopPing(path: from)]
            case .close(let reason):
                state = .ended(reason: reason)
                return [.end(reason: reason)]
            case .pathUp(let id, _):
                if live.contains(id) { return [.closePath(path: id)] }
                live.insert(id)
                scores[id] = scores[id] ?? -1
                return [.startPing(path: id), .ranking(.pathUp(id))]
            case .graceExpired:
                return []
            }

        case .orphaned(let since):
            switch event {
            case .pathUp(let id, _):
                if live.contains(id) { return [.closePath(path: id)] }
                live.insert(id)
                scores[id] = scores[id] ?? -1
                state = .live(current: id)
                return [.switchTo(path: id), .replayFromLastAck,
                        .requestKeyframes, .startPing(path: id),
                        .ranking(.pathUp(id))]
            case .pathDown(let id):
                live.remove(id)
                return [.ranking(.pathDown(id))]
            case .graceExpired:
                guard now - since >= PathTimers.grace else { return [] }
                state = .ended(reason: "graceExpired")
                return [.end(reason: "graceExpired")]
            case .currentFailed(let id):
                live.remove(id)
                return [.ranking(.currentFailed(id: id))]
            case .peerSwitch:
                return [.ignore]
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
        case .live(let current): return "live \(current)"
        case .migrating(let from, let to, _): return "migrating \(from)->\(to)"
        case .orphaned: return "orphaned"
        case .ended(let reason): return "ended \(reason)"
        }
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

    private(set) var state: PathRankingState = .idle
    private(set) var stats: [String: PathStats] = [:]
    private(set) var kinds: [String: PathKind] = [:]

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
            case .idle, .challenging:
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
