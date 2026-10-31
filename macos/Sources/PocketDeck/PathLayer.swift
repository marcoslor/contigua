// The Mac's path layer (docs/design/paths.md §3): one TLS channel per path, the
// session's seq/ack/replay stream above them, the 2 s ping, the switch's marker
// and the credit that pauses a bulk producer. It never decides a switch (PATH-8);
// the session machine does, and calls [moveTo] with the winner.
//
// All state is behind one lock: sends may come from the UI or the session's
// queue, reads from each path's channel thread, and the session queue drives
// the timers. Only one caller runs the session machine (Session's queue).

import Foundation

final class PathLayer {
    struct Path {
        let id: String
        let kind: PathKind
        /// Writes one encoded frame on this path's channel.
        let send: @Sendable ([UInt8]) -> Void
        let close: @Sendable () -> Void
        /// True while the channel's write buffer is below its water mark: only
        /// then does the layer feed it more bulk (D-2).
        let isWritable: @Sendable () -> Bool
        /// Stops or resumes reading this path: a full reorder window stops the
        /// path that is ahead instead of dropping (R-11).
        let setReading: @Sendable (Bool) -> Void

        init(id: String, kind: PathKind, send: @escaping @Sendable ([UInt8]) -> Void,
             close: @escaping @Sendable () -> Void,
             isWritable: @escaping @Sendable () -> Bool = { true },
             setReading: @escaping @Sendable (Bool) -> Void = { _ in }) {
            self.id = id
            self.kind = kind
            self.send = send
            self.close = close
            self.isWritable = isWritable
            self.setReading = setReading
        }
    }

    enum Event {
        /// One reliable frame, already deduped, in order.
        case deliver(Frame)
        /// A `path.pong` for the ping we sent; `rttMs` uses our own clock.
        case pong(path: String, rttMs: Double)
        /// The phone moved its sending path; `seq` is its next reliable seq.
        case peerSwitch(path: String, seq: UInt64, arrivedOn: String)
        /// A ping this side answered (told for logging only).
        case ping(path: String)
        /// The path died (EOF, reset, write error).
        case down(path: String)
        /// An ACK above anything sent: a protocol error the session ends on.
        case ackAboveSent
    }

    private struct Pending {
        let frame: Frame
        let bulk: Bool
        let completion: (@Sendable (Bool) -> Void)?
    }

    private let lock = NSLock()
    private let nowMs: () -> Int64
    private let log: (String) -> Void

    private var paths: [String: Path] = [:]
    /// Insertion order, for deterministic pings and close logs.
    private var order: [String] = []
    private var current: String?
    private var replay = ReplayBuffer()
    private var reorder = ReorderWindow()
    private var pending: [Pending] = []
    /// Admitted reliable frames per path, in seq order, fed to the channel only
    /// while it is writable (D-2). The replay buffer still owns them.
    private var outbox: [String: [[UInt8]]] = [:]
    /// The last time any frame arrived on a path: a path that is still receiving
    /// is alive even when a pong is late (D-2).
    private var lastInboundAt: [String: Int64] = [:]
    private var ackFrames = 0
    private var lastAckAt: Int64 = 0
    /// The last bulk frame admitted or delivered (D-1's transfer window).
    private var lastBulkAt: Int64 = 0
    private var lastPingAt: Int64 = 0
    private var pingSentAt: [String: Int64] = [:]
    private var joinedAwaitingPong: [String: Int64] = [:]
    private var draining: [String: Int64] = [:]
    private var closed = false

    /// Test seams.
    var heldBytes: Int { locked { replay.heldBytes } }
    private(set) var peakHeldBytes = 0
    var pathCount: Int { locked { paths.count } }
    var currentPath: String? { locked { current } }
    /// Attached path ids, for a new dial that must not reuse one (PATH-19).
    var pathIds: [String] { locked { order } }
    var ackValue: UInt64 { locked { reorder.ack } }

