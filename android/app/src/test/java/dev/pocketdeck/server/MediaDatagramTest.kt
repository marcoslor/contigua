package dev.pocketdeck.server

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P3's datagram layout (PROTOCOL "Media over UDP", PATH-27): the exact header
 * sizes, the 1200-byte cap, the 8 MiB access-unit cap and a fragment round
 * trip. No socket, codec or key is involved.
 */
class MediaDatagramTest {

    @Test
    fun `one datagram is exactly 1200 bytes at the fragment cap`() {
        val datagram = MediaDatagram.OUTER_HEADER + MediaDatagram.INNER_HEADER +
            MediaDatagram.MAX_FRAGMENT + MediaDatagram.TAG
        assertEquals(1200, datagram)
        assertEquals(1140, MediaDatagram.MAX_FRAGMENT)
    }

    @Test
    fun `the outer header round-trips`() {
        val header = MediaDatagram.outer(keyId = 0x01020304, epoch = 7, seq = 42,
            ciphertextLen = 26 + 10 + 16)
        val bytes = header + ByteArray(26 + 10 + 16)
        val outer = MediaDatagram.parseOuter(bytes)!!
        assertEquals(0x01020304, outer.keyId)
        assertEquals(7, outer.epoch)
        assertEquals(42, outer.seq)
        assertEquals(52, outer.ciphertextLen)
        assertEquals(18, header.size)
    }

    @Test
    fun `the outer header refuses a foreign, short or inconsistent datagram`() {
        val good = MediaDatagram.outer(1, 1, 1, 26 + 4 + 16) + ByteArray(26 + 4 + 16)
        assertEquals(null, MediaDatagram.parseOuter(ByteArray(17)))
        assertNull(MediaDatagram.parseOuter(good.copyOf().also { it[0] = 0x51 }))
        assertNull(MediaDatagram.parseOuter(good.copyOf().also { it[1] = 2 }))
        assertNull(MediaDatagram.parseOuter(good + byteArrayOf(0)))
        assertNull(MediaDatagram.parseOuter(good.copyOf().also { it[17] = 0 })) // len 0
    }

    @Test
    fun `the inner header round-trips every field`() {
        val bytes = MediaDatagram.inner(
            type = MediaDatagram.Type.Video,
            flags = MediaDatagram.FLAG_KEYFRAME or MediaDatagram.FLAG_RETRANSMIT,
            stream = 9,
            frameId = 0x7FFFFFFF,
            ptsUs = 123_456_789_012L,
            fragmentIndex = 3,
            fragmentCount = 4,
            sendUs = -5,
        )
        val inner = MediaDatagram.parseInner(bytes)!!
        assertEquals(MediaDatagram.Type.Video, inner.type)
        assertTrue(inner.keyframe)
        assertTrue(inner.retransmit)
        assertEquals(9, inner.stream)
        assertEquals(0x7FFFFFFF, inner.frameId)
        assertEquals(123_456_789_012L, inner.ptsUs)
        assertEquals(3, inner.fragmentIndex)
        assertEquals(4, inner.fragmentCount)
        assertEquals(-5, inner.sendUs)
        assertEquals(26, bytes.size)
    }

    @Test
    fun `the inner header refuses audio, unknown types and impossible fragments`() {
        assertThrows(IllegalArgumentException::class.java) {
            MediaDatagram.inner(MediaDatagram.Type.Audio, 0, 0, 0, 0, 0, 1, 0)
        }
        val video = MediaDatagram.inner(MediaDatagram.Type.Video, 0, 0, 0, 0, 0, 1, 0)
        assertEquals(MediaDatagram.Type.Video, MediaDatagram.parseInner(video)!!.type)
        assertNull(MediaDatagram.parseInner(video.copyOf().also { it[0] = 99 }))
        assertNull(MediaDatagram.parseInner(video.copyOf().also { it[19] = 1 })) // index >= count
        assertNull(MediaDatagram.parseInner(video.copyOf().also { it[20] = 0; it[21] = 0 })) // count 0
        assertNull(MediaDatagram.parseInner(video.copyOf().also { it[20] = 0xFF.toByte(); it[21] = 0xFF.toByte() }))
    }

    @Test
    fun `fragmentation covers the 8 MiB cap in 1140-byte pieces`() {
        assertEquals(1, MediaDatagram.fragmentCount(0))
        assertEquals(1, MediaDatagram.fragmentCount(1))
        assertEquals(1, MediaDatagram.fragmentCount(1140))
        assertEquals(2, MediaDatagram.fragmentCount(1141))
        assertEquals(7359, MediaDatagram.fragmentCount(8 * 1024 * 1024))
        assertThrows(IllegalArgumentException::class.java) {
            MediaDatagram.fragmentCount(8 * 1024 * 1024 + 1)
        }
    }

    @Test
    fun `fragments reassemble byte-exact at every boundary`() {
        for (size in intArrayOf(0, 1, 1139, 1140, 1141, 2_281, 10_000)) {
            val unit = ByteArray(size) { (it * 31).toByte() }
            val fragments = MediaDatagram.fragments(unit)
            assertEquals(MediaDatagram.fragmentCount(size), fragments.size)
            assertTrue(fragments.all { it.bytes.size <= MediaDatagram.MAX_FRAGMENT })
            val rebuilt = ByteArray(size)
            var offset = 0
            for (fragment in fragments) {
                assertArrayEquals(unit.copyOfRange(offset, offset + fragment.bytes.size), fragment.bytes)
                fragment.bytes.copyInto(rebuilt, offset)
                offset += fragment.bytes.size
            }
            assertArrayEquals(unit, rebuilt)
        }
    }

    @Test
    fun `a keyframe gets the long deadline`() {
        assertEquals(100, MediaDatagram.deadlineMs(keyframe = false))
        assertEquals(1_000, MediaDatagram.deadlineMs(keyframe = true))
    }
}
