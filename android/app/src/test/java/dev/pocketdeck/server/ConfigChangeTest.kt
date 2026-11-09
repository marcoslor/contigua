package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-63: the encoder's per-frame statistics change its output format before
 * almost every frame with the same parameter sets; only a real change may go
 * out as a VIDEO_CONFIG.
 */
class ConfigChangeTest {

    private val sps = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0xC0.toByte(), 0x1E)
    private val pps = byteArrayOf(0, 0, 0, 1, 0x68, 0xCE.toByte(), 0x38, 0x80.toByte())
    private val csd = sps + pps
    private val picture = IntRect(0, 0, 2136, 1482)

    @Test
    fun `the first format of an encoder always goes out`() {
        assertTrue(ConfigChange().shouldSend(1, 2136, 1482, picture, csd))
    }

    @Test
    fun `a moving picture's per-frame format changes send one config, not one per frame`() {
        val change = ConfigChange()
        // The real phone: 600+ format changes in a few seconds of video, each
        // with a new QP average and the same parameter sets.
        val sent = (0 until 600).count { change.shouldSend(1, 2136, 1482, picture, csd.copyOf()) }
        assertEquals(1, sent)
    }

    @Test
    fun `new parameter sets go out`() {
        val change = ConfigChange()
        change.shouldSend(1, 2136, 1482, picture, csd)
        val newPps = sps + byteArrayOf(0, 0, 0, 1, 0x68, 0xCE.toByte(), 0x3C, 0x80.toByte())
        assertTrue(change.shouldSend(1, 2136, 1482, picture, newPps))
        assertFalse(change.shouldSend(1, 2136, 1482, picture, newPps))
    }

    @Test
    fun `a new size, picture rect or codec goes out`() {
        val change = ConfigChange()
        change.shouldSend(1, 2136, 1482, picture, csd)
        assertTrue(change.shouldSend(1, 1080, 1482, picture, csd))
        assertTrue(change.shouldSend(1, 1080, 1482, IntRect(0, 0, 1080, 1482), csd))
        assertTrue(change.shouldSend(2, 1080, 1482, IntRect(0, 0, 1080, 1482), csd))
    }

    @Test
    fun `a change back to an earlier format goes out`() {
        val change = ConfigChange()
        change.shouldSend(1, 2136, 1482, picture, csd)
        change.shouldSend(1, 1080, 1482, picture, csd)
        assertTrue(change.shouldSend(1, 2136, 1482, picture, csd))
    }

    @Test
    fun `the remembered bytes are a copy`() {
        val change = ConfigChange()
        val bytes = csd.copyOf()
        change.shouldSend(1, 2136, 1482, picture, bytes)
        bytes[bytes.size - 1] = 0x7F
        assertTrue(change.shouldSend(1, 2136, 1482, picture, bytes))
    }
}
