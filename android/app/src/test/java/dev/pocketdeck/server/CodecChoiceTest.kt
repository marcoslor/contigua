package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The codec choice: the arm asks, the Mac says it can decode HEVC, and the
 * phone's HEVC encoder takes the size. Every other combination is H.264 with
 * one closed reason: mac, encoder or size.
 */
class CodecChoiceTest {

    private val avc = setOf(VideoCodec.Avc)
    private val both = setOf(VideoCodec.Avc, VideoCodec.Hevc)

    @Test
    fun theDefaultArmIsAlwaysAvc() {
        val choice = CodecChoice.choose(VideoCodec.Avc, both, hevcEncoder = true, sizeSupported = true)
        assertEquals(VideoCodec.Avc, choice.codec)
        assertNull(choice.reason)
        assertNull(choice.fallbackLine)
    }

    @Test
    fun hevcNeedsTheMacToSayItCanDecodeIt() {
        val choice = CodecChoice.choose(VideoCodec.Hevc, avc, hevcEncoder = true, sizeSupported = true)
        assertEquals(VideoCodec.Avc, choice.codec)
        assertEquals("mac", choice.reason)
        assertEquals("codec=hevc unsupported: mac", choice.fallbackLine)
    }

    @Test
    fun hevcNeedsThePhoneEncoder() {
        val choice = CodecChoice.choose(VideoCodec.Hevc, both, hevcEncoder = false, sizeSupported = false)
        assertEquals(VideoCodec.Avc, choice.codec)
        assertEquals("encoder", choice.reason)
        assertEquals("codec=hevc unsupported: encoder", choice.fallbackLine)
    }

    @Test
    fun hevcNeedsTheEncoderToTakeTheSize() {
        val choice = CodecChoice.choose(VideoCodec.Hevc, both, hevcEncoder = true, sizeSupported = false)
        assertEquals(VideoCodec.Avc, choice.codec)
        assertEquals("size", choice.reason)
        assertEquals("codec=hevc unsupported: size", choice.fallbackLine)
    }

    @Test
    fun everyConditionMetGivesHevcWithNoLine() {
        val choice = CodecChoice.choose(VideoCodec.Hevc, both, hevcEncoder = true, sizeSupported = true)
        assertEquals(VideoCodec.Hevc, choice.codec)
        assertNull(choice.reason)
        assertNull(choice.fallbackLine)
    }

    @Test
    fun aMissingCodecsListMeansAvcOnly() {
        assertEquals(avc, CodecChoice.macCodecs(null))
        assertEquals(avc, CodecChoice.macCodecs(emptyList<String>()))
        assertEquals(avc, CodecChoice.macCodecs(listOf("avc")))
    }

    @Test
    fun theMacsListIsParsedByName() {
        assertEquals(both, CodecChoice.macCodecs(listOf("avc", "hevc")))
        assertEquals(setOf(VideoCodec.Hevc), CodecChoice.macCodecs(listOf("hevc")))
        // An unknown name never becomes a second codec.
        assertEquals(avc, CodecChoice.macCodecs(listOf("h265", 7, null)))
        assertTrue(CodecChoice.macCodecs(listOf("hevc")).contains(VideoCodec.Hevc))
    }
}
