package dev.pocketdeck.server

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P3's key derivation and AEAD (PATH-26). The HKDF is pinned to RFC 5869's
 * first vector; the session context, direction split, seal/open and tamper
 * behaviour are pinned here so the socket code has a byte-exact core.
 */
class MediaCryptoTest {

    private val session = "00112233445566778899aabbccddeeff"

    private fun exporter() = ByteArray(32) { it.toByte() }
    private fun pin(fill: Int) = ByteArray(32) { fill.toByte() }

    @Test
    fun `HKDF matches RFC 5869 test case 1`() {
        val ikm = ByteArray(22) { 0x0b.toByte() }
        val salt = ByteArray(13) { it.toByte() }
        val info = ByteArray(10) { (0xf0 + it).toByte() }
        val prk = MediaCrypto.hkdfExtract(salt, ikm)
        assertEquals(
            "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5",
            hex(prk),
        )
        assertEquals(
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
            hex(MediaCrypto.hkdfExpand(prk, info, 42)),
        )
    }

    @Test
    fun `the same context derives the same keys and opposite directions differ`() {
        val a = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        val b = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        assertEquals(a, b)
        assertNotEquals(hex(a.c2s), hex(a.s2c))
        assertEquals(32, a.c2s.size)
        assertEquals(32, a.s2c.size)
        val digest = MediaCrypto.sha256(a.c2s + a.s2c)
        assertEquals(hex(digest.copyOf(4)), String.format("%08x", a.keyId))
    }

    @Test
    fun `two sessions, or a changed pin, give unrelated keys`() {
        val base = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        val otherSession = MediaCrypto.derive(exporter(), "ffeeddccbbaa99887766554433221100",
            pin(0x11), pin(0x22))
        val otherPin = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x23))
        assertNotEquals(hex(base.c2s), hex(otherSession.c2s))
        assertNotEquals(hex(base.s2c), hex(otherSession.s2c))
        assertNotEquals(base.keyId, otherSession.keyId)
        assertNotEquals(hex(base.c2s), hex(otherPin.c2s))
    }

    private fun inner(flags: Int = MediaDatagram.FLAG_KEYFRAME) =
        MediaDatagram.inner(MediaDatagram.Type.Video, flags, 7, 9, 123_456, 0, 1, 42)

    private fun datagram(keys: MediaCrypto.Keys, seq: Long, epoch: Int = 1,
                         flags: Int = MediaDatagram.FLAG_KEYFRAME): ByteArray {
        val bytes = inner(flags)
        val outer = MediaDatagram.outer(keys.keyId, epoch, seq, bytes.size + MediaDatagram.TAG)
        return MediaCrypto.seal(keys.c2s, seq, outer, bytes)
    }

    @Test
    fun `the same seal at the same sequence is the identical datagram`() {
        val keys = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        // A NACK retransmit resends the original bytes, not a re-seal with a
        // fresh sequence: same key + same nonce yields the identical ciphertext.
        assertArrayEquals(datagram(keys, 10), datagram(keys, 10))
        val replay = MediaReplayWindow()
        assertArrayEquals(inner(), MediaCrypto.openAndAccept(keys.c2s, datagram(keys, 10), replay))
        assertNull("the duplicate is delivered once", MediaCrypto.openAndAccept(keys.c2s, datagram(keys, 10), replay))
    }

    @Test
    fun `a retry may take a fresh sequence instead`() {
        val keys = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        val first = datagram(keys, 10)
        val retry = datagram(keys, 11, flags = MediaDatagram.FLAG_RETRANSMIT)
        assertTrue(!first.contentEquals(retry))
        val replay = MediaReplayWindow()
        assertArrayEquals(inner(), MediaCrypto.openAndAccept(keys.c2s, first, replay))
        assertArrayEquals(inner(MediaDatagram.FLAG_RETRANSMIT),
            MediaCrypto.openAndAccept(keys.c2s, retry, replay))
    }

    @Test
    fun `a tampered high sequence never moves the replay window`() {
        val keys = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        val replay = MediaReplayWindow()
        val tampered = datagram(keys, 5000).copyOf().also { it[20] = (it[20] + 1).toByte() }
        assertNull("AEAD fails", MediaCrypto.openAndAccept(keys.c2s, tampered, replay))
        assertEquals("the window did not advance", 0L, replay.highest())
        // A valid low sequence is still accepted; had the window moved first,
        // seq 1 would be outside the 1024-packet window.
        assertArrayEquals(inner(), MediaCrypto.openAndAccept(keys.c2s, datagram(keys, 1), replay))
        assertEquals(1L, replay.highest())
    }

    @Test
    fun `a valid packet is accepted once`() {
        val keys = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        val replay = MediaReplayWindow()
        val at10 = datagram(keys, 10)
        assertArrayEquals(inner(), MediaCrypto.openAndAccept(keys.c2s, at10, replay))
        assertNull(MediaCrypto.openAndAccept(keys.c2s, at10, replay))
        assertArrayEquals(inner(), MediaCrypto.openAndAccept(keys.c2s, datagram(keys, 11), replay))
    }

    @Test
    fun `seal and open round-trip, and every tamper is refused`() {
        val keys = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        val inner = MediaDatagram.inner(MediaDatagram.Type.Video,
            MediaDatagram.FLAG_KEYFRAME, 7, 9, 123_456, 0, 1, 42)
        val outer = MediaDatagram.outer(keys.keyId, 3, 10, inner.size + MediaDatagram.TAG)
        val datagram = MediaCrypto.seal(keys.c2s, 10, outer, inner)
        assertEquals(18 + inner.size + 16, datagram.size)
        assertArrayEquals(inner, MediaCrypto.open(keys.c2s, datagram))
        assertNull("the other direction is a different key", MediaCrypto.open(keys.s2c, datagram))

        assertNull(MediaCrypto.open(keys.c2s, datagram.copyOf().also { it[20] = (it[20] + 1).toByte() }))
        assertNull(MediaCrypto.open(keys.c2s, datagram.copyOf().also { it[13] = (it[13] + 1).toByte() }))
        assertNull(MediaCrypto.open(keys.c2s, datagram + byteArrayOf(0)))
        assertNull(MediaCrypto.open(keys.c2s, datagram.copyOf().also { it[0] = 0x51 }))
    }

    @Test
    fun `the nonce is four zero bytes then the sequence`() {
        assertEquals("000000000000000000000001", hex(MediaCrypto.nonce(1)))
        assertEquals("000000000000000000000002", hex(MediaCrypto.nonce(2)))
        assertNotEquals(hex(MediaCrypto.nonce(1)), hex(MediaCrypto.nonce(2)))
    }

    @Test
    fun `clearing the keys zeroes both directions`() {
        val keys = MediaCrypto.derive(exporter(), session, pin(0x11), pin(0x22))
        keys.clear()
        assertTrue(keys.c2s.all { it.toInt() == 0 })
        assertTrue(keys.s2c.all { it.toInt() == 0 })
    }
}

private fun hex(bytes: ByteArray): String =
    bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