    init(nowMs: @escaping () -> Int64 = { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
         log: @escaping (String) -> Void = { _ in }) {
        self.nowMs = nowMs
        self.log = log
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: Paths

    /// The first path founds the session; later ones attach.
    func start(first: Path) {
        locked {
            guard paths.isEmpty else { return }
            paths[first.id] = first
            order = [first.id]
            current = first.id
            outbox[first.id] = []
        }
    }

    func hasPath(_ id: String) -> Bool { locked { paths[id] != nil } }

    /// Adds a joined path. The session enforces the 3-path cap before calling.
    /// A join is pinged at once (PATH-12/D-1), so its ranking starts at once.
    func attach(_ path: Path, joined: Bool) {
        var pingNow = false
        locked {
            guard !closed, paths[path.id] == nil else { return }
            paths[path.id] = path
            order.append(path.id)
            outbox[path.id] = []
            if current == nil { current = path.id }
            if joined {
                let at = nowMs()
                joinedAwaitingPong[path.id] = at
                pingSentAt[path.id] = at
                pingNow = true
            }
        }
        if pingNow {
            let frame = Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload([
                "t": "path.ping", "path": path.id, "ts": NSNumber(value: nowMs()),
            ]))
            path.send(frame.encoded)
        }
    }

    @discardableResult
    func detach(_ id: String) -> Bool {
        let path: Path? = locked {
            guard let path = paths.removeValue(forKey: id) else { return nil }
            order.removeAll { $0 == id }
            if current == id { current = nil }
            draining.removeValue(forKey: id)
            pingSentAt.removeValue(forKey: id)
            joinedAwaitingPong.removeValue(forKey: id)
            outbox.removeValue(forKey: id)
            lastInboundAt.removeValue(forKey: id)
            return path
        }
        guard let path else { return false }
        path.close()
        return true
    }

    func closeAll() {
        let peak = locked { peakHeldBytes }
        let all: [Path] = locked {
            closed = true
            let all = order.compactMap { paths[$0] }
            paths.removeAll()
            order.removeAll()
            current = nil
            draining.removeAll()
            pingSentAt.removeAll()
            joinedAwaitingPong.removeAll()
            pending.removeAll()
            outbox.removeAll()
            lastInboundAt.removeAll()
            return all
        }
        for path in all { path.close() }
        log("paths: replay peak \(peak) bytes")
    }

    /// Moves the sending path. A planned switch leaves the old one draining
    /// until the peer's marker or the 2 s backstop closes it (§5.4). An
    /// unplanned one keeps the old path as a standby, so its queued bulk is
    /// dropped from the outbox and replayed on the new path (D-2).
    func moveTo(_ to: String, plannedFrom: String?) {
        let old: String? = locked {
            guard paths[to] != nil else { return nil }
            let old = current
            current = to
            if let plannedFrom, plannedFrom != to, paths[plannedFrom] != nil {
                draining[plannedFrom] = nowMs() + Self.drainBackstopMs
            } else if let old, old != to {
                outbox[old] = []
            }
            return old
        }
        if let old, old != to { pump(to) }
    }

    /// The channel under a path became writable again: feed it what the layer
    /// has been holding (D-2).
    func writable(_ id: String) { pump(id) }

    /// Old paths whose drain backstop passed; the caller detaches them.
    func closeDrained() -> [String] {
        let due: [String] = locked {
            let now = nowMs()
            let expired = draining.filter { now >= $0.value }.map(\.key)
            for id in expired { draining.removeValue(forKey: id) }
            return expired
        }
        return due
    }

    // MARK: Sending

    /// Sends one frame: reliable frames are wrapped, kept for replay and written
    /// on the current path; lossy ones go bare. A reliable frame that does not
    /// fit waits for the ack that frees credit (PATH-10), never dropped.
    func send(_ frame: Frame, completion: (@Sendable (Bool) -> Void)? = nil) {
        sendLocked(frame, completion: completion)
    }

    private func sendLocked(_ frame: Frame, completion: (@Sendable (Bool) -> Void)?) {
        guard !locked({ closed }) else { completion?(false); return }
        guard PathCodec.isReliable(frame.type) else {
            let target: Path? = locked { current.flatMap { paths[$0] } }
            if let target { target.send(frame.encoded) }
            completion?(target != nil)
            return
        }
        let bulk = PathCodec.isBulk(frame.type)
        var queuedOn: String?
        locked {
            guard !closed else { return }
            // Only bulk queues behind pending bulk (PATH-10, R-6): control is
            // admitted against its own budget at once, and seqs are assigned
            // at admission, so the wire order stays a valid seq order.
            if bulk {
                guard pending.isEmpty else {
                    pending.append(Pending(frame: frame, bulk: bulk, completion: completion))
                    return
                }
            }
            let wrapped = (try? PathCodec.encodeReliable(seq: replay.nextSeq, inner: frame))?.encoded
            let size = wrapped?.count ?? Int.max
            guard let wrapped, replay.canAdmit(bytes: size, bulk: bulk) else {
                pending.append(Pending(frame: frame, bulk: bulk, completion: completion))
                return
            }
            let seq = replay.nextSeq
            try? replay.append(seq: seq, frame: wrapped, bulk: bulk)
            peakHeldBytes = max(peakHeldBytes, replay.heldBytes)
            if bulk { lastBulkAt = nowMs() }
            if let id = current, paths[id] != nil {
                outbox[id, default: []].append(wrapped)
                queuedOn = id
            }
        }
        completion?(true)
        if let queuedOn { pump(queuedOn) }
    }

    /// Feeds a path's queued frames to its channel while it is writable. Bulk
    /// waits here instead of in the channel's write buffer, so a ping, a pong,
    /// an ACK or a marker never queues behind megabytes of a file (D-2).
    private func pump(_ id: String) {
        while true {
            let next: (Path, [UInt8])? = locked {
                guard let path = paths[id], let first = outbox[id]?.first,
                      path.isWritable() else { return nil }
                outbox[id]?.removeFirst()
                return (path, first)
            }
            guard let (path, bytes) = next else { return }
            path.send(bytes)
        }
    }

    /// Sends one bare frame on a named path: `hello`, `welcome`, `path.pong` and
    /// the ACK never enter the seq space (PATH-12).
    func sendBare(on id: String, frame: Frame) {
        let path: Path? = locked { paths[id] }
        path?.send(frame.encoded)
    }

    /// Sends a reliable `path.switch` on [on] naming [to]; the marker is frame
    /// N, so its `seq` field is N + 1 (§5.4).
    func sendMarker(on: String, to: String) -> Bool {
        var sent = false
        locked {
            guard !closed, paths[on] != nil else { return }
            let seq = replay.nextSeq
            let frame = Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload([
                "t": "path.switch", "path": to, "seq": NSNumber(value: seq + 1),
            ]))
            guard let wrapped = try? PathCodec.encodeReliable(seq: seq, inner: frame).encoded else { return }
            guard replay.canAdmit(bytes: wrapped.count, bulk: false) else {
                pending.append(Pending(frame: frame, bulk: false, completion: nil))
                return
            }
            try? replay.append(seq: seq, frame: wrapped, bulk: false)
            peakHeldBytes = max(peakHeldBytes, replay.heldBytes)
            outbox[on, default: []].append(wrapped)
            sent = true
        }
        if sent { pump(on) }
        return sent
    }

