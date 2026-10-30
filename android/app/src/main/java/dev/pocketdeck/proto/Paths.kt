package dev.pocketdeck.proto

import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.TreeMap

/**
 * The paths layer's pure core (docs/design/paths.md §3/§5/§8,
 * docs/specs/transport.md PATH-4/10/19, docs/PROTOCOL.md § "Paths"): the
 * RELIABLE/ACK codec, the replay buffer with credit, the reorder window, the
 * ids and the protocol version. The Mac's `PathsCore.swift` mirrors these
 * shapes and their golden vectors.
 */

/** Thrown for a paths-wire violation. */
class PathException(message: String) : Exception(message)

/** PATH-1/2: `hello.v` is 4 and another version is refused, never downgraded. */
object PathVersion {
    const val CURRENT = 4

    /** A peer's `v` (null = a v3 phone that sends none) that is not ours. */
    fun refused(peer: Int?): Boolean = peer != CURRENT

    /** The Mac's sentence for a phone that refused it. */
    fun macSentence(peer: Int?): String =
        if (peer != null && peer > CURRENT) "Update PocketDeck on this Mac."
        else "Update PocketDeck on your phone."

    /** The phone's sentence for a Mac whose hello carried another `v`. */
    fun phoneSentence(mac: Int?): String =
        if (mac != null && mac > CURRENT) "Update PocketDeck on your phone."
        else "Update PocketDeck on this Mac."

    /** `error version` with the refusing side's own version. */
    fun refusal(own: Int = CURRENT): ByteArray =
        Frames.encodeJson(0, Json.encode(mapOf("t" to "error", "code" to "version", "v" to own)))
}

/** PATH-3/19: a 128-bit session id, an 8-hex path id. */
object PathIds {
    private val random = SecureRandom()

    fun sessionId(): String {
        val bytes = ByteArray(16)
        random.nextBytes(bytes)
        return hex(bytes)
    }

    /** 8 lowercase hex, unique among the session's live path ids. */
    fun pathId(among: Set<String>): String {
        while (true) {
            val bytes = ByteArray(4)
            random.nextBytes(bytes)
            val candidate = hex(bytes)
            if (candidate !in among) return candidate
        }
    }

    fun hex(bytes: ByteArray): String {
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append("0123456789abcdef"[v ushr 4])
            out.append("0123456789abcdef"[v and 0x0F])
        }
        return out.toString()
    }
}

/** The paths wire: RELIABLE (0x30) and ACK (0x31). */
object PathCodec {
    const val TYPE_RELIABLE = 0x30
    const val TYPE_ACK = 0x31

    /** The RELIABLE payload's own header: 8 (seq) + 1 (type) + 4 (stream). */
    const val WRAPPER_BYTES = 13

    /** The largest inner payload the 8 MiB frame `len` (18 + n) can carry. */
    const val MAX_INNER_PAYLOAD = Frames.MAX_FRAME - 18

    /** Reliable types, wrapped in 0x30 (docs/design/paths.md §5.5). */
    fun isReliable(type: Int): Boolean = when (type) {
        Frames.TYPE_JSON, Frames.TYPE_TOUCH, Frames.TYPE_SCROLL, Frames.TYPE_KEY,
        Frames.TYPE_APK_DATA, Frames.TYPE_SHARE_DATA, Frames.TYPE_DROP_DATA,
        Frames.TYPE_CLIP_DATA, Frames.TYPE_FS_DATA -> true
        else -> false
    }

    /** Bulk producers share the 12 MiB budget; everything else is control. */
    fun isBulk(type: Int): Boolean = when (type) {
        Frames.TYPE_APK_DATA, Frames.TYPE_SHARE_DATA, Frames.TYPE_DROP_DATA,
        Frames.TYPE_CLIP_DATA, Frames.TYPE_FS_DATA -> true
        else -> false
    }

    data class Reliable(val seq: Long, val inner: Frame)

    fun encodeReliable(seq: Long, inner: Frame): ByteArray {
        if (!isReliable(inner.type)) throw PathException("not a reliable type: ${inner.type}")
        if (inner.payload.size > MAX_INNER_PAYLOAD) {
            throw PathException("inner payload too large: ${inner.payload.size}")
        }
        val payload = ByteArray(WRAPPER_BYTES + inner.payload.size)
        putLong(payload, 0, seq)
        payload[8] = inner.type.toByte()
        putInt(payload, 9, inner.stream)
        System.arraycopy(inner.payload, 0, payload, 13, inner.payload.size)
        return Frames.encode(TYPE_RELIABLE, inner.stream, payload)
    }

    fun decodeReliable(frame: Frame): Reliable {
        if (frame.type != TYPE_RELIABLE) throw PathException("not a RELIABLE frame")
        val p = frame.payload
        if (p.size < 13) throw PathException("short RELIABLE payload")
        val seq = readLong(p, 0)
        val innerType = p[8].toInt() and 0xFF
        val innerStream = readInt(p, 9)
        if (innerStream != frame.stream) {
            throw PathException("outer stream ${frame.stream} differs from inner $innerStream")
        }
        val inner = p.copyOfRange(13, p.size)
        return Reliable(seq, Frame(innerType, innerStream, inner))
    }

    fun encodeAck(ack: Long): ByteArray {
        val payload = ByteArray(8)
        putLong(payload, 0, ack)
        return Frames.encode(TYPE_ACK, 0, payload)
    }

    fun decodeAck(frame: Frame): Long {
        if (frame.type != TYPE_ACK || frame.stream != 0 || frame.payload.size != 8) {
            throw PathException("bad ACK frame")
        }
        return readLong(frame.payload, 0)
    }

