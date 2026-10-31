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
        /// A reliable frame whose outer stream disagreed with its inner one:
        /// §5.3 makes it a session protocol error, not one path's (R-16).
        case protocolError(String)
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
    /// Bytes in each outbox: bulk enters the seq space only while its path's
    /// outbox is under [bulkAdmitBytes] (E-4), so a key is never behind a
    /// whole file's credit.
    private var outboxBytes: [String: Int] = [:]
    /// The last time any frame arrived on a path: a path that is still receiving
    /// is alive even when a pong is late (D-2).
    private var lastInboundAt: [String: Int64] = [:]
    /// Reliable frames that did not fit a full reorder window, per path: kept,
    /// never dropped, while that path's reader is stopped (R-11).
    private var overflow: [String: [(UInt64, Frame)]] = [:]
    /// Bytes held per path's overflow: one window at most (PATH-10/PATH-15).
    private var overflowBytes: [String: Int] = [:]
    /// Lossy bytes written into a path's channel while it is over its water
    /// mark, per path: E-1's 128 KiB cap. Reset when the channel drains.
    private var lossyQueued: [String: Int] = [:]
    /// The path that last delivered in order: the gap before [reorder.expected]
    /// is that path's to fill (RR-7). Nil until the first delivery.
    private var gapPath: String?
    private var readingPaused: Set<String> = []
    private var ackFrames = 0
    private var lastAckPath: String?
    private var ackFlushArmed = false
    private var lastAckAt: Int64 = 0
    /// The last bulk frame admitted or delivered (D-1's transfer window).
    private var lastBulkAt: Int64 = 0
    private var lastPingAt: Int64 = 0
    private var pingSentAt: [String: Int64] = [:]
    private var joinedAwaitingPong: [String: Int64] = [:]
    private var draining: [String: Int64] = [:]
    /// Paths whose pump is running right now: one writer per path keeps a
    /// path's writes in order (PATH-4/RR-14). A second sender leaves its frame
    /// in the outbox and the running pump picks it up.
    private var pumping: Set<String> = []
    private var closed = false

    /// Test seams.
    var heldBytes: Int { locked { replay.heldBytes } }
    private(set) var peakHeldBytes = 0
    var pathCount: Int { locked { paths.count } }
    var currentPath: String? { locked { current } }
    /// Attached path ids, for a new dial that must not reuse one (PATH-19).
    var pathIds: [String] { locked { order } }
    var ackValue: UInt64 { locked { reorder.ack } }
    /// RR-9/PATH-7: a bulk transfer ran within the last [transferWindowMs].
    var transferActive: Bool { locked { transferActiveLocked(nowMs()) } }

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
            outboxBytes[first.id] = 0
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
            outboxBytes[path.id] = 0
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
            outboxBytes.removeValue(forKey: id)
            lastInboundAt.removeValue(forKey: id)
            overflow.removeValue(forKey: id)
            overflowBytes.removeValue(forKey: id)
            lossyQueued.removeValue(forKey: id)
            readingPaused.remove(id)
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
            outboxBytes.removeAll()
            lastInboundAt.removeAll()
            overflow.removeAll()
            overflowBytes.removeAll()
            lossyQueued.removeAll()
            readingPaused.removeAll()
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
                outboxBytes[old] = 0
            }
            return old
        }
        if let old, old != to { pump(to) }
    }

    /// The channel under a path became writable again: feed it what the layer
    /// has been holding (D-2) and let lossy frames queue again (E-1).
    func writable(_ id: String) {
        locked { lossyQueued[id] = 0 }
        pump(id)
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
            // E-1: lossy frames go straight to the channel, which has no
            // credit. While the channel is over its water mark they are
            // capped at 128 KiB per path: past that the frame is dropped (a
            // lossy frame is never replayed) instead of queueing without
            // bound. A writable channel resets the count.
            var target: Path?
            var sent = false
            locked {
                guard !closed, let id = current, let path = paths[id] else { return }
                if !path.isWritable() {
                    let queued = lossyQueued[id, default: 0]
                    guard queued < Self.lossyCapBytes else { return }
                    lossyQueued[id] = queued + frame.encoded.count
                }
                target = path
                sent = true
            }
            if let target { target.send(frame.encoded) }
            completion?(sent)
            return
        }
        let bulk = PathCodec.isBulk(frame.type)
        // The frame's wire size does not depend on its seq: size it before the
        // gate, so the unacknowledged window is a hard bound (E-4).
        let bulkSize = bulk ? (try? PathCodec.encodeReliable(seq: 0, inner: frame).encoded.count) ?? Int.max : 0
        var queuedOn: String?
        locked {
            guard !closed else { return }
            // Only bulk queues behind pending bulk (PATH-10, R-6): control is
            // admitted against its own budget at once, and seqs are assigned
            // at admission, so the wire order stays a valid seq order.
            if bulk {
                // Bulk waits outside the seq space while anything is already
                // pending, or while the current path has no room (E-4): it
                // gets a seq only when that path has room.
                guard pending.isEmpty, outboxHasBulkRoomLocked(for: bulkSize) else {
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
                outboxBytes[id, default: 0] += wrapped.count
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
        // One pump per path (PATH-4/RR-14): a second sender leaves its frame in
        // the outbox and the running pump picks it up, so two senders' frames
        // can never reach the channel out of seq order.
        let owner: Bool = locked {
            if pumping.contains(id) { return false }
            pumping.insert(id)
            return true
        }
        guard owner else { return }
        while true {
            var flushed: [Flushed] = []
            var stop = false
            let next: (Path, [UInt8])? = locked {
                guard let path = paths[id], path.isWritable() else {
                    stop = true
                    return nil
                }
                if outbox[id]?.isEmpty ?? true, id == current {
                    // The outbox drained: bulk that waited outside the seq
                    // space may enter it now, while there is room (E-4).
                    flushed = admitPendingLocked()
                    for item in flushed {
                        outbox[id, default: []].append(item.bytes)
                        outboxBytes[id, default: 0] += item.bytes.count
                    }
                }
                guard let first = outbox[id]?.first else {
                    stop = true
                    return nil
                }
                outbox[id]?.removeFirst()
                outboxBytes[id, default: 0] = max(0, (outboxBytes[id] ?? 0) - first.count)
                return (path, first)
            }
            for item in flushed { item.completion?(true) }
            guard let (path, bytes) = next else {
                if !stop { return }
                // Give up the claim and look again under the same lock: a
                // frame appended just before the claim is dropped is picked up
                // here, and one appended after it starts a fresh pump.
                let again: Bool = locked {
                    pumping.remove(id)
                    guard let path = paths[id], path.isWritable(),
                          !(outbox[id]?.isEmpty ?? true) else { return false }
                    pumping.insert(id)
                    return true
                }
                if again { continue }
                return
            }
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
            // E-6: the marker is one small control frame and never waits for
            // credit. Its field is the seq of the frame after it, set here,
            // when it is admitted — never earlier, and it is never queued in
            // the pending list with a stale field.
            guard let wrapped = try? PathCodec.encodeReliable(seq: seq, inner: frame).encoded else { return }
            try? replay.append(seq: seq, frame: wrapped, bulk: false, force: true)
            peakHeldBytes = max(peakHeldBytes, replay.heldBytes)
            outbox[on, default: []].append(wrapped)
            outboxBytes[on, default: 0] += wrapped.count
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
            let frames = replay.unacked.map(\.frame)
            outbox[id] = frames
            outboxBytes[id] = frames.reduce(0) { $0 + $1.count }
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
                    for item in flush {
                        outbox[id, default: []].append(item.bytes)
                        outboxBytes[id, default: 0] += item.bytes.count
                    }
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
            do {
                reliable = try PathCodec.decodeReliable(frame)
            } catch PathCodecError.streamMismatch {
                // §5.3: the outer stream disagreed with the inner one, which a
                // correct writer never produces: a session protocol error (R-16).
                return [.protocolError("stream-mismatch")]
            } catch {
                return [.down(path: id)]
            }
            var fed = Fed()
            locked { fed = feedLocked(id, reliable) }
            if let token = fed.protocolError {
                return [.protocolError(token)]
            }
            for pid in fed.pause { locked { paths[pid] }?.setReading(false) }
            for pid in fed.resume { locked { paths[pid] }?.setReading(true) }
            if fed.delivered.contains(where: { PathCodec.isBulk($0.frame.inner.type) }) {
                locked { lastBulkAt = nowMs() }
            }
            for item in fed.delivered {
                // A marker travels reliable, like every JSON frame: the
                // inner path.switch is the peer's switch, not a message
                // for the session (PATH-9).
                if item.frame.inner.type == MessageType.json.rawValue,
                   let message = JSONFrame.decode(payload: item.frame.inner.payload),
                   message.t == "path.switch",
                   let target = message.string("path"),
                   let seq = message.int("seq"), hasPath(target) {
                    events.append(.peerSwitch(path: target,
                                              seq: UInt64(max(0, seq)),
                                              arrivedOn: item.path))
                } else {
                    events.append(.deliver(item.frame.inner))
                }
            }
            for pid in fed.duplicates { sendAckNow(on: pid) }
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

    private struct Fed {
        var delivered: [(path: String, frame: ReliableFrame)] = []
        var duplicates: [String] = []
        var pause: [String] = []
        var resume: [String] = []
        /// More than one window ahead of a gap this path must fill itself.
        var protocolError: String?
    }

    /// Takes one reliable frame into the reorder window. A frame that does not
    /// fit is kept here and its path's reader is stopped — never dropped
    /// (PATH-10/R-11) — and drained when the gap fills.
    private func feedLocked(_ id: String, _ reliable: ReliableFrame?) -> Fed {
        var fed = Fed()
        if let reliable { feedOneLocked(id, reliable, into: &fed) }
        // A path that was stopped for a full window resumes as soon as there is
        // room again, and its held frames go in.
        for pid in Array(readingPaused) {
            if (overflow[pid]?.isEmpty ?? true) {
                readingPaused.remove(pid)
                fed.resume.append(pid)
                continue
            }
            guard reorderHasRoom else { continue }
            drainLocked(pid, into: &fed)
            if overflow[pid]?.isEmpty ?? true {
                readingPaused.remove(pid)
                fed.resume.append(pid)
            }
        }
        return fed
    }

    private var reorderHasRoom: Bool {
        reorder.bufferedCount < ReorderWindow.maxFrames && reorder.bufferedBytes < ReorderWindow.maxBytes
    }

    private func feedOneLocked(_ id: String, _ reliable: ReliableFrame, into fed: inout Fed) {
        switch reorder.receive(reliable) {
        case .deliver(let frames):
            gapPath = id
            for frame in frames { fed.delivered.append((id, frame)) }
        case .duplicate:
            fed.duplicates.append(id)
        case .buffered:
            break
        case .full:
            // RR-7/PATH-10: a frame ahead of a gap on this path's own stream
            // never stops its reader — a paused reader could never read the
            // frame that fills the gap. It waits in this path's overflow, one
            // window at most. Only a gap another path holds stops this one.
            overflow[id, default: []].append((reliable.seq, reliable.inner))
            overflowBytes[id, default: 0] += reliable.inner.payload.count
            if overflow[id]!.count > ReorderWindow.maxFrames
                || overflowBytes[id]! > ReorderWindow.maxBytes {
                fed.protocolError = "reorder-overflow"
                return
            }
            if gapPath != nil, gapPath != id, readingPaused.insert(id).inserted {
                fed.pause.append(id)
            }
            return
        }
        drainLocked(id, into: &fed)
    }

    private func drainLocked(_ id: String, into fed: inout Fed) {
        while let next = overflow[id]?.first {
            switch reorder.receive(ReliableFrame(seq: next.0, inner: next.1)) {
            case .deliver(let frames):
                gapPath = id
                overflow[id]?.removeFirst()
                overflowBytes[id, default: 0] = max(0, (overflowBytes[id] ?? 0) - next.1.payload.count)
                for frame in frames { fed.delivered.append((id, frame)) }
            case .duplicate, .buffered:
                overflow[id]?.removeFirst()
                overflowBytes[id, default: 0] = max(0, (overflowBytes[id] ?? 0) - next.1.payload.count)
            case .full:
                if gapPath != nil, gapPath != id, readingPaused.insert(id).inserted {
                    fed.pause.append(id)
                }
                return
            }
        }
    }

    /// The current path's outbox bytes; 0 with no attached current path (an
    /// orphan's bulk waits in the replay buffer like every reliable frame).
    private var currentOutboxBytesLocked: Int {
        guard let id = current, paths[id] != nil else { return 0 }
        return outboxBytes[id] ?? 0
    }

    /// True while bulk may take a seq on the current path (E-4). "Room" is the
    /// path's outbox under its 256 KiB watermark *and* its unacknowledged bulk
    /// under the 1 MiB window: the channel's own buffers hold a written frame
    /// until the peer reads it, so a gate on the outbox alone let the full
    /// 12 MiB credit sit in the kernel (the key was still about a credit late).
    private func outboxHasBulkRoomLocked(for size: Int) -> Bool {
        guard currentOutboxBytesLocked < Self.bulkAdmitBytes else { return false }
        // One frame larger than the window is admitted on an empty queue.
        return replay.bulkBytes == 0 || replay.bulkBytes + size <= Self.bulkWindowBytes
    }

    /// Admits the fitting prefix of [pending] in order. The bytes are already
    /// wrapped; the caller sends them. Nothing is re-queued through `send`:
    /// that would put the prefix behind the remainder and reorder the stream.
    private func admitPendingLocked() -> [Flushed] {
        var out: [Flushed] = []
        var queued = currentOutboxBytesLocked
        var inFlight = replay.bulkBytes
        while let item = pending.first {
            // Bulk waits outside the seq space until its path has room (E-4):
            // its outbox under the low watermark and its unacknowledged queue
            // inside the window. Control is admitted at once.
            let size = (try? PathCodec.encodeReliable(seq: 0, inner: item.frame).encoded.count) ?? Int.max
            if item.bulk,
               queued >= Self.bulkAdmitBytes
                || (inFlight > 0 && inFlight + size > Self.bulkWindowBytes) {
                break
            }
            let wrapped = try? PathCodec.encodeReliable(seq: replay.nextSeq, inner: item.frame).encoded
            guard let wrapped, replay.canAdmit(bytes: wrapped.count, bulk: item.bulk) else {
                break
            }
            queued += wrapped.count
            if item.bulk { inFlight += wrapped.count }
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
            lastAckPath = id
            if ackFrames >= Self.ackFrames || nowMs() - lastAckAt >= Self.ackEveryMs {
                ackFrames = 0
                lastAckAt = nowMs()
                return true
            }
            return false
        }
        if due {
            sendAckNow(on: id)
        } else {
            armAckFlush()
        }
    }

    /// R-15: the coalesced ACK is not left waiting for the next frame. 10 ms
    /// after the first unflushed frame the running session's queue flushes it.
    private func armAckFlush() {
        let arm: Bool = locked {
            guard !ackFlushArmed else { return false }
            ackFlushArmed = true
            return true
        }
        guard arm else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in  // gcd: the 10 ms ack flush timer hops back to the main queue
            self?.flushAck()
        }
    }

    /// Sends the one ACK a burst within the 10 ms window earned.
    func flushAck() {
        let target: (path: String, ack: UInt64)? = locked {
            ackFlushArmed = false
            guard ackFrames > 0, let id = lastAckPath ?? current else { return nil }
            ackFrames = 0
            lastAckAt = nowMs()
            return (id, reorder.ack)
        }
        guard let target, let path = locked({ paths[target.path] }) else { return }
        path.send(PathCodec.encodeAck(target.ack).encoded)
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

    /// Pings that timed out on a path that is still receiving: one ranking
    /// sample, never a failure (D-2/RR-14), exactly as the phone records it.
    func latePongs() -> [String] {
        let at = nowMs()
        return locked {
            let late = pingSentAt.filter { id, sent in
                at - sent > Self.pongTimeoutMs
                    && at - (lastInboundAt[id] ?? at - Self.aliveMs - 1) <= Self.aliveMs
            }.map(\.key)
            for id in late { pingSentAt.removeValue(forKey: id) }
            return late
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
    /// How recently a bulk frame must have moved to count as "a transfer runs"
    /// (PATH-7, the same 2 s on both sides).
    static let transferWindowMs: Int64 = 2_000
    static let pongTimeoutMs: Int64 = 1_500
    /// A path that delivered anything this recently is alive (D-2).
    static let aliveMs: Int64 = 1_500
    static let joinedPingDropMs: Int64 = 5_000
    static let drainBackstopMs: Int64 = 2_000
    static let ackEveryMs: Int64 = 10
    static let ackFrames = 16
    /// E-4: bulk enters the seq space only while its path's outbox is under
    /// this. The channel's own low write watermark is the same 256 KiB (D-2),
    /// so a key is never behind more than a watermark plus one chunk.
    static let bulkAdmitBytes = 256 << 10
    /// The unacknowledged window bulk may fill: RR-4's 1 MiB floor (about two
    /// RTTs at a LAN rate). The outbox keeps its 256 KiB watermark; without
    /// the floor one frame per ack round starved a 64 MiB drop on a path with
    /// packet-sized ack coalescing.
    static let bulkWindowBytes = 1 << 20
    /// E-1: lossy frames may queue at most this much on a path that is over
    /// its write watermark (the old SEND_BUFFER_BYTES role).
    static let lossyCapBytes = 128 << 10
}
