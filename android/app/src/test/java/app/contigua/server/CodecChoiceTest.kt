package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The codec choice: HEVC is the default, the Mac says it decodes HEVC, and the
 * phone's hardware HEVC encoder takes the size. `codec=avc` forces H.264;
 * every other combination is H.264 with one closed reason: mac, encoder, size
 * or the encoder's remembered configure failure.
 */
class CodecChoiceTest {

    private val avc = setOf(VideoCodec.Avc)
    private val both = setOf(VideoCodec.Avc, VideoCodec.Hevc)
    private val size = IntSize(1280, 720)
    private val hevc = CodecChoice.Encoder.Available { _, _ -> true }

    @Test
    fun theAvcArmForcesH264EvenWhenEverythingElseIsReady() {
        val choice = CodecChoice.choose(VideoCodec.Avc, both, hevc, size)
        assertEquals(VideoCodec.Avc, choice.codec)
        assertNull(choice.reason)
        assertNull(choice.fallbackLine)
    }

    @Test
    fun hevcNeedsTheMacToSayItCanDecodeIt() {
        val choice = CodecChoice.choose(VideoCodec.Hevc, avc, hevc, size)
        assertEquals(VideoCodec.Avc, choice.codec)
        assertEquals("mac", choice.reason)
        assertEquals("codec=hevc unsupported: mac", choice.fallbackLine)
    }

    @Test
    fun hevcNeedsAHardwarePhoneEncoder() {
        val choice = CodecChoice.choose(
            VideoCodec.Hevc,
            both,
            CodecChoice.Encoder.Unavailable("encoder"),
            size,
        )
        assertEquals(VideoCodec.Avc, choice.codec)
        assertEquals("encoder", choice.reason)
        assertEquals("codec=hevc unsupported: encoder", choice.fallbackLine)
    }

    @Test
    fun aRememberedConfigureFailureIsTheReasonForEveryLaterStream() {
        val choice = CodecChoice.choose(
            VideoCodec.Hevc,
            both,
            CodecChoice.Encoder.Unavailable("configure"),
            size,
        )
        assertEquals(VideoCodec.Avc, choice.codec)
        assertEquals("configure", choice.reason)
        assertEquals("codec=hevc unsupported: configure", choice.fallbackLine)
    }

    @Test
    fun hevcNeedsTheEncoderToTakeTheSize() {
        val small = CodecChoice.Encoder.Available { _, _ -> false }
        val choice = CodecChoice.choose(VideoCodec.Hevc, both, small, size)
        assertEquals(VideoCodec.Avc, choice.codec)
        assertEquals("size", choice.reason)
        assertEquals("codec=hevc unsupported: size", choice.fallbackLine)
    }

    @Test
    fun theSizeCheckAsksForTheStreamsOwnSize() {
        var asked: IntSize? = null
        val exact = CodecChoice.Encoder.Available { w, h ->
            asked = IntSize(w, h)
            true
        }
        val choice = CodecChoice.choose(VideoCodec.Hevc, both, exact, IntSize(640, 480))
        assertEquals(VideoCodec.Hevc, choice.codec)
        assertEquals(IntSize(640, 480), asked)
    }

    @Test
    fun everyConditionMetGivesHevcWithNoLine() {
        val choice = CodecChoice.choose(VideoCodec.Hevc, both, hevc, size)
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