    /// Writes every unacked frame on the current path (a switch's replay). The
    /// outbox is replaced, so a frame admitted but not yet written goes once.
    func replayOnCurrent() {
        let id: String? = locked {
            guard !closed, let id = current, paths[id] != nil else { return nil }
            outbox[id] = replay.unacked.map(\.frame)
            return id
        }
        if let id { pump(id) }
    }

    // MARK: Receiving

    func receive(path id: String, frame: Frame) -> [Event] {
        var events: [Event] = []
        locked { lastInboundAt[id] = nowMs() }
        if frame.type == PathCodec.ackType {
            let ack: UInt64
            do { ack = try PathCodec.decodeAck(frame) } catch { return [.ackAboveSent] }
            var flush: [Flushed] = []
            var target: String?
            let above: Bool = locked {
                if replay.ackAboveSent(ack) { return true }
                _ = replay.ack(ack)
                flush = admitPendingLocked()
                if let id = current, paths[id] != nil {
                    for item in flush { outbox[id, default: []].append(item.bytes) }
                    target = id
                }
                return false
            }
            if above { return [.ackAboveSent] }
            for item in flush { item.completion?(true) }
            if let target { pump(target) }
            return []
        }
        if frame.type == PathCodec.reliableType {
            let reliable: ReliableFrame
            do { reliable = try PathCodec.decodeReliable(frame) } catch {
                return [.down(path: id)]
            }
            let result: ReorderWindow.Result = locked { reorder.receive(reliable) }
            switch result {
            case .deliver(let frames):
                if frames.contains(where: { PathCodec.isBulk($0.inner.type) }) {
                    locked { lastBulkAt = nowMs() }
                }
                for item in frames {
                    // A marker travels reliable, like every JSON frame: the
                    // inner path.switch is the peer's switch, not a message
                    // for the session (PATH-9).
                    if item.inner.type == MessageType.json.rawValue,
                       let message = JSONFrame.decode(payload: item.inner.payload),
                       message.t == "path.switch",
                       let target = message.string("path"),
                       let seq = message.int("seq"), hasPath(target) {
                        events.append(.peerSwitch(path: target,
                                                  seq: UInt64(max(0, seq)),
                                                  arrivedOn: id))
                    } else {
                        events.append(.deliver(item.inner))
                    }
                }
            case .duplicate:
                sendAckNow(on: id)
            case .buffered, .full:
                break
            }
            ackLater(on: id)
            return events
        }
        // Bare JSON: path.ping/pong/switch only (every other JSON is reliable).
        if frame.type == MessageType.json.rawValue,
           let message = JSONFrame.decode(payload: frame.payload) {
            switch message.t {
            case "path.ping":
                let pingPath = message.string("path") ?? id
                let ts = Int64(message.int("ts") ?? 0)
                if hasPath(pingPath) {
                    sendBare(on: id, frame: Frame(type: MessageType.json.rawValue, stream: 0,
                                                  payload: JSONFrame.payload([
                                                      "t": "path.pong", "path": pingPath, "ts": NSNumber(value: ts),
                                                  ])))
                    events.append(.ping(path: pingPath))
                }
            case "path.pong":
                let pingPath = message.string("path") ?? id
                let ts = Int64(message.int("ts") ?? 0)
                if hasPath(pingPath) {
                    let rtt = Double(max(0, nowMs() - ts))
                    locked {
                        pingSentAt.removeValue(forKey: pingPath)
                        joinedAwaitingPong.removeValue(forKey: pingPath)
                    }
                    events.append(.pong(path: pingPath, rttMs: rtt))
                }
            case "path.switch":
                if let target = message.string("path"), hasPath(target),
                   let seq = message.int("seq").map({ UInt64(max(0, $0)) }) {
                    events.append(.peerSwitch(path: target, seq: seq, arrivedOn: id))
                } else {
                    log("path.switch for unknown path ignored")
                }
            default:
                events.append(.deliver(frame))
            }
            return events
        }
        events.append(.deliver(frame))
        return events
    }

