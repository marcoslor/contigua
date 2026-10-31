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
    private var ackFrames = 0
    private var lastAckAt: Int64 = 0
    private var lastPingAt: Int64 = 0
    private var pingSentAt: [String: Int64] = [:]
    private var joinedAwaitingPong: [String: Int64] = [:]
    private var draining: [String: Int64] = [:]
    private var closed = false

    /// Test seams.
    var heldBytes: Int { locked { replay.heldBytes } }
    var pathCount: Int { locked { paths.count } }
    var currentPath: String? { locked { current } }
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
        }
    }

    func hasPath(_ id: String) -> Bool { locked { paths[id] != nil } }

    /// Adds a joined path. The session enforces the 3-path cap before calling.
    func attach(_ path: Path, joined: Bool) {
        locked {
            guard !closed, paths[path.id] == nil else { return }
            paths[path.id] = path
            order.append(path.id)
            if current == nil { current = path.id }
            if joined { joinedAwaitingPong[path.id] = nowMs() }
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
            return path
        }
        guard let path else { return false }
        path.close()
        return true
    }

    func closeAll() {
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
            return all
        }
        for path in all { path.close() }
    }

    /// Moves the sending path. A planned switch leaves the old one draining
    /// until the peer's marker or the 2 s backstop closes it (§5.4).
    func moveTo(_ to: String, plannedFrom: String?) {
        locked {
            guard paths[to] != nil else { return }
            current = to
            if let plannedFrom, plannedFrom != to, paths[plannedFrom] != nil {
                draining[plannedFrom] = nowMs() + Self.drainBackstopMs
            }
        }
    }

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
        var ready: (path: Path?, seq: UInt64, frame: [UInt8])?
        locked {
            guard !closed else { return }
            let wrapped = (try? PathCodec.encodeReliable(seq: replay.nextSeq, inner: frame))?.encoded
            let size = wrapped?.count ?? Int.max
            guard let wrapped, replay.canAdmit(bytes: size, bulk: bulk) else {
                pending.append(Pending(frame: frame, bulk: bulk, completion: completion))
                return
            }
            let seq = replay.nextSeq
            try? replay.append(seq: seq, frame: wrapped, bulk: bulk)
            ready = (current.flatMap { paths[$0] }, seq, wrapped)
        }
        guard let ready else { return }
        ready.path?.send(ready.frame)
        completion?(true)
        if ready.path == nil && current != nil {
            // The write failed on a vanished path: that path's own error will
            // arrive from the channel; the frame stays in the replay buffer.
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
            paths[on]?.send(wrapped)
            sent = true
        }
        return sent
    }

    /// Writes every unacked frame on the current path (a switch's replay).
    func replayOnCurrent() {
        let target: (path: Path, frames: [[UInt8]])? = locked {
            guard !closed, let id = current, let path = paths[id] else { return nil }
            return (path, replay.unacked.map(\.frame))
        }
        guard let target else { return }
        for frame in target.frames { target.path.send(frame) }
    }

    // MARK: Receiving

    func receive(path id: String, frame: Frame) -> [Event] {
        var events: [Event] = []
        if frame.type == PathCodec.ackType {
            let ack: UInt64
            do { ack = try PathCodec.decodeAck(frame) } catch { return [.ackAboveSent] }
            var flush: [Pending] = []
            let above: Bool = locked {
                if replay.ackAboveSent(ack) { return true }
                _ = replay.ack(ack)
                flush = takePendingLocked()
                return false
            }
            if above { return [.ackAboveSent] }
            for item in flush { sendLocked(item.frame, completion: item.completion) }
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

    private func takePendingLocked() -> [Pending] {
        var out: [Pending] = []
        var keep: [Pending] = []
        for item in pending {
            let wrapped = try? PathCodec.encodeReliable(seq: replay.nextSeq, inner: item.frame).encoded
            if let wrapped, replay.canAdmit(bytes: wrapped.count, bulk: item.bulk) {
                out.append(item)
            } else {
                keep.append(item)
            }
        }
        pending = keep
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

    /// Every path is pinged every 2 s, the standby included (PATH-7).
    func pingAll() {
        let at = nowMs()
        let targets: [Path] = locked {
            guard !closed, at - lastPingAt >= Self.pingIntervalMs else { return [] }
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

    /// Paths whose ping went unanswered for 1.5 s (one lost sample).
    func lostPings() -> [String] {
        let at = nowMs()
        return locked {
            let lost = pingSentAt.filter { at - $0.value > Self.pongTimeoutMs }.map(\.key)
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
    static let pongTimeoutMs: Int64 = 1_500
    static let joinedPingDropMs: Int64 = 5_000
    static let drainBackstopMs: Int64 = 2_000
    static let ackEveryMs: Int64 = 10
    static let ackFrames = 16
}
