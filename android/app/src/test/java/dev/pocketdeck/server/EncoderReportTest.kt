package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The encoder report the Mac gets at session start (ISS-39): the codec's own
 * alignment and maximum size, and the largest pixel count it takes at 60 fps.
 * A fake capabilities object stands in for MediaCodec so the search is pure.
 */
class EncoderReportTest {

    private class Caps(
        override val maxWidth: Int = 8192,
        override val maxHeight: Int = 8192,
        override val widthAlignment: Int = 2,
        override val heightAlignment: Int = 2,
        private val maxPixelsAt60: Long = Long.MAX_VALUE,
        private val maxFps: Double = 60.0,
    ) : EncoderCapabilities {
        override fun isSizeAndRateSupported(width: Int, height: Int, fps: Double): Boolean =
            width > 0 && height > 0 && fps <= maxFps &&
                width.toLong() * height.toLong() <= maxPixelsAt60
    }

    @Test
    fun `the report carries the codec's alignment and maximum size`() {
        val report = EncoderReport.from(Caps(maxWidth = 4096, maxHeight = 2160, widthAlignment = 2,
                                             heightAlignment = 4))
        assertEquals(2, report.widthAlign)
        assertEquals(4, report.heightAlign)
        assertEquals(4096, report.maxWidth)
        assertEquals(2160, report.maxHeight)
    }

    @Test
    fun `the 60 fps pixel count is the largest area the codec takes`() {
        val caps = Caps(maxPixelsAt60 = 3840L * 2160)
        val report = EncoderReport.from(caps)
        assertEquals(3840L * 2160, report.maxPixelsAt60.toLong())
        assertTrue(caps.isSizeAndRateSupported(3840, 2160, 60.0))
        assertTrue(!caps.isSizeAndRateSupported(3840, 2161, 60.0))
    }

    @Test
    fun `a codec with no area limit reports its whole box`() {
        val report = EncoderReport.from(Caps(maxWidth = 1280, maxHeight = 720))
        assertEquals(1280L * 720, report.maxPixelsAt60.toLong())
    }

    @Test
    fun `the count follows the size ceiling, not a hardcoded number`() {
        val caps = Caps(maxWidth = 1920, maxHeight = 1080, maxPixelsAt60 = Long.MAX_VALUE)
        val report = EncoderReport.from(caps)
        assertEquals(1920L * 1080, report.maxPixelsAt60.toLong())
    }

    @Test
    fun `the wire names are the protocol's`() {
        val wire = EncoderReport.from(Caps(maxWidth = 4096, maxHeight = 2160)).wire()
        assertEquals(2, wire["widthAlign"])
        assertEquals(2, wire["heightAlign"])
        assertEquals(4096, wire["maxWidth"])
        assertEquals(2160, wire["maxHeight"])
        assertTrue((wire["maxPixels60"] as Int) > 0)
    }
}