    private struct Flushed {
        let bytes: [UInt8]
        let completion: (@Sendable (Bool) -> Void)?
    }

    /// Admits the fitting prefix of [pending] in order. The bytes are already
    /// wrapped; the caller sends them. Nothing is re-queued through `send`:
    /// that would put the prefix behind the remainder and reorder the stream.
    private func admitPendingLocked() -> [Flushed] {
        var out: [Flushed] = []
        while let item = pending.first {
            let wrapped = try? PathCodec.encodeReliable(seq: replay.nextSeq, inner: item.frame).encoded
            guard let wrapped, replay.canAdmit(bytes: wrapped.count, bulk: item.bulk) else {
                break
            }
            let seq = replay.nextSeq
            try? replay.append(seq: seq, frame: wrapped, bulk: item.bulk)
            peakHeldBytes = max(peakHeldBytes, replay.heldBytes)
            out.append(Flushed(bytes: wrapped, completion: item.completion))
            pending.removeFirst()
        }
        return out
    }

    private func sendAckNow(on id: String) {
        let ack: UInt64 = locked { reorder.ack }
        locked {
            paths[id]?.send(PathCodec.encodeAck(ack).encoded)
            lastAckAt = nowMs()
            ackFrames = 0
        }
    }

    private func ackLater(on id: String) {
        let due: Bool = locked {
            ackFrames += 1
            if ackFrames >= Self.ackFrames || nowMs() - lastAckAt >= Self.ackEveryMs {
                ackFrames = 0
                lastAckAt = nowMs()
                return true
            }
            return false
        }
        if due { sendAckNow(on: id) }
    }