    fun readInt(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 24) or ((b[off + 1].toInt() and 0xFF) shl 16) or
            ((b[off + 2].toInt() and 0xFF) shl 8) or (b[off + 3].toInt() and 0xFF)

    fun readLong(b: ByteArray, off: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (b[off + i].toLong() and 0xFF)
        return v
    }

    fun putInt(b: ByteArray, off: Int, value: Int) {
        b[off] = (value ushr 24).toByte()
        b[off + 1] = (value ushr 16).toByte()
        b[off + 2] = (value ushr 8).toByte()
        b[off + 3] = value.toByte()
    }

    fun putLong(b: ByteArray, off: Int, value: Long) {
        for (i in 0 until 8) b[off + i] = (value ushr (56 - 8 * i)).toByte()
    }
}

/**
 * The per-direction replay buffer (docs/design/paths.md §8): a producer asks
 * [canAdmit] before reading the next chunk, so it never overflows and no frame
 * is dropped. Bulk is capped at 12 MiB, leaving 4 MiB for control.
 */
class ReplayBuffer {
    data class Entry(val seq: Long, val frame: ByteArray, val bulk: Boolean) {
        override fun equals(other: Any?): Boolean =
            other is Entry && seq == other.seq && bulk == other.bulk && frame.contentEquals(other.frame)
        override fun hashCode(): Int = (seq.hashCode() * 31 + frame.contentHashCode()) * 31 + bulk.hashCode()
    }

    var lastAck: Long = 1
        private set
    var lastSeq: Long = 0
        private set
    var heldBytes: Int = 0
        private set
    var bulkBytes: Int = 0
        private set
    private val entries = ArrayDeque<Entry>()

    val count: Int get() = entries.size
    val isEmpty: Boolean get() = entries.isEmpty()
    val nextSeq: Long get() = lastSeq + 1

    /** True when a frame of [bytes] may be created now. */
    fun canAdmit(bytes: Int, bulk: Boolean): Boolean {
        if (bytes < 0 || bytes > Frames.MAX_FRAME + 4) return false
        if (heldBytes + bytes > CAPACITY) return false
        return if (bulk) bulkBytes + bytes <= BULK_CAPACITY else true
    }

    fun append(seq: Long, frame: ByteArray, bulk: Boolean) {
        if (seq != nextSeq) throw PathException("seq $seq is not the next ($nextSeq)")
        if (!canAdmit(frame.size, bulk)) throw PathException("replay buffer full for ${frame.size} bytes")
        entries.addLast(Entry(seq, frame, bulk))
        lastSeq = seq
        heldBytes += frame.size
        if (bulk) bulkBytes += frame.size
    }

    /** Releases everything the peer acknowledged; returns the release count. */
    fun ack(nextExpected: Long): Int {
        if (nextExpected <= lastAck) return 0
        lastAck = nextExpected
        var released = 0
        while (true) {
            val first = entries.peekFirst() ?: break
            if (first.seq >= nextExpected) break
            entries.removeFirst()
            heldBytes -= first.frame.size
            if (first.bulk) bulkBytes -= first.frame.size
            released++
        }
        return released
    }

    fun ackAboveSent(ack: Long): Boolean = ack > lastSeq + 1

    /** The unacked frames from the peer's last ack, oldest first. */
    fun unacked(): List<Entry> = entries.toList()

    fun discardAll() {
        entries.clear()
        heldBytes = 0
        bulkBytes = 0
    }

    companion object {
        const val CAPACITY = 16 shl 20
        const val BULK_CAPACITY = 12 shl 20
    }
}

/**
 * The receive side's out-of-order window: 64 frames / 4 MiB. A full window
 * makes the caller stop reading that path; it never drops.
 */
class ReorderWindow {
    sealed interface Result {
        data class Deliver(val frames: List<PathCodec.Reliable>) : Result
        data object Duplicate : Result
        data object Buffered : Result
        data object Full : Result
    }

    var expected: Long = 1
        private set
    var bufferedBytes: Int = 0
        private set
    private val buffered = TreeMap<Long, PathCodec.Reliable>()

    val ack: Long get() = expected
    val bufferedCount: Int get() = buffered.size

    fun receive(frame: PathCodec.Reliable, payloadBytes: Int = frame.inner.payload.size): Result {
        if (frame.seq < expected) return Result.Duplicate
        if (frame.seq == expected) {
            val out = ArrayList<PathCodec.Reliable>()
            out.add(frame)
            expected++
            while (true) {
                val next = buffered.remove(expected) ?: break
                bufferedBytes -= next.inner.payload.size
                out.add(next)
                expected++
            }
            return Result.Deliver(out)
        }
        if (buffered.containsKey(frame.seq)) return Result.Duplicate
        if (buffered.size >= MAX_FRAMES || bufferedBytes + payloadBytes > MAX_BYTES) return Result.Full
        buffered[frame.seq] = frame
        bufferedBytes += payloadBytes
        return Result.Buffered
    }

    fun reset() {
        expected = 1
        buffered.clear()
        bufferedBytes = 0
    }

    companion object {
        const val MAX_FRAMES = 64
        const val MAX_BYTES = 4 shl 20
    }
}

/** A path's provider (design/paths.md §9): bytes and a declared class only. */
enum class PathKind(val floorMbps: Int, val typicalMbps: Int?) {
    LAN(100, 209),
    DIRECT(8, null),
    WAN(2, 8),
}

sealed interface PathAvailability {
    data object Ready : PathAvailability
    data class NeedsSetup(val code: String) : PathAvailability
    data class Unavailable(val code: String) : PathAvailability
}
