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
) {
    class Transport(
        var id: String,
        val socket: Socket,
        val plain: Socket,
        val kind: PathKind,
    ) {
        val out: OutputStream = BufferedOutputStream(socket.getOutputStream())
        @Volatile var closed = false

        fun write(bytes: ByteArray) {
            if (closed) throw java.io.IOException("path closed")
            synchronized(this) {
                out.write(bytes)
                out.flush()
            }
        }

        fun close() {
            closed = true
            runCatching { plain.shutdownInput() }
            runCatching { plain.shutdownOutput() }
            runCatching { plain.close() }
            runCatching { socket.close() }
        }
    }

    sealed interface Event {
        /** One frame the session dispatcher sees, already deduped and in order. */
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

        /** The reorder window is full: stop reading this path, then retry. */
        data object Backpressure : Event
    }

    private val lock = Object()
    private val paths = LinkedHashMap<String, Transport>()
    private var current: String? = null
    private var replay = ReplayBuffer()
    private val reorder = ReorderWindow()
    private val pendingAck = HashSet<String>()
    private var ackFrames = 0
    private var lastAckAt = 0L
    private var lastPingAt = 0L
    private var pingSentAt = HashMap<String, Long>()
    /** A joined path that never answers a ping is dropped at 5 s (PATH-13). */
    private val joinedAwaitingPong = HashMap<String, Long>()
    private var closed = false
    /** Planned-switch old paths waiting for the peer's marker / the 2 s backstop. */
    private val draining = HashMap<String, Long>()

    val pathCount: Int get() = synchronized(lock) { paths.size }
    val currentPath: String? get() = synchronized(lock) { current }

    fun start(firstPath: Transport) {
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

    /** Marks a joined path's first-pong deadline (PATH-13). */
    fun expectFirstPong(id: String) = synchronized(lock) {
        if (paths.containsKey(id)) joinedAwaitingPong[id] = now()
    }

    /** Adds a joined path; false when the cap (3) is reached or the id is live. */
    fun attach(path: Transport): Boolean = synchronized(lock) {
        if (paths.size >= MAX_PATHS || paths.containsKey(path.id)) return false
        paths[path.id] = path
        if (current == null) current = path.id
        true
    }

    fun transport(id: String): Transport? = synchronized(lock) { paths[id] }

    fun detach(id: String): Boolean = synchronized(lock) {
        val t = paths.remove(id) ?: return false
        if (current == id) current = null
        draining.remove(id)
        pingSentAt.remove(id)
        joinedAwaitingPong.remove(id)
        runCatching { t.close() }
        true
    }

    fun closeAll() {
        val all = synchronized(lock) {
            closed = true
            val copy = paths.values.toList()
            paths.clear()
            current = null
            copy
        }
        for (t in all) runCatching { t.close() }
    }

    /** Sends a reliable frame wrapped, or a lossy one bare (PATH-4/5). */
    fun send(bytes: ByteArray) {
        val type = bytes[4].toInt() and 0xFF
        if (!PathCodec.isReliable(type)) {
            val target = synchronized(lock) { current }
            if (target != null) writeTo(target, bytes)
            return
        }
        val bulk = PathCodec.isBulk(type)
        // The replay buffer holds the frame as sent: the wrapper adds 13 bytes.
        awaitCredit(bytes.size + PathCodec.WRAPPER_BYTES, bulk)
        synchronized(lock) {
            if (closed) return
            val seq = replay.nextSeq
            val inner = frameOf(bytes)
            val wrapped = PathCodec.encodeReliable(seq, inner)
            replay.append(seq, wrapped, bulk)
            val target = current
            if (target != null) {
                try {
                    paths[target]?.write(wrapped)
                } catch (e: Throwable) {
                    failPath(target, e)
                }
            }
        }
    }

    /** Sends one bare JSON/frame on a named path (welcome, pong, ack). */
    fun sendOn(path: String, bytes: ByteArray) {
        writeTo(path, bytes)
    }

    fun sendJSONOn(path: String, obj: Map<String, Any?>) {
        writeTo(path, Frames.encodeJson(0, Json.encode(obj)))
    }

    /** Waits (writer thread) until the replay buffer can take the frame. */
    private fun awaitCredit(bytes: Int, bulk: Boolean) {
        synchronized(lock) {
            while (!closed && !replay.canAdmit(bytes, bulk)) {
                lock.wait(100)
            }
        }
    }

    fun canAdmit(bytes: Int, bulk: Boolean): Boolean = synchronized(lock) { replay.canAdmit(bytes, bulk) }

    /** Writes every unacked frame on the current path (a switch's replay). */
    fun replayOnCurrent() {
        synchronized(lock) {
            val target = current ?: return
            val t = paths[target] ?: return
            for (entry in replay.unacked()) {
                try {
                    t.write(entry.frame)
                } catch (e: Throwable) {
                    failPath(target, e)
                    return
                }
            }
        }
    }

    /** The phone's own marker: my next reliable frame is nextSeq and goes on [to]. */
    fun sendMarker(to: String) = sendMarkerOn(to, to)

    /**
     * A planned switch sends its marker on the path being left (PATH-9). The
     * marker is itself reliable frame `N`, so the field names `N + 1`.
     */
    fun sendMarkerOn(onPath: String, to: String) {
        synchronized(lock) {
            while (!closed) {
                val markerSeq = replay.nextSeq
                val bytes = Frames.encodeJson(
                    0,
                    Json.encode(mapOf("t" to "path.switch", "path" to to, "seq" to markerSeq + 1)),
                )
                if (!replay.canAdmit(bytes.size, bulk = false)) {
                    lock.wait(100)
                    continue
                }
                val wrapped = PathCodec.encodeReliable(markerSeq, frameOf(bytes))
                replay.append(markerSeq, wrapped, false)
                try {
                    paths[onPath]?.write(wrapped)
                } catch (e: Throwable) {
                    failPath(onPath, e)
                }
                return
            }
        }
    }

    /** Moves the sending path; the old one closes after the peer's marker or 2 s. */
    fun moveTo(to: String, plannedFrom: String?) {
        synchronized(lock) {
            if (!paths.containsKey(to)) return
            current = to
            if (plannedFrom != null && plannedFrom != to && paths.containsKey(plannedFrom)) {
                draining[plannedFrom] = now() + DRAIN_BACKSTOP_MS
            }
        }
    }

    fun closeDrained() {
        val due = synchronized(lock) {
            val expired = draining.filterValues { now() >= it }.keys.toList()
            for (id in expired) {
                draining.remove(id)
            }
            expired
        }
        for (id in due) {
            log("path drain backstop: $id")
            detach(id)
        }
    }

    // ---- reading ------------------------------------------------------

    /**
     * Processes one frame from [path]. Reliable frames are unwrapped, deduped,
     * reordered and acked; the returned events are what the session dispatches.
     */
    fun receive(path: String, frame: Frame): List<Event> {
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
                    return listOf(Event.Down(path))
                }
                val result = synchronized(lock) { reorder.receive(inner) }
                when (result) {
                    is ReorderWindow.Result.Deliver -> {
                        for (f in result.frames) {
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
                    ReorderWindow.Result.Full -> events.add(Event.Backpressure)
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
                                sendJSONOn(path, mapOf("t" to "path.pong", "path" to pingPath, "ts" to ts))
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

    private fun writeTo(path: String, bytes: ByteArray) {
        val t = synchronized(lock) { paths[path] } ?: return
        try {
            t.write(bytes)
        } catch (e: Throwable) {
            failPath(path, e)
        }
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

    private fun sendAckNow(path: String) {
        val ack = synchronized(lock) { reorder.ack }
        val bytes = PathCodec.encodeAck(ack)
        writeTo(path, bytes)
    }

    private fun ackLater(path: String) {
        val send = synchronized(lock) {
            ackFrames++
            val due = ackFrames >= ACK_FRAMES || now() - lastAckAt >= ACK_MS
            if (due) {
                ackFrames = 0
                lastAckAt = now()
                true
            } else false
        }
        if (send) sendAckNow(path)
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

    /** Every path is pinged every 2 s, the standby included (PATH-7). */
    fun pingAll() {
        val at = now()
        val targets = synchronized(lock) {
            if (closed || at - lastPingAt < PING_MS) return
            lastPingAt = at
            paths.keys.toList()
        }
        for (id in targets) {
            synchronized(lock) { pingSentAt[id] = at }
            sendJSONOn(id, mapOf("t" to "path.ping", "path" to id, "ts" to at))
        }
    }

    /** A ping with no pong within 1.5 s is one lost sample (PATH-7). */
    fun pongTimeouts(): List<String> {
        val at = now()
        val lost = synchronized(lock) {
            pingSentAt.filterValues { at - it > PONG_TIMEOUT_MS }.keys.toList()
        }
        for (id in lost) {
            synchronized(lock) { pingSentAt.remove(id) }
        }
        return lost
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
        const val PING_MS = 2_000L
        const val PONG_TIMEOUT_MS = 1_500L
        const val DRAIN_BACKSTOP_MS = 2_000L
        const val JOINED_PING_DROP_MS = 5_000L
        const val ACK_MS = 10L
        const val ACK_FRAMES = 16
    }
}