    // MARK: Ping and health

    /// D-1's policy: one path is never pinged (its liveness is TCP keepalive
    /// plus the session's 15 s ping); two or more are pinged every 2 s while
    /// the phone's screen is on or a transfer runs, otherwise every 15 s. The
    /// standby is included (PATH-7).
    func pingAll(active: Bool) {
        let at = nowMs()
        let targets: [Path] = locked {
            guard !closed else { return [] }
            guard paths.count >= 2 else {
                lastPingAt = at
                return []
            }
            let interval = (active || transferActiveLocked(at)) ? Self.pingIntervalMs : Self.pingIdleIntervalMs
            guard at - lastPingAt >= interval else { return [] }
            lastPingAt = at
            return order.compactMap { paths[$0] }
        }
        guard !targets.isEmpty else { return }
        for path in targets {
            locked { pingSentAt[path.id] = at }
            let frame = Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload([
                "t": "path.ping", "path": path.id, "ts": NSNumber(value: at),
            ]))
            path.send(frame.encoded)
        }
    }

    /// A transfer runs while a bulk frame moved recently (a drop, an APK, fs
    /// bulk or clipboard images); the 2 s ping interval applies then (D-1).
    private func transferActiveLocked(_ at: Int64) -> Bool {
        at - lastBulkAt <= Self.transferWindowMs
    }

    /// Paths whose ping went unanswered for 1.5 s (one lost sample). A path
    /// that received any frame in that window is alive: a pong can queue behind
    /// our own bulk on a slow link, and a live path must not be demoted for it
    /// (D-2).
    func lostPings() -> [String] {
        let at = nowMs()
        return locked {
            let lost = pingSentAt.filter { id, sent in
                at - sent > Self.pongTimeoutMs && at - (lastInboundAt[id] ?? at - Self.aliveMs - 1) > Self.aliveMs
            }.map(\.key)
            for id in lost { pingSentAt.removeValue(forKey: id) }
            return lost
        }
    }

    /// Joined paths that have answered no ping in 5 s (PATH-13).
    func joinedTimeouts() -> [String] {
        let at = nowMs()
        return locked {
            let lost = joinedAwaitingPong.filter { at - $0.value > Self.joinedPingDropMs }.map(\.key)
            for id in lost { joinedAwaitingPong.removeValue(forKey: id) }
            return lost
        }
    }

    /// The phone's marker arrived: the old path may drain at once.
    func drainNow(_ id: String) {
        locked { draining[id] = nowMs() }
    }

    static let maxPaths = 3
    static let pingIntervalMs: Int64 = 2_000
    /// The slower ping with two paths and no screen or transfer (D-1).
    static let pingIdleIntervalMs: Int64 = 15_000
    /// How recently a bulk frame must have moved to count as "a transfer runs".
    static let transferWindowMs: Int64 = 3_000
    static let pongTimeoutMs: Int64 = 1_500
    /// A path that delivered anything this recently is alive (D-2).
    static let aliveMs: Int64 = 1_500
    static let joinedPingDropMs: Int64 = 5_000
    static let drainBackstopMs: Int64 = 2_000
    static let ackEveryMs: Int64 = 10
    static let ackFrames = 16
}
