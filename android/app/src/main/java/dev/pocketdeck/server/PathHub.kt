package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathCodec
import dev.pocketdeck.proto.PathIds
import dev.pocketdeck.proto.PathKind
import dev.pocketdeck.proto.ReorderWindow
import dev.pocketdeck.proto.ReplayBuffer
import java.io.BufferedOutputStream
import java.io.OutputStream
import java.net.Socket
import java.util.ArrayDeque

/**
 * The phone's path layer (docs/design/paths.md §3): one TLS socket per path,
 * the session's seq/ack/replay stream above them, the 2 s ping, the switch's
 * marker and the credit that pauses a bulk producer. It never decides a switch
 * (PATH-8): the Mac's `path.switch` names the sending path.
 *
 * Reads run on a thread per path; all writes go through one lock so a path's
 * byte stream is never interleaved. The session thread owns the machine and
 * consumes [Event]s from [receive]/[detach].
 */
class PathHub(
    private val log: (String) -> Unit = {},
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    /** R-15: wakes the ticker so the 10 ms ACK timer is not late. */
    private val wake: () -> Unit = {},
) {
    /**
     * One path's socket plus its own writer (R-2): nothing is written under
     * the hub lock, so a stalled path cannot freeze the reader, the ticker or
     * teardown of the others. Bare control frames (ping, pong, ACK, an
     * unplanned switch marker) take a priority lane ahead of queued bulk.
     */
    class Transport(
        var id: String,
        val socket: Socket,
        val plain: Socket,
        val kind: PathKind,
    ) {
        val out: OutputStream = BufferedOutputStream(socket.getOutputStream())
        @Volatile var closed = false

        /** Set by the hub: the writer reports a dead socket from its own thread. */
        @Volatile var onFailure: ((Throwable) -> Unit)? = null

        private val writeLock = Object()
        private val priority = ArrayDeque<ByteArray>()
        private val normal = ArrayDeque<ByteArray>()
        private var priorityBytes = 0
        private var normalBytes = 0
        private var writingBytes = 0
        private var writer: Thread? = null
        private var writing = false

        /** Bytes queued on this path, the blocked write included (E-1/RR-1). */
        val queuedBytes: Int
            get() = synchronized(writeLock) { priorityBytes + normalBytes + writingBytes }

        /**
         * Queues bytes for this path; never blocks on the socket. E-1: a lossy
         * frame (video, audio, hover) waits here while the path already holds a
         * cap's worth, as the writer waited on the kernel buffer before R-2.
         * Priority lanes (ping, pong, ACK, marker) never wait on this.
         */
        fun send(bytes: ByteArray, priorityLane: Boolean = false, lossy: Boolean = false) {
            synchronized(writeLock) {
                if (lossy && !priorityLane) {
                    // One frame larger than the cap is admitted when the path is
                    // empty: waiting could never make room for it.
                    while (!closed && priorityBytes + normalBytes + writingBytes > 0 &&
                        priorityBytes + normalBytes + writingBytes + bytes.size > LOSSY_QUEUE_CAP_BYTES
                    ) {
                        writeLock.wait(100)
                    }
                }
                if (closed) return
                if (priorityLane) {
                    priority.addLast(bytes)
                    priorityBytes += bytes.size
                } else {
                    normal.addLast(bytes)
                    normalBytes += bytes.size
                }
                writeLock.notifyAll()
                if (writer == null) {
                    writer = Thread({ writerLoop() }, "pocketdeck-path-writer-$id").apply {
                        isDaemon = true
                        start()
                    }
                }
            }
        }

        private fun writerLoop() {
            while (true) {
                val bytes = synchronized(writeLock) {
                    while (!closed && priority.isEmpty() && normal.isEmpty()) writeLock.wait()
                    if (closed) return
                    val next = if (priority.isNotEmpty()) {
                        priority.removeFirst().also { priorityBytes -= it.size }
                    } else {
                        normal.removeFirst().also { normalBytes -= it.size }
                    }
                    writingBytes = next.size
                    writing = true
                    next
                }
                try {
                    out.write(bytes)
                    out.flush()
                } catch (e: Throwable) {
                    synchronized(writeLock) {
                        writing = false
                        writingBytes = 0
                        writeLock.notifyAll()
                    }
                    if (!closed) onFailure?.invoke(e)
                    return
                }
                synchronized(writeLock) {
                    writing = false
                    writingBytes = 0
                    writeLock.notifyAll()
                }
            }
        }

        /**
         * Waits until every queued byte is written, at most until [deadline]
         * (a monotonic ms value; 0 = don't wait). A parked write never blocks
         * a close for longer than that.
         */
        /** Waits for the queued bytes to be written, at most until [deadline]. */
        fun drain(deadline: Long) {
            synchronized(writeLock) {
                while (!closed && (writing || priority.isNotEmpty() || normal.isNotEmpty())) {
                    val left = deadline - System.currentTimeMillis()
                    if (left <= 0) break
                    writeLock.wait(left)
                }
            }
        }

        fun close(drainUntil: Long = 0L) {
            if (drainUntil > 0) drain(drainUntil)
            synchronized(writeLock) {
                closed = true
                priority.clear()
                normal.clear()
                writeLock.notifyAll()
            }
            runCatching { plain.shutdownInput() }
            runCatching { plain.shutdownOutput() }
            runCatching { plain.close() }
            runCatching { socket.close() }
        }
    }

    sealed interface Event {        /** One frame the session dispatcher sees, already deduped and in order. */
        data class Deliver(val frame: Frame) : Event

        /** The path died (EOF, reset, write error). */
        data class Down(val path: String) : Event

        /** A `path.pong` for the ping we sent; [rttMs] uses our own clock. */
        data class Pong(val path: String, val rttMs: Double) : Event

        /** A ping this side must answer (done inside [receive], but told too). */
        data class Ping(val path: String) : Event

        /** The peer moved its sending path; [seq] is its next reliable seq. */
        data class PeerSwitch(val path: String, val seq: Long, val arrivedOn: String) : Event

        /** An ACK above anything sent: a protocol error that ends the session. */
        data object AckAboveSent : Event

        /** A RELIABLE frame whose wrapper contradicts it: end the session (§5.3). */
        data object ProtocolError : Event

        /**
         * The reorder window is full. [stop] is false when the gap is on this
         * same path's stream: pausing that reader could never fill it (R-11).
         */
        data class Backpressure(val path: String, val stop: Boolean) : Event
    }

    /** One ping went unanswered; [alive] is true while the path keeps delivering. */
    data class PongLoss(val path: String, val alive: Boolean)

    private val lock = Object()
    private val paths = LinkedHashMap<String, Transport>()
    private var current: String? = null
    private var replay = ReplayBuffer()
    private val reorder = ReorderWindow()
    private val pendingAck = HashSet<String>()
    private var ackFrames = 0
    private var lastAckAt = 0L
    /** R-15: when the coalesced ACK's 10 ms timer expires, and its path. */
    private var ackDueAt = 0L
    private var ackPath: String? = null
    private var lastPingAt = 0L
    private var lastBulkAt = 0L
    private val pingSentAt = HashMap<String, Long>()
    /** D-2: the last time each path delivered any inbound bytes. */
    private val lastInboundAt = HashMap<String, Long>()
    /** A joined path that never answers a ping is dropped at 5 s (PATH-13). */
    private val joinedAwaitingPong = HashMap<String, Long>()
    private var closed = false
    /** The path that delivered the last in-order frame: where the gap is. */
    private var gapPath: String? = null

    val pathCount: Int get() = synchronized(lock) { paths.size }
    val currentPath: String? get() = synchronized(lock) { current }

    fun start(firstPath: Transport) {
        firstPath.onFailure = { failPath(firstPath.id, it) }
        synchronized(lock) {
            if (paths.isEmpty()) {
                paths[firstPath.id] = firstPath
                current = firstPath.id
            }
        }
    }

    /** Names the provisional handshake transport with the hello's path id. */
    fun rekey(old: String, new: String) {
        if (old == new) return
        synchronized(lock) {
            val t = paths.remove(old) ?: return
            t.id = new
            paths[new] = t
            if (current == old) current = new
        }
    }

    fun hasPath(id: String): Boolean = synchronized(lock) { paths.containsKey(id) }

    /** Waits (bounded) for the paths' writer queues to flush before a close. */
    fun drain(ms: Long = CLOSE_DRAIN_MS) {
        val all = synchronized(lock) { paths.values.toList() }
        val deadline = System.currentTimeMillis() + ms
        for (t in all) t.drain(deadline)
    }

    /** Marks a joined path's first-pong deadline (PATH-13). */
    fun expectFirstPong(id: String) = synchronized(lock) {
        if (paths.containsKey(id)) joinedAwaitingPong[id] = now()
    }

    /** Adds a joined path; false when the cap (3) is reached or the id is live. */
    fun attach(path: Transport): Boolean = synchronized(lock) {
        if (paths.size >= MAX_PATHS || paths.containsKey(path.id)) return false
        path.onFailure = { failPath(path.id, it) }
        paths[path.id] = path
        if (current == null) current = path.id
        true
    }

    fun transport(id: String): Transport? = synchronized(lock) { paths[id] }

    fun detach(id: String): Boolean {
        val t = synchronized(lock) {
            val removed = paths.remove(id) ?: return false
            if (current == id) current = null
            pingSentAt.remove(id)
            lastInboundAt.remove(id)
            joinedAwaitingPong.remove(id)
            removed
        }
        // Closing can wait on a peer's read; never under the hub lock (R-2).
        // A short drain lets a refusal or a planned switch's marker go out.
        runCatching { t.close(System.currentTimeMillis() + CLOSE_DRAIN_MS) }
        return true
    }

    fun closeAll() {
        val all = synchronized(lock) {
            closed = true
            val copy = paths.values.toList()
            paths.clear()
            current = null
            copy
        }
        // One shared deadline: teardown stays bounded however many paths exist.
        val drainUntil = System.currentTimeMillis() + CLOSE_DRAIN_MS
        for (t in all) runCatching { t.close(drainUntil) }
    }

    /** Sends a reliable frame wrapped, or a lossy one bare (PATH-4/5). */
    fun send(bytes: ByteArray) {
        val type = bytes[4].toInt() and 0xFF
        if (!PathCodec.isReliable(type)) {
            val target = synchronized(lock) { current }
            if (target != null) writeTo(target, bytes, lossy = true)
            return
        }
        val bulk = PathCodec.isBulk(type)
        // E-4: bulk enters the seq space only while its path has room, so a key
        // or a window frame is at most the watermark plus a chunk behind.
        if (bulk) awaitPathRoom()
        // The replay buffer holds the frame as sent: the wrapper adds 13 bytes.
        awaitCredit(bytes.size + PathCodec.WRAPPER_BYTES, bulk)
        synchronized(lock) {
            if (closed) return
            val seq = replay.nextSeq
            val inner = frameOf(bytes)
            val wrapped = PathCodec.encodeReliable(seq, inner)
            replay.append(seq, wrapped, bulk)
            if (bulk) lastBulkAt = now()
            // Enqueue under the lock so seq order matches the write order; the
            // path's own writer does the socket write outside it (R-2).
            val target = current
            if (target != null) paths[target]?.send(wrapped)
        }
    }

    /** Sends one bare JSON/frame on a named path (welcome, pong, ack). */
    fun sendOn(path: String, bytes: ByteArray) {
        writeTo(path, bytes)
    }

    fun sendJSONOn(path: String, obj: Map<String, Any?>, priority: Boolean = false) {
        writeTo(path, Frames.encodeJson(0, Json.encode(obj)), priority)
    }

    /** Waits (writer thread) until the replay buffer can take the frame. */
    private fun awaitCredit(bytes: Int, bulk: Boolean) {
        synchronized(lock) {
            while (!closed && !replay.canAdmit(bytes, bulk)) {
                lock.wait(100)
            }
        }
    }

    /**
     * E-4/RR-4: a bulk producer waits here, outside the seq space, while the
     * sending path still holds its watermark. The path's writer notifies only
     * its own lock, so this polls at a fraction of the smallest useful chunk's
     * time on the slowest path (256 KiB at 16 Mbit is 128 ms).
     */
    private fun awaitPathRoom() {
        synchronized(lock) {
            while (!closed) {
                val t = current?.let { paths[it] } ?: return
                if (t.queuedBytes < BULK_QUEUE_WATERMARK_BYTES) return
                lock.wait(10)
            }
        }
    }

    fun canAdmit(bytes: Int, bulk: Boolean): Boolean = synchronized(lock) { replay.canAdmit(bytes, bulk) }

    /** Writes every unacked frame on the current path (a switch's replay). */
    fun replayOnCurrent() {
        synchronized(lock) {
            val target = current ?: return
            val t = paths[target] ?: return
            for (entry in replay.unacked()) t.send(entry.frame)
        }
    }

    /**
     * E-3/E-6: follows the Mac's `path.switch`. The path left behind is never
     * closed here (E-3), and the marker never waits for credit: the replay is
     * what earns the ACK a waiting marker could never see.
     */
    fun followSwitch(to: String, markerOn: String) {
        moveTo(to)
        replayOnCurrent()
        sendMarkerOn(markerOn, to)
    }

    /** The phone's own marker: my next reliable frame is nextSeq and goes on [to]. */
    fun sendMarker(to: String) = sendMarkerOn(to, to)

    /**
     * A marker names the path being moved to (PATH-9); a planned switch sends
     * it on the path being left, an unplanned one on the new path. It is
     * itself reliable frame `N`, so the field names `N + 1`. E-6: it bypasses
     * credit (the replay it would wait for is what earns the ACK) and always
     * takes the priority lane; its seq is fixed here, under the lock that
     * assigns every seq, never when a writer later picks it up.
     */
    fun sendMarkerOn(onPath: String, to: String) {
        synchronized(lock) {
            if (closed) return
            val markerSeq = replay.nextSeq
            val bytes = Frames.encodeJson(
                0,
                Json.encode(mapOf("t" to "path.switch", "path" to to, "seq" to markerSeq + 1)),
            )
            val wrapped = PathCodec.encodeReliable(markerSeq, frameOf(bytes))
            replay.appendUncredited(markerSeq, wrapped)
            paths[onPath]?.send(wrapped, priorityLane = true)
        }
    }

    /**
     * Moves the sending path. E-3: the phone never closes the path it leaves;
     * it stays attached as a standby and the Mac closes it when it decides to.
     */
    fun moveTo(to: String) {
        synchronized(lock) {
            if (!paths.containsKey(to)) return
            current = to
        }
    }

    // ---- reading ------------------------------------------------------

    /**
     * Processes one frame from [path]. Reliable frames are unwrapped, deduped,
     * reordered and acked; the returned events are what the session dispatches.
     */
    fun receive(path: String, frame: Frame): List<Event> {
        synchronized(lock) { lastInboundAt[path] = now() }
        val events = ArrayList<Event>()
        when (frame.type) {
            PathCodec.TYPE_ACK -> {
                val ack = try {
                    PathCodec.decodeAck(frame)
                } catch (e: dev.pocketdeck.proto.PathException) {
                    return listOf(Event.AckAboveSent)
                }
                synchronized(lock) {
                    if (replay.ackAboveSent(ack)) return listOf(Event.AckAboveSent)
                    replay.ack(ack)
                    lock.notifyAll()
                }
            }
            PathCodec.TYPE_RELIABLE -> {
                val inner = try {
                    PathCodec.decodeReliable(frame)
                } catch (e: Throwable) {
                    // §5.3: a wrapper that contradicts its own header (or is
                    // malformed) is a session protocol error, not one path.
                    return listOf(Event.ProtocolError)
                }
                val result = synchronized(lock) { reorder.receive(inner) }
                when (result) {
                    is ReorderWindow.Result.Deliver -> {
                        synchronized(lock) { gapPath = path }
                        for (f in result.frames) {
                            if (PathCodec.isBulk(f.inner.type)) {
                                synchronized(lock) { lastBulkAt = now() }
                            }
                            // A marker travels reliable, like every JSON frame:
                            // the inner path.switch is the peer's switch, not a
                            // message for the session (PATH-9).
                            val inner = f.inner
                            val obj = if (inner.type == Frames.TYPE_JSON) {
                                runCatching { Json.parseObject(String(inner.payload)) }.getOrNull()
                            } else null
                            if (obj?.get("t") == "path.switch") {
                                val target = obj["path"] as? String
                                val seq = (obj["seq"] as? Number)?.toLong() ?: 0
                                if (target != null && target in currentPaths()) {
                                    events.add(Event.PeerSwitch(target, seq, path))
                                } else {
                                    log("path.switch for unknown path ignored")
                                }
                            } else {
                                events.add(Event.Deliver(inner))
                            }
                        }
                        synchronized(lock) { lock.notifyAll() }
                    }
                    ReorderWindow.Result.Duplicate -> sendAckNow(path)
                    ReorderWindow.Result.Buffered -> Unit
                    ReorderWindow.Result.Full -> {
                        val gap = synchronized(lock) { gapPath }
                        events.add(Event.Backpressure(path, stop = gap != null && gap != path))
                    }
                }
            }
            else -> {
                if (frame.type == Frames.TYPE_JSON) {
                    val obj = runCatching { Json.parseObject(String(frame.payload)) }.getOrNull()
                    when (obj?.get("t")) {
                        "path.ping" -> {
                            val pingPath = obj["path"] as? String ?: path
                            val ts = (obj["ts"] as? Number)?.toLong() ?: 0
                            if (pingPath in currentPaths()) {
                                sendJSONOn(path, mapOf("t" to "path.pong", "path" to pingPath, "ts" to ts), priority = true)
                                events.add(Event.Ping(pingPath))
                            }
                        }
                        "path.pong" -> {
                            val pingPath = obj["path"] as? String ?: path
                            val ts = (obj["ts"] as? Number)?.toLong() ?: 0
                            if (pingPath in currentPaths()) {
                                val rtt = (now() - ts).coerceAtLeast(0).toDouble()
                                synchronized(lock) {
                                    pingSentAt.remove(pingPath)
                                    joinedAwaitingPong.remove(pingPath)
                                }
                                events.add(Event.Pong(pingPath, rtt))
                            }
                        }
                        "path.switch" -> {
                            val target = obj["path"] as? String
                            val seq = (obj["seq"] as? Number)?.toLong() ?: 0
                            if (target != null && target in currentPaths()) {
                                events.add(Event.PeerSwitch(target, seq, path))
                            } else {
                                log("path.switch for unknown path ignored")
                            }
                        }
                        else -> events.add(Event.Deliver(frame))
                    }
                } else {
                    events.add(Event.Deliver(frame))
                }
            }
        }
        return events
    }

    private fun currentPaths(): Set<String> = synchronized(lock) { paths.keys.toSet() }

    private fun frameOf(encoded: ByteArray): Frame =
        Frame(encoded[4].toInt() and 0xFF, PathCodec.readInt(encoded, 5),
              encoded.copyOfRange(9, encoded.size))

    private fun writeTo(path: String, bytes: ByteArray, priority: Boolean = false, lossy: Boolean = false) {
        val t = synchronized(lock) { paths[path] } ?: return
        t.send(bytes, priority, lossy)
    }

    private fun failPath(path: String, why: Throwable) {
        // The reader thread reports the Down event; a write failure detaches here.
        // Class and message only: a payload or a path's bytes never reach a log
        // (R-PRIV-1). Boot 5 swallowed this exception, so the fix names it.
        log("path down: $path (${why.javaClass.simpleName}: ${why.message})")
        detach(path)
    }

    /** The reader handed this frame's events to the session: ACK may advance. */
    fun ackHandled(path: String) = ackLater(path)

    /** R-15: the 10 ms coalescing timer fired (the ticker calls this). */
    fun flushAck() {
        val path = synchronized(lock) {
            if (closed || ackDueAt == 0L || now() < ackDueAt) return
            val id = ackPath
            ackFrames = 0
            lastAckAt = now()
            ackDueAt = 0
            ackPath = null
            id
        }
        if (path != null) sendAckNow(path)
    }

    private fun sendAckNow(path: String) {
        val ack = synchronized(lock) {
            if (closed) return
            reorder.ack
        }
        val bytes = PathCodec.encodeAck(ack)
        writeTo(path, bytes, priority = true)
    }

    private fun ackLater(path: String) {
        var startTimer = false
        val send = synchronized(lock) {
            if (closed) return
            val at = now()
            ackFrames++
            val due = ackFrames >= ACK_FRAMES || at - lastAckAt >= ACK_MS
            if (due) {
                ackFrames = 0
                lastAckAt = at
                ackDueAt = 0
                ackPath = null
                true
            } else {
                if (ackDueAt == 0L) {
                    ackDueAt = at + ACK_MS
                    startTimer = true
                }
                ackPath = path
                false
            }
        }
        if (startTimer) wake()
        if (send) sendAckNow(path)
    }

    /** True when the reorder window can take one more frame (R-11 retry gate). */
    fun canBuffer(): Boolean = synchronized(lock) {
        reorder.bufferedCount < ReorderWindow.MAX_FRAMES && reorder.bufferedBytes < ReorderWindow.MAX_BYTES
    }

    /** Blocks the reader of [path] while the reorder window is full (PATH-10). */
    fun awaitReorderSpace(path: String) {
        synchronized(lock) {
            while (!closed &&
                (reorder.bufferedCount >= ReorderWindow.MAX_FRAMES ||
                    reorder.bufferedBytes >= ReorderWindow.MAX_BYTES)
            ) {
                lock.wait(50)
            }
        }
    }

    // ---- ping ---------------------------------------------------------

    /**
     * D-1: one path is never pinged (TCP keepalive and the session's 15 s
     * keepalive cover it). Two or more are pinged every 2 s while the screen
     * is on or a transfer runs, else every 15 s.
     */
    fun pingAll(active: Boolean) {
        val at = now()
        val targets = synchronized(lock) {
            if (closed || paths.size < 2) return
            val interval = if (active) ACTIVE_PING_MS else IDLE_PING_MS
            if (lastPingAt != 0L && at - lastPingAt < interval) return
            lastPingAt = at
            paths.keys.toList()
        }
        for (id in targets) {
            synchronized(lock) { pingSentAt[id] = at }
            sendJSONOn(id, mapOf("t" to "path.ping", "path" to id, "ts" to at), priority = true)
        }
    }

    /** D-1: a joined path is pinged at once so its ranking starts. */
    fun pingPath(id: String) {
        val at = now()
        synchronized(lock) {
            if (closed || !paths.containsKey(id)) return
            pingSentAt[id] = at
            lastPingAt = at
        }
        sendJSONOn(id, mapOf("t" to "path.ping", "path" to id, "ts" to at))
    }

    /** D-1: the ticker's next deadline (absolute ms), not a fixed poll. */
    fun nextDeadline(active: Boolean): Long {
        val at = now()
        return synchronized(lock) {
            if (closed) return Long.MAX_VALUE
            var next = Long.MAX_VALUE
            if (paths.size >= 2) {
                val interval = if (active) ACTIVE_PING_MS else IDLE_PING_MS
                next = if (lastPingAt == 0L) at else lastPingAt + interval
            }
            for (sent in pingSentAt.values) {
                val due = sent + PONG_TIMEOUT_MS
                if (due in 0 until next) next = due
            }
            for (sent in joinedAwaitingPong.values) {
                val due = sent + JOINED_PING_DROP_MS
                if (due in 0 until next) next = due
            }
            if (ackDueAt != 0L && ackDueAt in 0 until next) next = ackDueAt
            next
        }
    }

    /** D-1: true while a bulk transfer is moving in either direction. */
    fun bulkActive(): Boolean = synchronized(lock) {
        lastBulkAt != 0L && now() - lastBulkAt <= ACTIVE_PING_MS
    }

    /** A ping with no pong within 1.5 s is one lost sample (PATH-7). */
    fun pongLosses(): List<PongLoss> {
        val at = now()
        val lost = synchronized(lock) {
            pingSentAt.filterValues { at - it > PONG_TIMEOUT_MS }.keys.toList()
        }
        val out = ArrayList<PongLoss>(lost.size)
        for (id in lost) {
            val alive = synchronized(lock) {
                pingSentAt.remove(id)
                lastInboundAt[id]?.let { at - it <= PONG_ALIVE_MS } ?: false
            }
            out.add(PongLoss(id, alive))
        }
        return out
    }

    /** Joined paths that have answered no ping in 5 s (PATH-13). */
    fun joinedTimeouts(): List<String> {
        val at = now()
        val lost = synchronized(lock) {
            joinedAwaitingPong.filterValues { at - it > JOINED_PING_DROP_MS }.keys.toList()
        }
        for (id in lost) synchronized(lock) { joinedAwaitingPong.remove(id) }
        return lost
    }

    companion object {
        const val MAX_PATHS = 3
        const val ACTIVE_PING_MS = 2_000L
        const val IDLE_PING_MS = 15_000L
        const val PONG_TIMEOUT_MS = 1_500L
        /** D-2: inbound bytes this recently mean the path is alive despite a pong loss. */
        const val PONG_ALIVE_MS = 1_500L
        const val JOINED_PING_DROP_MS = 5_000L
        const val ACK_MS = 10L
        const val ACK_FRAMES = 16
        /** How long a close waits for queued bytes (a refusal, a switch marker). */
        const val CLOSE_DRAIN_MS = 300L
        /** E-1/RR-1: a lossy frame waits for the path's writer over this backlog. */
        const val LOSSY_QUEUE_CAP_BYTES = 128 * 1024

        /** E-4/RR-4: bulk takes a seq only while the sending path is under this. */
        const val BULK_QUEUE_WATERMARK_BYTES = 256 * 1024
    }
}
