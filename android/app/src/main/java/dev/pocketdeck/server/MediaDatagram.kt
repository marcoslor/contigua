package dev.pocketdeck.server

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * P3's UDP media packet (docs/PROTOCOL.md "Media over UDP", PATH-27). Pure byte
 * layout: the socket and the AEAD live in [MediaCrypto]/the sender, so the JVM
 * tests pin every field, the 1200-byte datagram and the 8 MiB access-unit cap
 * without a codec, a phone or a key.
 *
 * Outer (18 bytes, plaintext, the AEAD associated data):
 *   magic u8 = 0x50 · version u8 = 1 · keyId u32 · epoch u16 · seq u64 ·
 *   ciphertextLen u16
 * Inner (26 bytes, sealed):
 *   type u8 · flags u8 · stream u32 · frameId u32 · ptsUs u64 ·
 *   fragmentIndex u16 · fragmentCount u16 · sendUs u32
 */
object MediaDatagram {
    const val MAGIC = 0x50
    const val VERSION = 1
    const val OUTER_HEADER = 18
    const val INNER_HEADER = 26
    const val TAG = 16
    const val MAX_DATAGRAM = 1200
    const val MAX_FRAGMENT = MAX_DATAGRAM - OUTER_HEADER - INNER_HEADER - TAG // 1140
    const val MAX_FRAME = 8 * 1024 * 1024

    const val FLAG_KEYFRAME = 1
    const val FLAG_RETRANSMIT = 2

    enum class Type(val wire: Int) {
        Video(1),
        Audio(2),
        Feedback(3),
        Nack(4),
        Probe(5),
        ProbeReply(6),
        Parity(7);

        companion object {
            fun of(wire: Int): Type? = entries.firstOrNull { it.wire == wire }
        }
    }

    data class Outer(val keyId: Int, val epoch: Int, val seq: Long, val ciphertextLen: Int)

    data class Inner(
        val type: Type,
        val flags: Int,
        val stream: Int,
        val frameId: Int,
        val ptsUs: Long,
        val fragmentIndex: Int,
        val fragmentCount: Int,
        val sendUs: Int,
    ) {
        val keyframe: Boolean get() = flags and FLAG_KEYFRAME != 0
        val retransmit: Boolean get() = flags and FLAG_RETRANSMIT != 0
    }

    /**
     * The outer header. `ciphertextLen` is the inner header plus the payload
     * plus the 16-byte tag; the whole datagram is 18 + that.
     */
    fun outer(keyId: Int, epoch: Int, seq: Long, ciphertextLen: Int): ByteArray {
        require(epoch in 0..0xFFFF) { "epoch" }
        require(ciphertextLen in INNER_HEADER + TAG..MAX_DATAGRAM - OUTER_HEADER) { "ciphertextLen" }
        return ByteBuffer.allocate(OUTER_HEADER).order(ByteOrder.BIG_ENDIAN).apply {
            put(MAGIC.toByte())
            put(VERSION.toByte())
            putInt(keyId)
            putShort(epoch.toShort())
            putLong(seq)
            putShort(ciphertextLen.toShort())
        }.array()
    }

    /** The outer header only; nil for a short, foreign or impossible datagram. */
    fun parseOuter(bytes: ByteArray): Outer? {
        if (bytes.size < OUTER_HEADER || bytes.size > MAX_DATAGRAM) return null
        if (bytes[0].toInt() and 0xFF != MAGIC) return null
        if (bytes[1].toInt() and 0xFF != VERSION) return null
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        buffer.position(2)
        val keyId = buffer.int
        val epoch = buffer.short.toInt() and 0xFFFF
        val seq = buffer.long
        val ciphertextLen = buffer.short.toInt() and 0xFFFF
        if (ciphertextLen < INNER_HEADER + TAG) return null
        if (OUTER_HEADER + ciphertextLen != bytes.size) return null
        return Outer(keyId, epoch, seq, ciphertextLen)
    }

    /** The plaintext inner header, before AEAD. */
    fun inner(
        type: Type,
        flags: Int,
        stream: Int,
        frameId: Int,
        ptsUs: Long,
        fragmentIndex: Int,
        fragmentCount: Int,
        sendUs: Int,
    ): ByteArray {
        require(type != Type.Audio) { "audio is reserved; it stays on TCP" }
        require(fragmentIndex in 0 until fragmentCount) { "fragmentIndex" }
        require(fragmentCount in 1..MAX_FRAGMENT_COUNT) { "fragmentCount" }
        return ByteBuffer.allocate(INNER_HEADER).order(ByteOrder.BIG_ENDIAN).apply {
            put(type.wire.toByte())
            put(flags.toByte())
            putInt(stream)
            putInt(frameId)
            putLong(ptsUs)
            putShort(fragmentIndex.toShort())
            putShort(fragmentCount.toShort())
            putInt(sendUs)
        }.array()
    }

    /** The inner header at `offset` (the ciphertext's start); nil if short. */
    fun parseInner(bytes: ByteArray, offset: Int = 0): Inner? {
        if (offset < 0 || bytes.size - offset < INNER_HEADER) return null
        val buffer = ByteBuffer.wrap(bytes, offset, bytes.size - offset).order(ByteOrder.BIG_ENDIAN)
        val type = Type.of(buffer.get().toInt() and 0xFF) ?: return null
        val flags = buffer.get().toInt() and 0xFF
        val stream = buffer.int
        val frameId = buffer.int
        val ptsUs = buffer.long
        val fragmentIndex = buffer.short.toInt() and 0xFFFF
        val fragmentCount = buffer.short.toInt() and 0xFFFF
        val sendUs = buffer.int
        if (fragmentCount !in 1..MAX_FRAGMENT_COUNT) return null
        if (fragmentIndex >= fragmentCount) return null
        return Inner(type, flags, stream, frameId, ptsUs, fragmentIndex, fragmentCount, sendUs)
    }

    /** Fragments needed for an access unit, before the fragment itself. */
    fun fragmentCount(size: Int): Int {
        require(size in 0..MAX_FRAME) { "access unit" }
        return if (size == 0) 1 else (size + MAX_FRAGMENT - 1) / MAX_FRAGMENT
    }

    const val MAX_FRAGMENT_COUNT = (MAX_FRAME + MAX_FRAGMENT - 1) / MAX_FRAGMENT // 7359

    /** One fragment of an access unit; [bytes] is the access-unit slice. */
    data class Fragment(val index: Int, val count: Int, val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean =
            other is Fragment && index == other.index && count == other.count &&
                bytes.contentEquals(other.bytes)

        override fun hashCode(): Int = (index * 31 + count) * 31 + bytes.contentHashCode()
    }

    /** Splits one access unit (valueless: never drops or reorders fragments). */
    fun fragments(accessUnit: ByteArray): List<Fragment> {
        val count = fragmentCount(accessUnit.size)
        val out = ArrayList<Fragment>(count)
        var offset = 0
        for (index in 0 until count) {
            val end = minOf(offset + MAX_FRAGMENT, accessUnit.size)
            out += Fragment(index, count, accessUnit.copyOfRange(offset, end))
            offset = end
        }
        return out
    }

    /**
     * The receiver's deadline for a whole access unit: 100 ms for a delta,
     * 1 s for a keyframe (its bits can take that long at the target rate).
     */
    fun deadlineMs(keyframe: Boolean): Long = if (keyframe) 1_000 else 100
}
